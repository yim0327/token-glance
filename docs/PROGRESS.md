# Progress

Updated: 2026-10-12

## Status

- M0–M6 are merged to `main` (PR #1–#13). CI passes on `main`.
- **v0.1.0 is published**: https://github.com/yim0327/token-glance/releases/tag/v0.1.0
  (tag `v0.1.0` on `5c99b09`, build 23).
- **v0.1.1 is published** (new app icon): https://github.com/yim0327/token-glance/releases/tag/v0.1.1
  (tag `v0.1.1` on `2fc4a0e`, build 29, published 2026-10-11T07:30:12Z). `VERSION` is `0.1.1`.
- Release-blocker fixes and the public-docs cleanup are merged (PR #14).
- Final pre-release check done (see "Verified in the real app"); build requirements, release notes
  and these records corrected before tagging (PR #17).

## Done

- M0–M5: parsers, hook, menu bar label and panel, incremental updates, settings, notifications,
  Korean/English, 14-day history (PR #1–#5).
- Codex online limits (PRD §7.4, PR #6): opt-in (default OFF) account limit reads through the
  installed Codex App Server over stdio; fallback to local logs with a visible reason; multiple
  `limitId` buckets kept separate; account queries only on refresh/poll/wake/update/Codex reset.
  Review fixes before merge: SIGPIPE guard on the child's stdin, non-blocking stdout reader, early
  child exit reported as a launch failure, PATH for npm-installed `codex`, option lifecycle moved to
  `CodexOnlineLimitsController` with tests, no reads after a cancelled start or app quit. 211 tests
  in 34 suites.
- Claude online limits (PRD §7.5, PR #7): no stable official API for plan limits, so the app
  delegates to Claude Code's experimental `get_usage` control request in a short-lived headless
  child and never reads the Keychain item or token. Calling the undocumented endpoint with the token
  directly was rejected (Legal and compliance wording on collecting/intermediating credentials).
  Opt-in with a consent dialog; 20 s timeout, shared reads, backoff 5 → 30 min (Refresh bypasses),
  quick retries after launch/wake, cancel on OFF; hook-cache fallback with reason, source and
  observation time. Verified with 3 approved probe runs (one showed that
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` also blocks the usage read, so it is not set) and a
  5-minute ON measurement (2 successful queries). 248 tests in 39 suites.
- Missing limits stay visible (PR #9): every enabled tool keeps its menu bar line; the details panel
  keeps gray rows with `--/--` and the reason. Cause: a #6 regression where the Codex line
  disappeared after its 5-hour window reset. With online checks off, Codex no longer names
  "Local logs" as the source (PR #10). 254 tests in 40 suites.
- M6 release preparation (PR #12): repeated window use measured (93 open/close cycles, settled
  42–45 MB, no per-cycle growth, CPU 0.77%, lifetime peak 48.5 MB; measurement-only driver behind
  `-DTG_STRESS`, not in release builds; `docs/perf.md`); `scripts/package-release.sh` (zip + SHA-256,
  version/arch/resources/signature checks, run in CI); `.github/workflows/release.yml` (`v*` tag =
  `VERSION` → tests → package → **draft** Release); local install check of the zip (checksum, ad hoc
  signature, arm64, string tables, launch, `--print-state`; hook install/overwritten/repair/uninstall
  in a temporary profile); details panel fixes (the English source/observed line was cut off, so
  they are now separate lines; gauges follow the menu bar mode; after the fix: settled 28–30 MB over
  61 panel cycles); README screenshots. 255 tests in 40 suites.
- Service marks (PR #13): Claude mark and OpenAI Blossom from the supplied SVGs in the menu bar and
  next to the tool names in the panel; C/X badges as the fallback. Panel contrast: in dark mode
  blue/orange/red on the translucent background measured 1.46 / 2.88 / 1.69 : 1, now 5.85 / 7.03 /
  5.06 : 1 (black 45% dim, lighter tints); light mode about 3.4 / 2.8 / 3.1 : 1 (white 50%, deeper
  orange). Darker light-mode tints were tried and rejected as murky, so light text stays under
  4.5 : 1. Trademark points remain open (`docs/trademarks.md`). 261 tests in 42 suites.
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
  A second pass against the earlier history restored what the first pass had dropped: README
  limits and notices (local zip checks do not replace Gatekeeper; `repair` changes what `uninstall`
  restores; the child Claude Code may refresh its login and cache a usage snapshot; Codex limit
  fields verified on one machine only), the AI-tool note in the PRD, the source-analysis numbers
  behind the statusline-ordering rule (`docs/log-schemas.md` §3.2), the original wording on where
  the Blossom file came from, and per-PR review fixes, causes, contrast values and test counts here.
- Development notes (`docs/development.md`, Korean): starting point, milestones and plan changes,
  three cases (Codex update gaps, incremental parsing and repeated-use performance, the chaining
  hook and settings protection), how AI tools were used and what was checked by hand, current
  limits. Linked from both README sections.
- Generic hook status wording (`fix/generic-hook-status-wording`): the overwritten-hook texts
  (`reason.hookOverwritten`, `hook.status.overwritten`) no longer name a third-party tool; the
  example is now "another tool changed the statusline" in both languages. A string-table test
  rejects known third-party tool names in Korean and English values. Behavior unchanged.
  `./scripts/test.sh`: 277 tests in 43 suites pass.
- New app icon for v0.1.1 (`feat/app-icon`, PR #19): until v0.1.0 the bundle had no icon (no `.icns`,
  no `CFBundleIconFile`), so macOS showed the generic app icon. The new icon (two eyes looking over a
  usage bar) is Token Glance's own design: no third-party mark, shape based on one or brand color.
  Source `assets/AppIcon/AppIcon.svg`; `scripts/make-app-icon.sh` renders every iconset size
  (16–1024 px) with the system SVG renderer (`scripts/render-svg.swift`, no third-party tools) and
  packs the committed `AppIcon.icns`. `bundle-app.sh` copies it and sets `CFBundleIconFile`;
  `package-release.sh` (run in CI) fails if the icon is missing or differs from the source (both
  failure cases checked). One artwork for all sizes. Checked on macOS 26.6.2 with a bundled copy:
  Finder icon view, Get Info and list view show the new icon. Not checked: alerts and notifications
  (see "v0.1.1 release"); the Dock never shows the app (`LSUIElement`). `./scripts/test.sh`: 277
  tests in 43 suites pass.
  - Incident: while UI-scripting the settings window of a separate test copy (own bundle id and
    preference domain) for screenshots, that copy's Codex online checks were turned on for a few
    seconds. The likely cause (a late consent dialog receiving a click meant for the toggle) was not
    confirmed. The option was turned off at once, its `codex app-server` child ended, and no process
    was left after the copy quit. Since then CLAUDE.md forbids UI-automating consent dialogs and
    settings that enable online checks, network or child processes.
- README icon and light-mode panels (PR #21): `make-app-icon.sh` also renders
  `docs/images/app-icon.png` (128 px) from the same SVG; rerunning it left `AppIcon.icns` unchanged.
  The four panel images (`panel-{ko,en}-{light,dark}.png`) were retaken from a `main` build
  (`c38bd15`) in a separate copy on macOS 26.6.2 with both online checks on, one after another within
  a few minutes (same limits and items in all four; token counts differ slightly because Claude Code
  was in use). Appearance, language and the online options were switched by hand; the installed app
  was not changed.
- Install guide (PR #22): the README install section is four short steps; details moved to
  `docs/install.md` (Korean and English): steps with screenshots, checksum, update, uninstall, build
  from source and install troubleshooting. Screenshots were taken on macOS 26.6.2 with two separate
  copies built from `main` (`f0e7942`), each with its own bundle id, re-signed ad hoc and given a
  quarantine attribute so Gatekeeper blocked them (`spctl` rejected both); the person at the
  computer clicked through the dialogs, and the password prompt was never captured. The installed
  app and its settings were not touched; the copies and capture files were removed afterwards. The
  launch-complete step reuses `docs/images/menubar.png`.
- Docs alignment (`docs/align-docs-with-current-state`, 2026-10-12, docs only): current state and
  history separated (v0.1.1 in the development notes), PRD wording corrected (ad hoc signed and not
  notarized, reset handling, icon checklist), privacy wording made precise (log bytes read but
  prompt/response fields not extracted; the app's own cache, backups and settings listed apart from
  the original logs), uninstall steps narrowed to Token Glance's own items, synthetic fixtures
  described as such, perf and ADR notes clarified, this file condensed. License wording aligned with
  `LICENSE` (the project's software and documentation; no rights to third-party names or marks).
  `docs/releases/v0.1.1.md` got two clarifications (that license wording; the banner-icon steps are
  one Mac's record, not a recommended fix), so it now differs from the published Release text, which
  was not edited. No source, test, fixture or script changes.

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
| Codex live tracking with the online option on (new, resumed, resumed after restart) | app log only: state updated 1–2 s after each rollout write (no other Codex activity at the time); label change not observed by eye. Codex account reads could not be confirmed from logs because there is no Codex online log line |
| Language switch, panel closing, toggles, Refresh, test banner (M6 build) | checked by hand |
| Codex new/same/resumed-after-restart sessions (M6 build) | 0.49–1.0 s after the write (probe) |

After the release-blocker fixes (2026-10-11, separate app copies, both online checks on, 5 min):
quit left no `codex` or `claude` process in any child process group; launch and poll queries
succeeded; app CPU and settled footprint stayed within the run-to-run range of the previous `main`
(`docs/perf.md`).

Final pre-release check (2026-10-11, `main` at `6b60ff7`, build 22):

- CI on `6b60ff7` passed. No open PRs or issues, no tag or Release yet.
- `swift build` and `./scripts/test.sh` exit 0: 277 tests in 43 suites ran and passed.
- `./scripts/package-release.sh` exit 0: `TokenGlance-0.1.0-macos-arm64.zip`; checksum file
  verifies; app and hook arm64 (minimum macOS 14.0), ad hoc signed, `codesign --verify --strict
  --deep` passes; string tables and both mark SVGs inside, the marks byte for byte equal to the
  sources; `CFBundleShortVersionString` 0.1.0 = `VERSION`, `CFBundleVersion` 22; no home paths in
  the binaries. A CI build uses another toolchain, so its zip checksum is not expected to match
  the local one.
- `release.yml` read (not run): tag = `VERSION` → build → tests (at least 50) → package → release
  notes present → `--draft --verify-tag` Release.
- Privacy scan of tracked files and all 55 revisions: no real emails, user names, tokens or home
  paths (fixtures use `/Users/user` and similar; one fake token in a redaction test). Screenshots,
  including two that exist only in history, show no personal data. Commit emails are noreply.
- Fresh install with online checks off (copy with its own bundle id and an empty preference
  domain, 90 s, sampled every 5 s): no child process and no internet socket. Limits: short-lived
  connections between samples and DNS lookups through `mDNSResponder` would not be seen.

Settings-window checks on the build-22 app (2026-10-11, both online checks on; every descendant of
the app and any new orphan sampled every 0.5 s, plus the app log):

| Check | Result |
|---|---|
| Quit the previous app copy | its `codex` child gone within 0.5 s |
| Launch, panel, Refresh, history window, language switch and back | checked by hand and in the app log |
| Codex online checks off (3 times) | `codex` child gone within 0.5 s each time |
| Claude online checks off while a check runs (2 times) | child and grandchild gone; the child about 2 s after the change (SIGTERM ignored, SIGKILL after the 2 s grace), the grandchild at once |
| Check timeout (launch check and its quick retry) | child gone about 22 s after start (20 s timeout + 2 s grace) |
| Quit while a check runs | app and every child gone within 2 s |
| Real `claude` checks (18, counted from the app log) | all answered (`ok, 2 windows`): 0.6–1 s after Refresh, up to about 3 s for the check at launch |
| Refresh with the Claude option off | no `claude` started |

No child or grandchild was left and no orphan appeared in any run. Method and limits: a real check
ends in 0.6–0.7 s, too fast to turn the option off by hand, so the in-flight, timeout and
quit-while-running cases used a fake `claude` placed first in `PATH`. It never answers, ignores
SIGTERM and starts a grandchild, which is harsher than the real tool but is not Claude Code itself;
it writes nothing. The app was started from a terminal with that `PATH`, not from Finder.

## v0.1.0 release (2026-10-10 UTC)

- Annotated tag `v0.1.0` on `5c99b09d94897fa8731d0e3a41cf1e1547b693b3` (= `origin/main`, `VERSION`
  0.1.0), build 23 (commit count).
- Release workflow run 38072913605 passed every step (tag = `VERSION`, build, 277 tests, package,
  draft). SHA-256 printed by CI and in the `.sha256` file:
  `3ad205eaac1bf15c68355dd1d5bca5beb8e78da1d6897307c2180210104ab2e2` (differs from local builds,
  as expected for another toolchain).
- Draft review: two assets (zip 1,229,521 bytes, `.sha256` 100 bytes); notes byte for byte equal to
  `docs/releases/v0.1.0.md`; downloaded copy: checksum OK, app and hook arm64, ad hoc signed,
  `codesign --verify --strict --deep` passes, 0.1.0 / build 23, ko/en string tables, both mark SVGs
  byte for byte equal to the sources, no home or CI paths in the binaries.
- Published 2026-10-10T17:47:47Z, not a pre-release. Without a token: the release page answers 200,
  `releases/latest` (web and API) points to `v0.1.0`, both assets download from the public URLs and
  `shasum -a 256 -c` is OK; the README Releases link opens.
- Download check on the development Mac (macOS 26.6.2), files downloaded with a web browser: the zip
  and the unzipped app carried the quarantine attribute; checksum OK; `spctl --assess` rejected the
  app (not notarized, expected); opening it was blocked, and after **Open Anyway** (password) it ran
  from `/Applications/TokenGlance.app` with no App Translocation mount. A first attempt that moved
  the app with `mv` in Terminal ran it from an App Translocation path instead; removing it, unzipping
  again and dragging it in Finder gave the result above. README and release notes now say to drag
  it in Finder.

## v0.1.1 release (2026-10-11 UTC)

Scope: the new app icon (PR #19) is the only change to the app. Since `v0.1.0`, nothing under
`Sources/`, `Tests/`, `Package.swift` or `.github/` changed; `bundle-app.sh` only copies
`AppIcon.icns` and sets `CFBundleIconFile` (bundle id unchanged), and `package-release.sh` only adds
the icon checks. Preparation PR #23: `VERSION` 0.1.1 (read by `bundle-app.sh`,
`package-release.sh` and `release.yml`; nothing else hard-codes it) and `docs/releases/v0.1.1.md`.

- Pre-tag check on `main` at `2fc4a0e` (CI passed; no open PRs or issues; only tag `v0.1.0`):
  `swift build` and `./scripts/test.sh` exit 0, 277 tests in 43 suites; `./scripts/package-release.sh`
  exit 0 (0.1.1, build 29, arm64, ad hoc, icon checks passed, mark SVGs equal to the sources, no home
  paths). Links and anchors in the docs resolve. Privacy scan of tracked files and the 6 commits
  since `v0.1.0`: no real emails, names, tokens or home paths; the 11 new or changed images were
  looked at and hold no personal data (metadata: only the macOS "Screenshot" comment).
- Annotated tag `v0.1.1` on `2fc4a0e99e59728d6c34c2fc506d5230bd789047`, build 29 (commit count).
  Release workflow run 38119181535 passed every step (tag = `VERSION`, build, 277 tests, package,
  draft).
- Draft review: two assets (zip 1,600,057 bytes, `.sha256` 100 bytes); SHA-256
  `035ed32bcf16e7f92dda3fc4a2d074786c33ae8a27f7477c303cd73cc03a55a0` equal in the CI log, the
  `.sha256` file and the download; downloaded app 0.1.1 / build 29, app and hook arm64 (minimum
  macOS 14.0), ad hoc signed, `codesign --verify --strict --deep` passes, `CFBundleIconFile`
  AppIcon and the bundled `AppIcon.icns` byte for byte equal to `assets/AppIcon/AppIcon.icns`, both
  mark SVGs equal to the sources, ko/en string tables, no home or CI paths in the binaries; links in
  the notes answer 200 and the file names match the assets.
- Hand check by the maintainer (macOS 26.6.2) with the draft zip (downloaded with `gh`, so without
  the quarantine attribute), installed in place of v0.1.0: Finder icon view, Get Info and the
  online-check consent dialog showed the new icon; the test notification banner did not.
- Notification banner icon (one development Mac):
  - Seen: the notification service found the app at `/Applications/TokenGlance.app` and delivered
    the banner, with no icon error in the logs; the bundled icon file was complete. Unregistering
    other Launch Services registrations for the bundle id and restarting the notification processes
    did not change the banner. A copy with another bundle id could not serve as a control (the
    notification service rejected it).
  - Then several steps were taken together: other copies of the app and the user icon caches
    removed, the installed app removed, the Mac restarted, the draft zip downloaded again in a browser
    and installed. After that the banner showed the new icon.
  - Not known: which of these steps was needed, whether a restart alone helps, and whether other
    Macs updating from v0.1.0 see the same. These steps are a record of one Mac, not a recommended
    fix.
  - Removed on this Mac during the check: the test copies, `dist/TokenGlance.app` and the user icon,
    Dock icon and notification center caches. Not confirmed: emptying two old copies in the Trash and
    removing the system icon cache. Gatekeeper approvals were left as they are.
  - The draft notes were edited before publishing to say only what was seen;
    `docs/releases/v0.1.1.md` matched the published notes at that time.
- Published 2026-10-11T07:30:12Z, not a pre-release, with the reviewed notes. Without a token: the
  release page answers 200, both assets download from the public URLs (same sizes) and
  `shasum -a 256 -c` is OK, `releases/latest` (web and API) points to `v0.1.1`, and the published
  notes equal the reviewed draft.

## Next

- Pick from "Later (LOW)" below; no release blockers are open.
- Release workflow (found in the final check, not changed): raise the minimum test count from 50,
  and check that the tag commit is on `main`.

## Later (LOW)

- Pass failure reasons and the limit source as enums instead of English strings.
- Throttle reads triggered by `account/rateLimits/updated`; check what the server emits first.
- Show the next retry time while backing off; alerts for online windows without a reset time.
- The "waiting for account query" notice flashes orange for under a second after turning the option
  on; consider a neutral color while waiting. It is also shown while a fresher hook value replaces
  a reset Claude window.
- Log the Codex online outcome like `claude online: …` (there is no Codex online log line).
- Refresh is ignored while the launch/wake Claude check is still retrying (the read in flight
  includes its quick retries, up to the 20 s timeout each). Consider showing that a check is in
  progress, or letting Refresh restart it.
- Memory: combined footprint with Codex online checks is about 60 MB against the 50 MB target
  (`docs/perf.md`).
- Screenshot method for later updates: on macOS 26 the status item is hosted by Control Center;
  capture its screen rectangle (`screencapture -R`) for the label, and windows by id (`-l`) while
  they are on screen (the panel releases its content when it closes, and it closes when another
  app takes focus, so start a script that waits for the window before opening it). Panel windows
  are at window layer 101; the settings window is at layer 0. Light and dark pairs should be
  taken in one sitting without pressing Refresh: an account query or a hook update in between
  changes the numbers or adds the "hook cache differs" line.

## Won't do

- Resetting the alert baseline on account switches when `accountId` is missing (no signal to detect
  a switch; documented as a limitation).

## Not verified

- Building with a Swift 5.10 toolchain (`Package.swift` declares 5.10; builds and tests were run with
  Swift 6.1 on CI and 6.3 locally).
- "Open at login" and hook installation while the app runs from an App Translocation path.
- Claude Code versions other than 2.1.296; `weekly_scoped` (per-model weekly) rows.
- Expired-login and 429 answers (synthetic tests only).
- An npm-installed `codex` launched from Finder.
- Real threshold-crossing notifications (automated tests only).
- Launch at login after logging out and back in.
- Intel Macs (release zip is arm64 only).
- Notification banner icon after updating from v0.1.0 on other Macs, and which step restored it on
  the development Mac (see "v0.1.1 release").
