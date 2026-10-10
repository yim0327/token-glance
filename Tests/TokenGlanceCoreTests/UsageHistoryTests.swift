import Foundation
import Testing
@testable import TokenGlanceCore

struct UsageHistoryTests {
    static func calendar(_ id: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: id)!
        return calendar
    }

    let utc = calendar("UTC")
    let seoul = calendar("Asia/Seoul")
    let now = Fixtures.t0 + 3600  // 2026-10-08 02:00 UTC / 11:00 KST

    func record(_ offset: TimeInterval, output: Int, input: Int = 0, reasoning: Int = 0) -> UsageRecord {
        UsageRecord(timestamp: Fixtures.t0 + offset, model: "m", usage: TokenUsage(input: input, output: output, reasoning: reasoning))
    }

    @Test func fourteenDaysEndingTodayInTheGivenCalendar() {
        let days = UsageHistory.daily(records: [], coverageStart: nil, now: now, calendar: utc)
        #expect(days.count == 14)
        #expect(days.last?.day == utc.startOfDay(for: now))
        #expect(days.first?.day == utc.date(byAdding: .day, value: -13, to: utc.startOfDay(for: now)))
        #expect(days.allSatisfy { $0.usage == nil })  // no logs at all
    }

    @Test func confirmedZeroIsDistinctFromNoLogs() {
        let start = utc.date(byAdding: .day, value: -3, to: utc.startOfDay(for: now))!
        let days = UsageHistory.daily(records: [record(0, output: 5)], coverageStart: start + 3600, now: now, calendar: utc)
        #expect(days.prefix(10).allSatisfy { $0.usage == nil })               // before the oldest log
        #expect(days[10].usage == .zero && days[11].usage == .zero && days[12].usage == .zero)  // logs, no usage
        #expect(days[13].usage == TokenUsage(output: 5))
    }

    @Test func dayBoundariesFollowTheTimeZone() {
        // T0 - 2h = 2026-10-07 23:00 UTC = 2026-10-08 08:00 KST
        let records = [record(-2 * 3600, output: 1), record(0, output: 10)]
        let longAgo = Fixtures.t0 - 30 * 86_400
        let inUTC = UsageHistory.daily(records: records, coverageStart: longAgo, now: now, calendar: utc)
        #expect(inUTC[12].usage?.output == 1 && inUTC[13].usage?.output == 10)
        let inSeoul = UsageHistory.daily(records: records, coverageStart: longAgo, now: now, calendar: seoul)
        #expect(inSeoul[12].usage?.output == 0 && inSeoul[13].usage?.output == 11)
    }

    @Test func rangeIsInclusiveOfTheFirstDayAndExcludesEarlierRecords() {
        let first = utc.date(byAdding: .day, value: -13, to: utc.startOfDay(for: now))!
        let records = [
            UsageRecord(timestamp: first, model: "m", usage: TokenUsage(output: 7)),
            UsageRecord(timestamp: first - 1, model: "m", usage: TokenUsage(output: 100)),
        ]
        let days = UsageHistory.daily(records: records, coverageStart: first - 86_400, now: now, calendar: utc)
        #expect(days[0].usage?.output == 7)
        #expect(days.compactMap(\.usage).reduce(0) { $0 + $1.output } == 7)
    }

    @Test func totalsKeepNormalizationAndDoNotAddReasoningTwice() {
        let days = UsageHistory.daily(records: [record(0, output: 10, input: 3, reasoning: 4)], coverageStart: Fixtures.t0 - 86_400, now: now, calendar: utc)
        let today = days[13].usage!
        #expect(today == TokenUsage(input: 3, output: 10, reasoning: 4))
        #expect(today.total == 13)
    }

    @Test func retentionCoversTheChartRange() {
        #expect(UsageHistory.retention >= TimeInterval(UsageHistory.dayCount + 1) * 86_400)
    }
}

/// Daily results from incrementally maintained indexes equal those of a full parse, including after
/// pruning at the retention boundary, cross-file dedupe updates, and file removal.
struct UsageHistoryIncrementalTests {
    let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    let now = Fixtures.t0 + 3600

    @Test(arguments: 0..<15)
    func claudeIncrementalDailyMatchesFullParse(seed: UInt64) throws {
        var rng = SplitMix64(state: seed)
        let corpus = try claudeCorpus()
        var tree = MemoryTree(root: "/p")
        var index = ClaudeUsageIndex()
        var cut = 0
        while cut < corpus.count {
            cut = min(corpus.count, cut + Int.random(in: 1...500, using: &rng))
            tree.set("a/s.jsonl", corpus.prefix(cut))
            index.update(files: tree.list(), source: tree.source)
        }
        let start = Fixtures.t0 - 86_400
        #expect(UsageHistory.daily(records: index.records, coverageStart: start, now: now, calendar: utc)
            == UsageHistory.daily(records: fullClaude(tree), coverageStart: start, now: now, calendar: utc))
    }

    @Test func dedupeUpdateAcrossFilesAndRemovalAreReflected() {
        var tree = MemoryTree(root: "/p")
        var index = ClaudeUsageIndex()
        tree.set("a.jsonl", Data((ClaudeParserTests.line(id: "msg_D", req: "req_D", output: 4) + "\n").utf8))
        index.update(files: tree.list(), source: tree.source)
        func today() -> Int? { UsageHistory.daily(records: index.records, coverageStart: Fixtures.t0 - 86_400, now: now, calendar: utc)[13].usage?.output }
        #expect(today() == 4)
        tree.set("b.jsonl", Data((ClaudeParserTests.line(id: "msg_D", req: "req_D", output: 9) + "\n").utf8))
        index.update(files: tree.list(), source: tree.source)
        #expect(today() == 9)  // same message, higher output in another file: counted once, at the max
        tree.remove("b.jsonl")
        index.update(files: tree.list(), source: tree.source)
        #expect(today() == 4)
        tree.set("a.jsonl", Data((ClaudeParserTests.line(id: "msg_E", req: "req_E", output: 2) + "\n").utf8), inode: 7)  // replaced
        index.update(files: tree.list(), source: tree.source)
        #expect(today() == 2)
    }

    @Test func pruningAtRetentionKeepsTheChartIdentical() {
        // records spread over the last 20 days
        var lines = ""
        for day in 0..<20 {
            let ts = ISO8601DateFormatter().string(from: Fixtures.t0 - TimeInterval(day) * 86_400)
            lines += ClaudeParserTests.line(id: "msg_\(day)", req: "req_\(day)", output: day + 1, ts: ts) + "\n"
        }
        var tree = MemoryTree(root: "/p")
        tree.set("s.jsonl", Data(lines.utf8))
        var index = ClaudeUsageIndex()
        index.update(files: tree.list(), source: tree.source)
        let before = UsageHistory.daily(records: index.records, coverageStart: Fixtures.t0 - 30 * 86_400, now: now, calendar: utc)
        index.prune(before: now - UsageHistory.retention)
        let after = UsageHistory.daily(records: index.records, coverageStart: Fixtures.t0 - 30 * 86_400, now: now, calendar: utc)
        #expect(after == before)
        #expect(after.compactMap(\.usage).count == 14)
    }

    @Test func codexIncrementalDailyMatchesFullParse() throws {
        var tree = MemoryTree(root: "/c")
        var index = CodexUsageIndex()
        let sample = try Fixtures.data("codex-token-count-sample.jsonl")
        for cut in stride(from: 1, through: sample.count, by: 97) + [sample.count] {
            tree.set("rollout-a.jsonl", sample.prefix(cut))
            index.update(files: tree.list(), source: tree.source)
        }
        var full = CodexRolloutParser()
        full.consume(sample)
        let start = Fixtures.t0 - 86_400
        #expect(UsageHistory.daily(records: index.records, coverageStart: start, now: now, calendar: utc)
            == UsageHistory.daily(records: full.records, coverageStart: start, now: now, calendar: utc))
    }
}
