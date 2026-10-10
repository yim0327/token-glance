import Foundation

/// One plan limit window from Claude Code's `get_usage` answer.
public struct ClaudeLimitWindow: Equatable, Sendable {
    public let kind: LimitWindow.Kind
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(kind: LimitWindow.Kind, usedPercent: Double, resetsAt: Date?) {
        self.kind = kind
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

/// The session and weekly plan limits Claude Code reported. Only percentages and reset times are
/// kept; the rest of the answer (cost, plan type, model and spend rows) is dropped while decoding.
public struct ClaudeAccountLimits: Equatable, Sendable {
    public let windows: [ClaudeLimitWindow]
    public let observedAt: Date

    public init(windows: [ClaudeLimitWindow], observedAt: Date) {
        self.windows = windows
        self.observedAt = observedAt
    }

    /// Server meter kinds (`limits[].kind`) this app shows. Scoped weekly meters (per model or
    /// surface) and unknown kinds are ignored rather than guessed.
    static let kinds: [String: LimitWindow.Kind] = ["session": .session, "weekly_all": .weekly]
    /// Older answers without `limits[]` carry the same two windows under these keys.
    static let legacyKeys: [String: LimitWindow.Kind] = ["five_hour": .session, "seven_day": .weekly]

    /// Decodes the `response` object of a successful `get_usage` control response.
    public static func decode(_ value: [String: Any], observedAt: Date) -> Result<ClaudeAccountLimits, ClaudeUsageFailure> {
        if value["rate_limits_available"] as? Bool == false { return .failure(.subscriptionRequired) }
        guard let rateLimits = value["rate_limits"] as? [String: Any] else {
            // Claude Code answers null while its usage fetch fails (expired login, rate limit,
            // network); it does not say which.
            return value.keys.contains("rate_limits") ? .failure(.unavailable) : .failure(.invalidResponse)
        }
        var found: [LimitWindow.Kind: [ClaudeLimitWindow]] = [:]
        if let rows = rateLimits["limits"] as? [Any] {
            for case let row as [String: Any] in rows {
                guard let name = row["kind"] as? String, let kind = kinds[name],
                      let window = window(kind: kind, percent: row["percent"], resetsAt: row["resets_at"]) else { continue }
                found[kind, default: []].append(window)
            }
        } else {
            for (key, kind) in legacyKeys {
                guard let entry = rateLimits[key] as? [String: Any],
                      let window = window(kind: kind, percent: entry["utilization"], resetsAt: entry["resets_at"]) else { continue }
                found[kind, default: []].append(window)
            }
        }
        // Two rows of one kind would be a meter this app does not understand; show neither.
        let windows = LimitWindow.Kind.allCases.compactMap { kind in
            found[kind].flatMap { $0.count == 1 ? $0[0] : nil }
        }
        return .success(ClaudeAccountLimits(windows: windows, observedAt: observedAt))
    }

    private static func window(kind: LimitWindow.Kind, percent: Any?, resetsAt: Any?) -> ClaudeLimitWindow? {
        guard let percent = (percent as? NSNumber)?.doubleValue, percent.isFinite else { return nil }
        return ClaudeLimitWindow(kind: kind, usedPercent: min(max(percent, 0), 100),
                                 resetsAt: (resetsAt as? String).flatMap(parseDate))
    }

    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// Why an online Claude limit read failed. Cases carry no text from Claude Code or the server.
public enum ClaudeUsageFailure: Error, Equatable, Sendable {
    case disabled
    case executableUnavailable
    case launchFailed
    /// Signed in with an API key or a third-party provider, or not signed in to a subscription.
    case subscriptionRequired
    /// Claude Code could not get the plan usage right now (it answered `rate_limits: null`).
    case unavailable
    /// The installed Claude Code rejected the control request (too old or changed).
    case unsupported
    case timeout
    case disconnected
    case invalidResponse

    /// Failures worth a quick retry right after launch or wake, before the network is up.
    public var isTransient: Bool {
        switch self {
        case .unavailable, .timeout, .disconnected: true
        // A child that cannot start (or exits at once, e.g. an old Claude Code rejecting a flag)
        // will not start a few seconds later either.
        case .disabled, .executableUnavailable, .launchFailed, .subscriptionRequired, .unsupported, .invalidResponse: false
        }
    }
}
