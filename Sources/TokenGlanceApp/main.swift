import AppKit
import TokenGlanceCore
import TokenGlanceText

// `--print-state` prints the label and tooltip once (no UI), for checks and scripting.
if CommandLine.arguments.contains("--print-state") {
    let settings = AppSettings.load(from: .standard)
    let loader = UsageLoader()
    loader.configure(roots: LogRoots.resolve(settings))
    let (claude, codex) = loader.load(now: Date(), enabled: (settings.claudeEnabled, settings.codexEnabled))
    let label = MenuBarLabel.make(states: [claude, codex], mode: settings.percentMode)
    let localizer = Localizer(AppLanguage(rawValue: settings.language) ?? .system)
    for line in label.lines { print("\(line.tool.rawValue)\t\(line.text)\t\(line.severity)") }
    print(localizer.tooltip(states: [claude, codex], mode: settings.percentMode, now: Date()))
    let stringsURL = Localizer.resourceBundleURL?.path ?? ""
    let stringsKind = stringsURL.isEmpty ? "missing" : stringsURL.contains(".app/Contents/Resources/") ? "app-resources" : "build-directory"
    print("strings\t\(localizer.languageCode) \(localizer.hasResources ? "loaded" : "missing") from \(stringsKind)")
    let hook = HookLocator.bundledHook
    let hookKind = hook == nil ? "none" : hook!.path.contains(".app/Contents/Resources/") ? "app-resources" : "build-directory"
    print("hook source\t\(hookKind)")
    exit(0)
}

// `--login-item status|on|off` manages "open at login" from the command line (prints the state only).
if let index = CommandLine.arguments.firstIndex(of: "--login-item") {
    let command = CommandLine.arguments.dropFirst(index + 1).first ?? "status"
    if command == "on" || command == "off", let error = LoginItem.set(command == "on") { print(error) }
    print("login item: \(LoginItem.isEnabled ? "enabled" : "disabled")\(LoginItem.needsApproval ? " (needs approval)" : "")")
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
