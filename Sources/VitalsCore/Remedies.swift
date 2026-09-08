import Foundation
import AppKit
import os

/// Things Vitals can do to the machine. Every call here is a side effect the user asked for.
public enum Remedies {
    private static let log = Logger(subsystem: "com.dhruv.vitals", category: "remedies")

    // MARK: - Processes

    /// Terminate politely, then forcibly. Never touches pid 0/1, this process, or another user's process.
    /// - Returns: pids that are gone afterwards.
    @discardableResult
    public static func terminate(_ pids: [pid_t], grace: TimeInterval = 2.0) -> [pid_t] {
        let me = getpid()
        let targets = pids.filter { $0 > 1 && $0 != me && ownedByUs($0) }
        for pid in targets { Darwin.kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline, targets.contains(where: alive) { Thread.sleep(forTimeInterval: 0.1) }
        for pid in targets where alive(pid) { Darwin.kill(pid, SIGKILL) }
        Thread.sleep(forTimeInterval: 0.2)
        let gone = targets.filter { !alive($0) }
        log.notice("terminated \(gone.count)/\(targets.count) processes")
        return gone
    }

    /// Ask a running application to quit normally so it can save state. Never escalates to a kill:
    /// an app that puts up "Save changes?" is doing its job. If it is still running after `grace`
    /// the caller reports that and the user can choose Kill explicitly.
    /// - Returns: the app's pids that are gone afterwards (empty if it declined).
    public static func quitApp(named name: String, pids: [pid_t], grace: TimeInterval = 8.0) -> [pid_t] {
        let mine = Set(pids)
        let matches = NSWorkspace.shared.runningApplications.filter { mine.contains($0.processIdentifier) }
        guard !matches.isEmpty else {
            log.notice("\(name): no running application matches its pids; nothing to quit")
            return []
        }
        for app in matches { app.terminate() }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline, matches.contains(where: { !$0.isTerminated }) { Thread.sleep(forTimeInterval: 0.2) }
        let gone = pids.filter { !alive($0) }
        log.notice("\(name): asked to quit, \(gone.count)/\(pids.count) processes gone")
        return gone
    }

    /// Alive means present and not a zombie. `kill(pid, 0)` alone says yes for zombies, which would make
    /// a helper whose parent is hung look unkillable.
    static func alive(_ pid: pid_t) -> Bool {
        var bsd = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return false }
        return bsd.pbi_status != UInt32(SZOMB)
    }

    static func ownedByUs(_ pid: pid_t) -> Bool {
        var bsd = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return false }
        return bsd.pbi_uid == getuid()
    }

    // MARK: - Restart

    /// Shows the system restart confirmation through System Events. Prompts for Automation
    /// permission the first time; `NSAppleEventsUsageDescription` explains why.
    public static func requestRestart() -> Error? {
        var err: NSDictionary?
        NSAppleScript(source: "tell application \"System Events\" to restart")?.executeAndReturnError(&err)
        if let err {
            let msg = err[NSAppleScript.errorMessage] as? String ?? "not permitted"
            log.error("System Events restart failed: \(msg)")
            return NSError(domain: "Vitals", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not ask macOS to restart (\(msg)). Use the Apple menu."])
        }
        return nil
    }
}

/// Minimal subprocess runner. No shell, a fixed search path, output drained as it arrives so a
/// chatty child can never block on a full pipe.
public enum Shell {
    public struct Result { public let status: Int32; public let output: String; public var ok: Bool { status == 0 } }

    static let searchPath = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    public static func which(_ tool: String) -> String? {
        for dir in searchPath {
            let p = dir + "/" + tool
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    public static func run(_ argv: [String], timeout: TimeInterval) -> Result {
        guard let exe = which(argv[0]) else { return Result(status: 127, output: "\(argv[0]) not found") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = Array(argv.dropFirst())
        p.environment = ["PATH": searchPath.joined(separator: ":"), "HOME": NSHomeDirectory()]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        // Drain on a background thread until EOF. A blocked reader would let a chatty child
        // fill the pipe and hang; a reader that stops early would lose the tail. This does neither.
        var collected = Data()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            collected = pipe.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return Result(status: 126, output: error.localizedDescription) }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut { Darwin.kill(p.processIdentifier, SIGKILL); _ = exited.wait(timeout: .now() + 1) }
        }
        // EOF arrives once every writer has closed; grandchildren holding the pipe are rare, so cap the wait.
        _ = drained.wait(timeout: .now() + 5)
        return Result(status: p.terminationStatus, output: String(decoding: collected, as: UTF8.self))
    }
}
