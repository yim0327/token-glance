import Foundation

/// Token usage from Claude Code logs. Limits come from the statusline hook (M2), so `limits` is empty.
public struct ClaudeUsageProvider: UsageProvider {
    public let tool = Tool.claude
    public let projectsRoot: URL
    public let fileSource: any FileSource

    public init(projectsRoot: URL = Self.defaultProjectsRoot(), fileSource: any FileSource = LocalFileSource()) {
        self.projectsRoot = projectsRoot
        self.fileSource = fileSource
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
        return UsageSnapshot(records: parser.records)
    }
}
