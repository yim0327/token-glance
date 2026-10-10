import Foundation
import TokenGlanceCore

/// The UI language choice stored in settings.
public enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case korean = "ko"
    case english = "en"
}

/// Builds every user-facing string from Core values, in English or Korean.
///
/// The language is chosen per instance (not via the process locale), so switching it in settings
/// takes effect immediately without restarting the app. Numbers, dates and units use `locale`.
public struct Localizer: Sendable {
    /// "en" or "ko".
    public let languageCode: String
    public let locale: Locale
    public let timeZone: TimeZone
    private let table: [String: String]
    private let fallback: [String: String]

    public static let supportedLanguages = ["en", "ko"]

    public init(_ language: AppLanguage, preferredLanguages: [String] = Locale.preferredLanguages, timeZone: TimeZone = .current) {
        let code = Self.resolve(language, preferredLanguages: preferredLanguages)
        languageCode = code
        locale = Locale(identifier: code == "ko" ? "ko_KR" : "en_US")
        self.timeZone = timeZone
        table = Self.loadTable(code)
        fallback = code == "en" ? [:] : Self.loadTable("en")
    }

    /// `.system` picks Korean when it is the first supported language the user prefers, else English.
    public static func resolve(_ language: AppLanguage, preferredLanguages: [String]) -> String {
        switch language {
        case .korean: return "ko"
        case .english: return "en"
        case .system:
            for preferred in preferredLanguages {
                let base = String(preferred.prefix(2)).lowercased()
                if supportedLanguages.contains(base) { return base }
            }
            return "en"
        }
    }

    /// The localized string for `key` (English, then the key itself, as fallbacks).
    public func callAsFunction(_ key: String) -> String {
        table[key] ?? fallback[key] ?? key
    }

    /// The localized format for `key` filled with `arguments`.
    public func callAsFunction(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: self(key), locale: locale, arguments: arguments)
    }

    // MARK: - Resources

    /// The resource bundle. In the app it is copied to `Contents/Resources` by scripts/bundle-app.sh;
    /// during development and tests it is next to the SwiftPM build products.
    static let resourceBundle: Bundle? = {
        let name = "token-glance_TokenGlanceText.bundle"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name),
            Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent().appendingPathComponent(name),
        ]
        for case let url? in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let bundle = Bundle(url: url) { return bundle }
        }
        return nil
    }()

    private final class BundleToken {}

    static func loadTable(_ code: String) -> [String: String] {
        guard let url = resourceBundle?.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: code),
              let table = NSDictionary(contentsOf: url) as? [String: String]
        else { return [:] }
        return table
    }

    /// Whether the string tables were found (checked by `--print-state` and tests).
    public var hasResources: Bool { !table.isEmpty }

    /// Where the string tables were loaded from (diagnostics).
    public static var resourceBundleURL: URL? { resourceBundle?.bundleURL }
}

// MARK: - Values

extension Localizer {
    public func toolName(_ tool: Tool) -> String {
        tool == .claude ? self("tool.claude") : self("tool.codex")
    }

    public func windowName(_ kind: LimitWindow.Kind) -> String {
        kind == .session ? self("window.session") : self("window.weekly")
    }

    /// Coarse countdown: "2h 10m" / "2시간 10분", "<1m", "now" once reached.
    public func countdown(to target: Date, now: Date) -> String {
        let parts = DisplayFormat.durationParts(until: target, now: now)
        if parts.isZero { return self("duration.now") }
        if parts.days > 0 { return self("duration.daysHours", parts.days, parts.hours) }
        if parts.hours > 0 { return self("duration.hoursMinutes", parts.hours, parts.minutes) }
        if parts.minutes > 0 { return self("duration.minutes", parts.minutes) }
        return self("duration.lessThanMinute")
    }

    /// Ticking countdown: "2:05:09", or "3d 0:01:01" / "3일 0:01:01".
    public func clockCountdown(to target: Date, now: Date) -> String {
        let parts = DisplayFormat.durationParts(until: target, now: now)
        let clock = String(format: "%d:%02d:%02d", parts.hours, parts.minutes, parts.seconds)
        return parts.days > 0 ? self("clock.daysPrefix", parts.days, clock) : clock
    }

    public func relativeAge(of date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return self("age.justNow") }
        if seconds < 3600 { return self("age.minutes", seconds / 60) }
        if seconds < 86_400 { return self("age.hours", seconds / 3600) }
        return self("age.days", seconds / 86_400)
    }

    /// Compact token count in the UI language: "1.2M" / "120만".
    public func tokens(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(locale))
    }

    /// Full token count with grouping: "1,234,567".
    public func tokensExact(_ count: Int) -> String {
        count.formatted(.number.locale(locale))
    }

    /// Absolute reset time, e.g. "Oct 9, 3:30 PM" / "10월 9일 오후 3:30".
    public func resetTime(_ date: Date) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)
        style.timeZone = timeZone
        return date.formatted(style)
    }

    /// Short day label for charts, e.g. "Oct 9" / "10월 9일".
    public func dayLabel(_ date: Date) -> String {
        var style = Date.FormatStyle().month(.abbreviated).day().locale(locale)
        style.timeZone = timeZone
        return date.formatted(style)
    }

    public func unavailable(_ reason: UnavailableReason) -> String {
        switch reason {
        case .noData: self("reason.noData")
        case .corrupt: self("reason.corrupt")
        case .stale: self("reason.stale")
        case .unsupportedVersion: self("reason.unsupportedVersion")
        case .hookNotInstalled: self("reason.hookNotInstalled")
        case .hookOverwritten: self("reason.hookOverwritten")
        case .hookMissing: self("reason.hookMissing")
        case .settingsUnreadable: self("reason.settingsUnreadable")
        }
    }

    public func pathValidation(_ validation: PathValidation) -> String {
        switch validation {
        case .useDefault: self("path.useDefault")
        case .valid: self("path.valid")
        case .missingSubfolder(let name): self("path.missingSubfolder", name)
        case .notFound: self("path.notFound")
        case .notADirectory: self("path.notADirectory")
        case .notAbsolute: self("path.notAbsolute")
        }
    }

    public func hookError(_ error: Error) -> String {
        switch error as? StatuslineInstaller.InstallerError {
        case .settingsUnreadable: self("hook.error.settingsUnreadable")
        case .settingsNotWritable: self("hook.error.settingsNotWritable")
        case .hookSourceMissing: self("hook.error.hookSourceMissing")
        case .notInstalled: self("hook.error.notInstalled")
        case nil: error.localizedDescription
        }
    }

    public func thresholdError(_ error: NotificationThresholds.ValidationError) -> String {
        switch error {
        case .outOfRange: self("settings.notifications.invalidRange")
        case .warningNotAboveCritical: self("settings.notifications.invalidOrder")
        }
    }
}

// MARK: - Composite texts

extension Localizer {
    /// One line per enabled tool, e.g. "Claude session 62% left, resets in 2h 10m · weekly 76% left".
    public func tooltip(states: [ToolState], mode: PercentMode, now: Date) -> String {
        states.filter(\.isEnabled).map { tooltipLine($0, mode: mode, now: now) }.joined(separator: "\n")
    }

    func tooltipLine(_ state: ToolState, mode: PercentMode, now: Date) -> String {
        let name = toolName(state.tool)
        guard let session = state.session else {
            return self("tooltip.unavailable", name, unavailable(state.unavailableReason ?? .noData))
        }
        let reading = DisplayFormat.reading(session)
        var text = mode == .remaining
            ? self("tooltip.window.left", name, self("window.session.short"), reading.left)
            : self("tooltip.window.used", name, self("window.session.short"), reading.used)
        if let resetsAt = session.resetsAt {
            text += self("tooltip.resetsIn", countdown(to: resetsAt, now: now))
        } else if session.isReset {
            text += self("tooltip.windowReset")
        }
        if let weekly = state.weekly {
            let weeklyReading = DisplayFormat.reading(weekly)
            text += mode == .remaining ? self("tooltip.weekly.left", weeklyReading.left) : self("tooltip.weekly.used", weeklyReading.used)
        }
        return text
    }

    /// Title and body of the consent dialog shown before installing or repairing the hook.
    /// Paths under `home` are shown with `~`.
    public func hookConsent(settingsURL: URL, paths: TokenGlancePaths, hasExistingStatusLine: Bool,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) -> (title: String, body: String) {
        let settings = Self.abbreviate(settingsURL.path, home: home)
        let support = Self.abbreviate(paths.supportDirectory.path, home: home)
        var lines = [
            self("consent.intro"),
            self("consent.changeKey", settings),
            self("consent.backup", settings),
            self("consent.copyHook", support),
            self("consent.privacy"),
        ]
        if hasExistingStatusLine { lines.append(self("consent.keepsWorking")) }
        lines.append(self("consent.undo"))
        return (self("consent.title"), lines.joined(separator: "\n"))
    }

    static func abbreviate(_ path: String, home: URL) -> String {
        let homePath = home.path
        return path.hasPrefix(homePath + "/") ? "~" + path.dropFirst(homePath.count) : path
    }

    /// Title and body of a limit notification.
    public func notification(_ event: LimitNotification) -> (title: String, body: String) {
        let tool = toolName(event.tool), window = windowName(event.window)
        switch event.kind {
        case .warning:
            return (self("notify.warning.title", tool, window, event.leftPercent), self("notify.body.resets", resetTime(event.resetsAt)))
        case .critical:
            return (self("notify.critical.title", tool, window, event.leftPercent), self("notify.body.resets", resetTime(event.resetsAt)))
        case .reset:
            return (self("notify.reset.title", tool, window), self("notify.body.reset", event.leftPercent))
        }
    }
}
