import Foundation
import Darwin
import Testing
@testable import TokenGlanceCore

/// Real short-lived `/bin/sh` and `/usr/bin/perl` children; no network and no user files.
struct StdioChildTests {
    private static func alive(_ pid: Int32) -> Bool { Darwin.kill(pid, 0) == 0 }

    @Test func lastLineWithoutNewlineIsKeptAtEOF() async throws {
        let child = CodexProcessTransport(executableURL: URL(fileURLWithPath: "/bin/sh"),
                                          arguments: ["-c", "printf 'first\\nlast'"])
        try child.start()
        #expect(try await child.readLine() == Data("first".utf8))
        #expect(try await child.readLine() == Data("last".utf8))
        #expect(try await child.readLine() == nil)
        child.close()
    }

    @Test func manySmallLinesAreReadInFullUntilEOF() async throws {
        let codex = CodexProcessTransport(executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
                                          arguments: ["-e", "$|=1; print \"$_\\n\" for 1..2000;"])
        try codex.start()
        var count = 0
        while let line = try await codex.readLine() {
            count += 1
            #expect(line == Data(String(count).utf8))
        }
        #expect(count == 2000)
        codex.close()
    }

    @Test func queuedCompleteLinesAreCappedToo() async throws {
        let queue = LineQueue(limit: 8)
        // Each line is short, but together they exceed the cap while nobody reads.
        for _ in 0..<5 { queue.append(Data("abc\n".utf8)) }
        await #expect(throws: CodexAppServerFailure.invalidResponse) { try await queue.next() }
        // After the failure nothing more is buffered.
        queue.append(Data("x\n".utf8))
        await #expect(throws: CodexAppServerFailure.invalidResponse) { try await queue.next() }
    }

    @Test func cancelDropsBufferedOutput() async throws {
        let queue = LineQueue(limit: 64)
        queue.append(Data("a\nb".utf8))
        queue.cancel()
        #expect(try await queue.next() == nil)
    }

    @Test func closeWaitsForTheChildAndKillsItsProcessGroup() async throws {
        // Both the child and its background grandchild ignore SIGTERM, like a stuck CLI wrapper.
        let child = CodexProcessTransport(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; sleep 30 & echo $$ $!; wait"],
            grace: 0.3)
        try child.start()
        let line = try #require(try await child.readLine())
        let pids = String(decoding: line, as: UTF8.self).split(separator: " ").compactMap { Int32($0) }
        try #require(pids.count == 2)
        child.close()
        await child.waitUntilExited()
        #expect(!Self.alive(pids[0]))
        #expect(!Self.alive(pids[1]))
    }

    @Test func claudeClientStopWaitsForTheChild() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("tg-stdio-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = "trap '' TERM; echo $$ > '\(pidFile.path)'; sleep 30"
        let client = ClaudeUsageClient(transportFactory: {
            ClaudeProcessTransport(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], grace: 0.3)
        }, timeout: 30)
        let read = Task { await client.readLimits() }
        var pid: Int32?
        for _ in 0..<100 where pid == nil {
            try await Task.sleep(for: .milliseconds(20))
            pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        let child = try #require(pid)
        await client.stop()
        #expect(!Self.alive(child))
        #expect(await read.value == .failure(.disconnected))
    }

    @Test func codexClientStopWaitsForTheChild() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("tg-stdio-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = "trap '' TERM; echo $$ > '\(pidFile.path)'; sleep 30"
        let client = CodexAppServerClient(transportFactory: {
            CodexProcessTransport(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], grace: 0.3)
        }, timeout: 30)
        let read = Task { await client.readLimits() }
        var pid: Int32?
        for _ in 0..<100 where pid == nil {
            try await Task.sleep(for: .milliseconds(20))
            pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        let child = try #require(pid)
        await client.stop()
        #expect(!Self.alive(child))
        #expect(await read.value == .failure(.disconnected))
    }
}
