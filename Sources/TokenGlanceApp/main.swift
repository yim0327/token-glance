import AppKit
import TokenGlanceCore

// `--print-state` prints the label and tooltip once (no UI), for checks and scripting.
if CommandLine.arguments.contains("--print-state") {
    let (claude, codex) = UsageLoader().load(now: Date())
    let label = MenuBarLabel.make(states: [claude, codex], mode: .remaining, now: Date())
    for line in label.lines { print("\(line.tool.rawValue)\t\(line.text)\t\(line.severity)") }
    print(label.tooltip)
    let hook = HookLocator.bundledHook
    let hookKind = hook == nil ? "none" : hook!.path.contains(".app/Contents/Resources/") ? "app-resources" : "build-directory"
    print("hook source\t\(hookKind)")
    exit(0)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: UsageStore?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = UsageStore()
        self.store = store
        statusItem = StatusItemController(store: store)
        store.start()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
