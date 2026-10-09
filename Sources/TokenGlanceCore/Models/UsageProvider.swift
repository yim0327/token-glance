import Foundation

public enum Tool: String, Sendable, CaseIterable {
    case claude
    case codex
}

/// Why a provider has no limit values to show.
public enum LimitsUnavailableReason: String, Equatable, Sendable {
    /// Nothing recorded yet (no hook cache / no rollout with rate limits).
    case noData
    /// The source exists but could not be parsed.
    case corrupt
    /// Written by a newer Token Glance with a different cache schema.
    case unsupportedVersion
    /// Last observation is too old to be meaningful.
    case stale
}

/// Everything a provider could read from local data at one point in time.
public struct UsageSnapshot: Equatable, Sendable {
    public var limits: [LimitWindow]
    public var records: [UsageRecord]
    /// Set when `limits` is empty, explaining why.
    public var limitsIssue: LimitsUnavailableReason?

    public init(limits: [LimitWindow] = [], records: [UsageRecord] = [], limitsIssue: LimitsUnavailableReason? = nil) {
        self.limits = limits
        self.records = records
        self.limitsIssue = limitsIssue
    }

    public func limit(_ kind: LimitWindow.Kind) -> LimitWindow? {
        limits.first { $0.kind == kind }
    }
}

/// Reads one tool's local data. Implementations must not throw on malformed content:
/// unreadable files and lines are skipped.
public protocol UsageProvider: Sendable {
    var tool: Tool { get }
    func snapshot() -> UsageSnapshot
}
