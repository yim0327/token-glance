import Foundation

/// Selects the account limit display without changing locally indexed token totals.
public enum CodexOnlinePresentation {
    /// A response from an older request must never replace a later observation, even if its
    /// account or bucket set differs. Each accepted snapshot replaces the whole previous one.
    public static func newer(_ incoming: CodexAccountLimits, than current: CodexAccountLimits?) -> CodexAccountLimits {
        guard let current, current.observedAt > incoming.observedAt else { return incoming }
        return current
    }

    public static func apply(_ result: CodexAccountLimits, to local: ToolState, now: Date) -> ToolState {
        guard local.tool == .codex else { return local }
        let rows = result.buckets.enumerated().map { index, bucket -> OnlineBucketRow in
            let statuses = bucket.windows.compactMap { window -> LimitStatus? in
                guard let kind = window.kind else { return nil }
                let reset = window.resetsAt.map { $0 <= now } ?? false
                return LimitStatus(kind: kind, usedPercent: min(max(window.usedPercent, 0), 100),
                                   resetsAt: reset ? nil : window.resetsAt, isReset: reset,
                                   observedAt: result.observedAt)
            }
            let others = bucket.windows.filter { $0.kind == nil }.map { window in
                OnlineWindowRow(title: window.durationMinutes.map { "\($0)-minute" } ?? "Unknown window",
                                usedPercent: min(max(window.usedPercent, 0), 100),
                                resetsAt: window.resetsAt, observedAt: result.observedAt)
            }
            return OnlineBucketRow(title: "Limit bucket \(index + 1)",
                                   session: statuses.first { $0.kind == .session },
                                   weekly: statuses.first { $0.kind == .weekly },
                                   otherWindows: others)
        }
        guard rows.contains(where: { $0.session != nil || $0.weekly != nil || !$0.otherWindows.isEmpty }) else {
            return fallback(local, reason: "Account query returned no limit windows", now: now)
        }
        var state = local.withSummaryForLimits(now: now)
        state.limitSource = "Account query"
        state.limitObservedAt = result.observedAt
        state.onlineFailure = nil
        if rows.count == 1 {
            state.summary?.limits = [rows[0].session, rows[0].weekly].compactMap { $0 }
            state.limitWindows = state.summary?.limits.compactMap { status in
                guard let resetsAt = status.resetsAt, resetsAt > now else { return nil }
                return LimitWindow(kind: status.kind, usedPercent: status.usedPercent,
                                   resetsAt: resetsAt, observedAt: status.observedAt)
            } ?? []
            state.onlineBucketRows = rows[0].otherWindows.isEmpty ? [] : rows
            if state.summary?.limits.isEmpty == true { state.unavailableReason = .noData }
        } else {
            state.summary?.limits = []
            state.limitWindows = []
            state.onlineBucketRows = rows
            state.unavailableReason = .noData
        }
        return state
    }

    public static func fallback(_ local: ToolState, reason: String, now: Date) -> ToolState {
        var state = local
        state.onlineFailure = reason
        state.limitSource = "Local logs"
        state.onlineBucketRows = []
        // Local reset timestamps cannot prove that the account quota recovered.
        state.summary?.limits.removeAll { $0.isReset }
        if state.summary?.limits.isEmpty == true { state.unavailableReason = .noData }
        return state
    }
}
