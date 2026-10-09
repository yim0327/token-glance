import Foundation

/// The log files worth checking often: those that grew recently.
///
/// FSEvents does not report appends to a file the writer keeps open (Codex keeps its rollout open
/// for the whole session), so these files are checked with a cheap `stat` on a short timer instead.
/// Only sizes are compared here; reading the new bytes is left to the incremental indexes.
public struct ActiveFileSet: Sendable {
    public let window: TimeInterval
    private var sizes: [URL: Int] = [:]
    private var lastGrowth: [URL: Date] = [:]

    public init(window: TimeInterval) {
        self.window = window
    }

    /// Records the sizes seen by the latest refresh.
    public mutating func update(sizes newSizes: [URL: Int], now: Date) {
        for (url, size) in newSizes where sizes[url] != nil && sizes[url] != size {
            lastGrowth[url] = now
        }
        sizes = newSizes
        lastGrowth = lastGrowth.filter { newSizes[$0.key] != nil }
        referenceTime = now
    }

    private var referenceTime = Date.distantPast

    /// Files that grew within `window` of the last update; if none did, the one that grew most
    /// recently (or, if none ever grew, the last by path — rollout names sort by start time).
    public var active: [URL] {
        let recent = lastGrowth.filter { referenceTime.timeIntervalSince($0.value) <= window }.map(\.key)
        if !recent.isEmpty { return recent.sorted { $0.path < $1.path } }
        if let latest = lastGrowth.max(by: { $0.value < $1.value })?.key { return [latest] }
        return sizes.keys.max { $0.path < $1.path }.map { [$0] } ?? []
    }

    /// Whether any active file's size differs from the recorded one (or the file is gone).
    public func hasChanges(source: any TailSource) -> Bool {
        active.contains { source.stat($0)?.size != sizes[$0] }
    }
}
