import Foundation

public enum Severity: Int, Codable, Comparable, Sendable {
    case ok = 0, warn = 1, bad = 2
    public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
}

public enum IssueKind: String, Codable, Sendable {
    case runaway, busy, appHog, orphan, memory, swap, disk, uptime, thermal
}

/// What the user can do about an issue from the panel or a notification.
public enum Remedy: Hashable, Sendable {
    case none
    /// Terminate these processes (SIGTERM, then SIGKILL).
    case kill([pid_t])
    /// Ask the app to quit normally so it can save state; falls back to `kill` if it will not.
    case quitApp(name: String, pids: [pid_t])

    public var pids: [pid_t] {
        switch self {
        case .none: return []
        case .kill(let p), .quitApp(_, let p): return p
        }
    }
    public var isActionable: Bool { self != .none }
    public var verb: String {
        switch self {
        case .none: return ""
        case .kill: return "Kill"
        case .quitApp: return "Quit"
        }
    }
}

public struct Issue: Identifiable, Hashable, Sendable {
    public let kind: IssueKind
    public let severity: Severity
    /// Short and human: "Cursor · Cursor Helper (Renderer)".
    public let title: String
    /// "98% CPU for 19 days".
    public let detail: String
    public let remedy: Remedy
    /// Stable identity across samples. Same key means the same ongoing problem.
    public let key: String

    public init(kind: IssueKind, severity: Severity, title: String, detail: String, remedy: Remedy = .none, key: String) {
        self.kind = kind; self.severity = severity; self.title = title; self.detail = detail; self.remedy = remedy; self.key = key
    }
    public var id: String { key }
}

/// Every threshold in one place. Overridable with `defaults write com.dhruv.vitals <key> <value>`.
public struct Thresholds: Sendable {
    public var hotCPU = 85.0                       // % of one core
    public var hotFor: TimeInterval = 180
    public var lifetimeHotCPU = 75.0               // a process that has averaged this since launch...
    public var lifetimeMinAge: TimeInterval = 1800 // ...for at least this long is flagged immediately
    public var appHogCPUShareWarn = 35.0           // % of the whole machine
    public var appHogCPUShareBad = 60.0
    public var appHogFor: TimeInterval = 120
    public var appHogMemShare = 30.0               // % of physical RAM
    public var swapWarn = 75.0, swapBad = 90.0
    public var diskWarnFreePct = 15.0, diskBadFreePct = 8.0
    public var uptimeWarnDays = 14.0, uptimeBadDays = 30.0
    public var bootGrace: TimeInterval = 600       // ignore load right after boot

    public init() {}

    public static func load(from defaults: UserDefaults) -> Thresholds {
        var t = Thresholds()
        func d(_ key: String, _ v: inout Double) { if defaults.object(forKey: key) != nil { v = defaults.double(forKey: key) } }
        d("threshold.hotCPU", &t.hotCPU); d("threshold.hotFor", &t.hotFor)
        d("threshold.appHogCPUShareWarn", &t.appHogCPUShareWarn); d("threshold.appHogCPUShareBad", &t.appHogCPUShareBad)
        d("threshold.appHogFor", &t.appHogFor); d("threshold.appHogMemShare", &t.appHogMemShare)
        d("threshold.swapWarn", &t.swapWarn); d("threshold.swapBad", &t.swapBad)
        d("threshold.diskWarnFreePct", &t.diskWarnFreePct); d("threshold.diskBadFreePct", &t.diskBadFreePct)
        d("threshold.uptimeWarnDays", &t.uptimeWarnDays); d("threshold.uptimeBadDays", &t.uptimeBadDays)
        return t
    }
}

/// Turns a `Sample` into `Issue`s. Holds only the state needed for "how long has this been true".
/// Not thread-safe: drive it from the same queue as the `Sampler`.
public final class Rules {
    public var thresholds: Thresholds
    private var hotSince: [pid_t: Date] = [:]
    private var hogSince: [String: Date] = [:]

    public init(thresholds: Thresholds = Thresholds()) { self.thresholds = thresholds }

    /// Forget durations. Call after wake from sleep so time asleep does not count as "stuck".
    public func resetTimers() { hotSince.removeAll(); hogSince.removeAll() }

    /// Processes that legitimately pin a core for minutes. They get a softer verdict.
    public static let knownBusy: [String] = [
        "clang", "swift", "swiftc", "swift-frontend", "xcodebuild", "ld", "lld", "rustc", "cargo", "go",
        "ffmpeg", "handbrake", "compressor", "aftermath", "photoanalysisd", "mediaanalysisd",
        "mdworker", "mds_stores", "mds", "backupd", "imdpersistenceagent", "spotlightknowledged",
        "python", "python3", "node", "java", "docker", "qemu", "virtualization",
    ]

    public func evaluate(_ s: Sample) -> [Issue] {
        let t = thresholds
        var out: [Issue] = []
        out += runaways(s)
        out += appHogs(s)
        out += orphans(s)

        switch s.memoryPressure {
        case .critical: out.append(Issue(kind: .memory, severity: .bad, title: "Memory pressure critical", detail: "macOS is compressing and swapping hard", key: "memory"))
        case .warning:  out.append(Issue(kind: .memory, severity: .warn, title: "Memory pressure high", detail: "\(Format.bytes(s.memUsed)) of \(Format.bytes(s.memTotal)) in use", key: "memory"))
        case .normal: break
        }

        if s.swapPct >= t.swapBad {
            out.append(Issue(kind: .swap, severity: .bad, title: "Swap is full", detail: "\(Int(s.swapPct))% of \(Format.bytes(s.swapTotal)), paging to disk constantly", key: "swap"))
        } else if s.swapPct >= t.swapWarn {
            out.append(Issue(kind: .swap, severity: .warn, title: "Swap is high", detail: "\(Int(s.swapPct))% of \(Format.bytes(s.swapTotal))", key: "swap"))
        }

        if s.diskFreePct < t.diskBadFreePct {
            out.append(Issue(kind: .disk, severity: .bad, title: "Disk nearly full", detail: "\(Format.bytes(UInt64(s.diskFree))) free (\(Int(s.diskFreePct))%)", key: "disk"))
        } else if s.diskFreePct < t.diskWarnFreePct {
            out.append(Issue(kind: .disk, severity: .warn, title: "Disk is low", detail: "\(Format.bytes(UInt64(s.diskFree))) free (\(Int(s.diskFreePct))%)", key: "disk"))
        }

        if s.uptimeDays >= t.uptimeBadDays {
            out.append(Issue(kind: .uptime, severity: .bad, title: "No restart in \(Int(s.uptimeDays)) days", detail: "Leaked processes and swap only reset on reboot", key: "uptime"))
        } else if s.uptimeDays >= t.uptimeWarnDays {
            out.append(Issue(kind: .uptime, severity: .warn, title: "No restart in \(Int(s.uptimeDays)) days", detail: "Worth a reboot soon", key: "uptime"))
        }

        switch s.thermal {
        case .critical: out.append(Issue(kind: .thermal, severity: .bad, title: "Thermal: critical", detail: "macOS is throttling hard" + culpritSuffix(s), key: "thermal"))
        case .serious:  out.append(Issue(kind: .thermal, severity: .bad, title: "Thermal: hot", detail: "Fans at max" + culpritSuffix(s), key: "thermal"))
        case .fair:     out.append(Issue(kind: .thermal, severity: .warn, title: "Getting warm", detail: "Fans spinning up" + culpritSuffix(s), key: "thermal"))
        case .nominal: break
        }

        return out.sorted { $0.severity == $1.severity ? $0.kind.rawValue < $1.kind.rawValue : $0.severity > $1.severity }
    }

    private func culpritSuffix(_ s: Sample) -> String {
        guard let top = AppUsage.top(s.procs, cores: s.cores, limit: 1).first, top.cpu / Double(s.cores) >= 15 else { return "" }
        return ", mostly \(top.name) at \(Int(top.cpu / Double(s.cores)))% of CPU"
    }

    // MARK: - Individual processes

    private func runaways(_ s: Sample) -> [Issue] {
        let t = thresholds
        let now = s.at
        var live = Set<pid_t>()
        var out: [Issue] = []
        for p in s.procs {
            live.insert(p.pid)
            if p.cpuNow >= t.hotCPU {
                if hotSince[p.pid] == nil { hotSince[p.pid] = now }
            } else {
                hotSince[p.pid] = nil
            }
            let age = now.timeIntervalSince(p.startedAt)   // relative to the sample, not the wall clock
            let hotDuration = hotSince[p.pid].map { now.timeIntervalSince($0) } ?? 0
            let sustained = hotDuration >= t.hotFor
            let chronic = p.cpuLifetime >= t.lifetimeHotCPU && age >= t.lifetimeMinAge && p.cpuNow >= 70
            guard sustained || chronic else { continue }
            let since = chronic ? age : hotDuration
            let busy = Self.knownBusy.contains(p.name.lowercased())
            out.append(Issue(
                kind: busy ? .busy : .runaway,
                severity: busy ? .warn : .bad,
                title: busy ? "\(p.displayName) is working hard" : "\(p.displayName) is stuck",
                detail: "\(Int(p.cpuNow))% CPU for \(Format.duration(since))" + (busy ? ". Normal for a build or export" : ""),
                remedy: .kill([p.pid]),
                key: "\(busy ? "busy" : "runaway"):\(p.name)#\(p.pid)"
            ))
        }
        hotSince = hotSince.filter { live.contains($0.key) }
        return out
    }

    // MARK: - Whole apps

    /// An app (with all its helpers) holding a large share of the machine for a sustained period.
    private func appHogs(_ s: Sample) -> [Issue] {
        let t = thresholds
        let now = s.at
        var out: [Issue] = []
        var live = Set<String>()
        for a in AppUsage.top(s.procs, cores: s.cores, limit: 10) {
            let cpuShare = a.cpu / Double(max(s.cores, 1))
            let memShare = Double(a.rss) / Double(max(s.memTotal, 1)) * 100
            live.insert(a.name)
            if cpuShare >= t.appHogCPUShareWarn {
                if hogSince[a.name] == nil { hogSince[a.name] = now }
            } else {
                hogSince[a.name] = nil
            }
            let hogFor = hogSince[a.name].map { now.timeIntervalSince($0) } ?? 0
            let cpuHog = hogFor >= t.appHogFor
            let memHog = memShare >= t.appHogMemShare
            guard cpuHog || memHog else { continue }

            var parts: [String] = []
            if cpuHog { parts.append("\(Int(cpuShare))% of CPU for \(Format.duration(hogFor))") }
            if memHog { parts.append("\(Format.bytes(a.rss)) of RAM") }
            let sev: Severity = (cpuHog && cpuShare >= t.appHogCPUShareBad) ? .bad : .warn
            let remedy: Remedy = a.isBundle ? .quitApp(name: a.name, pids: a.pids) : .kill(a.pids)
            out.append(Issue(
                kind: .appHog, severity: sev,
                title: "\(a.name) is taking over",
                detail: parts.joined(separator: ", ") + " across \(a.procs) process\(a.procs == 1 ? "" : "es")",
                remedy: remedy,
                key: "appHog:\(a.name)"
            ))
        }
        hogSince = hogSince.filter { live.contains($0.key) }
        return out
    }

    // MARK: - Orphans

    /// Helpers whose owning session has exited: reparented to launchd (ppid 1) yet still running.
    /// Each rule names a family of helpers and how to recognise them.
    public struct OrphanRule: Sendable {
        public let family: String
        public let matches: @Sendable (Proc) -> Bool
        public init(family: String, matches: @escaping @Sendable (Proc) -> Bool) { self.family = family; self.matches = matches }
    }

    public var orphanRules: [OrphanRule] = [
        OrphanRule(family: "Claude Code") {
            $0.ppid == 1 && $0.path.localizedCaseInsensitiveContains("claude") &&
            ($0.args.contains("--bg-spare") || $0.args.contains("--bg-pty-host"))
        },
    ]

    private func orphans(_ s: Sample) -> [Issue] {
        var out: [Issue] = []
        for rule in orphanRules {
            let leaked = s.procs.filter(rule.matches)
            guard !leaked.isEmpty else { continue }
            let leakedPids = Set(leaked.map(\.pid))
            let children = s.procs.filter { leakedPids.contains($0.ppid) }
            let all = leaked + children
            let oldest = all.map { s.at.timeIntervalSince($0.startedAt) }.max() ?? 0
            out.append(Issue(
                kind: .orphan, severity: .warn,
                title: "Leaked \(rule.family) processes",
                detail: "\(all.count) left behind by closed sessions, oldest \(Format.duration(oldest))",
                remedy: .kill(all.map(\.pid)),
                key: "orphan:\(rule.family)"
            ))
        }
        return out
    }
}

/// Every process rolled up under the app it belongs to: "Cursor" = Cursor plus all its helpers.
public struct AppUsage: Identifiable, Sendable, Equatable {
    public let name: String
    public let procs: Int
    /// Percent of one core, summed across processes.
    public let cpu: Double
    public let rss: UInt64
    public let pids: [pid_t]
    /// True when the group is a `.app` bundle that can be asked to quit normally.
    public let isBundle: Bool
    public var id: String { name }

    public static func top(_ procs: [Proc], cores: Int, limit: Int = 5) -> [AppUsage] {
        var groups: [String: (n: Int, cpu: Double, rss: UInt64, pids: [pid_t], bundle: Bool)] = [:]
        for p in procs {
            let (k, bundle) = groupName(p)
            var g = groups[k] ?? (0, 0, 0, [], bundle)
            g.n += 1; g.cpu += p.cpuNow; g.rss += p.rssBytes; g.pids.append(p.pid)
            groups[k] = g
        }
        return groups.map { AppUsage(name: $0.key, procs: $0.value.n, cpu: $0.value.cpu, rss: $0.value.rss, pids: $0.value.pids, isBundle: $0.value.bundle) }
            .filter { $0.cpu >= 1 || $0.rss >= 500 * 1_048_576 }
            .sorted { ($0.cpu, $0.rss) > ($1.cpu, $1.rss) }
            .prefix(limit).map { $0 }
    }

    static func groupName(_ p: Proc) -> (String, Bool) {
        let path = p.path.lowercased()
        if path.contains("/claude-code/") || path.contains("/.local/share/claude/") || path.contains("/.local/bin/claude") || p.name == "claude" {
            return ("Claude Code", false)
        }
        if let app = p.app { return (app, true) }
        return (p.name, false)
    }
}
