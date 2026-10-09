import Foundation
import Testing
@testable import TokenGlanceCore

/// A fake CLAUDE_CONFIG_DIR + Token Glance support dir + a stand-in hook binary.
struct InstallerSandbox {
    let root: URL
    let settings: URL
    let paths: TokenGlancePaths
    let hookSource: URL
    static let omcCommand = "node ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hud/omc-hud.mjs"

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tg-install-\(UUID().uuidString)")
        settings = root.appendingPathComponent("claude/settings.json")
        paths = TokenGlancePaths(supportDirectory: root.appendingPathComponent("Application Support/TokenGlance"))
        hookSource = root.appendingPathComponent("build/token-glance-hook")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hookSource.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: hookSource)
    }

    func cleanup() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: settings.path)
        try? FileManager.default.removeItem(at: root)
    }

    var installer: StatuslineInstaller {
        StatuslineInstaller(settingsURL: settings, paths: paths, hookSource: hookSource,
                            now: { Date(timeIntervalSince1970: 1_791_421_200) })
    }

    func write(_ text: String) throws { try Data(text.utf8).write(to: settings) }
    func read() throws -> String { try String(contentsOf: settings, encoding: .utf8) }

    func command() throws -> String? {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
        return (object?["statusLine"] as? [String: Any])?["command"] as? String
    }

    var settingsBackups: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: settings.deletingLastPathComponent().path)) ?? [])
            .filter { $0.hasPrefix("settings.json.token-glance-backup-") }
    }

    static let omcSettings = """
    {
      "model": "opus",
      "statusLine": {
        "type": "command",
        "command": "node ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hud/omc-hud.mjs",
        "padding": 0
      },
      "hooks": { "Stop": [ { "matcher": "", "hooks": [] } ] },
      "env": { "NOTE": "keep \\"quotes\\" and /slashes/" }
    }

    """
}

@Suite(.serialized) struct StatuslineInstallerTests {
    @Test func installReplacesOnlyTheCommandAndUninstallRestoresBytes() throws {
        let box = try InstallerSandbox(); defer { box.cleanup() }
        try box.write(InstallerSandbox.omcSettings)
        #expect(box.installer.status() == .notInstalled)

        #expect(try box.installer.install() == .installed)
        let hook = box.installer.hookCommand
        #expect(try box.command() == hook)
        // everything except the command value is byte-identical
        let expected = InstallerSandbox.omcSettings.replacingOccurrences(
            of: #""\#(InstallerSandbox.omcCommand)""#, with: JSONTextEditor.encode(string: hook))
        #expect(try box.read() == expected)
        #expect(box.installer.status() == .installed)

        // backup keeps the original command verbatim (shell syntax not expanded)
        let backup = try #require(StatuslineBackup.load(from: box.paths.statuslineBackup))
        #expect(backup.originalCommand == InstallerSandbox.omcCommand)
        #expect(backup.installedCommand == hook)

        // full-file timestamped backup
        #expect(box.settingsBackups == ["settings.json.token-glance-backup-20261008-010000"])
        let fullBackup = box.settings.deletingLastPathComponent().appendingPathComponent(box.settingsBackups[0])
        #expect(try String(contentsOf: fullBackup, encoding: .utf8) == InstallerSandbox.omcSettings)

        // hook binary copied with 755
        let attributes = try FileManager.default.attributesOfItem(atPath: box.paths.hookBinary.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o755)

        #expect(try box.installer.uninstall() == .restored)
        #expect(try box.read() == InstallerSandbox.omcSettings)
        #expect(box.installer.status() == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: box.paths.statuslineBackup.path))
        #expect(!FileManager.default.fileExists(atPath: box.paths.hookBinary.path))
    }

    @Test func installedHookChainsTheBackedUpOriginal() throws {
        let box = try InstallerSandbox(); defer { box.cleanup() }
        try box.write(#"{"statusLine": {"type": "command", "command": "echo ${TG_UNSET_FOR_TEST:-chained}"}}"#)
        _ = try box.installer.install()
        let output = Pipe()
        let code = StatuslineHook(paths: box.paths).run(input: Data("{}".utf8), stdout: output.fileHandleForWriting.fileDescriptor)
        try output.fileHandleForWriting.close()
        #expect(code == 0)
        #expect(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "chained\n")
    }

    @Test func installWithoutStatusLineAddsKeyAndUninstallRemovesIt() throws {
        let box = try InstallerSandbox(); defer { box.cleanup() }
        let original = "{\n    \"model\": \"sonnet\",\n    \"permissions\": {\"allow\": []}\n}\n"
        try box.write(original)
        #expect(try box.installer.install() == .installed)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: box.settings)) as? [String: Any])
        #expect(object["statusLine"] as? NSDictionary == ["type": "command", "command": box.installer.hookCommand])
        #expect(StatuslineBackup.load(from: box.paths.statuslineBackup)?.originalCommand == nil)
        // the hook has nothing to chain: no output
        #expect(StatuslineHook(paths: box.paths).chainCommand == nil)

        #expect(try box.installer.uninstall() == .restored)
        #expect(try box.read() == original)
    }

    @Test func installIsIdempotent() throws {
        let box = try InstallerSandbox(); defer { box.cleanup() }
        try box.write(InstallerSandbox.omcSettings)
        _ = try box.installer.install()
        let afterFirst = try box.read()
        let backupAfterFirst = try Data(contentsOf: box.paths.statuslineBackup)
        #expect(try box.installer.install() == .alreadyInstalled)
        #expect(try box.read() == afterFirst)
        #expect(try Data(contentsOf: box.paths.statuslineBackup) == backupAfterFirst)
        #expect(box.settingsBackups.count == 1)
    }

    @Test func overwrittenIsDetectedAndRepairKeepsTheNewCommand() throws {
        let box = try InstallerSandbox(); defer { box.cleanup() }
        try box.write(InstallerSandbox.omcSettings)
        _ = try box.installer.install()
        // e.g. an OMC update rewrites statusLine
        let newer = "node ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hud/omc-hud-v2.mjs"
        try box.write(InstallerSandbox.omcSettings.replacingOccurrences(of: InstallerSandbox.omcCommand, with: newer))
        #expect(box.installer.status() == .overwritten)

        #expect(try box.installer.repair() == .repaired)
        #expect(box.installer.status() == .installed)
        #expect(StatuslineBackup.load(from: box.paths.statuslineBackup)?.originalCommand == newer)
        #expect(try box.installer.uninstall() == .restored)
        #expect(try box.command() == newer)
    }

    @Test func installOnOverwrittenStateRepairs() throws {
        let box = try InstallerSandbox(); defer { box.cleanup() }
        try box.write(InstallerSandbox.omcSettings)
        _ = try box.installer.install()
        try box.write(InstallerSandbox.omcSettings)  // statusLine reverted by someone else
        #expect(try box.installer.install() == .repaired)
        #expect(box.installer.status() == .installed)
    }

    @Test func uninstallLeavesSettingsAloneWhenOverwritten() throws {
        let box = try InstallerSandbox(); defer { box.cleanup() }
        try box.write(InstallerSandbox.omcSettings)
        _ = try box.installer.install()
        let foreign = InstallerSandbox.omcSettings.replacingOccurrences(of: InstallerSandbox.omcCommand, with: "other-statusline")
        try box.write(foreign)
        #expect(try box.installer.uninstall() == .settingsLeftUnchanged)
        #expect(try box.read() == foreign)
        #expect(box.installer.status() == .notInstalled)
    }

    @Test func missingSettingsFileIsCreatedAndRemovedAgain() throws {
        let box = try InstallerSandbox(); defer { box.cleanup() }
        #expect(box.installer.status() == .notInstalled)
        #expect(try box.installer.install() == .installed)
        #expect(try box.command() == box.installer.hookCommand)
        #expect(box.settingsBackups.isEmpty)
        #expect(try box.installer.uninstall() == .restored)
        #expect(!FileManager.default.fileExists(atPath: box.settings.path))
    }

    @Test func brokenSettingsAreRefusedUntouched() throws {
        let box = try InstallerSandbox(); defer { box.cleanup() }
        let broken = "{\n  \"statusLine\": { \"command\": \"x\", }\n"
        try box.write(broken)
        #expect(box.installer.status() == .settingsUnreadable)
        #expect(throws: StatuslineInstaller.InstallerError.settingsUnreadable) { try box.installer.install() }
        #expect(try box.read() == broken)
        #expect(box.settingsBackups.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: box.paths.statuslineBackup.path))
        #expect(!FileManager.default.fileExists(atPath: box.paths.hookBinary.path))
    }

    @Test func readOnlySettingsAreRefusedUntouched() throws {
        let box = try InstallerSandbox(); defer { box.cleanup() }
        try box.write(InstallerSandbox.omcSettings)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: box.settings.path)
        #expect(throws: StatuslineInstaller.InstallerError.settingsNotWritable) { try box.installer.install() }
        #expect(try box.read() == InstallerSandbox.omcSettings)
        #expect(box.settingsBackups.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: box.paths.statuslineBackup.path))
    }

    @Test func settingsPermissionsArePreserved() throws {
        let box = try InstallerSandbox(); defer { box.cleanup() }
        try box.write(InstallerSandbox.omcSettings)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: box.settings.path)
        _ = try box.installer.install()
        #expect((try FileManager.default.attributesOfItem(atPath: box.settings.path)[.posixPermissions] as? Int) == 0o600)
    }

    @Test func missingHookBinaryIsReportedAndFixedByInstall() throws {
        let box = try InstallerSandbox(); defer { box.cleanup() }
        try box.write(InstallerSandbox.omcSettings)
        _ = try box.installer.install()
        try FileManager.default.removeItem(at: box.paths.hookBinary)
        #expect(box.installer.status() == .hookMissing)
        #expect(try box.installer.install() == .repaired)
        #expect(box.installer.status() == .installed)
        #expect(StatuslineBackup.load(from: box.paths.statuslineBackup)?.originalCommand == InstallerSandbox.omcCommand)
    }

    @Test func hookCommandIsShellQuoted() {
        let installer = StatuslineInstaller(
            settingsURL: URL(fileURLWithPath: "/x/settings.json"),
            paths: TokenGlancePaths(supportDirectory: URL(fileURLWithPath: "/Users/a b/Library/Application Support/It's")),
            hookSource: nil)
        #expect(installer.hookCommand == #"'/Users/a b/Library/Application Support/It'\''s/bin/token-glance-hook'"#)
    }

    @Test func reportsWhetherAStatusLineExists() throws {
        let box = try InstallerSandbox(); defer { box.cleanup() }
        #expect(!box.installer.hasStatusLine)
        try box.write(#"{"model": "x"}"#)
        #expect(!box.installer.hasStatusLine)
        try box.write(InstallerSandbox.omcSettings)
        #expect(box.installer.hasStatusLine)
    }

    @Test func uninstallWithoutInstallIsANoOp() throws {
        let box = try InstallerSandbox(); defer { box.cleanup() }
        try box.write(InstallerSandbox.omcSettings)
        #expect(try box.installer.uninstall() == .notInstalled)
        #expect(try box.read() == InstallerSandbox.omcSettings)
    }
}
