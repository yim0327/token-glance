import Foundation

/// What `ClaudeOnlineLimitsController` needs from the usage client.
public protocol ClaudeLimitsReading: Sendable {
    func readLimits() async -> Result<ClaudeAccountLimits, ClaudeUsageFailure>
    func stop() async
}

extension ClaudeUsageClient: ClaudeLimitsReading {}

/// Delays between failed reads: doubling from `base` up to `maximum`, reset by a success. The base
/// equals the 5-minute poll, so even the first failure delays the next automatic read.
public struct ClaudeOnlineBackoff: Equatable, Sendable {
    public var base: TimeInterval = 300
    public var maximum: TimeInterval = 30 * 60
    /// Extra attempts right after launch or wake, when the network may not be up yet.
    public var startupRetries: [TimeInterval] = [5, 15]

    public init() {}

    public init(base: TimeInterval, maximum: TimeInterval, startupRetries: [TimeInterval]) {
        self.base = base
        self.maximum = maximum
        self.startupRetries = startupRetries
    }

    public func delay(afterFailures count: Int) -> TimeInterval {
        guard count > 0 else { return 0 }
        return min(maximum, base * pow(2, Double(min(count - 1, 30))))
    }
}

/// The opt-in lifecycle of online Claude limit reads: nothing starts while the option is off, at
/// most one read runs at a time, failures back off exponentially, and turning the option off
/// cancels a running read and its child process.
@MainActor
public final class ClaudeOnlineLimitsController {
    public enum Trigger: Sendable {
        case launch, wake, poll, manual, reset

        var retriesQuickly: Bool { self == .launch || self == .wake }
    }

    private let reader: any ClaudeLimitsReading
    private let isEnabled: @MainActor () -> Bool
    private let onResult: @MainActor (Result<ClaudeAccountLimits, ClaudeUsageFailure>) -> Void
    private let now: @MainActor () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let backoff: ClaudeOnlineBackoff
    private var readTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var generation = 0
    private var isShutDown = false
    public private(set) var consecutiveFailures = 0
    /// Reads are skipped until then after a failure.
    public private(set) var nextAllowedAt: Date?

    public init(
        reader: any ClaudeLimitsReading,
        isEnabled: @escaping @MainActor () -> Bool,
        onResult: @escaping @MainActor (Result<ClaudeAccountLimits, ClaudeUsageFailure>) -> Void,
        now: @escaping @MainActor () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        backoff: ClaudeOnlineBackoff = ClaudeOnlineBackoff()
    ) {
        self.reader = reader
        self.isEnabled = isEnabled
        self.onResult = onResult
        self.now = now
        self.sleep = sleep
        self.backoff = backoff
    }

    /// True when no read or stop is running.
    public var isIdle: Bool { readTask == nil && stopTask == nil }

    /// Starts a read if the option is on, nothing is running and no backoff is pending. The Refresh
    /// button (`.manual`) is the user's explicit request and is not held back by the backoff.
    public func refresh(_ trigger: Trigger = .poll) {
        guard !isShutDown, isEnabled(), readTask == nil, stopTask == nil else { return }
        if trigger != .manual, let nextAllowedAt, now() < nextAllowedAt { return }
        let current = generation
        let reader = reader
        let sleep = sleep
        let retries = trigger.retriesQuickly ? backoff.startupRetries : []
        readTask = Task { [weak self] in
            // A read cancelled before it reaches the client must not start a child.
            guard !Task.isCancelled else { return }
            var result = await reader.readLimits()
            for delay in retries {
                guard case .failure(let failure) = result, failure.isTransient else { break }
                do { try await sleep(delay) } catch { return }
                guard !Task.isCancelled else { return }
                result = await reader.readLimits()
            }
            guard let self, current == self.generation else { return }
            self.readTask = nil
            guard !Task.isCancelled, self.isEnabled() else { return }
            self.record(result)
            self.onResult(result)
        }
    }

    private func record(_ result: Result<ClaudeAccountLimits, ClaudeUsageFailure>) {
        switch result {
        case .success:
            consecutiveFailures = 0
            nextAllowedAt = nil
        case .failure:
            consecutiveFailures += 1
            nextAllowedAt = now().addingTimeInterval(backoff.delay(afterFailures: consecutiveFailures))
        }
    }

    /// Call after the option was turned off (or Claude disabled): cancels the read, stops its child
    /// and clears the backoff. If the option is on again by the time the stop finishes, a read starts.
    public func disable() {
        generation += 1
        readTask?.cancel()
        readTask = nil
        consecutiveFailures = 0
        nextAllowedAt = nil
        let previous = stopTask
        let stopped = generation
        let reader = reader
        stopTask = Task { [weak self] in
            await previous?.value
            await reader.stop()
            guard let self, self.generation == stopped else { return }
            self.stopTask = nil
            self.refresh(.poll)
        }
    }

    /// App shutdown: stops everything and waits for the child to be closed. Later refreshes are ignored.
    public func shutdown() async {
        isShutDown = true
        generation += 1
        readTask?.cancel()
        readTask = nil
        await stopTask?.value
        stopTask = nil
        await reader.stop()
    }
}
