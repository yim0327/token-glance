import Foundation

/// Extracts token usage and rate limits from Codex rollout files (`sessions/**/rollout-*.jsonl`).
///
/// `token_count` events carry a session-cumulative `total_token_usage`; usage is the delta between
/// consecutive events, so repeated snapshots add nothing. If the cumulative value goes backwards,
/// `last_token_usage` is used for that event. Tokens are attributed to the model of the most recent
/// `turn_context`. See docs/log-schemas.md §2.
public struct CodexRolloutParser {
    private var records_: [UsageRecord] = []
    private var newestLimits: [LimitWindow.Kind: LimitWindow] = [:]
    private let timestamps = TimestampParser()

    public init() {}

    static let unknownModel = "unknown"

    /// Feeds one rollout file (one session). Malformed lines are ignored.
    public mutating func consume(_ data: Data) {
        let decoder = JSONDecoder()
        var model = Self.unknownModel
        var previousTotal: RawUsage?
        for line in JSONLines.lines(in: data) {
            guard let entry = try? decoder.decode(Line.self, from: line),
                  let payload = entry.payload
            else { continue }
            if entry.type == "turn_context", let turnModel = payload.model {
                model = turnModel
                continue
            }
            guard entry.type == "event_msg", payload.type == "token_count",
                  let timestamp = timestamps.date(from: entry.timestamp)
            else { continue }

            if let rateLimits = payload.rate_limits {
                record(rateLimits, observedAt: timestamp)
            }
            guard let info = payload.info, let total = info.total_token_usage else { continue }
            let delta: RawUsage
            if let previous = previousTotal {
                let difference = total - previous
                delta = difference.hasNegative ? (info.last_token_usage ?? total) : difference
            } else {
                delta = total
            }
            previousTotal = total
            let usage = delta.normalized
            if !usage.isZero {
                records_.append(UsageRecord(timestamp: timestamp, model: model, usage: usage))
            }
        }
    }

    /// Records from all consumed sessions, ordered by time.
    public var records: [UsageRecord] {
        records_.sorted { $0.timestamp < $1.timestamp }
    }

    /// The most recently observed window of each kind.
    public var limits: [LimitWindow] {
        LimitWindow.Kind.allCases.compactMap { newestLimits[$0] }
    }

    /// Codex labels windows `primary` / `secondary`; classify by length instead of slot name.
    static func kind(forWindowMinutes minutes: Int) -> LimitWindow.Kind {
        minutes <= 24 * 60 ? .session : .weekly
    }

    private mutating func record(_ rateLimits: RateLimits, observedAt: Date) {
        for window in [rateLimits.primary, rateLimits.secondary].compactMap({ $0 }) {
            guard let minutes = window.window_minutes,
                  let percent = window.used_percent,
                  let resetsAt = window.resets_at
            else { continue }
            let limit = LimitWindow(
                kind: Self.kind(forWindowMinutes: minutes),
                usedPercent: percent,
                resetsAt: Date(timeIntervalSince1970: resetsAt),
                observedAt: observedAt
            )
            if let existing = newestLimits[limit.kind], existing.observedAt > observedAt { continue }
            newestLimits[limit.kind] = limit
        }
    }

    // MARK: - Decoding (only the fields we use)

    private struct Line: Decodable {
        let timestamp: String?
        let type: String?
        let payload: Payload?
    }

    private struct Payload: Decodable {
        let type: String?
        let model: String?
        let info: Info?
        let rate_limits: RateLimits?
    }

    private struct Info: Decodable {
        let total_token_usage: RawUsage?
        let last_token_usage: RawUsage?
    }

    private struct RateLimits: Decodable {
        let primary: Window?
        let secondary: Window?
    }

    private struct Window: Decodable {
        let used_percent: Double?
        let window_minutes: Int?
        let resets_at: Double?
    }

    /// Codex usage as reported: `input_tokens` includes `cached_input_tokens`,
    /// `output_tokens` includes `reasoning_output_tokens`.
    private struct RawUsage: Decodable {
        var input_tokens: Int = 0
        var cached_input_tokens: Int = 0
        var cache_write_input_tokens: Int = 0
        var output_tokens: Int = 0
        var reasoning_output_tokens: Int = 0

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            input_tokens = try c.decodeIfPresent(Int.self, forKey: .input_tokens) ?? 0
            cached_input_tokens = try c.decodeIfPresent(Int.self, forKey: .cached_input_tokens) ?? 0
            cache_write_input_tokens = try c.decodeIfPresent(Int.self, forKey: .cache_write_input_tokens) ?? 0
            output_tokens = try c.decodeIfPresent(Int.self, forKey: .output_tokens) ?? 0
            reasoning_output_tokens = try c.decodeIfPresent(Int.self, forKey: .reasoning_output_tokens) ?? 0
        }

        private init(_ input: Int, _ cached: Int, _ cacheWrite: Int, _ output: Int, _ reasoning: Int) {
            input_tokens = input
            cached_input_tokens = cached
            cache_write_input_tokens = cacheWrite
            output_tokens = output
            reasoning_output_tokens = reasoning
        }

        private enum CodingKeys: String, CodingKey {
            case input_tokens, cached_input_tokens, cache_write_input_tokens, output_tokens, reasoning_output_tokens
        }

        static func - (lhs: RawUsage, rhs: RawUsage) -> RawUsage {
            RawUsage(
                lhs.input_tokens - rhs.input_tokens,
                lhs.cached_input_tokens - rhs.cached_input_tokens,
                lhs.cache_write_input_tokens - rhs.cache_write_input_tokens,
                lhs.output_tokens - rhs.output_tokens,
                lhs.reasoning_output_tokens - rhs.reasoning_output_tokens
            )
        }

        var hasNegative: Bool {
            min(input_tokens, cached_input_tokens, cache_write_input_tokens, output_tokens, reasoning_output_tokens) < 0
        }

        var normalized: TokenUsage {
            TokenUsage(
                input: max(input_tokens - cached_input_tokens, 0),
                output: output_tokens,
                cacheRead: cached_input_tokens,
                cacheWrite: cache_write_input_tokens,
                reasoning: reasoning_output_tokens
            )
        }
    }
}
