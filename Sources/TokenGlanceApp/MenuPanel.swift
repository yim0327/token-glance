import AppKit
import SwiftUI

/// The window shown under the menu bar item, used instead of `NSPopover`.
///
/// Showing an `NSPopover` briefly allocated 115–150 MB of graphics memory each time, even with
/// AppKit-only content (measured in an isolated probe); a borderless panel with the same blurred
/// background stayed under 20 MB. The panel closes on Esc, on a click anywhere outside it, or when
/// the item is clicked again. Its content is released on close.
@MainActor
final class MenuPanel {
    private let panel = Panel()
    private var content: NSViewController?
    private var measure: (() -> CGSize)?
    private var sizeObservation: NSKeyValueObservation?
    private var monitors: [Any] = []
    private weak var button: NSStatusBarButton?

    var isShown: Bool { panel.isVisible }

    init() {
        panel.onCancel = { [weak self] in self?.close() }
    }

    func show<Content: View>(_ host: NSHostingController<Content>, below button: NSStatusBarButton) {
        close()
        self.button = button
        content = host
        measure = { [unowned host] in host.sizeThatFits(in: CGSize(width: 10_000, height: 10_000)) }

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        let dim = DarkDimView()
        dim.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(dim)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(host.view)
        NSLayoutConstraint.activate([
            dim.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            dim.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            dim.topAnchor.constraint(equalTo: background.topAnchor),
            dim.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: background.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background

        // Follow the content's size as data arrives (the top edge stays under the menu bar).
        sizeObservation = host.observe(\.preferredContentSize) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        layout()
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
        installMonitors()
    }

    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        sizeObservation = nil
        guard content != nil else { return }
        panel.orderOut(nil)
        panel.contentView = nil
        content = nil
        measure = nil
        button?.highlight(false)
    }

    private func layout() {
        guard let content, let button, let buttonWindow = button.window else { return }
        var size = content.preferredContentSize
        if size.width < 1 || size.height < 1, let measure { size = measure() }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? anchor
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let top = anchor.minY - 4
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
        panel.invalidateShadow()
    }

    private func installMonitors() {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // Clicks in other apps (including the desktop and other menu bar items).
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) {
            monitors.append(global)
        }
        // Clicks in this app's other windows. Clicks on the item itself are left to its action.
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self.panel, event.window !== self.button?.window { self.close() }
            }
            return event
        }) {
            monitors.append(local)
        }
    }
}

/// In dark mode, darkens the translucent background: over a bright desktop it was mid-gray and
/// colored text in the panel was hard to read. Clear in light mode; follows appearance changes.
private final class DarkDimView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.backgroundColor = dark ? NSColor.black.withAlphaComponent(0.45).cgColor : NSColor.clear.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Borderless, non-activating, and able to become key so buttons and Esc work without
/// bringing the app forward.
private final class Panel: NSPanel {
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
