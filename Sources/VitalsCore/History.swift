import Foundation
import os

/// An issue that was seen at some point. Closed when it stops being reported.
public struct Incident: Codable, Identifiable, Sendable, Equatable {
    public var key: String
    public var kind: IssueKind
    public var severity: Severity
    public var title: String
    public var detail: String
    public var openedAt: Date
    public var closedAt: Date?
    public var clearedByUser: Bool
    public var id: String { "\(key)@\(openedAt.timeIntervalSince1970)" }
}

public struct Snapshot: Codable, Sendable, Equatable {
    public let at: Date
    public let load1: Double
    public let memPct: Double
    /// Swap in use as a percent of RAM (see `Sample.swapPct`). Files from before 1.0 stored used/total here.
    public let swapPct: Double
    public let swapUsed: UInt64
    public let diskFreePct: Double

    public init(at: Date, load1: Double, memPct: Double, swapPct: Double, swapUsed: UInt64, diskFreePct: Double) {
        self.at = at; self.load1 = load1; self.memPct = memPct; self.swapPct = swapPct; self.swapUsed = swapUsed; self.diskFreePct = diskFreePct
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try c.decode(Date.self, forKey: .at)
        load1 = try c.decodeIfPresent(Double.self, forKey: .load1) ?? 0
        memPct = try c.decodeIfPresent(Double.self, forKey: .memPct) ?? 0
        swapPct = try c.decodeIfPresent(Double.self, forKey: .swapPct) ?? 0
        swapUsed = try c.decodeIfPresent(UInt64.self, forKey: .swapUsed) ?? 0
        diskFreePct = try c.decodeIfPresent(Double.self, forKey: .diskFreePct) ?? 0
    }
}

public struct Recurrence: Identifiable, Sendable, Equatable {
    /// The issue family (key without any per-process suffix).
    public let key: String
    public let title: String
    public let kind: IssueKind
    public let count: Int
    public let last: Date
    public var id: String { key }
}

public struct Trend: Sendable, Equatable {
    public let avgLoad: Double
    public let peakSwap: UInt64
    public let minDiskFree: Double
}

/// What `reconcile` found this round.
public struct Reconciliation: Sendable {
    /// Issues that were not open before.
    public let opened: [Issue]
    /// Issues that were open and just became more severe.
    public let escalated: [Issue]
}

/// Incidents and periodic snapshots, persisted as one JSON file.
///
/// Small enough that rewriting the file on save is fine. A file that fails to decode is
/// moved aside rather than overwritten, so nothing is lost silently.
/// Not thread-safe: use from one queue.
public final class History {
    struct File: Codable {
        static let currentVersion = 2
        var version = currentVersion
        var incidents: [Incident] = []
        var snapshots: [Snapshot] = []
        var notified: [String: Date] = [:]

        init() {}

        /// Every field decodes leniently so an older file, or one from a newer build that added a
        /// field, never reads as corrupt.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
            incidents = try c.decodeIfPresent([Incident].self, forKey: .incidents) ?? []
            snapshots = try c.decodeIfPresent([Snapshot].self, forKey: .snapshots) ?? []
            notified = try c.decodeIfPresent([String: Date].self, forKey: .notified) ?? [:]
        }
    }

    /// A key that closed this recently and reappears is the same problem flapping, not a new one.
    public static let reopenWindow: TimeInterval = 300
    /// Hard cap so a flapping key can never grow the file without bound.
    public static let maxIncidents = 5000

    private var file = File()
    private let url: URL?
    private let retention: TimeInterval
    private var dirty = false
    private let log = Logger(subsystem: "com.dhruv.vitals", category: "history")

    /// - Parameters:
    ///   - url: where to persist; `nil` keeps everything in memory (tests).
    ///   - retentionDays: incidents and snapshots older than this are dropped on save.
    public init(url: URL?, retentionDays: Double = 30) {
        self.url = url
        self.retention = retentionDays * 86400
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            file = try JSONDecoder().decode(File.self, from: data)
            migrate()
        } catch {
            let aside = url.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))").appendingPathExtension("json")
            try? FileManager.default.moveItem(at: url, to: aside)
            log.error("state.json failed to decode (\(error.localizedDescription)); moved to \(aside.lastPathComponent)")
        }
    }

    /// Bring an older file up to `File.currentVersion`. Each step is idempotent.
    private func migrate() {
        if file.version < 1 {
            // v0 keyed orphan incidents by a lowercase family and pid list; unify with today's keys.
            for i in file.incidents.indices where file.incidents[i].key.hasPrefix("orphan:claude") {
                file.incidents[i].key = "orphan:Claude Code"
            }
            file.notified = [:]
            file.version = 1
            dirty = true
        }
        if file.version < 2 {
            // v1 stored swap as used/total, which is meaningless (see Sample.swapPct). Drop it rather than mislead.
            file.snapshots = file.snapshots.map { Snapshot(at: $0.at, load1: $0.load1, memPct: $0.memPct, swapPct: 0, swapUsed: 0, diskFreePct: $0.diskFreePct) }
            file.version = 2
            dirty = true
        }
        if dirty { log.notice("migrated history to v\(File.currentVersion)") }
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vitals", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    public var incidents: [Incident] { file.incidents }
    public var snapshots: [Snapshot] { file.snapshots }
    public var openIncidents: [Incident] { file.incidents.filter { $0.closedAt == nil } }
    public var lastClosedIncident: Incident? { file.incidents.filter { $0.closedAt != nil }.max { $0.openedAt < $1.openedAt } }

    /// Reconcile the currently reported issues against open incidents.
    @discardableResult
    public func reconcile(_ issues: [Issue], at now: Date) -> Reconciliation {
        let current = Dictionary(issues.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var opened: [Issue] = []
        var escalated: [Issue] = []

        for i in file.incidents.indices where file.incidents[i].closedAt == nil {
            let inc = file.incidents[i]
            if let issue = current[inc.key] {
                // Still open: keep the text current, and let severity ratchet up.
                if issue.severity > inc.severity { escalated.append(issue) }
                if inc.detail != issue.detail || inc.title != issue.title || inc.severity < issue.severity {
                    file.incidents[i].detail = issue.detail
                    file.incidents[i].title = issue.title
                    file.incidents[i].severity = max(inc.severity, issue.severity)
                    dirty = true
                }
            } else {
                file.incidents[i].closedAt = now
                dirty = true
            }
        }
        let open = Set(openIncidents.map(\.key))
        for issue in issues where !open.contains(issue.key) {
            if let i = file.incidents.lastIndex(where: { $0.key == issue.key && !$0.clearedByUser && ($0.closedAt.map { now.timeIntervalSince($0) < Self.reopenWindow } ?? false) }) {
                // Flapping: continue the recent incident instead of minting a new one.
                file.incidents[i].closedAt = nil
                file.incidents[i].detail = issue.detail
                file.incidents[i].title = issue.title
                file.incidents[i].severity = max(file.incidents[i].severity, issue.severity)
            } else {
                file.incidents.append(Incident(key: issue.key, kind: issue.kind, severity: issue.severity, title: issue.title,
                                               detail: issue.detail, openedAt: now, closedAt: nil, clearedByUser: false))
                opened.append(issue)
            }
            dirty = true
        }
        capIncidents()
        return Reconciliation(opened: opened, escalated: escalated)
    }

    private func capIncidents() {
        guard file.incidents.count > Self.maxIncidents else { return }
        // Drop the oldest closed ones first; never drop an open incident.
        var closed = file.incidents.enumerated().filter { $0.element.closedAt != nil }.map(\.offset)
        let excess = file.incidents.count - Self.maxIncidents
        closed = Array(closed.prefix(excess))
        let drop = Set(closed)
        file.incidents = file.incidents.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
        dirty = true
    }

    public func markCleared(keys: [String], at now: Date) {
        for i in file.incidents.indices where file.incidents[i].closedAt == nil && keys.contains(file.incidents[i].key) {
            file.incidents[i].closedAt = now
            file.incidents[i].clearedByUser = true
            dirty = true
        }
        save(now: now)
    }

    /// Record a snapshot if at least `minInterval` has passed since the last one.
    public func snapshot(_ s: Sample, minInterval: TimeInterval = 300) {
        if let last = file.snapshots.last, s.at.timeIntervalSince(last.at) < minInterval { return }
        file.snapshots.append(Snapshot(at: s.at, load1: s.load1, memPct: s.memPct, swapPct: s.swapPct, swapUsed: s.swapUsed, diskFreePct: s.diskFreePct))
        dirty = true
    }

    /// Rate-limits notifications per issue key. An escalation bypasses the cooldown: a warning
    /// that turned bad is news even if the warning was announced a minute ago.
    public func shouldNotify(key: String, at now: Date, escalation: Bool = false, cooldown: TimeInterval = 1800) -> Bool {
        if !escalation, let last = file.notified[key], now.timeIntervalSince(last) < cooldown { return false }
        file.notified[key] = now
        dirty = true
        return true
    }

    /// Issue families seen at least `minCount` times within `window`. A pattern, not a one-off.
    /// Grouped by family, so a program that gets stuck under a new pid every day still counts.
    public func recurrences(window: TimeInterval = 30 * 86400, minCount: Int = 2, now: Date = Date()) -> [Recurrence] {
        let cutoff = now.addingTimeInterval(-window)
        let tracked: Set<IssueKind> = [.runaway, .busy, .appHog, .orphan, .thermal, .memory]
        let recent = file.incidents.filter { $0.openedAt >= cutoff && tracked.contains($0.kind) }
        return Dictionary(grouping: recent, by: { Issue.family(of: $0.key) }).compactMap { family, list -> Recurrence? in
            guard list.count >= minCount, let last = list.max(by: { $0.openedAt < $1.openedAt }) else { return nil }
            return Recurrence(key: family, title: last.title, kind: last.kind, count: list.count, last: last.openedAt)
        }.sorted { $0.count == $1.count ? $0.last > $1.last : $0.count > $1.count }
    }

    public func trend(hours: Double, now: Date = Date()) -> Trend? {
        let cutoff = now.addingTimeInterval(-hours * 3600)
        let w = file.snapshots.filter { $0.at >= cutoff }
        guard !w.isEmpty else { return nil }
        return Trend(avgLoad: w.map(\.load1).reduce(0, +) / Double(w.count),
                     peakSwap: w.map(\.swapUsed).max() ?? 0,
                     minDiskFree: w.map(\.diskFreePct).min() ?? 0)
    }

    /// Trim to the retention window and write if anything changed.
    public func save(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-retention)
        let before = (file.incidents.count, file.snapshots.count, file.notified.count)
        file.incidents.removeAll { ($0.closedAt ?? now) < cutoff }
        file.snapshots.removeAll { $0.at < cutoff }
        file.notified = file.notified.filter { $0.value >= cutoff }
        if before != (file.incidents.count, file.snapshots.count, file.notified.count) { dirty = true }
        guard dirty, let url else { return }
        do {
            let data = try JSONEncoder().encode(file)
            try data.write(to: url, options: .atomic)
            dirty = false
        } catch {
            log.error("save failed: \(error.localizedDescription)")
        }
    }
}
