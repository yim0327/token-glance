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
    private let lines = LineQueue(limit: 1_048_576)

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
        process.environment = Self.childEnvironment(executable: executable)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // Reads arrive on Foundation's dispatch source instead of blocking a Swift concurrency thread
        // for as long as the connection stays open.
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
            throw CodexAppServerFailure.launchFailed
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

    /// The child's exit status once it has exited, waiting briefly after EOF for it to be reaped.
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

/// Splits stdout chunks into newline-terminated lines for a single reader.
final class LineQueue: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var buffer = Data()
    private var lines: [Data] = []
    private var failure: Error?
    private var finished = false
    private var waiter: CheckedContinuation<Data?, Error>?

    init(limit: Int) { self.limit = limit }

    func append(_ data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(Data(buffer[buffer.startIndex..<newline]))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        if buffer.count > limit {
            failure = CodexAppServerFailure.invalidResponse
            finished = true
        }
        resumeLocked()
    }

    func finish() {
        lock.lock()
        finished = true
        resumeLocked()
    }

    func next() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            waiter = continuation
            resumeLocked()
        }
    }

    /// Called with the lock held; releases it.
    private func resumeLocked() {
        guard let waiter else { lock.unlock(); return }
        if !lines.isEmpty {
            let line = lines.removeFirst()
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: line)
        } else if let failure {
            self.waiter = nil
            lock.unlock()
            waiter.resume(throwing: failure)
        } else if finished {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: nil)
        } else {
            lock.unlock()
        }
    }
}
