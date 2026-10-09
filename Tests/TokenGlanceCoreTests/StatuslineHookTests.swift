import Foundation
import Testing
@testable import TokenGlanceCore

/// A temporary support directory plus helpers to run the hook pipeline and capture child output.
struct HookSandbox {
    let paths: TokenGlancePaths
    let now = Fixtures.t0 + 600

    init() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tg-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        paths = TokenGlancePaths(supportDirectory: dir)
    }

    func cleanup() { try? FileManager.default.removeItem(at: paths.supportDirectory) }

    func chain(_ command: String?) throws {
        try StatuslineBackup(originalCommand: command, originalStatusLineJSON: nil, installedCommand: "hook").write(to: paths.statuslineBackup)
    }

    /// Runs the hook with `input`; returns (exit code, child stdout).
    func run(_ input: Data) throws -> (Int32, String) {
        let output = Pipe()
        let code = StatuslineHook(paths: paths, now: { now }).run(input: input, stdout: output.fileHandleForWriting.fileDescriptor)
        try output.fileHandleForWriting.close()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (code, text)
    }

    var cache: ClaudeRateLimitCache? {
        (try? Data(contentsOf: paths.rateLimitCache)).flatMap { try? ClaudeRateLimitCache.decode($0) }
    }
}

@Suite(.serialized) struct StatuslineHookTests {
    @Test func writesCacheThenChainsOriginalCommand() throws {
        let box = try HookSandbox(); defer { box.cleanup() }
        try box.chain(#"echo "hud: $(cat | wc -c | tr -d ' ')""#)
        let input = try Fixtures.data("claude-statusline-stdin-sample.json")
        let (code, out) = try box.run(input)
        #expect(code == 0)
        #expect(out == "hud: \(input.count)\n")
        #expect(box.cache?.fiveHour?.usedPercentage == 38)
        #expect(box.cache?.sevenDay?.observedAt == box.now)
    }

    @Test func childReceivesInputBytesUnchanged() throws {
        let box = try HookSandbox(); defer { box.cleanup() }
        let copy = box.paths.supportDirectory.appendingPathComponent("received.bin")
        try box.chain("cat > '\(copy.path)'")
        // odd spacing, key order and unicode must survive (no re-serialization)
        let input = Data("{ \"z\":1,   \"a\" : \"\u{D55C}\\u00e9\", \"rate_limits\":{\"five_hour\":{\"used_percentage\":7,\"resets_at\":1791433200}} }\n".utf8)
        _ = try box.run(input)
        #expect(try Data(contentsOf: copy) == input)
    }

    @Test func cacheIsWrittenBeforeChildStarts() throws {
        let box = try HookSandbox(); defer { box.cleanup() }
        try box.chain("test -f '\(box.paths.rateLimitCache.path)' && echo cached || echo missing")
        let (_, out) = try box.run(Fixtures.data("claude-statusline-stdin-sample.json"))
        #expect(out == "cached\n")
    }

    @Test func missingOrNullRateLimitsStillChainsAndKeepsCache() throws {
        let box = try HookSandbox(); defer { box.cleanup() }
        try box.chain("echo ok")
        _ = try box.run(Fixtures.data("claude-statusline-stdin-sample.json"))
        let before = try Data(contentsOf: box.paths.rateLimitCache)
        #expect(try box.run(Fixtures.data("claude-statusline-stdin-no-rate-limits.synthetic.json")) == (0, "ok\n"))
        #expect(try box.run(Data(#"{"rate_limits":null}"#.utf8)) == (0, "ok\n"))
        #expect(try Data(contentsOf: box.paths.rateLimitCache) == before)
    }

    @Test func singleWindowUpdatesOnlyThatWindow() throws {
        let box = try HookSandbox(); defer { box.cleanup() }
        _ = try box.run(Fixtures.data("claude-statusline-stdin-sample.json"))
        _ = try box.run(Data(#"{"rate_limits":{"seven_day":{"used_percentage":13,"resets_at":1791788400}}}"#.utf8))
        #expect(box.cache?.fiveHour?.usedPercentage == 38)
        #expect(box.cache?.sevenDay?.usedPercentage == 13)
    }

    @Test func brokenInputStillChainsAndLeavesCacheIntact() throws {
        let box = try HookSandbox(); defer { box.cleanup() }
        try box.chain("cat")
        _ = try box.run(Fixtures.data("claude-statusline-stdin-sample.json"))
        let before = try Data(contentsOf: box.paths.rateLimitCache)
        #expect(try box.run(Data("{broken".utf8)) == (0, "{broken"))
        #expect(try box.run(Data()) == (0, ""))
        #expect(try Data(contentsOf: box.paths.rateLimitCache) == before)
    }

    @Test func unwritableCacheDirectoryStillChains() throws {
        let box = try HookSandbox(); defer { box.cleanup() }
        try box.chain("echo ok")
        // a directory where the cache file should be makes the rename fail
        try FileManager.default.createDirectory(at: box.paths.rateLimitCache, withIntermediateDirectories: true)
        #expect(try box.run(Fixtures.data("claude-statusline-stdin-sample.json")) == (0, "ok\n"))
    }

    @Test func largeInputIsHandled() throws {
        let box = try HookSandbox(); defer { box.cleanup() }
        try box.chain("wc -c | tr -d ' '")
        var object = try #require(try JSONSerialization.jsonObject(with: Fixtures.data("claude-statusline-stdin-sample.json")) as? [String: Any])
        object["padding"] = String(repeating: "x", count: 2_000_000)
        let input = try JSONSerialization.data(withJSONObject: object)
        let (code, out) = try box.run(input)
        #expect(code == 0)
        #expect(out == "\(input.count)\n")
        #expect(box.cache?.fiveHour?.usedPercentage == 38)
    }

    @Test func childExitCodeIsPropagated() throws {
        let box = try HookSandbox(); defer { box.cleanup() }
        try box.chain("cat >/dev/null; exit 7")
        #expect(try box.run(Data("{}".utf8)).0 == 7)
        try box.chain("kill -TERM $$")
        #expect(try box.run(Data("{}".utf8)).0 == 128 + SIGTERM)
    }

    @Test func childThatIgnoresStdinDoesNotHangOrCrash() throws {
        let box = try HookSandbox(); defer { box.cleanup() }
        try box.chain("echo done")  // never reads stdin
        let big = Data(repeating: UInt8(ascii: "a"), count: 1_000_000)
        #expect(try box.run(big) == (0, "done\n"))
        try box.chain("head -c 3")  // reads a little, then exits
        #expect(try box.run(big) == (0, "aaa"))
    }

    @Test func childLeadsItsOwnProcessGroup() throws {
        // Signals are forwarded to the whole group, so grandchildren of compound commands stop too.
        let box = try HookSandbox(); defer { box.cleanup() }
        try box.chain(#"test "$(ps -o pgid= -p $$ | tr -d ' ')" = "$$" && echo leader || echo member"#)
        #expect(try box.run(Data("{}".utf8)) == (0, "leader\n"))
    }

    @Test func environmentIsInherited() throws {
        let box = try HookSandbox(); defer { box.cleanup() }
        setenv("TG_HOOK_TEST_VAR", "inherited", 1)
        defer { unsetenv("TG_HOOK_TEST_VAR") }
        try box.chain(#"echo "$TG_HOOK_TEST_VAR""#)
        #expect(try box.run(Data("{}".utf8)) == (0, "inherited\n"))
    }

    @Test func shellSyntaxInOriginalCommandIsPreserved() throws {
        let box = try HookSandbox(); defer { box.cleanup() }
        setenv("TG_HOOK_TEST_HOME", "/expanded", 1)
        defer { unsetenv("TG_HOOK_TEST_HOME") }
        try box.chain(#"echo ${TG_HOOK_UNSET_VAR:-$TG_HOOK_TEST_HOME}/hud"#)
        #expect(try box.run(Data("{}".utf8)) == (0, "/expanded/hud\n"))
    }

    @Test func noChainTargetExitsCleanlyWithoutOutput() throws {
        let box = try HookSandbox(); defer { box.cleanup() }
        #expect(try box.run(Fixtures.data("claude-statusline-stdin-sample.json")) == (0, ""))
        #expect(box.cache != nil)
        try box.chain(nil)
        #expect(try box.run(Data("{}".utf8)) == (0, ""))
        try box.chain("   ")
        #expect(try box.run(Data("{}".utf8)) == (0, ""))
    }

    @Test func unreadableBackupBehavesLikeNoChain() throws {
        let box = try HookSandbox(); defer { box.cleanup() }
        try Data("{oops".utf8).write(to: box.paths.statuslineBackup)
        #expect(try box.run(Data("{}".utf8)) == (0, ""))
    }
}
