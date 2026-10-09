import Foundation

/// Claude Code rate limits as captured from statusline input. Only these numbers are stored:
/// no paths, session ids/names, prompt ids or other statusline fields. See docs/log-schemas.md §3.4.
public struct ClaudeRateLimitCache: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public struct Window: Codable, Equatable, Sendable {
        public var usedPercentage: Double
        /// Unix epoch seconds.
        public var resetsAt: Int
        /// When the hook last saw this window. Windows are updated independently.
        public var observedAt: Date

        public init(usedPercentage: Double, resetsAt: Int, observedAt: Date) {
            self.usedPercentage = usedPercentage
            self.resetsAt = resetsAt
            self.observedAt = observedAt
        }

        enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case resetsAt = "resets_at"
            case observedAt = "observed_at"
        }
    }

    public var schemaVersion: Int
    public var claudeVersion: String?
    public var fiveHour: Window?
    public var sevenDay: Window?

    public init(schemaVersion: Int = currentSchemaVersion, claudeVersion: String? = nil, fiveHour: Window? = nil, sevenDay: Window? = nil) {
        self.schemaVersion = schemaVersion
        self.claudeVersion = claudeVersion
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case claudeVersion = "claude_version"
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    /// Applies one statusline input to `existing`.
    ///
    /// Each window present with both `used_percentage` and `resets_at` replaces the stored one;
    /// absent or incomplete windows keep their previous value. Returns `nil` when the input carries
    /// no usable window (nothing to write). Throws if the input is not a JSON object.
    public static func updated(_ existing: ClaudeRateLimitCache?, with statuslineInput: Data, at now: Date) throws -> ClaudeRateLimitCache? {
        let input = try JSONDecoder().decode(StatuslineInput.self, from: statuslineInput)
        let fiveHour = input.rate_limits?.five_hour?.window(observedAt: now)
        let sevenDay = input.rate_limits?.seven_day?.window(observedAt: now)
        guard fiveHour != nil || sevenDay != nil else { return nil }

        var cache = existing ?? ClaudeRateLimitCache()
        cache.schemaVersion = currentSchemaVersion
        cache.claudeVersion = input.version ?? cache.claudeVersion
        if let fiveHour { cache.fiveHour = fiveHour }
        if let sevenDay { cache.sevenDay = sevenDay }
        return cache
    }

    public func encoded() throws -> Data {
        try Self.encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> ClaudeRateLimitCache {
        try decoder.decode(ClaudeRateLimitCache.self, from: data)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: - Statusline input (only the fields we read)

    private struct StatuslineInput: Decodable {
        let version: String?
        let rate_limits: RateLimits?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try? c.decodeIfPresent(String.self, forKey: .version)
            rate_limits = try? c.decodeIfPresent(RateLimits.self, forKey: .rate_limits)
        }

        enum CodingKeys: String, CodingKey { case version, rate_limits }
    }

    private struct RateLimits: Decodable {
        let five_hour: InputWindow?
        let seven_day: InputWindow?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            five_hour = try? c.decodeIfPresent(InputWindow.self, forKey: .five_hour)
            seven_day = try? c.decodeIfPresent(InputWindow.self, forKey: .seven_day)
        }

        enum CodingKeys: String, CodingKey { case five_hour, seven_day }
    }

    private struct InputWindow: Decodable {
        let used_percentage: Double?
        let resets_at: Double?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            used_percentage = try? c.decodeIfPresent(Double.self, forKey: .used_percentage)
            // Observed as epoch seconds; also accept numeric strings and milliseconds defensively.
            if let number = try? c.decodeIfPresent(Double.self, forKey: .resets_at) {
                resets_at = number
            } else if let string = try? c.decodeIfPresent(String.self, forKey: .resets_at) {
                resets_at = Double(string)
            } else {
                resets_at = nil
            }
        }

        enum CodingKeys: String, CodingKey { case used_percentage, resets_at }

        func window(observedAt: Date) -> Window? {
            guard let used_percentage, let resets_at, resets_at.isFinite, resets_at > 0 else { return nil }
            let seconds = resets_at >= 1e12 ? resets_at / 1000 : resets_at
            return Window(usedPercentage: used_percentage, resetsAt: Int(seconds), observedAt: observedAt)
        }
    }
}
