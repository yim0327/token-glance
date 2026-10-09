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

    init(store: UsageStore) {
        self.store = store
        super.init()
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePopover)
        }
        popover.behavior = .transient
        let host = NSHostingController(rootView: PopoverView(store: store))
        // Without this the popover keeps its initial size and clips SwiftUI content that is taller,
        // e.g. once data arrives after launch.
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        render()
    }

    /// Re-renders whenever an observed store property changes.
    private func render() {
        let label = withObservationTracking {
            MenuBarLabel.make(states: store.states, mode: store.percentMode, now: Date())
        } onChange: { [weak self] in
            Task { @MainActor in self?.render() }
        }
        guard let button = item.button else { return }
        button.image = LabelImage.make(label)
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
