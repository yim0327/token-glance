import Foundation
import Testing
@testable import TokenGlanceCore

struct RateLimitCacheTests {
    let now = Fixtures.t0 + 600

    func input(_ json: String) -> Data { Data(json.utf8) }

    @Test func extractsBothWindowsFromStatuslineInput() throws {
        let cache = try #require(try ClaudeRateLimitCache.updated(nil, with: Fixtures.data("claude-statusline-stdin-sample.json"), at: now))
        #expect(cache.schemaVersion == 1)
        #expect(cache.claudeVersion == "2.1.295")
        #expect(cache.fiveHour == .init(usedPercentage: 38, resetsAt: 1_791_433_200, observedAt: now))
        #expect(cache.sevenDay == .init(usedPercentage: 12, resetsAt: 1_791_788_400, observedAt: now))
    }

    @Test func inputWithoutRateLimitsProducesNoUpdate() throws {
        #expect(try ClaudeRateLimitCache.updated(nil, with: Fixtures.data("claude-statusline-stdin-no-rate-limits.synthetic.json"), at: now) == nil)
        #expect(try ClaudeRateLimitCache.updated(nil, with: input(#"{"rate_limits":null}"#), at: now) == nil)
        #expect(try ClaudeRateLimitCache.updated(nil, with: input(#"{"rate_limits":{}}"#), at: now) == nil)
    }

    @Test func windowsUpdateIndependently() throws {
        let first = try #require(try ClaudeRateLimitCache.updated(nil, with: Fixtures.data("claude-statusline-stdin-sample.json"), at: now))
        let later = now + 60
        let second = try #require(try ClaudeRateLimitCache.updated(first, with: input(
            #"{"version":"2.1.300","rate_limits":{"five_hour":{"used_percentage":40.5,"resets_at":1791433200}}}"#
        ), at: later))
        #expect(second.fiveHour == .init(usedPercentage: 40.5, resetsAt: 1_791_433_200, observedAt: later))
        #expect(second.sevenDay == first.sevenDay)  // kept, with its original observed_at
        #expect(second.claudeVersion == "2.1.300")
    }

    @Test func incompleteWindowIsIgnored() throws {
        let cache = try ClaudeRateLimitCache.updated(nil, with: input(
            #"{"rate_limits":{"five_hour":{"used_percentage":10},"seven_day":{"used_percentage":5,"resets_at":"1791788400"}}}"#
        ), at: now)
        #expect(cache?.fiveHour == nil)
        #expect(cache?.sevenDay == .init(usedPercentage: 5, resetsAt: 1_791_788_400, observedAt: now))
    }

    @Test func millisecondResetTimesAreNormalizedToSeconds() throws {
        let cache = try ClaudeRateLimitCache.updated(nil, with: input(
            #"{"rate_limits":{"five_hour":{"used_percentage":1,"resets_at":1791433200000}}}"#
        ), at: now)
        #expect(cache?.fiveHour?.resetsAt == 1_791_433_200)
    }

    @Test func malformedInputThrows() {
        #expect(throws: (any Error).self) { try ClaudeRateLimitCache.updated(nil, with: Data("{not json".utf8), at: now) }
    }

    @Test func encodedCacheContainsOnlyAllowedKeys() throws {
        let cache = try #require(try ClaudeRateLimitCache.updated(nil, with: Fixtures.data("claude-statusline-stdin-sample.json"), at: now))
        let object = try #require(try JSONSerialization.jsonObject(with: cache.encoded()) as? [String: Any])
        #expect(Set(object.keys) == ["schema_version", "claude_version", "five_hour", "seven_day"])
        let window = try #require(object["five_hour"] as? [String: Any])
        #expect(Set(window.keys) == ["used_percentage", "resets_at", "observed_at"])
        #expect(window["observed_at"] as? String == "2026-10-08T01:10:00Z")
        // nothing identifying from the statusline input leaks into the cache
        let text = String(decoding: try cache.encoded(), as: UTF8.self)
        for forbidden in ["session", "transcript", "cwd", "/Users/", "prompt", "workspace"] {
            #expect(!text.contains(forbidden))
        }
    }

    @Test func roundTripsThroughDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("nested/claude-rate-limits.json")
        let cache = try #require(try ClaudeRateLimitCache.updated(nil, with: Fixtures.data("claude-statusline-stdin-sample.json"), at: now))
        try AtomicFile.write(cache.encoded(), to: file)
        #expect(try ClaudeRateLimitCache.decode(Data(contentsOf: file)) == cache)
        // no temporary files left behind
        #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == ["claude-rate-limits.json"])
    }

    @Test func supportPathsHonorOverride() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let standard = TokenGlancePaths.default(environment: [:], home: home)
        #expect(standard.supportDirectory.path == "/Users/someone/Library/Application Support/TokenGlance")
        #expect(standard.rateLimitCache.lastPathComponent == "claude-rate-limits.json")
        #expect(standard.statuslineBackup.lastPathComponent == "statusline-backup.json")
        #expect(standard.hookBinary.path.hasSuffix("TokenGlance/bin/token-glance-hook"))
        #expect(TokenGlancePaths.default(environment: ["TOKEN_GLANCE_SUPPORT_DIR": "/tmp/x"], home: home).supportDirectory.path == "/tmp/x")
    }
}
