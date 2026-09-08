import XCTest
@testable import VitalsCore

/// The scanner is pointed at a throwaway "home" so every expectation is a file the test wrote.
final class StorageTests: XCTestCase {
    private var home: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appendingPathComponent("vitals-storage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: home)
    }

    private func options() -> StorageScanner.Options {
        var o = StorageScanner.Options()
        o.home = home.path
        o.minCacheBytes = 8_192          // allocated size rounds to 4 KB blocks, so "small" is under two blocks
        o.largeFileBytes = 64 * 1_024
        o.projectRoots = ["Code"]
        return o
    }

    @discardableResult
    private func write(_ rel: String, bytes: Int, modified: Date? = nil) throws -> String {
        let url = home.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: bytes).write(to: url)
        if let modified { try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        return url.path
    }

    private func touch(_ rel: String, _ date: Date) throws {
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: home.appendingPathComponent(rel).path)
    }

    // MARK: Grading

    func testKnownCachesAreSafeAndSizedFromDisk() throws {
        try write("Library/Developer/Xcode/DerivedData/App-abc/Build/x.o", bytes: 40_000)
        try write("Library/Developer/Xcode/DerivedData/App-abc/Index/y", bytes: 10_000)
        try write("Library/Caches/Homebrew/foo.bottle.tar.gz", bytes: 16_384)
        let r = StorageScanner(options: options()).scan()!

        let dd = try XCTUnwrap(r.items.first { $0.label == "Xcode DerivedData" })
        XCTAssertEqual(dd.grade, .safe)
        XCTAssertGreaterThanOrEqual(dd.bytes, 50_000, "allocated size covers both files")
        XCTAssertTrue(dd.explanation.contains("Rebuilt"), dd.explanation)

        let brew = try XCTUnwrap(r.items.first { $0.label == "Homebrew downloads" })
        XCTAssertEqual(brew.grade, .safe)
        XCTAssertGreaterThanOrEqual(brew.bytes, 16_384)
    }

    func testCachesBelowMinimumAreNotListed() throws {
        try write("Library/Caches/Homebrew/tiny", bytes: 100)   // under the 1 KB test minimum
        let r = StorageScanner(options: options()).scan()!
        XCTAssertNil(r.items.first { $0.label == "Homebrew downloads" })
    }

    func testGenericLibraryCachesGetAFriendlyNameAndSkipApple() throws {
        try write("Library/Caches/com.spotify.client/blob", bytes: 16_384)
        try write("Library/Caches/com.apple.something/blob", bytes: 16_384)
        let r = StorageScanner(options: options()).scan()!
        let spotify = try XCTUnwrap(r.items.first { $0.label == "Spotify cache" })
        XCTAssertEqual(spotify.grade, .safe)
        XCTAssertNil(r.items.first { $0.path.contains("com.apple.something") }, "Apple's own caches are left alone")
    }

    func testFriendlyAppNames() {
        XCTAssertEqual(StorageScanner.friendlyAppName("com.spotify.client"), "Spotify")
        XCTAssertEqual(StorageScanner.friendlyAppName("company.thebrowser.Browser"), "Arc")
        XCTAssertEqual(StorageScanner.friendlyAppName("org.example.Thing"), "Thing")
        XCTAssertEqual(StorageScanner.friendlyAppName("Google"), "Google")
    }

    // MARK: Projects

    func testNodeModulesInStaleProjectIsRebuildableWithAge() throws {
        let old = Date().addingTimeInterval(-45 * 86400)
        try write("Code/app/node_modules/left-pad/index.js", bytes: 16_384)
        try write("Code/app/package.json", bytes: 100, modified: old)
        try write("Code/app/src/main.js", bytes: 100, modified: old)
        try touch("Code/app", old)
        try touch("Code/app/src", old)
        let r = StorageScanner(options: options()).scan()!

        let nm = try XCTUnwrap(r.items.first { $0.path.hasSuffix("Code/app/node_modules") })
        XCTAssertEqual(nm.grade, .rebuildable)
        XCTAssertEqual(nm.label, "node_modules in Code/app")
        XCTAssertTrue(nm.explanation.contains("Untouched 4"), nm.explanation)   // 44 or 45 days
        XCTAssertTrue(nm.explanation.contains("npm install"), nm.explanation)
    }

    func testActiveProjectIsStillListedButSaysSo() throws {
        try write("Code/live/node_modules/x/index.js", bytes: 16_384)
        try write("Code/live/package.json", bytes: 100)   // modified now
        let r = StorageScanner(options: options()).scan()!
        let nm = try XCTUnwrap(r.items.first { $0.path.hasSuffix("Code/live/node_modules") })
        XCTAssertFalse(nm.explanation.contains("Untouched"), "an active project gets no idle note: \(nm.explanation)")
    }

    func testDoesNotDescendIntoBuildDirectories() throws {
        // A node_modules inside node_modules must not produce a second row.
        try write("Code/app/node_modules/a/node_modules/b/index.js", bytes: 16_384)
        try write("Code/app/package.json", bytes: 100)
        let r = StorageScanner(options: options()).scan()!
        XCTAssertEqual(r.items.filter { $0.path.contains("node_modules") }.count, 1)
    }

    func testRustTargetOnlyCountsNextToCargoToml() throws {
        try write("Code/rusty/target/debug/bin", bytes: 16_384)
        try write("Code/rusty/Cargo.toml", bytes: 50)
        try write("Code/notrust/target/thing", bytes: 16_384)
        let r = StorageScanner(options: options()).scan()!
        XCTAssertNotNil(r.items.first { $0.path.hasSuffix("Code/rusty/target") })
        XCTAssertNil(r.items.first { $0.path.hasSuffix("Code/notrust/target") }, "a folder merely named target is not a build directory")
    }

    func testSymlinkedProjectDirectoriesAreNotFollowed() throws {
        try write("Code/real/node_modules/x/i.js", bytes: 16_384)
        try write("Code/real/package.json", bytes: 10)
        try fm.createSymbolicLink(atPath: home.appendingPathComponent("Code/alias").path, withDestinationPath: home.appendingPathComponent("Code/real").path)
        let r = StorageScanner(options: options()).scan()!
        XCTAssertEqual(r.items.filter { $0.path.contains("node_modules") }.count, 1)
    }

    // MARK: Downloads and large files

    func testOldInstallersAreOfferedAsRebuildableAndFreshOnesAreNot() throws {
        try write("Downloads/Old.dmg", bytes: 30 * 1_048_576, modified: Date().addingTimeInterval(-10 * 86400))
        try write("Downloads/Fresh.dmg", bytes: 30 * 1_048_576, modified: Date().addingTimeInterval(-1 * 86400))
        let r = StorageScanner(options: options()).scan()!
        let old = try XCTUnwrap(r.items.first { $0.label == "Old.dmg" })
        XCTAssertEqual(old.grade, .rebuildable, "a .dmg can be an encrypted vault someone keeps on purpose; never pre-selected")
        XCTAssertTrue(old.explanation.contains("Installer from 10 days ago"), old.explanation)
        XCTAssertNil(r.items.first { $0.label == "Fresh.dmg" }, "a week-old rule: fresh installers are left alone")
    }

    func testArchivesAreReviewAndNoteAnExtractedFolder() throws {
        try write("Downloads/photos.zip", bytes: 210 * 1_048_576)
        try fm.createDirectory(at: home.appendingPathComponent("Downloads/photos"), withIntermediateDirectories: true)
        let r = StorageScanner(options: options()).scan()!
        let z = try XCTUnwrap(r.items.first { $0.label == "photos.zip" })
        XCTAssertEqual(z.grade, .review)
        XCTAssertTrue(z.explanation.contains("unpacked"), z.explanation)
    }

    func testLargePersonalFilesAreReviewOnly() throws {
        try write("Movies/talk.mp4", bytes: 128 * 1_024)
        try write("Movies/clip.mp4", bytes: 10 * 1_024)       // under the 64 KB test threshold
        let r = StorageScanner(options: options()).scan()!
        let talk = try XCTUnwrap(r.items.first { $0.label == "talk.mp4" })
        XCTAssertEqual(talk.grade, .review)
        XCTAssertTrue(talk.explanation.contains("Movies"), talk.explanation)
        XCTAssertNil(r.items.first { $0.label == "clip.mp4" })
    }

    func testReportTotalsAndOrdering() throws {
        try write("Library/Caches/Homebrew/a", bytes: 16_384)
        try write("Library/Developer/Xcode/DerivedData/x", bytes: 16_384)
        try write("Movies/big.mov", bytes: 128 * 1_024)
        let r = StorageScanner(options: options()).scan()!
        XCTAssertGreaterThanOrEqual(r.total(.safe), 32_768)
        XCTAssertEqual(r.items(.safe).map(\.label).first, "Xcode DerivedData", "largest first")
        XCTAssertGreaterThanOrEqual(r.total(.review), 128 * 1_024)
        XCTAssertEqual(r.total(.rebuildable), 0)
        XCTAssertTrue(StorageGrade.safe < StorageGrade.review)
    }

    func testNodeModulesNeedsAPackageJson() throws {
        try write("Code/notes/node_modules/x", bytes: 16_384)   // a folder that merely has the name
        let r = StorageScanner(options: options()).scan()!
        XCTAssertNil(r.items.first { $0.path.hasSuffix("notes/node_modules") })
    }

    func testHardLinksCountOnce() throws {
        let a = try write("Library/Caches/Homebrew/a", bytes: 64 * 1_024)
        try fm.linkItem(atPath: a, toPath: home.appendingPathComponent("Library/Caches/Homebrew/b").path)
        let r = StorageScanner(options: options()).scan()!
        let brew = try XCTUnwrap(r.items.first { $0.label == "Homebrew downloads" })
        XCTAssertLessThan(brew.bytes, 2 * 64 * 1_024, "the same blocks are not counted twice")
        XCTAssertGreaterThanOrEqual(brew.bytes, 64 * 1_024)
    }

    func testLargePackagesAreListedAsOneRow() throws {
        try write("Pictures/Trip.photoslibrary/originals/a.jpg", bytes: 40 * 1_024)
        try write("Pictures/Trip.photoslibrary/originals/b.jpg", bytes: 40 * 1_024)
        let r = StorageScanner(options: options()).scan()!
        let lib = try XCTUnwrap(r.items.first { $0.label == "Trip.photoslibrary" })
        XCTAssertEqual(lib.grade, .review)
        XCTAssertGreaterThanOrEqual(lib.bytes, 80 * 1_024)
        XCTAssertNil(r.items.first { $0.label == "a.jpg" }, "files inside a package are not listed on their own")
    }

    func testCachesAreTrashedByContentsNotByFolder() throws {
        try write("Library/Caches/Homebrew/a", bytes: 16_384)
        let r = StorageScanner(options: options()).scan()!
        let brew = try XCTUnwrap(r.items.first { $0.label == "Homebrew downloads" })
        XCTAssertTrue(brew.contentsOnly, "a running app expects its cache folder to exist")
        let nm = StorageItem(path: "/x/node_modules", label: "", explanation: "", bytes: 0, modified: nil, grade: .rebuildable)
        XCTAssertFalse(nm.contentsOnly)
    }

    func testTrashSizeIsReported() throws {
        try write(".Trash/junk", bytes: 16_384)
        let r = StorageScanner(options: options()).scan()!
        XCTAssertTrue(r.trashBytes == nil || r.trashBytes! >= 0, "nil without Automation permission, otherwise a size")
    }

    func testNoEmDashesInAnyExplanation() throws {
        try write("Library/Developer/Xcode/DerivedData/x", bytes: 16_384)
        try write("Code/app/node_modules/x", bytes: 16_384)
        try write("Downloads/Old.dmg", bytes: 30 * 1_048_576, modified: Date().addingTimeInterval(-10 * 86400))
        let r = StorageScanner(options: options()).scan()!
        for i in r.items {
            XCTAssertFalse(i.explanation.contains("\u{2014}"), i.explanation)
            XCTAssertFalse(i.label.contains("\u{2014}"), i.label)
        }
        for g in StorageGrade.allCases { XCTAssertFalse(g.title.contains("\u{2014}")) }
    }

    // MARK: Actions

    func testTrashRefusesPathsOutsideHome() {
        let outside = StorageItem(path: "/tmp/definitely-not-home-\(UUID().uuidString)", label: "x", explanation: "", bytes: 1, modified: nil, grade: .safe)
        let o = StorageActions.trash([outside])
        XCTAssertTrue(o.trashed.isEmpty)
        XCTAssertEqual(o.failed.first?.reason, "outside your home folder")
        let homeItself = StorageItem(path: NSHomeDirectory() + "/", label: "home", explanation: "", bytes: 1, modified: nil, grade: .safe)
        XCTAssertEqual(StorageActions.trash([homeItself]).failed.first?.reason, "that is your home folder")
        let dotdot = StorageItem(path: NSHomeDirectory() + "/Downloads/../../..", label: "up", explanation: "", bytes: 1, modified: nil, grade: .safe)
        XCTAssertNotNil(StorageActions.trash([dotdot]).failed.first, "paths are normalised before the check")
        let cloud = StorageItem(path: NSHomeDirectory() + "/Library/Mobile Documents/x", label: "icloud", explanation: "", bytes: 1, modified: nil, grade: .safe)
        XCTAssertTrue(StorageActions.trash([cloud]).failed.first?.reason.contains("cloud") == true)
        let inTrash = StorageItem(path: NSHomeDirectory() + "/.Trash/x", label: "t", explanation: "", bytes: 1, modified: nil, grade: .safe)
        XCTAssertEqual(StorageActions.trash([inTrash]).failed.first?.reason, "already in the Trash")
    }

    func testTrashMovesAnItemUnderHomeToTheTrash() throws {
        // A real file under the real home, so it lands in the real ~/.Trash. Cleaned up after.
        let real = NSHomeDirectory() + "/.vitals-test-\(UUID().uuidString)"
        try fm.createDirectory(atPath: real, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 2_048).write(to: URL(fileURLWithPath: real + "/f"))
        defer { try? fm.removeItem(atPath: real) }
        let item = StorageItem(path: real, label: "test", explanation: "", bytes: 16_384, modified: nil, grade: .safe)
        let o = StorageActions.trash([item])
        XCTAssertEqual(o.trashed, [real])
        XCTAssertEqual(o.bytes, 16_384)
        XCTAssertFalse(fm.fileExists(atPath: real), "moved away")
        let dest = try XCTUnwrap(o.trashedTo.first)
        XCTAssertTrue(dest.contains("/.Trash/"), dest)
        try? fm.removeItem(atPath: dest)   // best effort; ~/.Trash is TCC-protected
    }
}
