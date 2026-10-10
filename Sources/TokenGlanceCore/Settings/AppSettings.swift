import Foundation

/// User preferences, stored in UserDefaults. Unknown or malformed stored values fall back to defaults.
public struct AppSettings: Equatable, Sendable {
    public var percentMode: PercentMode = .remaining
    public var claudeEnabled = true
    public var codexEnabled = true
    /// Opt-in account limit reads through the installed Codex App Server.
    public var codexOnlineLimitsEnabled = false
    /// Opt-in plan limit reads through the installed Claude Code (`get_usage`).
    public var claudeOnlineLimitsEnabled = false
    /// Overrides `CLAUDE_CONFIG_DIR` (the folder that contains `projects/`). `nil` = default.
    public var claudeConfigDir: String?
    /// Overrides `CODEX_HOME` (the folder that contains `sessions/`). `nil` = default.
    public var codexHome: String?
    /// "system", "ko" or "en" (see TokenGlanceText.AppLanguage).
    public var language = "system"
    /// Limit notifications; off until the user turns them on.
    public var notificationsEnabled = false
    public var notificationThresholds = NotificationThresholds()

    public static let languages = ["system", "ko", "en"]

    public init() {}

    public enum Keys {
        public static let percentMode = "percentMode"
        public static let claudeEnabled = "claudeEnabled"
        public static let codexEnabled = "codexEnabled"
        public static let codexOnlineLimitsEnabled = "codexOnlineLimitsEnabled"
        public static let claudeOnlineLimitsEnabled = "claudeOnlineLimitsEnabled"
        public static let claudeConfigDir = "claudeConfigDir"
        public static let codexHome = "codexHome"
        public static let language = "language"
        public static let notificationsEnabled = "notificationsEnabled"
        public static let warningThreshold = "notificationWarningThreshold"
        public static let criticalThreshold = "notificationCriticalThreshold"
    }

    /// Blank overrides become `nil`; at least one tool stays enabled (Claude if both were off);
    /// unknown languages and invalid thresholds fall back to the defaults.
    public var normalized: AppSettings {
        var copy = self
        copy.claudeConfigDir = Self.nonBlank(claudeConfigDir)
        copy.codexHome = Self.nonBlank(codexHome)
        if !copy.claudeEnabled && !copy.codexEnabled { copy.claudeEnabled = true }
        if !Self.languages.contains(copy.language) { copy.language = "system" }
        if copy.notificationThresholds.validationError != nil { copy.notificationThresholds = NotificationThresholds() }
        return copy
    }

    public static func load(from defaults: UserDefaults) -> AppSettings {
        var settings = AppSettings()
        if let raw = defaults.string(forKey: Keys.percentMode), let mode = PercentMode(rawValue: raw) { settings.percentMode = mode }
        if let value = defaults.object(forKey: Keys.claudeEnabled) as? Bool { settings.claudeEnabled = value }
        if let value = defaults.object(forKey: Keys.codexEnabled) as? Bool { settings.codexEnabled = value }
        if let value = defaults.object(forKey: Keys.codexOnlineLimitsEnabled) as? Bool { settings.codexOnlineLimitsEnabled = value }
        if let value = defaults.object(forKey: Keys.claudeOnlineLimitsEnabled) as? Bool { settings.claudeOnlineLimitsEnabled = value }
        settings.claudeConfigDir = defaults.object(forKey: Keys.claudeConfigDir) as? String
        settings.codexHome = defaults.object(forKey: Keys.codexHome) as? String
        if let language = defaults.string(forKey: Keys.language) { settings.language = language }
        if let value = defaults.object(forKey: Keys.notificationsEnabled) as? Bool { settings.notificationsEnabled = value }
        if let warning = defaults.object(forKey: Keys.warningThreshold) as? Int,
           let critical = defaults.object(forKey: Keys.criticalThreshold) as? Int {
            settings.notificationThresholds = NotificationThresholds(warning: warning, critical: critical)
        }
        return settings.normalized
    }

    public func save(to defaults: UserDefaults) {
        let settings = normalized
        defaults.set(settings.percentMode.rawValue, forKey: Keys.percentMode)
        defaults.set(settings.claudeEnabled, forKey: Keys.claudeEnabled)
        defaults.set(settings.codexEnabled, forKey: Keys.codexEnabled)
        defaults.set(settings.codexOnlineLimitsEnabled, forKey: Keys.codexOnlineLimitsEnabled)
        defaults.set(settings.claudeOnlineLimitsEnabled, forKey: Keys.claudeOnlineLimitsEnabled)
        defaults.set(settings.claudeConfigDir, forKey: Keys.claudeConfigDir)
        defaults.set(settings.codexHome, forKey: Keys.codexHome)
        defaults.set(settings.language, forKey: Keys.language)
        defaults.set(settings.notificationsEnabled, forKey: Keys.notificationsEnabled)
        defaults.set(settings.notificationThresholds.warning, forKey: Keys.warningThreshold)
        defaults.set(settings.notificationThresholds.critical, forKey: Keys.criticalThreshold)
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// Where logs are read from: settings override, then `CLAUDE_CONFIG_DIR` / `CODEX_HOME`, then `~`.
public struct LogRoots: Equatable, Sendable {
    public var claudeProjects: URL
    public var codexHome: URL

    public init(claudeProjects: URL, codexHome: URL) {
        self.claudeProjects = claudeProjects
        self.codexHome = codexHome
    }

    /// Claude Code's settings.json next to `projects/`.
    public var claudeSettingsFile: URL {
        claudeProjects.deletingLastPathComponent().appendingPathComponent("settings.json")
    }

    public static func resolve(
        _ settings: AppSettings,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> LogRoots {
        let settings = settings.normalized
        let claude = settings.claudeConfigDir.map { PathValidation.expand($0, home: home).appendingPathComponent("projects") }
            ?? ClaudeUsageProvider.defaultProjectsRoot(environment: environment, home: home)
        let codex = settings.codexHome.map { PathValidation.expand($0, home: home) }
            ?? CodexUsageProvider.defaultCodexHome(environment: environment, home: home)
        return LogRoots(claudeProjects: claude, codexHome: codex)
    }
}

/// Result of checking a folder override typed by the user.
public enum PathValidation: Equatable, Sendable {
    case useDefault
    case valid
    /// Exists, but the expected subfolder (e.g. `projects`) is not there yet. Accepted with a warning.
    case missingSubfolder(String)
    case notFound
    case notADirectory
    case notAbsolute

    public var isAcceptable: Bool {
        switch self {
        case .useDefault, .valid, .missingSubfolder: true
        case .notFound, .notADirectory, .notAbsolute: false
        }
    }

    public static func check(_ input: String, expecting subfolder: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> PathValidation {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .useDefault }
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~") else { return .notAbsolute }
        let url = expand(trimmed, home: home)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return .notFound }
        guard isDirectory.boolValue else { return .notADirectory }
        var subIsDirectory: ObjCBool = false
        let hasSubfolder = FileManager.default.fileExists(atPath: url.appendingPathComponent(subfolder).path, isDirectory: &subIsDirectory)
        return hasSubfolder && subIsDirectory.boolValue ? .valid : .missingSubfolder(subfolder)
    }

    /// Expands a leading `~` to `home`.
    static func expand(_ path: String, home: URL) -> URL {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))) }
        return URL(fileURLWithPath: path)
    }
}
