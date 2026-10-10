import Foundation

/// What `CodexOnlineLimitsController` needs from the App Server client.
public protocol CodexLimitsReading: Sendable {
    func readLimits(enabled: Bool) async -> Result<CodexAccountLimits, CodexAppServerFailure>
    func stop() async
}

extension CodexAppServerClient: CodexLimitsReading {}

/// The opt-in lifecycle of online Codex limit reads: nothing starts while the option is off, at
/// most one read runs at a time, and turning the option back on waits for a pending stop to finish
/// so two App Server children never overlap.
@MainActor
public final class CodexOnlineLimitsController {
    private let reader: any CodexLimitsReading
    private let isEnabled: @MainActor () -> Bool
    private let onResult: @MainActor (Result<CodexAccountLimits, CodexAppServerFailure>) -> Void
    private var readTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var generation = 0

    public init(
        reader: any CodexLimitsReading,
        isEnabled: @escaping @MainActor () -> Bool,
        onResult: @escaping @MainActor (Result<CodexAccountLimits, CodexAppServerFailure>) -> Void
    ) {
        self.reader = reader
        self.isEnabled = isEnabled
        self.onResult = onResult
    }

    /// True when no read or stop is running.
    public var isIdle: Bool { readTask == nil && stopTask == nil }

    /// Starts a read if the option is on and nothing is running; otherwise does nothing.
    public func refresh() {
        guard isEnabled(), readTask == nil, stopTask == nil else { return }
        let current = generation
        let reader = reader
        readTask = Task { [weak self] in
            let result = await reader.readLimits(enabled: true)
            guard let self, current == self.generation else { return }
            self.readTask = nil
            guard !Task.isCancelled, self.isEnabled() else { return }
            self.onResult(result)
        }
    }

    /// Call after the option was turned off (or Codex disabled): cancels the read and stops the
    /// App Server. If the option is on again by the time the stop finishes, a new read starts.
    public func disable() {
        generation += 1
        readTask?.cancel()
        readTask = nil
        let previous = stopTask
        let stopped = generation
        let reader = reader
        stopTask = Task { [weak self] in
            await previous?.value
            await reader.stop()
            guard let self, self.generation == stopped else { return }
            self.stopTask = nil
            self.refresh()
        }
    }

    /// App shutdown: stops everything and waits for the App Server to be closed.
    public func shutdown() async {
        generation += 1
        readTask?.cancel()
        readTask = nil
        await stopTask?.value
        stopTask = nil
        await reader.stop()
    }
}
