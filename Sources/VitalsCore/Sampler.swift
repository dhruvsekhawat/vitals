import Foundation
import Darwin
import IOKit.ps

/// Reads the machine. Not thread-safe: call `sample()` from one serial queue.
///
/// Per-process metadata (path, command line, start time) is fetched once per pid and cached,
/// validated against the start time so a reused pid is never confused with its predecessor.
/// CPU is a delta of task CPU time between consecutive samples, so it is instantaneous rather
/// than the lifetime average `ps` shows.
public final class Sampler {
    private struct Meta { let path: String; let args: String; let started: Date }
    private var meta: [pid_t: Meta] = [:]
    private var cpuPrev: [pid_t: (time: UInt64, at: Date)] = [:]
    private let selfPid = getpid()
    private let uid = getuid()
    private let readArgs: Bool

    /// `proc_taskinfo` CPU totals are in Mach absolute-time ticks, not nanoseconds.
    /// On Apple Silicon a tick is 125/3 ns; treating ticks as ns under-reports CPU ~42×.
    static let ticksToNanos: (numer: UInt64, denom: UInt64) = {
        var tb = mach_timebase_info()
        mach_timebase_info(&tb)
        return (UInt64(max(tb.numer, 1)), UInt64(max(tb.denom, 1)))
    }()

    @inline(__always) static func nanos(fromTicks t: UInt64) -> UInt64 {
        t.multipliedReportingOverflow(by: ticksToNanos.numer).partialValue / ticksToNanos.denom
    }

    /// - Parameter readArgs: whether to read command lines (needed for the orphan rule).
    public init(readArgs: Bool = true) { self.readArgs = readArgs }

    /// Forget CPU baselines. Call after sleep so the first post-wake delta is not skewed.
    public func resetDeltas() { cpuPrev.removeAll() }

    public func sample() -> Sample {
        let now = Date()
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        let (memTotal, memUsed) = Self.memory()
        let (swapTotal, swapUsed) = Self.swap()
        let (diskTotal, diskFree) = Self.disk()

        return Sample(
            at: now,
            cores: ProcessInfo.processInfo.activeProcessorCount,
            load1: load[0], load5: load[1],
            memTotal: memTotal, memUsed: memUsed, memoryPressure: Self.memoryPressure(),
            swapTotal: swapTotal, swapUsed: swapUsed,
            diskTotal: diskTotal, diskFree: diskFree,
            uptime: Self.sinceBoot(),
            thermal: Self.thermal(),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            battery: Self.battery(),
            procs: processes(at: now)
        )
    }

    // MARK: - Machine-wide readings

    /// Wall-clock time since boot. `ProcessInfo.systemUptime` stops during sleep and would
    /// under-report "days since restart" badly on a laptop.
    static func sinceBoot() -> TimeInterval {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return ProcessInfo.processInfo.systemUptime }
        return Date().timeIntervalSince1970 - (TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1e6)
    }

    static func memory() -> (UInt64, UInt64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let total = ProcessInfo.processInfo.physicalMemory
        guard kr == KERN_SUCCESS else { return (total, 0) }
        let page = UInt64(vm_kernel_page_size)
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return (total, min(used, total))
    }

    static func memoryPressure() -> MemoryPressure {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        return MemoryPressure(rawValue: Int(level)) ?? .normal
    }

    static func swap() -> (UInt64, UInt64) {
        var xsw = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &xsw, &size, nil, 0) == 0 else { return (0, 0) }
        return (xsw.xsu_total, xsw.xsu_used)
    }

    static func disk() -> (Int64, Int64) {
        let url = URL(fileURLWithPath: "/")
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) else { return (0, 0) }
        return (Int64(v.volumeTotalCapacity ?? 0), v.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    static func thermal() -> Thermal {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }

    static func battery() -> Battery? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for src in list {
            guard let d = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let pct = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let onBattery = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
            return Battery(percent: pct, charging: charging, onBattery: onBattery)
        }
        return nil
    }

    // MARK: - Processes

    private func processes(at now: Date) -> [Proc] {
        // Size the buffer from the kernel rather than guessing. proc_listallpids returns a count.
        let count = Int(proc_listallpids(nil, 0))
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: count + 64)
        let n = max(Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))), 0)

        var out: [Proc] = []
        out.reserveCapacity(n)
        var seen = Set<pid_t>()

        for pid in pids.prefix(n) where pid > 0 && pid != selfPid {
            var bsd = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
                  bsd.pbi_uid == uid else { continue }   // only this user's processes are ours to judge or kill

            var task = proc_taskinfo()
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 else { continue }
            seen.insert(pid)

            let started = Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1e6)
            let m = metadata(for: pid, started: started)

            let cpuTime = Self.nanos(fromTicks: task.pti_total_user + task.pti_total_system)
            let age = max(now.timeIntervalSince(started), 1)
            let lifetime = Double(cpuTime) / 1e9 / age * 100
            var instant = lifetime
            if let prev = cpuPrev[pid], prev.time <= cpuTime {
                let dt = now.timeIntervalSince(prev.at)
                if dt > 0.5 { instant = Double(cpuTime - prev.time) / 1e9 / dt * 100 }
            }
            cpuPrev[pid] = (cpuTime, now)

            out.append(Proc(pid: pid, ppid: pid_t(bsd.pbi_ppid), path: m.path, args: m.args, startedAt: started,
                            cpuNow: instant, cpuLifetime: lifetime, rssBytes: task.pti_resident_size))
        }
        cpuPrev = cpuPrev.filter { seen.contains($0.key) }
        meta = meta.filter { seen.contains($0.key) }
        return out
    }

    private func metadata(for pid: pid_t, started: Date) -> Meta {
        if let m = meta[pid], abs(m.started.timeIntervalSince(started)) < 1 { return m }
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))   // PROC_PIDPATHINFO_MAXSIZE
        let path = proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : "pid \(pid)"
        let m = Meta(path: path, args: readArgs ? Self.args(for: pid) : "", started: started)
        meta[pid] = m
        return m
    }

    /// Command line via KERN_PROCARGS2. Empty if unreadable.
    static func args(for pid: pid_t) -> String {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return "" }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return "" }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }   // exec path
        while i < size && buf[i] == 0 { i += 1 }   // padding
        var parts: [String] = []
        var cur: [UInt8] = []
        while i < size && parts.count < argc {
            if buf[i] == 0 { parts.append(String(decoding: cur, as: UTF8.self)); cur.removeAll(keepingCapacity: true) }
            else { cur.append(buf[i]) }
            i += 1
        }
        return parts.joined(separator: " ")
    }
}
