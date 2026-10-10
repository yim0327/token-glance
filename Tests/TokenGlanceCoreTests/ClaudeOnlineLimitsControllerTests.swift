import Foundation
import Testing
@testable import TokenGlanceCore

private actor FakeClaudeReader: ClaudeLimitsReading {
    private(set) var reads = 0
    private(set) var stops = 0
    private(set) var maxActive = 0
    private var active = 0
    private var script: [Result<ClaudeAccountLimits, ClaudeUsageFailure>]
    private let readDelay: Duration

    init(script: [Result<ClaudeAccountLimits, ClaudeUsageFailure>] = [], readDelay: Duration = .milliseconds(10)) {
        self.script = script
        self.readDelay = readDelay
    }

    func readLimits() async -> Result<ClaudeAccountLimits, ClaudeUsageFailure> {
        reads += 1
        active += 1
        maxActive = max(maxActive, active)
        try? await Task.sleep(for: readDelay)
        active -= 1
        return script.isEmpty ? .success(ClaudeAccountLimits(windows: [], observedAt: Date(timeIntervalSince1970: 0)))
            : script.removeFirst()
    }

    func stop() async { stops += 1 }
}

@MainActor
private final class Harness {
    var enabled = false
    var clock = Date(timeIntervalSince1970: 1_000_000)
    var results: [Result<ClaudeAccountLimits, ClaudeUsageFailure>] = []
    let reader: FakeClaudeReader
    let sleeps = SleepLog()
    private(set) var controller: ClaudeOnlineLimitsController!

    init(reader: FakeClaudeReader = FakeClaudeReader(),
         backoff: ClaudeOnlineBackoff = ClaudeOnlineBackoff(base: 60, maximum: 480, startupRetries: [5, 15])) {
        self.reader = reader
        let sleeps = sleeps
        controller = ClaudeOnlineLimitsController(
            reader: reader,
            isEnabled: { [unowned self] in self.enabled },
            onResult: { [unowned self] in self.results.append($0) },
            now: { [unowned self] in self.clock },
            sleep: { sleeps.record($0) },
            backoff: backoff)
    }

    func settle() async throws {
        for _ in 0..<400 where !controller.isIdle {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(controller.isIdle)
    }
}

private final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var delays: [TimeInterval] = []
    func record(_ delay: TimeInterval) { lock.lock(); delays.append(delay); lock.unlock() }
    var values: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return delays }
}

private let failure: Result<ClaudeAccountLimits, ClaudeUsageFailure> = .failure(.unavailable)

@MainActor
struct ClaudeOnlineLimitsControllerTests {
    @Test func offNeverReadsOrStartsAnything() async throws {
        let harness = Harness()
        for trigger in [ClaudeOnlineLimitsController.Trigger.launch, .wake, .poll, .manual, .reset] {
            harness.controller.refresh(trigger)
        }
        try await harness.settle()
        #expect(await harness.reader.reads == 0)
        #expect(harness.results.isEmpty)
    }

    @Test func onReadsOnceEvenWhenRefreshedRepeatedly() async throws {
        let harness = Harness()
        harness.enabled = true
        harness.controller.refresh(.manual)
        harness.controller.refresh(.poll)
        harness.controller.refresh(.manual)
        try await harness.settle()
        #expect(await harness.reader.reads == 1)
        #expect(await harness.reader.maxActive == 1)
        #expect(harness.results.count == 1)
    }

    @Test func failuresBackOffExponentiallyAndSuccessResets() async throws {
        let harness = Harness(reader: FakeClaudeReader(script: [failure, .failure(.timeout), failure, failure, failure]))
        harness.enabled = true
        var expected: [TimeInterval] = []
        for _ in 0..<5 {
            harness.controller.refresh(.poll)
            try await harness.settle()
            let wait = try #require(harness.controller.nextAllowedAt).timeIntervalSince(harness.clock)
            expected.append(wait)
            // Too early: automatic triggers start nothing.
            harness.clock += wait - 1
            harness.controller.refresh(.poll)
            harness.controller.refresh(.reset)
            try await harness.settle()
            harness.clock += 1
        }
        #expect(expected == [60, 120, 240, 480, 480])
        #expect(await harness.reader.reads == 5)
        harness.controller.refresh(.poll)  // script exhausted: success
        try await harness.settle()
        #expect(harness.controller.nextAllowedAt == nil)
        #expect(harness.controller.consecutiveFailures == 0)
    }

    @Test func launchAndWakeRetryTransientFailuresBriefly() async throws {
        let harness = Harness(reader: FakeClaudeReader(script: [.failure(.disconnected), .failure(.timeout)]))
        harness.enabled = true
        harness.controller.refresh(.launch)
        try await harness.settle()
        #expect(await harness.reader.reads == 3)
        #expect(harness.sleeps.values == [5, 15])
        #expect(harness.results.count == 1)
        #expect((try? harness.results[0].get()) != nil)
    }

    @Test func pollAndPermanentFailuresDoNotRetryQuickly() async throws {
        let poll = Harness(reader: FakeClaudeReader(script: [failure]))
        poll.enabled = true
        poll.controller.refresh(.poll)
        try await poll.settle()
        #expect(await poll.reader.reads == 1)

        let permanent = Harness(reader: FakeClaudeReader(script: [.failure(.subscriptionRequired)]))
        permanent.enabled = true
        permanent.controller.refresh(.wake)
        try await permanent.settle()
        #expect(await permanent.reader.reads == 1)
        #expect(permanent.sleeps.values.isEmpty)
    }

    @Test func turningOffCancelsTheReadAndDropsItsResult() async throws {
        let harness = Harness(reader: FakeClaudeReader(readDelay: .milliseconds(200)))
        harness.enabled = true
        harness.controller.refresh(.manual)
        try await Task.sleep(for: .milliseconds(20))
        harness.enabled = false
        harness.controller.disable()
        try await harness.settle()
        try await Task.sleep(for: .milliseconds(250))
        #expect(await harness.reader.stops == 1)
        #expect(harness.results.isEmpty)
    }

    @Test func turningOffClearsBackoffSoReEnablingReadsAtOnce() async throws {
        let harness = Harness(reader: FakeClaudeReader(script: [failure]))
        harness.enabled = true
        harness.controller.refresh(.poll)
        try await harness.settle()
        #expect(harness.controller.nextAllowedAt != nil)
        harness.enabled = false
        harness.controller.disable()
        try await harness.settle()
        harness.enabled = true
        harness.controller.refresh(.poll)
        try await harness.settle()
        #expect(await harness.reader.reads == 2)
    }

    @Test func shutdownStopsAndIgnoresLaterRefreshes() async throws {
        let harness = Harness()
        harness.enabled = true
        await harness.controller.shutdown()
        harness.controller.refresh(.wake)
        try await harness.settle()
        #expect(await harness.reader.reads == 0)
        #expect(await harness.reader.stops == 1)
    }

    @Test func manualRefreshIsNotHeldBackByBackoff() async throws {
        let harness = Harness(reader: FakeClaudeReader(script: [failure]))
        harness.enabled = true
        harness.controller.refresh(.poll)
        try await harness.settle()
        #expect(harness.controller.nextAllowedAt != nil)
        harness.controller.refresh(.manual)
        try await harness.settle()
        #expect(await harness.reader.reads == 2)
    }

    @Test func launchFailuresAreNotRetriedQuickly() async throws {
        let harness = Harness(reader: FakeClaudeReader(script: [.failure(.launchFailed)]))
        harness.enabled = true
        harness.controller.refresh(.launch)
        try await harness.settle()
        #expect(await harness.reader.reads == 1)
    }

    @Test func backoffDelays() {
        let backoff = ClaudeOnlineBackoff()
        #expect(backoff.delay(afterFailures: 0) == 0)
        #expect(backoff.delay(afterFailures: 1) == 300)
        #expect(backoff.delay(afterFailures: 3) == 1200)
        #expect(backoff.delay(afterFailures: 100) == 1800)
    }
}
