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
    /// Ask the app to quit normally so it can save state. Never escalates on its own.
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
    /// Short and human: "Cursor · Cursor Helper (Renderer) is stuck".
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

    /// The key with any per-process suffix removed, so recurrences of the same program under
    /// different pids count together: "runaway:Cursor Helper#123" and "#456" share "runaway:Cursor Helper".
    public var family: String { Issue.family(of: key) }
    public static func family(of key: String) -> String {
        if let hash = key.lastIndex(of: "#") { return String(key[..<hash]) }
        return key
    }
}

/// Every threshold in one place. Overridable with `defaults write com.dhruv.vitals threshold.<name> <value>`.
public struct Thresholds: Sendable {
    public var hotCPU = 85.0                       // % of one core
    public var hotFor: TimeInterval = 180
    public var lifetimeHotCPU = 75.0               // a process that has averaged this since launch...
    public var lifetimeMinAge: TimeInterval = 1800 // ...for at least this long is flagged immediately
    public var appHogCPUShareWarn = 35.0           // % of the whole machine
    public var appHogCPUShareBad = 60.0
    public var appHogFor: TimeInterval = 120
    public var appHogMemShare = 30.0               // % of physical RAM
    public var swapWarn = 25.0, swapBad = 50.0     // swap in use as % of physical RAM
    public var diskWarnFreePct = 15.0, diskBadFreePct = 8.0
    public var uptimeWarnDays = 14.0, uptimeBadDays = 30.0
    public var bootGrace: TimeInterval = 600       // system daemons are expected to be busy this long after boot
    /// Consecutive samples below the threshold before a "hot" or "hog" clock resets. Stops verdicts flapping.
    public var coolSamples = 3

    public init() {}

    public static func load(from defaults: UserDefaults) -> Thresholds {
        var t = Thresholds()
        func d(_ key: String, _ v: inout Double) { if defaults.object(forKey: "threshold.\(key)") != nil { v = defaults.double(forKey: "threshold.\(key)") } }
        d("hotCPU", &t.hotCPU); d("hotFor", &t.hotFor)
        d("lifetimeHotCPU", &t.lifetimeHotCPU); d("lifetimeMinAge", &t.lifetimeMinAge)
        d("appHogCPUShareWarn", &t.appHogCPUShareWarn); d("appHogCPUShareBad", &t.appHogCPUShareBad)
        d("appHogFor", &t.appHogFor); d("appHogMemShare", &t.appHogMemShare)
        d("swapWarn", &t.swapWarn); d("swapBad", &t.swapBad)
        d("diskWarnFreePct", &t.diskWarnFreePct); d("diskBadFreePct", &t.diskBadFreePct)
        d("uptimeWarnDays", &t.uptimeWarnDays); d("uptimeBadDays", &t.uptimeBadDays)
        d("bootGrace", &t.bootGrace)
        if defaults.object(forKey: "threshold.coolSamples") != nil { t.coolSamples = max(1, defaults.integer(forKey: "threshold.coolSamples")) }
        return t
    }
}

/// Turns a `Sample` into `Issue`s. Holds only the state needed for "how long has this been true".
/// Not thread-safe: drive it from the same queue as the `Sampler`.
public final class Rules {
    public var thresholds: Thresholds

    /// A clock that starts when a condition first holds and only resets after `coolSamples`
    /// consecutive samples where it clearly does not. Sampling rate can change (the panel
    /// speeds it up), so durations are measured in time, not samples.
    private struct Clock { var since: Date; var cool = 0 }
    private var hot: [pid_t: Clock] = [:]
    private var hog: [String: Clock] = [:]

    public init(thresholds: Thresholds = Thresholds()) { self.thresholds = thresholds }

    /// Forget durations. Call after wake from sleep so time asleep does not count as "stuck".
    public func resetTimers() { hot.removeAll(); hog.removeAll() }

    /// Programs that legitimately pin cores for minutes. They get a softer verdict and no kill button.
    public static let knownBusy: Set<String> = [
        "clang", "clang++", "swift", "swiftc", "swift-frontend", "swift-build", "xcodebuild", "ld", "lld", "rustc", "cargo", "go", "gradle", "javac",
        "ffmpeg", "handbrake", "handbrakecli", "compressor", "aftermath", "photoanalysisd", "mediaanalysisd",
        "mdworker", "mdworker_shared", "mds_stores", "mds", "backupd", "imdpersistenceagent", "spotlightknowledged", "duetexpertd",
        "python", "python3", "node", "java", "docker", "qemu-system-aarch64", "com.apple.virtualization.virtualmachine",
    ]

    public static func isKnownBusy(_ name: String) -> Bool { knownBusy.contains(name.lowercased()) }

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
            out.append(Issue(kind: .swap, severity: .bad, title: "Swap is heavy", detail: "\(Format.bytes(s.swapUsed)) swapped out, \(Int(s.swapPct))% of your RAM. Paging to disk constantly", key: "swap"))
        } else if s.swapPct >= t.swapWarn {
            out.append(Issue(kind: .swap, severity: .warn, title: "Swap is growing", detail: "\(Format.bytes(s.swapUsed)) swapped out, \(Int(s.swapPct))% of your RAM", key: "swap"))
        }

        if s.diskKnown {
            if s.diskFreePct < t.diskBadFreePct {
                out.append(Issue(kind: .disk, severity: .bad, title: "Disk nearly full", detail: "\(Format.bytes(UInt64(s.diskFree))) free (\(Int(s.diskFreePct))%)", key: "disk"))
            } else if s.diskFreePct < t.diskWarnFreePct {
                out.append(Issue(kind: .disk, severity: .warn, title: "Disk is low", detail: "\(Format.bytes(UInt64(s.diskFree))) free (\(Int(s.diskFreePct))%)", key: "disk"))
            }
        }

        if s.uptimeDays >= t.uptimeBadDays {
            out.append(Issue(kind: .uptime, severity: .bad, title: "No restart in \(Int(s.uptimeDays)) days", detail: "Leaked processes and swap only reset on reboot", key: "uptime"))
        } else if s.uptimeDays >= t.uptimeWarnDays {
            out.append(Issue(kind: .uptime, severity: .warn, title: "No restart in \(Int(s.uptimeDays)) days", detail: "Worth a reboot soon", key: "uptime"))
        }

        switch s.thermal {
        case .critical: out.append(Issue(kind: .thermal, severity: .bad, title: "Thermal: critical", detail: "macOS is throttling hard" + culpritSuffix(s), key: "thermal"))
        case .serious:  out.append(Issue(kind: .thermal, severity: .bad, title: "Thermal: hot", detail: "Thermal pressure is high" + culpritSuffix(s), key: "thermal"))
        case .fair:     out.append(Issue(kind: .thermal, severity: .warn, title: "Getting warm", detail: "Thermal pressure is rising" + culpritSuffix(s), key: "thermal"))
        case .nominal: break
        }

        return out.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.key < $1.key
        }
    }

    private func culpritSuffix(_ s: Sample) -> String {
        guard let top = AppUsage.top(s.procs, cores: s.cores, limit: 1).first, top.cpu / Double(s.cores) >= 15 else { return "" }
        return ", mostly \(top.name) at \(Int(top.cpu / Double(s.cores)))% of CPU"
    }

    /// Advance a clock: start it when `on`, reset it after `coolSamples` samples that are clearly off.
    private func advance(_ clock: Clock?, on: Bool, clearlyOff: Bool, now: Date) -> Clock? {
        guard var c = clock else { return on ? Clock(since: now) : nil }
        if on { c.cool = 0; return c }
        if clearlyOff { c.cool += 1; return c.cool >= thresholds.coolSamples ? nil : c }
        return c
    }

    // MARK: - Individual processes

    private func runaways(_ s: Sample) -> [Issue] {
        let t = thresholds
        let now = s.at
        var live = Set<pid_t>()
        var out: [Issue] = []
        for p in s.procs {
            live.insert(p.pid)
            hot[p.pid] = advance(hot[p.pid], on: p.cpuNow >= t.hotCPU, clearlyOff: p.cpuNow < t.hotCPU - 15, now: now)
            let age = now.timeIntervalSince(p.startedAt)   // relative to the sample, not the wall clock
            let hotDuration = hot[p.pid].map { now.timeIntervalSince($0.since) } ?? 0
            let sustained = hotDuration >= t.hotFor && p.cpuNow >= t.hotCPU - 15
            let chronic = p.cpuLifetime >= t.lifetimeHotCPU && age >= t.lifetimeMinAge && p.cpuNow >= 70
            guard sustained || chronic else { continue }
            let busy = Self.isKnownBusy(p.name)
            if busy && s.uptime < t.bootGrace { continue }   // Spotlight, Photos and friends rebuild after boot
            let since = chronic ? age : hotDuration
            out.append(Issue(
                kind: busy ? .busy : .runaway,
                severity: busy ? .warn : .bad,
                title: busy ? "\(p.displayName) is working hard" : "\(p.displayName) is stuck",
                detail: "\(Int(p.cpuNow))% CPU for \(Format.duration(since))" + (busy ? ". Normal for a build or export" : ""),
                remedy: .kill([p.pid]),
                key: "\(busy ? "busy" : "runaway"):\(p.name)#\(p.pid)"
            ))
        }
        hot = hot.filter { live.contains($0.key) }
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
            hog[a.name] = advance(hog[a.name], on: cpuShare >= t.appHogCPUShareWarn, clearlyOff: cpuShare < t.appHogCPUShareWarn - 10, now: now)
            let hogFor = hog[a.name].map { now.timeIntervalSince($0.since) } ?? 0
            let cpuHog = hogFor >= t.appHogFor && cpuShare >= t.appHogCPUShareWarn - 10
            // Holding RAM is only a problem when the machine is short of it. Then the fix is closing
            // tabs or windows, not quitting the app you are working in, so no button.
            let memHog = memShare >= t.appHogMemShare && s.memoryPressure != .normal
            guard cpuHog || memHog else { continue }
            if memHog && !cpuHog {
                out.append(Issue(kind: .appHog, severity: .warn, title: "\(a.name) is holding \(Format.bytes(a.rss))",
                                 detail: "\(Int(memShare))% of your RAM across \(a.procs) process\(a.procs == 1 ? "" : "es"). Close tabs or windows you are not using.",
                                 remedy: .none, key: "appHog:\(a.name)"))
                continue
            }

            // Mostly compilers or encoders: it is busy, not broken. Say so, and do not offer to kill it.
            let mostlyBusy = a.cpu > 0 && a.busyCPU / a.cpu >= 0.5
            var parts: [String] = []
            if cpuHog { parts.append("\(Int(cpuShare))% of CPU for \(Format.duration(hogFor))") }
            if memHog { parts.append("\(Format.bytes(a.rss)) of RAM") }
            let across = " across \(a.procs) process\(a.procs == 1 ? "" : "es")"
            if mostlyBusy && cpuHog && !memHog {
                out.append(Issue(kind: .busy, severity: .warn, title: "\(a.name) is working hard",
                                 detail: parts.joined(separator: ", ") + across + ". Normal for a build or export",
                                 remedy: .none, key: "busy:\(a.name)"))
                continue
            }
            let sev: Severity = (cpuHog && cpuShare >= t.appHogCPUShareBad) ? .bad : .warn
            let remedy: Remedy = a.isBundle ? .quitApp(name: a.name, pids: a.pids) : .kill(a.pids)
            out.append(Issue(kind: .appHog, severity: sev, title: "\(a.name) is taking over",
                             detail: parts.joined(separator: ", ") + across, remedy: remedy, key: "appHog:\(a.name)"))
        }
        hog = hog.filter { live.contains($0.key) }
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
        var seenFamilies = Set<String>()
        for rule in orphanRules where seenFamilies.insert(rule.family).inserted {
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
    /// The part of `cpu` that comes from programs in `Rules.knownBusy` (compilers, encoders, indexers).
    public let busyCPU: Double
    public let rss: UInt64
    public let pids: [pid_t]
    /// True when the group is a `.app` bundle that can be asked to quit normally.
    public let isBundle: Bool
    public var id: String { name }

    public static func top(_ procs: [Proc], cores: Int, limit: Int = 5) -> [AppUsage] {
        struct G { var n = 0; var cpu = 0.0; var busy = 0.0; var rss: UInt64 = 0; var pids: [pid_t] = []; var bundle = false }
        var groups: [String: G] = [:]
        for p in procs {
            let (k, bundle) = groupName(p)
            var g = groups[k] ?? G(bundle: bundle)
            g.n += 1; g.cpu += p.cpuNow; g.rss += p.rssBytes; g.pids.append(p.pid)
            if Rules.isKnownBusy(p.name) { g.busy += p.cpuNow }
            groups[k] = g
        }
        var usages: [AppUsage] = []
        usages.reserveCapacity(groups.count)
        for (name, g) in groups where g.cpu >= 1 || g.rss >= 500 * 1_048_576 {
            usages.append(AppUsage(name: name, procs: g.n, cpu: g.cpu, busyCPU: g.busy, rss: g.rss, pids: g.pids.sorted(), isBundle: g.bundle))
        }
        // Busiest first; ties broken by memory, then name so rows do not reorder between samples.
        usages.sort { a, b in
            if a.cpu != b.cpu { return a.cpu > b.cpu }
            if a.rss != b.rss { return a.rss > b.rss }
            return a.name < b.name
        }
        return Array(usages.prefix(limit))
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
