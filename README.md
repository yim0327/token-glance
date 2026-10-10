# Token Glance

Claude Code & Codex usage limits at a glance, in your macOS menu bar.

<!-- SCREENSHOT PLACEHOLDER: two-line menu bar label (C 62% / X 80%) and the details panel.
     Add as docs/images/menubar.png and replace this comment with:
     ![Menu bar and details panel](docs/images/menubar.png) -->
*Screenshot coming soon.*

> **Status:** in development (M5). Build from source; no signed release yet.

Token Glance shows how much of the **5-hour session** and **weekly** limits you have left in
Claude Code and Codex CLI, as a two-line menu bar label:

```
[C] 62%
[X] 80%
```

Click it for details: per-window gauges with `N% used / M% left`, reset times with a live
countdown, and tokens used today and this week (input / output / cache, top models).

## Features

- Two-line label (one line when only one tool is enabled), orange at 30% left or less, red at 10%.
- Remaining % (default) or used %.
- Updates within seconds of new activity (FSEvents), reading only the bytes appended to logs.
- Shows why a value is missing (`--`): hook not installed, no data yet, data too old, …
- Settings: display mode, tools on/off, custom log folders, open at login, Claude hook install/repair/uninstall.
- Optional notifications (off by default) when the remaining percentage drops past 30% / 10%
  (configurable), and when a new window starts after running low.
- English and Korean, following the system language by default or chosen in settings.
- A 14-day history window with daily tokens per tool, from local logs.

## How it gets the numbers

| | Limits (% and reset time) | Tokens |
|---|---|---|
| **Claude Code** | Claude Code passes them only to **statusline commands**. A small hook records them and then runs your existing statusline (e.g. oh-my-claudecode's HUD) with the same input. | `~/.claude/projects/**/*.jsonl` (respects `CLAUDE_CONFIG_DIR`) |
| **Codex CLI** | `token_count` events in `~/.codex/sessions/**/rollout-*.jsonl` (respects `CODEX_HOME`). No setup. | same files |

Details of the formats are in [docs/log-schemas.md](docs/log-schemas.md).

## Privacy

- **No network calls.** Everything is read from local files.
- Prompt and response text is never stored, logged or sent. Only numbers (token counts,
  percentages, reset times, model names) are used, and only in memory.
- The hook writes just the limit values to
  `~/Library/Application Support/TokenGlance/claude-rate-limits.json`; no paths, session ids or names.
- Installing the hook changes one key (`statusLine.command`) in Claude Code's `settings.json`,
  only after you confirm, and only after backing up the whole file. Uninstall restores it.

## Install

Requires macOS 14+ and Swift 5.10+ (Xcode or the Command Line Tools).

```sh
git clone https://github.com/yim0327/token-glance.git
cd token-glance
./scripts/bundle-app.sh        # builds dist/TokenGlance.app (ad hoc signed)
open dist/TokenGlance.app
```

Then click the menu bar item, open **Settings…** and choose **Install…** under "Claude limits hook".
The same can be done from a terminal:

```sh
dist/TokenGlance.app/Contents/Resources/token-glance-hook install     # backs up settings.json first
~/Library/Application\ Support/TokenGlance/bin/token-glance-hook uninstall
```

### Opening an unsigned app

Token Glance is not notarized (no Apple Developer account). A locally built app usually opens
directly. If you downloaded a build and macOS refuses to open it, right-click the app and choose
**Open**, or remove the quarantine flag:

```sh
xattr -cr TokenGlance.app
```

"Open at login" uses `SMAppService`; for an unsigned app macOS may ask you to approve it in
System Settings › General › Login Items.

## Development

```sh
swift build
./scripts/test.sh     # `swift test`; also runs the tests when only the Command Line Tools are installed
dist/TokenGlance.app/Contents/MacOS/TokenGlance --print-state   # label and tooltip once, no UI
```

Design decisions: [docs/adr](docs/adr). Performance measurements: [docs/perf.md](docs/perf.md).

## Limitations

- Limits are percentages only; neither tool exposes remaining token counts for subscription plans.
- Claude limits update only while Claude Code runs (they arrive through the statusline). Values
  older than 7 days are hidden; a window whose reset time has passed shows as reset.
- Log formats are undocumented and may change. Unknown fields are ignored and unreadable lines skipped.
- Codex limit fields were verified on one machine with few sessions (see docs/log-schemas.md §2).
- Codex sessions idle for more than 24 hours and then resumed may update only with the 5-minute
  fallback poll.
- Notifications only react to new observations while the app is running; changes that happened
  while the Mac was asleep or the app was closed are not sent afterwards.
- The history chart counts only logs on this Mac. Days before the oldest log are shown as having
  no logs, not as zero usage.

## Compared with similar tools

Other menu bar apps track AI coding usage (for example
[CodexBar](https://github.com/steipete/CodexBar)). Token Glance makes a narrower set of choices:

- Two tools only (Claude Code and Codex), both visible at once in a two-line label.
- Official/local paths first: Claude limits come from Claude Code's own statusline input, not from
  web sessions or private APIs; Codex limits from its local logs.
- No network access and minimal permissions by default.
- A small, readable codebase with tests against anonymized fixtures.

If you need more providers or account-level features, look at the alternatives.

## License

MIT. See [LICENSE](LICENSE).

---

Not affiliated with Anthropic or OpenAI. "Claude" and "Codex" are trademarks of their respective
owners. Token Glance uses neutral glyphs, not their logos.
