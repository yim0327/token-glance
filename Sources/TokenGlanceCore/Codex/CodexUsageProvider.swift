import Foundation

/// Limits and token usage from Codex CLI rollout files.
public struct CodexUsageProvider: UsageProvider {
    public let tool = Tool.codex
    public let codexHome: URL
    public let fileSource: any FileSource

    public init(codexHome: URL = Self.defaultCodexHome(), fileSource: any FileSource = LocalFileSource()) {
        self.codexHome = codexHome
        self.fileSource = fileSource
    }

    /// `${CODEX_HOME:-~/.codex}`
    public static func defaultCodexHome(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex")
    }

    public func snapshot() -> UsageSnapshot {
        var parser = CodexRolloutParser()
        for directory in ["sessions", "archived_sessions"] {
            let root = codexHome.appendingPathComponent(directory)
            for url in fileSource.files(under: root, where: Self.isRollout) {
                guard let data = try? fileSource.contents(of: url) else { continue }
                parser.consume(data)
            }
        }
        return UsageSnapshot(limits: parser.limits, records: parser.records)
    }

    @Sendable static func isRollout(_ name: String) -> Bool {
        name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
    }
}
