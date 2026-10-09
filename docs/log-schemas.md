# Log / Hook Schema Notes

M0 검증 결과. 모든 확인은 **읽기 전용**으로, 키 이름·타입·값의 형태(자릿수, 문자 패턴)만 추출했다. 프롬프트/응답 본문, 경로, 식별자 값은 기록하지 않는다.

- 검증일: 2026-10-09
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
| 7.3 `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | ❓ | 이 머신에 `~/.codex/sessions` 없음 (Codex 세션 실행 이력 0). 실제 샘플 미확보 |
| 7.3 `token_count` / `rate_limits` 필드명 | ❓(간접 근거) | codex 바이너리 문자열에 필드명 존재, `resets_in_seconds`는 없음 |
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
| `message.usage.output_tokens_details.thinking_tokens` | int | ✅ | 일부 라인에만 (5,524/7,225) |
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

### 1.4 `type == "cost-state"` (참고)

`sessionId`, `totalCostUSD`(float, 일부 int), `totalAPIDuration`, `totalDuration`, `startTime`(int), `totalLinesAdded/Removed`, `hasUnknownModelCost`, `modelUsage: { <model>: { inputTokens, outputTokens, thinkingTokens, cacheReadInputTokens, cacheCreationInputTokens, webSearchRequests, costUSD } }`.
세션 누적 요약으로 보이며 57 라인뿐이라 집계 소스로 쓰지 않는다. 검증용 교차 체크 후보.

---

## 2. Codex CLI

### 2.1 로컬 상태 ❓

- `~/.codex/sessions/` **없음**. `CODEX_HOME` 미설정.
- `~/.codex/` 에는 SQLite DB들(`state_5.sqlite`, `logs_2.sqlite`, `goals_1`, `memories_1`, `queue_1`)과 `config.toml`, `auth.json`(읽지 않음) 등이 있다.
- `state_5.sqlite` `threads` 테이블: **0행**, `logs_2.sqlite` `logs`: **0행** → 이 머신에서 Codex 세션이 실행된 적 없음.
- `threads` 스키마에 `rollout_path TEXT NOT NULL`, `tokens_used INTEGER`, `cli_version`, `model` 컬럼이 있고, `rollout_migration_*` 테이블이 있다 → **rollout JSONL 파일은 여전히 존재하며 SQLite는 인덱스 역할**로 추정. 경로 형식은 미확인.
- 바이너리 문자열에 `archived_sessions` 존재 → 보관된 세션은 별도 디렉터리(`~/.codex/archived_sessions/`)일 가능성. 탐색 대상에 포함 검토.

### 2.2 `token_count` 이벤트 (간접 근거만) ❓

codex 0.155.1 바이너리 문자열 검색 결과(필드명 존재 여부만):

| 문자열 | 존재 |
|---|---|
| `token_count`, `total_token_usage`, `last_token_usage` | 있음 |
| `rate_limits`, `used_percent`, `window_minutes`, `resets_at` | 있음 |
| `cached_input_tokens`, `reasoning_output_tokens`, `model_context_window`, `plan_type`, `credits` | 있음 |
| `resets_in_seconds` (구버전 필드) | **없음** → `resets_at` 사용 |
| `wham/usage` | 있음 (비공식 API, 기본 OFF) |

예상 구조(공개 소스 기준, **실제 샘플로 미검증**):

```
{"timestamp": ISO8601, "type": "event_msg", "payload": {
  "type": "token_count",
  "info": null | { "total_token_usage": Usage, "last_token_usage": Usage, "model_context_window": int },
  "rate_limits": { "primary":   { "used_percent": float, "window_minutes": int, "resets_at": int(epoch s) },
                   "secondary": { ... }, "plan_type"?: string, "credits"?: object } } }
Usage = { input_tokens, cached_input_tokens, output_tokens, reasoning_output_tokens, total_tokens }
```

- 미확인 사항: 실제 경로/파일명, `info: null` 이벤트 빈도, 동일 누적값 반복 이벤트 존재 여부, `resets_at` 단위(초 추정), `primary`/`secondary`가 항상 5h/7d인지(`window_minutes`로 판별해야 함).
- **조치**: Codex 세션을 한 번 실행한 뒤 재검증 (M1 시작 전 권장). 그전까지 fixture는 synthetic.

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

### 3.3 체이닝 설계 메모 (M2 입력)

```
Claude Code ──stdin──▶ token-glance-hook
                         1. stdin 전체를 메모리로 읽음 (EOF까지)
                         2. rate_limits 4개 값만 추출 → cache tmp 파일 → rename (원자적)
                         3. 원래 statusLine.command 문자열을 /bin/sh -c 로 실행
                            (쉘 변수 확장 유지; 경로 직접 해석 금지)
                            - 자식 stdin ← 1의 원본 바이트, write 후 close
                            - 자식 stdout/stderr → 그대로 상속 (HUD 출력이 Claude Code에 표시됨)
                            - 자식 exit code 전달
```

- 원본 command는 설치 시 백업 파일에 그대로 저장, 제거 시 복원.
- 자식 환경변수는 그대로 상속 (`CLAUDE_SESSION_ID`, `CLAUDE_CONFIG_DIR` 등 OMC가 사용).
- 2단계는 파싱 실패해도 3단계를 반드시 실행 (사용자 statusline이 깨지지 않게).
- 훅은 OMC보다 오래 살아 있을 필요가 없도록 자식 대기 외 추가 작업 없음. Claude Code가 훅을 취소(SIGTERM 추정)하면 자식도 함께 정리되는지 M2에서 확인 ❓.
- OMC 업데이트/`omc-setup` 재실행 시 statusLine 덮어쓰기 가능 → 앱에서 "설치됨/덮어씀" 상태 점검.

---

## 4. 미확인 목록 (후속 검증)

| 항목 | 검증 방법 | 시점 |
|---|---|---|
| Codex rollout 경로·`token_count` 실제 구조 | Codex 세션 1회 실행 후 같은 방식으로 키/타입 추출 | M1 전 |
| `rate_limits` 최소 Claude Code 버전 | changelog 확인 | M2 |
| stdin에 `rate_limits`가 없을 때의 형태 | API 키 사용자 또는 첫 응답 전 stdin 캡처 | M2 |
| Claude Code 취소 시그널과 자식 프로세스 정리 | 훅 프로토타입으로 측정 | M2 |
| OMC HUD 실제 실행 시간 | 훅 프로토타입에서 체이닝 구간 측정 (네트워크 호출 유발에 주의) | M2 |
| `quotaLimits.rateLimitType`의 주간 값 이름 | 주간 한도 도달 시 관찰 | 수시 |
