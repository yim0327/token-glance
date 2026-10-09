import Foundation
import ServiceManagement

/// "Open at login" via `SMAppService.mainApp`. Verified to register and unregister with the ad hoc
/// signed bundle (2026-10-09). macOS may still ask for approval; errors are surfaced to the UI.
/// The login item points at the app's current location, so move the app before enabling it.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Human-readable state when it is not simply on or off.
    static var note: String? {
        switch SMAppService.mainApp.status {
        case .requiresApproval: String(localized: "Waiting for approval in System Settings › General › Login Items.")
        // `.notFound` is also what an app that was never registered reports, so it is not an error.
        case .enabled, .notRegistered, .notFound: nil
        @unknown default: nil
        }
    }

    /// Returns an error message on failure.
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return String(localized: "Could not change the login item: \(error.localizedDescription)")
        }
    }
}
