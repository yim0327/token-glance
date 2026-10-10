import Foundation

/// Chooses which Claude limit values are shown while the online option is on: the latest valid
/// account query, otherwise the statusline hook cache. Values from the two sources are never mixed,
/// averaged or summed, and token totals always stay the locally indexed ones.
public enum ClaudeOnlinePresentation {
    public static let accountQuery = "Account query"
    public static let hookCache = "Hook cache"
    /// An account query older than this (for example after sleep) no longer wins over the hook cache.
    public static let maxAge: TimeInterval = 15 * 60

    /// A response from an older request never replaces a later observation.
    public static func newer(_ incoming: ClaudeAccountLimits, than current: ClaudeAccountLimits?) -> ClaudeAccountLimits {
        guard let current, current.observedAt > incoming.observedAt else { return incoming }
        return current
    }

    public static func apply(_ result: ClaudeAccountLimits, to local: ToolState, now: Date) -> ToolState {
        guard local.tool == .claude else { return local }
        guard now.timeIntervalSince(result.observedAt) <= maxAge else {
            return fallback(local, reason: "Account query result is out of date", now: now)
        }
        // A window whose reset time has passed proves nothing about the account until the next
        // query reports it again, so it is not shown as recovered.
        let current = result.windows.filter { window in window.resetsAt.map { $0 > now } ?? true }
        guard !current.isEmpty else {
            let reason = result.windows.isEmpty ? "Account query returned no limit windows" : "Waiting for account query"
            return fallback(local, reason: reason, now: now)
        }
        var state = local
        let statuses = current.map { window in
            LimitStatus(kind: window.kind, usedPercent: window.usedPercent, resetsAt: window.resetsAt,
                        isReset: false, observedAt: result.observedAt)
        }
        let hook = activeLimits(local)
        state.otherSourceLimits = differs(hook, from: statuses) ? hook : []
        state.summary?.limits = statuses
        state.limitWindows = current.compactMap { window in
            window.resetsAt.map { LimitWindow(kind: window.kind, usedPercent: window.usedPercent, resetsAt: $0,
                                              observedAt: result.observedAt) }
        }
        state.limitSource = accountQuery
        state.limitObservedAt = result.observedAt
        state.onlineFailure = nil
        state.unavailableReason = nil
        return state
    }

    public static func fallback(_ local: ToolState, reason: String, now: Date) -> ToolState {
        var state = local
        state.onlineFailure = reason
        state.limitSource = hookCache
        state.otherSourceLimits = []
        let hadReset = local.summary?.limits.contains(where: \.isReset) ?? false
        // A passed reset time in the cache cannot prove that the account quota recovered either.
        state.summary?.limits = activeLimits(local)
        state.limitWindows.removeAll { $0.isReset(at: now) }
        state.limitObservedAt = state.summary?.limits.map(\.observedAt).max()
        if state.summary?.limits.isEmpty == true && (state.unavailableReason == nil || hadReset) {
            state.unavailableReason = hadReset ? .awaitingFreshLimit : .noData
        }
        return state
    }

    private static func activeLimits(_ state: ToolState) -> [LimitStatus] {
        (state.summary?.limits ?? []).filter { !$0.isReset }
    }

    /// True when the hook cache shows a window the query does not, or a different whole percent.
    private static func differs(_ hook: [LimitStatus], from online: [LimitStatus]) -> Bool {
        hook.contains { cached in
            guard let shown = online.first(where: { $0.kind == cached.kind }) else { return true }
            return cached.usedPercent.rounded() != shown.usedPercent.rounded()
        }
    }
}
