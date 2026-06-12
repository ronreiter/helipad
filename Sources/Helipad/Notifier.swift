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

    func notifyBlocked(_ pr: PullRequest) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "PR blocked on you"
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
