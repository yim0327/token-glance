import Foundation

public protocol CodexAppServerTransport: AnyObject, Sendable {
    func start() throws
    func write(_ data: Data) throws
    func readLine() async throws -> Data?
    func close()
}

/// One read-only stdio connection. The caller owns the opt-in and polling schedule.
public actor CodexAppServerClient {
    private let transportFactory: @Sendable () throws -> any CodexAppServerTransport
    private let now: @Sendable () -> Date
    private let timeout: TimeInterval
    private var transport: (any CodexAppServerTransport)?
    private var reader: Task<Void, Never>?
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var nextID = 1
    private var generation = 0
    private var initialized = false
    private var inFlight: Task<Result<CodexAccountLimits, CodexAppServerFailure>, Never>?
    private var inFlightID: UUID?
    private var retryAfter: Date?
    private var updatedHandler: (@Sendable () -> Void)?

    public init(
        transportFactory: @escaping @Sendable () throws -> any CodexAppServerTransport = { CodexProcessTransport() },
        now: @escaping @Sendable () -> Date = { Date() },
        timeout: TimeInterval = 10
    ) {
        self.transportFactory = transportFactory
        self.now = now
        self.timeout = timeout
    }

    public func setRateLimitsUpdatedHandler(_ handler: (@Sendable () -> Void)?) {
        updatedHandler = handler
    }

    public func readLimits() async -> Result<CodexAccountLimits, CodexAppServerFailure> {
        if let inFlight { return await inFlight.value }
        if let retryAfter, now() < retryAfter { return .failure(.rateLimited(retryAfter: retryAfter)) }
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

    public func stop() {
        resetConnection()
        inFlight?.cancel()
        inFlight = nil
        inFlightID = nil
    }

    private func resetConnection(failure: CodexAppServerFailure = .disconnected) {
        generation += 1
        initialized = false
        reader?.cancel()
        reader = nil
        transport?.close()
        transport = nil
        failPending(failure)
    }

    private func performRead() async -> Result<CodexAccountLimits, CodexAppServerFailure> {
        var readGeneration = generation
        do {
            try Task.checkCancellation()
            try await connectIfNeeded()
            readGeneration = generation
            try Task.checkCancellation()
            let account = try await request("account/read", params: ["refreshToken": false])
            guard let accountInfo = account["account"] as? [String: Any],
                  let type = accountInfo["type"] as? String else {
                throw CodexAppServerFailure.loginRequired
            }
            guard type == "chatgpt" else { throw CodexAppServerFailure.apiKeyAccount }
            let result = try await request("account/rateLimits/read", params: ["excludeResetCreditDetails": true])
            guard let limits = CodexAccountLimits.decode(result, observedAt: now()) else {
                throw CodexAppServerFailure.invalidResponse
            }
            return .success(limits)
        } catch let failure as CodexAppServerFailure {
            if (failure == .timeout || failure == .disconnected), generation == readGeneration { resetConnection() }
            return .failure(failure)
        } catch {
            if generation == readGeneration { resetConnection() }
            return .failure(.disconnected)
        }
    }

    private func connectIfNeeded() async throws {
        if initialized { return }
        resetConnection()
        let connection = try transportFactory()
        try connection.start()
        transport = connection
        let currentGeneration = generation
        reader = Task { await readLoop(connection, generation: currentGeneration) }
        do {
            _ = try await request("initialize", params: [
                "clientInfo": ["name": "token-glance", "version": "1.0"],
                "capabilities": ["experimentalApi": false]
            ])
            try Task.checkCancellation()
            try send(["method": "initialized"])
            initialized = true
        } catch {
            if generation == currentGeneration { resetConnection() }
            throw error
        }
    }

    private func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try send(["id": id, "method": method, "params": params])
            } catch {
                pending.removeValue(forKey: id)?.resume(throwing: CodexAppServerFailure.disconnected)
                return
            }
            let interval = timeout
            Task {
                try? await Task.sleep(for: .seconds(interval))
                self.timeoutRequest(id)
            }
        }
    }

    private func send(_ message: [String: Any]) throws {
        guard let transport else { throw CodexAppServerFailure.disconnected }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try transport.write(data)
    }

    private func timeoutRequest(_ id: Int) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CodexAppServerFailure.timeout)
    }

    private func readLoop(_ connection: any CodexAppServerTransport, generation current: Int) async {
        do {
            while !Task.isCancelled, let line = try await connection.readLine() {
                guard current == generation else { return }
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    resetConnection(failure: .invalidResponse)
                    return
                }
                receive(message)
            }
        } catch let failure as CodexAppServerFailure {
            if current == generation { resetConnection(failure: failure) }
            return
        } catch {
            if current == generation { resetConnection() }
            return
        }
        if current == generation { resetConnection() }
    }

    private func receive(_ message: [String: Any]) {
        if let method = message["method"] as? String {
            if method == "account/rateLimits/updated" { updatedHandler?() }
            return
        }
        guard let id = (message["id"] as? NSNumber)?.intValue,
              let continuation = pending.removeValue(forKey: id) else { return }
        if let error = message["error"] as? [String: Any] {
            let code = (error["code"] as? NSNumber)?.intValue
            let detail = (error["message"] as? String ?? "").lowercased()
            if code == -32601 {
                continuation.resume(throwing: CodexAppServerFailure.unsupportedMethod)
            } else if code == 401 || code == 403 {
                continuation.resume(throwing: CodexAppServerFailure.loginRequired)
            } else if code == 429 || detail.contains("429") || detail.contains("rate limit") {
                let delay: TimeInterval = 300
                let date = now().addingTimeInterval(delay)
                retryAfter = date
                continuation.resume(throwing: CodexAppServerFailure.rateLimited(retryAfter: date))
            } else {
                continuation.resume(throwing: CodexAppServerFailure.invalidResponse)
            }
        } else if let result = message["result"] as? [String: Any] {
            continuation.resume(returning: result)
        } else {
            continuation.resume(throwing: CodexAppServerFailure.invalidResponse)
        }
    }

    private func failPending(_ failure: CodexAppServerFailure) {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: failure) }
    }
}
