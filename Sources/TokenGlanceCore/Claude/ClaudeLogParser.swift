import Foundation

/// Extracts token usage from Claude Code project logs (`projects/**/*.jsonl`).
///
/// Claude Code writes one line per content block of a response, each carrying a usage snapshot,
/// and the same response can reappear in other files (resumed sessions, subagents). Lines are
/// deduplicated globally by `message.id` + `requestId`, keeping the snapshot with the highest
/// `output_tokens` (the final one). See docs/log-schemas.md §1.2.
public struct ClaudeLogParser {
    private struct Key: Hashable {
        let messageID: String
        let requestID: String?
    }

    private var best: [Key: UsageRecord] = [:]
    private let timestamps = TimestampParser()

    public init() {}

    /// Feeds the contents of one JSONL file. Lines that are not usable assistant lines are ignored.
    public mutating func consume(_ data: Data) {
        let decoder = JSONDecoder()
        for line in JSONLines.lines(in: data) {
            // Cheap pre-filter: most lines are attachments, user turns, etc.
            guard line.range(of: Self.assistantMarker) != nil,
                  let entry = try? decoder.decode(Line.self, from: line),
                  let record = record(from: entry)
            else { continue }
            let key = Key(messageID: record.messageID, requestID: entry.requestId)
            if let existing = best[key], existing.usage.output >= record.value.usage.output { continue }
            best[key] = record.value
        }
    }

    /// Deduplicated records, ordered by time.
    public var records: [UsageRecord] {
        best.values.sorted { ($0.timestamp, $0.model) < ($1.timestamp, $1.model) }
    }

    private static let assistantMarker = Data(#""assistant""#.utf8)
    private static let syntheticModel = "<synthetic>"

    private func record(from entry: Line) -> (messageID: String, value: UsageRecord)? {
        guard entry.type == "assistant",
              let message = entry.message,
              let id = message.id,
              let model = message.model, model != Self.syntheticModel,
              let usage = message.usage,
              let timestamp = timestamps.date(from: entry.timestamp)
        else { return nil }
        let tokens = TokenUsage(
            input: usage.input_tokens ?? 0,
            output: usage.output_tokens ?? 0,
            cacheRead: usage.cache_read_input_tokens ?? 0,
            cacheWrite: usage.cache_creation_input_tokens ?? 0,
            reasoning: usage.output_tokens_details?.thinking_tokens ?? 0
        )
        return (id, UsageRecord(timestamp: timestamp, model: model, usage: tokens))
    }

    // Only the fields we use; everything else (including message content) is ignored.
    private struct Line: Decodable {
        let type: String?
        let timestamp: String?
        let requestId: String?
        let message: Message?
    }

    private struct Message: Decodable {
        let id: String?
        let model: String?
        let usage: Usage?
    }

    private struct Usage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let cache_creation_input_tokens: Int?
        let cache_read_input_tokens: Int?
        let output_tokens_details: OutputDetails?
    }

    private struct OutputDetails: Decodable {
        let thinking_tokens: Int?
    }
}
