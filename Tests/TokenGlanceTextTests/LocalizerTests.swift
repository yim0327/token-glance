import Foundation
import Testing
@testable import TokenGlanceCore
@testable import TokenGlanceText

struct LocalizationResourceTests {
    let en = Localizer.loadTable("en")
    let ko = Localizer.loadTable("ko")

    @Test func bothTablesLoadFromTheResourceBundle() {
        #expect(Localizer.resourceBundle != nil)
        #expect(en.count > 100)
        #expect(Localizer(.english).hasResources && Localizer(.korean).hasResources)
    }

    @Test func tablesHaveTheSameKeys() {
        #expect(Set(en.keys).subtracting(ko.keys).sorted() == [])
        #expect(Set(ko.keys).subtracting(en.keys).sorted() == [])
    }

    @Test func formatSpecifiersMatchPerKey() {
        let pattern = try! NSRegularExpression(pattern: "%(\\d\\$)?[@dfs%]")
        func specifiers(_ text: String) -> [String] {
            pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .map { String(text[Range($0.range, in: text)!]) }.sorted()
        }
        for (key, english) in en {
            #expect(specifiers(english) == specifiers(ko[key] ?? ""), "format mismatch for \(key)")
        }
    }
}

struct LanguageSelectionTests {
    @Test func systemLanguageFollowsPreferredLanguages() {
        #expect(Localizer.resolve(.system, preferredLanguages: ["ko-KR", "en-US"]) == "ko")
        #expect(Localizer.resolve(.system, preferredLanguages: ["fr-FR", "ko-KR"]) == "ko")
        #expect(Localizer.resolve(.system, preferredLanguages: ["fr-FR", "de-DE"]) == "en")
        #expect(Localizer.resolve(.system, preferredLanguages: []) == "en")
        #expect(Localizer.resolve(.english, preferredLanguages: ["ko-KR"]) == "en")
        #expect(Localizer.resolve(.korean, preferredLanguages: ["en-US"]) == "ko")
    }

    @Test func missingKeyFallsBackToTheKey() {
        #expect(Localizer(.korean)("no.such.key") == "no.such.key")
    }
}

struct LocalizedFormattingTests {
    let now = Date(timeIntervalSince1970: 1_791_421_200)  // 2026-10-08T01:00:00Z
    let utc = TimeZone(identifier: "UTC")!
    var en: Localizer { Localizer(.english, timeZone: utc) }
    var ko: Localizer { Localizer(.korean, timeZone: utc) }

    @Test func countdowns() {
        #expect(en.countdown(to: now + 2 * 3600 + 10 * 60 + 59, now: now) == "2h 10m")
        #expect(ko.countdown(to: now + 2 * 3600 + 10 * 60 + 59, now: now) == "2시간 10분")
        #expect(en.countdown(to: now + 45 * 60, now: now) == "45m")
        #expect(ko.countdown(to: now + 3 * 86_400 + 4 * 3600, now: now) == "3일 4시간")
        #expect(en.countdown(to: now + 59, now: now) == "<1m")
        #expect(ko.countdown(to: now - 1, now: now) == "지금")
        #expect(en.clockCountdown(to: now + 2 * 3600 + 5 * 60 + 9, now: now) == "2:05:09")
        #expect(ko.clockCountdown(to: now + 3 * 86_400 + 61, now: now) == "3일 0:01:01")
    }

    @Test func ages() {
        #expect(en.relativeAge(of: now - 20, now: now) == "just now")
        #expect(ko.relativeAge(of: now - 3 * 60 - 5, now: now) == "3분 전")
        #expect(en.relativeAge(of: now - 2 * 3600, now: now) == "2h ago")
        #expect(ko.relativeAge(of: now - 3 * 86_400, now: now) == "3일 전")
    }

    @Test func tokenCountsFollowTheLocale() {
        #expect(en.tokens(950) == "950")
        #expect(en.tokens(34_560) == "34.6K")
        #expect(en.tokens(1_234_567) == "1.2M")
        #expect(ko.tokens(34_560) == "3.5만")
        #expect(ko.tokens(1_234_567) == "123.5만")
        #expect(en.tokensExact(1_234_567) == "1,234,567")
    }

    @Test func datesFollowLocaleAndInjectedTimeZone() {
        #expect(en.dayLabel(now) == "Oct 8")
        #expect(ko.dayLabel(now) == "10월 8일")
        let seoul = Localizer(.korean, timeZone: TimeZone(identifier: "Asia/Seoul")!)
        #expect(seoul.resetTime(now).contains("10:00"))
    }

    @Test func reasonsAndPathMessages() {
        #expect(en.unavailable(.hookNotInstalled) == "statusline hook not installed")
        #expect(ko.unavailable(.stale) == "데이터가 7일 넘게 지남")
        #expect(en.pathValidation(.missingSubfolder("sessions")) == "No “sessions” folder inside yet")
        #expect(ko.pathValidation(.notFound) == "폴더를 찾을 수 없습니다")
        #expect(ko.thresholdError(.warningNotAboveCritical) == "경고 값은 위험 값보다 커야 합니다.")
        #expect(en.hookError(StatuslineInstaller.InstallerError.settingsNotWritable) == "settings.json is not writable. Nothing was changed.")
    }
}

struct TooltipTests {
    let now = Date(timeIntervalSince1970: 1_791_421_200)

    func state(_ tool: Tool, session: Double?, weekly: Double? = nil, issue: UnavailableReason? = nil, enabled: Bool = true) -> ToolState {
        var limits: [LimitStatus] = []
        if let session { limits.append(LimitStatus(kind: .session, usedPercent: session, resetsAt: now + 2 * 3600 + 10 * 60, isReset: false, observedAt: now)) }
        if let weekly { limits.append(LimitStatus(kind: .weekly, usedPercent: weekly, resetsAt: now + 3 * 86_400, isReset: false, observedAt: now)) }
        let summary = UsageSummary(today: .zero, todayByModel: [:], week: .zero, weekByModel: [:],
                                   weekInterval: DateInterval(start: now - 86_400, end: now), limits: limits)
        return ToolState(tool: tool, isEnabled: enabled, summary: summary, unavailableReason: issue, refreshedAt: now)
    }

    @Test func bothToolsInEnglishAndKorean() {
        let states = [state(.claude, session: 38, weekly: 24), state(.codex, session: 20, weekly: 30)]
        #expect(Localizer(.english).tooltip(states: states, mode: .remaining, now: now)
            == "Claude session 62% left, resets in 2h 10m · weekly 76% left\nCodex session 80% left, resets in 2h 10m · weekly 70% left")
        #expect(Localizer(.korean).tooltip(states: states, mode: .remaining, now: now)
            == "Claude 세션 62% 남음, 2시간 10분 후 초기화 · 주간 76% 남음\nCodex 세션 80% 남음, 2시간 10분 후 초기화 · 주간 70% 남음")
    }

    @Test func usedModeUnavailableAndDisabled() {
        let en = Localizer(.english)
        #expect(en.tooltip(states: [state(.claude, session: 75)], mode: .used, now: now) == "Claude session 75% used, resets in 2h 10m")
        #expect(en.tooltip(states: [state(.claude, session: 38), state(.codex, session: nil, issue: .noData)], mode: .remaining, now: now)
            == "Claude session 62% left, resets in 2h 10m\nCodex: no data yet")
        #expect(Localizer(.korean).tooltip(states: [state(.claude, session: nil, issue: .hookNotInstalled), state(.codex, session: 1, enabled: false)],
                                           mode: .remaining, now: now) == "Claude: statusline 훅이 설치되지 않음")
    }

    @Test func resetWindow() {
        var claude = state(.claude, session: nil)
        claude.summary?.limits = [LimitStatus(kind: .session, usedPercent: 0, resetsAt: nil, isReset: true, observedAt: now - 7200)]
        #expect(Localizer(.english).tooltip(states: [claude], mode: .remaining, now: now) == "Claude session 100% left (window reset)")
    }
}

struct ComposedTextTests {
    let home = URL(fileURLWithPath: "/Users/someone")

    @Test func consentNamesFilesBackupAndUndoInBothLanguages() {
        let paths = TokenGlancePaths(supportDirectory: home.appendingPathComponent("Library/Application Support/TokenGlance"))
        for language in [AppLanguage.english, .korean] {
            let consent = Localizer(language).hookConsent(settingsURL: home.appendingPathComponent(".claude/settings.json"),
                                                          paths: paths, hasExistingStatusLine: true, home: home)
            #expect(consent.body.contains("~/.claude/settings.json"))
            #expect(consent.body.contains("statusLine"))
            #expect(consent.body.contains("~/.claude/settings.json.token-glance-backup-"))
            #expect(consent.body.contains("~/Library/Application Support/TokenGlance/statusline-backup.json"))
            #expect(!consent.body.contains("/Users/someone"))
        }
        let en = Localizer(.english).hookConsent(settingsURL: home.appendingPathComponent(".claude/settings.json"),
                                                 paths: paths, hasExistingStatusLine: false, home: home)
        #expect(en.title == "Install the Claude limits hook?")
        #expect(!en.body.contains("keeps working"))
    }

    @Test func notificationTexts() {
        let resets = Date(timeIntervalSince1970: 1_791_432_000)
        let utc = TimeZone(identifier: "UTC")!
        let warning = LimitNotification(tool: .codex, window: .session, kind: .warning, leftPercent: 30, resetsAt: resets)
        #expect(Localizer(.english, timeZone: utc).notification(warning).title == "Codex 5-hour limit: 30% left")
        #expect(Localizer(.korean, timeZone: utc).notification(warning).title == "Codex 5시간 한도: 30% 남음")
        let critical = LimitNotification(tool: .claude, window: .weekly, kind: .critical, leftPercent: 8, resetsAt: resets)
        #expect(Localizer(.korean, timeZone: utc).notification(critical).title == "Claude 주간 한도 거의 소진: 8% 남음")
        let reset = LimitNotification(tool: .claude, window: .session, kind: .reset, leftPercent: 97, resetsAt: resets)
        #expect(Localizer(.english).notification(reset) == ("Claude 5-hour limit reset", "97% left in the new window."))
    }
}
