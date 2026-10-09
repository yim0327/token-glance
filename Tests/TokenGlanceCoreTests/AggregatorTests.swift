import Foundation
import Testing
@testable import TokenGlanceCore

struct AggregatorTests {
    static func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    let utc = UsageAggregator(calendar: calendar("UTC"))
    let seoul = UsageAggregator(calendar: calendar("Asia/Seoul"))

    func record(_ offset: TimeInterval, _ model: String = "m", output: Int) -> UsageRecord {
        UsageRecord(timestamp: Fixtures.t0 + offset, model: model, usage: TokenUsage(output: output))
    }

    @Test func todayFollowsCalendarTimeZone() {
        // T0 = 2026-10-08 01:00 UTC = 10:00 KST
        let records = [
            record(-2 * 3600, output: 1),   // 10-07 23:00 UTC / 10-08 08:00 KST
            record(0, output: 10),           // 10-08 01:00 UTC
            record(15 * 3600, output: 100),  // 10-08 16:00 UTC / 10-09 01:00 KST
        ]
        let now = Fixtures.t0 + 3600
        #expect(utc.total(records, in: utc.today(now: now)).output == 10 + 100)
        #expect(seoul.total(records, in: seoul.today(now: now)).output == 1 + 10)
    }

    @Test func intervalsAreHalfOpen() {
        let interval = DateInterval(start: Fixtures.t0, end: Fixtures.t0 + 60)
        let records = [record(0, output: 1), record(59, output: 2), record(60, output: 4)]
        #expect(utc.total(records, in: interval).output == 3)
    }

    @Test func weekIntervalComesFromWeeklyResetTime() {
        let resetsAt = Fixtures.t0 + 2 * 86_400
        let weekly = LimitWindow(kind: .weekly, usedPercent: 40, resetsAt: resetsAt, observedAt: Fixtures.t0)
        let interval = utc.weekInterval(weekly: weekly, now: Fixtures.t0)
        #expect(interval == DateInterval(start: resetsAt - 7 * 86_400, end: resetsAt))
    }

    @Test func weekIntervalRollsForwardAfterReset() {
        let resetsAt = Fixtures.t0
        let weekly = LimitWindow(kind: .weekly, usedPercent: 90, resetsAt: resetsAt, observedAt: Fixtures.t0 - 86_400)
        let now = Fixtures.t0 + 8 * 86_400  // more than one full window later
        let interval = utc.weekInterval(weekly: weekly, now: now)
        #expect(interval == DateInterval(start: resetsAt + 7 * 86_400, end: resetsAt + 14 * 86_400))
        #expect(interval.start <= now && now < interval.end)
    }

    @Test func weekIntervalWithoutLimitIsTrailingSevenDays() {
        #expect(utc.weekInterval(weekly: nil, now: Fixtures.t0) == DateInterval(start: Fixtures.t0 - 7 * 86_400, end: Fixtures.t0))
    }

    @Test func byModelTotals() {
        let records = [record(0, "a", output: 1), record(1, "b", output: 2), record(2, "a", output: 4), record(-10, "a", output: 8)]
        let interval = DateInterval(start: Fixtures.t0, end: Fixtures.t0 + 60)
        #expect(utc.byModel(records, in: interval) == ["a": TokenUsage(output: 5), "b": TokenUsage(output: 2)])
    }

    @Test func limitStatusReportsResetWindowsAsZero() {
        let active = LimitWindow(kind: .session, usedPercent: 38, resetsAt: Fixtures.t0 + 60, observedAt: Fixtures.t0)
        let expired = LimitWindow(kind: .weekly, usedPercent: 95, resetsAt: Fixtures.t0 - 1, observedAt: Fixtures.t0 - 600)
        let statuses = utc.limitStatuses([active, expired], now: Fixtures.t0)
        #expect(statuses == [
            LimitStatus(kind: .session, usedPercent: 38, resetsAt: Fixtures.t0 + 60, isReset: false, observedAt: Fixtures.t0),
            LimitStatus(kind: .weekly, usedPercent: 0, resetsAt: nil, isReset: true, observedAt: Fixtures.t0 - 600),
        ])
        #expect(statuses[1].remainingPercent == 100)
        #expect(statuses[0].remainingPercent == 62)
    }

    @Test func summaryOfCodexFixture() throws {
        let source = try Fixtures.source(root: "/codex", [
            "sessions/2026/10/08/rollout-a.jsonl": "codex-token-count-sample.jsonl",
            "sessions/2026/10/08/rollout-b.jsonl": "codex-edge-cases.synthetic.jsonl",
        ])
        let snap = CodexUsageProvider(codexHome: URL(fileURLWithPath: "/codex"), fileSource: source).snapshot()
        let now = Fixtures.t0 + 3 * 3600
        let summary = utc.summary(of: snap, now: now)

        #expect(summary.today == TokenUsage(input: 8300, output: 1730, cacheRead: 18500, reasoning: 450))
        // weekly window: resets T0 + 5d, so it started T0 - 2d and contains every record
        #expect(summary.weekInterval == DateInterval(start: Fixtures.t0 - 2 * 86_400, end: Fixtures.t0 + 5 * 86_400))
        #expect(summary.week == summary.today)
        #expect(summary.weekByModel["gpt-6-astra"] == TokenUsage(input: 500, output: 250, cacheRead: 3500))
        #expect(summary.limits.map(\.usedPercent) == [31.0, 28.5])

        // After the 5h window resets (T0 + 4h) the session reads 0% while weekly stays.
        let later = utc.summary(of: snap, now: Fixtures.t0 + 4 * 3600)
        #expect(later.limits.map(\.usedPercent) == [0, 28.5])
        #expect(later.limits.map(\.isReset) == [true, false])
    }

    @Test func summaryOfClaudeFixtureHasNoLimits() throws {
        let source = try Fixtures.source(root: "/claude/projects", ["-p/s.jsonl": "claude-usage-sample.jsonl"])
        let snap = ClaudeUsageProvider(projectsRoot: URL(fileURLWithPath: "/claude/projects"), fileSource: source).snapshot()
        let summary = utc.summary(of: snap, now: Fixtures.t0 + 3600)
        #expect(summary.today == TokenUsage(input: 21, output: 794, cacheRead: 58000, cacheWrite: 3500, reasoning: 120))
        #expect(summary.limits.isEmpty)
        #expect(summary.weekInterval == DateInterval(start: Fixtures.t0 + 3600 - 7 * 86_400, end: Fixtures.t0 + 3600))
    }
}
