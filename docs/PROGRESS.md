# Progress

Updated: 2026-10-10

## Done

- M0–M5 merged to `main` (M5: PR #4; session rules: PR #5).
- Codex online limits (PRD §7.4, `feat/codex-online-limits`), separate from M5:
  - Opt-in (default OFF) account limit reads through the installed Codex App Server over stdio.
  - Fallback to local logs with a visible reason; multiple `limitId` buckets kept separate.
  - Review fixes: SIGPIPE guard on the child's stdin, non-blocking stdout reader, early child
    exit reported as a launch failure, PATH for npm-installed `codex`, option lifecycle moved to
    `CodexOnlineLimitsController` with tests, account queries only on refresh/poll/wake/update/Codex reset, no reads after a
    cancelled start or app quit.
  - `./scripts/test.sh`: 211 tests in 34 suites pass.

## Next

- Merge the Codex online limits PR after review and approval (squash).
- Follow-ups from review (LOW, not blocking):
  - Pass failure reasons and the limit source as enums instead of English strings to the popover.
  - Wait for the App Server child to exit on app quit (or kill its process group).
  - Keep online values when the first online read finishes before the first local scan.
  - Throttle reads triggered by `account/rateLimits/updated` and re-read after a push that arrives
    mid-read; check what the server emits.
  - Cap the number of buffered stdout lines.
  - Reset the alert baseline on account switches when `accountId` is missing.
- Memory: combined footprint with online checks is ~60 MB against the 50 MB target (`docs/perf.md`).
- Not verified: manual Refresh click in the real app, new/resumed Codex sessions with the online
  option, an npm-installed `codex` launched from Finder.
- M6: README screenshots, release automation, distribution check.
