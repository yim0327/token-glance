import Foundation

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

    public var message: String {
        switch self {
        case .noData: "no data yet"
        case .corrupt: "data could not be read"
        case .stale: "data is more than 7 days old"
        case .unsupportedVersion: "cache written by a newer Token Glance"
        case .hookNotInstalled: "statusline hook not installed"
        case .hookOverwritten: "statusline hook was replaced (e.g. by an OMC update)"
        case .hookMissing: "statusline hook binary is missing"
        case .settingsUnreadable: "Claude settings.json could not be read"
        }
    }
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

    public var displayName: String {
        switch tool {
        case .claude: "Claude"
        case .codex: "Codex"
        }
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
        return ToolState(tool: tool, isEnabled: isEnabled, summary: summary, unavailableReason: reason,
                         hookStatus: hookStatus, refreshedAt: now)
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
