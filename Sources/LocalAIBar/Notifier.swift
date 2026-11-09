import Foundation
import UserNotifications

/// macOS notifications (model crashed, restarted, turned off). Only inside a real .app bundle:
/// UNUserNotificationCenter needs one and traps when run from `swift run`.
@MainActor
enum Notifier {
    static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    private static let delegate = Delegate()

    static func requestAuthorization() {
        guard available else { return }
        let c = UNUserNotificationCenter.current()
        c.delegate = delegate
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func send(_ title: String, _ body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Show banners even while the menu-bar popover is open (the app counts as active then).
    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner, .sound])
        }
    }
}
