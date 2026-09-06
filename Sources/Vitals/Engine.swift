import Foundation
import AppKit
import os
import VitalsCore

/// Everything the panel renders, produced on the sampling queue and handed to the main actor whole.
struct ViewState {
    var sample: Sample?
    var issues: [Issue] = []
    var topApps: [AppUsage] = []
    var recommendations: [Recommendation] = []
    var recurrences: [Recurrence] = []
    var trend24h: Trend?
    var lastIncident: Incident?

    var severity: Severity { issues.map(\.severity).max() ?? .ok }
    var actionable: [Issue] { issues.filter { $0.remedy.isActionable } }
}

/// Sampler, rules and history together. Every method must be called on `queue`; nothing
/// here is otherwise synchronized. `@unchecked Sendable` states that contract to the compiler.
final class Pipeline: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.dhruv.vitals.pipeline", qos: .utility)
    private let sampler = Sampler()
    private let rules: Rules
    private let history: History

    init(thresholds: Thresholds, historyURL: URL?) {
        rules = Rules(thresholds: thresholds)
        history = History(url: historyURL)
    }

    struct Result {
        let view: ViewState
        /// Issues that are new and past their notification cooldown.
        let notify: [Issue]
    }

    func run() -> Result {
        dispatchPrecondition(condition: .onQueue(queue))
        let s = sampler.sample()
        let issues = rules.evaluate(s)
        let fresh = history.reconcile(issues, at: s.at)
        history.snapshot(s)
        let recurrences = history.recurrences()
        let last = history.lastClosedIncident
        let recs = Advisor.recommend(sample: s, issues: issues, recurrences: recurrences, lastIncident: last, thresholds: rules.thresholds)
        let notify = fresh.filter { $0.severity >= .warn && history.shouldNotify(key: $0.key, at: s.at) }
        let view = ViewState(sample: s, issues: issues, topApps: AppUsage.top(s.procs, cores: s.cores),
                             recommendations: recs, recurrences: recurrences, trend24h: history.trend(hours: 24), lastIncident: last)
        return Result(view: view, notify: notify)
    }

    /// - Returns: number of processes that are gone afterwards.
    func apply(_ issues: [Issue]) -> Int {
        dispatchPrecondition(condition: .onQueue(queue))
        var gone = 0
        for i in issues {
            switch i.remedy {
            case .kill(let pids): gone += Remedies.terminate(pids).count
            case .quitApp(let name, let pids): gone += Remedies.quitApp(named: name, pids: pids).count
            case .none: break
            }
        }
        history.markCleared(keys: issues.map(\.key), at: Date())
        return gone
    }

    func wake() {
        dispatchPrecondition(condition: .onQueue(queue))
        sampler.resetDeltas()
        rules.resetTimers()
    }

    func save() {
        dispatchPrecondition(condition: .onQueue(queue))
        history.save()
    }
}

/// Owns the sampling loop and the UI-facing state. Main actor only.
@MainActor
final class Engine: ObservableObject {
    @Published private(set) var state = ViewState()
    @Published private(set) var busy: String?
    @Published private(set) var lastResult: String?
    @Published private(set) var launchAtLogin = false
    @Published private(set) var notificationsAllowed = true
    /// True while the popover is showing. Sampling speeds up so numbers feel live.
    var panelVisible = false { didSet { if panelVisible != oldValue { reschedule() } } }

    private let pipeline: Pipeline
    private let notifier: Notifier?
    private var timer: DispatchSourceTimer?
    private var ticks = 0
    private var observers: [NSObjectProtocol] = []
    private let log = Logger(subsystem: "com.dhruv.vitals", category: "engine")

    /// - Parameter headless: no timer, notifications, or login-item changes (used by `--snapshot`).
    init(headless: Bool = false) {
        pipeline = Pipeline(thresholds: Thresholds.load(from: .standard), historyURL: History.defaultURL)
        notifier = headless ? nil : Notifier()
        notifier?.onClear = { [weak self] key in self?.clear(key: key) }

        tick()
        guard !headless else { return }

        launchAtLogin = LoginItem.isEnabled
        if !launchAtLogin && !UserDefaults.standard.bool(forKey: "loginItemDeclined") { setLaunchAtLogin(true) }
        notifier?.requestAuthorization { [weak self] ok in self?.notificationsAllowed = ok }
        reschedule()

        let wc = NSWorkspace.shared.notificationCenter
        observers.append(wc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let p = self.pipeline
            p.queue.async { p.wake() }
            self.log.notice("woke from sleep; timers reset")
        })
        observers.append(NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.tick()
        })
    }

    // MARK: - Sampling

    private var interval: TimeInterval {
        if panelVisible { return 2 }
        if state.sample?.battery?.onBattery == true { return 15 }
        return 5
    }

    private func reschedule() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: pipeline.queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(500))
        let p = pipeline
        t.setEventHandler { [weak self] in
            let r = p.run()
            Task { @MainActor in self?.publish(r) }
        }
        t.resume()
        timer = t
    }

    /// Sample now, off the main thread, and publish when done.
    func tick() {
        let p = pipeline
        p.queue.async { [weak self] in
            let r = p.run()
            Task { @MainActor in self?.publish(r) }
        }
    }

    private func publish(_ r: Pipeline.Result) {
        let wasOnBattery = state.sample?.battery?.onBattery
        state = r.view
        for i in r.notify { notifier?.post(i) }
        if wasOnBattery != r.view.sample?.battery?.onBattery { reschedule() }
        ticks += 1
        if ticks % 12 == 0 { let p = pipeline; p.queue.async { p.save() } }
    }

    // MARK: - Remedies

    /// Apply the remedy for one issue, or for every actionable issue when `key` is nil.
    func clear(key: String? = nil) {
        let targets = state.issues.filter { $0.remedy.isActionable && (key == nil || $0.key == key) }
        guard !targets.isEmpty, busy == nil else { return }
        busy = targets.count == 1 ? "\(targets[0].remedy.verb)ing \(targets[0].title)" : "Clearing \(targets.count) issues"
        let p = pipeline
        p.queue.async { [weak self] in
            let gone = p.apply(targets)
            Thread.sleep(forTimeInterval: 0.5)
            let r = p.run()
            Task { @MainActor in
                self?.busy = nil
                self?.lastResult = gone == 1 ? "Stopped 1 process" : "Stopped \(gone) processes"
                self?.publish(r)
            }
        }
    }

    func freeDisk() {
        guard busy == nil else { return }
        busy = "Freeing disk"
        let p = pipeline
        p.queue.async { [weak self] in
            let report = Remedies.purgeCaches { msg in Task { @MainActor in self?.busy = msg } }
            let r = p.run()
            Task { @MainActor in
                self?.busy = nil
                self?.lastResult = report.summary
                self?.publish(r)
            }
        }
    }

    func restart() {
        if let err = Remedies.requestRestart() { lastResult = err.localizedDescription }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            try LoginItem.set(on, executable: Bundle.main.executablePath ?? CommandLine.arguments[0])
            UserDefaults.standard.set(!on, forKey: "loginItemDeclined")
        } catch {
            lastResult = "Start at login failed: \(error.localizedDescription)"
        }
        launchAtLogin = LoginItem.isEnabled
    }

    func quit() {
        let p = pipeline
        p.queue.sync { p.save() }
        NSApp.terminate(nil)
    }
}
