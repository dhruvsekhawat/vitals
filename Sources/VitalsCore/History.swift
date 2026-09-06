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
    public let swapPct: Double
    public let diskFreePct: Double
}

public struct Recurrence: Identifiable, Sendable, Equatable {
    public let key: String
    public let title: String
    public let kind: IssueKind
    public let count: Int
    public let last: Date
    public var id: String { key }
}

public struct Trend: Sendable, Equatable {
    public let avgLoad: Double
    public let peakSwap: Double
    public let minDiskFree: Double
}

/// Incidents and periodic snapshots, persisted as one JSON file.
///
/// Small enough that rewriting the file on save is fine. A file that fails to decode is
/// moved aside rather than overwritten, so nothing is lost silently.
/// Not thread-safe: use from one queue.
public final class History {
    /// On-disk format. Every field decodes leniently so an older file (or one written by a
    /// newer build that added a field) never reads as corrupt. Bump `currentVersion` only for
    /// changes that need a migration.
    struct File: Codable {
        static let currentVersion = 1
        var version = currentVersion
        var incidents: [Incident] = []
        var snapshots: [Snapshot] = []
        var notified: [String: Date] = [:]

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
            incidents = try c.decodeIfPresent([Incident].self, forKey: .incidents) ?? []
            snapshots = try c.decodeIfPresent([Snapshot].self, forKey: .snapshots) ?? []
            notified = try c.decodeIfPresent([String: Date].self, forKey: .notified) ?? [:]
        }
    }

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
            let aside = url.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            log.error("state.json failed to decode (\(error.localizedDescription)); moved to \(aside.lastPathComponent)")
        }
    }

    /// Bring an older file up to `File.currentVersion`. Each step is idempotent.
    private func migrate() {
        if file.version < 1 {
            // Version 0 keyed orphan incidents by a lowercase family name and pid list; unify with today's keys.
            for i in file.incidents.indices {
                let k = file.incidents[i].key
                if k.hasPrefix("orphan:claude") { file.incidents[i].key = "orphan:Claude Code" }
                else if k.hasPrefix("runaway:") && k.contains(":") == true && !k.contains("#") { /* pid list dropped; leave as is */ }
            }
            file.notified = [:]   // keys changed shape; better one repeat notification than a missed one
            file.version = 1
            dirty = true
            log.notice("migrated history v0 to v1")
        }
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
    /// - Returns: issues that are new since the last call (candidates for a notification).
    @discardableResult
    public func reconcile(_ issues: [Issue], at now: Date) -> [Issue] {
        let current = Dictionary(uniqueKeysWithValues: issues.map { ($0.key, $0) })
        var fresh: [Issue] = []

        for i in file.incidents.indices where file.incidents[i].closedAt == nil {
            let key = file.incidents[i].key
            if let issue = current[key] {
                // Still open: keep the text current, and let severity ratchet up.
                let inc = file.incidents[i]
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
            file.incidents.append(Incident(key: issue.key, kind: issue.kind, severity: issue.severity, title: issue.title,
                                           detail: issue.detail, openedAt: now, closedAt: nil, clearedByUser: false))
            fresh.append(issue)
            dirty = true
        }
        return fresh
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
        file.snapshots.append(Snapshot(at: s.at, load1: s.load1, memPct: s.memPct, swapPct: s.swapPct, diskFreePct: s.diskFreePct))
        dirty = true
    }

    /// Rate-limits notifications per issue key.
    public func shouldNotify(key: String, at now: Date, cooldown: TimeInterval = 1800) -> Bool {
        if let last = file.notified[key], now.timeIntervalSince(last) < cooldown { return false }
        file.notified[key] = now
        dirty = true
        return true
    }

    /// Issue keys seen at least `minCount` times within `window`. A pattern, not a one-off.
    public func recurrences(window: TimeInterval = 30 * 86400, minCount: Int = 2, now: Date = Date()) -> [Recurrence] {
        let cutoff = now.addingTimeInterval(-window)
        let tracked: Set<IssueKind> = [.runaway, .busy, .appHog, .orphan, .thermal, .memory]
        let recent = file.incidents.filter { $0.openedAt >= cutoff && tracked.contains($0.kind) }
        return Dictionary(grouping: recent, by: \.key).compactMap { key, list -> Recurrence? in
            guard list.count >= minCount, let last = list.max(by: { $0.openedAt < $1.openedAt }) else { return nil }
            return Recurrence(key: key, title: last.title, kind: last.kind, count: list.count, last: last.openedAt)
        }.sorted { $0.count == $1.count ? $0.last > $1.last : $0.count > $1.count }
    }

    public func trend(hours: Double, now: Date = Date()) -> Trend? {
        let cutoff = now.addingTimeInterval(-hours * 3600)
        let w = file.snapshots.filter { $0.at >= cutoff }
        guard !w.isEmpty else { return nil }
        return Trend(avgLoad: w.map(\.load1).reduce(0, +) / Double(w.count),
                     peakSwap: w.map(\.swapPct).max() ?? 0,
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
