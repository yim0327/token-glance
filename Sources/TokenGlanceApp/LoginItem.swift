import Foundation
import ServiceManagement

/// "Open at login" via `SMAppService.mainApp`. Verified to register and unregister with the ad hoc
/// signed bundle (2026-10-09). macOS may still ask for approval; errors are surfaced to the UI.
/// The login item points at the app's current location, so move the app before enabling it.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Waiting for the user to approve it in System Settings › General › Login Items.
    /// (`.notFound` is also what a never-registered app reports, so it is not treated as an error.)
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// Returns the system error description on failure.
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
