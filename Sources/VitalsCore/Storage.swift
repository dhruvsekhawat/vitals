import Foundation
import os

/// How safe it is to remove something.
public enum StorageGrade: Int, Codable, Sendable, Comparable, CaseIterable {
    /// Rebuilds itself. Caches, build products, logs.
    case safe = 0
    /// Comes back with a reinstall, a rebuild, or a download: node_modules, virtualenvs, simulators, installers, Docker's disk.
    case rebuildable = 1
    /// The user's own files. Shown so they can decide; never selected by default.
    case review = 2

    public static func < (a: StorageGrade, b: StorageGrade) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .safe: return "Safe to clear"
        case .rebuildable: return "Rebuildable"
        case .review: return "Your files, review first"
        }
    }
}

/// One thing taking up space.
public struct StorageItem: Identifiable, Sendable, Equatable {
    public let path: String
    public let label: String
    /// One short sentence: what it is and what happens if it goes.
    public let explanation: String
    /// Allocated bytes, as Finder counts them. Hard links are counted once; APFS clones cannot be.
    public let bytes: UInt64
    public let modified: Date?
    public let grade: StorageGrade
    /// Trash the directory's contents rather than the directory. Used for caches a running app
    /// expects to exist.
    public let contentsOnly: Bool
    public var id: String { path }

    public init(path: String, label: String, explanation: String, bytes: UInt64, modified: Date?, grade: StorageGrade, contentsOnly: Bool = false) {
        self.path = path; self.label = label; self.explanation = explanation; self.bytes = bytes
        self.modified = modified; self.grade = grade; self.contentsOnly = contentsOnly
    }
}

public struct StorageReport: Sendable, Equatable {
    public var scannedAt: Date
    public var diskTotal: Int64
    public var diskFree: Int64
    public var items: [StorageItem]
    /// `nil` when Finder could not be asked (Automation permission declined).
    public var trashBytes: UInt64?

    public func total(_ g: StorageGrade) -> UInt64 { items.filter { $0.grade == g }.reduce(0) { $0 + $1.bytes } }
    public func items(_ g: StorageGrade) -> [StorageItem] { items.filter { $0.grade == g }.sorted { $0.bytes > $1.bytes } }
}

/// Finds what is filling the disk and grades it. Reads only; `StorageActions` does the moving.
///
/// The scan is targeted, not a full walk of the home directory: known cache and build locations
/// are sized directly (in parallel), project folders are walked a few levels deep for `node_modules`
/// and its cousins, and the usual places for large personal files are checked in one pass.
/// Sizes come from `fts` and are allocated bytes with hard links counted once.
public final class StorageScanner {
    public struct Options: Sendable {
        public var home = NSHomeDirectory()
        /// Where projects live. Walked up to `projectDepth` levels for build directories.
        public var projectRoots = ["Code", "Projects", "Developer", "dev", "src", "repos", "work", "Documents", "Desktop"]
        public var projectDepth = 5
        /// A build directory in a project not touched for this long is called out as untouched.
        public var staleProjectDays = 30.0
        /// A personal file or package at least this big is listed for review.
        public var largeFileBytes: UInt64 = 1_073_741_824
        /// Caches smaller than this are not worth a row.
        public var minCacheBytes: UInt64 = 100 * 1_048_576
        /// Installers in Downloads older than this are offered; younger ones may still be in use.
        public var installerAgeDays = 7.0
        public init() {}
    }

    public let options: Options
    private let homeResolved: String
    private let fm = FileManager.default
    private let log = Logger(subsystem: "com.dhruv.vitals", category: "storage")
    private let cancelledFlag = OSAllocatedUnfairLock(initialState: false)
    private var cancelled: Bool { cancelledFlag.withLock { $0 } }

    public init(options: Options = Options()) {
        self.options = options
        self.homeResolved = URL(fileURLWithPath: options.home).resolvingSymlinksInPath().path
    }

    /// Stop as soon as possible. Safe from any thread.
    public func cancel() { cancelledFlag.withLock { $0 = true } }

    /// Path relative to home, whichever spelling of home the system used.
    func relative(_ path: String) -> String {
        for h in [options.home, homeResolved] where path.hasPrefix(h + "/") { return String(path.dropFirst(h.count + 1)) }
        return path
    }

    // MARK: - Fixed locations

    private struct Spec { let path: String; let label: String; let why: String; let grade: StorageGrade; let contentsOnly: Bool }

    private func fixedSpecs() -> [Spec] {
        let h = options.home
        func s(_ p: String, _ l: String, _ w: String, _ g: StorageGrade, contents: Bool = false) -> Spec { Spec(path: h + "/" + p, label: l, why: w, grade: g, contentsOnly: contents) }
        var out: [Spec] = [
            s("Library/Developer/Xcode/DerivedData", "Xcode DerivedData", "Build products. Rebuilt on the next build.", .safe, contents: true),
            s("Library/Developer/Xcode/iOS DeviceSupport", "Xcode iOS device support", "Debug symbols. Fetched again when you plug in a device.", .safe, contents: true),
            s("Library/Developer/Xcode/macOS DeviceSupport", "Xcode macOS device support", "Debug symbols. Fetched again if needed.", .safe, contents: true),
            s("Library/Developer/Xcode/Archives", "Xcode archives", "Past release builds. Needed to read old crash logs.", .review),
            s("Library/Developer/CoreSimulator/Devices", "iOS simulators", "Simulator devices and their apps. Xcode recreates them.", .rebuildable, contents: true),
            s("Library/Developer/CoreSimulator/Caches", "Simulator cache", "Simulator runtime cache.", .safe, contents: true),
            s("Library/Caches/Homebrew", "Homebrew downloads", "Downloaded bottles. Fetched again on reinstall.", .safe, contents: true),
            s(".npm/_cacache", "npm cache", "Downloaded packages. Fetched again on install.", .safe, contents: true),
            s("Library/pnpm/store", "pnpm store", "Package store. Refetched on install.", .rebuildable),
            s("Library/Caches/Yarn", "Yarn cache", "Downloaded packages. Fetched again on install.", .safe, contents: true),
            s(".cache/uv", "uv cache", "Python packages. Fetched again on sync.", .safe, contents: true),
            s("Library/Caches/pip", "pip cache", "Python packages. Fetched again on install.", .safe, contents: true),
            s(".cargo/registry", "Cargo registry", "Rust crates. Fetched again on build.", .safe, contents: true),
            s(".gradle/caches", "Gradle caches", "Dependencies and build cache. Fetched again on build.", .safe, contents: true),
            s(".m2/repository", "Maven repository", "Java dependencies. Fetched again on build.", .safe, contents: true),
            s("Library/Caches/CocoaPods", "CocoaPods cache", "Downloaded pods. Fetched again on install.", .safe, contents: true),
            s(".cache/huggingface", "Hugging Face models", "Model weights. Downloaded again on first use, slowly.", .rebuildable),
            s("Library/Android/sdk/system-images", "Android system images", "Emulator images. Reinstall from Android Studio.", .rebuildable),
            s(".android/avd", "Android emulators", "Virtual devices. Recreate in Android Studio.", .rebuildable),
            s("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", "Docker disk image", "All images, containers and volumes, including database data in volumes. Quit Docker first.", .rebuildable),
            s("Library/Application Support/Adobe/Common/Media Cache Files", "Adobe media cache", "Premiere and After Effects previews. Rebuilt when a project opens.", .safe, contents: true),
            s("Library/Application Support/Adobe/Common/Media Cache", "Adobe media cache index", "Rebuilt with the media cache.", .safe, contents: true),
            s("Library/Caches/Adobe", "Adobe caches", "Creative Cloud cache.", .safe, contents: true),
            s("Library/Application Support/Spotify/PersistentCache", "Spotify music cache", "Streamed and downloaded music. Spotify downloads it again.", .rebuildable, contents: true),
            s("Library/Application Support/Slack/Cache", "Slack cache", "Message and file cache.", .safe, contents: true),
            s("Library/Application Support/discord/Cache", "Discord cache", "Image and file cache.", .safe, contents: true),
            s("Library/Application Support/Microsoft/Teams/Cache", "Teams cache", "Message and file cache.", .safe, contents: true),
            s("Library/Logs", "App logs", "Logs apps have written. They write new ones.", .safe, contents: true),
        ]
        // Everything else in ~/Library/Caches, one row per app. Caches are safe with a few known exceptions.
        let known = Set(out.map(\.path))
        for name in (try? fm.contentsOfDirectory(atPath: h + "/Library/Caches")) ?? [] {
            let p = h + "/Library/Caches/" + name
            guard !known.contains(p), !name.hasPrefix("com.apple.") else { continue }
            let lower = name.lowercased()
            if lower == "jetbrains" { continue }   // holds Local History: unsaved edits. Not a cache in the sense that matters.
            let app = Self.friendlyAppName(name)
            if lower == "ms-playwright" || lower == "cypress" {
                out.append(Spec(path: p, label: "\(app) browsers", why: "Test browser binaries. Downloaded again, slowly.", grade: .rebuildable, contentsOnly: true))
            } else {
                out.append(Spec(path: p, label: "\(app) cache", why: "Rebuilt as you use the app.", grade: .safe, contentsOnly: true))
            }
        }
        return out.filter { fm.fileExists(atPath: $0.path) }
    }

    /// Runs synchronously; call off the main thread. `progress` receives short status lines.
    public func scan(progress: @escaping (String) -> Void = { _ in }) -> StorageReport {
        var items: [StorageItem] = []

        progress("Caches")
        let specs = fixedSpecs()
        var sized = [UInt64](repeating: 0, count: specs.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: specs.count) { i in
            let b = self.size(of: specs[i].path)
            lock.lock(); sized[i] = b; lock.unlock()
        }
        for (i, sp) in specs.enumerated() where sized[i] >= options.minCacheBytes && !cancelled {
            items.append(StorageItem(path: sp.path, label: sp.label, explanation: sp.why, bytes: sized[i], modified: modified(sp.path), grade: sp.grade, contentsOnly: sp.contentsOnly))
        }

        progress("Projects")
        items += projectBuildDirectories()

        progress("Downloads")
        items += downloads()

        progress("Large files")
        items += largeFiles()

        progress("Checking the Trash with Finder")
        let trash = cancelled ? nil : StorageActions.trashBytes()

        let disk = Self.disk()
        var paths = Set<String>()
        let unique = items.filter { paths.insert($0.path).inserted }
        log.notice("storage scan: \(unique.count) items, \(Format.bytes(unique.reduce(0) { $0 + $1.bytes })) listed")
        return StorageReport(scannedAt: Date(), diskTotal: disk.total, diskFree: disk.free, items: unique, trashBytes: trash)
    }

    // MARK: - Projects

    static let buildDirNames: [String: (label: String, why: String)] = [
        "node_modules": ("node_modules", "JavaScript packages. npm install brings them back."),
        ".venv": ("Python virtualenv", "Python packages. uv sync or pip install brings them back."),
        "venv": ("Python virtualenv", "Python packages. uv sync or pip install brings them back."),
        "target": ("Rust build output", "Rebuilt by cargo build."),
        ".next": ("Next.js build", "Rebuilt by next build."),
        ".turbo": ("Turborepo cache", "Rebuilt on the next run."),
        "DerivedData": ("DerivedData", "Rebuilt on the next build."),
        ".build": ("Swift build output", "Rebuilt by swift build."),
        "Pods": ("CocoaPods", "pod install brings them back."),
    ]

    /// Only count a build directory when its parent looks like the matching kind of project.
    private func looksLikeBuildDir(_ name: String, in project: String) -> Bool {
        switch name {
        case "target": return fm.fileExists(atPath: project + "/Cargo.toml")
        case "venv", ".venv": return fm.fileExists(atPath: project + "/" + name + "/pyvenv.cfg")
        case "Pods": return fm.fileExists(atPath: project + "/Podfile")
        case "node_modules": return fm.fileExists(atPath: project + "/package.json")
        default: return true
        }
    }

    private func projectBuildDirectories() -> [StorageItem] {
        var out: [StorageItem] = []
        let cutoff = Date().addingTimeInterval(-options.staleProjectDays * 86400)
        for root in options.projectRoots {
            let base = "\(options.home)/\(root)"
            guard fm.fileExists(atPath: base) else { continue }
            walk(base, depth: 0) { dir, name in
                if name == ".git" { return true }
                guard let kind = Self.buildDirNames[name] else { return false }
                let project = (dir as NSString).deletingLastPathComponent
                guard self.looksLikeBuildDir(name, in: project) else { return true }
                let b = self.size(of: dir)
                guard b >= self.options.minCacheBytes else { return true }
                let touched = self.projectLastTouched(project)
                let stale = touched < cutoff
                out.append(StorageItem(path: dir, label: "\(kind.label) in \(self.relative(project))",
                                       explanation: kind.why + (stale ? " Untouched \(Int(Date().timeIntervalSince(touched) / 86400)) days." : ""),
                                       bytes: b, modified: touched, grade: .rebuildable))
                return true   // do not descend into a build directory
            }
        }
        return out
    }

    /// Visit directories under `path`; `visit` returns true to stop descending into that directory.
    private func walk(_ path: String, depth: Int, visit: (String, String) -> Bool) {
        guard depth <= options.projectDepth, !cancelled else { return }
        guard let names = try? fm.contentsOfDirectory(atPath: path) else { return }
        for name in names {
            if name.hasPrefix(".") && Self.buildDirNames[name] == nil && name != ".git" { continue }
            let p = path + "/" + name
            guard let v = try? URL(fileURLWithPath: p).resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  v.isDirectory == true, v.isSymbolicLink != true else { continue }
            if visit(p, name) { continue }
            walk(p, depth: depth + 1, visit: visit)
        }
    }

    /// Newest of the project directory and its manifest files. Cheap and close enough.
    private func projectLastTouched(_ project: String) -> Date {
        var best = modified(project) ?? .distantPast
        for f in ["package.json", "pyproject.toml", "Cargo.toml", "Package.swift", "pnpm-lock.yaml", "package-lock.json", "src", "app", "Sources"] {
            if let m = modified(project + "/" + f), m > best { best = m }
        }
        return best
    }

    // MARK: - Personal files

    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg"]
    static let archiveExtensions: Set<String> = ["zip", "tar", "gz", "tgz", "7z", "rar", "iso"]

    private func downloads() -> [StorageItem] {
        var out: [StorageItem] = []
        let dir = "\(options.home)/Downloads"
        let cutoff = Date().addingTimeInterval(-options.installerAgeDays * 86400)
        for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where !name.hasPrefix(".") {
            let p = dir + "/" + name
            let ext = (name as NSString).pathExtension.lowercased()
            let m = modified(p)
            if Self.installerExtensions.contains(ext), let m, m < cutoff {
                let b = size(of: p)
                guard b >= 20 * 1_048_576 else { continue }
                let days = Int(Date().timeIntervalSince(m) / 86400)
                // A disk image is not always an installer: people keep encrypted .dmg vaults. Never pre-selected.
                out.append(StorageItem(path: p, label: name, explanation: "Installer from \(days) days ago. Delete once the app is installed.", bytes: b, modified: m, grade: .rebuildable))
            } else if Self.archiveExtensions.contains(ext) {
                let b = size(of: p)
                guard b >= 200 * 1_048_576 else { continue }
                var stem = (name as NSString).deletingPathExtension
                if (stem as NSString).pathExtension.lowercased() == "tar" { stem = (stem as NSString).deletingPathExtension }
                let extracted = fm.fileExists(atPath: dir + "/" + stem)
                out.append(StorageItem(path: p, label: name, explanation: extracted ? "Archive. Already unpacked next to it." : "Archive.", bytes: b, modified: m, grade: .review))
            }
        }
        return out
    }

    /// One pass over the personal folders: big files and big packages (libraries), skipping build
    /// directories and `.git`, which the project pass owns.
    private func largeFiles() -> [StorageItem] {
        var out: [StorageItem] = []
        let roots = ["Downloads", "Desktop", "Documents", "Movies", "Music", "Pictures"].map { "\(options.home)/\($0)" }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .contentModificationDateKey, .isPackageKey, .nameKey]
        for root in roots where fm.fileExists(atPath: root) {
            guard let e = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { continue }
            var files = 0
            for case let url as URL in e {
                if cancelled || files > 200_000 { break }
                guard let v = try? url.resourceValues(forKeys: keys) else { continue }
                let name = url.lastPathComponent
                if v.isDirectory == true {
                    if Self.buildDirNames[name] != nil || name == ".git" { e.skipDescendants(); continue }
                    if v.isPackage == true {
                        e.skipDescendants()
                        let b = size(of: url.path)
                        if b >= options.largeFileBytes {
                            out.append(StorageItem(path: url.path, label: name, explanation: "Library or bundle in \(folder(of: url)).", bytes: b, modified: v.contentModificationDate, grade: .review))
                        }
                    }
                    continue
                }
                guard v.isRegularFile == true else { continue }
                files += 1
                guard let b = v.totalFileAllocatedSize, UInt64(b) >= options.largeFileBytes else { continue }
                let ext = url.pathExtension.lowercased()
                if root.hasSuffix("/Downloads"), Self.installerExtensions.contains(ext) || Self.archiveExtensions.contains(ext) { continue }
                out.append(StorageItem(path: url.path, label: name, explanation: "In \(folder(of: url)).", bytes: UInt64(b), modified: v.contentModificationDate, grade: .review))
            }
        }
        return out.sorted { $0.bytes > $1.bytes }.prefix(25).map { $0 }
    }

    private func folder(of url: URL) -> String {
        let rel = relative(url.deletingLastPathComponent().path)
        return rel.isEmpty ? "home" : rel
    }

    // MARK: - Helpers

    /// Allocated bytes for a file or a tree, hard links counted once, symlinks not followed,
    /// never crossing onto another volume. Matches Finder's "on disk" figure for non-cloned data.
    public func size(of path: String) -> UInt64 {
        var total: UInt64 = 0
        var seen = Set<UInt64>()   // (dev << 32 | ino) for multiply-linked files
        let args: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        defer { free(args[0]) }
        guard let fts = fts_open(args, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return 0 }
        defer { fts_close(fts) }
        var n = 0
        while let ent = fts_read(fts) {
            n += 1
            if n & 0x3FF == 0, cancelled { break }
            let info = Int32(ent.pointee.fts_info)
            guard info == FTS_F || info == FTS_DEFAULT, let st = ent.pointee.fts_statp else { continue }
            if st.pointee.st_nlink > 1 {
                let key = (UInt64(UInt32(bitPattern: st.pointee.st_dev)) << 32) | UInt64(st.pointee.st_ino & 0xFFFF_FFFF)
                if !seen.insert(key).inserted { continue }
            }
            total += UInt64(max(st.pointee.st_blocks, 0)) * 512
        }
        return total
    }

    func modified(_ path: String) -> Date? {
        (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    public static func disk() -> (total: Int64, free: Int64) {
        let v = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return (Int64(v?.volumeTotalCapacity ?? 0), v?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    /// "com.spotify.client" → "Spotify", "company.thebrowser.Browser" → "Arc", "Google" → "Google".
    static func friendlyAppName(_ bundleOrName: String) -> String {
        let map: [String: String] = [
            "company.thebrowser.browser": "Arc", "com.spotify.client": "Spotify", "com.google.chrome": "Chrome",
            "com.brave.browser": "Brave", "com.microsoft.edgemac": "Edge", "com.tinyspeck.slackmacgap": "Slack",
            "com.hnc.discord": "Discord", "com.anthropic.claudefordesktop.shipit": "Claude updater", "com.figma.desktop": "Figma",
            "notion.id": "Notion", "us.zoom.xos": "Zoom", "com.microsoft.teams2": "Teams", "com.todesktop.230313mzl4w4u92": "Cursor",
            "ms-playwright": "Playwright", "cypress": "Cypress",
        ]
        if let m = map[bundleOrName.lowercased()] { return m }
        if bundleOrName.contains(".") {
            let last = bundleOrName.split(separator: ".").last.map(String.init) ?? bundleOrName
            return last.prefix(1).uppercased() + last.dropFirst()
        }
        return bundleOrName
    }
}

/// Moves things to the Trash and empties it. The Trash is the undo; nothing is unlinked by
/// this code. Emptying goes through Finder, and only when the user asks.
public enum StorageActions {
    private static let log = Logger(subsystem: "com.dhruv.vitals", category: "storage")

    public struct Outcome: Sendable {
        public var trashed: [String] = []
        /// Where each trashed item ended up.
        public var trashedTo: [String] = []
        public var failed: [(path: String, reason: String)] = []
        /// Bytes as the rows counted them. Space actually regained can be less (clones, hard links).
        public var bytes: UInt64 = 0
    }

    /// Paths that must never be trashed from here, even though they live under home.
    static func refusal(for rawPath: String) -> String? {
        let home = NSHomeDirectory()
        let homeResolved = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        let p = URL(fileURLWithPath: rawPath).standardized.path
        if [home, homeResolved].contains(p) { return "that is your home folder" }
        let inHome = [home, homeResolved].contains { p.hasPrefix($0 + "/") }
        guard inHome else { return "outside your home folder" }
        for h in [home, homeResolved] {
            if p.hasPrefix(h + "/.Trash") { return "already in the Trash" }
            if p.hasPrefix(h + "/Library/Mobile Documents") || p.hasPrefix(h + "/Library/CloudStorage") { return "synced to the cloud; removing it here removes it everywhere" }
        }
        return nil
    }

    /// Move each item to the Trash. Same volume, so it is instant and recoverable.
    public static func trash(_ items: [StorageItem]) -> Outcome {
        var o = Outcome()
        let fm = FileManager.default
        for i in items {
            if let why = refusal(for: i.path) { o.failed.append((i.path, why)); continue }
            let targets: [String]
            if i.contentsOnly, let names = try? fm.contentsOfDirectory(atPath: i.path) {
                targets = names.map { i.path + "/" + $0 }
            } else {
                targets = [i.path]
            }
            var ok = true
            for t in targets {
                var dest: NSURL?
                do {
                    try fm.trashItem(at: URL(fileURLWithPath: t), resultingItemURL: &dest)
                    if let d = dest?.path { o.trashedTo.append(d) }
                } catch {
                    ok = false
                    o.failed.append((t, error.localizedDescription))
                    log.error("trash \(i.label): \(error.localizedDescription)")
                }
            }
            if ok { o.trashed.append(i.path); o.bytes += i.bytes }
        }
        log.notice("moved \(o.trashed.count) items (\(Format.bytes(o.bytes))) to Trash")
        return o
    }

    /// `~/.Trash` cannot be listed without Full Disk Access, but Finder can. One Apple Event.
    /// - Returns: `nil` when Finder is unavailable or Automation permission was declined.
    public static func trashBytes() -> UInt64? {
        // Fast path if Full Disk Access happens to be granted.
        let trash = NSHomeDirectory() + "/.Trash"
        if let names = try? FileManager.default.contentsOfDirectory(atPath: trash) {
            let s = StorageScanner()
            return names.reduce(0) { $0 + s.size(of: trash + "/" + $1) }
        }
        var err: NSDictionary?
        guard let out = NSAppleScript(source: "tell application \"Finder\" to get physical size of every item of trash")?.executeAndReturnError(&err), err == nil else { return nil }
        if out.numberOfItems == 0 { return out.doubleValue > 0 ? UInt64(out.doubleValue) : 0 }
        var total: UInt64 = 0
        for i in 1...out.numberOfItems { total += UInt64(max(out.atIndex(i)?.doubleValue ?? 0, 0)) }
        return total
    }

    /// Ask Finder to empty the Trash, then wait for it to finish (it is asynchronous and may show
    /// its own confirmation). The one irreversible step; only the user triggers it.
    /// - Returns: an error message if Finder refused, otherwise nil.
    public static func emptyTrash(timeout: TimeInterval = 30) -> String? {
        var err: NSDictionary?
        NSAppleScript(source: "tell application \"Finder\" to empty the trash")?.executeAndReturnError(&err)
        if let err {
            let msg = err[NSAppleScript.errorMessage] as? String ?? "Finder did not respond"
            log.error("empty trash: \(msg)")
            return msg
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, (trashBytes() ?? 0) > 0 { Thread.sleep(forTimeInterval: 0.5) }
        log.notice("emptied Trash via Finder")
        return nil
    }
}
