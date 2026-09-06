import Foundation

public struct Recommendation: Identifiable, Sendable, Equatable {
    public enum Action: Sendable, Equatable { case clear, freeDisk, restart, none }
    public let text: String
    public let action: Action
    public let id: String
    public init(_ text: String, _ action: Action = .none, id: String? = nil) {
        self.text = text; self.action = action; self.id = id ?? text
    }
}

/// Plain-language advice derived from the current sample, its issues, and history.
/// Pure: same inputs, same output. No side effects.
public enum Advisor {
    public static func recommend(sample s: Sample, issues: [Issue], recurrences: [Recurrence],
                                 lastIncident: Incident?, thresholds t: Thresholds = Thresholds(), now: Date = Date()) -> [Recommendation] {
        var out: [Recommendation] = []

        for i in issues where i.kind == .runaway {
            let name = i.title.replacingOccurrences(of: " is stuck", with: "")
            out.append(Recommendation("\(name) is pinned at \(i.detail). It will not recover on its own. Kill it.", .clear, id: "rec:\(i.key)"))
        }
        for i in issues where i.kind == .appHog {
            let name = i.title.replacingOccurrences(of: " is taking over", with: "")
            let verb = i.remedy.verb.lowercased()
            out.append(Recommendation("\(name) is using \(i.detail). Close what you are not using, or \(verb) it from here.", .clear, id: "rec:\(i.key)"))
        }
        for i in issues where i.kind == .orphan {
            out.append(Recommendation("\(i.remedy.pids.count) helpers were left running by closed sessions. Clear them.", .clear, id: "rec:\(i.key)"))
        }

        if s.memoryPressure == .critical || s.swapPct >= t.swapBad {
            out.append(Recommendation("Memory is exhausted and macOS is paging \(Format.bytes(s.swapUsed)) to disk. Quit the biggest apps, or restart to reset it.", .restart, id: "rec:memory"))
        } else if s.swapPct >= t.swapWarn {
            out.append(Recommendation("\(Format.bytes(s.swapUsed)) of swap in use, \(Int(s.swapPct))% of your RAM. A restart is the only thing that empties it.", .restart, id: "rec:swap"))
        } else if s.uptimeDays >= t.uptimeWarnDays {
            out.append(Recommendation("\(Int(s.uptimeDays)) days since a restart. Reboot before things pile up again.", .restart, id: "rec:uptime"))
        }

        if s.diskKnown && s.diskFreePct < t.diskWarnFreePct {
            out.append(Recommendation("Disk is \(Int(100 - s.diskFreePct))% full. macOS gets slow under about 15% free.", .freeDisk, id: "rec:disk"))
        }

        if s.uptime < t.bootGrace && s.load5 > Double(s.cores) * 1.5 {
            out.append(Recommendation("Just restarted. macOS is rebuilding Spotlight and Messages indexes, so load is high for a few minutes. Nothing to do.", id: "rec:boot"))
        } else if s.load5 > Double(s.cores) * 1.5 && !issues.contains(where: { $0.kind == .runaway || $0.kind == .appHog || $0.kind == .busy }) {
            out.append(Recommendation("5-minute load is \(Int(s.load5)) on \(s.cores) cores with no single culprit. Too many apps open at once.", id: "rec:load"))
        }

        if let b = s.battery, b.onBattery, !s.lowPowerMode, issues.contains(where: { $0.kind == .appHog || $0.kind == .runaway || $0.kind == .thermal }) {
            out.append(Recommendation("On battery at \(b.percent)% with the CPU busy. Plug in, or turn on Low Power Mode.", id: "rec:battery"))
        }

        for r in recurrences {
            // "Cursor · Helper (Renderer) is stuck" reads badly inside a sentence; use the subject alone.
            let subject = r.title
                .replacingOccurrences(of: " is stuck", with: "")
                .replacingOccurrences(of: " is taking over", with: "")
                .replacingOccurrences(of: " is working hard", with: "")
            let lead: String
            switch r.kind {
            case .runaway: lead = "\(subject) has got stuck \(r.count) times in 30 days."
            case .appHog: lead = "\(subject) has taken over the machine \(r.count) times in 30 days."
            case .busy: lead = "\(subject) has run flat out \(r.count) times in 30 days."
            case .orphan: lead = "\(r.title) have come back \(r.count) times in 30 days."
            default: lead = "\(r.title) has happened \(r.count) times in 30 days."
            }
            var hint = " That is a pattern, not a one-off."
            let lower = subject.lowercased()
            if r.kind == .runaway && (lower.contains("renderer") || lower.contains("helper")) {
                hint += " Usually a window or extension that never finished loading. Update the app and close windows you are not using."
            } else if r.kind == .orphan {
                hint += " They are left behind when sessions close. Restarting the parent app now and then stops the buildup."
            } else if r.kind == .appHog {
                hint += " Consider fewer windows or tabs in it, or check its extensions."
            }
            out.append(Recommendation(lead + hint, id: "rec:recur:\(r.key)"))
        }

        if out.isEmpty {
            if let last = lastIncident {
                out.append(Recommendation("Nothing to fix. Last problem: \(last.title), \(Format.ago(last.openedAt, now: now)).", id: "rec:clear"))
            } else {
                out.append(Recommendation("Nothing to fix.", id: "rec:clear"))
            }
        }
        return out
    }
}
