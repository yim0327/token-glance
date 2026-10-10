import AppKit
import Foundation
import Observation
import os
import TokenGlanceCore
import TokenGlanceText

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
    /// Builds all user-facing text; replaced when the language setting changes (no restart needed).
    private(set) var localizer: Localizer
    private(set) var notificationAuthorization: Notifier.Authorization = .notDetermined
    /// Claude hook state, kept apart from `claude` so the settings window only re-renders when it changes.
    private(set) var hookStatus: StatuslineInstaller.Status?

    var percentMode: PercentMode { settings.percentMode }

    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private var planner: NotificationPlanner
    @ObservationIgnored private var marks = UserDefaultsNotificationMarks()

    init() {
        let settings = AppSettings.load(from: .standard)
        self.settings = settings
        localizer = Localizer(AppLanguage(rawValue: settings.language) ?? .system)
        planner = NotificationPlanner(thresholds: settings.notificationThresholds)
    }

    @ObservationIgnored private let loader = UsageLoader()
    @ObservationIgnored private let onlineClient = CodexAppServerClient()
    @ObservationIgnored private var localCodex = ToolState(tool: .codex)
    @ObservationIgnored private var onlineSnapshot: CodexAccountLimits?
    @ObservationIgnored private var onlineFailure: String?
    @ObservationIgnored private lazy var online = CodexOnlineLimitsController(
        reader: onlineClient,
        isEnabled: { [weak self] in self?.onlineEnabled ?? false },
        onResult: { [weak self] in self?.applyOnline($0) })
    /// The Claude folder override, read by the usage child when it starts.
    @ObservationIgnored private let claudeConfigDir = LockedURL()
    @ObservationIgnored private lazy var claudeOnlineClient = ClaudeUsageClient(transportFactory: { [claudeConfigDir] in
        ClaudeProcessTransport(configDir: claudeConfigDir.value)
    })
    @ObservationIgnored private var localClaude = ToolState(tool: .claude)
    @ObservationIgnored private var claudeOnlineSnapshot: ClaudeAccountLimits?
    @ObservationIgnored private var claudeOnlineFailure: String?
    @ObservationIgnored private lazy var claudeOnline = ClaudeOnlineLimitsController(
        reader: claudeOnlineClient,
        isEnabled: { [weak self] in self?.claudeOnlineEnabled ?? false },
        onResult: { [weak self] in self?.applyClaudeOnline($0) })
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
        claudeConfigDir.value = Self.claudeConfigOverride(settings)
        refresh(reason: "launch")
        claudeOnline.refresh(.launch)
        Task { [weak self] in
            guard let self else { return }
            await onlineClient.setRateLimitsUpdatedHandler { [weak self] in
                Task { @MainActor in self?.online.refresh() }
            }
            online.refresh()
        }
        startWatching()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.fallbackPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh(checkHook: true, reason: "poll")
                self?.online.refresh()
                self?.claudeOnline.refresh(.poll)
            }
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
            MainActor.assumeIsolated {
                // Changes that happened while asleep are not announced afterwards.
                self?.planner.rebaseline()
                self?.refresh(checkHook: true, reason: "wake")
                self?.online.refresh()
                self?.claudeOnline.refresh(.wake)
            }
        }
        marks.prune(before: Date().addingTimeInterval(-8 * 24 * 60 * 60))
        Task { await updateNotificationAuthorization() }
    }

    /// Saves new settings. Changed log folders rebuild the indexes and the file watcher.
    func apply(_ newSettings: AppSettings) {
        let newSettings = newSettings.normalized
        guard newSettings != settings else {
            log.debug("settings: apply with no change")
            return
        }
        log.info("settings: apply \(Self.changedFields(self.settings, newSettings), privacy: .public)")
        let old = settings
        let rootsChanged = LogRoots.resolve(newSettings) != LogRoots.resolve(old)
        let onlineChanged = newSettings.codexOnlineLimitsEnabled != old.codexOnlineLimitsEnabled
            || newSettings.codexEnabled != old.codexEnabled
        let wasClaudeOnline = claudeOnlineEnabled
        // A different Claude folder can mean a different login, so an earlier answer no longer applies.
        let claudeOnlineChanged = newSettings.claudeOnlineLimitsEnabled != old.claudeOnlineLimitsEnabled
            || newSettings.claudeEnabled != old.claudeEnabled
            || Self.claudeConfigOverride(newSettings) != Self.claudeConfigOverride(old)
        settings = newSettings
        newSettings.save(to: .standard)
        if newSettings.language != old.language {
            localizer = Localizer(AppLanguage(rawValue: newSettings.language) ?? .system)
        }
        planner.thresholds = newSettings.notificationThresholds
        // Alert baselines restart from the next observation whenever what they describe changes.
        if newSettings.notificationsEnabled && !old.notificationsEnabled {
            planner.rebaseline()
            Task {
                notificationAuthorization = await notifier.requestAuthorization()
                log.info("notifications: requested, now \(String(describing: self.notificationAuthorization), privacy: .public)")
            }
        }
        if rootsChanged { planner.rebaseline() }
        if !newSettings.claudeEnabled { planner.forget(tool: .claude) }
        if !newSettings.codexEnabled { planner.forget(tool: .codex) }
        if onlineChanged { planner.forget(tool: .codex) }
        if claudeOnlineChanged {
            planner.forget(tool: .claude)
            claudeConfigDir.value = Self.claudeConfigOverride(newSettings)
            claudeOnlineSnapshot = nil
            claudeOnlineFailure = nil
        }
        if rootsChanged {
            loader.configure(roots: LogRoots.resolve(newSettings))
            claude.refreshedAt = nil  // shows indexing progress again
            startWatching()
        }
        refresh(reason: "settings")
        if onlineChanged {
            if onlineEnabled {
                online.refresh()
            } else {
                onlineSnapshot = nil
                onlineFailure = nil
                codex = localCodex
                online.disable()
            }
        }
        if claudeOnlineChanged {
            // After a folder change the old folder's values stay hidden until the new index is ready.
            if !rootsChanged { claude = presentClaude(now: Date()) }
            if claudeOnlineEnabled && !wasClaudeOnline {
                claudeOnline.refresh(.manual)
            } else {
                // Off: cancel now. Still on (folder changed): stop the old read; a new one starts after.
                claudeOnline.disable()
            }
        }
    }

    /// Names of the settings that differ (diagnostics; no values or paths).
    private static func changedFields(_ a: AppSettings, _ b: AppSettings) -> String {
        var names: [String] = []
        if a.percentMode != b.percentMode { names.append("percentMode") }
        if a.claudeEnabled != b.claudeEnabled { names.append("claudeEnabled") }
        if a.codexEnabled != b.codexEnabled { names.append("codexEnabled") }
        if a.codexOnlineLimitsEnabled != b.codexOnlineLimitsEnabled { names.append("codexOnlineLimitsEnabled") }
        if a.claudeOnlineLimitsEnabled != b.claudeOnlineLimitsEnabled { names.append("claudeOnlineLimitsEnabled") }
        if a.claudeConfigDir != b.claudeConfigDir { names.append("claudeConfigDir") }
        if a.codexHome != b.codexHome { names.append("codexHome") }
        if a.language != b.language { names.append("language") }
        if a.notificationsEnabled != b.notificationsEnabled { names.append("notificationsEnabled") }
        if a.notificationThresholds != b.notificationThresholds { names.append("thresholds") }
        return names.joined(separator: ",")
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
        refresh(checkHook: true, reason: "hook")
        if case .failure(let error) = result { return localizer.hookError(error) }
        return nil
    }

    // MARK: Notifications

    func updateNotificationAuthorization() async {
        notificationAuthorization = await notifier.authorization()
        log.info("notifications: authorization \(String(describing: self.notificationAuthorization), privacy: .public)")
    }

    func openNotificationSettings() {
        notifier.openSystemSettings()
    }

    /// Sends a test notification. Returns an error description on failure.
    func sendTestNotification() async -> String? {
        let error = await notifier.send(id: "test-\(UUID().uuidString)", title: localizer("notify.test.title"), body: localizer("notify.test.body"))
        log.info("notifications: test sent, error \(error != nil, privacy: .public)")
        return error
    }

    private func evaluateNotifications(now: Date) {
        guard settings.notificationsEnabled else { return }
        var events: [LimitNotification] = []
        for state in states where state.isEnabled {
            events += planner.evaluate(tool: state.tool, windows: state.limitWindows, now: now, marks: &marks)
        }
        guard !events.isEmpty, notificationAuthorization == .authorized else { return }
        for event in events {
            let text = localizer.notification(event)
            let id = "\(event.tool.rawValue).\(event.window.rawValue).\(event.kind.rawValue).\(Int(event.resetsAt.timeIntervalSince1970))"
            Task { [notifier, log] in
                if let error = await notifier.send(id: id, title: text.title, body: text.body) {
                    log.error("notification failed: \(error, privacy: .public)")
                }
            }
            log.info("notification: \(event.kind.rawValue, privacy: .public)")
        }
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

    /// The Refresh button: local logs, hook state and, when opted in, the account queries.
    func refreshNow() {
        refresh(checkHook: true, reason: "manual")
        online.refresh()
        claudeOnline.refresh(.manual)
    }

    /// Incremental refresh of local data. `checkHook` also re-reads the hook installation state from
    /// settings.json. Never queries an account; see `refreshNow()`.
    func refresh(checkHook: Bool = false, reason: String) {
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
            self.localClaude = claude
            let presentedClaude = self.presentClaude(now: Date())
            let claudeChanged = !presentedClaude.sameContent(as: self.claude) || self.claude.refreshedAt == nil
            self.localCodex = codex
            let presentedCodex = self.presentCodex(now: Date())
            let codexChanged = !presentedCodex.sameContent(as: self.codex) || self.codex.refreshedAt == nil
            if claudeChanged { self.claude = presentedClaude }
            if claude.hookStatus != self.hookStatus { self.hookStatus = claude.hookStatus }
            if codexChanged { self.codex = presentedCodex }
            log.info("state: claude changed \(claudeChanged, privacy: .public), codex changed \(codexChanged, privacy: .public)")
            self.lastRefresh = Date()
            self.evaluateNotifications(now: Date())
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

    private func presentCodex(now: Date) -> ToolState {
        guard settings.codexEnabled && settings.codexOnlineLimitsEnabled else { return localCodex }
        if let onlineSnapshot {
            return CodexOnlinePresentation.apply(onlineSnapshot, to: localCodex, now: now)
        }
        return CodexOnlinePresentation.fallback(localCodex,
                                                reason: onlineFailure ?? "Waiting for account query", now: now)
    }

    private var onlineEnabled: Bool { settings.codexEnabled && settings.codexOnlineLimitsEnabled }

    private func applyOnline(_ result: Result<CodexAccountLimits, CodexAppServerFailure>) {
        switch result {
        case .success(let snapshot):
            // Replace the complete account/bucket snapshot. Never merge partial identities.
            let accepted = CodexOnlinePresentation.newer(snapshot, than: onlineSnapshot)
            if onlineSnapshot?.accountIdentity != accepted.accountIdentity
                || onlineSnapshot?.buckets.map(\.limitId) != accepted.buckets.map(\.limitId) {
                planner.forget(tool: .codex)
            }
            onlineSnapshot = accepted
            onlineFailure = nil
        case .failure(let failure):
            if onlineSnapshot != nil { planner.forget(tool: .codex) }
            onlineSnapshot = nil
            onlineFailure = Self.onlineFailureText(failure)
        }
        let displayed = presentCodex(now: Date())
        if !displayed.sameContent(as: codex) { codex = displayed }
        evaluateNotifications(now: Date())
        scheduleResetRefresh()
    }

    private var claudeOnlineEnabled: Bool { settings.claudeEnabled && settings.claudeOnlineLimitsEnabled }

    private func presentClaude(now: Date) -> ToolState {
        // Before the first local index there is no summary to put limits into; wait for it.
        guard claudeOnlineEnabled, localClaude.summary != nil else { return localClaude }
        if let claudeOnlineSnapshot {
            return ClaudeOnlinePresentation.apply(claudeOnlineSnapshot, to: localClaude, now: now)
        }
        return ClaudeOnlinePresentation.fallback(localClaude, reason: claudeOnlineFailure ?? "Waiting for account query", now: now)
    }

    private func applyClaudeOnline(_ result: Result<ClaudeAccountLimits, ClaudeUsageFailure>) {
        switch result {
        case .success(let snapshot):
            // Alert baselines restart when the shown source switches from the hook cache.
            if claudeOnlineSnapshot == nil { planner.forget(tool: .claude) }
            claudeOnlineSnapshot = ClaudeOnlinePresentation.newer(snapshot, than: claudeOnlineSnapshot)
            claudeOnlineFailure = nil
        case .failure(let failure):
            if claudeOnlineSnapshot != nil { planner.forget(tool: .claude) }
            claudeOnlineSnapshot = nil
            claudeOnlineFailure = Self.claudeOnlineFailureText(failure)
        }
        log.info("claude online: \(Self.claudeOnlineOutcome(result), privacy: .public)")
        let displayed = presentClaude(now: Date())
        if !displayed.sameContent(as: claude) { claude = displayed }
        evaluateNotifications(now: Date())
        scheduleResetRefresh()
    }

    /// The Claude folder override from settings, passed to the usage child as `CLAUDE_CONFIG_DIR`.
    private static func claudeConfigOverride(_ settings: AppSettings) -> URL? {
        guard settings.normalized.claudeConfigDir != nil else { return nil }
        return LogRoots.resolve(settings).claudeProjects.deletingLastPathComponent()
    }

    /// A category for the diagnostics log; never values.
    private static func claudeOnlineOutcome(_ result: Result<ClaudeAccountLimits, ClaudeUsageFailure>) -> String {
        switch result {
        case .success(let limits): "ok, \(limits.windows.count) windows"
        case .failure(let failure): "failed, \(failure)"
        }
    }

    private static func claudeOnlineFailureText(_ failure: ClaudeUsageFailure) -> String {
        switch failure {
        case .disabled: "Claude online limit checks disabled"
        case .executableUnavailable: "Claude Code executable not found"
        case .launchFailed: "Claude Code could not start"
        case .subscriptionRequired: "Claude subscription login required"
        case .unavailable: "Claude Code could not read plan usage"
        case .unsupported: "Installed Claude Code does not support usage reads"
        case .timeout: "Account query timed out"
        case .disconnected: "Claude Code exited before answering"
        case .invalidResponse: "Account query returned invalid data"
        }
    }

    func stop() async {
        pollTimer?.invalidate()
        activeTimer?.invalidate()
        resetTimer?.invalidate()
        watcher = nil
        await online.shutdown()
        await claudeOnline.shutdown()
    }

    private static func onlineFailureText(_ failure: CodexAppServerFailure) -> String {
        switch failure {
        case .disabled: "Codex online limit checks disabled"
        case .executableUnavailable: "Codex executable not found"
        case .launchFailed: "Codex App Server could not start"
        case .loginRequired: "Codex login required"
        case .apiKeyAccount: "ChatGPT subscription login required"
        case .unsupportedMethod: "Installed Codex does not support account limits"
        case .timeout: "Account query timed out"
        case .rateLimited: "Account query rate limited"
        case .disconnected: "Codex App Server disconnected"
        case .invalidResponse: "Account query returned invalid data"
        }
    }

    /// Refreshes right after the earliest upcoming reset so the label flips to "reset" on time.
    private func scheduleResetRefresh() {
        resetTimer?.invalidate()
        func nextReset(_ state: ToolState) -> Date? {
            (state.summary?.limits ?? []).compactMap(\.resetsAt).filter { $0 > Date() }.min()
        }
        guard let next = states.compactMap(nextReset).min() else { return }
        // A window reset is worth an account query only for the tool that reset.
        let codexReset = nextReset(codex) == next
        let claudeReset = nextReset(claude) == next
        resetTimer = Timer.scheduledTimer(withTimeInterval: next.timeIntervalSinceNow + 1, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.refresh(reason: "reset")
                if codexReset { self?.online.refresh() }
                if claudeReset { self?.claudeOnline.refresh(.reset) }
            }
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
    private var codexActive = ActiveFileSet(window: 15 * 60, recentlyModified: 24 * 60 * 60)

    private let paths = TokenGlancePaths.default()
    private let fileSource = LocalFileSource()
    private var claudeRoot = ClaudeUsageProvider.defaultProjectsRoot()
    private var codexHome = CodexUsageProvider.defaultCodexHome()

    /// Records older than this are dropped from memory; it covers the weekly window and the
    /// 14-day history chart.
    static let retention = UsageHistory.retention

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
        codexActive = ActiveFileSet(window: 15 * 60, recentlyModified: 24 * 60 * 60)
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
        // A disabled tool's index is kept as it was, so turning the tool back on reads only what was
        // appended meanwhile instead of every log again.
        if enabled.claude {
            claudeIndex.update(files: claudeFiles, source: fileSource, onRead: reporter)
        }
        if enabled.codex {
            codexIndex.update(files: codexFiles, source: fileSource, onRead: reporter)
            var codexSizes: [URL: Int] = [:]
            var codexModified: [URL: Date] = [:]
            for url in codexFiles {
                guard let stat = fileSource.stat(url) else { continue }
                codexSizes[url] = stat.size
                codexModified[url] = stat.modified
            }
            codexActive.update(sizes: codexSizes, modified: codexModified, now: now)
        }
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
        var claude = ToolState.make(tool: .claude, snapshot: claudeSnapshot, hookStatus: hookStatus, aggregator: aggregator, now: now,
                                    isEnabled: enabled.claude)
        var codex = ToolState.make(tool: .codex, snapshot: codexSnapshot, hookStatus: nil, aggregator: aggregator, now: now,
                                   isEnabled: enabled.codex)
        // History from the records already in memory; coverage starts at the oldest log's creation.
        let calendar = Calendar.current
        claude.history = UsageHistory.daily(records: claudeSnapshot.records, coverageStart: oldestCreation(claudeFiles), now: now, calendar: calendar)
        codex.history = UsageHistory.daily(records: codexSnapshot.records, coverageStart: oldestCreation(codexFiles), now: now, calendar: calendar)
        return (claude, codex)
    }
}

extension UsageLoader {
    fileprivate func oldestCreation(_ files: [URL]) -> Date? {
        files.compactMap { LocalFileSource().stat($0)?.created }.min()
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

/// A URL shared with the usage child factory, which runs off the main actor.
final class LockedURL: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URL?

    var value: URL? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
