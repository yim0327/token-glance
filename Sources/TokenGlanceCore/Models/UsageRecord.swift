import Foundation

/// One deduplicated unit of token usage (a Claude API response, or a Codex token-count delta).
public struct UsageRecord: Equatable, Sendable {
    public var timestamp: Date
    public var model: String
    public var usage: TokenUsage

    public init(timestamp: Date, model: String, usage: TokenUsage) {
        self.timestamp = timestamp
        self.model = model
        self.usage = usage
    }
}

extension UsageRecord {
    /// Total order used for every record list, so results never depend on dictionary iteration order.
    static func precedes(_ a: UsageRecord, _ b: UsageRecord) -> Bool {
        let lhs = (a.timestamp, a.model, a.usage.output, a.usage.input, a.usage.cacheRead, a.usage.cacheWrite)
        let rhs = (b.timestamp, b.model, b.usage.output, b.usage.input, b.usage.cacheRead, b.usage.cacheWrite)
        return lhs != rhs ? lhs < rhs : a.usage.reasoning < b.usage.reasoning
    }
}
