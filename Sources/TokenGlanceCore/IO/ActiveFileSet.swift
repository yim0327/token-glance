import Foundation

/// The log files worth checking often: those that grew recently.
///
/// FSEvents does not report appends to a file the writer keeps open (Codex keeps its rollout open
/// for the whole session), so these files are checked with a cheap `stat` on a short timer instead.
/// Only sizes are compared here; reading the new bytes is left to the incremental indexes.
public struct ActiveFileSet: Sendable {
    public let window: TimeInterval
    /// Files modified within this interval are watched even without growth seen by this process
    /// (e.g. after an app restart, or an older session that is used again).
    public let recentlyModified: TimeInterval
    private var sizes: [URL: Int] = [:]
    private var modified: [URL: Date] = [:]
    private var lastGrowth: [URL: Date] = [:]
    /// False until the first update; files present then are not treated as new.
    private var hasBaseline = false

    public init(window: TimeInterval, recentlyModified: TimeInterval = 0) {
        self.window = window
        self.recentlyModified = recentlyModified
    }

    /// Records the sizes seen by the latest refresh.
    ///
    /// A file that appears after the first update (a new session) counts as just grown: Codex creates
    /// the file before it writes any usage, so it must be watched from the moment it shows up.
    public mutating func update(sizes newSizes: [URL: Int], modified newModified: [URL: Date] = [:], now: Date) {
        for (url, size) in newSizes {
            if let previous = sizes[url] {
                if previous != size { lastGrowth[url] = now }
            } else if hasBaseline {
                lastGrowth[url] = now
            }
        }
        sizes = newSizes
        modified = newModified
        hasBaseline = true
        lastGrowth = lastGrowth.filter { newSizes[$0.key] != nil }
        referenceTime = now
    }

    private var referenceTime = Date.distantPast

    /// Files that grew within `window` of the last update; if none did, the one that grew most
    /// recently (or, if none ever grew, the last by path — rollout names sort by start time).
    public var active: [URL] {
        let grew = lastGrowth.filter { referenceTime.timeIntervalSince($0.value) <= window }.map(\.key)
        let touched = modified.filter { referenceTime.timeIntervalSince($0.value) <= recentlyModified }.map(\.key)
        let recent = Set(grew).union(touched)
        if !recent.isEmpty { return recent.sorted { $0.path < $1.path } }
        if let latest = lastGrowth.max(by: { $0.value < $1.value })?.key { return [latest] }
        return sizes.keys.max { $0.path < $1.path }.map { [$0] } ?? []
    }

    /// Whether any active file's size differs from the recorded one (or the file is gone).
    public func hasChanges(source: any TailSource) -> Bool {
        active.contains { source.stat($0)?.size != sizes[$0] }
    }
}
