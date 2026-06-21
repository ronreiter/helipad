import AppKit
import UserNotifications

/// Posts a user notification when a PR becomes blocked on the author.
/// Only active inside the .app bundle — UNUserNotificationCenter traps in
/// bare SwiftPM executables, which have no bundle identifier.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private let isAvailable = Bundle.main.bundleIdentifier != nil

    func start() {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Triggers the native permission prompt when notifications haven't been
    /// requested yet. If the user previously denied them — macOS won't prompt
    /// again — opens System Settings' Notifications pane so they can flip it on
    /// without hunting. Wired to the "Enable notifications…" menu item.
    func promptForAuthorization() {
        guard isAvailable else {
            showAlert(title: "Notifications unavailable",
                      info: "This build has no bundle identifier, so macOS can't deliver notifications. Use the Helipad app installed from the DMG.")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .notDetermined:
                    center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
                case .denied:
                    // Ventura+ pane id, with a fallback to the legacy one.
                    let modern = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
                    if !NSWorkspace.shared.open(modern) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
                    }
                default:
                    self.showAlert(title: "Notifications are on",
                                   info: "Helipad already has permission to notify you.")
                }
            }
        }
    }

    private func showAlert(title: String, info: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Posts a notification for `pr` with a condition-specific `title`
    /// (e.g. "PR approved — ready to merge", "PR awaiting your review").
    func notify(_ pr: PullRequest, title: String) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = "\(pr.repoShortName) #\(pr.number)"
        content.body = pr.title
        content.sound = .default
        content.userInfo = ["url": pr.url]
        let request = UNNotificationRequest(identifier: pr.url, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // Show banners even while the panel is frontmost.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // Clicking the notification opens the PR.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let url = (response.notification.request.content.userInfo["url"] as? String).flatMap(URL.init) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }
}
