import Foundation

/// Starts the installed `claude` headless for one control request over stdio. Claude Code reads
/// its own login; this app never opens the Keychain item or credentials file.
public final class ClaudeProcessTransport: ClaudeControlTransport, @unchecked Sendable {
    /// No prompt is sent, so no model request is made. Nothing is saved as a session, and the
    /// user's hooks, plugins and MCP servers do not run.
    static let arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                            "--no-session-persistence", "--safe-mode", "--strict-mcp-config"]
    /// Telemetry, error reporting and update checks are off. `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`
    /// is not set: it also stops the usage read.
    static let quietEnvironment = ["DISABLE_TELEMETRY": "1", "DISABLE_ERROR_REPORTING": "1", "DISABLE_AUTOUPDATER": "1"]

    private let executableURL: URL?
    private let configDir: URL?
    private let arguments: [String]
    private let child: StdioChild

    /// `configDir` is the Claude folder override from settings (passed as `CLAUDE_CONFIG_DIR`).
    /// `arguments` and `grace` (time to exit after SIGTERM before a kill) are replaced only in tests.
    public init(executableURL: URL? = nil, configDir: URL? = nil, arguments: [String]? = nil, grace: TimeInterval = 2) {
        self.executableURL = executableURL
        self.configDir = configDir
        self.arguments = arguments ?? Self.arguments
        child = StdioChild(lineLimit: 4_194_304, overflow: ClaudeUsageFailure.invalidResponse, grace: grace)
    }

    public func start() throws {
        guard let executable = executableURL ?? Self.findClaudeExecutable() else {
            throw ClaudeUsageFailure.executableUnavailable
        }
        // Process errors can contain local paths. Expose only the safe category.
        try child.start(executable: executable, arguments: arguments,
                        environment: Self.childEnvironment(executable: executable, configDir: configDir),
                        directory: FileManager.default.temporaryDirectory,
                        launchFailure: ClaudeUsageFailure.launchFailed)
    }

    public func write(_ data: Data) throws { try child.write(data) }
    public func readLine() async throws -> Data? { try await child.readLine() }
    public func exitStatus() async -> Int32? { await child.exitStatus() }
    public func close() { child.close() }
    public func waitUntilExited() async { await child.waitUntilExited() }

    private static var searchDirectories: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["\(home)/.local/bin", "\(home)/.claude/local", "\(home)/.npm-global/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    }

    private static func findClaudeExecutable() -> URL? {
        searchDirectories.lazy.map { URL(fileURLWithPath: $0).appendingPathComponent("claude") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Apps launched from Finder inherit launchd's short PATH; an npm-installed `claude` needs `node`
    /// from the directory it was found in.
    static func childEnvironment(executable: URL, configDir: URL?,
                                 base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        var seen = Set<String>()
        let path = ([executable.deletingLastPathComponent().path] + searchDirectories + ["/usr/bin", "/bin"])
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        environment["PATH"] = path.joined(separator: ":")
        environment.merge(quietEnvironment) { _, quiet in quiet }
        if let configDir { environment["CLAUDE_CONFIG_DIR"] = configDir.path }
        return environment
    }
}
