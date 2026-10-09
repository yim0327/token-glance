# Log / Hook Schema Notes

M0 검증 결과. 모든 확인은 **읽기 전용**으로, 키 이름·타입·값의 형태(자릿수, 문자 패턴)만 추출했다. 프롬프트/응답 본문, 경로, 식별자 값은 기록하지 않는다.

- 검증일: 2026-10-09 (Codex는 M1에서 재검증)
- 환경: macOS 26.6.2 (arm64), Claude Code 2.1.295, codex-cli 0.155.1, oh-my-claudecode 5.6.1
- 표기: ✅ 확인됨 / ⚠️ 예상과 다름 / ❓ 미확인

## 요약

| PRD 항목 | 결과 | 비고 |
|---|---|---|
| 7.1 statusline stdin `rate_limits.five_hour / seven_day` | ✅ | `used_percentage` int, `resets_at` Unix epoch **초** (10자리) |
| 7.1 최소 버전 v2.1.80+ | ❓ | 2.1.295에서 존재 확인. 최소 버전은 검증 불가 |
| 7.2 `~/.claude/projects/**/*.jsonl` 경로 | ✅ | 서브에이전트 로그가 `<project>/<session-uuid>/subagents/*.jsonl` 에 중첩 |
| 7.2 `message.usage` 4개 필드 | ✅ | 추가 필드 다수 (아래 표) |
| 7.2 `message.id` + `requestId` dedupe | ⚠️ | 키는 맞지만 **중복이 매우 많고, 중복 간 `output_tokens`가 다름** → "첫 줄 채택" 금지, 키별 최댓값(=마지막 줄) 채택. 파일 간 중복도 존재 |
| 7.1 "로컬 로그에는 한도 정보가 없다" | ⚠️ | 한도 **도달 시**에만 assistant 라인에 `quotaLimits` (resetsAt 포함, % 없음) 기록됨 |
| 7.3 `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | ✅ | M1 재검증. 파일명 `rollout-<local datetime>-<uuid>.jsonl` |
| 7.3 `token_count` / `rate_limits` 필드 | ✅ | primary=300분, secondary=10080분, `resets_at` epoch 초. 신규: `cache_write_input_tokens`, `token_usage_record` 라인 |
| 7.3 Codex input 의미 | ⚠️ | `input_tokens`가 `cached_input_tokens`를 포함 (Claude와 다름) |
| OMC HUD stdin/rate_limits 처리 | ✅ | stdin + **비공식 OAuth usage API 병행** (아래) |

---

## 1. Claude Code 로그 JSONL

- 경로: `${CLAUDE_CONFIG_DIR:-~/.claude}/projects/<encoded-cwd>/<session-uuid>.jsonl` ✅
  - 서브에이전트: `.../projects/<encoded-cwd>/<session-uuid>/subagents/*.jsonl` ✅ (해당 라인은 `isSidechain: true`, `agentId` 존재)
  - 따라서 탐색은 반드시 재귀(`**`)로 한다.
- 샘플 규모: 74 파일, 39,954 라인, 파싱 실패 0.
- 라인 `type` 분포: `attachment`, `assistant`, `user`, `last-prompt`, `mode`, `atis-latch`, `permission-mode`, `ai-title`, `bridge-session`, `system`, `queue-operation`, `file-history-snapshot`, `file-history-delta`, `cost-state` → **`assistant` 외는 무시**(단, `cost-state`는 참고).

### 1.1 `type == "assistant"` 라인

| 필드 | 타입 | 상태 | 형태 / 비고 |
|---|---|---|---|
| `type` | string | ✅ | `"assistant"` |
| `timestamp` | string | ✅ | ISO 8601 UTC, 밀리초: `YYYY-MM-DDTHH:MM:SS.sssZ` |
| `cwd` | string | ✅ | 절대 경로 (개인정보: 저장 금지) |
| `sessionId` | string | ✅ | UUID. 일부 라인에 `session_id`(중복 키)도 존재 |
| `requestId` | string | ✅ | `req_…`. **5/7,225 라인 누락** (`message.model == "<synthetic>"`, usage 전부 0) |
| `uuid`, `parentUuid` | string | ✅ | UUID |
| `isSidechain` | bool | ✅ | 서브에이전트 라인은 `true` |
| `version` | string | ✅ | Claude Code 버전 (`2.1.x`) |
| `entrypoint` | string | ✅ | `cli`, `claude-vscode`, `sdk-cli` |
| `apiBlockIndex` | int | ✅ | 콘텐츠 블록 인덱스 (아래 중복 원인) |
| `isApiErrorMessage`, `apiErrorStatus`, `error` | bool/int/string | ✅ | 오류 라인에만 |
| `quotaLimits` | object | ⚠️ | 한도 거절 시에만 (1.3 참조) |
| `message.id` | string | ✅ | `msg_…` |
| `message.model` | string | ✅ | 예: `claude-sonnet-5`, `claude-opus-5-5`, `claude-haiku-4-5-20251001`, `<synthetic>` |
| `message.role` | string | ✅ | `"assistant"` |
| `message.stop_reason` | string\|null | ✅ | `tool_use`, `end_turn`, `stop_sequence`, `null`(스트리밍 중간 라인) |
| `message.content` | array | ✅ | **라인당 블록 1개**. 텍스트 포함 → 읽지 않음 |
| `message.usage.input_tokens` | int | ✅ | |
| `message.usage.output_tokens` | int | ✅ | 같은 메시지의 중복 라인 사이에서 증가 (1.2) |
| `message.usage.cache_creation_input_tokens` | int | ✅ | |
| `message.usage.cache_read_input_tokens` | int | ✅ | |
| `message.usage.cache_creation.ephemeral_5m_input_tokens` | int | ✅ | 신규 (분류용) |
| `message.usage.cache_creation.ephemeral_1h_input_tokens` | int | ✅ | 신규 |
| `message.usage.output_tokens_details.thinking_tokens` | int | ✅ | 일부 라인에만 (5,524/7,225). 관찰 5,640/5,640에서 `≤ output_tokens` → output에 포함으로 추정 |
| `message.usage.server_tool_use.{web_search_requests,web_fetch_requests}` | int | ✅ | 일부 라인 |
| `message.usage.service_tier`, `speed`, `inference_geo` | string\|null | ✅ | 무시 |
| `message.usage.iterations`, `fallback_credit` | array/null | ✅ | 무시 |

### 1.2 중복 (dedupe) ⚠️

- assistant 7,225 라인 → 고유 `(message.id, requestId)` 3,194개. 그룹 크기 1~14.
- 원인: 한 API 응답의 콘텐츠 블록(thinking/text/tool_use)마다 별도 라인이 기록되고, 각 라인에 **같은 usage 스냅샷**이 붙는다.
- 중복 그룹 2,422개 중 817개는 `output_tokens`만 다름(input/cache는 동일). 817개 모두 **파일 내 순서대로 단조 증가, 마지막 라인 = 최댓값**.
- **파일 간 중복**: 258 라인이 다른 파일에도 같은 키로 존재 (세션 재개/분기 추정).
- 집계 규칙(제안):
  1. 키 = `message.id` + `requestId` (requestId 없으면 `message.id`만).
  2. **전역**(파일 간) dedupe.
  3. 키별로 `output_tokens`가 가장 큰 usage를 채택 (input/cache는 그룹 내 동일).
  4. `message.model == "<synthetic>"` 은 제외.

### 1.3 `quotaLimits` ⚠️ (예상 밖)

한도에 걸려 요청이 거절된 경우에만 assistant 라인에 기록된다 (12 라인, 모두 아래 조합).

| 필드 | 타입 | 관찰 값 / 형태 |
|---|---|---|
| `rateLimitType` | string | `five_hour` (주간 값은 미관찰) |
| `status` | string | `rejected` |
| `resetsAt` | int | Unix epoch 초 (10자리) |
| `overageStatus` | string | `rejected` |
| `overageDisabledReason` | string | `org_level_disabled` |
| `isUsingOverage`, `unifiedRateLimitFallbackAvailable` | bool | |
| `lowPriorityOffer` | string | `control` |
| `lowPriorityMaxWaitSeconds`, `lowPriorityRetryAfterSeconds` | int | |
| `upgradePaths` | array | |

- `used_percentage`는 없으므로 메인 소스가 될 수 없다. **보조 신호**: "세션 한도 도달 + 초기화 시각"을 statusline 캐시가 없을 때 표시하는 용도로 쓸 수 있다.

**제안 (M2 결정, 미구현):** 보조 신호로 사용한다. 단 아래 조건을 모두 만족할 때만.
1. 훅 캐시가 `noData` 또는 `stale`일 때만 쓴다. 훅 캐시가 있으면 항상 훅 값이 우선 (%가 있고 더 자주 갱신됨).
2. `status == "rejected"`이고 `resetsAt > now`인 가장 최근 라인 1개만 사용. `rateLimitType`이 `five_hour`면 session, `seven_day`(추정, 미관찰)면 weekly로 매핑하고 그 외 값은 무시.
3. 표시는 "한도 도달 (100%)" + `resetsAt` 카운트다운, `observedAt`은 라인의 `timestamp`. `resetsAt`이 지나면 기존 규칙대로 "초기화됨(0%)".
4. 근거: 한도 도달은 사용자가 가장 알고 싶은 순간인데, 이때 Claude Code 응답이 거절되어 statusline 갱신이 멈출 수 있다. 로그 파싱은 이미 하고 있어 추가 I/O가 없다.

### 1.4 `type == "cost-state"` (참고)

`sessionId`, `totalCostUSD`(float, 일부 int), `totalAPIDuration`, `totalDuration`, `startTime`(int), `totalLinesAdded/Removed`, `hasUnknownModelCost`, `modelUsage: { <model>: { inputTokens, outputTokens, thinkingTokens, cacheReadInputTokens, cacheCreationInputTokens, webSearchRequests, costUSD } }`.
세션 누적 요약으로 보이며 57 라인뿐이라 집계 소스로 쓰지 않는다. 검증용 교차 체크 후보.

---

## 2. Codex CLI

M1 재검증 (2026-10-09): codex-cli 0.155.1, 실제 rollout 1개 파일 / 60 라인, 파싱 실패 0. 키·타입·형태만 확인.

### 2.1 경로 ✅

- `${CODEX_HOME:-~/.codex}/sessions/YYYY/MM/DD/rollout-YYYY-MM-DDTHH-MM-SS-<uuid>.jsonl` ✅ (날짜 디렉터리 + 로컬 시각 기반 파일명)
- `~/.codex/archived_sessions/` ❓ 이 머신엔 없음 (바이너리 문자열엔 존재). 있으면 함께 탐색한다.
- SQLite(`state_5.sqlite` `threads.rollout_path`)는 인덱스. 파서는 JSONL만 읽는다.
- (2026-10-09 관찰) `thread_history_1.sqlite`가 생김: `thread_turns`/`thread_items`와 `thread_history_projection_state.next_rollout_byte_offset`로 rollout을 **투영**한 것으로 보이며, rollout JSONL은 계속 기록됨. `threads.history_mode` 관찰값은 `paginated`. 이 DB가 rollout 없이 단독으로 쓰이는 경우가 있는지는 ❓.
- (2026-10-09 관찰) Codex는 세션 동안 rollout 파일을 열어 둔 채 이어 쓰며, FSEvents는 생성 이벤트만 보고하고 이어 쓰기는 보고하지 않음 → 앱은 최근 rollout을 stat 폴링 (`docs/perf.md`).

### 2.2 라인 공통 / 타입 분포

공통 최상위 키: `timestamp` (ISO 8601 UTC, ms, `Z`), `type`, `payload`, `ordinal` (int, 신규 ⚠️).

| `type` / `payload.type` | 개수 | 용도 |
|---|---|---|
| `session_meta` | 1 | `payload.{id, session_id, cwd, cli_version, originator, source, model_provider, timestamp}` — 경로·ID는 저장 금지 |
| `turn_context` | 2 | **`payload.model`** (턴 모델), `effort`, `cwd` 등 |
| `event_msg` / `token_count` | 6 | 토큰 누적 + rate_limits |
| `token_usage_record` ⚠️ | 6 | 응답 단위 usage (아래 2.4) |
| `event_msg` / `task_started`, `task_complete`, `item_completed`, `thread_settings_applied` | 2/2/13/3 | 무시 |
| `response_item` / `message`, `reasoning`, `custom_tool_call(_output)` | 11/4/4/4 | 본문 — 읽지 않음 |
| `world_state` | 2 | 무시 |

### 2.3 `event_msg` / `token_count` ✅

| 필드 | 타입 | 상태 | 형태 / 비고 |
|---|---|---|---|
| `payload.info` | object\|null | ✅ (null ❓) | 관찰 6/6 모두 object. null 이벤트는 관찰되지 않음 → 방어적으로 처리 |
| `payload.info.total_token_usage` | Usage | ✅ | 세션 누적 |
| `payload.info.last_token_usage` | Usage | ✅ | 직전 이벤트 이후 증가분. **관찰된 모든 연속 쌍에서 `total[i] - total[i-1] == last[i]`**, 첫 이벤트는 `total == last` |
| `payload.info.model_context_window` | int | ✅ | |
| `payload.rate_limits.primary.used_percent` | float | ✅ | 0~100 |
| `payload.rate_limits.primary.window_minutes` | int | ✅ | `300` (5h) |
| `payload.rate_limits.primary.resets_at` | int | ✅ | Unix epoch **초** (10자리) |
| `payload.rate_limits.secondary.*` | | ✅ | `window_minutes = 10080` (7d), 나머지 동일 |
| `payload.rate_limits.limit_id` | string | ⚠️ 신규 | `"codex"` |
| `payload.rate_limits.limit_name`, `individual_limit`, `rate_limit_reached_type`, `spend_control_reached` | null | ⚠️ 신규 | 관찰값 모두 null |
| `payload.rate_limits.plan_type` | string | ✅ | 예: `plus` |
| `payload.rate_limits.credits.{has_credits, unlimited, balance}` | bool/bool/string | ⚠️ 신규 | `balance`는 숫자 문자열 |

Usage 객체: `input_tokens`, `cached_input_tokens`, **`cache_write_input_tokens`** (⚠️ 신규), `output_tokens`, `reasoning_output_tokens`, `total_tokens`.

- 관계 (관찰 6/6): `total_tokens == input_tokens + output_tokens`, `cached_input_tokens ≤ input_tokens`, `reasoning_output_tokens ≤ output_tokens`.
  → **input은 cached를 포함**, output은 reasoning을 포함. Claude와 의미가 다르므로 정규화 필요 (`input(non-cached) = input - cached`).
- 동일 누적값 반복 이벤트: 관찰 0건 ❓ (샘플이 작음). 파서는 delta 0으로 처리.
- `info == null` 이벤트: 관찰 0건 ❓. 파서는 토큰은 건너뛰고 `rate_limits`만 사용.
- 누적값 감소(리셋/컴팩션 등): 관찰 0건 ❓. 감소 시 `last_token_usage`로 대체.

### 2.4 `token_usage_record` ⚠️ (예상 밖)

`payload.{thread_id, turn_id, root_turn_id, session_id, response_id}` (ID — 저장 금지) + `payload.usage`, `payload.turn_token_usage`, `payload.thread_token_usage` (각각 Usage 객체). 각 `token_count` 직전에 1개씩 나타난다.
`token_count`만으로 집계가 성립하므로 M1에서는 사용하지 않는다. `response_id`는 향후 dedupe 키 후보.

### 2.5 모델명 ✅

- `turn_context.payload.model` (턴마다). `token_count`에는 모델이 없으므로 **직전 `turn_context`의 모델**에 귀속시킨다.
- 한 세션 안에서 모델이 바뀔 수 있음 (관찰: 2개 턴, 서로 다른 모델).
- `event_msg/thread_settings_applied`, `world_state`에도 모델 필드가 있으나 사용하지 않는다.

### 2.6 미확인 (Codex)

- `info: null`, 반복 스냅샷, 누적 감소의 실제 발생 여부 (세션 1개만 관찰).
- 세션 재개(resume) 시 같은 파일에 append인지 새 파일인지, fork 시 누적값 복제 여부.
- `archived_sessions` 경로 구조.

---

## 3. Claude statusline

### 3.1 stdin JSON ✅

OMC HUD가 저장해 둔 실제 stdin 캐시 3개(최근 60일)에서 키/타입만 추출했다. 값은 기록하지 않는다.

| 필드 | 타입 | 상태 | 형태 / 비고 |
|---|---|---|---|
| `rate_limits.five_hour.used_percentage` | number | ✅ | 관찰값은 정수(0~100). float 가능성 대비 Double로 파싱 |
| `rate_limits.five_hour.resets_at` | int | ✅ | Unix epoch **초** (10자리) |
| `rate_limits.seven_day.used_percentage` | number | ✅ | 동일 |
| `rate_limits.seven_day.resets_at` | int | ✅ | 동일 |
| `version` | string | ✅ | Claude Code 버전 |
| `session_id`, `prompt_id`, `session_name` | string | ✅ | 저장 금지 (`session_name`은 사용자 텍스트) |
| `transcript_path`, `cwd`, `workspace.*`, `scratchpad_dir` | string/object | ✅ | 경로 — 저장 금지 |
| `model.id`, `model.display_name` | string | ✅ | |
| `context_window.{context_window_size,used_percentage,remaining_percentage,total_input_tokens,total_output_tokens,current_usage.*}` | int/object | ✅ | |
| `cost.{total_cost_usd,total_duration_ms,total_api_duration_ms,total_lines_added,total_lines_removed}` | number | ✅ | |
| `prompt_cache.*`, `effort.level`, `thinking.enabled`, `fast_mode`, `exceeds_200k_tokens`, `output_style.name` | 다양 | ✅ | 무시 |

- `rate_limits`가 **없는 경우의 형태**(키 부재 vs `null`)는 ❓ — 관찰된 3개 모두 존재. 파서는 둘 다 처리한다.
- **훅이 캐시에 기록할 것**: `rate_limits` 하위 4개 값 + 관측 시각 + `version` 정도로 최소화. 경로·세션명·프롬프트 ID는 기록하지 않는다.

### 3.2 oh-my-claudecode HUD 분석 (체이닝 입력)

`statusLine.command` = `node ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hud/omc-hud.mjs` (확인됨). 이 파일은 **로더 래퍼**이고 실제 로직은 `~/.claude/plugins/cache/omc/oh-my-claudecode/<latest-built-semver>/dist/hud/index.js` (현재 5.6.1)를 동적 import한다.

1. **rate_limits 출처: stdin + 네트워크 둘 다**
   - stdin의 `rate_limits.five_hour/seven_day.used_percentage`, `resets_at`을 읽는다 (`resets_at`은 숫자면 `< 1e12`일 때 초로 간주, 문자열이면 ISO 파싱).
   - 동시에 `getUsage()`로 **비공식 OAuth usage API** (`api.anthropic.com/api/oauth/usage`)를 호출한다. 자격증명은 macOS Keychain(`/usr/bin/security`, 2s timeout) → `~/.claude/.credentials.json` 순. 만료 시 토큰 refresh 요청 후 Keychain에 write-back.
   - 병합: 같은 윈도우(`resets_at` 근접)면 stdin과 API 중 **큰 %** 채택, 아니면 stdin 우선.
   - HUD 설정 `elements.rateLimits === false`이면 API 호출 안 함.
2. **디스크 캐시**
   - stdin 전체: `<worktree-root>/.omc/state/sessions/<CLAUDE_SESSION_ID>/hud-stdin-cache.json` (세션 ID 없으면 `<root>/.omc/state/hud-stdin-cache.json`). `JSON.stringify(stdin)` 그대로, **비원자적 `writeFileSync`**.
   - API 결과: `${CLAUDE_CONFIG_DIR:-~/.claude}/plugins/oh-my-claudecode/.usage-cache-<source>.json` (`source`=`anthropic` 등). 키: `timestamp`(ms), `data`, `error`, `errorReason`, `source`, `rateLimited*`, `lastSuccessAt`, `rateLimitIdentity`, `credentialIdentity`, `rateLimitBackoffs`. 파일 락 사용.
   - → Token Glance는 **이 캐시들에 의존하지 않는다** (OMC 내부 형식, 프로젝트별로 흩어짐, 경로·세션명 포함, 비원자적 쓰기). 자체 훅 캐시를 쓴다.
3. **실행 시간 요인**
   - `node` 프로세스 기동 + 다수 ESM 모듈 동적 import (수십 ms 이상 예상, 미측정).
   - usage API: 캐시가 유효하면(기본 폴링 90s, 실패 15s, 네트워크 오류 2m, 429는 최대 5m 백오프) 호출 안 함. 만료 시 **Keychain exec + HTTPS(10s timeout)를 statusline 실행 경로에서 await** → 수백 ms~수 초 가능.
   - 플러그인 캐시를 못 찾으면 `npm root -g` execFileSync(1.5s timeout) 폴백 (현재 환경에선 도달하지 않음).
   - 그 외 동기 fs I/O (stdin 캐시 쓰기, 업데이트 체크 캐시 읽기 등).
   - → PRD의 "훅이 먼저 저장을 끝낸다" 순서가 필수임을 재확인. Claude Code가 OMC 실행 중 다음 업데이트로 취소해도 우리 캐시는 이미 기록돼 있어야 한다.
4. **stdin 읽기 방식**: `process.stdin.isTTY`면 null. 아니면 `for await` 로 **EOF까지 전부** 읽어 `JSON.parse`. 파싱 실패 시 null(진단 출력).
   - → 체이닝 시 받은 stdin **바이트를 그대로** 자식 프로세스 stdin에 쓰고 **반드시 close(EOF)** 해야 한다. 재직렬화하지 말 것(필드 손실 방지).

### 3.3 체이닝 설계 (M2 구현)

```
Claude Code ──stdin──▶ token-glance-hook (no args)
                         1. stdin 전체를 EOF까지 읽어 원본 바이트 보관
                         2. rate_limits만 파싱 → 캐시 임시파일 → rename (실패해도 3 진행)
                         3. statusline-backup.json의 original_command를 /bin/sh -c 로 실행 (posix_spawn)
                            - 자식 stdin ← 1의 원본 바이트 (재직렬화 없음), 별도 스레드에서 쓰고 close
                            - stdout/stderr·환경변수 상속, 그 외 fd는 닫힘 (POSIX_SPAWN_CLOEXEC_DEFAULT)
                            - 자식은 자체 프로세스 그룹의 리더 (pgid = pid)
                            - 자식 exit code 그대로 반환, 시그널로 죽으면 128+sig
                         original_command 없음/빈 문자열/백업 파일 깨짐 → 출력 없이 exit 0
```

- 관리 명령: `token-glance-hook install | uninstall | status | repair` (Claude Code는 인자 없이 실행). 출력은 상태 단어만.
- 설치(`StatuslineInstaller`):
  - settings.json은 `statusLine` 멤버의 바이트만 편집 (`JSONTextEditor`). 기존 statusLine 객체가 있으면 `command` 값만 교체해 `type`/`padding` 등 보존. 없으면 마지막 멤버 뒤에 추가.
  - 쓰기 전 `settings.json.token-glance-backup-<UTC yyyyMMdd-HHmmss>` 전체 복사, 원래 권한 유지, 임시파일→rename.
  - `statusline-backup.json`에 원본 `command`와 statusLine 원문(JSON 텍스트)을 그대로 저장. 셸 변수 확장 문자열을 해석하지 않음.
  - 훅 바이너리는 `~/Library/Application Support/TokenGlance/bin/token-glance-hook`로 복사(755). settings.json에는 셸 인용된 절대 경로가 들어감(경로에 공백 포함).
  - 거부: JSON이 깨졌거나 객체가 아님(`settingsUnreadable`), 쓰기 불가(`settingsNotWritable`). 거부 시 어떤 파일도 만들지 않음.
  - `status`: notInstalled / installed / overwritten / hookMissing / settingsUnreadable. `repair`는 덮어쓴 새 command를 원본으로 채택해 재설치.
  - `uninstall`: statusLine이 아직 훅을 가리키면 원문 복원(원래 없었으면 키 제거, 설치가 만든 파일이면 삭제). 다른 command로 바뀌어 있으면 settings.json은 건드리지 않음.
- 시그널: 훅이 SIGTERM/SIGINT/SIGHUP을 받으면 자식 **프로세스 그룹**에 전달하고 자식 종료를 기다린 뒤 128+sig로 종료. 2단계 중 시그널이 오면 자식을 띄우지 않음.

**측정 (2026-10-09, release, M-series Mac, 합성 입력 1.3KB, 300회)**

| 항목 | p50 | p95 | 비고 |
|---|---|---|---|
| 프로세스 생성 기준선 (`/usr/bin/true`) | 1.45ms | 2.02ms | 비교용 |
| 훅 단독 (stdin → 캐시, 체이닝 없음) | 5.65ms | 7.26ms | 목표 20ms 이하 ✅ |
| 훅 + 체이닝 `cat >/dev/null` | 9.61ms | 11.24ms | |

- 순서: 자식이 `sleep 3`인 경우에도 캐시 기록 완료(훅 시작 후 4.9ms)가 자식 시작보다 앞섬 ✅. 단위 테스트(`cacheIsWrittenBeforeChildStarts`)로도 고정.
- 취소: SIGTERM/SIGINT → 자식과 복합 명령의 손자까지 종료, 좀비 0 ✅. **SIGKILL**은 가로챌 수 없어 자식이 끝까지 실행됨(고아, 좀비 아님) — OMC HUD는 자체 타임아웃 안에서 끝나므로 허용.

**실제 환경 검증 (2026-10-09, Claude Code 2.1.295 + OMC 5.6.1, 사용자 승인 후 설치)**

- `install` 후 settings.json 변경은 `statusLine.command` 한 줄뿐(다른 키 값·순서 동일, 텍스트 diff 확인). `statusline-backup.json`에 OMC command 원문 저장.
- 실행 중 세션과 새 세션 모두에서 훅이 캐시를 기록(허용 키 4개만). OMC HUD 정상 출력(사용자 확인).
- 수치: 5h는 캐시와 HUD 일치. 주간은 캐시 24% / HUD 25% — OMC HUD가 stdin 값과 비공식 OAuth usage API 값 중 큰 값을 표시하기 때문(3.2). 캐시는 Claude Code가 statusline에 넘긴 공식 값과 동일하다. API 값 자체는 OMC 캐시를 읽지 않는 원칙에 따라 확인하지 않음.
- OMC HUD 체이닝 구간 실행 시간은 측정하지 않음(측정하려면 HUD를 직접 실행해야 하고, 그러면 네트워크 호출이 일어날 수 있음).

### 3.4 Token Glance 캐시 포맷 (M2)

경로: `~/Library/Application Support/TokenGlance/claude-rate-limits.json` (`TOKEN_GLANCE_SUPPORT_DIR`로 디렉터리 교체 가능, 테스트·측정용).

```json
{
  "schema_version": 1,
  "claude_version": "2.1.295",
  "five_hour": { "used_percentage": 38, "resets_at": 1791433200, "observed_at": "2026-10-08T01:10:00Z" },
  "seven_day": { "used_percentage": 12, "resets_at": 1791788400, "observed_at": "2026-10-08T01:10:00Z" }
}
```

| 키 | 타입 | 비고 |
|---|---|---|
| `schema_version` | int | 현재 `1`. 리더는 모르는 버전을 "지원 안 함"으로 처리 |
| `claude_version` | string? | 마지막으로 기록한 입력의 `version` |
| `five_hour` / `seven_day` | object? | 없으면 생략 |
| `.used_percentage` | number | 입력 그대로 (0~100) |
| `.resets_at` | int | Unix epoch 초. 입력이 ms(≥1e12)거나 숫자 문자열이면 정규화 |
| `.observed_at` | string | ISO 8601 UTC(초 단위). **윈도우별** 기록 |

- 기록 금지: 경로, `session_id`, `session_name`, `prompt_id`, `cwd`, `transcript_path`, `workspace`, 비용·컨텍스트 값 등 위 표 외 모든 필드.
- 갱신 규칙: 윈도우별 독립 갱신. `used_percentage`와 `resets_at`이 **둘 다** 있는 윈도우만 교체하고, 없거나 불완전한 윈도우는 기존 값(과 그 `observed_at`)을 유지한다.
- `rate_limits` 키가 없거나 `null`이거나 쓸 수 있는 윈도우가 하나도 없으면 **파일을 쓰지 않는다**(기존 캐시 유지).
- 쓰기: 같은 디렉터리의 임시 파일에 쓴 뒤 `rename(2)` (원자적). fsync는 하지 않음(크래시 내구성보다 지연 우선).
- 동시성: Claude Code 세션 여러 개가 동시에 쓰면 마지막 rename이 이긴다. 서로 다른 윈도우를 거의 동시에 갱신하면 한쪽 갱신이 유실될 수 있으나 다음 statusline 갱신에서 회복된다.

---

## 4. 미확인 목록 (후속 검증)

| 항목 | 검증 방법 | 시점 |
|---|---|---|
| Codex `info: null`·반복 스냅샷·누적 감소, resume/fork 동작 | 세션이 더 쌓인 뒤 재검증 | 수시 |
| `rate_limits` 최소 Claude Code 버전 | changelog 확인 | M2 |
| stdin에 `rate_limits`가 없을 때의 형태 | API 키 사용자 또는 첫 응답 전 stdin 캡처 | M2 |
| Claude Code가 실제로 보내는 취소 시그널 종류 | 훅 SIGTERM/SIGINT 시 자식 그룹 정리는 확인됨(3.3). Claude Code가 SIGKILL을 쓰면 자식이 끝까지 실행됨 — 실제 시그널은 미확인 | 수시 |
| OMC HUD 실제 실행 시간 | 미측정(직접 실행 시 네트워크 호출 가능). 실제 사용에서 표시 이상 없음 | 수시 |
| `quotaLimits.rateLimitType`의 주간 값 이름 | 주간 한도 도달 시 관찰 | 수시 |
