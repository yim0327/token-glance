import Foundation
import Darwin

/// A child process spoken to with newline-delimited messages over stdin/stdout. Shared by the
/// Codex App Server and Claude Code transports.
///
/// - stdout is read until EOF; a last line without a newline is kept. The read end is closed by the
///   reader itself after EOF, never while a read may still be running.
/// - Buffered output is capped (`lineLimit` bytes, complete and partial lines together); going over
///   fails the reader with `overflow` and drops what was buffered.
/// - `close()` sends SIGTERM to the child's process group (Foundation starts each child as its own
///   group leader, so wrapper scripts and their children are included), then SIGKILL after `grace`.
///   `waitUntilExited()` returns once that is done.
final class StdioChild: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lines: LineQueue
    private let grace: TimeInterval
    private let lock = NSLock()
    private var closed = false
    private var reaper: Task<Void, Never>?

    init(lineLimit: Int, overflow: any Error, grace: TimeInterval) {
        lines = LineQueue(limit: lineLimit, overflow: overflow)
        self.grace = grace
    }

    /// Throws `launchFailure` (a category without local paths) when the child cannot start.
    func start(executable: URL, arguments: [String], environment: [String: String],
               directory: URL? = nil, launchFailure: any Error) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let directory { process.currentDirectoryURL = directory }
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
                try? handle.close()
            } else {
                lines.append(data)
            }
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            lines.finish()
            try? output.fileHandleForReading.close()
            throw launchFailure
        }
        // A child that exits before reading must not kill the app with SIGPIPE; writes throw EPIPE instead.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    func write(_ data: Data) throws {
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func readLine() async throws -> Data? {
        try await lines.next()
    }

    /// The child's exit status once it has exited, waiting briefly after EOF for it to be reaped.
    func exitStatus() async -> Int32? {
        for _ in 0..<50 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return process.isRunning ? nil : process.terminationStatus
    }

    /// Stops reading, closes the child's stdin and ends the child and its process group. Returns at
    /// once; see `waitUntilExited()`.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        lines.cancel()
        try? input.fileHandleForWriting.close()
        guard process.processIdentifier > 0 else { return }
        let child = process
        let pid = child.processIdentifier
        // Signal the group only when the child leads its own; never the app's group.
        let group = getpgid(pid) == pid && pid != getpgrp() ? pid : nil
        func signal(_ number: Int32) {
            if let group { _ = Darwin.kill(-group, number) } else if child.isRunning { _ = Darwin.kill(pid, number) }
        }
        signal(SIGTERM)
        let grace = grace
        reaper = Task.detached(priority: .utility) {
            let deadline = Date().addingTimeInterval(grace)
            while child.isRunning && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            // Also reaches grandchildren that ignored SIGTERM after the leader exited.
            signal(SIGKILL)
            for _ in 0..<100 where child.isRunning {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    /// Returns after `close()` has ended the child (at most `grace` plus a short kill wait).
    func waitUntilExited() async {
        await currentReaper()?.value
    }

    private func currentReaper() -> Task<Void, Never>? {
        lock.withLock { reaper }
    }
}

/// Splits stdout chunks into newline-terminated lines for a single reader.
final class LineQueue: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private let overflow: any Error
    private var buffer = Data()
    private var lines: [Data] = []
    /// Bytes in `lines`; `buffer` holds the partial line.
    private var queuedBytes = 0
    private var failure: Error?
    private var finished = false
    private var waiter: CheckedContinuation<Data?, Error>?

    init(limit: Int, overflow: any Error = CodexAppServerFailure.invalidResponse) {
        self.limit = limit
        self.overflow = overflow
    }

    func append(_ data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            lines.append(line)
            queuedBytes += line.count
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        if queuedBytes + buffer.count > limit {
            failure = overflow
            finished = true
            dropBuffered()
        }
        resumeLocked()
    }

    /// End of output: a last line without a newline is still delivered.
    func finish() {
        lock.lock()
        if !finished && !buffer.isEmpty {
            lines.append(buffer)
            queuedBytes += buffer.count
            buffer = Data()
        }
        finished = true
        resumeLocked()
    }

    /// The reader is no longer interested: buffered output is dropped and `next()` returns nil.
    func cancel() {
        lock.lock()
        finished = true
        dropBuffered()
        resumeLocked()
    }

    func next() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            waiter = continuation
            resumeLocked()
        }
    }

    private func dropBuffered() {
        buffer = Data()
        lines = []
        queuedBytes = 0
    }

    /// Called with the lock held; releases it.
    private func resumeLocked() {
        guard let waiter else { lock.unlock(); return }
        if !lines.isEmpty {
            let line = lines.removeFirst()
            queuedBytes -= line.count
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
