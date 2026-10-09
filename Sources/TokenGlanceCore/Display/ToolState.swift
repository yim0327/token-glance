import Foundation

/// One account limit bucket. A multi-bucket response stays separated in the popover.
public struct OnlineBucketRow: Equatable, Sendable {
    public var title: String
    public var session: LimitStatus?
    public var weekly: LimitStatus?
    public var otherWindows: [OnlineWindowRow]

    public init(title: String, session: LimitStatus?, weekly: LimitStatus?, otherWindows: [OnlineWindowRow] = []) {
        self.title = title
        self.session = session
        self.weekly = weekly
        self.otherWindows = otherWindows
    }
}

public struct OnlineWindowRow: Equatable, Sendable {
    public var title: String
    public var usedPercent: Double
    public var resetsAt: Date?
    public var observedAt: Date
}

/// Why a tool shows no limit values, in terms a user can act on.
public enum UnavailableReason: Equatable, Sendable {
    case noData
    case corrupt
    case stale
    case unsupportedVersion
    case hookNotInstalled
    case hookOverwritten
    case hookMissing
    case settingsUnreadable
}

/// Everything the UI needs about one tool at one refresh.
public struct ToolState: Equatable, Sendable {
    public var tool: Tool
    public var isEnabled: Bool
    public var summary: UsageSummary?
    /// Set when there are no limit values to show.
    public var unavailableReason: UnavailableReason?
    /// Claude only: state of the statusline hook installation.
    public var hookStatus: StatuslineInstaller.Status?
    public var refreshedAt: Date?
    /// The limit observations behind `summary.limits` (for alert decisions); empty when unavailable.
    public var limitWindows: [LimitWindow] = []
    /// Daily totals for the last 14 days (see `UsageHistory`).
    public var history: [DailyUsage] = []
    /// Codex limit provenance; token totals still come from local logs.
    public var limitSource: String?
    public var limitObservedAt: Date?
    public var onlineFailure: String?
    public var onlineBucketRows: [OnlineBucketRow] = []

    public init(tool: Tool, isEnabled: Bool = true, summary: UsageSummary? = nil, unavailableReason: UnavailableReason? = nil,
                hookStatus: StatuslineInstaller.Status? = nil, refreshedAt: Date? = nil) {
        self.tool = tool
        self.isEnabled = isEnabled
        self.summary = summary
        self.unavailableReason = unavailableReason
        self.hookStatus = hookStatus
        self.refreshedAt = refreshedAt
    }

    /// Equal apart from `refreshedAt`.
    public func sameContent(as other: ToolState) -> Bool {
        var copy = other
        copy.refreshedAt = refreshedAt
        return copy == self
    }

    public var session: LimitStatus? { summary?.limits.first { $0.kind == .session } }
    public var weekly: LimitStatus? { summary?.limits.first { $0.kind == .weekly } }

    /// Claude only: the hook needs attention even if cached values are still shown.
    public var hookNeedsAttention: Bool {
        guard let hookStatus else { return false }
        return hookStatus != .installed
    }

    public static func make(tool: Tool, snapshot: UsageSnapshot, hookStatus: StatuslineInstaller.Status?,
                            aggregator: UsageAggregator, now: Date, isEnabled: Bool = true) -> ToolState {
        let summary = aggregator.summary(of: snapshot, now: now)
        var reason: UnavailableReason?
        if summary.limits.isEmpty {
            reason = hookReason(hookStatus) ?? snapshot.limitsIssue.map(Self.reason) ?? .noData
        }
        var state = ToolState(tool: tool, isEnabled: isEnabled, summary: summary, unavailableReason: reason,
                              hookStatus: hookStatus, refreshedAt: now)
        state.limitWindows = snapshot.limits
        if tool == .codex {
            state.limitSource = "Local logs"
            state.limitObservedAt = snapshot.limits.map(\.observedAt).max()
        }
        return state
    }

    /// When Claude has no cached limits, a broken hook installation is the more useful explanation.
    private static func hookReason(_ status: StatuslineInstaller.Status?) -> UnavailableReason? {
        switch status {
        case .notInstalled: .hookNotInstalled
        case .overwritten: .hookOverwritten
        case .hookMissing: .hookMissing
        case .settingsUnreadable: .settingsUnreadable
        case .installed, nil: nil
        }
    }

    private static func reason(_ issue: LimitsUnavailableReason) -> UnavailableReason {
        switch issue {
        case .noData: .noData
        case .corrupt: .corrupt
        case .unsupportedVersion: .unsupportedVersion
        case .stale: .stale
        }
    }
}
