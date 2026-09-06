import Foundation
import UserNotifications
import os
import VitalsCore

/// User notifications with a "Clear" action. Shows banners even while Vitals is frontmost.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let category = "com.dhruv.vitals.issue"
    static let clearAction = "com.dhruv.vitals.clear"

    var onClear: ((String) -> Void)?
    private let center = UNUserNotificationCenter.current()
    private let log = Logger(subsystem: "com.dhruv.vitals", category: "notify")

    override init() {
        super.init()
        center.delegate = self
        let clear = UNNotificationAction(identifier: Self.clearAction, title: "Clear", options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [clear], intentIdentifiers: [])])
    }

    func requestAuthorization(_ done: @escaping (Bool) -> Void) {
        center.requestAuthorization(options: [.alert, .sound]) { ok, err in
            if let err { self.log.error("notification auth: \(err.localizedDescription)") }
            DispatchQueue.main.async { done(ok) }
        }
    }

    func post(_ issue: Issue) {
        let c = UNMutableNotificationContent()
        c.title = issue.title
        c.body = issue.detail + (issue.remedy.isActionable ? ". Open Vitals to \(issue.remedy.verb.lowercased()) it." : "")
        c.sound = issue.severity == .bad ? .default : nil
        c.categoryIdentifier = issue.remedy.isActionable ? Self.category : ""
        c.userInfo = ["key": issue.key]
        c.interruptionLevel = issue.severity == .bad ? .timeSensitive : .active
        center.add(UNNotificationRequest(identifier: issue.key, content: c, trigger: nil)) { err in
            if let err { self.log.error("post: \(err.localizedDescription)") }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler handler: @escaping () -> Void) {
        if response.actionIdentifier == Self.clearAction, let key = response.notification.request.content.userInfo["key"] as? String {
            DispatchQueue.main.async { self.onClear?(key) }
        }
        handler()
    }
}
