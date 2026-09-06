import Foundation
import ServiceManagement
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

    public static func set(_ on: Bool, executable: String) throws {
        try? SMAppService.mainApp.unregister()   // never let two mechanisms launch it
        if on {
            let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
                <key>Label</key><string>\(label)</string>
                <key>ProgramArguments</key><array><string>\(executable)</string></array>
                <key>RunAtLoad</key><true/>
                <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
                <key>ThrottleInterval</key><integer>5</integer>
                <key>ProcessType</key><string>Interactive</string>
            </dict></plist>
            """
            try FileManager.default.createDirectory(atPath: (plistPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try xml.write(toFile: plistPath, atomically: true, encoding: .utf8)
            _ = Shell.run(["launchctl", "bootstrap", "gui/\(getuid())", plistPath], timeout: 10)
            log.notice("login item enabled")
        } else if isEnabled {
            _ = Shell.run(["launchctl", "bootout", "gui/\(getuid())", plistPath], timeout: 10)
            try FileManager.default.removeItem(atPath: plistPath)
            log.notice("login item disabled")
        }
    }
}
