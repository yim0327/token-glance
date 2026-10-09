import Foundation
import Testing
@testable import TokenGlanceCore

struct LimitWindowTests {
    let observed = Date(timeIntervalSince1970: 1_000_000)

    @Test func activeWindowReportsClampedPercent() {
        let window = LimitWindow(kind: .session, usedPercent: 38, resetsAt: observed + 3600, observedAt: observed)
        #expect(!window.isReset(at: observed))
        #expect(window.usedPercent(at: observed) == 38)
        #expect(window.remainingPercent(at: observed) == 62)

        let over = LimitWindow(kind: .session, usedPercent: 120, resetsAt: observed + 60, observedAt: observed)
        #expect(over.usedPercent(at: observed) == 100)
        let negative = LimitWindow(kind: .session, usedPercent: -5, resetsAt: observed + 60, observedAt: observed)
        #expect(negative.usedPercent(at: observed) == 0)
    }

    @Test func windowPastResetIsTreatedAsZeroUsed() {
        let window = LimitWindow(kind: .weekly, usedPercent: 90, resetsAt: observed + 60, observedAt: observed)
        #expect(window.isReset(at: observed + 60))
        #expect(window.usedPercent(at: observed + 61) == 0)
        #expect(window.remainingPercent(at: observed + 61) == 100)
    }

    @Test func windowStartDerivesFromKindDuration() {
        let reset = observed + 10_000
        #expect(LimitWindow(kind: .session, usedPercent: 0, resetsAt: reset, observedAt: observed).startsAt == reset - 18_000)
        #expect(LimitWindow(kind: .weekly, usedPercent: 0, resetsAt: reset, observedAt: observed).startsAt == reset - 604_800)
    }
}

struct TokenUsageTests {
    @Test func additionAndTotal() {
        let a = TokenUsage(input: 1, output: 2, cacheRead: 3, cacheWrite: 4, reasoning: 1)
        let b = TokenUsage(input: 10, output: 20, cacheRead: 30, cacheWrite: 40, reasoning: 5)
        var sum = a
        sum += b
        #expect(sum == TokenUsage(input: 11, output: 22, cacheRead: 33, cacheWrite: 44, reasoning: 6))
        // reasoning is part of output, so it is not added to the total again
        #expect(sum.total == 11 + 22 + 33 + 44)
        #expect(TokenUsage.zero.isZero)
    }
}

struct FileSourceTests {
    @Test func localSourceFindsNestedFilesAndSkipsOthers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("proj/session/subagents")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("proj/a.jsonl"))
        try Data("{}".utf8).write(to: nested.appendingPathComponent("b.jsonl"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("proj/notes.txt"))

        let found = LocalFileSource().files(under: root) { $0.hasSuffix(".jsonl") }
        #expect(found.map(\.lastPathComponent) == ["a.jsonl", "b.jsonl"])
        #expect(try LocalFileSource().contents(of: found[0]) == Data("{}".utf8))
    }

    @Test func localSourceWithMissingRootIsEmpty() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(LocalFileSource().files(under: missing) { _ in true }.isEmpty)
    }

    @Test func inMemorySourceFiltersByRootAndName() throws {
        let source = InMemoryFileSource(files: [
            "/r/x/a.jsonl": Data("1".utf8),
            "/r/b.txt": Data("2".utf8),
            "/other/c.jsonl": Data("3".utf8),
        ])
        let found = source.files(under: URL(fileURLWithPath: "/r")) { $0.hasSuffix(".jsonl") }
        #expect(found.map(\.path) == ["/r/x/a.jsonl"])
        #expect(try source.contents(of: found[0]) == Data("1".utf8))
        #expect(throws: (any Error).self) { try source.contents(of: URL(fileURLWithPath: "/r/missing")) }
    }
}

struct ParsingHelpersTests {
    @Test func jsonLinesSplitsAndDropsBlankLines() {
        let lines = JSONLines.lines(in: Data("{\"a\":1}\r\n\n{\"b\":2}\n".utf8))
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["{\"a\":1}", "{\"b\":2}"])
    }

    @Test func timestampParserHandlesFractionalAndPlain() {
        let parser = TimestampParser()
        #expect(parser.date(from: "2026-10-08T01:00:00.000Z") == Fixtures.t0)
        #expect(parser.date(from: "2026-10-08T01:00:00Z") == Fixtures.t0)
        #expect(parser.date(from: "not a date") == nil)
        #expect(parser.date(from: nil) == nil)
    }
}
