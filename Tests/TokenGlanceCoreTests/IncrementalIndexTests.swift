import Foundation
import Testing
@testable import TokenGlanceCore

/// Deterministic RNG so property tests are reproducible.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A mutable in-memory file tree for driving incremental readers.
struct MemoryTree {
    var source = InMemoryFileSource(files: [:])
    let root: String

    init(root: String) { self.root = root }

    mutating func set(_ relative: String, _ data: Data, inode: UInt64? = nil) {
        let path = root + "/" + relative
        source.files[path] = data
        if let inode { source.inodes[path] = inode }
    }

    mutating func remove(_ relative: String) { source.files[root + "/" + relative] = nil }

    func list(_ suffix: String = ".jsonl") -> [URL] {
        source.files(under: URL(fileURLWithPath: root)) { $0.hasSuffix(suffix) }
    }
}

func fullClaude(_ tree: MemoryTree) -> [UsageRecord] {
    var parser = ClaudeLogParser()
    for url in tree.list() { parser.consume(try! tree.source.contents(of: url)) }
    return parser.records
}

/// Claude fixture plus extra lines that duplicate keys with different output across files.
func claudeCorpus() throws -> Data {
    var data = try Fixtures.data("claude-usage-sample.jsonl")
    data.append(Data((ClaudeParserTests.line(id: "msg_X", req: "req_X", output: 3) + "\n"
        + ClaudeParserTests.line(id: "msg_X", req: "req_X", output: 9, ts: "2026-10-08T01:00:05.000Z") + "\n").utf8))
    return data
}

struct ClaudeIncrementalTests {
    @Test(arguments: 0..<40)
    func randomAppendSplitsMatchFullParse(seed: UInt64) throws {
        var rng = SplitMix64(state: seed)
        let corpus = try claudeCorpus()
        var tree = MemoryTree(root: "/p")
        var index = ClaudeUsageIndex()
        var cut = 0
        while cut < corpus.count {
            cut = min(corpus.count, cut + Int.random(in: 1...400, using: &rng))
            tree.set("a/s.jsonl", corpus.prefix(cut))
            index.update(files: tree.list(), source: tree.source)
        }
        #expect(index.records == fullClaude(tree))
        #expect(index.records.reduce(TokenUsage.zero) { $0 + $1.usage }.output == 794 + 9)
    }

    @Test func incompleteLastLineWaitsForNewline() throws {
        var tree = MemoryTree(root: "/p")
        var index = ClaudeUsageIndex()
        let line = ClaudeParserTests.line(id: "msg_A", req: "req_A", output: 5)
        tree.set("s.jsonl", Data(line.utf8))  // no newline yet
        index.update(files: tree.list(), source: tree.source)
        #expect(index.records.isEmpty)
        tree.set("s.jsonl", Data((line + "\n").utf8))
        index.update(files: tree.list(), source: tree.source)
        #expect(index.records.map(\.usage.output) == [5])
    }

    @Test func onlyNewBytesAreRead() throws {
        var tree = MemoryTree(root: "/p")
        var index = ClaudeUsageIndex()
        let first = Data((ClaudeParserTests.line(id: "msg_A", req: "req_A", output: 5) + "\n").utf8)
        tree.set("s.jsonl", first)
        var changed = index.update(files: tree.list(), source: tree.source)
        #expect(changed)
        #expect(index.bytesRead == first.count)
        changed = index.update(files: tree.list(), source: tree.source)
        #expect(!changed)  // nothing changed
        #expect(index.bytesRead == first.count)
        let second = Data((ClaudeParserTests.line(id: "msg_B", req: "req_B", output: 7) + "\n").utf8)
        tree.set("s.jsonl", first + second)
        changed = index.update(files: tree.list(), source: tree.source)
        #expect(changed)
        #expect(index.bytesRead == first.count + second.count)
        #expect(index.records.map(\.usage.output).sorted() == [5, 7])
    }

    @Test func truncatedOrReplacedFileIsReadAgainFromStart() throws {
        var tree = MemoryTree(root: "/p")
        var index = ClaudeUsageIndex()
        let a = ClaudeParserTests.line(id: "msg_A", req: "req_A", output: 50) + "\n"
        let b = ClaudeParserTests.line(id: "msg_B", req: "req_B", output: 2) + "\n"
        tree.set("s.jsonl", Data((a + b).utf8), inode: 1)
        index.update(files: tree.list(), source: tree.source)

        tree.set("s.jsonl", Data(b.utf8), inode: 1)  // truncated: smaller than offset
        index.update(files: tree.list(), source: tree.source)
        #expect(index.records == fullClaude(tree))
        #expect(index.records.map(\.usage.output) == [2])

        // same size, different inode (rotated / replaced)
        let c = ClaudeParserTests.line(id: "msg_C", req: "req_C", output: 3) + "\n"
        tree.set("s.jsonl", Data(c.utf8), inode: 2)
        index.update(files: tree.list(), source: tree.source)
        #expect(index.records.map(\.usage.output) == [3])
    }

    @Test func deletedNewAndSubagentFiles() throws {
        var tree = MemoryTree(root: "/p")
        var index = ClaudeUsageIndex()
        tree.set("proj/s.jsonl", try Fixtures.data("claude-usage-sample.jsonl"))
        index.update(files: tree.list(), source: tree.source)
        #expect(index.records.count == 4)

        tree.set("proj/s/subagents/agent.jsonl", Data((ClaudeParserTests.line(id: "msg_S", req: "req_S", output: 11) + "\n").utf8))
        tree.set("other/new.jsonl", Data((ClaudeParserTests.line(id: "msg_N", req: "req_N", output: 12) + "\n").utf8))
        index.update(files: tree.list(), source: tree.source)
        #expect(index.records.count == 6)
        #expect(index.records == fullClaude(tree))

        tree.remove("proj/s.jsonl")
        index.update(files: tree.list(), source: tree.source)
        #expect(index.records.map(\.usage.output).sorted() == [11, 12])
        #expect(index.records == fullClaude(tree))
    }

    @Test func crossFileDuplicateKeepsMaxAndFallsBackWhenMaxFileDisappears() throws {
        var tree = MemoryTree(root: "/p")
        var index = ClaudeUsageIndex()
        tree.set("a.jsonl", Data((ClaudeParserTests.line(id: "msg_D", req: "req_D", output: 4) + "\n").utf8))
        tree.set("b.jsonl", Data((ClaudeParserTests.line(id: "msg_D", req: "req_D", output: 8) + "\n").utf8))
        index.update(files: tree.list(), source: tree.source)
        #expect(index.records.map(\.usage.output) == [8])
        tree.remove("b.jsonl")
        index.update(files: tree.list(), source: tree.source)
        #expect(index.records.map(\.usage.output) == [4])
    }

    @Test func pruningDropsOldEntriesOnly() throws {
        var tree = MemoryTree(root: "/p")
        var index = ClaudeUsageIndex()
        tree.set("s.jsonl", try Fixtures.data("claude-usage-sample.jsonl"))
        index.update(files: tree.list(), source: tree.source)
        // fixture records are at T0 + 0m, 5m, 10m, 20m
        index.prune(before: Fixtures.t0 + 7 * 60)
        #expect(index.records.count == 2)
        #expect(index.records.allSatisfy { $0.timestamp >= Fixtures.t0 + 7 * 60 })
    }
}

struct CodexIncrementalTests {
    func fullCodex(_ tree: MemoryTree) -> (records: [UsageRecord], limits: [LimitWindow]) {
        var parser = CodexRolloutParser()
        for url in tree.list() { parser.consume(try! tree.source.contents(of: url)) }
        return (parser.records, parser.limits)
    }

    @Test(arguments: 0..<40)
    func randomAppendSplitsMatchFullParse(seed: UInt64) throws {
        var rng = SplitMix64(state: seed)
        let sample = try Fixtures.data("codex-token-count-sample.jsonl")
        let edge = try Fixtures.data("codex-edge-cases.synthetic.jsonl")
        var tree = MemoryTree(root: "/c")
        var index = CodexUsageIndex()
        var cuts = (0, 0)
        while cuts.0 < sample.count || cuts.1 < edge.count {
            cuts.0 = min(sample.count, cuts.0 + Int.random(in: 1...300, using: &rng))
            cuts.1 = min(edge.count, cuts.1 + Int.random(in: 1...300, using: &rng))
            tree.set("2026/10/08/rollout-a.jsonl", sample.prefix(cuts.0))
            tree.set("2026/10/08/rollout-b.jsonl", edge.prefix(cuts.1))
            index.update(files: tree.list(), source: tree.source)
        }
        let full = fullCodex(tree)
        #expect(index.records == full.records)
        #expect(index.limits == full.limits)
        #expect(index.records.reduce(TokenUsage.zero) { $0 + $1.usage } == TokenUsage(input: 8300, output: 1730, cacheRead: 18500, reasoning: 450))
    }

    /// A session file that appears after the first sync and then grows in partial chunks ends up
    /// identical to a full parse (the new-session path that previously waited for the slow poll).
    @Test(arguments: 0..<20)
    func sessionCreatedAfterFirstSyncMatchesFullParse(seed: UInt64) throws {
        var rng = SplitMix64(state: seed)
        let first = try Fixtures.data("codex-token-count-sample.jsonl")
        let second = try Fixtures.data("codex-edge-cases.synthetic.jsonl")
        var tree = MemoryTree(root: "/c")
        var index = CodexUsageIndex()
        tree.set("2026/10/08/rollout-a.jsonl", first)
        index.update(files: tree.list(), source: tree.source)
        var cut = 0
        while cut < second.count {
            cut = min(second.count, cut + Int.random(in: 1...250, using: &rng))
            tree.set("2026/10/09/rollout-b.jsonl", second.prefix(cut))  // new date folder, new session
            index.update(files: tree.list(), source: tree.source)
        }
        let full = fullCodex(tree)
        #expect(index.records == full.records)
        #expect(index.limits == full.limits)
    }

    @Test func rotatedSessionFileIsReparsedAndDeletedFileDropsItsData() throws {
        var tree = MemoryTree(root: "/c")
        var index = CodexUsageIndex()
        tree.set("rollout-a.jsonl", try Fixtures.data("codex-token-count-sample.jsonl"), inode: 1)
        tree.set("rollout-b.jsonl", try Fixtures.data("codex-edge-cases.synthetic.jsonl"), inode: 2)
        index.update(files: tree.list(), source: tree.source)
        #expect(index.limits.first { $0.kind == .session }?.usedPercent == 31.0)

        tree.remove("rollout-b.jsonl")
        index.update(files: tree.list(), source: tree.source)
        #expect(index.limits.first { $0.kind == .session }?.usedPercent == 20.5)
        #expect(index.records.count == 3)

        tree.set("rollout-a.jsonl", try Fixtures.data("codex-token-count-sample.jsonl"), inode: 9)
        index.update(files: tree.list(), source: tree.source)
        #expect(index.records == fullCodex(tree).records)
    }

    @Test func pruningKeepsCumulativeBaseline() throws {
        var tree = MemoryTree(root: "/c")
        var index = CodexUsageIndex()
        let sample = try Fixtures.data("codex-token-count-sample.jsonl")
        // feed only the first event, prune it, then let the rest arrive: deltas must not double count
        let lines = sample.split(separator: UInt8(ascii: "\n"))
        let firstEventEnd = lines.prefix(6).reduce(0) { $0 + $1.count + 1 }
        tree.set("rollout-a.jsonl", sample.prefix(firstEventEnd))
        index.update(files: tree.list(), source: tree.source)
        #expect(index.records.count == 1)
        index.prune(before: Fixtures.t0 + 3 * 60)
        #expect(index.records.isEmpty)
        tree.set("rollout-a.jsonl", sample)
        index.update(files: tree.list(), source: tree.source)
        #expect(index.records.reduce(TokenUsage.zero) { $0 + $1.usage }.output == 1550 - 400)
    }
}
