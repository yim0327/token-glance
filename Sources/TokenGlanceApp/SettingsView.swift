import AppKit
import SwiftUI
import TokenGlanceCore

/// Hosts `SettingsView` in a regular window (the app has no Dock icon or main menu).
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let store: UsageStore

    init(store: UsageStore) {
        self.store = store
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(store: store))
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.title = String(localized: "Token Glance Settings")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    let store: UsageStore
    @State private var claudeDir = ""
    @State private var codexDir = ""

    var body: some View {
        Form {
            Section("Menu bar") {
                Picker("Show", selection: binding(\.percentMode)) {
                    Text("Remaining %").tag(PercentMode.remaining)
                    Text("Used %").tag(PercentMode.used)
                }
                .pickerStyle(.radioGroup)
                Toggle("Claude Code", isOn: binding(\.claudeEnabled))
                    .disabled(store.settings.claudeEnabled && !store.settings.codexEnabled)
                Toggle("Codex", isOn: binding(\.codexEnabled))
                    .disabled(store.settings.codexEnabled && !store.settings.claudeEnabled)
                Text("With one tool enabled the label uses a single line.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LoginSection()
            HookSection(store: store)
            Section("Log folders") {
                PathField(title: "Claude config folder", placeholder: "Default: $CLAUDE_CONFIG_DIR or ~/.claude",
                          text: $claudeDir, subfolder: "projects")
                PathField(title: "Codex home", placeholder: "Default: $CODEX_HOME or ~/.codex",
                          text: $codexDir, subfolder: "sessions")
                HStack {
                    Spacer()
                    Button("Apply folders") { applyFolders() }
                        .disabled(!canApplyFolders)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear {
            claudeDir = store.settings.claudeConfigDir ?? ""
            codexDir = store.settings.codexHome ?? ""
        }
    }

    private var canApplyFolders: Bool {
        PathValidation.check(claudeDir, expecting: "projects").isAcceptable
            && PathValidation.check(codexDir, expecting: "sessions").isAcceptable
            && (claudeDir != (store.settings.claudeConfigDir ?? "") || codexDir != (store.settings.codexHome ?? ""))
    }

    private func applyFolders() {
        var settings = store.settings
        settings.claudeConfigDir = claudeDir
        settings.codexHome = codexDir
        store.apply(settings)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { value in
                var settings = store.settings
                settings[keyPath: keyPath] = value
                store.apply(settings)
            }
        )
    }
}

private struct PathField: View {
    let title: LocalizedStringKey
    let placeholder: String
    @Binding var text: String
    let subfolder: String

    var body: some View {
        let validation = PathValidation.check(text, expecting: subfolder)
        VStack(alignment: .leading, spacing: 4) {
            TextField(title, text: $text, prompt: Text(placeholder))
            Label(validation.message, systemImage: validation.isAcceptable ? (validation == .missingSubfolder(subfolder) ? "exclamationmark.triangle" : "checkmark.circle") : "xmark.octagon")
                .font(.caption)
                .foregroundStyle(validation.isAcceptable ? (validation == .missingSubfolder(subfolder) ? Color.orange : Color.secondary) : Color.red)
        }
    }
}

/// Claude limits hook: state, actions, and consent before editing settings.json.
private struct HookSection: View {
    let store: UsageStore
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Section("Claude limits hook") {
            let status = store.claude.hookStatus
            HStack {
                Label(statusText(status), systemImage: status == .installed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(status == .installed ? Color.green : Color.orange)
                Spacer()
                ForEach(status.map(HookAction.available(for:)) ?? [], id: \.self) { action in
                    Button(title(action)) { run(action) }.disabled(busy)
                }
            }
            Text("Claude Code shares its limits only with statusline commands. The hook records them and then runs your existing statusline.")
                .font(.caption).foregroundStyle(.secondary)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func statusText(_ status: StatuslineInstaller.Status?) -> String {
        switch status {
        case .installed: String(localized: "Installed")
        case .notInstalled: String(localized: "Not installed")
        case .overwritten: String(localized: "Replaced by another statusline (e.g. an OMC update) — Repair to restore")
        case .hookMissing: String(localized: "Hook program missing — Install to restore it")
        case .settingsUnreadable: String(localized: "settings.json could not be read; nothing will be changed")
        case nil: String(localized: "Checking…")
        }
    }

    private func title(_ action: HookAction) -> String {
        switch action {
        case .install: String(localized: "Install…")
        case .repair: String(localized: "Repair…")
        case .uninstall: String(localized: "Uninstall")
        }
    }

    private func run(_ action: HookAction) {
        if action.needsConsent && !confirm(action) { return }
        busy = true
        error = nil
        Task {
            error = await store.perform(action)
            busy = false
        }
    }

    private func confirm(_ action: HookAction) -> Bool {
        let installer = store.makeInstaller()
        let consent = HookConsent(settingsURL: installer.settingsURL, paths: installer.paths, hasExistingStatusLine: installer.hasStatusLine)
        let alert = NSAlert()
        alert.messageText = consent.title
        alert.informativeText = consent.body
        alert.addButton(withTitle: action == .repair ? String(localized: "Repair") : String(localized: "Install"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}

private struct LoginSection: View {
    @State private var enabled = LoginItem.isEnabled
    @State private var message: String? = LoginItem.note

    var body: some View {
        Section("Startup") {
            Toggle("Open Token Glance at login", isOn: Binding(
                get: { enabled },
                set: { newValue in
                    let error = LoginItem.set(newValue)
                    enabled = LoginItem.isEnabled
                    message = error ?? LoginItem.note
                }
            ))
            if let message {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
