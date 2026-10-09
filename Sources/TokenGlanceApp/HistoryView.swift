import AppKit
import Charts
import SwiftUI
import TokenGlanceCore
import TokenGlanceText

/// Hosts the 14-day history chart in its own window, so the popover stays light.
@MainActor
final class HistoryWindowController {
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
            window.center()
            self.window = window
        }
        window?.title = store.localizer("history.title")
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Daily tokens per tool for the last 14 days, from the totals already kept in memory.
struct HistoryView: View {
    let store: UsageStore

    private struct Bar: Identifiable {
        let id: String
        let tool: String
        let day: Date
        let tokens: Int
    }

    var body: some View {
        let l10n = store.localizer
        let tools = store.states.filter(\.isEnabled)
        let bars = tools.flatMap { state in
            state.history.compactMap { day -> Bar? in
                guard let usage = day.usage else { return nil }
                return Bar(id: "\(state.tool.rawValue)-\(day.day.timeIntervalSince1970)", tool: l10n.toolName(state.tool),
                           day: day.day, tokens: usage.total)
            }
        }
        // Days that no enabled tool's logs cover.
        let days = tools.first?.history.map(\.day) ?? []
        let uncovered = days.filter { day in tools.allSatisfy { $0.history.first { $0.day == day }?.usage == nil } }

        VStack(alignment: .leading, spacing: 10) {
            Text(l10n("history.heading")).font(.headline)
            Chart {
                ForEach(uncovered, id: \.self) { day in
                    RectangleMark(x: .value(l10n("history.day"), day, unit: .day))
                        .foregroundStyle(.gray.opacity(0.12))
                }
                ForEach(bars) { bar in
                    BarMark(x: .value(l10n("history.day"), bar.day, unit: .day),
                            y: .value(l10n("history.tokens"), bar.tokens))
                        .foregroundStyle(by: .value("Tool", bar.tool))
                        .position(by: .value("Tool", bar.tool))
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 2)) { value in
                    AxisGridLine()
                    AxisValueLabel { if let date = value.as(Date.self) { Text(l10n.dayLabel(date)) } }
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel { if let tokens = value.as(Int.self) { Text(l10n.tokens(tokens)) } }
                }
            }
            .frame(height: 220)
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
    }
}
