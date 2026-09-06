import Foundation

/// One process as observed in a single sample.
public struct Proc: Identifiable, Hashable, Sendable {
    public let pid: pid_t
    public let ppid: pid_t
    public let path: String
    /// Full command line. Held in memory for rule matching only; never persisted or logged.
    public let args: String
    public let startedAt: Date
    /// Percent of one core over the last sampling interval. For a process seen for the
    /// first time this equals `cpuLifetime`.
    public let cpuNow: Double
    /// Percent of one core averaged since the process started.
    public let cpuLifetime: Double
    public let rssBytes: UInt64

    public init(pid: pid_t, ppid: pid_t, path: String, args: String, startedAt: Date,
                cpuNow: Double, cpuLifetime: Double, rssBytes: UInt64) {
        self.pid = pid; self.ppid = ppid; self.path = path; self.args = args
        self.startedAt = startedAt; self.cpuNow = cpuNow; self.cpuLifetime = cpuLifetime; self.rssBytes = rssBytes
    }

    public var id: pid_t { pid }
    public var name: String { (path as NSString).lastPathComponent }
    public var age: TimeInterval { Date().timeIntervalSince(startedAt) }

    /// The outermost `.app` bundle name, e.g. "Cursor" for a Cursor helper. `nil` for bare executables.
    public var app: String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return (String(path[..<r.lowerBound]) as NSString).lastPathComponent
    }

    public var displayName: String {
        if let app, app != name { return "\(app) · \(name)" }
        return name
    }
}

/// Kernel memory-pressure level, as Activity Monitor reports it.
public enum MemoryPressure: Int, Sendable {
    case normal = 1, warning = 2, critical = 4
}

public struct Battery: Sendable, Equatable {
    public let percent: Int
    public let charging: Bool
    public let onBattery: Bool
    public init(percent: Int, charging: Bool, onBattery: Bool) {
        self.percent = percent; self.charging = charging; self.onBattery = onBattery
    }
}

public enum Thermal: Int, Sendable, Comparable {
    case nominal = 0, fair, serious, critical
    public static func < (a: Thermal, b: Thermal) -> Bool { a.rawValue < b.rawValue }
}

/// A point-in-time reading of the whole machine.
public struct Sample: Sendable {
    public let at: Date
    public let cores: Int
    public let load1: Double
    public let load5: Double
    public let memTotal: UInt64
    public let memUsed: UInt64
    public let memoryPressure: MemoryPressure
    public let swapTotal: UInt64
    public let swapUsed: UInt64
    public let diskTotal: Int64
    public let diskFree: Int64
    /// Wall-clock seconds since boot (counts time asleep).
    public let uptime: TimeInterval
    public let thermal: Thermal
    public let lowPowerMode: Bool
    public let battery: Battery?
    public let procs: [Proc]

    public init(at: Date, cores: Int, load1: Double, load5: Double,
                memTotal: UInt64, memUsed: UInt64, memoryPressure: MemoryPressure,
                swapTotal: UInt64, swapUsed: UInt64, diskTotal: Int64, diskFree: Int64,
                uptime: TimeInterval, thermal: Thermal, lowPowerMode: Bool, battery: Battery?, procs: [Proc]) {
        self.at = at; self.cores = cores; self.load1 = load1; self.load5 = load5
        self.memTotal = memTotal; self.memUsed = memUsed; self.memoryPressure = memoryPressure
        self.swapTotal = swapTotal; self.swapUsed = swapUsed; self.diskTotal = diskTotal; self.diskFree = diskFree
        self.uptime = uptime; self.thermal = thermal; self.lowPowerMode = lowPowerMode; self.battery = battery; self.procs = procs
    }

    public var memPct: Double { memTotal == 0 ? 0 : Double(memUsed) / Double(memTotal) * 100 }
    /// Swap in use as a percent of physical RAM. Can exceed 100.
    ///
    /// Not used/total: macOS grows swap files on demand, so that ratio sits near 100% whenever
    /// any swap exists and says nothing about memory health. Relative to RAM it means something:
    /// 25% is noticeable, 50% is a machine that is paging constantly.
    public var swapPct: Double { memTotal == 0 ? 0 : Double(swapUsed) / Double(memTotal) * 100 }
    /// Free space as a percent of the volume. 0 when the volume could not be read; callers skip the disk rule then.
    public var diskFreePct: Double { diskTotal == 0 ? 0 : Double(diskFree) / Double(diskTotal) * 100 }
    public var diskKnown: Bool { diskTotal > 0 }
    public var uptimeDays: Double { uptime / 86400 }
}
