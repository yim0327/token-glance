import Foundation

/// Installs the statusline hook into Claude Code's settings.json, chaining the existing statusLine.
///
/// Only the `statusLine` member is edited (in place, see `JSONTextEditor`); other keys, order and
/// formatting are preserved. Before any write, settings.json is copied to
/// `settings.json.token-glance-backup-<UTC yyyyMMdd-HHmmss>`, and the original statusLine is kept in
/// `statusline-backup.json` exactly as written so uninstall can restore it.
public struct StatuslineInstaller {
    public enum Status: Equatable, Sendable {
        case notInstalled
        case installed
        /// We installed, but statusLine now points elsewhere (e.g. an OMC update rewrote it).
        case overwritten
        /// settings.json points at the hook, but the hook binary is gone.
        case hookMissing
        /// settings.json exists but cannot be read or is not a JSON object.
        case settingsUnreadable
    }

    public enum InstallOutcome: Equatable, Sendable {
        case installed, alreadyInstalled, repaired
    }

    public enum UninstallOutcome: Equatable, Sendable {
        /// The original statusLine was put back.
        case restored
        /// statusLine no longer pointed at the hook, so settings.json was not touched.
        case settingsLeftUnchanged
        case notInstalled
    }

    public enum InstallerError: Error, Equatable {
        case settingsUnreadable
        case settingsNotWritable
        case hookSourceMissing
        case notInstalled
    }

    public let settingsURL: URL
    public let paths: TokenGlancePaths
    /// The hook binary to copy into `paths.hookBinary`.
    public let hookSource: URL?
    public let now: () -> Date

    public init(settingsURL: URL, paths: TokenGlancePaths, hookSource: URL?, now: @escaping () -> Date = Date.init) {
        self.settingsURL = settingsURL
        self.paths = paths
        self.hookSource = hookSource
        self.now = now
    }

    /// `${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json`
    public static func defaultSettingsURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        ClaudeUsageProvider.defaultProjectsRoot(environment: environment, home: home)
            .deletingLastPathComponent()
            .appendingPathComponent("settings.json")
    }

    /// The statusLine command written to settings.json (shell-quoted absolute path).
    public var hookCommand: String {
        "'" + paths.hookBinary.path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    public func status() -> Status {
        let settings: JSONTextEditor?
        do { settings = try readSettings() } catch { return .settingsUnreadable }
        let current = settings.flatMap(currentCommand)
        if current == hookCommand {
            return FileManager.default.isExecutableFile(atPath: paths.hookBinary.path) ? .installed : .hookMissing
        }
        return StatuslineBackup.load(from: paths.statuslineBackup) == nil ? .notInstalled : .overwritten
    }

    @discardableResult
    public func install() throws -> InstallOutcome {
        switch status() {
        case .settingsUnreadable: throw InstallerError.settingsUnreadable
        case .installed: return .alreadyInstalled
        case .hookMissing:
            try copyHook()
            return .repaired
        case .overwritten: return try repair()
        case .notInstalled:
            try takeOver(createdBefore: false)
            return .installed
        }
    }

    /// Re-points statusLine at the hook, adopting whatever it currently runs as the new original.
    @discardableResult
    public func repair() throws -> InstallOutcome {
        switch status() {
        case .settingsUnreadable: throw InstallerError.settingsUnreadable
        case .notInstalled: throw InstallerError.notInstalled
        case .installed: return .alreadyInstalled
        case .hookMissing:
            try copyHook()
            return .repaired
        case .overwritten:
            let previous = StatuslineBackup.load(from: paths.statuslineBackup)
            try takeOver(createdBefore: previous?.createdSettingsFile ?? false)
            return .repaired
        }
    }

    @discardableResult
    public func uninstall() throws -> UninstallOutcome {
        guard let backup = StatuslineBackup.load(from: paths.statuslineBackup) else { return .notInstalled }
        let settings: JSONTextEditor?
        do { settings = try readSettings() } catch { throw InstallerError.settingsUnreadable }

        var outcome = UninstallOutcome.settingsLeftUnchanged
        if var editor = settings, currentCommand(editor) == backup.installedCommand {
            try ensureWritable()
            if let original = backup.originalStatusLineJSON, let member = editor.topLevelMember("statusLine") {
                editor.replace(member.value, with: original)
            } else {
                editor.removeTopLevelMember("statusLine")
            }
            try backUpSettingsFile()
            let isEmpty = (try? JSONSerialization.jsonObject(with: Data(editor.bytes)) as? [String: Any])?.isEmpty ?? false
            if backup.createdSettingsFile && isEmpty {
                try FileManager.default.removeItem(at: settingsURL)
            } else {
                try writeSettings(editor)
            }
            outcome = .restored
        }
        try? FileManager.default.removeItem(at: paths.statuslineBackup)
        try? FileManager.default.removeItem(at: paths.hookBinary)
        return outcome
    }

    // MARK: - Steps

    /// Makes statusLine run the hook, recording the current statusLine as the one to chain.
    private func takeOver(createdBefore: Bool) throws {
        let existing = try readSettings()
        try ensureWritable()
        try copyHook()

        var editor = try existing ?? JSONTextEditor("{}\n")
        let member = editor.topLevelMember("statusLine")
        let backup = StatuslineBackup(
            originalCommand: currentCommand(editor),
            originalStatusLineJSON: member.map { editor.text($0.value) },
            installedCommand: hookCommand,
            createdSettingsFile: createdBefore || existing == nil
        )

        let encodedHook = JSONTextEditor.encode(string: hookCommand)
        if let member, let command = editor.member("command", inObjectAt: member.value) {
            editor.replace(command.value, with: encodedHook)
        } else if let member {
            editor.replace(member.value, with: #"{"type": "command", "command": \#(encodedHook)}"#)
        } else {
            editor.insertTopLevelMember("statusLine", valueJSON: #"{"type": "command", "command": \#(encodedHook)}"#)
        }
        guard currentCommand(editor) == hookCommand else { throw InstallerError.settingsUnreadable }

        if existing != nil { try backUpSettingsFile() }
        try backup.write(to: paths.statuslineBackup)
        do {
            try writeSettings(editor)
        } catch {
            try? FileManager.default.removeItem(at: paths.statuslineBackup)
            throw error
        }
    }

    private func copyHook() throws {
        guard let hookSource, let data = try? Data(contentsOf: hookSource) else { throw InstallerError.hookSourceMissing }
        if hookSource.standardizedFileURL.resolvingSymlinksInPath() == paths.hookBinary.standardizedFileURL.resolvingSymlinksInPath() {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.hookBinary.path)
            return
        }
        try AtomicFile.write(data, to: paths.hookBinary, permissions: 0o755)
    }

    /// `nil` when settings.json does not exist; throws when it exists but is unusable.
    private func readSettings() throws -> JSONTextEditor? {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return nil }
        guard let data = try? Data(contentsOf: settingsURL), let text = String(data: data, encoding: .utf8) else {
            throw InstallerError.settingsUnreadable
        }
        do { return try JSONTextEditor(text) } catch { throw InstallerError.settingsUnreadable }
    }

    private func currentCommand(_ editor: JSONTextEditor) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(editor.bytes)) as? [String: Any] else { return nil }
        return (object["statusLine"] as? [String: Any])?["command"] as? String
    }

    private func ensureWritable() throws {
        let fileManager = FileManager.default
        let target = fileManager.fileExists(atPath: settingsURL.path) ? settingsURL : settingsURL.deletingLastPathComponent()
        if fileManager.fileExists(atPath: target.path), !fileManager.isWritableFile(atPath: target.path) {
            throw InstallerError.settingsNotWritable
        }
    }

    private func writeSettings(_ editor: JSONTextEditor) throws {
        let permissions = (try? FileManager.default.attributesOfItem(atPath: settingsURL.path)[.posixPermissions] as? Int) ?? 0o644
        try AtomicFile.write(Data(editor.bytes), to: settingsURL, permissions: permissions)
    }

    private func backUpSettingsFile() throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "settings.json.token-glance-backup-" + formatter.string(from: now())
        let directory = settingsURL.deletingLastPathComponent()
        var candidate = directory.appendingPathComponent(base)
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(suffix)")
            suffix += 1
        }
        try FileManager.default.copyItem(at: settingsURL, to: candidate)
    }
}
