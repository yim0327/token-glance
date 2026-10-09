# Token Glance

Claude Code & Codex usage limits at a glance, in your macOS menu bar.

> **Status:** early development (M0). Nothing to install yet.

Token Glance shows the remaining percentage and reset time of the 5-hour session
and weekly limits for Claude Code and Codex CLI, as a two-line menu bar label.

- Read-only and local-first: no network calls by default.
- Prompt and response content is never stored, logged, or sent; only numeric metadata is used.

## Build

Requires macOS 14+ and Swift 5.10+.

```sh
swift build
./scripts/test.sh   # same as `swift test`; also works with Command Line Tools only
```

## License

MIT. See [LICENSE](LICENSE).

---

Not affiliated with Anthropic or OpenAI. "Claude" and "Codex" are trademarks of their respective owners.
