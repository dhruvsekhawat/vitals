import XCTest
@testable import VitalsCore

final class HistoryTests: XCTestCase {

    private var tmp: URL!
    private var stateURL: URL { tmp.appendingPathComponent("state.json") }

    override func setUp() {
        super.setUp()
        tmp = makeTempDir("vitals-history")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    private let swapWarn = makeIssue(kind: .swap, severity: .warn, title: "Swap is high", detail: "80% of 4.0 GB", key: "swap")
    private let swapBad = makeIssue(kind: .swap, severity: .bad, title: "Swap is full", detail: "95% of 4.0 GB", key: "swap")

    // MARK: reconcile

    func testReconcileOpensOnceAndClosesWhenGone() throws {
        let h = History(url: nil)

        let fresh1 = h.reconcile([swapWarn], at: T0)
        XCTAssertEqual(fresh1.opened.map(\.key), ["swap"])
        XCTAssertEqual(h.openIncidents.count, 1)
        XCTAssertEqual(h.openIncidents[0].openedAt, T0)
        XCTAssertNil(h.openIncidents[0].closedAt)
        XCTAssertFalse(h.openIncidents[0].clearedByUser)

        let fresh2 = h.reconcile([swapWarn], at: T0.addingTimeInterval(10))
        XCTAssertTrue(fresh2.opened.isEmpty)
        XCTAssertEqual(h.incidents.count, 1)
        XCTAssertEqual(h.openIncidents.count, 1)

        h.reconcile([], at: T0.addingTimeInterval(20))
        XCTAssertTrue(h.openIncidents.isEmpty)
        XCTAssertEqual(h.incidents.count, 1)
        XCTAssertEqual(h.incidents[0].closedAt, T0.addingTimeInterval(20))
        XCTAssertEqual(h.lastClosedIncident?.key, "swap")

        let fresh3 = h.reconcile([swapWarn], at: T0.addingTimeInterval(400))
        XCTAssertEqual(fresh3.opened.map(\.key), ["swap"])
        XCTAssertEqual(h.incidents.count, 2, "a recurrence is a new incident")
        XCTAssertEqual(h.openIncidents.count, 1)
        XCTAssertEqual(h.openIncidents[0].openedAt, T0.addingTimeInterval(400))
    }

    func testReopensRecentlyClosedIncidentInsteadOfMintingANewOne() throws {
        let h = History(url: nil)
        h.reconcile([swapWarn], at: T0)
        h.reconcile([], at: T0.addingTimeInterval(20))
        XCTAssertEqual(h.incidents[0].closedAt, T0.addingTimeInterval(20))

        let back = h.reconcile([swapWarn], at: T0.addingTimeInterval(20 + History.reopenWindow - 1))
        XCTAssertTrue(back.opened.isEmpty, "a flap is not news")
        XCTAssertEqual(h.incidents.count, 1)
        XCTAssertEqual(h.openIncidents.count, 1)
        XCTAssertEqual(h.openIncidents[0].openedAt, T0, "same incident, original start")
        XCTAssertNil(h.openIncidents[0].closedAt)

        // But one the user cleared is never silently reopened.
        h.markCleared(keys: ["swap"], at: T0.addingTimeInterval(400))
        let after = h.reconcile([swapWarn], at: T0.addingTimeInterval(410))
        XCTAssertEqual(after.opened.map(\.key), ["swap"])
        XCTAssertEqual(h.incidents.count, 2)
    }

    func testReconcileReportsEscalation() throws {
        let h = History(url: nil)
        XCTAssertTrue(h.reconcile([swapWarn], at: T0).escalated.isEmpty)
        let r = h.reconcile([swapBad], at: T0.addingTimeInterval(10))
        XCTAssertEqual(r.escalated.map(\.key), ["swap"])
        XCTAssertTrue(r.opened.isEmpty)
        XCTAssertTrue(h.reconcile([swapBad], at: T0.addingTimeInterval(20)).escalated.isEmpty, "only reported once")
        XCTAssertTrue(h.reconcile([swapWarn], at: T0.addingTimeInterval(30)).escalated.isEmpty, "going down is not an escalation")
        XCTAssertTrue(h.shouldNotify(key: "swap", at: T0))
        XCTAssertFalse(h.shouldNotify(key: "swap", at: T0.addingTimeInterval(1)))
        XCTAssertTrue(h.shouldNotify(key: "swap", at: T0.addingTimeInterval(2), escalation: true), "escalation bypasses the cooldown")
    }

    func testReconcileRatchetsSeverityUpAndKeepsTitleCurrent() throws {
        let h = History(url: nil)
        h.reconcile([swapWarn], at: T0)
        h.reconcile([swapBad], at: T0.addingTimeInterval(10))
        XCTAssertEqual(h.incidents.count, 1)
        XCTAssertEqual(h.incidents[0].severity, .bad)
        XCTAssertEqual(h.incidents[0].title, "Swap is full")
        XCTAssertEqual(h.incidents[0].detail, "95% of 4.0 GB")

        h.reconcile([swapWarn], at: T0.addingTimeInterval(20))
        XCTAssertEqual(h.incidents.count, 1)
        XCTAssertEqual(h.incidents[0].severity, .bad, "severity only ratchets up")
        XCTAssertEqual(h.incidents[0].title, "Swap is high")
        XCTAssertEqual(h.incidents[0].openedAt, T0, "still the original incident")
    }

    func testIdentityIsByKeyNotPids() throws {
        let h = History(url: nil)
        let a = makeIssue(kind: .orphan, severity: .warn, title: "Leaked Claude Code processes", detail: "2 left behind",
                          remedy: .kill([100, 101]), key: "orphan:Claude Code")
        let b = makeIssue(kind: .orphan, severity: .warn, title: "Leaked Claude Code processes", detail: "3 left behind",
                          remedy: .kill([100, 101, 102]), key: "orphan:Claude Code")
        h.reconcile([a], at: T0)
        let fresh = h.reconcile([b], at: T0.addingTimeInterval(5))
        XCTAssertTrue(fresh.opened.isEmpty)
        XCTAssertEqual(h.incidents.count, 1)
        XCTAssertEqual(h.incidents[0].detail, "3 left behind")
    }

    // MARK: markCleared

    func testMarkClearedClosesOnlyNamedOpenIncidents() throws {
        // Huge retention so the save() inside markCleared does not trim 2023-dated incidents.
        let h = History(url: nil, retentionDays: 1_000_000)
        let disk = makeIssue(kind: .disk, severity: .warn, title: "Disk is low", key: "disk")
        h.reconcile([swapWarn, disk], at: T0)
        h.markCleared(keys: ["swap", "not-open"], at: T0.addingTimeInterval(60))

        let swap = try XCTUnwrap(h.incidents.first { $0.key == "swap" })
        XCTAssertEqual(swap.closedAt, T0.addingTimeInterval(60))
        XCTAssertTrue(swap.clearedByUser)

        let diskInc = try XCTUnwrap(h.incidents.first { $0.key == "disk" })
        XCTAssertNil(diskInc.closedAt)
        XCTAssertFalse(diskInc.clearedByUser)
        XCTAssertEqual(h.openIncidents.map(\.key), ["disk"])
    }

    // MARK: snapshot / trend

    func testSnapshotIsRateLimitedTo300Seconds() throws {
        let h = History(url: nil)
        h.snapshot(makeSample(at: T0))
        h.snapshot(makeSample(at: T0.addingTimeInterval(299)))
        XCTAssertEqual(h.snapshots.count, 1)
        h.snapshot(makeSample(at: T0.addingTimeInterval(301)))
        XCTAssertEqual(h.snapshots.count, 2)
        XCTAssertEqual(h.snapshots.map(\.at), [T0, T0.addingTimeInterval(301)])
    }

    func testTrendAveragesLoadAndTakesPeakSwapAndMinDisk() throws {
        let h = History(url: nil)
        // load 1, 2, 3; swap 10, 50, 20; disk free 40, 30, 35 (percent).
        h.snapshot(makeSample(at: T0, load1: 1, swapTotal: 100, swapUsed: 10, diskTotal: 100, diskFree: 40))
        h.snapshot(makeSample(at: T0.addingTimeInterval(600), load1: 2, swapTotal: 100, swapUsed: 50, diskTotal: 100, diskFree: 30))
        h.snapshot(makeSample(at: T0.addingTimeInterval(1200), load1: 3, swapTotal: 100, swapUsed: 20, diskTotal: 100, diskFree: 35))

        let all = try XCTUnwrap(h.trend(hours: 1, now: T0.addingTimeInterval(1200)))
        XCTAssertEqual(all, Trend(avgLoad: 2, peakSwap: 50, minDiskFree: 30))

        // 0.2 h = 720 s window from +1200 reaches back to +480: only the last two.
        let recent = try XCTUnwrap(h.trend(hours: 0.2, now: T0.addingTimeInterval(1200)))
        XCTAssertEqual(recent, Trend(avgLoad: 2.5, peakSwap: 50, minDiskFree: 30))

        XCTAssertNil(h.trend(hours: 1, now: T0.addingTimeInterval(10 * 86400)), "nothing in window")
        XCTAssertNil(History(url: nil).trend(hours: 1, now: T0))
    }

    // MARK: recurrences

    func testRecurrencesCountTrackedKindsOnlyAndGroupByFamily() throws {
        let h = History(url: nil)
        // Same program stuck under a new pid each time: one family.
        let runaways = (1...3).map { makeIssue(kind: .runaway, severity: .bad, title: "Foo is stuck", key: "runaway:Foo#\($0)") }
        let hogV1 = makeIssue(kind: .appHog, severity: .warn, title: "Arc is taking over", key: "appHog:Arc")
        let hogV2 = makeIssue(kind: .appHog, severity: .warn, title: "Arc is taking over (again)", key: "appHog:Arc")

        // Three swap incidents and three runaway incidents, opened at +0, +600, +1200 (past the reopen window).
        for n in 0..<3 {
            h.reconcile([swapWarn, runaways[n]], at: T0.addingTimeInterval(Double(n) * 600))
            h.reconcile([], at: T0.addingTimeInterval(Double(n) * 600 + 60))
        }
        // Two appHog incidents, opened at +1500 and +1900, newest with a different title.
        h.reconcile([hogV1], at: T0.addingTimeInterval(1500))
        h.reconcile([], at: T0.addingTimeInterval(1550))
        h.reconcile([hogV2], at: T0.addingTimeInterval(1900))
        XCTAssertEqual(h.incidents.count, 8)

        let now = T0.addingTimeInterval(3000)
        let recs = h.recurrences(now: now)
        XCTAssertEqual(recs.map(\.key), ["runaway:Foo", "appHog:Arc"], "sorted by count desc; swap is not tracked; pids collapsed")
        XCTAssertEqual(recs[0].count, 3)
        XCTAssertEqual(recs[0].last, T0.addingTimeInterval(1200))
        XCTAssertEqual(recs[0].kind, .runaway)
        XCTAssertEqual(recs[1].count, 2)
        XCTAssertEqual(recs[1].last, T0.addingTimeInterval(1900))
        XCTAssertEqual(recs[1].title, "Arc is taking over (again)", "title comes from the newest incident")

        XCTAssertEqual(h.recurrences(minCount: 3, now: now).map(\.key), ["runaway:Foo"])
        XCTAssertTrue(h.recurrences(window: 100, now: now).isEmpty, "window excludes everything")
        // Window reaching back to +1450 sees only the two appHog openings.
        XCTAssertEqual(h.recurrences(window: 1550, now: now).map(\.key), ["appHog:Arc"])
    }

    // MARK: shouldNotify

    func testShouldNotifyHonoursCooldown() throws {
        let h = History(url: nil)
        XCTAssertTrue(h.shouldNotify(key: "swap", at: T0, cooldown: 1800))
        XCTAssertFalse(h.shouldNotify(key: "swap", at: T0.addingTimeInterval(1799), cooldown: 1800))
        XCTAssertTrue(h.shouldNotify(key: "disk", at: T0.addingTimeInterval(1799), cooldown: 1800), "keys are independent")
        XCTAssertTrue(h.shouldNotify(key: "swap", at: T0.addingTimeInterval(1800), cooldown: 1800))
        XCTAssertFalse(h.shouldNotify(key: "swap", at: T0.addingTimeInterval(1801), cooldown: 1800), "the cooldown restarted")
    }

    // MARK: save / retention

    func testSaveTrimsClosedIncidentsAndOldSnapshotsButNeverOpenIncidents() throws {
        let h = History(url: stateURL, retentionDays: 1)
        let disk = makeIssue(kind: .disk, severity: .warn, title: "Disk is low", key: "disk")
        h.reconcile([swapWarn, disk], at: T0)
        h.reconcile([disk], at: T0.addingTimeInterval(10))          // swap closes at +10
        h.snapshot(makeSample(at: T0))
        XCTAssertTrue(h.shouldNotify(key: "swap", at: T0))

        let farFuture = T0.addingTimeInterval(10 * 86400)
        h.save(now: farFuture)

        XCTAssertEqual(h.incidents.map(\.key), ["disk"], "closed-before-cutoff incident trimmed; open one kept")
        XCTAssertTrue(h.snapshots.isEmpty)
        XCTAssertTrue(h.shouldNotify(key: "swap", at: T0.addingTimeInterval(1)), "notified entry was trimmed too")

        let reloaded = History(url: stateURL, retentionDays: 1)
        XCTAssertEqual(reloaded.incidents.map(\.key), ["disk"])
        XCTAssertNil(reloaded.incidents[0].closedAt)
        XCTAssertTrue(reloaded.snapshots.isEmpty)
    }

    func testPersistenceRoundTrip() throws {
        let h = History(url: stateURL)
        h.reconcile([swapWarn], at: T0)
        h.reconcile([swapBad], at: T0.addingTimeInterval(60))
        h.reconcile([], at: T0.addingTimeInterval(120))
        h.reconcile([swapWarn], at: T0.addingTimeInterval(500))
        h.snapshot(makeSample(at: T0, load1: 2.5))
        h.snapshot(makeSample(at: T0.addingTimeInterval(600), load1: 3.5))
        XCTAssertTrue(h.shouldNotify(key: "swap", at: T0))
        h.save(now: T0.addingTimeInterval(600))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))

        let again = History(url: stateURL)
        XCTAssertEqual(again.incidents, h.incidents)
        XCTAssertEqual(again.incidents.count, 2)
        XCTAssertEqual(again.snapshots, h.snapshots)
        XCTAssertEqual(again.snapshots.count, 2)
        XCTAssertFalse(again.shouldNotify(key: "swap", at: T0.addingTimeInterval(100)), "notified dates survive")
    }

    func testSaveWithoutChangesDoesNotWrite() throws {
        let h = History(url: stateURL)
        h.save(now: T0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
    }

    // MARK: corruption

    func testCorruptFileIsMovedAsideAndHistoryStartsEmpty() throws {
        try "not json".write(to: stateURL, atomically: true, encoding: .utf8)
        let h = History(url: stateURL)
        XCTAssertTrue(h.incidents.isEmpty)
        XCTAssertTrue(h.snapshots.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path), "corrupt file moved, not left in place")

        let names = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
        let aside = names.filter { $0.range(of: #"^state\.corrupt-[0-9]+\.json$"#, options: .regularExpression) != nil }
        XCTAssertEqual(aside.count, 1, "\(names)")
        let moved = try String(contentsOf: tmp.appendingPathComponent(aside[0]), encoding: .utf8)
        XCTAssertEqual(moved, "not json")
    }

    // MARK: on-disk format

    func testDecodesHandWrittenStateFile() throws {
        // Dates are seconds since 2001-01-01 (Foundation's default). 721692800 == T0.
        let json = """
        {
          "version": 1,
          "incidents": [
            {"key": "swap", "kind": "swap", "severity": 1, "title": "Swap is high", "detail": "80% of 4.0 GB",
             "openedAt": 721692800, "clearedByUser": false},
            {"key": "runaway:foo#12", "kind": "runaway", "severity": 2, "title": "foo is stuck", "detail": "99% CPU for 5m",
             "openedAt": 721692800, "closedAt": 721696400, "clearedByUser": true}
          ],
          "snapshots": [
            {"at": 721692800, "load1": 2.5, "memPct": 50, "swapPct": 10, "diskFreePct": 40}
          ],
          "notified": {"swap": 721692800}
        }
        """
        try json.write(to: stateURL, atomically: true, encoding: .utf8)
        let h = History(url: stateURL)

        XCTAssertEqual(h.incidents.count, 2)
        let swap = h.incidents[0]
        XCTAssertEqual(swap.key, "swap")
        XCTAssertEqual(swap.kind, .swap)
        XCTAssertEqual(swap.severity, .warn)
        XCTAssertEqual(swap.title, "Swap is high")
        XCTAssertEqual(swap.detail, "80% of 4.0 GB")
        XCTAssertEqual(swap.openedAt, T0)
        XCTAssertNil(swap.closedAt)
        XCTAssertFalse(swap.clearedByUser)

        let runaway = h.incidents[1]
        XCTAssertEqual(runaway.kind, .runaway)
        XCTAssertEqual(runaway.severity, .bad)
        XCTAssertEqual(runaway.closedAt, T0.addingTimeInterval(3600))
        XCTAssertTrue(runaway.clearedByUser)
        XCTAssertEqual(h.openIncidents.map(\.key), ["swap"])

        XCTAssertEqual(h.snapshots, [Snapshot(at: T0, load1: 2.5, memPct: 50, swapPct: 10, swapUsed: 0, diskFreePct: 40)])
        XCTAssertFalse(h.shouldNotify(key: "swap", at: T0.addingTimeInterval(100)), "notified map decoded")
        XCTAssertTrue(h.shouldNotify(key: "swap", at: T0.addingTimeInterval(1801)))
    }

    func testEncodesDatesAsSecondsSince2001AndEnumsAsRawValues() throws {
        let h = History(url: stateURL)
        h.reconcile([swapBad], at: T0)
        h.save(now: T0)
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        let incidents = try XCTUnwrap(obj?["incidents"] as? [[String: Any]])
        XCTAssertEqual(incidents.count, 1)
        XCTAssertEqual(incidents[0]["openedAt"] as? Double, 721692800)
        XCTAssertEqual(incidents[0]["severity"] as? Int, 2)
        XCTAssertEqual(incidents[0]["kind"] as? String, "swap")
        XCTAssertEqual(obj?["version"] as? Int, 2)
    }
}
