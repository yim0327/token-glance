import Foundation

/// Uses only stdio; no listening socket or direct access to Codex credentials.
public final class CodexProcessTransport: CodexAppServerTransport, @unchecked Sendable {
    private let executableURL: URL?
    private let arguments: [String]
    private let child: StdioChild

    /// `grace` is how long the child may take to exit after SIGTERM before it is killed.
    public init(executableURL: URL? = nil, arguments: [String] = ["app-server"], grace: TimeInterval = 2) {
        self.executableURL = executableURL
        self.arguments = arguments
        child = StdioChild(lineLimit: 1_048_576, overflow: CodexAppServerFailure.invalidResponse, grace: grace)
    }

    public func start() throws {
        guard let executable = executableURL ?? Self.findCodexExecutable() else {
            throw CodexAppServerFailure.executableUnavailable
        }
        // Process errors can contain local paths. Expose only the safe category.
        try child.start(executable: executable, arguments: arguments,
                        environment: Self.childEnvironment(executable: executable),
                        launchFailure: CodexAppServerFailure.launchFailed)
    }

    public func write(_ data: Data) throws { try child.write(data) }
    public func readLine() async throws -> Data? { try await child.readLine() }
    public func exitStatus() async -> Int32? { await child.exitStatus() }
    public func close() { child.close() }
    public func waitUntilExited() async { await child.waitUntilExited() }

    private static var searchDirectories: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["\(home)/.local/bin", "\(home)/.npm-global/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    }

    private static func findCodexExecutable() -> URL? {
        searchDirectories.lazy.map { URL(fileURLWithPath: $0).appendingPathComponent("codex") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Apps launched from Finder inherit launchd's short PATH. An npm-installed `codex` is a
    /// `#!/usr/bin/env node` script, so the child needs the directories it was found in.
    static func childEnvironment(executable: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        var seen = Set<String>()
        let path = ([executable.deletingLastPathComponent().path] + searchDirectories + ["/usr/bin", "/bin"])
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        environment["PATH"] = path.joined(separator: ":")
        return environment
    }
}
