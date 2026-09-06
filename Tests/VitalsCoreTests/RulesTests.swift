import XCTest
@testable import VitalsCore

final class RulesTests: XCTestCase {

    private func issues(_ s: Sample, rules: Rules = Rules()) -> [Issue] { rules.evaluate(s) }
    private func issue(_ s: Sample, kind: IssueKind, rules: Rules = Rules()) -> Issue? {
        rules.evaluate(s).first { $0.kind == kind }
    }

    // MARK: Swap

    func testSwapBelowWarnIsNotAnIssue() throws {
        let s = makeSample(swapTotal: 1000 * MB, swapUsed: 740 * MB)   // 74%
        XCTAssertNil(issue(s, kind: .swap))
    }

    func testSwapAtWarnThresholdWarns() throws {
        let s = makeSample(swapTotal: 1000 * MB, swapUsed: 750 * MB)   // 75%
        let i = try XCTUnwrap(issue(s, kind: .swap))
        XCTAssertEqual(i.severity, .warn)
        XCTAssertEqual(i.title, "Swap is high")
        XCTAssertEqual(i.key, "swap")
    }

    func testSwapAtBadThresholdIsBad() throws {
        let s = makeSample(swapTotal: 1000 * MB, swapUsed: 900 * MB)   // 90%
        let i = try XCTUnwrap(issue(s, kind: .swap))
        XCTAssertEqual(i.severity, .bad)
        XCTAssertEqual(i.title, "Swap is full")
    }

    // MARK: Disk

    func testDiskFreeAbove15PercentIsFine() throws {
        XCTAssertNil(issue(makeSample(diskTotal: 1000 * Int64(GB), diskFree: 160 * Int64(GB)), kind: .disk))
    }

    func testDiskFreeUnder15PercentWarns() throws {
        let i = try XCTUnwrap(issue(makeSample(diskTotal: 1000 * Int64(GB), diskFree: 149 * Int64(GB)), kind: .disk))
        XCTAssertEqual(i.severity, .warn)
        XCTAssertEqual(i.title, "Disk is low")
    }

    func testDiskFreeUnder8PercentIsBad() throws {
        let i = try XCTUnwrap(issue(makeSample(diskTotal: 1000 * Int64(GB), diskFree: 79 * Int64(GB)), kind: .disk))
        XCTAssertEqual(i.severity, .bad)
        XCTAssertEqual(i.title, "Disk nearly full")
    }

    // MARK: Uptime

    func testUptimeUnder14DaysIsFine() throws {
        XCTAssertNil(issue(makeSample(uptime: 13.9 * 86400), kind: .uptime))
    }

    func testUptimeAt14DaysWarns() throws {
        let i = try XCTUnwrap(issue(makeSample(uptime: 14 * 86400), kind: .uptime))
        XCTAssertEqual(i.severity, .warn)
        XCTAssertEqual(i.title, "No restart in 14 days")
    }

    func testUptimeAt30DaysIsBadAndNamesTheDayCount() throws {
        let i = try XCTUnwrap(issue(makeSample(uptime: 30 * 86400), kind: .uptime))
        XCTAssertEqual(i.severity, .bad)
        XCTAssertTrue(i.title.contains("30"), i.title)
    }

    // MARK: Memory pressure

    func testMemoryPressureWarningWarns() throws {
        let i = try XCTUnwrap(issue(makeSample(memoryPressure: .warning), kind: .memory))
        XCTAssertEqual(i.severity, .warn)
        XCTAssertEqual(i.key, "memory")
    }

    func testMemoryPressureCriticalIsBad() throws {
        let i = try XCTUnwrap(issue(makeSample(memoryPressure: .critical), kind: .memory))
        XCTAssertEqual(i.severity, .bad)
    }

    func testMemoryPressureNormalIsNotAnIssue() throws {
        XCTAssertNil(issue(makeSample(memoryPressure: .normal), kind: .memory))
    }

    // MARK: Thermal

    func testThermalFairWarns() throws {
        let i = try XCTUnwrap(issue(makeSample(thermal: .fair), kind: .thermal))
        XCTAssertEqual(i.severity, .warn)
        XCTAssertEqual(i.title, "Getting warm")
        XCTAssertFalse(i.detail.contains("mostly"), "no culprit when nothing is busy: \(i.detail)")
    }

    func testThermalSeriousIsBad() throws {
        let i = try XCTUnwrap(issue(makeSample(thermal: .serious), kind: .thermal))
        XCTAssertEqual(i.severity, .bad)
    }

    func testThermalDetailNamesAnAppUsingAtLeast15PercentOfMachine() throws {
        // 3 x 70% of one core = 210% on 8 cores = 26% of the machine.
        let procs = (1...3).map { n in
            makeProc(pid: pid_t(100 + n), path: "/Applications/Arc.app/Contents/MacOS/Arc", cpuNow: 70)
        }
        let i = try XCTUnwrap(issue(makeSample(cores: 8, thermal: .fair, procs: procs), kind: .thermal))
        XCTAssertTrue(i.detail.contains("mostly Arc"), i.detail)
        XCTAssertTrue(i.detail.contains("26%"), i.detail)
    }

    // MARK: Runaway (sustained)

    private func hot(_ cpu: Double, pid: pid_t = 4242, path: String = "/Applications/Foo.app/Contents/MacOS/Foo") -> Proc {
        makeProc(pid: pid, path: path, startedAt: T0.addingTimeInterval(-60), cpuNow: cpu, cpuLifetime: 20)
    }

    func testRunawayNeedsHotForBeforeFlagging() throws {
        let rules = Rules()
        XCTAssertNil(issue(makeSample(at: T0, procs: [hot(95)]), kind: .runaway, rules: rules))
        XCTAssertNil(issue(makeSample(at: T0.addingTimeInterval(179), procs: [hot(95)]), kind: .runaway, rules: rules))

        let i = try XCTUnwrap(issue(makeSample(at: T0.addingTimeInterval(181), procs: [hot(95)]), kind: .runaway, rules: rules))
        XCTAssertEqual(i.severity, .bad)
        XCTAssertEqual(i.remedy, .kill([4242]))
        XCTAssertEqual(i.key, "runaway:Foo#4242")
        XCTAssertEqual(i.title, "Foo is stuck")
        XCTAssertTrue(i.detail.hasPrefix("95% CPU for 3m"), i.detail)
    }

    func testRunawayClearsWhenCoolAndRestartsTheClock() throws {
        let rules = Rules()
        _ = rules.evaluate(makeSample(at: T0, procs: [hot(95)]))
        XCTAssertNotNil(issue(makeSample(at: T0.addingTimeInterval(200), procs: [hot(95)]), kind: .runaway, rules: rules))

        // A cool sample clears it.
        XCTAssertNil(issue(makeSample(at: T0.addingTimeInterval(210), procs: [hot(10)]), kind: .runaway, rules: rules))
        // Heating up again starts a fresh 180 s clock: nothing yet.
        XCTAssertNil(issue(makeSample(at: T0.addingTimeInterval(220), procs: [hot(95)]), kind: .runaway, rules: rules))
        XCTAssertNil(issue(makeSample(at: T0.addingTimeInterval(390), procs: [hot(95)]), kind: .runaway, rules: rules))
        XCTAssertNotNil(issue(makeSample(at: T0.addingTimeInterval(401), procs: [hot(95)]), kind: .runaway, rules: rules))
    }

    func testRunawayForgetsProcessesThatDisappear() throws {
        let rules = Rules()
        _ = rules.evaluate(makeSample(at: T0, procs: [hot(95)]))
        _ = rules.evaluate(makeSample(at: T0.addingTimeInterval(100), procs: []))   // pid gone
        // Same pid back: the clock starts over.
        XCTAssertNil(issue(makeSample(at: T0.addingTimeInterval(200), procs: [hot(95)]), kind: .runaway, rules: rules))
    }

    // MARK: Runaway (chronic)

    func testChronicRunawayFlagsOnFirstSample() throws {
        let p = makeProc(pid: 77, path: "/Applications/Foo.app/Contents/MacOS/Foo",
                         startedAt: T0.addingTimeInterval(-3600), cpuNow: 75, cpuLifetime: 80)
        let i = try XCTUnwrap(issue(makeSample(at: T0, procs: [p]), kind: .runaway))
        XCTAssertEqual(i.severity, .bad)
        XCTAssertEqual(i.key, "runaway:Foo#77")
        XCTAssertEqual(i.remedy, .kill([77]))
    }

    func testChronicNeedsCurrentCPUToo() throws {
        // Averaged hot since launch but idle right now: not stuck.
        let p = makeProc(pid: 77, path: "/Applications/Foo.app/Contents/MacOS/Foo",
                         startedAt: T0.addingTimeInterval(-3600), cpuNow: 5, cpuLifetime: 80)
        XCTAssertNil(issue(makeSample(at: T0, procs: [p]), kind: .runaway))
    }

    // MARK: Known-busy

    func testKnownBusyToolGetsSofterVerdict() throws {
        let rules = Rules()
        let clang = { (cpu: Double) in self.hot(cpu, pid: 900, path: "/usr/bin/clang") }
        _ = rules.evaluate(makeSample(at: T0, procs: [clang(95)]))
        XCTAssertTrue(rules.evaluate(makeSample(at: T0.addingTimeInterval(100), procs: [clang(95)])).isEmpty)

        let out = rules.evaluate(makeSample(at: T0.addingTimeInterval(181), procs: [clang(95)]))
        XCTAssertEqual(out.count, 1)
        let i = out[0]
        XCTAssertEqual(i.kind, .busy)
        XCTAssertEqual(i.severity, .warn)
        XCTAssertTrue(i.title.contains("working hard"), i.title)
        XCTAssertEqual(i.key, "busy:clang#900")
        XCTAssertEqual(i.remedy, .kill([900]))
    }

    // MARK: resetTimers

    func testResetTimersForgetsAccumulatedHeat() throws {
        let rules = Rules()
        _ = rules.evaluate(makeSample(at: T0, procs: [hot(95)]))
        _ = rules.evaluate(makeSample(at: T0.addingTimeInterval(179), procs: [hot(95)]))
        rules.resetTimers()
        XCTAssertNil(issue(makeSample(at: T0.addingTimeInterval(181), procs: [hot(95)]), kind: .runaway, rules: rules))
        XCTAssertNil(issue(makeSample(at: T0.addingTimeInterval(360), procs: [hot(95)]), kind: .runaway, rules: rules))
        XCTAssertNotNil(issue(makeSample(at: T0.addingTimeInterval(362), procs: [hot(95)]), kind: .runaway, rules: rules))
    }

    // MARK: appHog

    /// Six Arc processes (main + 5 helpers) whose cpuNow values are given.
    private func arc(_ cpus: [Double], rssEach: UInt64 = 10 * MB) -> [Proc] {
        precondition(cpus.count == 6)
        let main = "/Applications/Arc.app/Contents/MacOS/Arc"
        let helper = "/Applications/Arc.app/Contents/Frameworks/Arc Helper (Renderer).app/Contents/MacOS/Arc Helper (Renderer)"
        return cpus.enumerated().map { n, cpu in
            makeProc(pid: pid_t(2000 + n), path: n == 0 ? main : helper, cpuNow: cpu, cpuLifetime: 20, rssBytes: rssEach)
        }
    }
    private let arcPids: Set<pid_t> = Set((0..<6).map { pid_t(2000 + $0) })

    func testAppHogWarnsAfterSustainedCPUShare() throws {
        let rules = Rules()
        let procs = arc([50, 50, 50, 50, 50, 50])   // 300% of 8 cores = 37.5%
        XCTAssertNil(issue(makeSample(at: T0, cores: 8, procs: procs), kind: .appHog, rules: rules))
        XCTAssertNil(issue(makeSample(at: T0.addingTimeInterval(119), cores: 8, procs: procs), kind: .appHog, rules: rules))

        let i = try XCTUnwrap(issue(makeSample(at: T0.addingTimeInterval(121), cores: 8, procs: procs), kind: .appHog, rules: rules))
        XCTAssertEqual(i.severity, .warn)
        XCTAssertEqual(i.key, "appHog:Arc")
        XCTAssertEqual(i.title, "Arc is taking over")
        guard case .quitApp(let name, let pids) = i.remedy else { return XCTFail("expected quitApp, got \(i.remedy)") }
        XCTAssertEqual(name, "Arc")
        XCTAssertEqual(Set(pids), arcPids)
        XCTAssertEqual(pids.count, 6)
        XCTAssertTrue(i.detail.contains("37% of CPU"), i.detail)
        XCTAssertTrue(i.detail.contains("across 6 processes"), i.detail)
    }

    func testAppHogIsBadAbove60PercentShare() throws {
        let rules = Rules()
        let procs = arc([84, 84, 84, 84, 84, 80])   // 500% of 8 cores = 62.5%
        _ = rules.evaluate(makeSample(at: T0, cores: 8, procs: procs))
        let i = try XCTUnwrap(issue(makeSample(at: T0.addingTimeInterval(121), cores: 8, procs: procs), kind: .appHog, rules: rules))
        XCTAssertEqual(i.severity, .bad)
    }

    func testAppHogClearsWhenShareDrops() throws {
        let rules = Rules()
        _ = rules.evaluate(makeSample(at: T0, cores: 8, procs: arc([50, 50, 50, 50, 50, 50])))
        _ = rules.evaluate(makeSample(at: T0.addingTimeInterval(60), cores: 8, procs: arc([10, 10, 10, 10, 10, 10])))
        // Back above the line: the clock restarted at +60, so +121 is only 61 s in.
        XCTAssertNil(issue(makeSample(at: T0.addingTimeInterval(121), cores: 8, procs: arc([50, 50, 50, 50, 50, 50])), kind: .appHog, rules: rules))
    }

    func testAppHogOnMemoryAloneIsImmediate() throws {
        // 6 procs x 5.2% of 16 GB = 31% of RAM, zero CPU.
        let memTotal = 16 * GB
        let each = UInt64(Double(memTotal) * 0.31 / 6)
        let procs = arc([0, 0, 0, 0, 0, 0], rssEach: each)
        let i = try XCTUnwrap(issue(makeSample(at: T0, cores: 8, memTotal: memTotal, procs: procs), kind: .appHog))
        XCTAssertEqual(i.severity, .warn)
        XCTAssertTrue(i.detail.contains("of RAM"), i.detail)
        XCTAssertFalse(i.detail.contains("of CPU"), i.detail)
    }

    func testAppHogNonBundleGroupGetsKillNotQuit() throws {
        let rules = Rules()
        let procs = (0..<6).map { n in
            makeProc(pid: pid_t(3000 + n), ppid: 500,
                     path: "/Users/x/Library/Application Support/Claude/claude-code/2.1.258/claude.app/Contents/MacOS/claude",
                     cpuNow: 50, cpuLifetime: 20)
        }
        _ = rules.evaluate(makeSample(at: T0, cores: 8, procs: procs))
        let i = try XCTUnwrap(issue(makeSample(at: T0.addingTimeInterval(121), cores: 8, procs: procs), kind: .appHog, rules: rules))
        XCTAssertEqual(i.key, "appHog:Claude Code")
        guard case .kill(let pids) = i.remedy else { return XCTFail("expected kill, got \(i.remedy)") }
        XCTAssertEqual(Set(pids), Set((0..<6).map { pid_t(3000 + $0) }))
    }

    // MARK: Orphans

    private let claudeHelper = "/Users/x/Library/Application Support/Claude/claude-code/2.1.258/claude.app/Contents/MacOS/claude"

    func testOrphanedClaudeHelperAndItsChildAreOneIssue() throws {
        let orphan = makeProc(pid: 6001, ppid: 1, path: claudeHelper, args: "claude --bg-spare")
        let child = makeProc(pid: 6002, ppid: 6001, path: "/bin/zsh", args: "zsh -l")
        let bystander = makeProc(pid: 6003, ppid: 500, path: "/bin/zsh", args: "zsh")
        let out = issues(makeSample(procs: [orphan, child, bystander]))
        XCTAssertEqual(out.count, 1, "\(out)")
        let i = out[0]
        XCTAssertEqual(i.kind, .orphan)
        XCTAssertEqual(i.severity, .warn)
        XCTAssertEqual(i.key, "orphan:Claude Code")
        XCTAssertEqual(i.title, "Leaked Claude Code processes")
        XCTAssertEqual(Set(i.remedy.pids), [6001, 6002])
        XCTAssertTrue(i.detail.hasPrefix("2 left behind"), i.detail)
    }

    func testOrphanRuleAcceptsPtyHostFlag() throws {
        let orphan = makeProc(pid: 6001, ppid: 1, path: claudeHelper, args: "claude --bg-pty-host 42")
        XCTAssertNotNil(issue(makeSample(procs: [orphan]), kind: .orphan))
    }

    func testClaudeUnderLaunchdWithoutBackgroundFlagIsNotAnOrphan() throws {
        let p = makeProc(pid: 6001, ppid: 1, path: claudeHelper, args: "claude --resume")
        XCTAssertNil(issue(makeSample(procs: [p]), kind: .orphan))
    }

    func testBackgroundHelperWithLiveParentIsNotAnOrphan() throws {
        let p = makeProc(pid: 6001, ppid: 500, path: claudeHelper, args: "claude --bg-spare")
        XCTAssertNil(issue(makeSample(procs: [p]), kind: .orphan))
    }

    // MARK: Sorting

    func testBadIssuesComeBeforeWarn() throws {
        // swap bad, disk warn, uptime warn, memory bad, thermal warn.
        let s = makeSample(memoryPressure: .critical,
                           swapTotal: 1000 * MB, swapUsed: 950 * MB,
                           diskTotal: 1000 * Int64(GB), diskFree: 100 * Int64(GB),
                           uptime: 15 * 86400, thermal: .fair)
        let out = issues(s)
        XCTAssertEqual(out.count, 5)
        let sev = out.map(\.severity)
        XCTAssertEqual(sev, [.bad, .bad, .warn, .warn, .warn])
        XCTAssertEqual(Set(out.prefix(2).map(\.kind)), [.swap, .memory])
    }

    // MARK: Thresholds

    func testThresholdsLoadReadsOverridesFromDefaults() throws {
        let suite = "vitals-tests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removePersistentDomain(forName: suite)

        XCTAssertEqual(Thresholds.load(from: defaults).swapWarn, 75, "untouched suite gives the default")

        defaults.set(50.0, forKey: "threshold.swapWarn")
        defaults.set(7.0, forKey: "threshold.hotFor")
        let t = Thresholds.load(from: defaults)
        XCTAssertEqual(t.swapWarn, 50)
        XCTAssertEqual(t.hotFor, 7)
        XCTAssertEqual(t.swapBad, 90, "keys not set keep their default")

        // The override actually moves the boundary: 60% swap now warns.
        let s = makeSample(swapTotal: 1000 * MB, swapUsed: 600 * MB)
        XCTAssertNil(issue(s, kind: .swap, rules: Rules()))
        XCTAssertEqual(issue(s, kind: .swap, rules: Rules(thresholds: t))?.severity, .warn)
    }
}
