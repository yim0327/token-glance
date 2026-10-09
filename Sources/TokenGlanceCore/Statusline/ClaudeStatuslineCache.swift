import Foundation

/// Reads the rate limits recorded by the statusline hook (see docs/log-schemas.md §3.4).
public struct ClaudeStatuslineCache: Sendable {
    public enum Reading: Equatable, Sendable {
        case available([LimitWindow])
        case unavailable(LimitsUnavailableReason)

        public var windows: [LimitWindow]? {
            if case .available(let windows) = self { return windows }
            return nil
        }
    }

    /// Cached values older than this say nothing useful about current limits.
    public static let staleAfter: TimeInterval = LimitWindow.Kind.weekly.duration

    public let fileURL: URL
    public let fileSource: any FileSource

    public init(fileURL: URL, fileSource: any FileSource = LocalFileSource()) {
        self.fileURL = fileURL
        self.fileSource = fileSource
    }

    /// Windows whose `resetsAt` has passed are returned as is; callers show them as reset
    /// via `LimitWindow.usedPercent(at:)` / `UsageAggregator.limitStatuses`.
    public func read(now: Date) -> Reading {
        guard let data = try? fileSource.contents(of: fileURL) else { return .unavailable(.noData) }
        guard let version = try? JSONDecoder().decode(VersionProbe.self, from: data) else { return .unavailable(.corrupt) }
        guard version.schema_version == ClaudeRateLimitCache.currentSchemaVersion else { return .unavailable(.unsupportedVersion) }
        guard let cache = try? ClaudeRateLimitCache.decode(data) else { return .unavailable(.corrupt) }

        let windows = [
            cache.fiveHour.map { Self.window(.session, $0) },
            cache.sevenDay.map { Self.window(.weekly, $0) },
        ].compactMap { $0 }
        guard let newest = windows.map(\.observedAt).max() else { return .unavailable(.noData) }
        guard now.timeIntervalSince(newest) <= Self.staleAfter else { return .unavailable(.stale) }
        return .available(windows)
    }

    private static func window(_ kind: LimitWindow.Kind, _ cached: ClaudeRateLimitCache.Window) -> LimitWindow {
        LimitWindow(
            kind: kind,
            usedPercent: cached.usedPercentage,
            resetsAt: Date(timeIntervalSince1970: TimeInterval(cached.resetsAt)),
            observedAt: cached.observedAt
        )
    }

    private struct VersionProbe: Decodable {
        let schema_version: Int
    }
}
