import Foundation

/// A rate-limit window reported by a tool, e.g. the 5-hour session or 7-day weekly limit.
public struct LimitWindow: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case session
        case weekly

        /// Nominal window length, used to derive the window start from `resetsAt`.
        public var duration: TimeInterval {
            switch self {
            case .session: 5 * 60 * 60
            case .weekly: 7 * 24 * 60 * 60
            }
        }
    }

    public var kind: Kind
    /// Percent of the window already used, as reported (0...100).
    public var usedPercent: Double
    public var resetsAt: Date
    /// When this value was reported by the tool.
    public var observedAt: Date

    public init(kind: Kind, usedPercent: Double, resetsAt: Date, observedAt: Date) {
        self.kind = kind
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.observedAt = observedAt
    }

    /// The window has rolled over since it was observed.
    public func isReset(at now: Date) -> Bool {
        resetsAt <= now
    }

    /// Used percent clamped to 0...100; 0 once the window has reset.
    public func usedPercent(at now: Date) -> Double {
        isReset(at: now) ? 0 : min(max(usedPercent, 0), 100)
    }

    public func remainingPercent(at now: Date) -> Double {
        100 - usedPercent(at: now)
    }

    /// Start of the window this value belongs to.
    public var startsAt: Date {
        resetsAt.addingTimeInterval(-kind.duration)
    }
}
