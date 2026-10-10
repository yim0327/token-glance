import Foundation

public struct CodexLimitWindow: Equatable, Sendable {
    public let durationMinutes: Int?
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(durationMinutes: Int?, usedPercent: Double, resetsAt: Date?) {
        self.durationMinutes = durationMinutes
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    public var kind: LimitWindow.Kind? {
        switch durationMinutes {
        case 300: .session
        case 10_080: .weekly
        default: nil
        }
    }
}

public struct CodexLimitBucket: Equatable, Sendable {
    /// Opaque meter identity. Kept in memory only.
    public let limitId: String?
    public let windows: [CodexLimitWindow]

    public init(limitId: String?, windows: [CodexLimitWindow]) {
        self.limitId = limitId
        self.windows = windows
    }
}

public struct CodexAccountLimits: Equatable, Sendable {
    /// Opaque account identity, when the server supplies it. Kept in memory only.
    public let accountIdentity: String?
    public let buckets: [CodexLimitBucket]
    public let observedAt: Date

    public init(accountIdentity: String?, buckets: [CodexLimitBucket], observedAt: Date) {
        self.accountIdentity = accountIdentity
        self.buckets = buckets
        self.observedAt = observedAt
    }

    public static func decode(_ value: [String: Any], observedAt: Date) -> CodexAccountLimits? {
        var buckets: [CodexLimitBucket] = []
        if let byID = value["rateLimitsByLimitId"] as? [String: Any], !byID.isEmpty {
            for key in byID.keys.sorted() {
                // A missing bucket must not turn a multi-bucket account into a single
                // apparently complete limit in the menu bar.
                guard let snapshot = byID[key] as? [String: Any] else { return nil }
                buckets.append(bucket(snapshot, fallbackID: key))
            }
        } else if let snapshot = value["rateLimits"] as? [String: Any] {
            buckets = [bucket(snapshot, fallbackID: nil)]
        } else {
            return nil
        }
        return CodexAccountLimits(accountIdentity: value["accountId"] as? String,
                                  buckets: buckets, observedAt: observedAt)
    }

    private static func bucket(_ value: [String: Any], fallbackID: String?) -> CodexLimitBucket {
        let windows = ["primary", "secondary"].compactMap { key -> CodexLimitWindow? in
            guard let raw = value[key] as? [String: Any],
                  let percent = (raw["usedPercent"] as? NSNumber)?.doubleValue,
                  percent.isFinite else { return nil }
            let minutes = (raw["windowDurationMins"] as? NSNumber)?.intValue
            let epoch = (raw["resetsAt"] as? NSNumber)?.doubleValue
            return CodexLimitWindow(durationMinutes: minutes, usedPercent: percent,
                                    resetsAt: epoch.map(Date.init(timeIntervalSince1970:)))
        }
        return CodexLimitBucket(limitId: value["limitId"] as? String ?? fallbackID, windows: windows)
    }
}

public enum CodexAppServerFailure: Error, Equatable, Sendable {
    case disabled
    case executableUnavailable
    case launchFailed
    case loginRequired
    case apiKeyAccount
    case unsupportedMethod
    case timeout
    case rateLimited(retryAfter: Date)
    case disconnected
    case invalidResponse
}
