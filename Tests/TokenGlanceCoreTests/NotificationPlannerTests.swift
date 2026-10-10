import Foundation
import Testing
@testable import TokenGlanceCore

struct NotificationPlannerTests {
    let t0 = Fixtures.t0
    let resets = Fixtures.t0 + 3 * 3600

    func window(_ used: Double, _ kind: LimitWindow.Kind = .session, at observed: Date, resets: Date? = nil) -> LimitWindow {
        LimitWindow(kind: kind, usedPercent: used, resetsAt: resets ?? self.resets, observedAt: observed)
    }

    /// Runs one evaluation for Claude with the given windows at `now`.
    func run(_ planner: inout NotificationPlanner, _ marks: inout InMemoryNotificationMarks,
             _ windows: [LimitWindow]?, now: Date, tool: Tool = .claude) -> [LimitNotification] {
        planner.evaluate(tool: tool, windows: windows, now: now, marks: &marks)
    }

    @Test func firstObservationOnlySetsTheBaseline() {
        var planner = NotificationPlanner(), marks = InMemoryNotificationMarks()
        // already below both thresholds when first seen (e.g. at app start): no past alerts
        #expect(run(&planner, &marks, [window(95, at: t0)], now: t0).isEmpty)
        #expect(run(&planner, &marks, [window(96, at: t0 + 60)], now: t0 + 60).isEmpty)
    }

    @Test func crossingWarningAndCriticalBoundaries() {
        var planner = NotificationPlanner(), marks = InMemoryNotificationMarks()
        _ = run(&planner, &marks, [window(69, at: t0)], now: t0)                        // 31% left
        #expect(run(&planner, &marks, [window(69.4, at: t0 + 60)], now: t0 + 60).isEmpty) // still 31%
        let warning = run(&planner, &marks, [window(70, at: t0 + 120)], now: t0 + 120)    // exactly 30% left
        #expect(warning == [LimitNotification(tool: .claude, window: .session, kind: .warning, leftPercent: 30, resetsAt: resets)])
        #expect(run(&planner, &marks, [window(89, at: t0 + 180)], now: t0 + 180).isEmpty) // 11% left
        let critical = run(&planner, &marks, [window(90, at: t0 + 240)], now: t0 + 240)   // 10% left
        #expect(critical.map(\.kind) == [.critical])
    }

    @Test func crossingBothThresholdsAtOnceSendsOnlyTheMostSevere() {
        var planner = NotificationPlanner(), marks = InMemoryNotificationMarks()
        _ = run(&planner, &marks, [window(50, at: t0)], now: t0)
        let events = run(&planner, &marks, [window(95, at: t0 + 60)], now: t0 + 60)
        #expect(events.map(\.kind) == [.critical])
        #expect(events.first?.leftPercent == 5)
        // the skipped warning is marked too: recovering above 30% and dropping again does not re-warn
        _ = run(&planner, &marks, [window(60, at: t0 + 120)], now: t0 + 120)
        #expect(run(&planner, &marks, [window(75, at: t0 + 180)], now: t0 + 180).isEmpty)
    }

    @Test func repeatedObservationsDoNotRepeatAlerts() {
        var planner = NotificationPlanner(), marks = InMemoryNotificationMarks()
        _ = run(&planner, &marks, [window(60, at: t0)], now: t0)
        #expect(run(&planner, &marks, [window(75, at: t0 + 60)], now: t0 + 60).count == 1)
        #expect(run(&planner, &marks, [window(75, at: t0 + 60)], now: t0 + 90).isEmpty)  // same observation again
        _ = run(&planner, &marks, [window(65, at: t0 + 120)], now: t0 + 120)              // back above 30% left
        #expect(run(&planner, &marks, [window(72, at: t0 + 180)], now: t0 + 180).isEmpty) // same window and threshold
    }

    @Test func restartKeepsDedupeButNeverReplaysMissedAlerts() {
        var marks = InMemoryNotificationMarks()
        var first = NotificationPlanner()
        _ = run(&first, &marks, [window(60, at: t0)], now: t0)
        #expect(run(&first, &marks, [window(75, at: t0 + 60)], now: t0 + 60).count == 1)

        // restart: new planner, persisted marks. The first evaluation only sets the baseline even though
        // usage crossed 10% left while the app was not running.
        var second = NotificationPlanner()
        #expect(run(&second, &marks, [window(92, at: t0 + 600)], now: t0 + 600).isEmpty)
        // after recovering above 30% within the same window, the warning stays suppressed by the persisted mark
        _ = run(&second, &marks, [window(60, at: t0 + 660)], now: t0 + 660)
        #expect(run(&second, &marks, [window(75, at: t0 + 720)], now: t0 + 720).isEmpty)
    }

    @Test func newWindowStartsFreshAndAnnouncesResetOnlyAfterANewObservation() {
        var planner = NotificationPlanner(), marks = InMemoryNotificationMarks()
        _ = run(&planner, &marks, [window(60, at: t0)], now: t0)
        _ = run(&planner, &marks, [window(92, at: t0 + 60)], now: t0 + 60)  // critical sent

        // time passes beyond resetsAt but nothing new is observed: no "reset" alert
        #expect(run(&planner, &marks, [window(92, at: t0 + 60)], now: resets + 600).isEmpty)

        // a new observation for the next window
        let next = resets + 5 * 3600
        let observed = resets + 700
        let events = run(&planner, &marks, [window(3, at: observed, resets: next)], now: observed + 5)
        #expect(events == [LimitNotification(tool: .claude, window: .session, kind: .reset, leftPercent: 97, resetsAt: next)])
        // thresholds apply again in the new window
        #expect(run(&planner, &marks, [window(71, at: observed + 60, resets: next)], now: observed + 65).map(\.kind) == [.warning])
    }

    @Test func noResetAlertWhenThePreviousWindowWasNotConstrained() {
        var planner = NotificationPlanner(), marks = InMemoryNotificationMarks()
        _ = run(&planner, &marks, [window(20, at: t0)], now: t0)  // 80% left
        let next = resets + 5 * 3600
        #expect(run(&planner, &marks, [window(1, at: resets + 60, resets: next)], now: resets + 61).isEmpty)
    }

    @Test func staleObservationsAreAbsorbedWithoutAlerts() {
        var planner = NotificationPlanner(), marks = InMemoryNotificationMarks()
        _ = run(&planner, &marks, [window(60, at: t0)], now: t0)
        // e.g. after sleep: a new reading that was observed long ago only moves the baseline
        #expect(run(&planner, &marks, [window(80, at: t0 + 120)], now: t0 + 120 + NotificationPlanner.freshness + 1).isEmpty)
        #expect(run(&planner, &marks, [window(85, at: t0 + 2000)], now: t0 + 2001).isEmpty)  // 20%→15%: no crossing
    }

    @Test func wakeRebaselinesSoMissedCrossingsAreNotSent() {
        var planner = NotificationPlanner(), marks = InMemoryNotificationMarks()
        _ = run(&planner, &marks, [window(60, at: t0)], now: t0)
        planner.rebaseline()  // system woke up
        #expect(run(&planner, &marks, [window(92, at: t0 + 3600)], now: t0 + 3601).isEmpty)
        #expect(run(&planner, &marks, [window(93, at: t0 + 3660)], now: t0 + 3661).isEmpty)
    }

    @Test func unavailableDataAndDisabledToolsNeverAlert() {
        var planner = NotificationPlanner(), marks = InMemoryNotificationMarks()
        _ = run(&planner, &marks, [window(60, at: t0)], now: t0)
        #expect(run(&planner, &marks, nil, now: t0 + 60).isEmpty)  // no data / corrupt / stale cache
        #expect(run(&planner, &marks, [], now: t0 + 90).isEmpty)
        planner.forget(tool: .claude)  // tool disabled, folder changed or notifications re-enabled
        #expect(run(&planner, &marks, [window(95, at: t0 + 120)], now: t0 + 121).isEmpty)
    }

    @Test func toolsAndWindowsAreIndependent() {
        var planner = NotificationPlanner(), marks = InMemoryNotificationMarks()
        _ = run(&planner, &marks, [window(60, at: t0), window(60, .weekly, at: t0, resets: t0 + 4 * 86_400)], now: t0)
        _ = run(&planner, &marks, [window(60, at: t0)], now: t0, tool: .codex)
        let claude = run(&planner, &marks, [window(60, at: t0 + 60), window(75, .weekly, at: t0 + 60, resets: t0 + 4 * 86_400)], now: t0 + 60)
        #expect(claude.map(\.window) == [.weekly])
        let codex = run(&planner, &marks, [window(75, at: t0 + 60)], now: t0 + 60, tool: .codex)
        #expect(codex.map(\.tool) == [.codex])
    }

    @Test func customThresholdsAndValidation() {
        #expect(NotificationThresholds(warning: 30, critical: 10).validationError == nil)
        #expect(NotificationThresholds(warning: 10, critical: 10).validationError == .warningNotAboveCritical)
        #expect(NotificationThresholds(warning: 5, critical: 20).validationError == .warningNotAboveCritical)
        #expect(NotificationThresholds(warning: 101, critical: 10).validationError == .outOfRange)
        #expect(NotificationThresholds(warning: 30, critical: -1).validationError == .outOfRange)

        var planner = NotificationPlanner(thresholds: NotificationThresholds(warning: 50, critical: 20))
        var marks = InMemoryNotificationMarks()
        _ = run(&planner, &marks, [window(40, at: t0)], now: t0)
        #expect(run(&planner, &marks, [window(55, at: t0 + 60)], now: t0 + 60).map(\.kind) == [.warning])
    }

    @Test func marksPersistInUserDefaultsAndExpire() {
        let suite = "tg-marks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var store = UserDefaultsNotificationMarks(defaults: defaults)
        let mark = NotificationMark(tool: .codex, window: .weekly, level: .warning, resetsAt: t0)
        store.insert(mark)
        #expect(UserDefaultsNotificationMarks(defaults: defaults).contains(mark))
        // only minimal identifiers are stored
        let stored = defaults.stringArray(forKey: UserDefaultsNotificationMarks.key) ?? []
        #expect(stored.count == 1 && stored[0].hasPrefix("codex.weekly.warning."))
        store.prune(before: t0 + 1)
        #expect(!UserDefaultsNotificationMarks(defaults: defaults).contains(mark))
    }
}
