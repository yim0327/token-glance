import Foundation
import Darwin
import Testing
@testable import TokenGlanceCore

private final class FakeCodexTransport: CodexAppServerTransport, @unchecked Sendable {
    typealias Reply = ([String: Any]) -> [String: Any]?
    private let lock = NSLock()
    private var lines: [Data] = []
    private var waiter: CheckedContinuation<Data?, Error>?
    private var isClosed = false
    private var sent: [[String: Any]] = []
    let reply: Reply

    init(reply: @escaping Reply) { self.reply = reply }
    func start() throws { }

    func write(_ data: Data) throws {
        guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        lock.lock()
        sent.append(message)
        lock.unlock()
        if let response = reply(message) { enqueue(response) }
    }

    func readLine() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !lines.isEmpty {
                let line = lines.removeFirst()
                lock.unlock()
                continuation.resume(returning: line)
            } else if isClosed {
                lock.unlock()
                continuation.resume(returning: nil)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func close() {
        lock.lock()
        isClosed = true
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume(returning: nil)
    }

    func enqueue(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        enqueueRaw(data)
    }

    func enqueueRaw(_ data: Data) {
        lock.lock()
        let pending = waiter
        waiter = nil
        if pending == nil { lines.append(data) }
        lock.unlock()
        pending?.resume(returning: data)
    }

    func failRead() {
        lock.lock()
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume(throwing: CodexAppServerFailure.disconnected)
    }

    var methods: [String] {
        lock.lock(); defer { lock.unlock() }
        return sent.compactMap { $0["method"] as? String }
    }
    var closed: Bool {
        lock.lock(); defer { lock.unlock() }
        return isClosed
    }
    var messages: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return sent
    }
}

private func fixtureTransport(
    account: [String: Any] = ["type": "chatgpt"],
    limits: [String: Any] = ["accountId": "acct-1", "rateLimits": [
        "limitId": "codex", "primary": ["usedPercent": 20, "windowDurationMins": 300, "resetsAt": 1_800_000_000],
        "secondary": ["usedPercent": 40, "windowDurationMins": 10_080, "resetsAt": 1_800_300_000]
    ]],
    error: [String: Any]? = nil
) -> FakeCodexTransport {
    FakeCodexTransport { message in
        guard let id = message["id"] else { return nil }
        switch message["method"] as? String {
        case "initialize": return ["id": id, "result": [:]]
        case "account/read": return ["id": id, "result": ["account": account, "requiresOpenaiAuth": true]]
        case "account/rateLimits/read":
            if let error { return ["id": id, "error": error] }
            return ["id": id, "result": limits]
        default: return nil
        }
    }
}

struct CodexAppServerClientTests {
    @Test func constructionDoesNotStartProcess() async {
        let count = LockedCounter()
        let client = CodexAppServerClient(transportFactory: {
            count.increment()
            return fixtureTransport()
        })
        #expect(count.value == 0)
        await client.stop()
        #expect(count.value == 0)
    }

    @Test func initializesAndReadsOnlyExpectedMethods() async throws {
        let fake = fixtureTransport()
        let client = CodexAppServerClient(transportFactory: { fake })
        let result = await client.readLimits()
        let limits = try #require(result.success)
        #expect(limits.accountIdentity == "acct-1")
        #expect(limits.buckets.count == 1)
        #expect(limits.buckets[0].windows.map(\.kind) == [.session, .weekly])
        #expect(fake.methods == ["initialize", "initialized", "account/read", "account/rateLimits/read"])
        let messages = fake.messages
        #expect((messages[2]["params"] as? [String: Bool])?["refreshToken"] == false)
        #expect((messages[3]["params"] as? [String: Bool])?["excludeResetCreditDetails"] == true)
        await client.stop()
        #expect(fake.closed)
    }

    @Test func apiKeyDoesNotReadRateLimits() async {
        let fake = fixtureTransport(account: ["type": "apiKey"])
        let client = CodexAppServerClient(transportFactory: { fake })
        #expect(await client.readLimits() == .failure(.apiKeyAccount))
        #expect(!fake.methods.contains("account/rateLimits/read"))
        await client.stop()
    }

    @Test func handlesNullWindowsMultipleBucketsAndUnknownFields() throws {
        let value: [String: Any] = [
            "accountId": "acct-2", "rateLimits": ["primary": ["usedPercent": 99]],
            "rateLimitsByLimitId": [
                "codex": ["primary": NSNull(), "secondary": ["usedPercent": 12, "windowDurationMins": 300, "resetsAt": 1_800_000_000]],
                "other": ["limitId": "other", "primary": ["usedPercent": 30, "windowDurationMins": 30, "resetsAt": NSNull(), "future": 1]]
            ], "future": "ignored"
        ]
        let limits = try #require(CodexAccountLimits.decode(value, observedAt: Date(timeIntervalSince1970: 100)))
        #expect(limits.buckets.count == 2)
        #expect(limits.buckets[0].limitId == "codex")
        #expect(limits.buckets[0].windows.first?.kind == .session)
        #expect(limits.buckets[1].windows.first?.durationMinutes == 30)
        #expect(limits.buckets[1].windows.first?.kind == nil)
        #expect(limits.buckets[1].windows.first?.resetsAt == nil)
    }

    @Test func unsupportedAndRateLimited() async {
        let unsupported = fixtureTransport(error: ["code": -32601, "message": "Method not found"])
        let first = CodexAppServerClient(transportFactory: { unsupported })
        #expect(await first.readLimits() == .failure(.unsupportedMethod))
        await first.stop()

        let limited = fixtureTransport(error: ["code": 429, "message": "rate limited"])
        let second = CodexAppServerClient(transportFactory: { limited }, now: { Date(timeIntervalSince1970: 100) })
        #expect(await second.readLimits() == .failure(.rateLimited(retryAfter: Date(timeIntervalSince1970: 400))))
        #expect(await second.readLimits() == .failure(.rateLimited(retryAfter: Date(timeIntervalSince1970: 400))))
        #expect(limited.methods.filter { $0 == "account/rateLimits/read" }.count == 1)
        await second.stop()
    }

    @Test func timeoutCleansUpAndReconnects() async {
        let hung = FakeCodexTransport { _ in nil }
        let good = fixtureTransport()
        let factory = SequentialFactory([hung, good])
        let client = CodexAppServerClient(transportFactory: { factory.next() }, timeout: 0.02)
        #expect(await client.readLimits() == .failure(.timeout))
        #expect(hung.closed)
        #expect((await client.readLimits()).success != nil)
        await client.stop()
        #expect(good.closed)
    }

    @Test func concurrentReadsShareOneRequest() async throws {
        let pendingID = LockedID()
        let fake = FakeCodexTransport { message in
            guard let id = message["id"] else { return nil }
            switch message["method"] as? String {
            case "initialize": return ["id": id, "result": [:]]
            case "account/read": return ["id": id, "result": ["account": ["type": "chatgpt"]]]
            case "account/rateLimits/read": pendingID.set(id); return nil
            default: return nil
            }
        }
        let client = CodexAppServerClient(transportFactory: { fake })
        let first = Task { await client.readLimits() }
        let second = Task { await client.readLimits() }
        for _ in 0..<100 where pendingID.value == nil { try await Task.sleep(for: .milliseconds(5)) }
        let id = try #require(pendingID.value)
        fake.enqueue(["id": id, "result": ["rateLimits": ["primary": ["usedPercent": 10, "windowDurationMins": 300, "resetsAt": 1_800_000_000]]]])
        #expect((await first.value).success != nil)
        #expect((await second.value).success != nil)
        #expect(fake.methods.filter { $0 == "account/rateLimits/read" }.count == 1)
        await client.stop()
    }

    @Test func stopCancelsPendingReadAndClosesChild() async throws {
        let hung = FakeCodexTransport { _ in nil }
        let client = CodexAppServerClient(transportFactory: { hung }, timeout: 10)
        let task = Task { await client.readLimits() }
        for _ in 0..<100 where !hung.methods.contains("initialize") { try await Task.sleep(for: .milliseconds(5)) }
        await client.stop()
        #expect(hung.closed)
        #expect(await task.value == .failure(.disconnected))
    }

    @Test func disconnectAllowsReconnect() async throws {
        let first = fixtureTransport()
        let second = fixtureTransport()
        let factory = SequentialFactory([first, second])
        let client = CodexAppServerClient(transportFactory: { factory.next() })
        #expect((await client.readLimits()).success != nil)
        first.close()
        for _ in 0..<20 where !second.methods.contains("initialize") {
            try await Task.sleep(for: .milliseconds(5))
            _ = await client.readLimits()
        }
        #expect(second.methods.contains("initialize"))
        await client.stop()
    }

    @Test func sparseUpdateIsOnlyRefreshSignal() async throws {
        let fake = fixtureTransport()
        let count = LockedCounter()
        let client = CodexAppServerClient(transportFactory: { fake })
        await client.setRateLimitsUpdatedHandler { count.increment() }
        #expect((await client.readLimits()).success != nil)
        fake.enqueue(["method": "account/rateLimits/updated", "params": ["rateLimits": ["primary": ["usedPercent": 99]]]])
        for _ in 0..<100 where count.value == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(count.value == 1)
        await client.stop()
    }

    @Test func malformedServerLineIsInvalidResponseAndClosesConnection() async throws {
        let pendingID = LockedID()
        let fake = FakeCodexTransport { message in
            guard let id = message["id"] else { return nil }
            switch message["method"] as? String {
            case "initialize": return ["id": id, "result": [:]]
            case "account/read": return ["id": id, "result": ["account": ["type": "chatgpt"]]]
            case "account/rateLimits/read": pendingID.set(id); return nil
            default: return nil
            }
        }
        let client = CodexAppServerClient(transportFactory: { fake })
        let task = Task { await client.readLimits() }
        for _ in 0..<100 where pendingID.value == nil { try await Task.sleep(for: .milliseconds(5)) }
        _ = try #require(pendingID.value)
        fake.enqueueRaw(Data("{malformed".utf8))
        #expect(await task.value == .failure(.invalidResponse))
        #expect(fake.closed)
        await client.stop()
    }

    @Test func transportReadErrorIsDisconnected() async throws {
        let hung = FakeCodexTransport { _ in nil }
        let client = CodexAppServerClient(transportFactory: { hung })
        let task = Task { await client.readLimits() }
        for _ in 0..<100 where !hung.methods.contains("initialize") { try await Task.sleep(for: .milliseconds(5)) }
        hung.failRead()
        #expect(await task.value == .failure(.disconnected))
        #expect(hung.closed)
        await client.stop()
    }

    @Test func stubbornChildIsKilledAndReaped() async throws {
        let child = CodexProcessTransport(executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", "$SIG{TERM}='IGNORE'; $|=1; print \"$$\\n\"; sleep 30;"])
        try child.start()
        let line = try #require(try await child.readLine())
        let pid = try #require(Int32(String(decoding: line, as: UTF8.self)))
        child.close()
        for _ in 0..<80 where Darwin.kill(pid, 0) == 0 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(Darwin.kill(pid, 0) == -1)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class LockedID: @unchecked Sendable {
    private let lock = NSLock()
    private var id: Any?
    func set(_ value: Any) { lock.lock(); id = value; lock.unlock() }
    var value: Any? { lock.lock(); defer { lock.unlock() }; return id }
}

private final class SequentialFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [FakeCodexTransport]
    init(_ transports: [FakeCodexTransport]) { self.transports = transports }
    func next() -> any CodexAppServerTransport {
        lock.lock(); defer { lock.unlock() }
        return transports.removeFirst()
    }
}

private extension Result where Success == CodexAccountLimits, Failure == CodexAppServerFailure {
    var success: CodexAccountLimits? {
        if case .success(let limits) = self { return limits }
        return nil
    }
}
