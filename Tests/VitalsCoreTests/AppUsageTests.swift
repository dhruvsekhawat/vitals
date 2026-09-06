import XCTest
@testable import VitalsCore

final class AppUsageTests: XCTestCase {

    private let cursorMain = "/Applications/Cursor.app/Contents/MacOS/Cursor"
    private let cursorHelper = "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Renderer).app/Contents/MacOS/Cursor Helper (Renderer)"
    private let claudeApp = "~/Library/Application Support/Claude/claude-code/2.1.258/claude.app/Contents/MacOS/claude"
    private let claudeLocal = "/Users/x/.local/share/claude/versions/2.1.247"

    // MARK: Proc naming

    func testProcAppIsOutermostBundle() {
        XCTAssertEqual(makeProc(pid: 1, path: cursorHelper).app, "Cursor")
        XCTAssertEqual(makeProc(pid: 2, path: cursorMain).app, "Cursor")
        XCTAssertNil(makeProc(pid: 3, path: "/usr/bin/python3").app)
    }

    func testProcDisplayName() {
        XCTAssertEqual(makeProc(pid: 1, path: cursorHelper).displayName, "Cursor \u{00B7} Cursor Helper (Renderer)")
        XCTAssertEqual(makeProc(pid: 2, path: cursorMain).displayName, "Cursor")
        XCTAssertEqual(makeProc(pid: 3, path: "/usr/bin/python3").displayName, "python3")
    }

    // MARK: Grouping

    func testHelpersRollUpUnderTheOutermostApp() {
        let procs = [
            makeProc(pid: 11, path: cursorMain, cpuNow: 12.5, rssBytes: 300 * MB),
            makeProc(pid: 12, path: cursorHelper, cpuNow: 7.5, rssBytes: 200 * MB),
        ]
        let top = AppUsage.top(procs, cores: 8)
        XCTAssertEqual(top.count, 1)
        let g = top[0]
        XCTAssertEqual(g.name, "Cursor")
        XCTAssertTrue(g.isBundle)
        XCTAssertEqual(g.procs, 2)
        XCTAssertEqual(g.cpu, 20)
        XCTAssertEqual(g.rss, 500 * MB)
        XCTAssertEqual(Set(g.pids), [11, 12])
    }

    func testClaudeCodeInstallsGroupTogetherAsNonBundle() {
        let procs = [
            makeProc(pid: 21, path: claudeApp, cpuNow: 5),
            makeProc(pid: 22, path: claudeLocal, cpuNow: 5),
        ]
        let top = AppUsage.top(procs, cores: 8)
        XCTAssertEqual(top.count, 1)
        XCTAssertEqual(top[0].name, "Claude Code")
        XCTAssertFalse(top[0].isBundle)
        XCTAssertEqual(top[0].procs, 2)
        XCTAssertEqual(top[0].cpu, 10)
    }

    func testBareExecutableGroupsByItsName() {
        let top = AppUsage.top([makeProc(pid: 31, path: "/usr/bin/python3", cpuNow: 3)], cores: 8)
        XCTAssertEqual(top.count, 1)
        XCTAssertEqual(top[0].name, "python3")
        XCTAssertFalse(top[0].isBundle)
    }

    // MARK: Filter

    func testQuietSmallGroupsAreDropped() {
        let quiet = makeProc(pid: 41, path: "/usr/bin/quiet", cpuNow: 0.5, rssBytes: 100 * MB)
        XCTAssertTrue(AppUsage.top([quiet], cores: 8).isEmpty)
    }

    func testOnePercentCPUIsEnoughToBeListed() {
        let p = makeProc(pid: 42, path: "/usr/bin/busy", cpuNow: 1.0, rssBytes: 100 * MB)
        XCTAssertEqual(AppUsage.top([p], cores: 8).map(\.name), ["busy"])
    }

    func testFiveHundredMegabytesIsEnoughToBeListed() {
        let p = makeProc(pid: 43, path: "/usr/bin/fat", cpuNow: 0, rssBytes: 500 * MB)
        XCTAssertEqual(AppUsage.top([p], cores: 8).map(\.name), ["fat"])
    }

    // MARK: Ordering and limit

    func testSortedByCPUThenRSSDescending() {
        let procs = [
            makeProc(pid: 51, path: "/usr/bin/a", cpuNow: 5, rssBytes: 600 * MB),
            makeProc(pid: 52, path: "/usr/bin/b", cpuNow: 20, rssBytes: 10 * MB),
            makeProc(pid: 53, path: "/usr/bin/c", cpuNow: 5, rssBytes: 900 * MB),
            makeProc(pid: 54, path: "/usr/bin/d", cpuNow: 9, rssBytes: 10 * MB),
        ]
        XCTAssertEqual(AppUsage.top(procs, cores: 8).map(\.name), ["b", "d", "c", "a"])
    }

    func testLimitIsRespected() {
        let procs = (0..<5).map { n in makeProc(pid: pid_t(60 + n), path: "/usr/bin/tool\(n)", cpuNow: Double(10 - n)) }
        XCTAssertEqual(AppUsage.top(procs, cores: 8, limit: 2).map(\.name), ["tool0", "tool1"])
        XCTAssertEqual(AppUsage.top(procs, cores: 8).count, 5, "default limit is 5")
    }
}
