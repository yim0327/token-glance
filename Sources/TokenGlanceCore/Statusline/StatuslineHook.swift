import Foundation

/// The statusline hook pipeline: capture rate limits, then hand off to the original statusline.
///
/// Order matters: Claude Code may cancel a running statusline script when a newer update arrives,
/// so the cache is written before the (possibly slow) original command starts.
public struct StatuslineHook {
    public var paths: TokenGlancePaths
    public var now: () -> Date

    public init(paths: TokenGlancePaths, now: @escaping () -> Date = Date.init) {
        self.paths = paths
        self.now = now
    }

    /// Updates the cache from `input`. Never throws: any failure leaves the previous cache as is.
    public func updateCache(with input: Data) {
        let existing = (try? Data(contentsOf: paths.rateLimitCache)).flatMap { try? ClaudeRateLimitCache.decode($0) }
        guard let updated = try? ClaudeRateLimitCache.updated(existing, with: input, at: now()),
              let data = try? updated.encoded()
        else { return }
        try? AtomicFile.write(data, to: paths.rateLimitCache)
    }

    /// The original statusline command to chain, if one was backed up.
    public var chainCommand: String? {
        StatuslineBackup.load(from: paths.statuslineBackup)?.chainCommand
    }

    /// Full pipeline. Returns the exit code to exit with.
    public func run(
        input: Data,
        stdout: Int32 = STDOUT_FILENO,
        stderr: Int32 = STDERR_FILENO,
        shouldChain: () -> Bool = { true },
        onSpawn: (pid_t) -> Void = { _ in }
    ) -> Int32 {
        updateCache(with: input)
        guard let command = chainCommand, shouldChain() else { return 0 }
        return StatuslineChain.run(command: command, input: input, stdout: stdout, stderr: stderr, onSpawn: onSpawn)
    }
}
