import Foundation

/// Extracts token usage from Claude Code project logs (`projects/**/*.jsonl`).
///
/// Claude Code writes one line per content block of a response, each carrying a usage snapshot,
/// and the same response can reappear in other files (resumed sessions, subagents). Lines are
/// deduplicated globally by `message.id` + `requestId`, keeping the snapshot with the highest
/// `output_tokens` (the final one). See docs/log-schemas.md §1.2.
public struct ClaudeLogParser: LineConsumer {
    struct Key: Hashable {
        let messageID: String
        let requestID: String?
    }

    private(set) var best: [Key: UsageRecord] = [:]
    private var timestamps: TimestampParser { .shared }
    private var decoder: JSONDecoder { SharedDecoder.json }

    public init() {}

    /// Feeds the contents of one JSONL file. Lines that are not usable assistant lines are ignored.
    public mutating func consume(_ data: Data) {
        for line in JSONLines.lines(in: data) { consume(line: line) }
    }

    /// Feeds one line. Within a parser, a key keeps the first line with the highest `output_tokens`.
    public mutating func consume(line: Data) {
        // Cheap pre-filter: most lines are attachments, user turns, etc.
        guard line.range(of: Self.assistantMarker) != nil,
              let entry = try? decoder.decode(Line.self, from: line),
              let record = record(from: entry)
        else { return }
        let key = Key(messageID: record.messageID, requestID: entry.requestId)
        if let existing = best[key], existing.usage.output >= record.value.usage.output { return }
        best[key] = record.value
    }

    /// Deduplicated records, ordered by time.
    public var records: [UsageRecord] {
        Self.sorted(best.values)
    }

    /// Merges per-file parsers in path order with the same rule as parsing the files one after
    /// another: a later file replaces a key only with a strictly higher `output_tokens`.
    static func merged<S: Sequence>(_ parsers: S) -> [UsageRecord] where S.Element == ClaudeLogParser {
        var merged: [Key: UsageRecord] = [:]
        for parser in parsers {
            for (key, record) in parser.best {
                if let existing = merged[key], existing.usage.output >= record.usage.output { continue }
                merged[key] = record
            }
        }
        return sorted(merged.values)
    }

    /// Forgets records older than `cutoff`.
    public mutating func prune(before cutoff: Date) {
        best = best.filter { $0.value.timestamp >= cutoff }
    }

    private static func sorted<S: Sequence>(_ records: S) -> [UsageRecord] where S.Element == UsageRecord {
        records.sorted(by: UsageRecord.precedes)
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
