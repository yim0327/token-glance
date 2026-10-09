import AppKit
import Foundation
import Observation
import os
import TokenGlanceCore

/// App state: one `ToolState` per tool.
///
/// Updates are driven by FSEvents on the log directories and the hook cache, with a 5-minute
/// fallback poll, a refresh at the next limit reset, after wake, and on demand. Each refresh only
/// reads bytes appended since the last one (`UsageLoader`); work runs off the main thread.
@Observable @MainActor
final class UsageStore {
    private(set) var claude = ToolState(tool: .claude)
    private(set) var codex = ToolState(tool: .codex)
    private(set) var isRefreshing = false
    /// 0...1 while the first full scan runs, `nil` otherwise.
    private(set) var scanProgress: Double?
    /// Time of the last completed refresh (shown as freshness), kept apart from tool states.
    private(set) var lastRefresh: Date?
    /// Saved to UserDefaults on change; see `apply(_:)`.
    private(set) var settings = AppSettings.load(from: .standard)

    var percentMode: PercentMode { settings.percentMode }

    @ObservationIgnored private let loader = UsageLoader()
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var resetTimer: Timer?
    @ObservationIgnored private var activeTimer: Timer?
    @ObservationIgnored private var refreshAgain = false
    /// Numbers only (durations, byte counts); never paths or content.
    @ObservationIgnored private let log = Logger(subsystem: "io.github.yim0327.token-glance", category: "refresh")

    static let fallbackPollInterval: TimeInterval = 300
    /// Codex keeps its rollout open while appending, which FSEvents does not report; active
    /// rollouts are stat-ed this often instead (no reading unless the size changed).
    static let activeCodexCheckInterval: TimeInterval = 2
    static let eventLatency: TimeInterval = 1.5

    var states: [ToolState] { [claude, codex] }

    func start() {
        loader.configure(roots: LogRoots.resolve(settings))
        refresh(reason: "launch")
        startWatching()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.fallbackPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(checkHook: true, reason: "poll") }
        }
        pollTimer?.tolerance = 30
        activeTimer = Timer.scheduledTimer(withTimeInterval: Self.activeCodexCheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.settings.codexEnabled, !self.isRefreshing,
                      self.loader.activeCodexFilesChanged() else { return }
                self.refresh(reason: "codex-active")
            }
        }
        activeTimer?.tolerance = 0.5
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(checkHook: true, reason: "wake") }
        }
    }

    /// Saves new settings. Changed log folders rebuild the indexes and the file watcher.
    func apply(_ newSettings: AppSettings) {
        let newSettings = newSettings.normalized
        guard newSettings != settings else { return }
        let rootsChanged = LogRoots.resolve(newSettings) != LogRoots.resolve(settings)
        settings = newSettings
        newSettings.save(to: .standard)
        if rootsChanged {
            loader.configure(roots: LogRoots.resolve(newSettings))
            claude.refreshedAt = nil  // shows indexing progress again
            startWatching()
        }
        refresh()
    }

    /// The installer for the Claude config folder currently in use.
    func makeInstaller() -> StatuslineInstaller {
        StatuslineInstaller(settingsURL: LogRoots.resolve(settings).claudeSettingsFile, paths: TokenGlancePaths.default(),
                            hookSource: HookLocator.bundledHook)
    }

    /// Runs a hook action off the main thread, then re-reads the hook state. Returns an error message on failure.
    func perform(_ action: HookAction) async -> String? {
        let installer = makeInstaller()
        let result: Result<StatuslineInstaller.Status, Error> = await Task.detached { Result { try action.perform(with: installer) } }.value
        refresh(checkHook: true)
        if case .failure(let error) = result { return HookErrorText.describe(error) }
        return nil
    }

    private func startWatching() {
        let filter = WatchFilter(rateLimitCache: TokenGlancePaths.default().rateLimitCache)
        watcher = FileWatcher(paths: loader.watchedPaths, latency: Self.eventLatency) { [weak self] paths in
            MainActor.assumeIsolated {
                let relevant = filter.isRelevant(paths)
                self?.log.debug("fsevents: \(paths.count, privacy: .public) paths, relevant: \(relevant, privacy: .public)")
                if relevant { self?.refresh(reason: "fsevents") }
            }
        }
        if watcher == nil { log.error("FSEvents stream could not be created; relying on polling") }
    }

    /// Incremental refresh. `checkHook` also re-reads the hook installation state from settings.json.
    func refresh(checkHook: Bool = false, reason: String = "manual") {
        guard !isRefreshing else {
            refreshAgain = true  // coalesce: run once more after the current refresh
            log.debug("refresh coalesced (\(reason, privacy: .public))")
            return
        }
        isRefreshing = true
        let loader = loader
        let firstScan = claude.refreshedAt == nil
        let enabled = (claude: settings.claudeEnabled, codex: settings.codexEnabled)
        if firstScan { scanProgress = 0 }
        let progress: @Sendable (Double) -> Void = { value in
            Task { @MainActor [weak self] in if self?.scanProgress != nil { self?.scanProgress = value } }
        }
        let started = Date()
        let bytesBefore = loader.bytesRead
        Task {
            let (claude, codex) = await Task.detached(priority: .utility) {
                loader.load(now: Date(), enabled: enabled, checkHook: checkHook || firstScan, progress: firstScan ? progress : nil)
            }.value
            // Replace state only when something besides the refresh time changed, so SwiftUI and the
            // label are not recomputed for no-op refreshes.
            let claudeChanged = !claude.sameContent(as: self.claude) || self.claude.refreshedAt == nil
            let codexChanged = !codex.sameContent(as: self.codex) || self.codex.refreshedAt == nil
            if claudeChanged { self.claude = claude }
            if codexChanged { self.codex = codex }
            log.info("state: claude changed \(claudeChanged, privacy: .public), codex changed \(codexChanged, privacy: .public)")
            self.lastRefresh = Date()
            log.info("refresh (\(reason, privacy: .public)): \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public) ms, \(loader.bytesRead - bytesBefore, privacy: .public) bytes read")
            self.scanProgress = nil
            self.isRefreshing = false
            scheduleResetRefresh()
            if refreshAgain {
                refreshAgain = false
                refresh(reason: "coalesced")
            }
        }
    }

    /// Refreshes right after the earliest upcoming reset so the label flips to "reset" on time.
    private func scheduleResetRefresh() {
        resetTimer?.invalidate()
        let next = states.flatMap { $0.summary?.limits ?? [] }.compactMap(\.resetsAt).filter { $0 > Date() }.min()
        guard let next else { return }
        resetTimer = Timer.scheduledTimer(withTimeInterval: next.timeIntervalSinceNow + 1, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh(reason: "reset") }
        }
    }
}

/// Keeps the incremental indexes and turns them into `ToolState`s. Not main-actor bound; calls are
/// serialized with a lock.
final class UsageLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var claudeIndex = ClaudeUsageIndex()
    private var codexIndex = CodexUsageIndex()
    private var hookStatus: StatuslineInstaller.Status?
    private var lastPrune = Date.distantPast
    private var codexActive = ActiveFileSet(window: 15 * 60)

    private let paths = TokenGlancePaths.default()
    private let fileSource = LocalFileSource()
    private var claudeRoot = ClaudeUsageProvider.defaultProjectsRoot()
    private var codexHome = CodexUsageProvider.defaultCodexHome()

    /// Records older than this are dropped from memory (the weekly window is at most 7 days back).
    static let retention: TimeInterval = 8 * 24 * 60 * 60

    var bytesRead: Int {
        lock.lock()
        defer { lock.unlock() }
        return claudeIndex.bytesRead + codexIndex.bytesRead
    }

    /// Cheap check for the short timer: stats only the active Codex rollouts. Returns false without
    /// waiting if a refresh currently holds the loader.
    func activeCodexFilesChanged() -> Bool {
        guard lock.try() else { return false }
        defer { lock.unlock() }
        return codexActive.hasChanges(source: fileSource)
    }

    /// Points the loader at new log folders, discarding everything indexed so far.
    func configure(roots: LogRoots) {
        lock.lock()
        defer { lock.unlock() }
        guard roots.claudeProjects != claudeRoot || roots.codexHome != codexHome || claudeIndex.trackedFileCount == 0 else { return }
        claudeRoot = roots.claudeProjects
        codexHome = roots.codexHome
        claudeIndex = ClaudeUsageIndex()
        codexIndex = CodexUsageIndex()
        codexActive = ActiveFileSet(window: 15 * 60)
    }

    var watchedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return [claudeRoot.path, codexHome.appendingPathComponent("sessions").path,
         codexHome.appendingPathComponent("archived_sessions").path, paths.supportDirectory.path]
    }

    func load(now: Date, enabled: (claude: Bool, codex: Bool) = (true, true), checkHook: Bool = true,
              progress: (@Sendable (Double) -> Void)? = nil) -> (ToolState, ToolState) {
        lock.lock()
        defer { lock.unlock() }

        // Disabled tools are not read at all.
        let claudeFiles = enabled.claude ? fileSource.files(under: claudeRoot) { $0.hasSuffix(".jsonl") } : []
        let codexFiles = enabled.codex ? ["sessions", "archived_sessions"].flatMap {
            fileSource.files(under: codexHome.appendingPathComponent($0), where: CodexUsageProvider.isRollout)
        } : []

        var reporter: ((Int) -> Void)?
        if let progress {
            let total = max(1, (claudeFiles + codexFiles).compactMap { fileSource.stat($0)?.size }.reduce(0, +))
            var done = 0, lastReported = 0.0
            reporter = { bytes in
                done += bytes
                let fraction = min(1, Double(done) / Double(total))
                if fraction - lastReported >= 0.02 { lastReported = fraction; progress(fraction) }
            }
        }
        claudeIndex.update(files: claudeFiles, source: fileSource, onRead: reporter)
        codexIndex.update(files: codexFiles, source: fileSource, onRead: reporter)
        var codexSizes: [URL: Int] = [:]
        for url in codexFiles { codexSizes[url] = fileSource.stat(url)?.size }
        codexActive.update(sizes: codexSizes, now: now)
        if now.timeIntervalSince(lastPrune) > 3600 {
            claudeIndex.prune(before: now - Self.retention)
            codexIndex.prune(before: now - Self.retention)
            lastPrune = now
        }

        if checkHook || hookStatus == nil {
            hookStatus = StatuslineInstaller(settingsURL: claudeRoot.deletingLastPathComponent().appendingPathComponent("settings.json"),
                                             paths: paths, hookSource: HookLocator.bundledHook).status()
        }

        let aggregator = UsageAggregator()
        let cache = ClaudeStatuslineCache(fileURL: paths.rateLimitCache, fileSource: fileSource)
        let claudeSnapshot: UsageSnapshot
        switch cache.read(now: now) {
        case .available(let windows): claudeSnapshot = UsageSnapshot(limits: windows, records: claudeIndex.records)
        case .unavailable(let reason): claudeSnapshot = UsageSnapshot(records: claudeIndex.records, limitsIssue: reason)
        }
        let codexLimits = codexIndex.limits
        let codexSnapshot = UsageSnapshot(limits: codexLimits, records: codexIndex.records, limitsIssue: codexLimits.isEmpty ? .noData : nil)
        return (
            ToolState.make(tool: .claude, snapshot: claudeSnapshot, hookStatus: hookStatus, aggregator: aggregator, now: now,
                           isEnabled: enabled.claude),
            ToolState.make(tool: .codex, snapshot: codexSnapshot, hookStatus: nil, aggregator: aggregator, now: now,
                           isEnabled: enabled.codex)
        )
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

enum HookErrorText {
    static func describe(_ error: Error) -> String {
        switch error as? StatuslineInstaller.InstallerError {
        case .settingsUnreadable: String(localized: "settings.json could not be read as JSON. Nothing was changed.")
        case .settingsNotWritable: String(localized: "settings.json is not writable. Nothing was changed.")
        case .hookSourceMissing: String(localized: "The hook program is missing from the app bundle. Rebuild with scripts/bundle-app.sh.")
        case .notInstalled: String(localized: "The hook is not installed.")
        case nil: error.localizedDescription
        }
    }
}
