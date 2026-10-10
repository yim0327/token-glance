import Foundation

/// User-facing actions on the statusline hook, mapped onto `StatuslineInstaller`.
public enum HookAction: String, Sendable, CaseIterable {
    case install, repair, uninstall

    /// Buttons to offer for a given installation state.
    public static func available(for status: StatuslineInstaller.Status) -> [HookAction] {
        switch status {
        case .notInstalled: [.install]
        case .installed: [.uninstall]
        case .overwritten: [.repair, .uninstall]
        case .hookMissing: [.install, .uninstall]
        case .settingsUnreadable: []
        }
    }

    /// Actions that edit settings.json to point at the hook ask for consent first.
    public var needsConsent: Bool { self != .uninstall }

    /// Runs the action and returns the resulting status.
    @discardableResult
    public func perform(with installer: StatuslineInstaller) throws -> StatuslineInstaller.Status {
        switch self {
        case .install: try installer.install()
        case .repair: try installer.repair()
        case .uninstall: try installer.uninstall()
        }
        return installer.status()
    }
}
