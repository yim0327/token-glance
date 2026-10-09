import Foundation
import Testing
@testable import TokenGlanceCore

struct CodexParserTests {
    let home = "/codex"

    func snapshot(_ layout: [String: String]) throws -> UsageSnapshot {
        let source = try Fixtures.source(root: home, layout)
        return CodexUsageProvider(codexHome: URL(fileURLWithPath: home), fileSource: source).snapshot()
    }

    func total(_ records: [UsageRecord]) -> TokenUsage {
        records.reduce(.zero) { $0 + $1.usage }
    }

    static let sample = "sessions/2026/10/08/rollout-2026-10-08T10-00-00-00000000-0000-4000-b000-000000000001.jsonl"
    static let edge = "sessions/2026/10/08/rollout-2026-10-08T11-00-00-00000000-0000-4000-b000-000000000002.jsonl"

    @Test func sampleTokensAreNormalizedDeltas() throws {
        let snap = try snapshot([Self.sample: "codex-token-count-sample.jsonl"])
        #expect(snap.records.count == 3)
        // input excludes cached tokens (Codex reports them inside input_tokens)
        #expect(total(snap.records) == TokenUsage(input: 6500, output: 1550, cacheRead: 18500, cacheWrite: 0, reasoning: 450))
    }

    @Test func tokensAreAttributedToPrecedingTurnModel() throws {
        let snap = try snapshot([Self.sample: "codex-token-count-sample.jsonl"])
        let byModel = Dictionary(grouping: snap.records, by: \.model).mapValues(total)
        #expect(byModel == [
            "gpt-6-sol": TokenUsage(input: 6000, output: 1300, cacheRead: 15000, reasoning: 450),
            "gpt-6-astra": TokenUsage(input: 500, output: 250, cacheRead: 3500),
        ])
    }

    @Test func latestRateLimitsBecomeSessionAndWeeklyWindows() throws {
        let snap = try snapshot([Self.sample: "codex-token-count-sample.jsonl"])
        let observed = Fixtures.t0 + 6 * 60
        #expect(snap.limit(.session) == LimitWindow(kind: .session, usedPercent: 20.5,
                                                    resetsAt: Date(timeIntervalSince1970: 1_791_435_600), observedAt: observed))
        #expect(snap.limit(.weekly) == LimitWindow(kind: .weekly, usedPercent: 27.0,
                                                   resetsAt: Date(timeIntervalSince1970: 1_791_853_200), observedAt: observed))
    }

    @Test func edgeCasesNullInfoRepeatsDecreasesAndMalformedLines() throws {
        let snap = try snapshot([Self.edge: "codex-edge-cases.synthetic.jsonl"])
        // +1000/100, repeat +0 (dropped), decrease -> last +500/50, +300/30
        #expect(snap.records.map(\.usage.input) == [1000, 500, 300])
        #expect(total(snap.records) == TokenUsage(input: 1800, output: 180))
        // info:null still contributes limits; rate_limits:null is ignored
        #expect(snap.limit(.session)?.usedPercent == 31.0)
        #expect(snap.limit(.weekly)?.usedPercent == 28.5)
        #expect(snap.limit(.session)?.observedAt == Fixtures.t0 + 3600 + 120)
    }

    @Test func sessionsAreSummedAndNewestLimitsWinAcrossFiles() throws {
        let snap = try snapshot([
            Self.edge: "codex-edge-cases.synthetic.jsonl",
            Self.sample: "codex-token-count-sample.jsonl",
        ])
        #expect(total(snap.records) == TokenUsage(input: 8300, output: 1730, cacheRead: 18500, reasoning: 450))
        #expect(snap.limit(.session)?.usedPercent == 31.0)
        #expect(snap.records.map(\.timestamp) == snap.records.map(\.timestamp).sorted())
    }

    @Test func archivedSessionsAreIncludedAndOtherFilesIgnored() throws {
        let snap = try snapshot([
            "archived_sessions/rollout-2026-10-08T10-00-00-x.jsonl": "codex-token-count-sample.jsonl",
            "sessions/2026/10/08/other.jsonl": "codex-edge-cases.synthetic.jsonl",
        ])
        #expect(total(snap.records).output == 1550)
    }

    @Test func windowKindComesFromWindowMinutesNotSlotName() {
        var parser = CodexRolloutParser()
        parser.consume(Data(Self.tokenCount(primary: (10080, 70), secondary: (300, 5)).utf8))
        let limits = parser.limits
        #expect(limits.first { $0.kind == .weekly }?.usedPercent == 70)
        #expect(limits.first { $0.kind == .session }?.usedPercent == 5)
    }

    @Test func windowWithoutResetTimeIsOmitted() {
        var parser = CodexRolloutParser()
        parser.consume(Data(#"""
        {"timestamp":"2026-10-08T01:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":5,"window_minutes":300},"secondary":{"used_percent":7,"window_minutes":10080,"resets_at":1791853200}}}}
        """#.utf8))
        #expect(parser.limits.map(\.kind) == [.weekly])
        #expect(parser.limits.first?.usedPercent == 7)
    }

    @Test func classifiesUnusualWindowLengths() {
        #expect(CodexRolloutParser.kind(forWindowMinutes: 300) == .session)
        #expect(CodexRolloutParser.kind(forWindowMinutes: 10080) == .weekly)
        #expect(CodexRolloutParser.kind(forWindowMinutes: 60) == .session)
        #expect(CodexRolloutParser.kind(forWindowMinutes: 1440) == .session)
        #expect(CodexRolloutParser.kind(forWindowMinutes: 1441) == .weekly)
    }

    @Test func tokensWithoutTurnContextUseUnknownModel() {
        var parser = CodexRolloutParser()
        parser.consume(Data(#"""
        {"timestamp":"2026-10-08T01:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":4,"output_tokens":2,"reasoning_output_tokens":0,"total_tokens":12},"last_token_usage":{"input_tokens":10,"cached_input_tokens":4,"output_tokens":2,"reasoning_output_tokens":0,"total_tokens":12}},"rate_limits":null}}
        """#.utf8))
        #expect(parser.records == [UsageRecord(timestamp: Fixtures.t0, model: "unknown",
                                               usage: TokenUsage(input: 6, output: 2, cacheRead: 4))])
    }

    @Test func defaultHomeHonorsCodexHome() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(CodexUsageProvider.defaultCodexHome(environment: [:], home: home).path == "/Users/someone/.codex")
        #expect(CodexUsageProvider.defaultCodexHome(environment: ["CODEX_HOME": "/cx"], home: home).path == "/cx")
    }

    static func tokenCount(primary: (Int, Double), secondary: (Int, Double)) -> String {
        #"{"timestamp":"2026-10-08T01:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":\#(primary.1),"window_minutes":\#(primary.0),"resets_at":1791435600},"secondary":{"used_percent":\#(secondary.1),"window_minutes":\#(secondary.0),"resets_at":1791853200}}}}"#
    }
}
