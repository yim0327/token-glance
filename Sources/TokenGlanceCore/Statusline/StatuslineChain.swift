import Foundation

/// Runs the user's original statusline command with the exact input bytes Claude Code sent.
public enum StatuslineChain {
    /// Runs `command` via `/bin/sh -c`, writes `input` to its stdin and closes it, and waits.
    ///
    /// stdout/stderr and the environment are inherited (or redirected to the given descriptors).
    /// The child gets default handlers for SIGTERM/SIGINT/SIGPIPE even if the caller changed them, and
    /// leads its own process group (pgid == pid), so `onSpawn`'s pid can be used with `kill(-pid, …)`
    /// to stop the whole tree, including grandchildren of compound commands.
    /// Returns the child's exit code, `128 + signal` if it was killed, or 127 if it could not start.
    public static func run(
        command: String,
        input: Data,
        stdout: Int32 = STDOUT_FILENO,
        stderr: Int32 = STDERR_FILENO,
        onSpawn: (pid_t) -> Void = { _ in }
    ) -> Int32 {
        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else { return 127 }
        let (readEnd, writeEnd) = (pipeFDs[0], pipeFDs[1])
        // A child that exits without reading must not kill us with SIGPIPE.
        _ = fcntl(writeEnd, F_SETNOSIGPIPE, 1)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, readEnd, STDIN_FILENO)
        for (source, target) in [(stdout, STDOUT_FILENO), (stderr, STDERR_FILENO)] {
            // With POSIX_SPAWN_CLOEXEC_DEFAULT, a descriptor kept at its own number must be inherited explicitly.
            if source == target {
                posix_spawn_file_actions_addinherit_np(&actions, target)
            } else {
                posix_spawn_file_actions_adddup2(&actions, source, target)
            }
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGTERM, SIGINT, SIGPIPE, SIGHUP] { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        // Only stdin/stdout/stderr reach the child; every other descriptor is closed.
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let arguments = ["/bin/sh", "-c", command]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, "/bin/sh", &actions, &attributes, &argv, environ)
        close(readEnd)
        guard spawned == 0 else {
            close(writeEnd)
            return 127
        }
        onSpawn(pid)

        // Write on another thread: a child that stops reading must not block waiting for it.
        let writer = Thread {
            input.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = write(writeEnd, buffer.baseAddress! + offset, buffer.count - offset)
                    if written > 0 {
                        offset += written
                    } else if written < 0 && errno == EINTR {
                        continue
                    } else {
                        break  // EPIPE: the child closed stdin
                    }
                }
            }
            close(writeEnd)
        }
        writer.start()

        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        return exitCode(fromWaitStatus: status)
    }

    static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }
}
