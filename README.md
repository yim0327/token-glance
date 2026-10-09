# Token Glance

Claude Code & Codex usage limits at a glance, in your macOS menu bar.

> **Status:** early development (M3 MVP). Build from source; no release yet.

Token Glance shows the remaining percentage and reset time of the 5-hour session
and weekly limits for Claude Code and Codex CLI, as a two-line menu bar label.

- Read-only and local-first: no network calls by default.
- Prompt and response content is never stored, logged, or sent; only numeric metadata is used.

## Build and run

Requires macOS 14+ and Swift 5.10+ (Xcode or the Command Line Tools).

```sh
swift build
./scripts/test.sh          # same as `swift test`; also works with Command Line Tools only
./scripts/bundle-app.sh    # builds dist/TokenGlance.app (ad hoc signed)
open dist/TokenGlance.app
```

The app lives in the menu bar only (no Dock icon). Click it for details; **Quit** is at the bottom of
the popover.

### Opening an unsigned app

Token Glance is not notarized (no Apple Developer account). A locally built app usually opens
directly. If you downloaded a build and macOS refuses to open it, either right-click the app and
choose **Open**, or remove the quarantine flag:

```sh
xattr -cr TokenGlance.app
```

### Claude Code limits

Claude Code passes rate limits to statusline commands only. Token Glance captures them with a small
hook that runs first and then hands the same input to your existing statusline (for example
oh-my-claudecode's HUD). Install it with:

```sh
dist/TokenGlance.app/Contents/Resources/token-glance-hook install   # backs up settings.json first
~/Library/Application\ Support/TokenGlance/bin/token-glance-hook uninstall   # restores it
```

An install button in the app is planned. Codex limits are read from Codex's local session logs and
need no setup.

## License

MIT. See [LICENSE](LICENSE).

---

Not affiliated with Anthropic or OpenAI. "Claude" and "Codex" are trademarks of their respective owners.
