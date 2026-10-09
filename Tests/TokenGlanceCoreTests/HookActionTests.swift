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
}
