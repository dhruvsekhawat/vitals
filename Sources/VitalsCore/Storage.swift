import Foundation
import os

/// How safe it is to remove something.
public enum StorageGrade: Int, Codable, Sendable, Comparable, CaseIterable {
    /// Rebuilds itself. Caches, build products, logs, installers for apps already installed.
    case safe = 0
    /// Comes back with a reinstall or rebuild: node_modules, virtualenvs, simulators, Docker's disk.
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
    public var subtitle: String {
        switch self {
        case .safe: return "Comes back on its own. Apps and tools rebuild these."
        case .rebuildable: return "Comes back with a reinstall or a rebuild."
        case .review: return "Only you know if these matter. Nothing here is selected for you."
        }
    }
}

/// One thing taking up space.
public struct StorageItem: Identifiable, Sendable, Equatable {
    public let path: String
    public let label: String
    /// One plain sentence: what it is and what happens if it goes.
    public let explanation: String
    public let bytes: UInt64
    public let modified: Date?
    public let grade: StorageGrade
    public var id: String { path }

    public init(path: String, label: String, explanation: String, bytes: UInt64, modified: Date?, grade: StorageGrade) {
        self.path = path; self.label = label; self.explanation = explanation; self.bytes = bytes; self.modified = modified; self.grade = grade
    }
}

public struct StorageReport: Sendable, Equatable {
    public let scannedAt: Date
    public let diskTotal: Int64
    public let diskFree: Int64
    public let items: [StorageItem]
    public let trashBytes: UInt64

    public func total(_ g: StorageGrade) -> UInt64 { items.filter { $0.grade == g }.reduce(0) { $0 + $1.bytes } }
    public func items(_ g: StorageGrade) -> [StorageItem] { items.filter { $0.grade == g }.sorted { $0.bytes > $1.bytes } }
}

/// Finds what is filling the disk and grades it. Reads only; `StorageActions` does the moving.
///
/// The scan is targeted, not a full walk of the home directory: known cache and build locations
/// are sized directly, project folders are walked a few levels deep for `node_modules` and its
/// cousins, and the usual places for large personal files are checked for anything over a threshold.
/// Sizes are allocated bytes on disk, the same number Finder shows.
public final class StorageScanner {
    public struct Options: Sendable {
        public var home = NSHomeDirectory()
        /// Where projects live. Walked up to `projectDepth` levels for build directories.
        public var projectRoots = ["Code", "Projects", "Developer", "dev", "src", "repos", "work", "Documents", "Desktop"]
        public var projectDepth = 5
        /// A build directory in a project not touched for this long is offered as rebuildable.
        public var staleProjectDays = 30.0
        /// A personal file at least this big is listed for review.
        public var largeFileBytes: UInt64 = 1_073_741_824
        /// Caches smaller than this are not worth a row.
        public var minCacheBytes: UInt64 = 100 * 1_048_576
        /// Installers in Downloads older than this are safe: the app is installed by now.
        public var installerAgeDays = 7.0
        public init() {}
    }

    public let options: Options
    /// `options.home` with symlinks resolved, because enumerators hand back `/private/var/...` for `/var/...`.
    private let homeResolved: String
    private let fm = FileManager.default
    private let log = Logger(subsystem: "com.dhruv.vitals", category: "storage")
    private var cancelled = false

    public init(options: Options = Options()) {
        self.options = options
        self.homeResolved = URL(fileURLWithPath: options.home).resolvingSymlinksInPath().path
    }

    /// Path relative to home, whichever spelling of home the system used.
    func relative(_ path: String) -> String {
        for h in [options.home, homeResolved] where path.hasPrefix(h + "/") { return String(path.dropFirst(h.count + 1)) }
        return path
    }

    public func cancel() { cancelled = true }

    /// Runs synchronously; call off the main thread. `progress` receives short status lines.
    public func scan(progress: @escaping (String) -> Void = { _ in }) -> StorageReport {
        let home = options.home
        var items: [StorageItem] = []
        func add(_ path: String, _ label: String, _ why: String, _ grade: StorageGrade, min: UInt64 = 0) {
            guard !cancelled, fm.fileExists(atPath: path) else { return }
            let b = size(of: path)
            guard b >= min else { return }
            items.append(StorageItem(path: path, label: label, explanation: why, bytes: b, modified: modified(path), grade: grade))
        }

        progress("Developer caches")
        add("\(home)/Library/Developer/Xcode/DerivedData", "Xcode DerivedData", "Xcode build products. Rebuilt on the next build.", .safe, min: options.minCacheBytes)
        add("\(home)/Library/Developer/Xcode/iOS DeviceSupport", "Xcode iOS device support", "Debug symbols. Fetched again when you plug in a device.", .safe, min: options.minCacheBytes)
        add("\(home)/Library/Developer/Xcode/macOS DeviceSupport", "Xcode macOS device support", "Debug symbols. Fetched again if needed.", .safe, min: options.minCacheBytes)
        add("\(home)/Library/Developer/Xcode/Archives", "Xcode archives", "Past release builds. Needed to read old crash logs.", .review, min: options.minCacheBytes)
        add("\(home)/Library/Developer/CoreSimulator/Devices", "iOS simulators", "Simulator devices and their apps. Xcode recreates them.", .rebuildable, min: options.minCacheBytes)
        add("\(home)/Library/Developer/CoreSimulator/Caches", "Simulator cache", "Simulator runtime cache.", .safe, min: options.minCacheBytes)
        add("\(home)/Library/Caches/Homebrew", "Homebrew downloads", "Downloaded bottles. Fetched again on reinstall.", .safe, min: options.minCacheBytes)
        add("\(home)/.npm/_cacache", "npm cache", "Downloaded packages. Fetched again on install.", .safe, min: options.minCacheBytes)
        add("\(home)/Library/pnpm/store", "pnpm store", "Package store. Refetched on install.", .rebuildable, min: options.minCacheBytes)
        add("\(home)/Library/Caches/Yarn", "Yarn cache", "Downloaded packages. Fetched again on install.", .safe, min: options.minCacheBytes)
        add("\(home)/.cache/uv", "uv cache", "Python packages. Fetched again on sync.", .safe, min: options.minCacheBytes)
        add("\(home)/Library/Caches/pip", "pip cache", "Python packages. Fetched again on install.", .safe, min: options.minCacheBytes)
        add("\(home)/.cargo/registry", "Cargo registry", "Rust crates. Fetched again on build.", .safe, min: options.minCacheBytes)
        add("\(home)/.gradle/caches", "Gradle caches", "Dependencies and build cache. Fetched again on build.", .safe, min: options.minCacheBytes)
        add("\(home)/.m2/repository", "Maven repository", "Java dependencies. Fetched again on build.", .safe, min: options.minCacheBytes)
        add("\(home)/Library/Caches/CocoaPods", "CocoaPods cache", "Downloaded pods. Fetched again on install.", .safe, min: options.minCacheBytes)
        add("\(home)/.cache/huggingface", "Hugging Face models", "Model weights. Downloaded again on first use, slowly.", .rebuildable, min: options.minCacheBytes)
        add("\(home)/Library/Android/sdk/system-images", "Android system images", "Emulator images. Reinstall from Android Studio.", .rebuildable, min: options.minCacheBytes)
        add("\(home)/.android/avd", "Android emulators", "Virtual devices. Recreate in Android Studio.", .rebuildable, min: options.minCacheBytes)
        add("\(home)/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", "Docker disk image", "All images, containers and volumes. Quit Docker first.", .rebuildable, min: options.minCacheBytes)

        progress("App caches")
        add("\(home)/Library/Application Support/Adobe/Common/Media Cache Files", "Adobe media cache", "Premiere and After Effects previews. Rebuilt when a project opens.", .safe, min: options.minCacheBytes)
        add("\(home)/Library/Application Support/Adobe/Common/Media Cache", "Adobe media cache database", "Media cache index. Rebuilt with it.", .safe, min: options.minCacheBytes)
        add("\(home)/Library/Caches/Adobe", "Adobe caches", "Creative Cloud cache.", .safe, min: options.minCacheBytes)
        add("\(home)/Library/Application Support/Spotify/PersistentCache", "Spotify offline cache", "Streamed music kept for replay. Your downloads stay.", .safe, min: options.minCacheBytes)
        add("\(home)/Library/Application Support/Slack/Cache", "Slack cache", "Message and file cache.", .safe, min: options.minCacheBytes)
        add("\(home)/Library/Application Support/discord/Cache", "Discord cache", "Image and file cache.", .safe, min: options.minCacheBytes)
        add("\(home)/Library/Application Support/Microsoft/Teams/Cache", "Teams cache", "Cache.", .safe, min: options.minCacheBytes)
        add("\(home)/Library/Logs", "Logs", "App and system logs.", .safe, min: options.minCacheBytes)
        add("\(home)/Library/Application Support/CrashReporter", "Crash reports", "Old crash reports.", .safe, min: options.minCacheBytes)

        // Everything else in ~/Library/Caches, one row per app, if big enough. Caches are safe by definition.
        let known = Set(items.map(\.path))
        for name in (try? fm.contentsOfDirectory(atPath: "\(home)/Library/Caches")) ?? [] where !cancelled {
            let p = "\(home)/Library/Caches/\(name)"
            guard !known.contains(p), !name.hasPrefix("com.apple.") else { continue }
            add(p, "\(Self.friendlyAppName(name)) cache", "Rebuilt as you use the app.", .safe, min: options.minCacheBytes)
        }

        progress("Projects")
        items += projectBuildDirectories()

        progress("Downloads and large files")
        items += downloads()
        items += largeFiles()

        progress("Trash")
        let trash = StorageActions.trashBytes()

        let disk = Self.disk()
        let seen = Set<String>()
        var unique: [StorageItem] = []
        var paths = seen
        for i in items where paths.insert(i.path).inserted { unique.append(i) }
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

    private func projectBuildDirectories() -> [StorageItem] {
        var out: [StorageItem] = []
        let cutoff = Date().addingTimeInterval(-options.staleProjectDays * 86400)
        for root in options.projectRoots {
            let base = "\(options.home)/\(root)"
            guard fm.fileExists(atPath: base) else { continue }
            walk(base, depth: 0) { dir, name in
                guard let kind = Self.buildDirNames[name] else { return false }
                if name == "target", !self.fm.fileExists(atPath: (dir as NSString).deletingLastPathComponent + "/Cargo.toml") { return false }
                let project = (dir as NSString).deletingLastPathComponent
                let touched = self.projectLastTouched(project)
                let b = self.size(of: dir)
                guard b >= self.options.minCacheBytes else { return true }
                let stale = touched < cutoff
                let rel = self.relative(project)
                out.append(StorageItem(path: dir, label: "\(kind.label) in \(rel)",
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
            if name.hasPrefix(".") && Self.buildDirNames[name] == nil { continue }
            let p = path + "/" + name
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { continue }
            if let v = try? URL(fileURLWithPath: p).resourceValues(forKeys: [.isSymbolicLinkKey]), v.isSymbolicLink == true { continue }
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

    private func downloads() -> [StorageItem] {
        var out: [StorageItem] = []
        let dir = "\(options.home)/Downloads"
        let cutoff = Date().addingTimeInterval(-options.installerAgeDays * 86400)
        for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where !name.hasPrefix(".") {
            let p = dir + "/" + name
            let ext = (name as NSString).pathExtension.lowercased()
            let m = modified(p)
            if ["dmg", "pkg", "iso", "mpkg"].contains(ext), let m, m < cutoff {
                let b = size(of: p)
                guard b >= 20 * 1_048_576 else { continue }
                out.append(StorageItem(path: p, label: name, explanation: "Installer. The app is already installed.", bytes: b, modified: m, grade: .safe))
            } else if ["zip", "tar", "gz", "tgz", "7z", "rar"].contains(ext) {
                let b = size(of: p)
                guard b >= 200 * 1_048_576 else { continue }
                let extracted = fm.fileExists(atPath: dir + "/" + (name as NSString).deletingPathExtension)
                out.append(StorageItem(path: p, label: name, explanation: extracted ? "Archive. Already unpacked next to it." : "Archive.", bytes: b, modified: m, grade: .review))
            }
        }
        return out
    }

    private func largeFiles() -> [StorageItem] {
        var out: [StorageItem] = []
        let roots = ["Downloads", "Desktop", "Documents", "Movies", "Music", "Pictures"].map { "\(options.home)/\($0)" }
        for root in roots where fm.fileExists(atPath: root) {
            guard let e = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .contentModificationDateKey, .isPackageKey],
                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            var n = 0
            for case let url as URL in e {
                if cancelled { break }
                n += 1; if n > 200_000 { break }
                guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .contentModificationDateKey, .isPackageKey]) else { continue }
                if v.isPackage == true { e.skipDescendants() }
                guard v.isRegularFile == true, let b = v.totalFileAllocatedSize, UInt64(b) >= options.largeFileBytes else { continue }
                // Installers and archives in Downloads have their own rules; do not list them twice.
                let ext = url.pathExtension.lowercased()
                if root.hasSuffix("/Downloads"), ["dmg", "pkg", "iso", "mpkg", "zip", "tar", "gz", "tgz", "7z", "rar"].contains(ext) { continue }
                let rel = relative(url.path)
                out.append(StorageItem(path: url.path, label: url.lastPathComponent,
                                       explanation: "In \((rel as NSString).deletingLastPathComponent).",
                                       bytes: UInt64(b), modified: v.contentModificationDate, grade: .review))
            }
        }
        // iOS backups are personal data with a clear owner.
        let backups = "\(options.home)/Library/Application Support/MobileSync/Backup"
        if fm.fileExists(atPath: backups) {
            let b = size(of: backups)
            if b >= options.largeFileBytes {
                out.append(StorageItem(path: backups, label: "iPhone and iPad backups", explanation: "iPhone backups. Keep unless you use iCloud backup.", bytes: b, modified: modified(backups), grade: .review))
            }
        }
        return out.sorted { $0.bytes > $1.bytes }.prefix(25).map { $0 }
    }

    // MARK: - Helpers

    /// Allocated bytes on disk for a file or a tree. Matches Finder's "on disk" figure.
    public func size(of path: String) -> UInt64 {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        if !isDir.boolValue {
            return UInt64((try? URL(fileURLWithPath: path).resourceValues(forKeys: keys).totalFileAllocatedSize) ?? 0)
        }
        guard let e = fm.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: Array(keys), options: []) else { return 0 }
        var total: UInt64 = 0
        for case let url as URL in e {
            if cancelled { break }
            if let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true, let b = v.totalFileAllocatedSize { total += UInt64(b) }
        }
        return total
    }

    func modified(_ path: String) -> Date? {
        (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    static func disk() -> (total: Int64, free: Int64) {
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return (Int64(v?.volumeTotalCapacity ?? 0), v?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    /// "com.spotify.client" → "Spotify", "company.thebrowser.Browser" → "Arc", "Google" → "Google".
    static func friendlyAppName(_ bundleOrName: String) -> String {
        let map: [String: String] = [
            "company.thebrowser.browser": "Arc", "com.spotify.client": "Spotify", "com.google.chrome": "Chrome",
            "com.brave.browser": "Brave", "com.microsoft.edgemac": "Edge", "com.tinyspeck.slackmacgap": "Slack",
            "com.hnc.discord": "Discord", "com.anthropic.claudefordesktop.shipit": "Claude updater", "com.figma.desktop": "Figma",
            "notion.id": "Notion", "us.zoom.xos": "Zoom", "com.microsoft.teams2": "Teams", "com.todesktop.230313mzl4w4u92": "Cursor",
        ]
        if let m = map[bundleOrName.lowercased()] { return m }
        if bundleOrName.contains(".") {
            let last = bundleOrName.split(separator: ".").last.map(String.init) ?? bundleOrName
            return last.prefix(1).uppercased() + last.dropFirst()
        }
        return bundleOrName
    }
}

/// Moves things to the Trash and empties it. The Trash is the undo; nothing is unlinked directly
/// except when the user explicitly empties it.
public enum StorageActions {
    private static let log = Logger(subsystem: "com.dhruv.vitals", category: "storage")

    public struct Outcome: Sendable {
        public var trashed: [String] = []
        /// Where each trashed item ended up.
        public var trashedTo: [String] = []
        public var failed: [(path: String, reason: String)] = []
        public var bytes: UInt64 = 0
    }

    /// Move each item to the Trash. Same volume, so it is instant and recoverable.
    public static func trash(_ items: [StorageItem]) -> Outcome {
        var o = Outcome()
        let home = NSHomeDirectory()
        let homeResolved = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        for i in items {
            // Refuse anything outside the home directory, and the home directory itself.
            guard i.path.hasPrefix(home + "/") || i.path.hasPrefix(homeResolved + "/") else { o.failed.append((i.path, "outside your home folder")); continue }
            var dest: NSURL?
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: i.path), resultingItemURL: &dest)
                o.trashed.append(i.path); o.bytes += i.bytes
                if let d = dest?.path { o.trashedTo.append(d) }
            } catch {
                o.failed.append((i.path, error.localizedDescription))
                log.error("trash \(i.label): \(error.localizedDescription)")
            }
        }
        log.notice("moved \(o.trashed.count) items (\(Format.bytes(o.bytes))) to Trash")
        return o
    }

    /// `~/.Trash` cannot be listed without Full Disk Access, but Finder can. Ask it.
    /// Returns 0 when Finder is unavailable or Automation permission was declined.
    public static func trashBytes() -> UInt64 {
        let script = """
        tell application "Finder"
            set total to 0
            repeat with i in (items of trash)
                try
                    set total to total + (physical size of i)
                end try
            end repeat
            return total
        end tell
        """
        var err: NSDictionary?
        guard let out = NSAppleScript(source: script)?.executeAndReturnError(&err), err == nil else { return 0 }
        return UInt64(max(out.doubleValue, 0))
    }

    /// Delete everything in the Trash, through Finder. The one irreversible step; only the user triggers it.
    /// - Returns: an error message if Finder refused, otherwise nil.
    public static func emptyTrash() -> String? {
        var err: NSDictionary?
        NSAppleScript(source: "tell application \"Finder\" to empty the trash")?.executeAndReturnError(&err)
        if let err {
            let msg = err[NSAppleScript.errorMessage] as? String ?? "Finder did not respond"
            log.error("empty trash: \(msg)")
            return msg
        }
        log.notice("emptied Trash via Finder")
        return nil
    }
}
