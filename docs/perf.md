# Performance

Targets (PRD §9): idle CPU < 1% (including while Claude Code is running), memory < 50MB by
physical footprint (Activity Monitor "Memory"); peaks tracked separately. RSS is recorded for
reference only (it includes shared framework pages).

## Method

- Bundled release app (`./scripts/bundle-app.sh`), launched with `open`, measured for 5 minutes
  while a Claude Code session is actively writing logs (this development session).
- CPU: cumulative CPU time from `ps -o time=` sampled every 5s. Average = ΔCPU / Δwall;
  "max 5s" = highest 5-second interval. (`ps %cpu` is a decaying average and is not used.)
- Memory: `footprint <pid>` every 5s (average, max sampled), `vmmap --summary` at the end for
  current and peak physical footprint; RSS from `ps -o rss=`.
- Single full parse: `TokenGlance --print-state` timed with `/usr/bin/time -l` (3 runs).
- Data on the measuring machine: Claude logs 72 files / 163.7 MB, Codex rollouts 1 file / 211 KB.

## Baseline (M3, before incremental parsing) — 2026-10-09

Full re-parse of all Claude logs every 60s whenever any log file changed.

| Metric | Value |
|---|---|
| CPU average (5 min) | **2.37%** |
| CPU max (5s interval) | 30.4% |
| Footprint average (sampled) | 15.0 MB |
| Footprint at end | 40.1 MB |
| Footprint peak | **208.2 MB** |
| RSS max (sampled) | 192.7 MB |
| One full parse | 0.85–0.91 s wall, 0.8 s CPU, reads 163.9 MB, peak footprint ~150 MB |

(M3 had measured ~4.1% average over a different 5-minute window; the rate depends on how often
the logs change.)

## After incremental parsing (M4) — 2026-10-09

Byte-offset incremental reading (`TailedFiles`), FSEvents with 1.5s coalescing, relevance filter
for event paths, no state update when results are unchanged.

| Metric | Baseline (M3) | M4 | Target |
|---|---|---|---|
| CPU average (5 min, Claude Code running) | 2.37% | **0.31%** | < 1% |
| CPU max (5s interval) | 30.4% | 1.6% | |
| Footprint average (sampled) | 15.0 MB | 23.8 MB | < 50 MB |
| Footprint peak | 208.2 MB | **47.0 MB** | < 50 MB |
| RSS average / max (sampled) | — / 192.7 MB | 37.0 / 40.9 MB | reference |
| Refreshes in 5 min | 5 full re-parses | 59 incremental | |
| Refresh time | 0.85–0.91 s | avg 12.9 ms, max 33 ms | < 200 ms |
| Bytes read after start | ~164 MB per refresh | 816 KB total | |

- First full scan at launch: 1.4 s, 175 MB read, peak footprint 37–47 MB.
- Worst case if events arrived continuously: one refresh per 1.5 s × 12.9 ms ≈ 0.9% CPU.
- Caveat: log activity during this window was lighter than during the baseline (which overlapped
  with builds and test runs in the same Claude Code session). The per-refresh cost above is what
  scales with activity.

### What mattered

1. **Autorelease pools per chunk.** Reading with `FileHandle` and decoding JSON returns autoreleased
   Foundation objects; on a background thread without a run loop they lived until the whole scan
   finished. A read-only probe held ~209 MB; with a pool per chunk it dropped to 63 MB (4 MB chunks)
   and 26 MB (1 MB chunks). The old full re-parse had the same issue.
2. **1 MB chunks** bound the transient buffers (chunk + line copies + pending partial line).
3. **Event filter.** Claude Code writes many non-log files under `projects/` (tool outputs etc.).
   Only `.jsonl` files, the hook cache and directory events now trigger a refresh.
4. **No-op refreshes don't touch the UI.** Results equal except for the refresh time are not
   reassigned, so SwiftUI and the label are not recomputed.

### Notes

- FSEvents did not report every append to a file kept open by the writer (one batch for 20 s of
  continuous appends in a synthetic test). Freshness is still bounded by the 5-minute fallback poll,
  the refresh at the next reset time, and manual refresh; Claude Code's statusline updates also
  rewrite the hook cache, which is watched.
- Index state is memory-only. Persisting it would save the 1.4 s first scan at launch; not needed
  at current sizes.

## Codex live updates (2026-10-09)

Symptom: the Codex value did not change while Codex was in use; it did change after **Refresh**.

Diagnosis (probe: FSEvents with zero latency + `stat` every 200 ms on the rollout, recording only
times, event kinds, byte counts and line types; app: refresh logs with their trigger):

| Step | Observed | Delay |
|---|---|---|
| 1. Codex writes `token_count` + `rate_limits` | appended immediately after each turn | none |
| 2. File change detection | FSEvents reported only the rollout's **creation**; no event for any later append (Codex keeps the file open) | **cause** |
| 3. Incremental read | ran only on manual refresh / 5-min poll; then read exactly the appended bytes in ~20 ms | follows 2 |
| 4. State and label | updated in the same main-actor turn as the refresh | none |

Before the fix: first `token_count` at 16:28:13.8 appeared at 16:28:50.2 via the 5-minute poll
(36 s; up to 5 min). Manual refresh picked it up immediately.

Fix: `ActiveFileSet` — every 2 s, `stat` only the Codex rollouts that grew in the last 15 minutes
(or the most recent one) and run the incremental refresh when a size changed. New session files are
still found through their FSEvents creation event. No full re-parse.

After the fix (real Codex use):

| `token_count` written | App updated | Delay |
|---|---|---|
| 16:29:52.6 | 16:29:54.4 | 1.8 s |
| 16:29:58.0 | 16:29:58.4 | 0.4 s |
| 16:30:02.2 | 16:30:02.4 | 0.2 s |

5-minute window with Codex and Claude Code in use: CPU average **0.39%** (max 2.8% per 5 s);
refreshes: 13 FSEvents (avg 14 ms), 7 active-Codex (avg 11 ms, 84 KB), 1 poll. Footprint 23 MB
until the popover was opened.

### Popover cost (found during this run; fixed in M5, see below)

Opening the popover raised the footprint to a 163 MB transient peak, then 43 MB while open, and
CPU to ~1% while it stays open (1-second countdown redraws). Candidates: drop the hosting
controller when the popover closes, tick only the countdown text, update freshness every 30 s.

## Codex live updates, follow-up (2026-10-09)

Symptom: Codex token totals stopped updating again during real use.

Observed (probe: times, event kinds, byte counts, `token_count` direction only):

- Existing, most recent session: updated within ~1–2 s (the first fix works).
- **New session:** the rollout's creation event triggered a refresh before Codex wrote any
  `token_count`. The file then had no recorded growth, so it was not in the active set; its usage
  appeared only with the 5-minute poll (observed 7 s by coincidence; up to 5 min).
- **Older session used again / after an app restart:** not the newest file and no growth seen by
  this process, so not watched either. One observation updated after 5.4 s only because an
  unrelated Claude log event happened to trigger a refresh.

Fix: files that appear after the first scan count as just grown, and every rollout modified within
24 hours is stat-polled every 2 s (sizes only; reading stays incremental).

After the fix (real Codex use, single app instance, build 10):

| Case | `token_count` written | App updated | Delay |
|---|---|---|---|
| New session | 17:08:56.71 | 17:08:56.74 | 0.03 s |
| Most recent existing session | 17:08:23.30 | 17:08:24.74 | 1.4 s |
| Older session resumed after restart | 17:11:27.31 | 17:11:28.74 | 1.4 s |

5 minutes including these: CPU 0.25% average (max 1.2% per 5 s), footprint 24 MB average,
44.9 MB peak; 7 active-Codex refreshes (avg 15 ms), 25 FSEvents refreshes (avg 14 ms).

## M5: notifications, localization, history window (2026-10-10)

Same method; the app was used normally (panel, settings, history window opened and closed by
hand). "Peak" is `vmmap`'s lifetime peak, i.e. it includes launch, the first scan and every
window opened so far. Spikes were also checked with `footprint --sample` at 0.2–0.5 s.

| State (final build) | CPU avg | CPU max 5 s | Footprint avg | Lifetime peak |
|---|---|---|---|---|
| Nothing opened since launch (before the fixes below, 5 min) | 0.17% | 1.4% | 19.8 MB | 40.5 MB |
| All windows closed after using panel and settings (5 min) | 0.14% | 1.4% | 40.0 MB | 43.6 MB |
| History window open (3 min) | 0.37% | 2.4% | 46.1 MB | 46.8 MB |
| First scan, `--print-state` (3 runs, 1.26–1.32 s) | — | — | — | 29.7–34.7 MB |

Once SwiftUI windows have been shown, about 20 MB stays resident after they close (likely
framework caches; not investigated further). Growth over many open/close cycles was not measured.

### What was fixed in M5

- **Per-parser date formatters.** Each tailed log kept its own two `ISO8601DateFormatter`s
  (89 parsers → 178 ICU formatters, ~25 MB). One shared formatter and decoder: 45 → 20 MB idle.
- **Hidden popover kept ticking.** Its 1-second countdowns kept laying out while closed:
  2.65% CPU with only the history window visible. The details view is now built on show and
  released on close (0.29% after).
- **Swift Charts redraws.** Every chart redraw (data change or window focus change) briefly
  allocated ~100 MB of graphics memory (151 MB samples). An isolated probe reproduced it with
  plain Charts (132 MB vs 17 MB for text or shapes; disabling animation or rendering to an image
  did not help). The chart is now drawn with shapes and redrawn only when a daily total changes.
- **NSPopover itself.** Every show briefly allocated 115–150 MB of graphics memory, also with
  AppKit-only content in the probe; a borderless panel with the same blurred background stayed
  at 14–16 MB. The details now open in such a panel (Esc, outside click or the item closes it).
- **Re-enabling a tool re-read all its logs.** Disabling synced the index with no files;
  the index is now kept, and re-enabling Claude took 21–26 ms with 0 bytes read.

Codex live updates on the M5 build (real use): new session 0.7 s, resumed previous-day
session 0.5 s, most recent open session 0.7 s.
