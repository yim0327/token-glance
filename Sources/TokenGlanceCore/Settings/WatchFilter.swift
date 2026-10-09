import Foundation

/// Decides whether a batch of file-system event paths can affect what Token Glance shows.
/// Claude Code writes many other files under `projects/` (tool outputs, snapshots); skipping those
/// avoids refreshes that would read nothing.
public struct WatchFilter: Sendable {
    public let rateLimitCache: URL

    public init(rateLimitCache: URL) {
        self.rateLimitCache = rateLimitCache
    }

    public func isRelevant(_ paths: [String]) -> Bool {
        paths.contains { path in
            if path.hasSuffix(".jsonl") || path == rateLimitCache.path { return true }
            // A path without an extension or ending in "/" is a directory event: rescan.
            let name = (path as NSString).lastPathComponent
            return path.hasSuffix("/") || !name.contains(".")
        }
    }
}
