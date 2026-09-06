#if os(macOS)
import XCTest
import Darwin
@testable import VitalsCore

/// Reads the real machine. Assertions are deliberately loose bounds, never exact values.
final class SamplerIntegrationTests: XCTestCase {

    private var spawned: [Process] = []

    override func tearDown() {
        for p in spawned where p.isRunning { p.terminate() }
        for p in spawned where p.isRunning { p.waitUntilExit() }
        spawned.removeAll()
        super.tearDown()
    }

    /// Run a tool to completion and return stdout.
    private func output(of exe: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func testSampleReadsAPlausibleMachine() {
        let s = Sampler().sample()
        XCTAssertGreaterThanOrEqual(s.cores, 1)
        XCTAssertGreaterThan(s.memTotal, 0)
        XCTAssertLessThanOrEqual(s.memUsed, s.memTotal)
        XCTAssertGreaterThan(s.uptime, 0)
        XCTAssertGreaterThan(s.diskTotal, 0)
        XCTAssertGreaterThanOrEqual(s.procs.count, 10, "expected at least 10 processes for this uid")

        let me = getpid()
        for p in s.procs {
            XCTAssertFalse(p.path.isEmpty, "pid \(p.pid) has no path")
            XCTAssertGreaterThan(p.pid, 0)
            XCTAssertNotEqual(p.pid, me, "the sampler must skip itself")
            XCTAssertGreaterThanOrEqual(p.cpuNow, 0)
            XCTAssertGreaterThanOrEqual(p.cpuLifetime, 0)
        }
        XCTAssertEqual(Set(s.procs.map(\.pid)).count, s.procs.count, "no duplicate pids")
    }

    /// `proc_taskinfo` reports CPU in Mach ticks. If they were read as nanoseconds, a process
    /// pinning one core would show ~2% instead of ~100%.
    func testCPUPercentIsInUnitsOfOneCore() throws {
        let yes = Process()
        yes.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        yes.standardOutput = FileHandle.nullDevice
        yes.standardError = FileHandle.nullDevice
        try yes.run()
        spawned.append(yes)
        let pid = yes.processIdentifier

        let sampler = Sampler(readArgs: false)
        Thread.sleep(forTimeInterval: 0.5)
        _ = sampler.sample()                      // establishes the CPU-time baseline
        Thread.sleep(forTimeInterval: 1.5)
        let second = sampler.sample()

        let proc = try XCTUnwrap(second.procs.first { $0.pid == pid }, "yes (pid \(pid)) not in sample")
        XCTAssertEqual(proc.name, "yes")
        XCTAssertGreaterThanOrEqual(proc.cpuNow, 80, "cpuNow \(proc.cpuNow): looks like ticks read as nanoseconds")
        XCTAssertLessThanOrEqual(proc.cpuNow, 130, "cpuNow \(proc.cpuNow): more than one core for a single thread")
        XCTAssertGreaterThanOrEqual(proc.cpuLifetime, 50, "cpuLifetime \(proc.cpuLifetime)")
    }

    /// `proc_listallpids` returns a count of pids, not a byte count. If the two were confused the
    /// sampler would see a quarter (or four times) as many processes as `ps` does.
    func testProcessCountMatchesPs() throws {
        let uid = getuid()
        let ps = try output(of: "/bin/ps", ["-Ao", "uid"])
        let psCount = ps.split(separator: "\n")
            .compactMap { UInt32($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 == uid }
            .count
        XCTAssertGreaterThanOrEqual(psCount, 10)

        let ours = Sampler(readArgs: false).sample().procs.count
        let tolerance = Int((Double(psCount) * 0.15).rounded(.up))
        XCTAssertLessThanOrEqual(abs(ours - psCount), tolerance,
                                 "sampler saw \(ours) processes, ps saw \(psCount) for uid \(uid)")
    }

    func testBatteryIsNilOrInRange() {
        guard let b = Sampler.battery() else { return }   // desktop
        XCTAssertTrue((0...100).contains(b.percent), "battery percent \(b.percent)")
    }

    func testSinceBootMatchesKernelBootTime() throws {
        let raw = try output(of: "/usr/sbin/sysctl", ["-n", "kern.boottime"])
        // "{ sec = 1757100000, usec = 123456 } Sat Sep  6 ..."
        let match = try XCTUnwrap(raw.range(of: #"sec = ([0-9]+)"#, options: .regularExpression), raw)
        let secText = raw[match].split(separator: "=")[1].trimmingCharacters(in: .whitespaces)
        let bootSec = try XCTUnwrap(TimeInterval(secText), raw)

        let expected = Date().timeIntervalSince1970 - bootSec
        let actual = Sampler.sinceBoot()
        XCTAssertEqual(actual, expected, accuracy: 5, "sinceBoot \(actual) vs sysctl \(expected)")
        XCTAssertGreaterThan(actual, 0)
    }
}
#endif
