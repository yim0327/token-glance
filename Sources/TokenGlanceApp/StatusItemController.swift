import AppKit
import Observation
import SwiftUI
import TokenGlanceCore

/// Owns the menu bar item: renders the label from the store and toggles the popover.
@MainActor
final class StatusItemController: NSObject {
    private let store: UsageStore
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var lastLabel: MenuBarLabel?
    private var settingsWindow: SettingsWindowController?

    init(store: UsageStore) {
        self.store = store
        super.init()
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePopover)
        }
        popover.behavior = .transient
        let settingsWindow = SettingsWindowController(store: store)
        self.settingsWindow = settingsWindow
        let host = NSHostingController(rootView: PopoverView(store: store, openSettings: { [weak self] in
            self?.popover.performClose(nil)
            settingsWindow.show()
        }))
        // Without this the popover keeps its initial size and clips SwiftUI content that is taller,
        // e.g. once data arrives after launch.
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
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
        let label = withObservationTracking {
            MenuBarLabel.make(states: store.states, mode: store.percentMode, now: Date())
        } onChange: { [weak self] in
            Task { @MainActor in self?.render() }
        }
        guard let button = item.button, label != lastLabel else { return }
        if label.lines != lastLabel?.lines { button.image = LabelImage.make(label) }
        lastLabel = label
        button.toolTip = label.tooltip
        button.setAccessibilityLabel("Token Glance: " + label.tooltip)
    }

    @objc private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
