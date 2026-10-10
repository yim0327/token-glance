import Foundation

public protocol ClaudeControlTransport: AnyObject, Sendable {
    func start() throws
    func write(_ data: Data) throws
    func readLine() async throws -> Data?
    func close()
    /// Exit status after EOF, or nil when unknown or still running.
    func exitStatus() async -> Int32?
    /// Returns once a closed child has exited (or was killed).
    func waitUntilExited() async
}

extension ClaudeControlTransport {
    public func exitStatus() async -> Int32? { nil }
    public func waitUntilExited() async { }
}

/// Reads the plan limits through Claude Code's `get_usage` control request: one short-lived child
/// per read, closed as soon as the answer (or a timeout) arrives. Overlapping calls share one read.
/// The caller owns the opt-in, schedule and backoff.
public actor ClaudeUsageClient {
    static let initializeID = "token-glance-initialize"
    static let usageID = "token-glance-usage"

    private let transportFactory: @Sendable () throws -> any ClaudeControlTransport
    private let now: @Sendable () -> Date
    private let timeout: TimeInterval
    private var transport: (any ClaudeControlTransport)?
    /// The last child started, so `stop()` can wait for it to exit even after its read finished.
    private var lastConnection: (any ClaudeControlTransport)?
    private var generation = 0
    private var timedOutGeneration: Int?
    private var inFlight: Task<Result<ClaudeAccountLimits, ClaudeUsageFailure>, Never>?
    private var inFlightID: UUID?

    public init(
        transportFactory: @escaping @Sendable () throws -> any ClaudeControlTransport = { ClaudeProcessTransport() },
        now: @escaping @Sendable () -> Date = { Date() },
        timeout: TimeInterval = 20
    ) {
        self.transportFactory = transportFactory
        self.now = now
        self.timeout = timeout
    }

    public func readLimits() async -> Result<ClaudeAccountLimits, ClaudeUsageFailure> {
        // The caller (turned off meanwhile) was cancelled before reaching the actor: the unstructured
        // read below would not inherit that, so no child may start.
        guard !Task.isCancelled else { return .failure(.disconnected) }
        if let inFlight { return await inFlight.value }
        let id = UUID()
        let task = Task { await performRead() }
        inFlight = task
        inFlightID = id
        let result = await task.value
        if inFlightID == id {
            inFlight = nil
            inFlightID = nil
        }
        return result
    }

    /// Ends a running read and its child process, and returns after the child has exited. The read
    /// then returns `.disconnected`.
    public func stop() async {
        generation += 1
        transport?.close()
        transport = nil
        inFlight?.cancel()
        inFlight = nil
        inFlightID = nil
        await lastConnection?.waitUntilExited()
    }

    private func performRead() async -> Result<ClaudeAccountLimits, ClaudeUsageFailure> {
        guard !Task.isCancelled else { return .failure(.disconnected) }
        generation += 1
        let current = generation
        let connection: any ClaudeControlTransport
        do {
            connection = try transportFactory()
            try connection.start()
        } catch let failure as ClaudeUsageFailure {
            return .failure(failure)
        } catch {
            return .failure(.launchFailed)
        }
        transport = connection
        lastConnection = connection
        let interval = timeout
        let timer = Task { [weak self] in
            try await Task.sleep(for: .seconds(interval))
            await self?.expire(current)
        }
        defer {
            timer.cancel()
            connection.close()
            if generation == current { transport = nil }
        }
        do {
            try send(["type": "control_request", "request_id": Self.initializeID, "request": ["subtype": "initialize"]], to: connection)
            try send(["type": "control_request", "request_id": Self.usageID,
                      "request": ["subtype": "get_usage", "skip_behaviors": true]], to: connection)
        } catch {
            // The child closed stdin; its exit is reported below through EOF.
        }
        var sawLine = false
        do {
            while let line = try await connection.readLine() {
                sawLine = true
                guard generation == current else { return .failure(.disconnected) }
                // Lines that are not JSON or not our answer (status events, other responses) are skipped.
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      message["type"] as? String == "control_response",
                      let response = message["response"] as? [String: Any],
                      response["request_id"] as? String == Self.usageID else { continue }
                guard response["subtype"] as? String == "success" else { return .failure(.unsupported) }
                guard let body = response["response"] as? [String: Any] else { return .failure(.invalidResponse) }
                return ClaudeAccountLimits.decode(body, observedAt: now())
            }
        } catch {
            return .failure(timedOutGeneration == current ? .timeout : .invalidResponse)
        }
        if timedOutGeneration == current { return .failure(.timeout) }
        guard generation == current else { return .failure(.disconnected) }
        // A child that exits non-zero without printing anything never started properly (for example
        // an old Claude Code without these flags); only the status code is used.
        if !sawLine, let status = await connection.exitStatus(), status != 0 { return .failure(.launchFailed) }
        return .failure(.disconnected)
    }

    private func expire(_ readGeneration: Int) {
        guard generation == readGeneration else { return }
        timedOutGeneration = readGeneration
        transport?.close()
    }

    private func send(_ message: [String: Any], to connection: any ClaudeControlTransport) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try connection.write(data)
    }
}
