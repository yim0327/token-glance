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
| `codex-token-count-sample.jsonl` | codex-cli 0.155.1 rollout (verified in M1) | 11 lines |
| `codex-edge-cases.synthetic.jsonl` | same structure; cases **not observed** in real logs | 8 lines |
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

| input | output | cache_creation | cache_read | thinking (reasoning) |
|---|---|---|---|---|
| 21 | 794 | 3500 | 58000 | 120 |

Per model: `claude-sonnet-5` 8/184/2000/35000, `claude-opus-5-5` 3/410/500/18000 (thinking 120),
`claude-haiku-4-5-20251001` 10/200/1000/5000.

### `codex-token-count-sample.jsonl`

One session, three `token_count` events (each preceded by a `token_usage_record`), model switches
from `gpt-6-sol` to `gpt-6-astra` before the third event. Codex `input_tokens` **includes**
`cached_input_tokens`; normalized `input` below is `input_tokens - cached_input_tokens`.

| | raw input | cached | output | reasoning | normalized input | cacheRead | cacheWrite |
|---|---|---|---|---|---|---|---|
| total | 25000 | 18500 | 1550 | 450 | 6500 | 18500 | 0 |
| `gpt-6-sol` | 21000 | 15000 | 1300 | 450 | 6000 | 15000 | 0 |
| `gpt-6-astra` | 4000 | 3500 | 250 | 0 | 500 | 3500 | 0 |

- Latest `rate_limits` (observed `T0 + 6m`): 300 min `20.5%` resets `T0 + 4h = 1791435600`;
  10080 min `27.0%` resets `T0 + 5d = 1791853200`.

### `codex-edge-cases.synthetic.jsonl`

Second session starting `T0 + 1h`, model `gpt-6-sol`, no cached tokens.

| Line case | Expectation |
|---|---|
| `info: null` (with rate limits) | no tokens; rate limits still used |
| first snapshot total 1000/100 | +1000 input, +100 output |
| identical repeated snapshot | +0 |
| cumulative **decreased** to 500/50 | fall back to `last_token_usage`: +500 / +50 |
| total 800/80, last 300/30, `rate_limits: null` | +300 / +30; rate limits ignored |
| malformed JSON line | skipped |

- Session totals: input `1800`, output `180`.
- Latest non-null `rate_limits` (observed `T0 + 1h2m`): 300 min `31.0%`, 10080 min `28.5%`
  (same reset times as above). Across both Codex files this is the newest snapshot.

### `claude-statusline-stdin-sample.json`

- `five_hour`: `38%` used, resets `1791433200` (T0 + 3h20m).
- `seven_day`: `12%` used, resets `1791788400` (T0 + 4d6h).
