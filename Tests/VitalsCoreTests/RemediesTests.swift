import XCTest
import Darwin
@testable import VitalsCore

final class RemediesTests: XCTestCase {

    private var spawned: [Process] = []
    private var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = makeTempDir("vitals-remedies")
    }

    override func tearDown() {
        for p in spawned where p.isRunning { p.terminate() }
        for p in spawned where p.isRunning { p.waitUntilExit() }
        spawned.removeAll()
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    private func spawnSleep(_ seconds: Int = 60) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["\(seconds)"]
        try p.run()
        spawned.append(p)
        return p
    }

    /// True when the kernel still knows the pid (including as a zombie).
    private func exists(_ pid: pid_t) -> Bool { Darwin.kill(pid, 0) == 0 || errno == EPERM }

    // MARK: terminate

    func testTerminateKillsASpawnedProcessAndReportsIt() throws {
        let sleep = try spawnSleep()
        let pid = sleep.processIdentifier
        XCTAssertTrue(exists(pid))

        let gone = Remedies.terminate([pid], grace: 2)
        XCTAssertEqual(gone, [pid])

        sleep.waitUntilExit()   // reap so the pid is fully released
        XCTAssertFalse(sleep.isRunning)
        XCTAssertFalse(exists(pid), "pid \(pid) still exists after terminate")
        XCTAssertEqual(sleep.terminationReason, .uncaughtSignal)
    }

    func testTerminateRefusesLaunchdAndItself() {
        let me = getpid()
        let gone = Remedies.terminate([1, me], grace: 0.1)
        XCTAssertTrue(gone.isEmpty, "\(gone)")
        XCTAssertTrue(exists(1))
        XCTAssertTrue(exists(me))
    }

    func testTerminateSkipsProtectedPidsButStillKillsTheRest() throws {
        let sleep = try spawnSleep()
        let pid = sleep.processIdentifier
        let gone = Remedies.terminate([1, pid, getpid()], grace: 2)
        XCTAssertEqual(gone, [pid])
        sleep.waitUntilExit()
        XCTAssertFalse(exists(pid))
    }

    // MARK: Shell

    func testWhichFindsSystemToolsOnly() {
        XCTAssertEqual(Shell.which("ls"), "/bin/ls")
        XCTAssertNil(Shell.which("definitely-not-a-tool-xyz"))
    }

    func testRunReportsExitStatus() {
        XCTAssertTrue(Shell.run(["true"], timeout: 5).ok)
        let f = Shell.run(["false"], timeout: 5)
        XCTAssertFalse(f.ok)
        XCTAssertEqual(f.status, 1)
    }

    func testRunCapturesOutput() {
        let r = Shell.run(["echo", "hello"], timeout: 5)
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.output, "hello\n")
    }

    func testRunOfMissingToolIs127() {
        let r = Shell.run(["definitely-not-a-tool-xyz"], timeout: 5)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.status, 127)
    }

    func testRunTimesOutAndReturnsPromptly() {
        let start = Date()
        let r = Shell.run(["sleep", "30"], timeout: 1)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(r.ok)
        XCTAssertLessThan(elapsed, 3, "took \(elapsed)s")
        XCTAssertGreaterThanOrEqual(elapsed, 1)
    }

    // MARK: purgeCaches

    func testPurgeCachesRemovesExistingTargetsAndSkipsMissingOnes() throws {
        let cache = tmp.appendingPathComponent("SomeCache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 1_048_576).write(to: cache.appendingPathComponent("blob.bin"))
        let missing = tmp.appendingPathComponent("does-not-exist").path

        var progress: [String] = []
        let report = Remedies.purgeCaches(
            targets: [Remedies.PurgeTarget("Test cache", cache.path), Remedies.PurgeTarget("Ghost cache", missing)],
            commands: [],
            progress: { progress.append($0) })

        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path), "target directory should be gone")
        XCTAssertEqual(report.removed, ["Test cache"])
        XCTAssertTrue(report.failed.isEmpty, "\(report.failed)")
        XCTAssertGreaterThanOrEqual(report.freedBytes, 0)
        XCTAssertEqual(progress, ["Clearing Test cache"])
        XCTAssertTrue(report.summary.hasPrefix("Freed "), report.summary)
        XCTAssertTrue(report.summary.hasSuffix("(Test cache)"), report.summary)
    }

    func testPurgeCachesExpandsTilde() throws {
        // A target written as "~/..." resolves against HOME. Use a unique dir under HOME's temp-safe area.
        let home = NSHomeDirectory()
        let rel = ".vitals-test-\(UUID().uuidString)"
        let abs = home + "/" + rel
        try FileManager.default.createDirectory(atPath: abs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: abs) }

        let report = Remedies.purgeCaches(targets: [Remedies.PurgeTarget("Tilde cache", "~/" + rel)], commands: [], progress: { _ in })
        XCTAssertEqual(report.removed, ["Tilde cache"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: abs))
    }

    func testPurgeCachesRunsCommandsOnlyWhenInstalled() {
        var progress: [String] = []
        let report = Remedies.purgeCaches(
            targets: [],
            commands: [("say true", ["true"]), ("say false", ["false"]), ("ghost", ["definitely-not-a-tool-xyz"])],
            progress: { progress.append($0) })
        XCTAssertEqual(report.removed, ["say true"])
        XCTAssertEqual(report.failed, ["say false"])
        XCTAssertEqual(progress, ["Running say true", "Running say false"])
    }

    // MARK: PurgeReport.summary

    func testSummaryWhenNothingHappened() {
        XCTAssertEqual(Remedies.PurgeReport().summary, "Nothing to free")
        var r = Remedies.PurgeReport()
        r.freedBytes = 5 * Int64(GB)
        XCTAssertEqual(r.summary, "Nothing to free", "bytes alone do not count without a removed or failed label")
    }

    func testSummaryWithRemovedOnly() {
        var r = Remedies.PurgeReport()
        r.freedBytes = 2 * Int64(GB)
        r.removed = ["A", "B"]
        XCTAssertEqual(r.summary, "Freed 2.0 GB (A, B)")
    }

    func testSummaryWithFailedOnly() {
        var r = Remedies.PurgeReport()
        r.failed = ["C"]
        XCTAssertEqual(r.summary, "Freed 0 MB. Skipped: C")
    }

    func testSummaryWithBothAndNegativeBytesClampedToZero() {
        var r = Remedies.PurgeReport()
        r.freedBytes = -123_456
        r.removed = ["A"]
        r.failed = ["C", "D"]
        XCTAssertEqual(r.summary, "Freed 0 MB (A). Skipped: C, D")
    }
}
