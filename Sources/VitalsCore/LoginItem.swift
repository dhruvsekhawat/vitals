import Foundation
import os

/// Start-at-login via a user LaunchAgent.
///
/// Chosen over `SMAppService` because launchd also relaunches Vitals if it crashes
/// (`KeepAlive` on unsuccessful exit). A normal Quit exits 0 and stays quit.
public enum LoginItem {
    public static let label = "com.dhruv.vitals"
    private static let log = Logger(subsystem: "com.dhruv.vitals", category: "login")

    public static var plistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"
    }

    public static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistPath) }

    /// The executable the agent currently points at, if any.
    public static var programPath: String? {
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return (plist["ProgramArguments"] as? [String])?.first
    }

    /// True when this process was started by launchd as the agent. Booting the job out from
    /// inside it would kill us mid-operation.
    public static var isCurrentProcessTheAgent: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label
    }

    /// Enable or disable. Safe to call from the agent itself. Blocking: runs `launchctl`.
    public static func set(_ on: Bool, executable: String) throws {
        let fm = FileManager.default
        if on {
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [executable],
                "RunAtLoad": true,
                "KeepAlive": ["SuccessfulExit": false],
                "ThrottleInterval": 5,
                "ProcessType": "Interactive",
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try fm.createDirectory(atPath: (plistPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
            if !isCurrentProcessTheAgent {
                let r = Shell.run(["launchctl", "bootstrap", "gui/\(getuid())", plistPath], timeout: 10)
                // "already bootstrapped" (EEXIST, status 37) is fine; anything else is not.
                // Already loaded shows up as EEXIST (37) on older systems and EIO (5) on recent ones.
                if !r.ok && r.status != 37 && r.status != 5 && !r.output.contains("already") {
                    try? fm.removeItem(atPath: plistPath)
                    throw NSError(domain: "Vitals", code: 3, userInfo: [NSLocalizedDescriptionKey: "launchctl bootstrap failed: \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))"])
                }
            }
            log.notice("login item enabled")
        } else {
            guard isEnabled else { return }
            // Remove the file first so the state on disk is right even if we die below.
            try fm.removeItem(atPath: plistPath)
            if !isCurrentProcessTheAgent {
                _ = Shell.run(["launchctl", "bootout", "gui/\(getuid())/\(label)"], timeout: 10)
            }
            // If we are the agent, the loaded job simply ends at logout and will not return.
            log.notice("login item disabled")
        }
    }
}
