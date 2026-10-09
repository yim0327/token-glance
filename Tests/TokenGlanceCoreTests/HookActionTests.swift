import Foundation
import Testing
@testable import TokenGlanceCore

@Suite(.serialized) struct HookActionTests {
    @Test func actionsOfferedPerStatus() {
        #expect(HookAction.available(for: .notInstalled) == [.install])
        #expect(HookAction.available(for: .installed) == [.uninstall])
        #expect(HookAction.available(for: .overwritten) == [.repair, .uninstall])
        #expect(HookAction.available(for: .hookMissing) == [.install, .uninstall])
        #expect(HookAction.available(for: .settingsUnreadable).isEmpty)
        #expect(HookAction.install.needsConsent && HookAction.repair.needsConsent && !HookAction.uninstall.needsConsent)
    }

    @Test func stateTransitionsThroughTheInstaller() throws {
        let box = try InstallerSandbox(); defer { box.cleanup() }
        try box.write(InstallerSandbox.omcSettings)
        let installer = box.installer

        #expect(try HookAction.install.perform(with: installer) == .installed)
        #expect(try HookAction.uninstall.perform(with: installer) == .notInstalled)
        #expect(try box.read() == InstallerSandbox.omcSettings)

        #expect(try HookAction.install.perform(with: installer) == .installed)
        try box.write(InstallerSandbox.omcSettings)  // e.g. OMC rewrote statusLine
        #expect(installer.status() == .overwritten)
        #expect(try HookAction.repair.perform(with: installer) == .installed)

        try FileManager.default.removeItem(at: box.paths.hookBinary)
        #expect(installer.status() == .hookMissing)
        #expect(try HookAction.install.perform(with: installer) == .installed)
        #expect(try HookAction.uninstall.perform(with: installer) == .notInstalled)
    }

    @Test func failedActionReportsTheError() throws {
        let box = try InstallerSandbox(); defer { box.cleanup() }
        try box.write("{ broken")
        #expect(throws: StatuslineInstaller.InstallerError.settingsUnreadable) { try HookAction.install.perform(with: box.installer) }
    }

    @Test func consentTextNamesFilesBackupAndUndo() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let consent = HookConsent(
            settingsURL: home.appendingPathComponent(".claude/settings.json"),
            paths: TokenGlancePaths(supportDirectory: home.appendingPathComponent("Library/Application Support/TokenGlance")),
            hasExistingStatusLine: true, home: home)
        #expect(consent.title == "Install the Claude limits hook?")
        #expect(consent.body.contains("~/.claude/settings.json"))
        #expect(consent.body.contains("statusLine"))
        #expect(consent.body.contains("~/.claude/settings.json.token-glance-backup-"))
        #expect(consent.body.contains("Your current statusline keeps working"))
        #expect(consent.body.contains("Uninstall"))
        #expect(!consent.body.contains("/Users/someone"))

        let fresh = HookConsent(settingsURL: home.appendingPathComponent(".claude/settings.json"),
                                paths: TokenGlancePaths(supportDirectory: home.appendingPathComponent("x")),
                                hasExistingStatusLine: false, home: home)
        #expect(!fresh.body.contains("Your current statusline keeps working"))
    }
}
