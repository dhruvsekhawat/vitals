import SwiftUI
import VitalsCore

/// Drives the Storage window. The scan runs on a background queue; the view only ever sees
/// finished reports. Selection defaults: safe on, everything else off.
@MainActor
final class StorageModel: ObservableObject {
    @Published private(set) var report: StorageReport?
    @Published private(set) var scanning = false
    @Published private(set) var status = ""
    @Published var selected: Set<String> = []
    @Published private(set) var lastOutcome: String?
    @Published var confirmEmpty = false
    @Published var expanded: Set<StorageGrade> = []

    private var scanner: StorageScanner?
    private let queue = DispatchQueue(label: "com.dhruv.vitals.storage", qos: .userInitiated)

    var selectedItems: [StorageItem] { report?.items.filter { selected.contains($0.id) } ?? [] }
    var selectedBytes: UInt64 { selectedItems.reduce(0) { $0 + $1.bytes } }

    func scan() {
        guard !scanning else { return }
        scanner?.cancel()
        scanning = true; status = "Starting"; lastOutcome = nil
        let s = StorageScanner()
        scanner = s
        let previous = report
        let previousSelection = selected
        queue.async { [weak self] in
            let r = s.scan { line in Task { @MainActor in self?.status = line } }
            Task { @MainActor in
                guard let self, self.scanner === s else { return }   // a newer scan superseded this one
                guard let r else { self.scanning = false; self.status = ""; return }   // cancelled: keep the old report
                // Keep the user's choices: what they ticked stays ticked, what they unticked stays unticked,
                // and only rows that are new since last time get the safe-by-default treatment.
                let ids = Set(r.items.map(\.id))
                let known = Set(previous?.items.map(\.id) ?? [])
                let fresh = r.items.filter { $0.grade == .safe && !known.contains($0.id) }.map(\.id)
                self.selected = previousSelection.intersection(ids).union(fresh)
                self.scanning = false
                self.status = ""
            }
        }
    }

    /// Stop the current scan. The next `scan()` starts fresh instead of waiting on a cancelled one.
    func cancel() {
        scanner?.cancel()
        scanner = nil
        scanning = false
        status = ""
    }

    func setAll(_ grade: StorageGrade, on: Bool) {
        guard let r = report else { return }
        let ids = r.items(grade).map(\.id)
        if on { selected.formUnion(ids) } else { selected.subtract(ids) }
    }

    func trashSelected() {
        let items = selectedItems
        guard !items.isEmpty, !scanning else { return }
        scanning = true; status = "Moving to Trash"
        queue.async { [weak self] in
            let o = StorageActions.trash(items)
            let trash = StorageActions.trashBytes()
            let disk = StorageScanner.disk()
            Task { @MainActor in
                guard let self else { return }
                self.scanning = false; self.status = ""
                var msg = "Moved \(Format.bytes(o.bytes)) to the Trash, as Finder counts it. Empty the Trash to get the space back."
                if !o.failed.isEmpty { msg = "Could not move " + o.failed.map { "\(($0.path as NSString).lastPathComponent) (\($0.reason))" }.joined(separator: ", ") + ". " + msg }
                self.lastOutcome = msg
                // Drop the rows that went; no need to rescan the whole disk for that.
                let gone = Set(o.trashed)
                if var r = self.report {
                    r.items.removeAll { gone.contains($0.path) }
                    r.trashBytes = trash; r.diskFree = disk.free; r.diskTotal = disk.total
                    self.report = r
                }
                self.selected.subtract(gone)
            }
        }
    }

    func emptyTrash() {
        guard !scanning else { return }
        scanning = true; status = "Finder is emptying the Trash"
        let had = report?.trashBytes ?? 0
        queue.async { [weak self] in
            let err = StorageActions.emptyTrash()
            let trash = StorageActions.trashBytes()
            let disk = StorageScanner.disk()
            Task { @MainActor in
                guard let self else { return }
                self.scanning = false; self.status = ""
                self.lastOutcome = err.map { "Could not empty the Trash: \($0). Use Finder." } ?? "Emptied the Trash. \(Format.bytes(had)) back."
                if var r = self.report { r.trashBytes = trash; r.diskFree = disk.free; r.diskTotal = disk.total; self.report = r }
            }
        }
    }
}

struct StorageView: View {
    @ObservedObject var model: StorageModel
    /// Off for `--snapshot-storage`: ImageRenderer draws a ScrollView blank.
    var scrollable = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(20)
            Divider()
            if let r = model.report {
                let list = VStack(alignment: .leading, spacing: 18) {
                    ForEach(StorageGrade.allCases, id: \.self) { g in
                        let items = r.items(g)
                        if !items.isEmpty { section(g, items: items, total: r.total(g)) }
                    }
                    if r.items.isEmpty {
                        Text("Nothing worth clearing. Your disk is tidy.").foregroundStyle(.secondary).padding(.top, 8)
                    }
                }
                .padding(20)
                if scrollable { ScrollView { list } } else { list }
            } else {
                Spacer()
                HStack { Spacer(); VStack(spacing: 8) { ProgressView(); Text(model.status.isEmpty ? "Scanning" : model.status).foregroundStyle(.secondary) }; Spacer() }
                Spacer()
            }
            Divider()
            footer.padding(16)
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 520, idealHeight: 720)
        .font(.system(size: 13))
        .onAppear { if model.report == nil { model.scan() } }
        .onDisappear { model.cancel() }
        .alert("Empty the Trash?", isPresented: $model.confirmEmpty) {
            Button("Empty Trash", role: .destructive) { model.emptyTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes everything in the Trash for good, including anything you put there yourself, and the Trash of any connected drive. " + (model.report?.trashBytes.map { "\(Format.bytes($0)) comes back." } ?? "Size unknown."))
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Storage").font(.system(size: 20, weight: .semibold))
                Spacer()
                if let r = model.report {
                    Text("\(Format.bytes(UInt64(max(r.diskFree, 0)))) free of \(Format.bytes(UInt64(max(r.diskTotal, 0))))").foregroundStyle(.secondary)
                }
            }
            if let r = model.report, r.diskTotal > 0 {
                let used = 1 - Double(r.diskFree) / Double(r.diskTotal)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(used > 0.92 ? Severity.bad.color : used > 0.85 ? Severity.warn.color : Color.accentColor)
                            .frame(width: geo.size.width * used)
                        if model.selectedBytes > 0 {
                            // The slice you are about to get back, drawn from the right edge of "used".
                            let slice = geo.size.width * Double(model.selectedBytes) / Double(r.diskTotal)
                            Rectangle().fill(Color.white.opacity(0.55))
                                .frame(width: min(slice, geo.size.width * used), height: 8)
                                .offset(x: max(geo.size.width * used - min(slice, geo.size.width * used), 0))
                        }
                    }
                }
                .frame(height: 8)
                .accessibilityLabel("Disk \(Int(used * 100)) percent full")
            }
            HStack(spacing: 8) {
                if model.scanning {
                    ProgressView().controlSize(.small)
                    Text(model.status).foregroundStyle(.secondary)
                } else if let r = model.report {
                    Text("Scanned \(Format.ago(r.scannedAt))").foregroundStyle(.secondary)
                    Button("Rescan") { model.scan() }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                }
                Spacer()
                if let o = model.lastOutcome { Text(o).foregroundStyle(.secondary).lineLimit(2) }
            }
            .font(.system(size: 12))
        }
    }

    // MARK: Sections

    private func section(_ g: StorageGrade, items: [StorageItem], total: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(g.title.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(gradeColor(g)).kerning(0.6)
                Spacer()
                Text(Format.bytes(total)).font(.system(size: 13, weight: .semibold))
                if g != .review {
                    let all = items.allSatisfy { model.selected.contains($0.id) }
                    Button(all ? "None" : "All") { model.setAll(g, on: !all) }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.system(size: 12))
                        .help(all ? "Deselect every item in this group" : "Select every item in this group")
                }
            }
            .padding(.bottom, 2)
            // Never hide a selected row: what the button will act on must be on screen.
            let shown = model.expanded.contains(g) ? items : items.enumerated().filter { $0.offset < 10 || model.selected.contains($0.element.id) }.map(\.element)
            ForEach(shown) { i in row(i) }
            if items.count > shown.count {
                Button("\(items.count - shown.count) more") { model.expanded.insert(g) }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.system(size: 12)).padding(.top, 2)
            }
        }
    }

    private func row(_ i: StorageItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            let on = model.selected.contains(i.id)
            Button { if on { model.selected.remove(i.id) } else { model.selected.insert(i.id) } } label: {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15)).foregroundStyle(on ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain).padding(.top, 1)
            .accessibilityLabel(i.label).accessibilityValue(on ? "selected" : "not selected")
            VStack(alignment: .leading, spacing: 2) {
                Text(i.label).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Text(i.explanation).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.bytes(i.bytes)).fontWeight(.medium).monospacedDigit()
                if let m = i.modified { Text(Format.ago(m)).font(.system(size: 11)).foregroundStyle(.tertiary) }
            }
            .frame(width: 84, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .contextMenu { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: i.path)]) } }
        .help(i.path)
    }

    private func gradeColor(_ g: StorageGrade) -> Color {
        switch g {
        case .safe: return Severity.ok.color
        case .rebuildable: return Severity.warn.color
        case .review: return .secondary
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            let n = model.selectedItems.count
            Button(n == 0 ? "Move to Trash" : "Move \(Format.bytes(model.selectedBytes)) to Trash") { model.trashSelected() }
                .disabled(n == 0 || model.scanning)
                .help("Moves the selected items to the Trash. Nothing is deleted until you empty it.")
            Text(n == 0 ? "Nothing selected" : "\(n) item\(n == 1 ? "" : "s")").foregroundStyle(.secondary)
            Spacer()
            if let r = model.report {
                if let t = r.trashBytes {
                    if t > 0 { Text("Trash holds \(Format.bytes(t))").foregroundStyle(.secondary) }
                } else {
                    Text("Trash size unknown. Allow Vitals to control Finder in System Settings, Privacy and Security, Automation.")
                        .foregroundStyle(.secondary).font(.system(size: 11)).lineLimit(2).frame(maxWidth: 260)
                }
                if (r.trashBytes ?? 1) > 0 {
                    Button("Empty Trash") { model.confirmEmpty = true }.disabled(model.scanning)
                        .help("Asks Finder to delete everything in the Trash. This cannot be undone.")
                }
            }
        }
        .controlSize(.regular)
    }
}
