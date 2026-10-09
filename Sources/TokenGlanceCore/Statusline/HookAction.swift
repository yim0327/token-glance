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

/// Text of the consent dialog shown before installing or repairing the hook.
public struct HookConsent: Equatable, Sendable {
    public let title: String
    public let body: String

    public init(settingsURL: URL, paths: TokenGlancePaths, hasExistingStatusLine: Bool,
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let settings = Self.abbreviate(settingsURL.path, home: home)
        let support = Self.abbreviate(paths.supportDirectory.path, home: home)
        title = "Install the Claude limits hook?"
        var lines = [
            "Claude Code only shares its 5-hour and weekly limits with statusline commands. Token Glance will:",
            "• Change one key, statusLine.command, in \(settings). Other settings are left untouched.",
            "• First copy the whole file to \(settings).token-glance-backup-<time>.",
            "• Copy a small hook program to \(support)/bin and save your previous statusLine in \(support)/statusline-backup.json.",
            "The hook only records the limit percentages and reset times. It does not use the network and does not store prompts, paths or session names.",
        ]
        if hasExistingStatusLine {
            lines.append("Your current statusline keeps working: the hook runs it afterwards with the same input.")
        }
        lines.append("To undo, choose Uninstall in Token Glance settings; your previous statusLine is restored.")
        body = lines.joined(separator: "\n")
    }

    static func abbreviate(_ path: String, home: URL) -> String {
        let homePath = home.path
        return path.hasPrefix(homePath + "/") ? "~" + path.dropFirst(homePath.count) : path
    }
}
