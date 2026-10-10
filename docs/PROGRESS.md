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

- Codex online limits merged (PR #6); Claude online limits merged (PR #7).
- Post-merge cleanup (2026-10-10): merged worktrees and branches removed, a leftover stash
  checked against `main` and dropped; `.omx/` ignored (PR #8).
- Missing limits stay visible (PR #9): every enabled tool keeps its menu bar line; a missing value
  is drawn as two digit-wide bars in the number color. The details panel keeps the 5-hour and
  weekly rows as gray bars with `--/--` and the reason (or a fallback message) under the bar.
  Fixes a #6 regression where the Codex line disappeared after its 5-hour window reset.
- With online checks off, the Codex details no longer name "Local logs" as the source, matching
  Claude (PR #10).
- `./scripts/test.sh`: 254 tests in 40 suites pass.

## Verified in the real app (2026-10-10)

| Check | Result |
|---|---|
| Consent dialogs: Claude shows all 5 notices, Codex shows its notice | user-confirmed |
| Cancelling either consent dialog keeps the option off | user-confirmed |
| Refresh with the option on: source changes to "Account query" | user-confirmed |
| Hook cache value differs: notice and source shown | user-confirmed |
| Option off during a check: no child left; no orphan after quit | user-confirmed |
| Codex live tracking with the online option on: new session, resumed session, resume after app restart | app log only: Codex state updated 1–2 s after each rollout write (16:47–16:49, no other Codex activity); label change not reported by the user |
| Codex source line hidden when the option is off | user-confirmed |

- M6 release preparation (branch `chore/m6-release`, PR pending review):
  - Repeated window use measured (93 open/close cycles): footprint settles at 42–45 MB after first
    use, no per-cycle growth; CPU 0.77% over the run; lifetime peak 48.5 MB (`docs/perf.md`).
  - Measurement-only driver behind `-DTG_STRESS` (not in release builds).
  - `scripts/package-release.sh` (zip + SHA-256, version/arch/resources/signature checks), run in CI.
  - `.github/workflows/release.yml`: `v*` tag = VERSION → tests → package → **draft** Release.
  - Local install check of the zip: checksum, ad hoc signature, arm64, string tables, launch,
    `--print-state`; hook install/overwritten/repair/uninstall in a temporary profile.
  - PRD v1.0, README screenshots (panel and history, English/Korean), install and Gatekeeper steps.
  - Real-app regression checks passed (language, panel closing, toggles, refresh, test banner,
    Codex new/same/resumed-after-restart sessions 0.49–1.0 s).

- Release wrap-up on PR #12 (2026-10-10):
  - Details panel: limit source and observation time on separate lines (English line was cut off).
  - Details panel gauges follow the menu bar mode (remaining = what is left, used = what is used);
    `DisplayFormat.gaugePercent` with tests. Checked in the real app in remaining mode.
  - Memory after the layout fix (separate copy, online off, 61 panel cycles): settled 28–30 MB,
    lifetime peak 39.0 MB, no per-cycle growth (`docs/perf.md`).
  - README split into a Korean section (top) and an English section (bottom) with language links;
    each section shows only its own screenshots. Other-project mentions removed from both.
    CLAUDE.md README rule updated to match.
  - Screenshots retaken after both panel changes (user-approved): panel and history in Korean and
    English, plus the menu bar label (`menubar.png`); dark mode, online checks on, real usage.
  - `./scripts/test.sh`: 255 tests in 40 suites pass.

- M6 release preparation merged (PR #12, squash `5d6d820`, 2026-10-10).
- Service marks (PR #13, `feat/menubar-service-marks`, user request; trademark points open, see
  `docs/trademarks.md`):
  - Menu bar: Claude mark / OpenAI Blossom from the supplied SVGs (unchanged files), 10 pt (one
    line 13 pt), `labelColor`; 1 pt between the lines; warning colors on the numbers only; C/X
    badges as the fallback. `SVGPath` / `ServiceMarks` with tests; SVGs checked by packaging.
  - Details panel: the same marks next to the tool names (15 pt).
  - Dark mode panel: background dimmed (black 45%), lighter blue/orange/red; measured contrast
    5.85 / 7.03 / 5.06 : 1 (was 1.46 / 2.88 / 1.69). Light mode unchanged, checked in the real app.
  - README: menu bar label plus panels in light and dark for each language (user-approved);
    history images unchanged.
  - `./scripts/test.sh`: 261 tests in 42 suites pass.

## Next

- PR #13 (needs approval): merge, then push tag `v0.1.0` (approval), review the draft Release,
  publish (approval).
- After publishing: download the zip on a Mac and check the Gatekeeper "Open Anyway" flow.
- Screenshot method (for later updates): the status item is hosted by Control Center on macOS 26;
  capture its screen rectangle (`screencapture -R`) for the label, and windows by id (`-l`) while
  they are on screen (the panel releases its content when it closes).
- Fix now (small PRs, not started):
  1. Child process robustness: wait for the App Server / Claude Code child to exit on quit (or kill
     its process group), cap buffered stdout lines, close stdout only after EOF.
  2. Online/hook combination: keep online values when the first online read finishes before the
     first local scan; after an online window passes its reset, use a fresher hook value.
- Later (LOW):
  - Pass failure reasons and the limit source as enums instead of English strings.
  - Throttle reads triggered by `account/rateLimits/updated`; check what the server emits first.
  - Show the next retry time while backing off; alerts for online windows without a reset time.
  - The "waiting for account query" notice flashes orange for under a second after turning the
    option on; consider a neutral color while waiting.
  - Log the Codex online outcome like `claude online: …` (no Codex online log line exists, so the
    live-tracking window could not confirm Codex account reads from logs).
  - Memory: combined footprint with online checks is ~60 MB against the 50 MB target (`docs/perf.md`).
- Won't do: resetting the alert baseline on account switches when `accountId` is missing (no signal
  to detect a switch; documented as a limitation).
- Not verified: Claude Code versions other than 2.1.296, `weekly_scoped` (per-model weekly) rows,
  expired-login and 429 answers (synthetic tests only), an npm-installed `codex` launched from Finder.
