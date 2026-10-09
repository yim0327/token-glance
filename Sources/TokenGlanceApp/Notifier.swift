import AppKit
import Foundation
import UserNotifications

/// Delivers limit alerts through UserNotifications. Permission is requested only when the user turns
/// notifications on; nothing is sent otherwise.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Authorization: Equatable {
        /// Not running as an app bundle (e.g. `--print-state`): notifications are not available.
        case unavailable
        case notDetermined
        case denied
        case authorized
    }

    /// `UNUserNotificationCenter` requires a bundled app; it is never touched otherwise.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    override init() {
        super.init()
        center?.delegate = self
    }

    func authorization() async -> Authorization {
        guard let center else { return .unavailable }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    /// Shows the system permission prompt if the user has not decided yet.
    func requestAuthorization() async -> Authorization {
        guard let center else { return .unavailable }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        return await authorization()
    }

    /// Returns an error description if delivery failed.
    func send(id: String, title: String, body: String) async -> String? {
        guard let center else { return nil }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    // A menu bar app is often "active" while its popover is open; show banners anyway.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
