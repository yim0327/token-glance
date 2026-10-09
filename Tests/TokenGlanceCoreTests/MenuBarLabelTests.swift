import Foundation
import Testing
@testable import TokenGlanceCore

struct MenuBarLabelTests {
    let now = Fixtures.t0

    func state(_ tool: Tool, session: Double?, weekly: Double? = nil, sessionResetsIn: TimeInterval = 2 * 3600 + 10 * 60,
               issue: UnavailableReason? = nil, enabled: Bool = true) -> ToolState {
        var limits: [LimitStatus] = []
        if let session {
            limits.append(LimitStatus(kind: .session, usedPercent: session, resetsAt: now + sessionResetsIn, isReset: false, observedAt: now))
        }
        if let weekly {
            limits.append(LimitStatus(kind: .weekly, usedPercent: weekly, resetsAt: now + 3 * 86_400, isReset: false, observedAt: now))
        }
        let summary = UsageSummary(today: .zero, todayByModel: [:], week: .zero, weekByModel: [:],
                                   weekInterval: DateInterval(start: now - 86_400, end: now), limits: limits)
        return ToolState(tool: tool, isEnabled: enabled, summary: summary, unavailableReason: issue, refreshedAt: now)
    }

    @Test func twoLinesWhenBothToolsHaveData() {
        let label = MenuBarLabel.make(states: [state(.claude, session: 38, weekly: 24), state(.codex, session: 20, weekly: 30)], mode: .remaining, now: now)
        #expect(label.lines == [
            .init(tool: .claude, text: "62%", severity: .normal),
            .init(tool: .codex, text: "80%", severity: .normal),
        ])
        #expect(label.tooltip == "Claude session 62% left, resets in 2h 10m · weekly 76% left\nCodex session 80% left, resets in 2h 10m · weekly 70% left")
    }

    @Test func usedModeAndSeverity() {
        let label = MenuBarLabel.make(states: [state(.claude, session: 75), state(.codex, session: 95)], mode: .used, now: now)
        #expect(label.lines.map(\.text) == ["75%", "95%"])
        #expect(label.lines.map(\.severity) == [.warning, .critical])
        #expect(label.tooltip.hasPrefix("Claude session 75% used, resets in 2h 10m"))
    }

    @Test func singleLineWhenOnlyOneToolHasData() {
        let label = MenuBarLabel.make(states: [state(.claude, session: 38), state(.codex, session: nil, issue: .noData)], mode: .remaining, now: now)
        #expect(label.lines == [.init(tool: .claude, text: "62%", severity: .normal)])
        #expect(label.tooltip == "Claude session 62% left, resets in 2h 10m\nCodex: no data yet")
    }

    @Test func singleLineWhenOnlyOneToolEnabled() {
        let label = MenuBarLabel.make(states: [state(.claude, session: 38, enabled: false), state(.codex, session: 20)], mode: .remaining, now: now)
        #expect(label.lines.map(\.tool) == [.codex])
        #expect(!label.tooltip.contains("Claude"))
    }

    @Test func dashesWithReasonsWhenNothingAvailable() {
        let label = MenuBarLabel.make(states: [state(.claude, session: nil, issue: .hookNotInstalled), state(.codex, session: nil, issue: .stale)],
                                      mode: .remaining, now: now)
        #expect(label.lines == [
            .init(tool: .claude, text: "--", severity: .unavailable),
            .init(tool: .codex, text: "--", severity: .unavailable),
        ])
        #expect(label.tooltip == "Claude: statusline hook not installed\nCodex: data is more than 7 days old")
    }

    @Test func resetWindowReadsAsFullyAvailable() {
        var claude = state(.claude, session: nil)
        claude.summary?.limits = [LimitStatus(kind: .session, usedPercent: 0, resetsAt: nil, isReset: true, observedAt: now - 7200)]
        let label = MenuBarLabel.make(states: [claude], mode: .remaining, now: now)
        #expect(label.lines == [.init(tool: .claude, text: "100%", severity: .normal)])
        #expect(label.tooltip == "Claude session 100% left (window reset)")
    }

    @Test func toolStateFromSnapshotPicksActionableReason() {
        let aggregator = UsageAggregator(calendar: Calendar(identifier: .gregorian))
        let empty = UsageSnapshot(limitsIssue: .noData)
        #expect(ToolState.make(tool: .claude, snapshot: empty, hookStatus: .notInstalled, aggregator: aggregator, now: now).unavailableReason == .hookNotInstalled)
        #expect(ToolState.make(tool: .claude, snapshot: empty, hookStatus: .overwritten, aggregator: aggregator, now: now).unavailableReason == .hookOverwritten)
        #expect(ToolState.make(tool: .claude, snapshot: empty, hookStatus: .installed, aggregator: aggregator, now: now).unavailableReason == .noData)
        #expect(ToolState.make(tool: .codex, snapshot: UsageSnapshot(limitsIssue: .corrupt), hookStatus: nil, aggregator: aggregator, now: now).unavailableReason == .corrupt)

        let window = LimitWindow(kind: .session, usedPercent: 10, resetsAt: now + 60, observedAt: now)
        let ok = ToolState.make(tool: .codex, snapshot: UsageSnapshot(limits: [window]), hookStatus: nil, aggregator: aggregator, now: now)
        #expect(ok.unavailableReason == nil)
        #expect(ok.session?.usedPercent == 10)
        #expect(ok.refreshedAt == now)
    }
}

struct ToolStateContentTests {
    @Test func sameContentIgnoresRefreshTime() {
        let a = ToolState(tool: .codex, refreshedAt: Fixtures.t0)
        var b = a
        b.refreshedAt = Fixtures.t0 + 60
        #expect(a.sameContent(as: b))
        b.unavailableReason = .stale
        #expect(!a.sameContent(as: b))
    }
}
