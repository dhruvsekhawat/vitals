import SwiftUI
import VitalsCore

extension Severity {
    var color: Color {
        switch self {
        case .ok: return Color(red: 0.20, green: 0.72, blue: 0.40)
        case .warn: return Color(red: 0.95, green: 0.68, blue: 0.10)
        case .bad: return Color(red: 0.90, green: 0.25, blue: 0.22)
        }
    }
}

struct PanelView: View {
    @ObservedObject var engine: Engine
    @Environment(\.openWindow) private var openWindow
    private var st: ViewState { engine.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 8)
            if let s = st.sample { stats(s) } else { Text("Sampling").foregroundStyle(.secondary) }
            if !st.topApps.isEmpty, let s = st.sample {
                Divider().padding(.vertical, 8)
                topApps(s)
            }
            if !st.issues.isEmpty {
                Divider().padding(.vertical, 8)
                issues
            }
            Divider().padding(.vertical, 8)
            recommendations
            Divider().padding(.vertical, 8)
            footer
        }
        .padding(14)
        .frame(width: 340)
        .font(.system(size: 12))
        .onAppear { engine.panelVisible = true }
        .onDisappear { engine.panelVisible = false }
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            Text("Vitals").font(.system(size: 14, weight: .semibold))
            Spacer()
            Circle().fill(st.severity.color).frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(statusText).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        let n = st.issues.count
        if n == 0 { return "All clear" }
        return n == 1 ? "1 issue" : "\(n) issues"
    }

    private func stats(_ s: Sample) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            row("Load", String(format: "%.1f", s.load1), sub: "\(s.cores) cores",
                tone: s.load1 > Double(s.cores) * 1.5 ? .warn : .ok)
            row("Memory", "\(Int(s.memPct))%", sub: memSub(s),
                tone: s.memoryPressure == .critical ? .bad : s.memoryPressure == .warning ? .warn : .ok)
            row("Swap", s.swapUsed == 0 ? "none" : Format.bytes(s.swapUsed),
                sub: s.swapUsed == 0 ? "" : "\(Int(s.swapPct))% of RAM",
                tone: s.swapPct >= 50 ? .bad : s.swapPct >= 25 ? .warn : .ok)
            if s.diskKnown {
                row("Disk", "\(Format.bytes(UInt64(s.diskFree))) free", sub: "\(Int(100 - s.diskFreePct))% used",
                    tone: s.diskFreePct < 8 ? .bad : s.diskFreePct < 15 ? .warn : .ok)
            }
            row("Uptime", Format.uptime(s.uptime), sub: "",
                tone: s.uptimeDays >= 30 ? .bad : s.uptimeDays >= 14 ? .warn : .ok)
            if let b = s.battery {
                row("Power", b.onBattery ? "Battery \(b.percent)%" : (b.charging ? "Charging \(b.percent)%" : "Plugged in"),
                    sub: s.lowPowerMode ? "Low Power Mode" : "", tone: b.onBattery && b.percent <= 20 ? .warn : .ok)
            }
            if s.thermal != .nominal {
                row("Thermal", thermalText(s.thermal), sub: "", tone: s.thermal == .fair ? .warn : .bad)
            }
        }
    }

    private func memSub(_ s: Sample) -> String {
        let base = "\(Format.bytes(s.memUsed)) of \(Format.bytes(s.memTotal))"
        switch s.memoryPressure {
        case .normal: return base
        case .warning: return base + ", pressure high"
        case .critical: return base + ", pressure critical"
        }
    }

    private func row(_ label: String, _ value: String, sub: String, tone: Severity) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.leading)
            HStack(spacing: 6) {
                Text(value).fontWeight(.medium).foregroundStyle(tone == .ok ? Color.primary : tone.color)
                if !sub.isEmpty { Text(sub).foregroundStyle(.tertiary) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Per-app rollup. CPU is a share of the whole machine: 25% means a quarter of all cores.
    private func topApps(_ s: Sample) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(st.topApps) { a in
                let share = a.cpu / Double(max(s.cores, 1))
                HStack(spacing: 8) {
                    Text(a.name).fontWeight(.medium).lineLimit(1)
                    Text("\(a.procs) proc\(a.procs == 1 ? "" : "s")").foregroundStyle(.tertiary)
                    Spacer()
                    Text(String(format: "%.0f%% CPU", share))
                        .foregroundStyle(share >= 25 ? Severity.bad.color : share >= 10 ? Severity.warn.color : Color.primary)
                        .frame(width: 64, alignment: .trailing)
                    Text(Format.bytes(a.rss)).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(a.name), \(a.procs) processes, \(Int(share)) percent CPU, \(Format.bytes(a.rss))")
            }
        }
    }

    private var issues: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(st.issues) { i in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(i.severity.color).frame(width: 6, height: 6).padding(.top, 5).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(i.title).fontWeight(.medium)
                        Text(i.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if i.remedy.isActionable {
                        Button(i.remedy.verb) { engine.clear(key: i.key) }
                            .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                            .disabled(engine.busy != nil)
                            .help(helpText(i.remedy))
                    }
                }
            }
        }
    }

    private func helpText(_ r: Remedy) -> String {
        switch r {
        case .kill(let p): return p.count == 1 ? "Stop this process (SIGTERM, then SIGKILL)" : "Stop these \(p.count) processes"
        case .quitApp(let name, _): return "Ask \(name) to quit normally so it can save its state. It is never force-killed from here."
        case .none: return ""
        }
    }

    private var recommendations: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(st.recommendations) { r in
                HStack(alignment: .top, spacing: 6) {
                    Text("→").foregroundStyle(.tertiary).accessibilityHidden(true)
                    Text(r.text).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let t = st.trend24h {
                Text(String(format: "Last 24h: load avg %.1f, swap peak %@, disk low %d%% free", t.avgLoad, t.peakSwap == 0 ? "none" : Format.bytes(t.peakSwap), Int(t.minDiskFree)))
                    .foregroundStyle(.tertiary).padding(.top, 2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                let n = st.actionable.count
                Button(n == 0 ? "Clear" : "Clear \(n)") { engine.clear() }
                    .disabled(n == 0 || engine.busy != nil)
                    .help("Apply every fix listed above")
                Button("Storage…") { openStorage() }
                    .help("See what is filling the disk, graded by how safe it is to remove")
                Button("Restart…") { engine.restart() }
                    .help("Ask macOS to restart. You get the usual confirmation.")
                Spacer()
                Button("Quit") { engine.quit() }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .disabled(engine.busy != nil)
                    .help("Quit Vitals until next login")
            }
            .controlSize(.small)
            HStack {
                if let b = engine.busy {
                    ProgressView().controlSize(.mini)
                    Text(b).foregroundStyle(.secondary)
                } else if !engine.notificationsAllowed {
                    Text("Notifications are off. Enable them in System Settings.").foregroundStyle(.secondary)
                } else if let r = engine.lastResult {
                    Text(r).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Toggle("Start at login", isOn: Binding(get: { engine.launchAtLogin }, set: { engine.setLaunchAtLogin($0) }))
                    .toggleStyle(.checkbox).controlSize(.mini).foregroundStyle(.secondary)
                    .help("Also relaunches Vitals if it ever crashes")
            }
        }
    }

    private func openStorage() {
        openWindow(id: "storage")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func thermalText(_ t: Thermal) -> String {
        switch t {
        case .nominal: return "normal"
        case .fair: return "warm"
        case .serious: return "hot"
        case .critical: return "critical"
        }
    }
}

/// Menu bar label: a colored dot plus the issue count, drawn as an image so the color
/// survives the menu bar's template-image treatment.
func menuBarImage(severity: Severity, count: Int) -> NSImage {
    let text = count > 0 ? " \(count)" : ""
    let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
    let textSize = (text as NSString).size(withAttributes: attrs)
    let dot: CGFloat = 9
    let size = NSSize(width: dot + textSize.width + 2, height: 18)
    let img = NSImage(size: size, flipped: false) { rect in
        NSColor(severity.color).setFill()
        NSBezierPath(ovalIn: NSRect(x: 1, y: (rect.height - dot) / 2, width: dot, height: dot)).fill()
        (text as NSString).draw(at: NSPoint(x: dot + 2, y: (rect.height - textSize.height) / 2), withAttributes: attrs)
        return true
    }
    img.isTemplate = false
    let status = severity == .ok ? "all clear" : (count == 1 ? "1 issue" : "\(count) issues")
    img.accessibilityDescription = "Vitals, \(status)"
    return img
}
