import Foundation
import Darwin

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
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var closed = false
    private let lines = LineQueue(limit: 4_194_304)

    /// `configDir` is the Claude folder override from settings (passed as `CLAUDE_CONFIG_DIR`).
    public init(executableURL: URL? = nil, configDir: URL? = nil) {
        self.executableURL = executableURL
        self.configDir = configDir
    }

    public func start() throws {
        guard let executable = executableURL ?? Self.findClaudeExecutable() else {
            throw ClaudeUsageFailure.executableUnavailable
        }
        process.executableURL = executable
        process.arguments = Self.arguments
        process.environment = Self.childEnvironment(executable: executable, configDir: configDir)
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let lines = lines
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                lines.finish()
            } else {
                lines.append(data)
            }
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            lines.finish()
            // Process errors can contain local paths. Expose only the safe category.
            throw ClaudeUsageFailure.launchFailed
        }
        // A child that exits before reading must not kill the app with SIGPIPE; writes throw EPIPE instead.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    public func write(_ data: Data) throws {
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    public func readLine() async throws -> Data? {
        try await lines.next()
    }

    public func exitStatus() async -> Int32? {
        for _ in 0..<50 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return process.isRunning ? nil : process.terminationStatus
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        output.fileHandleForReading.readabilityHandler = nil
        lines.finish()
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        if process.isRunning {
            process.terminate()
            let child = process
            DispatchQueue.global(qos: .utility).async {
                let deadline = Date().addingTimeInterval(2)
                while child.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
                child.waitUntilExit()
            }
        }
    }

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
