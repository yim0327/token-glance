import AppKit
import Observation
import os
import SwiftUI
import TokenGlanceCore
import TokenGlanceText

/// Owns the menu bar item: renders the label from the store and toggles the popover.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let store: UsageStore
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
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
            button.action = #selector(togglePopover)
        }
        popover.behavior = .transient
        popover.delegate = self
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

    @objc private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.contentViewController = makePopoverContent()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// The popover's SwiftUI view is built on each show and released on close: a hidden popover
    /// otherwise keeps its once-a-second countdowns running and re-lays itself out (measured at
    /// about 2% CPU with the popover closed).
    private func makePopoverContent() -> NSViewController {
        let host = NSHostingController(rootView: PopoverView(
            store: store,
            openSettings: { [weak self] in
                self?.popover.performClose(nil)
                self?.settingsWindow?.show()
            },
            openHistory: { [weak self] in
                self?.popover.performClose(nil)
                self?.historyWindow?.show()
            }
        ))
        // Without this the popover keeps its initial size and clips SwiftUI content that is taller,
        // e.g. once data arrives after launch.
        host.sizingOptions = [.preferredContentSize]
        return host
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }
}
