import AppKit
import SwiftUI
import TokenGlanceCore
import TokenGlanceText

/// Hosts `SettingsView` in a regular window (the app has no Dock icon or main menu).
/// The window and its SwiftUI view are released when closed, so a closed window keeps no
/// observation of the store (and costs no rendering).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let store: UsageStore

    init(store: UsageStore) {
        self.store = store
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(store: store))
            host.sizingOptions = [.minSize, .maxSize]
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .resizable]
            // The form scrolls; open it as tall as fits on the screen, up to its usual height.
            let available = (NSScreen.main?.visibleFrame.height ?? 800) - 80
            window.setContentSize(NSSize(width: SettingsView.width, height: min(SettingsView.idealHeight, available)))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.title = store.localizer("settings.title")
        Task { await store.updateNotificationAuthorization() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        window = nil
    }
}

struct SettingsView: View {
    static let width: CGFloat = 520
    static let idealHeight: CGFloat = 760

    let store: UsageStore
    @State private var claudeDir = ""
    @State private var codexDir = ""

    var body: some View {
        let l10n = store.localizer
        Form {
            Section(l10n("settings.menuBar")) {
                Picker(l10n("settings.show"), selection: binding(\.percentMode)) {
                    Text(l10n("settings.remaining")).tag(PercentMode.remaining)
                    Text(l10n("settings.used")).tag(PercentMode.used)
                }
                .pickerStyle(.radioGroup)
                Toggle(l10n("tool.claudeCode"), isOn: binding(\.claudeEnabled))
                    .disabled(store.settings.claudeEnabled && !store.settings.codexEnabled)
                Toggle(l10n("tool.codex"), isOn: binding(\.codexEnabled))
                    .disabled(store.settings.codexEnabled && !store.settings.claudeEnabled)
                Text(l10n("settings.oneLine")).font(.caption).foregroundStyle(.secondary)
                Picker(l10n("settings.language"), selection: binding(\.language)) {
                    Text(l10n("language.system")).tag("system")
                    Text(l10n("language.korean")).tag("ko")
                    Text(l10n("language.english")).tag("en")
                }
            }
            NotificationSection(store: store)
            LoginSection(l10n: l10n)
            HookSection(store: store)
            Section(l10n("settings.codexOnline.section")) {
                Toggle(l10n("settings.codexOnline.toggle"), isOn: Binding(
                    get: { store.settings.codexOnlineLimitsEnabled },
                    set: { enabled in
                        guard !enabled || confirmCodexOnlineLimits(l10n) else { return }
                        var settings = store.settings
                        settings.codexOnlineLimitsEnabled = enabled
                        store.apply(settings)
                    }
                ))
                .disabled(!store.settings.codexEnabled)
                Text(l10n("settings.codexOnline.explain"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section(l10n("settings.logFolders")) {
                PathField(title: l10n("settings.claudeFolder"), placeholder: l10n("settings.claudeFolder.placeholder"),
                          text: $claudeDir, subfolder: "projects", l10n: l10n)
                PathField(title: l10n("settings.codexFolder"), placeholder: l10n("settings.codexFolder.placeholder"),
                          text: $codexDir, subfolder: "sessions", l10n: l10n)
                HStack {
                    Spacer()
                    Button(l10n("settings.applyFolders")) { applyFolders() }
                        .disabled(!canApplyFolders)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: Self.width)
        .frame(minHeight: 320)
        .environment(\.locale, l10n.locale)
        .onAppear {
            claudeDir = store.settings.claudeConfigDir ?? ""
            codexDir = store.settings.codexHome ?? ""
        }
        .onChange(of: store.settings.language) { NSApp.keyWindow?.title = store.localizer("settings.title") }
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

    private func confirmCodexOnlineLimits(_ l10n: Localizer) -> Bool {
        let alert = NSAlert()
        alert.messageText = l10n("settings.codexOnline.consentTitle")
        alert.informativeText = l10n("settings.codexOnline.consentBody")
        alert.addButton(withTitle: l10n("settings.codexOnline.enable"))
        alert.addButton(withTitle: l10n("settings.codexOnline.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
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
    let title: String
    let placeholder: String
    @Binding var text: String
    let subfolder: String
    let l10n: Localizer

    var body: some View {
        let validation = PathValidation.check(text, expecting: subfolder)
        let warning = validation == .missingSubfolder(subfolder)
        VStack(alignment: .leading, spacing: 4) {
            TextField(title, text: $text, prompt: Text(placeholder))
            Label(l10n.pathValidation(validation),
                  systemImage: validation.isAcceptable ? (warning ? "exclamationmark.triangle" : "checkmark.circle") : "xmark.octagon")
                .font(.caption)
                .foregroundStyle(validation.isAcceptable ? (warning ? Color.orange : Color.secondary) : Color.red)
        }
    }
}

/// Limit alerts: on/off, thresholds (validated), permission state and a test notification.
private struct NotificationSection: View {
    let store: UsageStore
    @State private var warning = ""
    @State private var critical = ""
    @State private var message: String?

    var body: some View {
        let l10n = store.localizer
        Section(l10n("settings.notifications")) {
            Toggle(l10n("settings.notifications.enable"), isOn: Binding(
                get: { store.settings.notificationsEnabled },
                set: { value in
                    var settings = store.settings
                    settings.notificationsEnabled = value
                    store.apply(settings)
                }
            ))
            HStack {
                TextField(l10n("settings.notifications.warning"), text: $warning).frame(maxWidth: 220)
                TextField(l10n("settings.notifications.critical"), text: $critical).frame(maxWidth: 220)
                Spacer()
                Button(l10n("settings.notifications.apply")) { applyThresholds() }
                    .disabled(pendingThresholds == store.settings.notificationThresholds)
            }
            if let error = validationError {
                Text(l10n.thresholdError(error)).font(.caption).foregroundStyle(.red)
            }
            Text(l10n("settings.notifications.explain"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if store.settings.notificationsEnabled {
                permissionRow(l10n)
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear {
            warning = String(store.settings.notificationThresholds.warning)
            critical = String(store.settings.notificationThresholds.critical)
        }
    }

    @ViewBuilder private func permissionRow(_ l10n: Localizer) -> some View {
        switch store.notificationAuthorization {
        case .denied:
            HStack {
                Text(l10n("notifications.permission.denied")).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(l10n("notifications.permission.openSettings")) { store.openNotificationSettings() }
            }
        case .notDetermined:
            Text(l10n("notifications.permission.notDetermined")).font(.caption).foregroundStyle(.secondary)
        case .authorized:
            HStack {
                Spacer()
                Button(l10n("settings.notifications.test")) {
                    Task {
                        if let error = await store.sendTestNotification() { message = l10n("notifications.sendFailed", error) }
                    }
                }
            }
        case .unavailable:
            EmptyView()
        }
    }

    /// `nil` while either field is not a whole number.
    private var pendingThresholds: NotificationThresholds? {
        guard let warning = Int(warning.trimmingCharacters(in: .whitespaces)),
              let critical = Int(critical.trimmingCharacters(in: .whitespaces)) else { return nil }
        return NotificationThresholds(warning: warning, critical: critical)
    }

    private var validationError: NotificationThresholds.ValidationError? {
        guard let pending = pendingThresholds else { return .outOfRange }
        return pending.validationError
    }

    private func applyThresholds() {
        guard let pending = pendingThresholds, pending.validationError == nil else { return }
        var settings = store.settings
        settings.notificationThresholds = pending
        store.apply(settings)
    }
}

/// Claude limits hook: state, actions, and consent before editing settings.json.
private struct HookSection: View {
    let store: UsageStore
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        let l10n = store.localizer
        Section(l10n("hook.section")) {
            let status = store.hookStatus
            HStack {
                Label(statusText(status, l10n), systemImage: status == .installed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(status == .installed ? Color.green : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                ForEach(status.map(HookAction.available(for:)) ?? [], id: \.self) { action in
                    Button(title(action, l10n)) { run(action, l10n) }.disabled(busy)
                }
            }
            Text(l10n("hook.explain"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func statusText(_ status: StatuslineInstaller.Status?, _ l10n: Localizer) -> String {
        switch status {
        case .installed: l10n("hook.status.installed")
        case .notInstalled: l10n("hook.status.notInstalled")
        case .overwritten: l10n("hook.status.overwritten")
        case .hookMissing: l10n("hook.status.hookMissing")
        case .settingsUnreadable: l10n("hook.status.settingsUnreadable")
        case nil: l10n("hook.status.checking")
        }
    }

    private func title(_ action: HookAction, _ l10n: Localizer) -> String {
        switch action {
        case .install: l10n("hook.button.install")
        case .repair: l10n("hook.button.repair")
        case .uninstall: l10n("hook.button.uninstall")
        }
    }

    private func run(_ action: HookAction, _ l10n: Localizer) {
        if action.needsConsent && !confirm(action, l10n) { return }
        busy = true
        error = nil
        Task {
            error = await store.perform(action)
            busy = false
        }
    }

    private func confirm(_ action: HookAction, _ l10n: Localizer) -> Bool {
        let installer = store.makeInstaller()
        let consent = l10n.hookConsent(settingsURL: installer.settingsURL, paths: installer.paths, hasExistingStatusLine: installer.hasStatusLine)
        let alert = NSAlert()
        alert.messageText = consent.title
        alert.informativeText = consent.body
        alert.addButton(withTitle: action == .repair ? l10n("alert.repair") : l10n("alert.install"))
        alert.addButton(withTitle: l10n("alert.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}

private struct LoginSection: View {
    let l10n: Localizer
    @State private var enabled = LoginItem.isEnabled
    @State private var error: String?

    var body: some View {
        Section(l10n("settings.startup")) {
            Toggle(l10n("settings.openAtLogin"), isOn: Binding(
                get: { enabled },
                set: { newValue in
                    error = LoginItem.set(newValue).map { l10n("login.error", $0) }
                    enabled = LoginItem.isEnabled
                }
            ))
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            } else if LoginItem.needsApproval {
                Text(l10n("login.approval")).font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
