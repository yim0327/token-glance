import Foundation
import Testing
@testable import TokenGlanceCore

struct StatuslineCacheReaderTests {
    static let cachePath = "/support/claude-rate-limits.json"
    let observed = Fixtures.t0 + 600

    func reader(_ data: Data?) -> ClaudeStatuslineCache {
        let files = data.map { [Self.cachePath: $0] } ?? [:]
        return ClaudeStatuslineCache(fileURL: URL(fileURLWithPath: Self.cachePath), fileSource: InMemoryFileSource(files: files))
    }

    func cacheData(_ fixture: String = "claude-statusline-stdin-sample.json") throws -> Data {
        try #require(try ClaudeRateLimitCache.updated(nil, with: Fixtures.data(fixture), at: observed)).encoded()
    }

    @Test func readsBothWindowsFromHookCache() throws {
        let reading = reader(try cacheData()).read(now: observed + 60)
        #expect(reading == .available([
            LimitWindow(kind: .session, usedPercent: 38, resetsAt: Date(timeIntervalSince1970: 1_791_433_200), observedAt: observed),
            LimitWindow(kind: .weekly, usedPercent: 12, resetsAt: Date(timeIntervalSince1970: 1_791_788_400), observedAt: observed),
        ]))
    }

    @Test func missingCorruptAndUnsupportedAreDistinguished() {
        #expect(reader(nil).read(now: observed) == .unavailable(.noData))
        #expect(reader(Data("{oops".utf8)).read(now: observed) == .unavailable(.corrupt))
        #expect(reader(Data(#"{"schema_version":99,"five_hour":{"x":1}}"#.utf8)).read(now: observed) == .unavailable(.unsupportedVersion))
        #expect(reader(Data(#"{"schema_version":1}"#.utf8)).read(now: observed) == .unavailable(.noData))
    }

    @Test func dataOlderThanAWeekIsStale() throws {
        let data = try cacheData()
        #expect(reader(data).read(now: observed + 7 * 86_400 - 1).windows?.count == 2)
        #expect(reader(data).read(now: observed + 7 * 86_400 + 1) == .unavailable(.stale))
    }

    @Test func providerExposesCachedLimitsAndResetHandling() throws {
        var files = try Fixtures.source(root: "/claude/projects", ["-p/s.jsonl": "claude-usage-sample.jsonl"]).files
        files[Self.cachePath] = try cacheData()
        let source = InMemoryFileSource(files: files)
        let cache = ClaudeStatuslineCache(fileURL: URL(fileURLWithPath: Self.cachePath), fileSource: source)

        let early = ClaudeUsageProvider(projectsRoot: URL(fileURLWithPath: "/claude/projects"), fileSource: source,
                                        rateLimitCache: cache, now: { observed + 60 }).snapshot()
        #expect(early.limits.map(\.usedPercent) == [38, 12])
        #expect(early.limitsIssue == nil)
        #expect(early.records.count == 4)

        // After the 5h reset time the session window reads as reset (0%), weekly stays.
        let afterReset = Date(timeIntervalSince1970: 1_791_433_200)
        let snap = ClaudeUsageProvider(projectsRoot: URL(fileURLWithPath: "/claude/projects"), fileSource: source,
                                       rateLimitCache: cache, now: { afterReset }).snapshot()
        let statuses = UsageAggregator(calendar: Calendar(identifier: .gregorian)).limitStatuses(snap.limits, now: afterReset)
        #expect(statuses.map(\.usedPercent) == [0, 12])
        #expect(statuses.map(\.isReset) == [true, false])
        // the weekly window drives the week interval
        #expect(UsageAggregator().weekInterval(weekly: snap.limit(.weekly), now: afterReset).end == Date(timeIntervalSince1970: 1_791_788_400))
    }

    @Test func providerReportsWhyLimitsAreMissing() throws {
        let source = InMemoryFileSource(files: [:])
        let cache = ClaudeStatuslineCache(fileURL: URL(fileURLWithPath: Self.cachePath), fileSource: source)
        let snap = ClaudeUsageProvider(projectsRoot: URL(fileURLWithPath: "/claude/projects"), fileSource: source,
                                       rateLimitCache: cache, now: { observed }).snapshot()
        #expect(snap.limits.isEmpty)
        #expect(snap.limitsIssue == .noData)
    }

    @Test func codexProviderReportsNoDataWithoutRollouts() {
        let snap = CodexUsageProvider(codexHome: URL(fileURLWithPath: "/codex"), fileSource: InMemoryFileSource(files: [:])).snapshot()
        #expect(snap.limitsIssue == .noData)
    }
}
