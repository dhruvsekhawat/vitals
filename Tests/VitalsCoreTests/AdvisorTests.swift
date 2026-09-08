import XCTest
@testable import VitalsCore

final class AdvisorTests: XCTestCase {

    private let emDash = "\u{2014}"

    private func recommend(_ s: Sample, issues: [Issue] = [], recurrences: [Recurrence] = [], lastIncident: Incident? = nil) -> [Recommendation] {
        let out = Advisor.recommend(sample: s, issues: issues, recurrences: recurrences, lastIncident: lastIncident, now: T0)
        for r in out { XCTAssertFalse(r.text.contains(emDash), "em dash in: \(r.text)") }
        return out
    }

    private let runaway = makeIssue(kind: .runaway, severity: .bad, title: "Foo is stuck", detail: "98% CPU for 19d",
                                    remedy: .kill([42]), key: "runaway:Foo#42")
    private let appHog = makeIssue(kind: .appHog, severity: .warn, title: "Arc is taking over",
                                   detail: "40% of CPU for 5m across 6 processes",
                                   remedy: .quitApp(name: "Arc", pids: [1, 2, 3, 4, 5, 6]), key: "appHog:Arc")
    private let orphan = makeIssue(kind: .orphan, severity: .warn, title: "Leaked Claude Code processes", detail: "3 left behind",
                                   remedy: .kill([10, 11, 12]), key: "orphan:Claude Code")

    // MARK: Nothing to fix

    func testBenignMachineHasNothingToFix() throws {
        let out = recommend(makeSample())
        XCTAssertEqual(out.map(\.text), ["Nothing to fix."])
    }

    func testNothingToFixMentionsLastIncident() throws {
        let last = Incident(key: "runaway:Foo#42", kind: .runaway, severity: .bad, title: "Foo is stuck", detail: "98% CPU",
                            openedAt: T0.addingTimeInterval(-3 * 86400), closedAt: T0.addingTimeInterval(-2 * 86400), clearedByUser: true)
        let out = recommend(makeSample(), lastIncident: last)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].text, "Nothing to fix. Last problem: Foo is stuck, 3d ago.")
    }

    // MARK: Issue-driven

    func testIssueRowsAreNotRepeatedAsRecommendations() throws {
        // The issue row already says what to do and has the button; the advice list stays for cross-cutting things.
        for i in [runaway, appHog, orphan] {
            let out = recommend(makeSample(), issues: [i])
            XCTAssertTrue(out.isEmpty, "\(i.key): \(out.map(\.text))")
        }
    }

    func testPagingAdviceNamesTheMemoryHogs() throws {
        let arc = makeIssue(kind: .appHog, severity: .warn, title: "Arc is holding 14 GB", detail: "73% of your RAM across 55 processes. Close tabs or windows you are not using.", key: "appHog:Arc")
        let out = recommend(makeSample(memoryPressure: .warning, swapUsed: 9 * GB), issues: [arc])
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].text.contains("Close tabs and windows in Arc"), out[0].text)
        XCTAssertFalse(out[0].text.lowercased().contains("quit"), "never tells people to quit the app they are working in")
    }

    // MARK: Restart

    func testFullSwapRecommendsRestartBecauseOfPaging() throws {
        let out = recommend(makeSample(swapUsed: 9 * GB))   // 56% of 16 GB RAM
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].text.contains("paging"), out[0].text)
    }

    func testHighSwapRecommendsRestartWithPercent() throws {
        let out = recommend(makeSample(swapUsed: 5 * GB))   // 31% of 16 GB RAM
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].text.contains("31%"), out[0].text)
        XCTAssertFalse(out[0].text.contains("paging"), out[0].text)
    }

    func testLongUptimeWithLowSwapRecommendsRestart() throws {
        let out = recommend(makeSample(swapTotal: 100, swapUsed: 5, uptime: 20 * 86400))
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].text.hasPrefix("20 days since a restart"), out[0].text)
    }

    func testCriticalMemoryPressureRecommendsRestart() throws {
        let out = recommend(makeSample(memoryPressure: .critical))
    }

    // MARK: Disk

    func testLowDiskRecommendsFreeingSpace() throws {
        let out = recommend(makeSample(diskTotal: 100, diskFree: 10))
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].text.hasPrefix("Disk is 90% full"), out[0].text)
    }

    // MARK: Load

    func testHighLoadRightAfterBootIsExplainedAway() throws {
        let out = recommend(makeSample(cores: 8, load5: 24, uptime: 100))
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].text.hasPrefix("Just restarted"), out[0].text)
        XCTAssertFalse(out[0].text.contains("no single culprit"))
    }

    func testHighLoadWithNoCulpritIsCalledOut() throws {
        let out = recommend(makeSample(cores: 8, load5: 24, uptime: 86400))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].text, "5-minute load is 24 on 8 cores with no single culprit. Too many apps open at once.")
    }

    func testHighLoadWithARunawayDoesNotBlameEveryone() throws {
        let out = recommend(makeSample(cores: 8, load5: 24, uptime: 86400), issues: [runaway])
        XCTAssertNil(out.first { $0.text.contains("no single culprit") })
        XCTAssertNil(out.first { $0.text.hasPrefix("Nothing to fix") }, "there is an issue on screen")
    }

    func testModerateLoadIsSilent() throws {
        // 1.5 x 8 cores = 12 is the line; 12 is not over it.
        XCTAssertEqual(recommend(makeSample(cores: 8, load5: 12, uptime: 86400)).map(\.text), ["Nothing to fix."])
    }

    // MARK: Battery

    func testBusyOnBatteryAsksToPlugIn() throws {
        let battery = Battery(percent: 37, charging: false, onBattery: true)
        let out = recommend(makeSample(lowPowerMode: false, battery: battery), issues: [appHog])
        let plug = try XCTUnwrap(out.first { $0.text.contains("Plug in") })
        XCTAssertTrue(plug.text.contains("37%"), plug.text)
    }

    func testBusyOnBatteryInLowPowerModeSaysNothingAboutPluggingIn() throws {
        let battery = Battery(percent: 37, charging: false, onBattery: true)
        let out = recommend(makeSample(lowPowerMode: true, battery: battery), issues: [appHog])
        XCTAssertNil(out.first { $0.text.contains("Plug in") })
    }

    func testPluggedInWithBusyCPUSaysNothingAboutBattery() throws {
        let battery = Battery(percent: 90, charging: true, onBattery: false)
        let out = recommend(makeSample(battery: battery), issues: [appHog])
        XCTAssertNil(out.first { $0.text.contains("Plug in") })
    }

    // MARK: Recurrences

    func testRendererRecurrenceGetsExtensionHint() throws {
        let r = Recurrence(key: "runaway:Cursor Helper (Renderer)#1", title: "Cursor \u{00B7} Cursor Helper (Renderer) is stuck",
                           kind: .runaway, count: 4, last: T0)
        let out = recommend(makeSample(), recurrences: [r])
        XCTAssertEqual(out.count, 1)
        let text = out[0].text
        XCTAssertTrue(text.contains("4 times in 30 days"), text)
        XCTAssertTrue(text.contains("extension"), text)
    }

    func testOrphanRecurrenceGetsParentAppHint() throws {
        let r = Recurrence(key: "orphan:Claude Code", title: "Leaked Claude Code processes", kind: .orphan, count: 2, last: T0)
        let out = recommend(makeSample(), recurrences: [r])
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].text.contains("2 times in 30 days"), out[0].text)
        XCTAssertTrue(out[0].text.contains("parent app"), out[0].text)
    }

    // MARK: Everything at once

    func testCombinedCaseHasNoEmDashesAndNoNothingToFix() throws {
        let battery = Battery(percent: 12, charging: false, onBattery: true)
        let r = Recurrence(key: "appHog:Arc", title: "Arc is taking over", kind: .appHog, count: 3, last: T0)
        let s = makeSample(cores: 8, load5: 30, memoryPressure: .warning,
                           swapTotal: 100, swapUsed: 80, diskTotal: 100, diskFree: 5,
                           uptime: 40 * 86400, thermal: .serious, battery: battery)
        let out = recommend(s, issues: [runaway, appHog, orphan], recurrences: [r])
        XCTAssertNil(out.first { $0.text.hasPrefix("Nothing to fix") })
        XCTAssertNotNil(out.first { $0.text.contains("Plug in") })
        XCTAssertNotNil(out.first { $0.text.contains("3 times in 30 days") })
        XCTAssertNil(out.first { $0.text.contains("no single culprit") }, "runaway and appHog are the culprits")
    }
}
