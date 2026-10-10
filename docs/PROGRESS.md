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

- Claude online limits (PRD §7.5, `feat/claude-online-limits`), separate from M5:
  - Research: no stable official API for plan limits. The app delegates to Claude Code's
    experimental `get_usage` control request in a short-lived headless child; it never reads the
    Keychain item or token. Calling the undocumented endpoint with the token was rejected
    (Legal and compliance wording on collecting/intermediating credentials).
  - Opt-in (default OFF) with a consent dialog; launch/wake/5-min poll/Refresh/reset triggers,
    20 s timeout, shared reads, exponential backoff (5 min → 30 min, Refresh bypasses), quick
    retries after launch/wake, cancel on OFF.
  - Hook-cache fallback with reason, source and observation time; differing hook values shown.
  - Verified with 3 approved probe runs and a 5-minute ON measurement (2 successful queries).
  - `./scripts/test.sh`: 248 tests in 39 suites pass.

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
- Merge the Claude online limits PR after review and approval (squash).
- Claude online follow-ups (LOW, from review): show the next retry time while backing off; wait
  for a stubborn child to exit on quit; when one online window has passed its reset, consider the
  fresher hook value; alerts for online windows without a reset time; close the stdout handle only
  after EOF (shared with Codex).
- Not verified (Claude online): Claude Code versions other than 2.1.296, `weekly_scoped` rows,
  expired-login and 429 answers (synthetic tests only), the Refresh click and consent dialog in the
  real UI, Codex live tracking while the option is on (no Codex session during the measurement).
- M6: README screenshots, release automation, distribution check.
