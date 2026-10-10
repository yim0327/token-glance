import Foundation
import Testing
@testable import TokenGlanceCore

private actor FakeLimitsReader: CodexLimitsReading {
    private(set) var reads = 0
    private(set) var stops = 0
    private(set) var maxActive = 0
    private var active = 0
    private let readDelay: Duration
    private let stopDelay: Duration

    init(readDelay: Duration = .milliseconds(10), stopDelay: Duration = .zero) {
        self.readDelay = readDelay
        self.stopDelay = stopDelay
    }

    func readLimits(enabled: Bool) async -> Result<CodexAccountLimits, CodexAppServerFailure> {
        reads += 1
        active += 1
        maxActive = max(maxActive, active)
        try? await Task.sleep(for: readDelay)
        active -= 1
        return .success(CodexAccountLimits(accountIdentity: nil, buckets: [], observedAt: Date(timeIntervalSince1970: 0)))
    }

    func stop() async {
        stops += 1
        try? await Task.sleep(for: stopDelay)
    }
}

@MainActor
private final class Harness {
    var enabled = false
    var results = 0
    let reader: FakeLimitsReader
    private(set) var controller: CodexOnlineLimitsController!

    init(reader: FakeLimitsReader = FakeLimitsReader()) {
        self.reader = reader
        controller = CodexOnlineLimitsController(
            reader: reader,
            isEnabled: { [unowned self] in self.enabled },
            onResult: { [unowned self] _ in self.results += 1 })
    }

    func settle() async throws {
        for _ in 0..<400 where !controller.isIdle {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(controller.isIdle)
    }
}

@MainActor
struct CodexOnlineLimitsControllerTests {
    @Test func offNeverReads() async throws {
        let harness = Harness()
        harness.controller.refresh()
        harness.controller.refresh()
        try await harness.settle()
        #expect(await harness.reader.reads == 0)
        #expect(harness.results == 0)
    }

    @Test func offOnOffOnOffLifecycle() async throws {
        let harness = Harness()
        let controller = harness.controller!

        harness.enabled = true          // ON
        controller.refresh()
        try await harness.settle()
        #expect(await harness.reader.reads == 1)
        #expect(harness.results == 1)

        harness.enabled = false         // OFF
        controller.disable()
        controller.refresh()            // e.g. poll timer while off
        try await harness.settle()
        #expect(await harness.reader.reads == 1)
        #expect(await harness.reader.stops == 1)

        harness.enabled = true          // ON again
        controller.refresh()
        try await harness.settle()
        #expect(await harness.reader.reads == 2)

        harness.enabled = false         // OFF
        controller.disable()
        try await harness.settle()
        #expect(await harness.reader.stops == 2)
        #expect(await harness.reader.reads == 2)
        #expect(await harness.reader.maxActive == 1)
    }

    @Test func fastOffOnWaitsForStopThenReadsOnce() async throws {
        let harness = Harness(reader: FakeLimitsReader(stopDelay: .milliseconds(50)))
        let controller = harness.controller!
        harness.enabled = true
        controller.refresh()
        try await harness.settle()

        harness.enabled = false
        controller.disable()
        harness.enabled = true
        controller.refresh()            // ignored while the stop runs
        #expect(await harness.reader.reads == 1)
        try await harness.settle()
        #expect(await harness.reader.stops == 1)
        #expect(await harness.reader.reads == 2)  // restarted after the stop finished
    }

    @Test func fastOffOnOffEndsStopped() async throws {
        let harness = Harness(reader: FakeLimitsReader(stopDelay: .milliseconds(30)))
        let controller = harness.controller!
        harness.enabled = true
        controller.refresh()
        try await harness.settle()

        harness.enabled = false
        controller.disable()
        harness.enabled = true
        controller.refresh()
        harness.enabled = false
        controller.disable()
        try await harness.settle()
        #expect(await harness.reader.reads == 1)
        #expect(await harness.reader.stops == 2)
    }

    @Test func resultAfterDisableIsDropped() async throws {
        let harness = Harness(reader: FakeLimitsReader(readDelay: .milliseconds(50)))
        harness.enabled = true
        harness.controller.refresh()
        harness.controller.refresh()    // shares the running read
        harness.enabled = false
        harness.controller.disable()
        try await harness.settle()
        try await Task.sleep(for: .milliseconds(80))
        #expect(harness.results == 0)
        #expect(await harness.reader.reads <= 1)
    }

    @Test func shutdownStops() async throws {
        let harness = Harness()
        harness.enabled = true
        harness.controller.refresh()
        await harness.controller.shutdown()
        #expect(harness.controller.isIdle)
        #expect(await harness.reader.stops == 1)
    }

    @Test func refreshAfterShutdownIsIgnored() async throws {
        let harness = Harness()
        harness.enabled = true
        await harness.controller.shutdown()
        harness.controller.refresh()    // e.g. a wake or update notification during quit
        try await harness.settle()
        #expect(await harness.reader.reads == 0)
    }

    @Test func readCancelledBeforeStartingNeverReachesReader() async throws {
        let harness = Harness()
        harness.enabled = true
        harness.controller.refresh()
        harness.enabled = false
        harness.controller.disable()    // same main-actor turn: the read task has not run yet
        try await harness.settle()
        #expect(await harness.reader.reads == 0)
        #expect(await harness.reader.stops == 1)
    }
}
