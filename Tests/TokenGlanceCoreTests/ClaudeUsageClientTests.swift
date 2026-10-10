import Foundation
import Testing
@testable import TokenGlanceCore

/// Shape of a `get_usage` answer from Claude Code 2.1.296, with synthetic values. Unknown keys
/// (cost, plan type, spend, codenamed meters) are present so decoding must ignore them.
private func usageBody(limits: Any? = [
    ["kind": "session", "group": "session", "percent": 37, "resets_at": "2026-10-10T08:00:00.000Z",
     "severity": "normal", "is_active": true, "scope": NSNull()],
    ["kind": "weekly_all", "group": "weekly", "percent": 12, "resets_at": "2026-10-14T03:00:00Z",
     "severity": "normal", "is_active": false, "scope": NSNull()],
], extra: [String: Any] = [:]) -> [String: Any] {
    var rateLimits: [String: Any] = [
        "five_hour": ["utilization": 37, "resets_at": "2026-10-10T08:00:00.000Z"],
        "seven_day": ["utilization": 12, "resets_at": "2026-10-14T03:00:00Z"],
        "seven_day_opus": NSNull(),
        "some_future_meter": ["utilization": 99],
        "spend": ["percent": 3, "disclaimer": "synthetic"],
    ]
    if let limits { rateLimits["limits"] = limits } else { rateLimits.removeValue(forKey: "limits") }
    rateLimits.merge(extra) { _, new in new }
    return [
        "session": ["total_cost_usd": 0, "model_usage": [:]],
        "subscription_type": "synthetic-plan",
        "rate_limits_available": true,
        "rate_limits": rateLimits,
        "behaviors": NSNull(),
    ]
}

private let observed = Date(timeIntervalSince1970: 1_791_600_000)

struct ClaudeAccountLimitsDecodeTests {
    @Test func decodesSessionAndWeeklyByKind() throws {
        let limits = try ClaudeAccountLimits.decode(usageBody(), observedAt: observed).get()
        #expect(limits.observedAt == observed)
        #expect(limits.windows.map(\.kind) == [.session, .weekly])
        #expect(limits.windows.map(\.usedPercent) == [37, 12])
        #expect(limits.windows[0].resetsAt == ClaudeAccountLimits.parseDate("2026-10-10T08:00:00Z"))
        #expect(limits.windows[1].resetsAt == Date(timeIntervalSince1970: 1_791_946_800))
    }

    @Test func missingWindowIsLeftOut() throws {
        let body = usageBody(limits: [["kind": "weekly_all", "group": "weekly", "percent": 50, "resets_at": NSNull()]])
        let limits = try ClaudeAccountLimits.decode(body, observedAt: observed).get()
        #expect(limits.windows == [ClaudeLimitWindow(kind: .weekly, usedPercent: 50, resetsAt: nil)])
    }

    @Test func unknownAndScopedKindsAreIgnoredNotGuessed() throws {
        let body = usageBody(limits: [
            ["kind": "weekly_scoped", "group": "weekly", "percent": 90, "resets_at": "2026-10-14T03:00:00Z",
             "scope": ["model": ["display_name": "Synthetic"]]],
            ["kind": "monthly_something", "group": "monthly", "percent": 80],
            ["kind": "session", "group": "renamed-group", "percent": 5, "new_field": [1, 2]],
        ])
        let limits = try ClaudeAccountLimits.decode(body, observedAt: observed).get()
        #expect(limits.windows == [ClaudeLimitWindow(kind: .session, usedPercent: 5, resetsAt: nil)])
    }

    @Test func schemaChangesDegradeInsteadOfFailing() throws {
        // Rows with the wrong types are skipped; a bad date becomes "no reset time".
        let odd = usageBody(limits: [
            ["kind": "session", "percent": "37"],
            ["kind": "weekly_all", "percent": 120, "resets_at": "next tuesday"],
            "not an object",
        ])
        #expect(try ClaudeAccountLimits.decode(odd, observedAt: observed).get().windows
                == [ClaudeLimitWindow(kind: .weekly, usedPercent: 100, resetsAt: nil)])
        // Without `limits[]`, the windows keyed by length are used.
        let legacy = try ClaudeAccountLimits.decode(usageBody(limits: nil), observedAt: observed).get()
        #expect(legacy.windows.map(\.kind) == [.session, .weekly])
        #expect(legacy.windows.map(\.usedPercent) == [37, 12])
        // An empty `limits[]` means the server reported no meters; nothing is guessed from elsewhere.
        #expect(try ClaudeAccountLimits.decode(usageBody(limits: []), observedAt: observed).get().windows.isEmpty)
    }

    @Test func duplicateKindsAreDroppedAsAmbiguous() throws {
        let body = usageBody(limits: [
            ["kind": "session", "percent": 10], ["kind": "session", "percent": 60], ["kind": "weekly_all", "percent": 20],
        ])
        #expect(try ClaudeAccountLimits.decode(body, observedAt: observed).get().windows.map(\.kind) == [.weekly])
    }

    @Test func unavailableStatesMapToFailures() {
        var body = usageBody()
        body["rate_limits_available"] = false
        body["rate_limits"] = NSNull()
        #expect(ClaudeAccountLimits.decode(body, observedAt: observed) == .failure(.subscriptionRequired))
        body["rate_limits_available"] = true
        #expect(ClaudeAccountLimits.decode(body, observedAt: observed) == .failure(.unavailable))
        body.removeValue(forKey: "rate_limits")
        #expect(ClaudeAccountLimits.decode(body, observedAt: observed) == .failure(.invalidResponse))
    }
}

private final class FakeClaudeTransport: ClaudeControlTransport, @unchecked Sendable {
    typealias Reply = ([String: Any]) -> [Data]
    private let lock = NSLock()
    private var lines: [Data] = []
    private var waiter: CheckedContinuation<Data?, Error>?
    private var isClosed = false
    private var sent: [[String: Any]] = []
    private let reply: Reply
    let status: Int32?

    init(status: Int32? = 0, reply: @escaping Reply) {
        self.status = status
        self.reply = reply
    }

    func start() throws {}

    func write(_ data: Data) throws {
        guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        lock.lock()
        sent.append(message)
        lock.unlock()
        for line in reply(message) { enqueue(line) }
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

    func exitStatus() async -> Int32? { status }

    func enqueue(_ line: Data) {
        lock.lock()
        let pending = waiter
        waiter = nil
        if pending == nil { lines.append(line) }
        lock.unlock()
        pending?.resume(returning: line)
    }

    var requests: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return sent.compactMap { $0["request"] as? [String: Any] }
    }
    var closed: Bool {
        lock.lock(); defer { lock.unlock() }
        return isClosed
    }
}

private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

/// Answers like Claude Code: a status line, the initialize response, then the usage response.
private func answering(_ usage: @escaping (String) -> [String: Any]) -> FakeClaudeTransport {
    FakeClaudeTransport { message in
        guard let id = message["request_id"] as? String,
              let subtype = (message["request"] as? [String: Any])?["subtype"] as? String else { return [] }
        switch subtype {
        case "initialize":
            return [json(["type": "system", "subtype": "ui_invalidate"]),
                    json(["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": [:]]])]
        case "get_usage":
            return [Data("not json at all".utf8), json(usage(id))]
        default:
            return []
        }
    }
}

private func success(_ body: [String: Any]) -> (String) -> [String: Any] {
    { id in ["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": body]] }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

struct ClaudeUsageClientTests {
    @Test func constructionAndStopDoNotStartClaude() async {
        let launches = Counter()
        let client = ClaudeUsageClient(transportFactory: {
            launches.increment()
            return answering(success(usageBody()))
        })
        await client.stop()
        #expect(launches.value == 0)
    }

    @Test func readSendsOnlyInitializeAndUsageThenClosesChild() async throws {
        let fake = answering(success(usageBody()))
        let client = ClaudeUsageClient(transportFactory: { fake }, now: { observed })
        let limits = try await client.readLimits().get()
        #expect(limits.windows.map(\.usedPercent) == [37, 12])
        #expect(limits.observedAt == observed)
        #expect(fake.requests.map { $0["subtype"] as? String } == ["initialize", "get_usage"])
        #expect(fake.requests.last?["skip_behaviors"] as? Bool == true)
        #expect(fake.closed)
    }

    @Test func controlErrorMeansUnsupported() async {
        let fake = answering { id in
            ["type": "control_response", "response": ["subtype": "error", "request_id": id,
                                                       "error": "get_usage is not supported in this context"]]
        }
        let client = ClaudeUsageClient(transportFactory: { fake })
        #expect(await client.readLimits() == .failure(.unsupported))
        #expect(fake.closed)
    }

    @Test func timeoutClosesTheChild() async {
        let fake = FakeClaudeTransport { _ in [] }
        let client = ClaudeUsageClient(transportFactory: { fake }, timeout: 0.05)
        #expect(await client.readLimits() == .failure(.timeout))
        #expect(fake.closed)
    }

    @Test func childExitClassification() async {
        let silentFailure = FakeClaudeTransport(status: 1) { _ in [] }
        silentFailure.close()
        #expect(await ClaudeUsageClient(transportFactory: { silentFailure }).readLimits() == .failure(.launchFailed))

        let talkedThenExited = FakeClaudeTransport(status: 0) { message in
            (message["request"] as? [String: Any])?["subtype"] as? String == "get_usage"
                ? [json(["type": "system"])] : []
        }
        let client = ClaudeUsageClient(transportFactory: { talkedThenExited })
        let task = Task { await client.readLimits() }
        try? await Task.sleep(for: .milliseconds(50))
        talkedThenExited.close()
        #expect(await task.value == .failure(.disconnected))
    }

    @Test func missingExecutableAndLaunchErrors() async {
        final class Failing: ClaudeControlTransport, @unchecked Sendable {
            let error: Error
            init(_ error: Error) { self.error = error }
            func start() throws { throw error }
            func write(_ data: Data) throws {}
            func readLine() async throws -> Data? { nil }
            func close() {}
        }
        #expect(await ClaudeUsageClient(transportFactory: { Failing(ClaudeUsageFailure.executableUnavailable) }).readLimits()
                == .failure(.executableUnavailable))
        #expect(await ClaudeUsageClient(transportFactory: { Failing(CocoaError(.fileNoSuchFile)) }).readLimits()
                == .failure(.launchFailed))
    }

    @Test func overlappingReadsShareOneChild() async {
        let launches = Counter()
        let fake = FakeClaudeTransport { _ in [] }
        let client = ClaudeUsageClient(transportFactory: {
            launches.increment()
            return fake
        })
        let first = Task { await client.readLimits() }
        let second = Task { await client.readLimits() }
        try? await Task.sleep(for: .milliseconds(50))
        fake.enqueue(json(success(usageBody())(ClaudeUsageClient.usageID)))
        #expect((try? await first.value.get()) != nil)
        #expect((try? await second.value.get()) != nil)
        #expect(launches.value == 1)
    }

    @Test func stopCancelsARunningRead() async {
        let fake = FakeClaudeTransport { _ in [] }
        let client = ClaudeUsageClient(transportFactory: { fake })
        let task = Task { await client.readLimits() }
        try? await Task.sleep(for: .milliseconds(50))
        await client.stop()
        #expect(await task.value == .failure(.disconnected))
        #expect(fake.closed)
    }

    @Test func secretsInTheAnswerNeverReachResultsOrFailures() async {
        let secret = "sk-ant-oat01-SYNTHETIC-SECRET"
        let email = "someone@example.invalid"
        let body = usageBody(extra: ["accessToken": secret, "account": ["email": email]])
        let ok = await ClaudeUsageClient(transportFactory: { answering(success(body)) }).readLimits()
        let failed = await ClaudeUsageClient(transportFactory: {
            answering { id in ["type": "control_response",
                               "response": ["subtype": "error", "request_id": id, "error": "bad token \(secret) for \(email)"]]}
        }).readLimits()
        for text in [String(describing: ok), String(reflecting: ok), String(describing: failed), String(reflecting: failed)] {
            #expect(!text.contains(secret))
            #expect(!text.contains(email))
            #expect(!text.contains("synthetic-plan"))
        }
    }
}

struct ClaudeProcessTransportTests {
    @Test func childRunsHeadlessWithoutPromptSessionOrUserExtensions() {
        let args = ClaudeProcessTransport.arguments
        #expect(args.starts(with: ["-p", "--input-format", "stream-json", "--output-format", "stream-json"]))
        for flag in ["--no-session-persistence", "--safe-mode", "--strict-mcp-config"] { #expect(args.contains(flag)) }
        // No positional prompt: nothing reaches the model.
        #expect(!args.contains { !$0.hasPrefix("-") && !["stream-json"].contains($0) })
    }

    @Test func childEnvironmentTurnsOffTelemetryButKeepsTheUsageRead() {
        let env = ClaudeProcessTransport.childEnvironment(
            executable: URL(fileURLWithPath: "/opt/example/bin/claude"), configDir: URL(fileURLWithPath: "/tmp/alt-claude"),
            base: ["PATH": "/usr/bin", "HOME": "/Users/example", "DISABLE_TELEMETRY": "0"])
        #expect(env["DISABLE_TELEMETRY"] == "1")
        #expect(env["DISABLE_ERROR_REPORTING"] == "1")
        #expect(env["DISABLE_AUTOUPDATER"] == "1")
        #expect(env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == nil)
        #expect(env["CLAUDE_CONFIG_DIR"] == "/tmp/alt-claude")
        #expect(env["PATH"]?.hasPrefix("/opt/example/bin:") == true)
        #expect(ClaudeProcessTransport.childEnvironment(executable: URL(fileURLWithPath: "/x/claude"), configDir: nil,
                                                       base: [:])["CLAUDE_CONFIG_DIR"] == nil)
    }
}
