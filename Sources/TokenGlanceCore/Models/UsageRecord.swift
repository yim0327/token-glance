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
