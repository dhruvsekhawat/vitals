import SwiftUI
import VitalsCore

@main
struct VitalsApp: App {
    @StateObject private var engine: Engine

    init() {
        let args = CommandLine.arguments
        if args.contains("--version") {
            print("Vitals \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
            exit(0)
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Self.snapshot(to: args[i + 1])   // never returns
        }
        if let i = args.firstIndex(of: "--snapshot-storage"), i + 1 < args.count {
            Self.snapshotStorage(to: args[i + 1])   // never returns
        }
        // One instance only: the LaunchAgent and a manual `open` can race at install time.
        let me = ProcessInfo.processInfo.processIdentifier
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.dhruv.vitals").contains(where: { $0.processIdentifier != me }) {
            exit(0)
        }
        _engine = StateObject(wrappedValue: Engine())
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(engine: engine)
        } label: {
            Image(nsImage: menuBarImage(severity: engine.state.severity, count: engine.state.issues.count))
        }
        .menuBarExtraStyle(.window)

        Window("Storage", id: "storage") {
            StorageView(model: engine.storage)
        }
        .defaultSize(width: 600, height: 720)
        .windowResizability(.contentMinSize)
    }

    /// `Vitals --snapshot-storage out.png` runs a real scan and renders the Storage window to a PNG.
    @MainActor
    private static func snapshotStorage(to path: String) -> Never {
        let model = StorageModel()
        model.scan()
        let deadline = Date().addingTimeInterval(180)
        while model.report == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        let view = StorageView(model: model, scrollable: false).frame(width: 600).background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let img = renderer.nsImage, let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        if let r = model.report {
            for g in StorageGrade.allCases { for i in r.items(g) { FileHandle.standardError.write("\(g): \(i.label) \(Format.bytes(i.bytes))\n".data(using: .utf8)!) } }
        }
        exit(0)
    }

    /// `Vitals --snapshot out.png` renders the panel once to a PNG and exits. Lets the UI be
    /// checked from a shell without screen-recording permission. Prints the per-app rollup to stderr.
    @MainActor
    private static func snapshot(to path: String) -> Never {
        let engine = Engine(headless: true)
        // Two samples spaced apart so per-process CPU is a real delta, not a lifetime average.
        // Sampling is asynchronous, so pump the run loop while waiting.
        func pump(_ seconds: TimeInterval) {
            let until = Date().addingTimeInterval(seconds)
            while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        pump(1.5)
        engine.tick()
        pump(1.0)
        if let s = engine.state.sample {
            FileHandle.standardError.write("procs=\(s.procs.count) cores=\(s.cores) load=\(s.load1)\n".data(using: .utf8)!)
            for a in engine.state.topApps {
                FileHandle.standardError.write("\(a.name) procs=\(a.procs) cpu=\(Int(a.cpu))% rss=\(Format.bytes(a.rss))\n".data(using: .utf8)!)
            }
            for i in engine.state.issues { FileHandle.standardError.write("issue: \(i.title): \(i.detail)\n".data(using: .utf8)!) }
        }
        let view = PanelView(engine: engine).background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let img = renderer.nsImage, let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        exit(0)
    }
}
