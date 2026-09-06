import Foundation
@testable import VitalsCore

/// Fixed reference instant: 2023-11-14T22:13:20Z. Every rule/history test measures time from here.
let T0 = Date(timeIntervalSince1970: 1_700_000_000)

let MB: UInt64 = 1_048_576
let GB: UInt64 = 1_073_741_824

/// Build a `Sample` with every field explicit. Defaults describe a healthy 8-core, 16 GB machine
/// that booted an hour ago.
func makeSample(at: Date = T0,
                cores: Int = 8,
                load1: Double = 1,
                load5: Double = 1,
                memTotal: UInt64 = 16 * GB,
                memUsed: UInt64 = 8 * GB,
                memoryPressure: MemoryPressure = .normal,
                swapTotal: UInt64 = 1000 * MB,
                swapUsed: UInt64 = 0,
                diskTotal: Int64 = 1000 * Int64(GB),
                diskFree: Int64 = 500 * Int64(GB),
                uptime: TimeInterval = 3600,
                thermal: Thermal = .nominal,
                lowPowerMode: Bool = false,
                battery: Battery? = nil,
                procs: [Proc] = []) -> Sample {
    Sample(at: at, cores: cores, load1: load1, load5: load5,
           memTotal: memTotal, memUsed: memUsed, memoryPressure: memoryPressure,
           swapTotal: swapTotal, swapUsed: swapUsed, diskTotal: diskTotal, diskFree: diskFree,
           uptime: uptime, thermal: thermal, lowPowerMode: lowPowerMode, battery: battery, procs: procs)
}

/// Build a `Proc` with every field explicit. Defaults describe a quiet process started a minute before T0.
func makeProc(pid: pid_t,
              ppid: pid_t = 500,
              path: String,
              args: String = "",
              startedAt: Date = T0.addingTimeInterval(-60),
              cpuNow: Double = 0,
              cpuLifetime: Double = 0,
              rssBytes: UInt64 = 10 * MB) -> Proc {
    Proc(pid: pid, ppid: ppid, path: path, args: args, startedAt: startedAt,
         cpuNow: cpuNow, cpuLifetime: cpuLifetime, rssBytes: rssBytes)
}

func makeIssue(kind: IssueKind, severity: Severity, title: String, detail: String = "", remedy: Remedy = .none, key: String) -> Issue {
    Issue(kind: kind, severity: severity, title: title, detail: detail, remedy: remedy, key: key)
}

/// A fresh, empty directory under the system temp dir. Caller removes it in teardown.
func makeTempDir(_ name: String = "vitals-tests") -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
