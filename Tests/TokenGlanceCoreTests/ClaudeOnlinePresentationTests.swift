import Foundation
import Testing
@testable import TokenGlanceCore

struct ClaudeOnlinePresentationTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    /// Claude state built from the hook cache, as `UsageLoader` does.
    private func hookState(session: Double = 40, weekly: Double? = 20, sessionResetsAt: Date? = nil) -> ToolState {
        var limits = [LimitWindow(kind: .session, usedPercent: session, resetsAt: sessionResetsAt ?? now + 3600,
                                  observedAt: now - 30)]
        if let weekly {
            limits.append(LimitWindow(kind: .weekly, usedPercent: weekly, resetsAt: now + 86_400, observedAt: now - 60))
        }
        let snapshot = UsageSnapshot(limits: limits,
                                     records: [UsageRecord(timestamp: now - 10, model: "test", usage: TokenUsage(input: 10, output: 5))])
        return ToolState.make(tool: .claude, snapshot: snapshot, hookStatus: .installed, aggregator: UsageAggregator(), now: now)
    }

    private func online(_ windows: [ClaudeLimitWindow], observedAt: Date? = nil) -> ClaudeAccountLimits {
        ClaudeAccountLimits(windows: windows, observedAt: observedAt ?? now - 5)
    }

    @Test func accountQueryWinsAndOnlyReplacesLimits() {
        let local = hookState()
        let shown = ClaudeOnlinePresentation.apply(online([
            ClaudeLimitWindow(kind: .session, usedPercent: 55, resetsAt: now + 1800),
            ClaudeLimitWindow(kind: .weekly, usedPercent: 30, resetsAt: now + 90_000),
        ]), to: local, now: now)
        #expect(shown.session?.usedPercent == 55)
        #expect(shown.weekly?.usedPercent == 30)
        #expect(shown.limitSource == ClaudeOnlinePresentation.accountQuery)
        #expect(shown.limitObservedAt == now - 5)
        #expect(shown.onlineFailure == nil)
        #expect(shown.limitWindows.map(\.usedPercent) == [55, 30])
        // Token totals stay the local ones.
        #expect(shown.summary?.today == local.summary?.today)
        #expect(shown.summary?.week == local.summary?.week)
        #expect(shown.history == local.history)
    }

    @Test func differingHookValuesStayVisibleButAreNotMixedIn() {
        let shown = ClaudeOnlinePresentation.apply(online([
            ClaudeLimitWindow(kind: .session, usedPercent: 55, resetsAt: now + 1800),
        ]), to: hookState(session: 40, weekly: 20), now: now)
        #expect(shown.summary?.limits.map(\.usedPercent) == [55])
        #expect(shown.otherSourceLimits.map(\.usedPercent) == [40, 20])

        let same = ClaudeOnlinePresentation.apply(online([
            ClaudeLimitWindow(kind: .session, usedPercent: 40.2, resetsAt: now + 1800),
            ClaudeLimitWindow(kind: .weekly, usedPercent: 19.8, resetsAt: now + 90_000),
        ]), to: hookState(session: 40, weekly: 20), now: now)
        #expect(same.otherSourceLimits.isEmpty)
    }

    @Test func failureFallsBackToHookCacheWithReasonAndSource() {
        let shown = ClaudeOnlinePresentation.fallback(hookState(), reason: "Account query timed out", now: now)
        #expect(shown.session?.usedPercent == 40)
        #expect(shown.limitSource == ClaudeOnlinePresentation.hookCache)
        #expect(shown.onlineFailure == "Account query timed out")
        #expect(shown.limitObservedAt == now - 30)
    }

    @Test func outdatedAccountQueryFallsBack() {
        let shown = ClaudeOnlinePresentation.apply(online([
            ClaudeLimitWindow(kind: .session, usedPercent: 90, resetsAt: now + 1800),
        ], observedAt: now - ClaudeOnlinePresentation.maxAge - 1), to: hookState(), now: now)
        #expect(shown.session?.usedPercent == 40)
        #expect(shown.limitSource == ClaudeOnlinePresentation.hookCache)
        #expect(shown.onlineFailure == "Account query result is out of date")
    }

    @Test func olderResponseNeverReplacesNewer() {
        let newer = online([ClaudeLimitWindow(kind: .session, usedPercent: 70, resetsAt: nil)], observedAt: now)
        let older = online([ClaudeLimitWindow(kind: .session, usedPercent: 10, resetsAt: nil)], observedAt: now - 60)
        #expect(ClaudeOnlinePresentation.newer(older, than: newer) == newer)
        #expect(ClaudeOnlinePresentation.newer(newer, than: older) == newer)
        #expect(ClaudeOnlinePresentation.newer(older, than: nil) == older)
    }

    @Test func passedResetTimesDoNotClaimRecovery() {
        // Online: a window whose reset passed is dropped, not shown as 0% used.
        let shown = ClaudeOnlinePresentation.apply(online([
            ClaudeLimitWindow(kind: .session, usedPercent: 95, resetsAt: now - 1),
            ClaudeLimitWindow(kind: .weekly, usedPercent: 30, resetsAt: now + 90_000),
        ]), to: hookState(), now: now)
        #expect(shown.session == nil)
        #expect(shown.weekly?.usedPercent == 30)
        #expect(!(shown.summary?.limits.contains(where: \.isReset) ?? true))

        // Fallback: the cached reset window is dropped too.
        let local = hookState(weekly: nil, sessionResetsAt: now - 1)
        #expect(local.session?.isReset == true)
        let fallback = ClaudeOnlinePresentation.fallback(local, reason: "Account query timed out", now: now)
        #expect(fallback.session == nil)
        #expect(fallback.unavailableReason == .awaitingFreshLimit)
        #expect(fallback.limitWindows.isEmpty)
    }

    @Test func emptyAnswerFallsBack() {
        let shown = ClaudeOnlinePresentation.apply(online([]), to: hookState(), now: now)
        #expect(shown.session?.usedPercent == 40)
        #expect(shown.onlineFailure == "Account query returned no limit windows")
    }

    @Test func codexStateIsUntouched() {
        let codex = ToolState(tool: .codex)
        #expect(ClaudeOnlinePresentation.apply(online([ClaudeLimitWindow(kind: .session, usedPercent: 1, resetsAt: nil)]),
                                               to: codex, now: now) == codex)
    }

    @Test func onlineLimitsArrivingBeforeTheFirstLocalScanAreShownAndKept() {
        let result = online([
            ClaudeLimitWindow(kind: .session, usedPercent: 55, resetsAt: now + 1800),
            ClaudeLimitWindow(kind: .weekly, usedPercent: 30, resetsAt: now + 90_000),
        ])
        let early = ClaudeOnlinePresentation.apply(result, to: ToolState(tool: .claude), now: now)
        #expect(early.session?.usedPercent == 55)
        #expect(early.weekly?.usedPercent == 30)
        #expect(early.limitSource == ClaudeOnlinePresentation.accountQuery)
        // No tokens were indexed yet, and the state says so.
        #expect(early.refreshedAt == nil)
        #expect(early.summary?.hasTokens == false)
        // The first scan finishes later with older hook values: the account query still wins.
        let scanned = ClaudeOnlinePresentation.apply(result, to: hookState(session: 40, weekly: 20), now: now)
        #expect(scanned.session?.usedPercent == 55)
        #expect(scanned.limitSource == ClaudeOnlinePresentation.accountQuery)
    }

    @Test func fresherHookWinsAfterAnOnlineWindowPassesItsReset() {
        // Queried 10 minutes ago; its session window has reset since, its weekly window has not.
        let result = online([
            ClaudeLimitWindow(kind: .session, usedPercent: 70, resetsAt: now - 60),
            ClaudeLimitWindow(kind: .weekly, usedPercent: 30, resetsAt: now + 90_000),
        ], observedAt: now - 600)
        // The hook saw the new session window after that (observed 30 s and 60 s ago).
        let shown = ClaudeOnlinePresentation.apply(result, to: hookState(session: 5, weekly: 31), now: now)
        #expect(shown.session?.usedPercent == 5)
        // The weekly value comes from the same hook observation; sources are not mixed.
        #expect(shown.weekly?.usedPercent == 31)
        #expect(shown.limitSource == ClaudeOnlinePresentation.hookCache)
        #expect(shown.limitObservedAt == now - 30)
        #expect(shown.otherSourceLimits.isEmpty)
    }

    @Test func olderHookDoesNotReplaceTheQueryAfterAReset() {
        let result = online([
            ClaudeLimitWindow(kind: .session, usedPercent: 70, resetsAt: now - 1),
            ClaudeLimitWindow(kind: .weekly, usedPercent: 30, resetsAt: now + 90_000),
        ], observedAt: now - 5)
        // Hook values observed before the query know nothing newer.
        let shown = ClaudeOnlinePresentation.apply(result, to: hookState(session: 99, weekly: 20), now: now)
        #expect(shown.limitSource == ClaudeOnlinePresentation.accountQuery)
        #expect(shown.session == nil)
        #expect(shown.weekly?.usedPercent == 30)
    }

    @Test func aHigherOrFresherHookPercentAloneDoesNotReplaceAValidQuery() {
        let result = online([
            ClaudeLimitWindow(kind: .session, usedPercent: 10, resetsAt: now + 1800),
            ClaudeLimitWindow(kind: .weekly, usedPercent: 30, resetsAt: now + 90_000),
        ], observedAt: now - 600)
        let shown = ClaudeOnlinePresentation.apply(result, to: hookState(session: 90, weekly: 95), now: now)
        #expect(shown.limitSource == ClaudeOnlinePresentation.accountQuery)
        #expect(shown.session?.usedPercent == 10)
        #expect(shown.weekly?.usedPercent == 30)
    }

    @Test func passedResetWithoutAFresherHookValueWaitsForTheNextQuery() {
        let result = online([ClaudeLimitWindow(kind: .session, usedPercent: 70, resetsAt: now - 60)],
                            observedAt: now - 600)
        // The hook's own session window has also reset: nothing valid to show.
        let shown = ClaudeOnlinePresentation.apply(result, to: hookState(session: 50, weekly: nil, sessionResetsAt: now - 10), now: now)
        #expect(shown.session == nil)
        #expect(shown.onlineFailure == "Waiting for account query")
    }
}
