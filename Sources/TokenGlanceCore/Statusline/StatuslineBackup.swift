import Foundation

/// What the installer replaced, kept in `statusline-backup.json`.
///
/// `originalCommand` is stored exactly as written in settings.json (shell syntax such as
/// `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` is not expanded); the hook runs it through `/bin/sh -c`.
public struct StatuslineBackup: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// The original `statusLine.command` the hook chains to; `nil` if there was none.
    public var originalCommand: String?
    /// The original `statusLine` value as raw JSON text, restored verbatim on uninstall;
    /// `nil` if settings.json had no `statusLine`.
    public var originalStatusLineJSON: String?
    /// The command the installer wrote, used to tell "installed" from "overwritten".
    public var installedCommand: String
    /// settings.json did not exist before install.
    public var createdSettingsFile: Bool

    public init(originalCommand: String?, originalStatusLineJSON: String?, installedCommand: String, createdSettingsFile: Bool = false) {
        schemaVersion = Self.currentSchemaVersion
        self.originalCommand = originalCommand
        self.originalStatusLineJSON = originalStatusLineJSON
        self.installedCommand = installedCommand
        self.createdSettingsFile = createdSettingsFile
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case originalCommand = "original_command"
        case originalStatusLineJSON = "original_status_line_json"
        case installedCommand = "installed_command"
        case createdSettingsFile = "created_settings_file"
    }

    public static func load(from url: URL) -> StatuslineBackup? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StatuslineBackup.self, from: data)
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try AtomicFile.write(encoder.encode(self), to: url, permissions: 0o600)
    }

    /// The command to chain, or `nil` when there is nothing meaningful to run.
    public var chainCommand: String? {
        guard let originalCommand, !originalCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return originalCommand
    }
}
