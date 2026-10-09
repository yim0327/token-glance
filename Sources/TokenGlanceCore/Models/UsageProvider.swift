import Foundation

public enum Tool: String, Sendable, CaseIterable {
    case claude
    case codex
}

/// Everything a provider could read from local data at one point in time.
public struct UsageSnapshot: Equatable, Sendable {
    public var limits: [LimitWindow]
    public var records: [UsageRecord]

    public init(limits: [LimitWindow] = [], records: [UsageRecord] = []) {
        self.limits = limits
        self.records = records
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
