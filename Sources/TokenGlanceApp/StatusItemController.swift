import AppKit
import Observation
import os
import SwiftUI
import TokenGlanceCore
import TokenGlanceText

/// Owns the menu bar item: renders the label from the store and toggles the details panel.
@MainActor
final class StatusItemController: NSObject {
    private let store: UsageStore
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = MenuPanel()
    private var lastLabel: MenuBarLabel?
    private var lastTooltip: String?
    private var settingsWindow: SettingsWindowController?
    private var historyWindow: HistoryWindowController?
    private let log = Logger(subsystem: "io.github.yim0327.token-glance", category: "label")

    init(store: UsageStore) {
        self.store = store
        super.init()
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePanel)
        }
        settingsWindow = SettingsWindowController(store: store)
        historyWindow = HistoryWindowController(store: store)
        render()
        // The tooltip's "resets in …" is time-based; recompute it each minute (the image is only
        // redrawn when the label actually changes).
        let ticker = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        ticker.tolerance = 10
        RunLoop.main.add(ticker, forMode: .common)
    }

    /// Re-renders whenever an observed store property changes.
    private func render() {
        let (label, tooltip) = withObservationTracking {
            let label = MenuBarLabel.make(states: store.states, mode: store.percentMode)
            let tooltip = store.localizer.tooltip(states: store.states, mode: store.percentMode, now: Date())
            return (label, tooltip)
        } onChange: { [weak self] in
            Task { @MainActor in self?.render() }
        }
        guard let button = item.button else { return }
        if label != lastLabel {
            button.image = LabelImage.make(label)
            lastLabel = label
            log.info("label redrawn")
        }
        if tooltip != lastTooltip {
            lastTooltip = tooltip
            button.toolTip = tooltip
            button.setAccessibilityLabel(store.localizer("a11y.statusItem", tooltip))
        }
    }

    @objc private func togglePanel() {
        guard let button = item.button else { return }
        if panel.isShown {
            panel.close()
        } else {
            panel.show(makePanelContent(), below: button)
        }
    }

    /// The panel's SwiftUI view is built on each show and released on close: hidden, it would
    /// otherwise keep its once-a-second countdowns running and re-lay itself out (measured at
    /// about 2% CPU with the popover it replaced closed).
    private func makePanelContent() -> NSHostingController<PopoverView> {
        let host = NSHostingController(rootView: PopoverView(
            store: store,
            openSettings: { [weak self] in
                self?.panel.close()
                self?.settingsWindow?.show()
            },
            openHistory: { [weak self] in
                self?.panel.close()
                self?.historyWindow?.show()
            }
        ))
        // Without this the panel keeps its initial size and clips SwiftUI content that is taller,
        // e.g. once data arrives after launch.
        host.sizingOptions = [.preferredContentSize]
        return host
    }
}

#if TG_STRESS
/// Measurement builds only (`swift build -Xswiftc -DTG_STRESS`, never in releases): opens and
/// closes the details panel, settings and history windows through their normal code paths, so
/// repeated use can be measured without UI automation. See docs/perf.md.
///
/// `plan` is a comma-separated list of `kind:count` (kind: panel, settings, history). After every
/// 10th cycle and at the end of each step the driver logs a checkpoint and rests `rest` seconds.
extension StatusItemController {
    func runStressPlan(_ plan: String, rest: Double, initialRest: Double, finalRest: Double) {
        let log = Logger(subsystem: "io.github.yim0327.token-glance", category: "stress")
        let steps = plan.split(separator: ",").compactMap { part -> (String, Int)? in
            let pair = part.split(separator: ":")
            guard pair.count == 2, let count = Int(pair[1]), count > 0 else { return nil }
            return (String(pair[0]), count)
        }
        func checkpoint(_ name: String) {
            let windows = NSApp.windows
            log.notice("stress checkpoint \(name, privacy: .public) windows \(windows.count, privacy: .public) visible \(windows.filter(\.isVisible).count, privacy: .public)")
        }
        Task { @MainActor in
            checkpoint("start")
            try? await Task.sleep(for: .seconds(initialRest))
            checkpoint("baseline")
            for (kind, count) in steps {
                for cycle in 1...count {
                    stressOpen(kind)
                    try? await Task.sleep(for: .seconds(1.5))
                    stressClose(kind)
                    try? await Task.sleep(for: .seconds(1))
                    if cycle % 10 == 0 || cycle == count {
                        checkpoint("\(kind) \(cycle)/\(count) closed")
                        try? await Task.sleep(for: .seconds(rest))
                        checkpoint("\(kind) \(cycle)/\(count) rested")
                    }
                }
            }
            try? await Task.sleep(for: .seconds(finalRest))
            checkpoint("done")
        }
    }

    private func stressOpen(_ kind: String) {
        switch kind {
        case "panel": if !panel.isShown { togglePanel() }
        case "settings": settingsWindow?.show()
        case "history": historyWindow?.show()
        default: break
        }
    }

    private func stressClose(_ kind: String) {
        switch kind {
        case "panel": panel.close()
        case "settings": settingsWindow?.closeForStress()
        case "history": historyWindow?.closeForStress()
        default: break
        }
    }
}
#endif
