# Progress

Updated: 2026-10-11

## Status

- M0–M6 are merged to `main` (PR #1–#13). CI passes on `main`.
- No tag and no GitHub Release exist yet. `VERSION` is `0.1.0`.
- Release-blocker fixes and the public-docs cleanup are on `fix/release-blockers` (PR pending
  review).

## Done

- M0–M5: parsers, hook, menu bar label and panel, incremental updates, settings, notifications,
  Korean/English, 14-day history (PR #1–#5).
- Codex online limits (PRD §7.4, PR #6): opt-in (default OFF) account limit reads through the
  installed Codex App Server over stdio; fallback to local logs with a visible reason; multiple
  `limitId` buckets kept separate; account queries only on refresh/poll/wake/update/Codex reset.
- Claude online limits (PRD §7.5, PR #7): no stable official API for plan limits, so the app
  delegates to Claude Code's experimental `get_usage` control request in a short-lived headless
  child and never reads the Keychain item or token. Calling the undocumented endpoint with the token
  directly was rejected (Legal and compliance wording on collecting/intermediating credentials).
  Opt-in with a consent dialog; 20 s timeout, shared reads, backoff 5 → 30 min (Refresh bypasses),
  quick retries after launch/wake, cancel on OFF; hook-cache fallback with reason, source and
  observation time.
- Missing limits stay visible (PR #9): every enabled tool keeps its menu bar line; the details panel
  keeps gray rows with `--/--` and the reason. With online checks off, Codex no longer names
  "Local logs" as the source (PR #10).
- M6 release preparation (PR #12): repeated window use measured (93 open/close cycles, settled
  42–45 MB, no per-cycle growth, `docs/perf.md`); `scripts/package-release.sh` (zip + SHA-256,
  version/arch/resources/signature checks, run in CI); `.github/workflows/release.yml` (`v*` tag =
  `VERSION` → tests → package → **draft** Release); local install check of the zip; details panel
  layout and gauge direction fixes; README screenshots.
- Service marks (PR #13): Claude mark and OpenAI Blossom from the supplied SVGs in the menu bar and
  next to the tool names in the panel; C/X badges as the fallback; panel contrast changes in dark
  and light mode. Trademark points remain open (`docs/trademarks.md`).
- Release-blocker fixes (`fix/release-blockers`):
  - Online-check children: shared `StdioChild` for both transports; SIGTERM to the child's process
    group recorded at launch, SIGKILL after a 2 s grace; `stop()` waits for every closed child, so
    quit and option OFF leave no child or grandchild; quit stops both tools at once. All buffered
    stdout is capped (overflow fails the read and drops the buffer); a last line without a newline
    is kept at EOF; the read end is closed by the reader after EOF.
  - Online/local combination: account limits that finish before the first local scan are shown at
    once (token table hidden until the scan ends) and are not replaced by older local values. When
    a queried Claude window has passed its reset and the hook has values observed after the query,
    the hook values are shown (whole source, never mixed, never chosen by the higher percent).
  - Regression tests: 14 new (real `/bin/sh`/`perl` children for process groups, stubborn and
    wrapper-exited children, EOF and overflow; synthetic presentation tests for ordering and
    reset/freshness). Ten failed against the old code first; four are guards that pass on both
    (long output read in full; an older hook does not replace a query; a higher percent alone does
    not win; a reset hook window is not shown).
  - `./scripts/test.sh`: 275 tests in 43 suites pass.
- Public docs cleanup (`fix/release-blockers`): README rewritten as a user guide (install, first run,
  online checks and privacy, limitations, troubleshooting), Korean and English kept in step;
  development-session wording removed from PRD, log schemas, performance notes, ADR, trademarks,
  release notes and CLAUDE.md, keeping measurement conditions and verification status.

## Verified in the real app

Manual checks on the development Mac (2026-10-10), before the release-blocker fixes:

| Check | Result |
|---|---|
| Consent dialogs: Claude shows all 5 notices, Codex shows its notice | checked by hand |
| Cancelling either consent dialog keeps the option off | checked by hand |
| Refresh with the option on: source changes to "Account query" | checked by hand |
| Hook cache value differs: notice and source shown | checked by hand |
| Option off during a check: no child left; no orphan after quit | checked by hand |
| Codex source line hidden when the option is off | checked by hand |
| Codex live tracking with the online option on (new, resumed, resumed after restart) | app log only: state updated 1–2 s after each rollout write; label change not observed by eye |
| Language switch, panel closing, toggles, Refresh, test banner (M6 build) | checked by hand |
| Codex new/same/resumed-after-restart sessions (M6 build) | 0.49–1.0 s after the write (probe) |

After the release-blocker fixes (2026-10-11, separate app copies, both online checks on, 5 min):
quit left no `codex` or `claude` process in any child process group; launch and poll queries
succeeded; app CPU and settled footprint stayed within the run-to-run range of the previous `main`
(`docs/perf.md`). Turning an option off through the settings window was not repeated after the
fixes (automated tests only).

## Next (release blockers)

1. Review and merge the `fix/release-blockers` PR (approval).
2. Push tag `v0.1.0` (approval), review the draft Release and its notes, publish (approval).
3. After publishing: download the zip on a Mac and check the checksum and the Gatekeeper
   "Open Anyway" flow.

## Later (LOW)

- Pass failure reasons and the limit source as enums instead of English strings.
- Throttle reads triggered by `account/rateLimits/updated`; check what the server emits first.
- Show the next retry time while backing off; alerts for online windows without a reset time.
- The "waiting for account query" notice flashes orange for under a second after turning the option
  on; consider a neutral color while waiting. It is also shown while a fresher hook value replaces
  a reset Claude window.
- Log the Codex online outcome like `claude online: …` (there is no Codex online log line).
- Memory: combined footprint with Codex online checks is about 60 MB against the 50 MB target
  (`docs/perf.md`).
- The hook status text "Replaced by another statusline (e.g. an OMC update)" names a specific tool;
  consider a neutral example.
- Light-mode panel screenshots (`docs/images/panel-*-light.png`) predate the light-mode color change
  and are no longer used by the README.
- Screenshot method for later updates: on macOS 26 the status item is hosted by Control Center;
  capture its screen rectangle (`screencapture -R`) for the label, and windows by id (`-l`) while
  they are on screen (the panel releases its content when it closes).

## Won't do

- Resetting the alert baseline on account switches when `accountId` is missing (no signal to detect
  a switch; documented as a limitation).

## Not verified

- Claude Code versions other than 2.1.296; `weekly_scoped` (per-model weekly) rows.
- Expired-login and 429 answers (synthetic tests only).
- An npm-installed `codex` launched from Finder.
- Real threshold-crossing notifications (automated tests only).
- Launch at login after logging out and back in.
- Intel Macs (release zip is arm64 only).
