import Foundation
import Observation
import TokenGlanceCore

/// App state: one `ToolState` per tool, refreshed every 60 seconds and on demand.
/// Parsing runs off the main thread; only the results are applied on the main actor.
@Observable @MainActor
final class UsageStore {
    private(set) var claude = ToolState(tool: .claude)
    private(set) var codex = ToolState(tool: .codex)
    private(set) var isRefreshing = false
    var percentMode: PercentMode = .remaining

    @ObservationIgnored private let loader = UsageLoader()
    @ObservationIgnored private var timer: Timer?

    static let pollInterval: TimeInterval = 60

    var states: [ToolState] { [claude, codex] }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 10
    }

    func refresh(force: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true
        let loader = loader
        Task {
            let (claude, codex) = await Task.detached(priority: .utility) { loader.load(now: Date(), force: force) }.value
            self.claude = claude
            self.codex = codex
            self.isRefreshing = false
        }
    }
}

/// Reads both tools. Claude logs are re-parsed only when the log files changed.
final class UsageLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var claudeSignature: FilesSignature?
    private var claudeRecords: [UsageRecord] = []

    private let paths = TokenGlancePaths.default()
    private let fileSource = LocalFileSource()

    func load(now: Date, force: Bool = false) -> (ToolState, ToolState) {
        lock.lock()
        defer { lock.unlock() }
        let aggregator = UsageAggregator()

        let installer = StatuslineInstaller(settingsURL: StatuslineInstaller.defaultSettingsURL(), paths: paths,
                                            hookSource: HookLocator.bundledHook)
        let claudeLogs = fileSource.files(under: ClaudeUsageProvider.defaultProjectsRoot()) { $0.hasSuffix(".jsonl") }
        let signature = FilesSignature.of(claudeLogs)
        if force || signature != claudeSignature {
            var parser = ClaudeLogParser()
            for url in claudeLogs {
                if let data = try? fileSource.contents(of: url) { parser.consume(data) }
            }
            claudeRecords = parser.records
            claudeSignature = signature
        }
        let cache = ClaudeStatuslineCache(fileURL: paths.rateLimitCache, fileSource: fileSource)
        let claudeSnapshot: UsageSnapshot
        switch cache.read(now: now) {
        case .available(let windows): claudeSnapshot = UsageSnapshot(limits: windows, records: claudeRecords)
        case .unavailable(let reason): claudeSnapshot = UsageSnapshot(records: claudeRecords, limitsIssue: reason)
        }
        let claude = ToolState.make(tool: .claude, snapshot: claudeSnapshot, hookStatus: installer.status(),
                                    aggregator: aggregator, now: now)
        let codex = ToolState.make(tool: .codex, snapshot: CodexUsageProvider().snapshot(), hookStatus: nil,
                                   aggregator: aggregator, now: now)
        return (claude, codex)
    }
}

enum HookLocator {
    /// The hook shipped in `TokenGlance.app/Contents/Resources`, or next to the executable in a
    /// SwiftPM build directory during development.
    static var bundledHook: URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("token-glance-hook"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("token-glance-hook"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
