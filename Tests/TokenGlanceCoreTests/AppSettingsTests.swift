import Foundation
import Testing
@testable import TokenGlanceCore

struct AppSettingsTests {
    let home = URL(fileURLWithPath: "/Users/someone")

    func defaults() -> UserDefaults {
        let suite = "tg-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func defaultsWhenNothingStored() {
        let settings = AppSettings.load(from: defaults())
        #expect(settings == AppSettings())
        #expect(settings.percentMode == .remaining)
        #expect(settings.claudeEnabled && settings.codexEnabled)
        #expect(!settings.codexOnlineLimitsEnabled)
        #expect(settings.claudeConfigDir == nil && settings.codexHome == nil)
    }

    @Test func roundTripsThroughUserDefaults() {
        let store = defaults()
        var settings = AppSettings()
        settings.percentMode = .used
        settings.codexEnabled = false
        settings.codexOnlineLimitsEnabled = true
        settings.claudeConfigDir = "~/alt-claude"
        settings.save(to: store)
        #expect(AppSettings.load(from: store) == settings)
    }

    @Test func corruptStoredValuesFallBackToDefaults() {
        let store = defaults()
        store.set("sideways", forKey: AppSettings.Keys.percentMode)
        store.set(42, forKey: AppSettings.Keys.claudeConfigDir)
        store.set("yes", forKey: AppSettings.Keys.codexOnlineLimitsEnabled)
        let settings = AppSettings.load(from: store)
        #expect(settings.percentMode == .remaining)
        #expect(settings.claudeConfigDir == nil)
        #expect(!settings.codexOnlineLimitsEnabled)
    }

    @Test func atLeastOneToolStaysEnabled() {
        var settings = AppSettings()
        settings.claudeEnabled = false
        settings.codexEnabled = false
        #expect(settings.normalized.claudeEnabled)
        let store = defaults()
        settings.save(to: store)
        #expect(AppSettings.load(from: store).claudeEnabled)
    }

    @Test func languageAndNotificationSettingsRoundTripWithSafeDefaults() {
        let store = defaults()
        #expect(AppSettings.load(from: store).language == "system")
        #expect(!AppSettings.load(from: store).notificationsEnabled)
        #expect(AppSettings.load(from: store).notificationThresholds == NotificationThresholds(warning: 30, critical: 10))

        var settings = AppSettings()
        settings.language = "ko"
        settings.notificationsEnabled = true
        settings.notificationThresholds = NotificationThresholds(warning: 40, critical: 15)
        settings.save(to: store)
        #expect(AppSettings.load(from: store) == settings)

        store.set("fr", forKey: AppSettings.Keys.language)
        store.set(5, forKey: AppSettings.Keys.warningThreshold)   // not above critical (15)
        let loaded = AppSettings.load(from: store)
        #expect(loaded.language == "system")
        #expect(loaded.notificationThresholds == NotificationThresholds())
    }

    @Test func blankOverridesMeanDefault() {
        var settings = AppSettings()
        settings.claudeConfigDir = "   "
        settings.codexHome = ""
        #expect(settings.normalized.claudeConfigDir == nil)
        #expect(settings.normalized.codexHome == nil)
    }

    @Test func rootsUseOverridesThenEnvironmentThenHome() {
        var settings = AppSettings()
        #expect(LogRoots.resolve(settings, environment: [:], home: home)
            == LogRoots(claudeProjects: URL(fileURLWithPath: "/Users/someone/.claude/projects"), codexHome: URL(fileURLWithPath: "/Users/someone/.codex")))
        #expect(LogRoots.resolve(settings, environment: ["CLAUDE_CONFIG_DIR": "/env/claude", "CODEX_HOME": "/env/codex"], home: home)
            == LogRoots(claudeProjects: URL(fileURLWithPath: "/env/claude/projects"), codexHome: URL(fileURLWithPath: "/env/codex")))
        settings.claudeConfigDir = "~/alt"
        settings.codexHome = "/opt/codex"
        #expect(LogRoots.resolve(settings, environment: ["CLAUDE_CONFIG_DIR": "/env/claude"], home: home)
            == LogRoots(claudeProjects: URL(fileURLWithPath: "/Users/someone/alt/projects"), codexHome: URL(fileURLWithPath: "/opt/codex")))
    }

    @Test func pathValidation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tg-path-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("claude/projects"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("codex"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("file.txt"))

        #expect(PathValidation.check("", expecting: "projects", home: home) == .useDefault)
        #expect(PathValidation.check(root.appendingPathComponent("claude").path, expecting: "projects", home: home) == .valid)
        #expect(PathValidation.check(root.appendingPathComponent("codex").path, expecting: "sessions", home: home) == .missingSubfolder("sessions"))
        #expect(PathValidation.check(root.appendingPathComponent("nope").path, expecting: "projects", home: home) == .notFound)
        #expect(PathValidation.check(root.appendingPathComponent("file.txt").path, expecting: "projects", home: home) == .notADirectory)
        #expect(PathValidation.check("relative/path", expecting: "projects", home: home) == .notAbsolute)
        #expect(PathValidation.missingSubfolder("sessions").isAcceptable)
        #expect(!PathValidation.notFound.isAcceptable)
    }
}

struct WatchFilterTests {
    let filter = WatchFilter(rateLimitCache: URL(fileURLWithPath: "/s/TokenGlance/claude-rate-limits.json"))

    @Test func onlyLogsAndTheHookCacheTriggerRefresh() {
        #expect(filter.isRelevant(["/c/projects/-p/abc.jsonl"]))
        #expect(filter.isRelevant(["/x/.codex/sessions/2026/10/09/rollout-a.jsonl"]))
        #expect(filter.isRelevant(["/s/TokenGlance/claude-rate-limits.json"]))
        #expect(!filter.isRelevant(["/c/projects/-p/abc/tool-results/out.txt"]))
        #expect(!filter.isRelevant(["/s/TokenGlance/.claude-rate-limits.json.tmp-1-2"]))
        #expect(!filter.isRelevant(["/s/TokenGlance/statusline-backup.json"]))
        #expect(!filter.isRelevant([]))
        #expect(filter.isRelevant(["/c/projects/-p/notes.md", "/c/projects/-p/abc.jsonl"]))
    }

    @Test func directoryChangesRescan() {
        // FSEvents may report a directory (e.g. coalesced events or a removed folder): rescan to be safe.
        #expect(filter.isRelevant(["/c/projects/-p/"]))
        #expect(filter.isRelevant(["/c/projects/new-project"]))
    }
}
