import Foundation
import Darwin

/// Uses only stdio; no listening socket or direct access to Codex credentials.
public final class CodexProcessTransport: CodexAppServerTransport, @unchecked Sendable {
    private let executableURL: URL?
    private let arguments: [String]
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var closed = false

    public init(executableURL: URL? = nil, arguments: [String] = ["app-server"]) {
        self.executableURL = executableURL
        self.arguments = arguments
    }

    public func start() throws {
        guard let executable = executableURL ?? Self.findCodexExecutable() else {
            throw CodexAppServerFailure.executableUnavailable
        }
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    public func write(_ data: Data) throws {
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    public func readLine() async throws -> Data? {
        try await Task.detached { [output] in
            var line = Data()
            while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
                if byte[0] == 0x0A { return line }
                line.append(byte)
                if line.count > 1_048_576 { throw CodexAppServerFailure.invalidResponse }
            }
            return nil
        }.value
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
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

    private static func findCodexExecutable() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["\(home)/.local/bin", "\(home)/.npm-global/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        return candidates.lazy.map { URL(fileURLWithPath: $0).appendingPathComponent("codex") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
