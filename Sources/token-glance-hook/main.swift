import Foundation
import TokenGlanceCore

// Claude Code statusline hook. Reads the statusline JSON from stdin, records rate limits to the
// Token Glance cache, then runs the user's original statusline command with the same input.
// No network, no Keychain, no logging of input content.

let paths = TokenGlancePaths.default()

// MARK: Management commands
// `token-glance-hook install|uninstall|status|repair` edits ${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json.
// Claude Code always runs the hook without arguments. Output is status words only, never commands or paths.

if CommandLine.arguments.count > 1 {
    let installer = StatuslineInstaller(
        settingsURL: StatuslineInstaller.defaultSettingsURL(),
        paths: paths,
        hookSource: Bundle.main.executableURL?.resolvingSymlinksInPath()
    )
    do {
        switch CommandLine.arguments[1] {
        case "status": print(installer.status())
        case "install": print(try installer.install())
        case "repair": print(try installer.repair())
        case "uninstall": print(try installer.uninstall())
        default:
            FileHandle.standardError.write(Data("usage: token-glance-hook [install|uninstall|status|repair]\n".utf8))
            exit(64)
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
}

// MARK: Signal forwarding
// The handler only touches these globals and async-signal-safe calls.
nonisolated(unsafe) var childPID: pid_t = 0
nonisolated(unsafe) var pendingSignal: Int32 = 0

/// Sends `signal` to the child's process group (the child leads its own group).
func signalChild(_ pid: pid_t, _ signal: Int32) {
    if kill(-pid, signal) != 0 { kill(pid, signal) }
}

func forwardSignal(_ signal: Int32) {
    pendingSignal = signal
    if childPID > 0 { signalChild(childPID, signal) }
}

for signal in [SIGTERM, SIGINT, SIGHUP] {
    Darwin.signal(signal) { forwardSignal($0) }
}

// MARK: Hook

let input = FileHandle.standardInput.readDataToEndOfFile()
let hook = StatuslineHook(paths: paths)
let code = hook.run(
    input: input,
    shouldChain: { pendingSignal == 0 },
    onSpawn: { pid in
        childPID = pid
        // A signal that arrived between spawn and here has not reached the child yet.
        if pendingSignal != 0 { signalChild(pid, pendingSignal) }
    }
)
exit(pendingSignal != 0 && code == 0 ? 128 + pendingSignal : code)
