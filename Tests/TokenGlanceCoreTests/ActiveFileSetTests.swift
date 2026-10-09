import Foundation
import Testing
@testable import TokenGlanceCore

struct ActiveFileSetTests {
    let t0 = Fixtures.t0
    func url(_ name: String) -> URL { URL(fileURLWithPath: "/c/sessions/\(name)") }

    @Test func newestFileIsAlwaysWatchedEvenWhenIdle() {
        var set = ActiveFileSet(window: 15 * 60)
        set.update(sizes: [url("a.jsonl"): 10, url("b.jsonl"): 20], now: t0)
        // nothing has grown yet: watch only the most recently seen-growing (here: last listed by path) file
        set.update(sizes: [url("a.jsonl"): 10, url("b.jsonl"): 25], now: t0 + 60)
        #expect(set.active == [url("b.jsonl")])
        // an hour later with no growth, the last file that grew is still watched (it may be resumed)
        set.update(sizes: [url("a.jsonl"): 10, url("b.jsonl"): 25], now: t0 + 3600)
        #expect(set.active == [url("b.jsonl")])
    }

    @Test func recentlyGrowingFilesAreActiveAndOldOnesDropOut() {
        var set = ActiveFileSet(window: 15 * 60)
        set.update(sizes: [url("a.jsonl"): 1, url("b.jsonl"): 1], now: t0)
        set.update(sizes: [url("a.jsonl"): 2, url("b.jsonl"): 2], now: t0 + 10)
        #expect(Set(set.active) == [url("a.jsonl"), url("b.jsonl")])
        set.update(sizes: [url("a.jsonl"): 3, url("b.jsonl"): 2], now: t0 + 20 * 60)
        #expect(set.active == [url("a.jsonl")])
    }

    @Test func detectsGrowthOfActiveFilesOnly() {
        var source = InMemoryFileSource(files: ["/c/sessions/a.jsonl": Data("x".utf8), "/c/sessions/b.jsonl": Data("y".utf8)])
        var set = ActiveFileSet(window: 15 * 60)
        set.update(sizes: [url("a.jsonl"): 1, url("b.jsonl"): 1], now: t0)
        set.update(sizes: [url("a.jsonl"): 1, url("b.jsonl"): 1], now: t0 + 1)
        #expect(!set.hasChanges(source: source))

        source.files["/c/sessions/b.jsonl"] = Data("yy".utf8)  // the active (newest) file grows
        #expect(set.hasChanges(source: source))

        // a file outside the active set changing is left to FSEvents / the slow poll
        var other = ActiveFileSet(window: 15 * 60)
        other.update(sizes: [url("a.jsonl"): 1, url("b.jsonl"): 2], now: t0)
        other.update(sizes: [url("a.jsonl"): 1, url("b.jsonl"): 3], now: t0 + 1)
        source.files["/c/sessions/a.jsonl"] = Data("xx".utf8)
        source.files["/c/sessions/b.jsonl"] = Data("yyy".utf8)
        #expect(other.active == [url("b.jsonl")])
        #expect(!other.hasChanges(source: source))
    }

    @Test func removedOrReplacedFilesCountAsChanges() {
        var source = InMemoryFileSource(files: ["/c/sessions/a.jsonl": Data("x".utf8)])
        var set = ActiveFileSet(window: 15 * 60)
        set.update(sizes: [url("a.jsonl"): 1], now: t0)
        source.files["/c/sessions/a.jsonl"] = nil
        #expect(set.hasChanges(source: source))
    }

    @Test func emptySetNeverReportsChanges() {
        let set = ActiveFileSet(window: 60)
        #expect(set.active.isEmpty)
        #expect(!set.hasChanges(source: InMemoryFileSource(files: [:])))
    }
}
