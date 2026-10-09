import Foundation

/// Token usage from Claude Code logs; limits from the statusline hook cache.
public struct ClaudeUsageProvider: UsageProvider {
    public let tool = Tool.claude
    public let projectsRoot: URL
    public let fileSource: any FileSource
    public let rateLimitCache: ClaudeStatuslineCache
    public let now: @Sendable () -> Date

    /// `rateLimitCache` defaults to the standard cache location read through `fileSource`.
    public init(
        projectsRoot: URL = Self.defaultProjectsRoot(),
        fileSource: any FileSource = LocalFileSource(),
        rateLimitCache: ClaudeStatuslineCache? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.projectsRoot = projectsRoot
        self.fileSource = fileSource
        self.rateLimitCache = rateLimitCache
            ?? ClaudeStatuslineCache(fileURL: TokenGlancePaths.default().rateLimitCache, fileSource: fileSource)
        self.now = now
    }

    /// `${CLAUDE_CONFIG_DIR:-~/.claude}/projects`
    public static func defaultProjectsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let configDir = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".claude")
        return configDir.appendingPathComponent("projects")
    }

    public func snapshot() -> UsageSnapshot {
        var parser = ClaudeLogParser()
        for url in fileSource.files(under: projectsRoot, where: { $0.hasSuffix(".jsonl") }) {
            guard let data = try? fileSource.contents(of: url) else { continue }
            parser.consume(data)
        }
        switch rateLimitCache.read(now: now()) {
        case .available(let windows):
            return UsageSnapshot(limits: windows, records: parser.records)
        case .unavailable(let reason):
            return UsageSnapshot(records: parser.records, limitsIssue: reason)
        }
    }
}
