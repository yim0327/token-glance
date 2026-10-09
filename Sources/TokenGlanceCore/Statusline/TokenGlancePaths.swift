import Foundation

/// Files owned by Token Glance, under `~/Library/Application Support/TokenGlance`
/// (overridable with `TOKEN_GLANCE_SUPPORT_DIR`, used by tests and measurements).
public struct TokenGlancePaths: Equatable, Sendable {
    public var supportDirectory: URL

    public init(supportDirectory: URL) {
        self.supportDirectory = supportDirectory
    }

    public static let supportDirectoryVariable = "TOKEN_GLANCE_SUPPORT_DIR"

    public static func `default`(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> TokenGlancePaths {
        if let override = environment[supportDirectoryVariable], !override.isEmpty {
            return TokenGlancePaths(supportDirectory: URL(fileURLWithPath: override))
        }
        return TokenGlancePaths(supportDirectory: home.appendingPathComponent("Library/Application Support/TokenGlance"))
    }

    /// Rate limits captured by the statusline hook.
    public var rateLimitCache: URL { supportDirectory.appendingPathComponent("claude-rate-limits.json") }
    /// The user's original statusLine, chained by the hook and restored on uninstall.
    public var statuslineBackup: URL { supportDirectory.appendingPathComponent("statusline-backup.json") }
    /// Installed copy of the hook binary referenced from settings.json.
    public var hookBinary: URL { supportDirectory.appendingPathComponent("bin/token-glance-hook") }
}
