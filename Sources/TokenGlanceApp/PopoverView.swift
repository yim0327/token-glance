import SwiftUI
import TokenGlanceCore

/// Popover content. Countdowns tick with a 1-second `TimelineView` computed from dates,
/// so they stay exact while the popover is open and never re-read files.
struct PopoverView: View {
    let store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolSection(state: store.claude)
            Divider()
            ToolSection(state: store.codex)
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    private var footer: some View {
        HStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(freshness(now: context.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh") { store.refresh(force: true) }
                .disabled(store.isRefreshing)
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }

    private func freshness(now: Date) -> String {
        guard let refreshed = store.states.compactMap(\.refreshedAt).max() else { return String(localized: "Loading…") }
        return String(localized: "Updated \(DisplayFormat.relativeAge(of: refreshed, now: now))")
    }
}

private struct ToolSection: View {
    let state: ToolState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(state.tool == .claude ? "Claude Code" : "Codex").font(.headline)
                if state.hookNeedsAttention {
                    Label(hookWarning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
            if let reason = state.unavailableReason, state.session == nil, state.weekly == nil {
                Text(reason.message).font(.callout).foregroundStyle(.secondary)
            }
            if let session = state.session { LimitRow(title: String(localized: "5-hour"), status: session) }
            if let weekly = state.weekly { LimitRow(title: String(localized: "Weekly"), status: weekly) }
            if let summary = state.summary { TokenTable(summary: summary) }
        }
    }

    private var hookWarning: String {
        switch state.hookStatus {
        case .overwritten: String(localized: "Hook replaced — reinstall in Settings (coming in M4)")
        case .notInstalled: String(localized: "Statusline hook not installed")
        case .hookMissing: String(localized: "Hook binary missing")
        case .settingsUnreadable: String(localized: "settings.json unreadable")
        case .installed, nil: ""
        }
    }
}

private struct LimitRow: View {
    let title: String
    let status: LimitStatus

    var body: some View {
        let reading = DisplayFormat.reading(status)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Text("\(reading.used)% used / \(reading.left)% left")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(tint)
            }
            ProgressView(value: Double(reading.used), total: 100).tint(tint)
            resetLine.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var resetLine: some View {
        if let resetsAt = status.resetsAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("Resets \(resetsAt.formatted(date: .abbreviated, time: .shortened)) · in \(DisplayFormat.clockCountdown(to: resetsAt, now: context.date))")
            }
        } else {
            Text("Window reset — waiting for new data")
        }
    }

    private var tint: Color {
        switch DisplayFormat.severity(status) {
        case .warning: .orange
        case .critical: .red
        case .normal, .unavailable: .accentColor
        }
    }
}

private struct TokenTable: View {
    let summary: UsageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 2) {
                GridRow {
                    Text("Tokens").gridColumnAlignment(.leading)
                    Text("Input"); Text("Output"); Text("Cache")
                }
                .foregroundStyle(.secondary)
                row(String(localized: "Today"), summary.today)
                row(String(localized: "This week"), summary.week)
            }
            .font(.caption.monospacedDigit())
            if !topModels.isEmpty {
                Text("Top models this week: " + topModels.map { "\($0.0) \(DisplayFormat.tokens($0.1.total))" }.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func row(_ title: String, _ usage: TokenUsage) -> some View {
        GridRow {
            Text(title).gridColumnAlignment(.leading)
            Text(DisplayFormat.tokens(usage.input))
            Text(DisplayFormat.tokens(usage.output))
            Text(DisplayFormat.tokens(usage.cacheRead + usage.cacheWrite))
        }
    }

    private var topModels: [(String, TokenUsage)] {
        summary.weekByModel.sorted { $0.value.total > $1.value.total }.prefix(3).map { ($0.key, $0.value) }
    }
}
