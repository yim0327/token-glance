import AppKit
import os
import SwiftUI
import TokenGlanceCore
import TokenGlanceText

/// Hosts the 14-day history chart in its own window, so the menu panel stays light. The window is
/// released when closed.
@MainActor
final class HistoryWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let store: UsageStore

    init(store: UsageStore) {
        self.store = store
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: HistoryView(store: store))
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.title = store.localizer("history.title")
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        window = nil
    }
}

/// Daily tokens per tool for the last 14 days, from the totals already kept in memory.
///
/// The chart reads a snapshot of the daily totals taken when the window opens and checked every
/// minute after, not the live store: tool states change every few seconds while the CLIs are in
/// use, and redrawing the chart that often cost several percent CPU for no visible benefit at
/// daily granularity. The snapshot is replaced only when a daily total actually changed.
struct HistoryView: View {
    let store: UsageStore
    @State private var tools: [ToolHistory] = []

    static let snapshotInterval: Duration = .seconds(60)
    private static let log = Logger(subsystem: "io.github.yim0327.token-glance", category: "history")
    private static let palette: [Color] = [.blue, .green]

    private struct ToolHistory: Equatable {
        let tool: Tool
        let history: [DailyUsage]
    }

    var body: some View {
        let l10n = store.localizer
        // Days that no enabled tool's logs cover.
        let days = tools.first?.history.map(\.day) ?? []
        let uncovered = Set(days.filter { day in tools.allSatisfy { $0.history.first { $0.day == day }?.usage == nil } })

        VStack(alignment: .leading, spacing: 10) {
            Text(l10n("history.heading")).font(.headline)
            DailyBarChart(days: days, uncovered: uncovered, series: tools.enumerated().map { index, tool in
                DailyBarChart.Series(name: l10n.toolName(tool.tool), color: Self.palette[index % Self.palette.count],
                                     values: days.map { day in tool.history.first { $0.day == day }?.usage?.total })
            }, l10n: l10n)
            ForEach(tools.filter { $0.history.allSatisfy { $0.usage == nil } }, id: \.tool) { state in
                Text(l10n("history.noLogsFor", l10n.toolName(state.tool))).font(.caption).foregroundStyle(.secondary)
            }
            if !uncovered.isEmpty {
                Label(l10n("history.noLogs"), systemImage: "square.fill")
                    .font(.caption).foregroundStyle(.gray)
            }
            Text(l10n("history.caption"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 560)
        .environment(\.locale, l10n.locale)
        .task {
            while !Task.isCancelled {
                let snapshot = store.states.filter(\.isEnabled).map { ToolHistory(tool: $0.tool, history: $0.history) }
                if snapshot != tools {
                    tools = snapshot
                    Self.log.info("history snapshot replaced")
                }
                try? await Task.sleep(for: Self.snapshotInterval)
            }
        }
    }
}

/// Grouped daily bars drawn with plain SwiftUI shapes.
///
/// Swift Charts was used first, but every redraw of a chart (including window focus changes)
/// briefly allocated about 100 MB of graphics memory, measured both in the app and in an isolated
/// probe; the same bars as shapes stay flat. Days with no logs get a gray background, not a bar.
private struct DailyBarChart: View {
    struct Series {
        let name: String
        let color: Color
        /// One value per day; `nil` means no logs that day.
        let values: [Int?]
    }

    let days: [Date]
    let uncovered: Set<Date>
    let series: [Series]
    let l10n: Localizer

    private let plotHeight: CGFloat = 200

    var body: some View {
        let maxValue = series.flatMap { $0.values.compactMap { $0 } }.max() ?? 0
        let ticks = AxisTicks.make(maxValue: maxValue)
        let top = CGFloat(max(ticks.last ?? 0, 1))
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                // Labels and grid lines are pinned to the bottom of fixed-size frames and moved up
                // by their value's height (labels sit in zero-height frames, so they are centered).
                // The axis column is as wide as its longest label.
                Text(ticks.map { l10n.tokens($0) }.max { $0.count < $1.count } ?? "")
                    .font(.caption2.monospacedDigit())
                    .hidden()
                    .frame(height: plotHeight)
                    .overlay(alignment: .bottomTrailing) {
                        ZStack(alignment: .bottomTrailing) {
                            ForEach(ticks, id: \.self) { tick in
                                Text(l10n.tokens(tick)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                    .fixedSize()
                                    .frame(height: 0)
                                    .offset(y: -CGFloat(tick) / top * plotHeight)
                            }
                        }
                    }
                VStack(spacing: 4) {
                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(days.indices, id: \.self) { index in
                            dayColumn(index, top: top)
                        }
                    }
                    .frame(height: plotHeight)
                    .background(alignment: .bottom) {
                        ZStack(alignment: .bottom) {
                            ForEach(ticks, id: \.self) { tick in
                                Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 1)
                                    .offset(y: -CGFloat(tick) / top * plotHeight)
                            }
                        }
                    }
                    HStack(spacing: 0) {
                        ForEach(days.indices, id: \.self) { index in
                            Text(index % 2 == 0 ? l10n.dayLabel(days[index]) : " ")
                                .font(.caption2).foregroundStyle(.secondary)
                                .fixedSize()
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            HStack(spacing: 12) {
                ForEach(series.indices, id: \.self) { index in
                    Label {
                        Text(series[index].name)
                    } icon: {
                        Circle().fill(series[index].color).frame(width: 8, height: 8)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func dayColumn(_ index: Int, top: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            Rectangle().fill(uncovered.contains(days[index]) ? Color.gray.opacity(0.12) : Color.clear)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(series.indices, id: \.self) { item in
                    let value = series[item].values[index] ?? 0
                    Rectangle().fill(series[item].color)
                        .frame(height: value > 0 ? max(1, CGFloat(value) / top * plotHeight) : 0)
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(index))
    }

    private func accessibilityText(_ index: Int) -> String {
        let values = series.map { item in
            item.values[index].map { "\(item.name) \(l10n.tokens($0))" } ?? "\(item.name) \(l10n("history.noLogs"))"
        }
        return ([l10n.dayLabel(days[index])] + values).joined(separator: ", ")
    }
}
