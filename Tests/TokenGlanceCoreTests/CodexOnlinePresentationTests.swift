import Foundation
import Testing
@testable import TokenGlanceCore

struct CodexOnlinePresentationTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func localState() -> ToolState {
        let snapshot = UsageSnapshot(
            limits: [LimitWindow(kind: .session, usedPercent: 40, resetsAt: now + 100, observedAt: now - 20)],
            records: [UsageRecord(timestamp: now - 10, model: "test", usage: TokenUsage(input: 10))]
        )
        return ToolState.make(tool: .codex, snapshot: snapshot, hookStatus: nil,
                              aggregator: UsageAggregator(), now: now)
    }

    @Test func accountLimitsReplaceOnlyLimitDisplay() throws {
        let result = try #require(CodexAccountLimits.decode([
            "accountId": "opaque-account",
            "rateLimits": ["primary": ["usedPercent": 60, "windowDurationMins": 300, "resetsAt": 1_001_000]],
        ], observedAt: now))
        let local = localState()
        let displayed = CodexOnlinePresentation.apply(result, to: local, now: now)
        #expect(displayed.session?.usedPercent == 60)
        #expect(displayed.summary?.today == local.summary?.today)
        #expect(displayed.limitSource == "Account query")
        #expect(displayed.limitWindows.map(\.usedPercent) == [60])
    }

    @Test func multipleBucketsRemainSeparateAndDoNotChooseMenuBarValue() throws {
        let result = try #require(CodexAccountLimits.decode([
            "rateLimits": [:],
            "rateLimitsByLimitId": [
                "one": ["primary": ["usedPercent": 10, "windowDurationMins": 300]],
                "two": ["secondary": ["usedPercent": 80, "windowDurationMins": 10_080]],
            ],
        ], observedAt: now))
        let displayed = CodexOnlinePresentation.apply(result, to: localState(), now: now)
        #expect(displayed.session == nil)
        #expect(displayed.weekly == nil)
        #expect(displayed.onlineBucketRows.count == 2)
        #expect(displayed.limitWindows.isEmpty)
        let label = MenuBarLabel.make(states: [displayed], mode: .remaining)
        #expect(label.lines.first?.text == "--")
    }

    @Test func expiredOnlineReadingDoesNotClaimRecovery() throws {
        let result = try #require(CodexAccountLimits.decode([
            "rateLimits": ["primary": ["usedPercent": 90, "windowDurationMins": 300, "resetsAt": 999_999]],
        ], observedAt: now))
        let displayed = CodexOnlinePresentation.apply(result, to: localState(), now: now)
        #expect(displayed.session?.usedPercent == 90)
        #expect(displayed.session?.isReset == true)
        #expect(displayed.session?.resetsAt == nil)
    }

    @Test func failedOnlineReadFallsBackWithoutClaimingExpiredLocalReset() {
        var local = localState()
        local.summary?.limits = [LimitStatus(kind: .session, usedPercent: 0, resetsAt: nil,
                                            isReset: true, observedAt: now - 100)]
        let displayed = CodexOnlinePresentation.fallback(local, reason: "Account query timed out", now: now)
        #expect(displayed.session == nil)
        #expect(displayed.onlineFailure == "Account query timed out")
        #expect(displayed.summary?.today == local.summary?.today)
    }

    @Test func olderResponseCannotReplaceAccountOrBucketSnapshot() throws {
        let latest = try #require(CodexAccountLimits.decode([
            "accountId": "new-account",
            "rateLimits": ["primary": ["usedPercent": 20, "windowDurationMins": 300]],
        ], observedAt: now))
        let older = try #require(CodexAccountLimits.decode([
            "accountId": "old-account",
            "rateLimits": ["primary": ["usedPercent": 90, "windowDurationMins": 300]],
        ], observedAt: now - 60))
        #expect(CodexOnlinePresentation.newer(older, than: latest) == latest)
        let changed = try #require(CodexAccountLimits.decode([
            "accountId": "other-account",
            "rateLimits": ["secondary": ["usedPercent": 70, "windowDurationMins": 10_080]],
        ], observedAt: now + 60))
        #expect(CodexOnlinePresentation.newer(changed, than: latest) == changed)
    }

    @Test func accountLimitsArrivingBeforeTheFirstLocalScanAreShownAndKept() throws {
        let result = try #require(CodexAccountLimits.decode([
            "rateLimits": ["primary": ["usedPercent": 60, "windowDurationMins": 300, "resetsAt": 1_001_000]],
        ], observedAt: now))
        let early = CodexOnlinePresentation.apply(result, to: ToolState(tool: .codex), now: now)
        #expect(early.session?.usedPercent == 60)
        #expect(early.limitWindows.map(\.usedPercent) == [60])
        #expect(early.limitSource == "Account query")
        #expect(early.refreshedAt == nil)
        #expect(early.summary?.hasTokens == false)
        // The first scan then brings an older local value; the account query is still shown.
        let scanned = CodexOnlinePresentation.apply(result, to: localState(), now: now)
        #expect(scanned.session?.usedPercent == 60)
    }
}
