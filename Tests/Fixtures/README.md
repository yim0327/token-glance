# Fixtures

All fixtures are **hand-built with fake values**. No line was copied from a real log.
Structure (keys, types, nesting, value shapes) mirrors what was observed locally in M0;
see `docs/log-schemas.md`. Text content is `[redacted]` or empty, paths use `/Users/user/project`,
and IDs are `*_FAKE*` or zero-padded UUIDs.

Files with `.synthetic` in the name are based on a schema that has **not** been verified
against a real sample yet.

| File | Source of structure | Notes |
|---|---|---|
| `claude-usage-sample.jsonl` | Claude Code 2.1.295 project logs (verified) | 11 lines |
| `codex-token-count-sample.synthetic.jsonl` | codex-cli 0.155.1 binary field names + public format (unverified) | 7 lines |
| `claude-statusline-stdin-sample.json` | Claude Code 2.1.295 statusline stdin (verified) | with `rate_limits` |
| `claude-statusline-stdin-no-rate-limits.synthetic.json` | same, `rate_limits` key removed (absence shape unverified) | |

All timestamps are relative to `T0 = 2026-10-08T01:00:00Z` (epoch `1791421200`).

## Expected values

### `claude-usage-sample.jsonl`

| Case | Key (`message.id`) | Expectation |
|---|---|---|
| non-assistant lines (`user`, `ai-title`) | - | skipped |
| A single line | `msg_FAKE0001` | counted as is |
| B streaming duplicates (3 lines, `output_tokens` 10 → 10 → 410) | `msg_FAKE0002` | counted once with `output_tokens = 410` (max) |
| C exact duplicate line | `msg_FAKE0003` | counted once |
| D `<synthetic>` model, no `requestId` | `msg_FAKE0004` | excluded |
| E `<synthetic>` + `quotaLimits` (`five_hour`, `rejected`, `resetsAt = T0 + 3h = 1791432000`) | `msg_FAKE0005` | excluded from tokens; quota signal |
| F sidechain (subagent), haiku | `msg_FAKE0006` | counted |

Totals after dedupe (A + B + C + F):

| input | output | cache_creation | cache_read |
|---|---|---|---|
| 21 | 794 | 3500 | 58000 |

### `codex-token-count-sample.synthetic.jsonl`

- First `token_count` has `info: null` (rate limits only).
- Three turns, plus one repeated cumulative snapshot after turn 2 (must not be double counted).
- Final session totals (delta sum == last `total_token_usage`):
  `input 25000, cached_input 43000, output 1550, reasoning_output 450`.
- Latest `rate_limits`: primary `20.5%` / 300 min / resets `T0 + 4h = 1791435600`;
  secondary `27.0%` / 10080 min / resets `T0 + 5d = 1791853200`.

### `claude-statusline-stdin-sample.json`

- `five_hour`: `38%` used, resets `1791433200` (T0 + 3h20m).
- `seven_day`: `12%` used, resets `1791788400` (T0 + 4d6h).
