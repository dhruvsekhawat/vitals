import Foundation

public struct Recommendation: Identifiable, Sendable, Equatable {
    public enum Action: Sendable, Equatable { case clear, freeDisk, restart, none }
    public let text: String
    public let action: Action
    public var id: String { text }
    public init(_ text: String, _ action: Action = .none) { self.text = text; self.action = action }
}

/// Plain-language advice derived from the current sample, its issues, and history.
/// Pure: same inputs, same output. No side effects.
public enum Advisor {
    public static func recommend(sample s: Sample, issues: [Issue], recurrences: [Recurrence],
                                 lastIncident: Incident?, thresholds t: Thresholds = Thresholds(), now: Date = Date()) -> [Recommendation] {
        var out: [Recommendation] = []

        for i in issues where i.kind == .runaway {
            out.append(Recommendation("\(i.title.replacingOccurrences(of: " is stuck", with: "")) is pinned at \(i.detail). It will not recover on its own. Kill it.", .clear))
        }
        for i in issues where i.kind == .appHog {
            let name = i.title.replacingOccurrences(of: " is taking over", with: "")
            out.append(Recommendation("\(name) is using \(i.detail). Close what you are not using, or quit it from here.", .clear))
        }
        for i in issues where i.kind == .orphan {
            out.append(Recommendation("\(i.remedy.pids.count) helpers were left running by closed sessions. Clear them.", .clear))
        }

        if s.memoryPressure == .critical || s.swapPct >= t.swapBad {
            out.append(Recommendation("Memory is exhausted and macOS is paging to disk. Quit the biggest apps, or restart to reset it.", .restart))
        } else if s.swapPct >= t.swapWarn {
            out.append(Recommendation("Swap is \(Int(s.swapPct))% full. A restart is the only thing that empties it.", .restart))
        } else if s.uptimeDays >= t.uptimeWarnDays {
            out.append(Recommendation("\(Int(s.uptimeDays)) days since a restart. Reboot before things pile up again.", .restart))
        }

        if s.diskFreePct < t.diskWarnFreePct {
            out.append(Recommendation("Disk is \(Int(100 - s.diskFreePct))% full. macOS gets slow under about 15% free.", .freeDisk))
        }

        if s.uptime < t.bootGrace && s.load5 > Double(s.cores) * 1.5 {
            out.append(Recommendation("Just restarted. macOS is rebuilding Spotlight and Messages indexes, so load is high for a few minutes. Nothing to do."))
        } else if s.load5 > Double(s.cores) * 1.5 && !issues.contains(where: { $0.kind == .runaway || $0.kind == .appHog || $0.kind == .busy }) {
            out.append(Recommendation("5-minute load is \(Int(s.load5)) on \(s.cores) cores with no single culprit. Too many apps open at once."))
        }

        if let b = s.battery, b.onBattery, !s.lowPowerMode, issues.contains(where: { $0.kind == .appHog || $0.kind == .runaway || $0.kind == .thermal }) {
            out.append(Recommendation("On battery at \(b.percent)% with the CPU busy. Plug in, or turn on Low Power Mode."))
        }

        for r in recurrences {
            var hint = ""
            let t = r.title.lowercased()
            if r.kind == .runaway && (t.contains("renderer") || t.contains("helper")) {
                hint = " Usually a window or extension that never finished loading. Update the app and close windows you are not using."
            } else if r.kind == .orphan {
                hint = " They are left behind when sessions close. Restarting the parent app now and then stops the buildup."
            } else if r.kind == .appHog {
                hint = " Consider fewer windows or tabs in it, or check its extensions."
            }
            out.append(Recommendation("\(r.title) has come back \(r.count) times in 30 days. That is a pattern, not a one-off.\(hint)"))
        }

        if out.isEmpty {
            if let last = lastIncident {
                out.append(Recommendation("Nothing to fix. Last problem: \(last.title), \(Format.ago(last.openedAt, now: now))."))
            } else {
                out.append(Recommendation("Nothing to fix."))
            }
        }
        return out
    }
}
