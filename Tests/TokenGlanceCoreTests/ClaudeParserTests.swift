import Foundation
import Testing
@testable import TokenGlanceCore

struct ClaudeParserTests {
    let root = "/claude/projects"

    func snapshot(_ layout: [String: String]) throws -> UsageSnapshot {
        let source = try Fixtures.source(root: root, layout)
        return ClaudeUsageProvider(projectsRoot: URL(fileURLWithPath: root), fileSource: source).snapshot()
    }

    func total(_ records: [UsageRecord]) -> TokenUsage {
        records.reduce(.zero) { $0 + $1.usage }
    }

    @Test func fixtureTotalsMatchDocumentedExpectations() throws {
        let snap = try snapshot(["-proj/session.jsonl": "claude-usage-sample.jsonl"])
        #expect(snap.records.count == 4)
        #expect(total(snap.records) == TokenUsage(input: 21, output: 794, cacheRead: 58000, cacheWrite: 3500, reasoning: 120))
        // Limits come from the hook cache, which this in-memory source does not contain.
        #expect(snap.limits.isEmpty)
    }

    @Test func perModelTotals() throws {
        let snap = try snapshot(["-proj/session.jsonl": "claude-usage-sample.jsonl"])
        let byModel = Dictionary(grouping: snap.records, by: \.model).mapValues(total)
        #expect(byModel == [
            "claude-sonnet-5": TokenUsage(input: 8, output: 184, cacheRead: 35000, cacheWrite: 2000),
            "claude-opus-5-5": TokenUsage(input: 3, output: 410, cacheRead: 18000, cacheWrite: 500, reasoning: 120),
            "claude-haiku-4-5-20251001": TokenUsage(input: 10, output: 200, cacheRead: 5000, cacheWrite: 1000),
        ])
    }

    @Test func streamingDuplicateUsesFinalLineTimestamp() throws {
        let snap = try snapshot(["-proj/session.jsonl": "claude-usage-sample.jsonl"])
        let opus = try #require(snap.records.first { $0.model == "claude-opus-5-5" })
        #expect(opus.timestamp == Fixtures.t0 + 5 * 60 + 4)
    }

    @Test func dedupeIsGlobalAcrossFilesIncludingSubagents() throws {
        let snap = try snapshot([
            "-proj/session.jsonl": "claude-usage-sample.jsonl",
            "-proj/session/subagents/agent.jsonl": "claude-usage-sample.jsonl",
            "-other/resumed.jsonl": "claude-usage-sample.jsonl",
        ])
        #expect(snap.records.count == 4)
        #expect(total(snap.records).output == 794)
    }

    @Test func ignoresFilesOutsideRootAndNonJSONL() throws {
        var files = try Fixtures.source(root: root, ["-proj/session.jsonl": "claude-usage-sample.jsonl"]).files
        files["/elsewhere/x.jsonl"] = try Fixtures.data("claude-usage-sample.jsonl")
        files[root + "/-proj/notes.json"] = try Fixtures.data("claude-usage-sample.jsonl")
        let provider = ClaudeUsageProvider(projectsRoot: URL(fileURLWithPath: root), fileSource: InMemoryFileSource(files: files))
        #expect(provider.snapshot().records.count == 4)
    }

    @Test func maxOutputWinsRegardlessOfLineOrder() {
        var parser = ClaudeLogParser()
        parser.consume(Data("""
        \(Self.line(id: "msg_A", req: "req_A", output: 50, ts: "2026-10-08T01:00:02.000Z"))
        \(Self.line(id: "msg_A", req: "req_A", output: 10, ts: "2026-10-08T01:00:01.000Z"))
        """.utf8))
        #expect(parser.records.map(\.usage.output) == [50])
    }

    @Test func missingRequestIdFallsBackToMessageId() {
        var parser = ClaudeLogParser()
        parser.consume(Data("""
        \(Self.line(id: "msg_B", req: nil, output: 5))
        \(Self.line(id: "msg_B", req: nil, output: 7))
        \(Self.line(id: "msg_B", req: "req_B", output: 3))
        """.utf8))
        // (msg_B, nil) and (msg_B, req_B) are different keys.
        #expect(parser.records.map(\.usage.output).sorted() == [3, 7])
    }

    @Test func malformedAndIncompleteLinesAreSkipped() {
        var parser = ClaudeLogParser()
        parser.consume(Data("""
        {not json
        {"type":"assistant","timestamp":"2026-10-08T01:00:00.000Z","message":{"model":"m","usage":{"output_tokens":1}}}
        {"type":"assistant","message":{"id":"msg_C","model":"m","usage":{"output_tokens":1}}}
        {"type":"assistant","timestamp":"2026-10-08T01:00:00.000Z","message":{"id":"msg_D","model":"m"}}
        {"type":"user","timestamp":"2026-10-08T01:00:00.000Z","message":{"id":"msg_E","usage":{"output_tokens":9}}}
        \(Self.line(id: "msg_F", req: "req_F", output: 2))
        """.utf8))
        // only msg_F has id + timestamp + usage on an assistant line
        #expect(parser.records.map(\.usage.output) == [2])
    }

    @Test func defaultRootHonorsClaudeConfigDir() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(ClaudeUsageProvider.defaultProjectsRoot(environment: [:], home: home).path == "/Users/someone/.claude/projects")
        #expect(ClaudeUsageProvider.defaultProjectsRoot(environment: ["CLAUDE_CONFIG_DIR": "/cfg"], home: home).path == "/cfg/projects")
        #expect(ClaudeUsageProvider.defaultProjectsRoot(environment: ["CLAUDE_CONFIG_DIR": ""], home: home).path == "/Users/someone/.claude/projects")
    }

    static func line(id: String, req: String?, output: Int, ts: String = "2026-10-08T01:00:00.000Z") -> String {
        let reqField = req.map { #","requestId":"\#($0)""# } ?? ""
        return #"{"type":"assistant","timestamp":"\#(ts)"\#(reqField),"message":{"id":"\#(id)","model":"m","usage":{"input_tokens":1,"output_tokens":\#(output),"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
    }
}
