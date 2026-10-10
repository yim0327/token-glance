import SwiftUI
import TokenGlanceCore
import TokenGlanceText

/// Popover content. Countdowns tick with a 1-second `TimelineView` computed from dates,
/// so they stay exact while the popover is open and never re-read files.
struct PopoverView: View {
    let store: UsageStore
    let openSettings: () -> Void
    let openHistory: () -> Void

    var body: some View {
        let l10n = store.localizer
        VStack(alignment: .leading, spacing: 12) {
            if let progress = store.scanProgress {
                ProgressView(value: progress) { Text(l10n("popover.indexing")).font(.caption) }
            }
            ForEach(store.states.filter(\.isEnabled), id: \.tool) { state in
                ToolSection(state: state, mode: store.percentMode, l10n: l10n)
                Divider()
            }
            footer(l10n)
        }
        .padding(14)
        .frame(width: 340)
        .environment(\.locale, l10n.locale)
    }

    private func footer(_ l10n: Localizer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(freshness(l10n, now: context.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button(l10n("popover.history"), action: openHistory)
                Button(l10n("popover.settings"), action: openSettings)
                Spacer()
                Button(l10n("popover.refresh")) { store.refreshNow() }
                    .disabled(store.isRefreshing)
                Button(l10n("popover.quit")) { NSApplication.shared.terminate(nil) }
            }
        }
    }

    private func freshness(_ l10n: Localizer, now: Date) -> String {
        guard let refreshed = store.lastRefresh else { return l10n("popover.loading") }
        return l10n("popover.updated", l10n.relativeAge(of: refreshed, now: now))
    }
}

private struct ToolSection: View {
    let state: ToolState
    let mode: PercentMode
    let l10n: Localizer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if ServiceMarkPath.path(for: state.tool) != nil {
                    ServiceMarkShape(tool: state.tool)
                        .frame(width: 15, height: 15)
                        .accessibilityHidden(true) // the name next to it is the label
                }
                Text(state.tool == .claude ? l10n("tool.claudeCode") : l10n("tool.codex")).font(.headline)
                if state.hookNeedsAttention {
                    Label(hookWarning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(PanelColor.warning)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            if state.tool == .codex && !state.onlineBucketRows.isEmpty {
                ForEach(Array(state.onlineBucketRows.enumerated()), id: \.offset) { entry in
                    Text(l10n("popover.online.bucket", entry.offset + 1)).font(.subheadline.weight(.semibold))
                    if let session = entry.element.session {
                        LimitRow(title: l10n.windowName(.session), status: session, mode: mode, l10n: l10n)
                    }
                    if let weekly = entry.element.weekly {
                        LimitRow(title: l10n.windowName(.weekly), status: weekly, mode: mode, l10n: l10n)
                    }
                    ForEach(Array(entry.element.otherWindows.enumerated()), id: \.offset) { window in
                        OtherWindowRow(window: window.element, mode: mode, l10n: l10n)
                    }
                }
            } else {
                // Both windows keep their rows; an unknown value is a gray bar with "--/--".
                LimitRow(title: l10n.windowName(.session), status: state.session, missingReason: missing, mode: mode, l10n: l10n)
                LimitRow(title: l10n.windowName(.weekly), status: state.weekly, missingReason: missing, mode: mode, l10n: l10n)
            }
            if state.tool == .codex || state.limitSource != nil {
                if let source = state.limitSource {
                    // Source and observation time on their own lines: side by side, a long
                    // English date was truncated or wrapped into a narrow column.
                    VStack(alignment: .leading, spacing: 1) {
                        Text(l10n("popover.online.source", sourceName(source)))
                        if let observedAt = state.limitObservedAt {
                            Text(l10n("popover.online.observed", l10n.resetTime(observedAt)))
                        }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if !state.otherSourceLimits.isEmpty {
                    Text(hookComparison).font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let failure = state.onlineFailure {
                    Text(l10n("popover.online.failure", onlineFailure(failure))
                         + (state.tool == .codex ? " " + l10n("popover.online.localIdentityUnverified") : ""))
                        .font(.caption).foregroundStyle(PanelColor.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // An empty token table is left out while a limit value is unknown.
            if let summary = state.summary, missing == nil || summary.hasTokens {
                TokenTable(summary: summary, l10n: l10n)
            }
        }
    }

    /// Why a limit row has no value; shown under that row's gray bar.
    private var missing: String? {
        state.onlineBucketRows.isEmpty ? l10n.missingLimitsMessage(state) : nil
    }

    private var hookWarning: String {
        switch state.hookStatus {
        case .overwritten: l10n("popover.hook.overwritten")
        case .notInstalled: l10n("popover.hook.notInstalled")
        case .hookMissing: l10n("popover.hook.missing")
        case .settingsUnreadable: l10n("popover.hook.settingsUnreadable")
        case .installed, nil: ""
        }
    }

    private func sourceName(_ source: String) -> String {
        switch source {
        case "Account query": l10n("popover.online.accountQuery")
        case "Hook cache": l10n("popover.online.hookCache")
        default: l10n("popover.online.localLogs")
        }
    }

    /// The hook cache values that differ from the account query shown above them.
    private var hookComparison: String {
        let values = state.otherSourceLimits.map {
            l10n("popover.online.hookValue", l10n.windowName($0.kind), Int($0.usedPercent.rounded()))
        }.joined(separator: " · ")
        let observed = state.otherSourceLimits.map(\.observedAt).max().map(l10n.resetTime) ?? "--"
        return l10n("popover.online.hookDiffers", values, observed)
    }

    private func onlineFailure(_ message: String) -> String {
        let key: String
        switch message {
        case "Account query result is out of date": key = "popover.online.outdated"
        case "Claude online limit checks disabled": key = "popover.online.claude.disabled"
        case "Claude Code executable not found": key = "popover.online.claude.executableUnavailable"
        case "Claude Code could not start": key = "popover.online.claude.launchFailed"
        case "Claude subscription login required": key = "popover.online.claude.subscriptionRequired"
        case "Claude Code could not read plan usage": key = "popover.online.claude.unavailable"
        case "Installed Claude Code does not support usage reads": key = "popover.online.claude.unsupported"
        case "Claude Code exited before answering": key = "popover.online.claude.disconnected"
        case "Waiting for account query": key = "popover.online.waiting"
        case "Account query returned no limit windows": key = "popover.online.noWindows"
        case "Codex login required": key = "popover.online.loginRequired"
        case "ChatGPT subscription login required": key = "popover.online.subscriptionRequired"
        case "Installed Codex does not support account limits": key = "popover.online.unsupported"
        case "Account query timed out": key = "popover.online.timeout"
        case "Account query rate limited": key = "popover.online.rateLimited"
        case "Codex App Server disconnected": key = "popover.online.disconnected"
        case "Account query returned invalid data": key = "popover.online.invalidResponse"
        case "Codex executable not found": key = "popover.online.executableUnavailable"
        case "Codex App Server could not start": key = "popover.online.launchFailed"
        case "Codex online limit checks disabled": key = "popover.online.disabled"
        default: return message
        }
        return l10n(key)
    }
}

private struct LimitRow: View {
    let title: String
    let status: LimitStatus?
    var missingReason: String?
    let mode: PercentMode
    let l10n: Localizer

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Text(status.map { l10n("popover.usedLeft", DisplayFormat.reading($0).used, DisplayFormat.reading($0).left) } ?? "--/--")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(tint)
            }
            // The bar fills like the menu bar number reads: what is left, or what is used.
            ProgressView(value: Double(DisplayFormat.gaugePercent(status, mode: mode)), total: 100).tint(tint)
            if let status {
                resetLine(status).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            } else if let missingReason {
                Text(missingReason).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func resetLine(_ status: LimitStatus) -> some View {
        if let resetsAt = status.resetsAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(l10n("popover.resets", l10n.resetTime(resetsAt), l10n.clockCountdown(to: resetsAt, now: context.date)))
            }
        } else if status.isReset {
            Text(l10n("popover.windowReset"))
        } else {
            Text(l10n("popover.online.resetUnavailable"))
        }
    }

    private var tint: Color {
        switch DisplayFormat.severity(status) {
        case .warning: PanelColor.warning
        case .critical: PanelColor.critical
        case .normal: PanelColor.normal
        case .unavailable: .secondary
        }
    }
}

private struct OtherWindowRow: View {
    let window: OnlineWindowRow
    let mode: PercentMode
    let l10n: Localizer

    var body: some View {
        let used = min(max(window.usedPercent, 0), 100)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(windowTitle).font(.subheadline.weight(.medium))
                Spacer()
                Text(l10n("popover.usedLeft", Int(used.rounded()), Int((100 - used).rounded())))
                    .font(.subheadline.monospacedDigit())
            }
            ProgressView(value: Double(DisplayFormat.gaugePercent(usedPercent: window.usedPercent, mode: mode)), total: 100)
            if let resetsAt = window.resetsAt {
                Text(l10n("popover.online.resets", l10n.resetTime(resetsAt)))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(l10n("popover.online.resetUnavailable"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var windowTitle: String {
        if let minutes = Int(window.title.replacingOccurrences(of: "-minute", with: "")) {
            return l10n("popover.online.windowMinutes", minutes)
        }
        return l10n("popover.online.unknownWindow")
    }
}

private struct TokenTable: View {
    let summary: UsageSummary
    let l10n: Localizer

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 2) {
                GridRow {
                    Text(l10n("tokens.header")).gridColumnAlignment(.leading)
                    Text(l10n("tokens.input")); Text(l10n("tokens.output")); Text(l10n("tokens.cache"))
                }
                .foregroundStyle(.secondary)
                row(l10n("tokens.today"), summary.today)
                row(l10n("tokens.thisWeek"), summary.week)
            }
            .font(.caption.monospacedDigit())
            if !topModels.isEmpty {
                Text(l10n("tokens.topModels", topModels.map { "\($0.0) \(l10n.tokens($0.1.total))" }.joined(separator: ", ")))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ title: String, _ usage: TokenUsage) -> some View {
        GridRow {
            Text(title).gridColumnAlignment(.leading)
            Text(l10n.tokens(usage.input))
            Text(l10n.tokens(usage.output))
            Text(l10n.tokens(usage.cacheRead + usage.cacheWrite))
        }
    }

    private var topModels: [(String, TokenUsage)] {
        summary.weekByModel.sorted { $0.value.total > $1.value.total }.prefix(3).map { ($0.key, $0.value) }
    }
}

/// Text and gauge colors in the details panel. Light mode uses the system colors; dark mode uses
/// lighter tints, because the panel's translucent background can be mid-gray over a bright desktop
/// and the system blue and red fell to about 1.5:1 contrast there (MenuPanel also darkens it).
enum PanelColor {
    static let normal = dynamic(light: .controlAccentColor, dark: NSColor(srgbRed: 120 / 255, green: 185 / 255, blue: 1, alpha: 1))
    static let warning = dynamic(light: .systemOrange, dark: NSColor(srgbRed: 1, green: 185 / 255, blue: 80 / 255, alpha: 1))
    static let critical = dynamic(light: .systemRed, dark: NSColor(srgbRed: 1, green: 135 / 255, blue: 125 / 255, alpha: 1))

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}
