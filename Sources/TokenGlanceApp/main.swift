import AppKit
import TokenGlanceCore

// `--print-state` prints the label and tooltip once (no UI), for checks and scripting.
if CommandLine.arguments.contains("--print-state") {
    let settings = AppSettings.load(from: .standard)
    let loader = UsageLoader()
    loader.configure(roots: LogRoots.resolve(settings))
    let (claude, codex) = loader.load(now: Date(), enabled: (settings.claudeEnabled, settings.codexEnabled))
    let label = MenuBarLabel.make(states: [claude, codex], mode: settings.percentMode, now: Date())
    for line in label.lines { print("\(line.tool.rawValue)\t\(line.text)\t\(line.severity)") }
    print(label.tooltip)
    let hook = HookLocator.bundledHook
    let hookKind = hook == nil ? "none" : hook!.path.contains(".app/Contents/Resources/") ? "app-resources" : "build-directory"
    print("hook source\t\(hookKind)")
    exit(0)
}

// `--login-item status|on|off` manages "open at login" from the command line (prints the state only).
if let index = CommandLine.arguments.firstIndex(of: "--login-item") {
    let command = CommandLine.arguments.dropFirst(index + 1).first ?? "status"
    if command == "on" || command == "off", let error = LoginItem.set(command == "on") { print(error) }
    print("login item: \(LoginItem.isEnabled ? "enabled" : "disabled")\(LoginItem.note.map { " (\($0))" } ?? "")")
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
