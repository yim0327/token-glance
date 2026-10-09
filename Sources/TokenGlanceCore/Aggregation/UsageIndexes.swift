import Foundation

/// Incrementally maintained Claude usage: per-file dedupe summaries, merged on demand.
///
/// Only key → best usage summaries are kept per file (no lines or content). Merging the files in
/// path order gives exactly the result of parsing all files from scratch (see `ClaudeLogParser`).
public struct ClaudeUsageIndex {
    private var tailed = TailedFiles<ClaudeLogParser>()
    /// Merged, deduplicated records; recomputed only when a file changed.
    public private(set) var records: [UsageRecord] = []

    public init() {}

    /// Reads whatever was appended to `files` since the last update. Returns whether anything changed.
    @discardableResult
    public mutating func update(files: [URL], source: any TailSource, onRead: ((Int) -> Void)? = nil) -> Bool {
        let changed = tailed.sync(files, source: source, onRead: onRead)
        if changed { remerge() }
        return changed
    }

    public mutating func prune(before cutoff: Date) {
        tailed.updateStates { $0.prune(before: cutoff) }
        remerge()
    }

    public var bytesRead: Int { tailed.bytesRead }
    public var trackedFileCount: Int { tailed.files.count }

    private mutating func remerge() {
        records = ClaudeLogParser.merged(tailed.files.sorted { $0.key < $1.key }.map(\.value.state))
    }
}

/// Incrementally maintained Codex usage: per-session cumulative baseline, records and newest limits.
public struct CodexUsageIndex {
    private var tailed = TailedFiles<CodexSessionParser>()

    public init() {}

    @discardableResult
    public mutating func update(files: [URL], source: any TailSource, onRead: ((Int) -> Void)? = nil) -> Bool {
        tailed.sync(files, source: source, onRead: onRead)
    }

    /// Sessions in path order, matching `CodexRolloutParser` fed with files in path order.
    private var sessions: [CodexSessionParser] { tailed.files.sorted { $0.key < $1.key }.map(\.value.state) }

    public var records: [UsageRecord] { CodexSessionParser.records(of: sessions) }
    public var limits: [LimitWindow] { CodexSessionParser.limits(of: sessions) }

    public mutating func prune(before cutoff: Date) {
        tailed.updateStates { $0.prune(before: cutoff) }
    }

    public var bytesRead: Int { tailed.bytesRead }
}
