# PRD: Token Glance - Claude Code / Codex 한도 잔여량 메뉴바 앱

> 상태: Draft v1.0 (M0~M5 구현·병합, 온라인 한도 조회 옵션(§7.4, §7.5) 병합, M6 릴리스 준비 중. 2026-10-10)
> 한 줄 설명: Claude Code & Codex usage limits at a glance, in your macOS menu bar.
> 오픈소스 프로젝트 (MIT). 개발은 Claude Code로 진행.
> `[확인 필요]`는 구현 전에 실제 로컬 데이터로 검증할 가정이다.

## 1. 배경 / 문제

- Claude Code(Pro/Max)와 Codex CLI(ChatGPT 플랜)는 **구독 플랜 기준 한도(5시간 세션 / 주간)** 로 사용량이 제한된다.
- 지금은 한도 확인을 위해 터미널에서 `/usage`, `/status`를 치거나 도구별로 따로 확인해야 한다.
- 두 도구의 "얼마나 남았고, 언제 초기화되는지"를 나란히 보여주는 상시 노출 UI가 필요하다.

## 2. 목표 (Goals)

1. 메뉴바에서 Claude Code와 Codex의 **세션(5시간) / 주간 한도 잔여량과 초기화 시각**을 한눈에 본다.
2. 별도 로그인/API 키 입력 없이 동작한다 (zero-config, 가능한 한 공식 경로 우선).
3. 가볍다 (idle CPU ~0%, 메모리 50MB 이하).
4. 오픈소스 품질: 테스트, CI, README, 데모 GIF, 릴리스 자동화.

## 3. 용어 정리 (중요)

- 요청 중 "일간"은 두 서비스에서 **5시간 롤링 세션 윈도우**에 해당한다. 일 단위 한도는 없다.
  - 표기: **세션(5h)** = 사용자가 말한 "일간 잔여/초기화", **주간(7d)** = 주간 잔여/초기화.
- 구독 플랜의 한도는 **토큰 수가 아니라 비율(%)** 로만 노출된다. 절대 "남은 토큰 수"는 제공되지 않는다.
  - 따라서 메인 지표는 `잔여 % + 초기화까지 남은 시간`.
  - 보조 지표로 로컬 로그에서 계산한 **실제 사용 토큰 수**(오늘/주간)를 함께 표시한다.

## 4. 비목표 (Non-Goals, v1)

- 팀/조직 집계, 클라우드 동기화
- 다른 도구(Cursor, Gemini 등) 지원 (Provider 구조로 확장 여지만 둠)
- API 키 사용자의 비용 청구 정확도
- Windows/Linux
- 사용량 제한/차단 (읽기 전용)

## 5. 타깃 사용자

- Claude Code와 Codex CLI를 구독 플랜으로 함께 쓰는 개발자
- macOS 14+ (Apple Silicon 우선)

## 6. 핵심 시나리오

1. 작업 중 메뉴바만 보고 `Claude 세션 62% 남음 / Codex 세션 80% 남음`을 확인한다.
2. 클릭하면 상세 패널에서 세션/주간 잔여 게이지, 초기화까지 남은 시간(카운트다운), 오늘 사용 토큰을 본다.
3. 알림을 켜면 잔여량이 임계값(기본 30%, 10%)을 하향 통과할 때 알림을 받는다.
4. 로그인 시 자동 실행되어 신경 쓰지 않아도 갱신된다.

## 7. 데이터 소스 전략 (핵심)

### 7.1 Claude Code - 한도 잔여량

로컬 로그(JSONL)에는 **사용률(%) 정보가 없다.** 한도에 걸려 요청이 거절된 경우에만 assistant 라인에 `quotaLimits`(`rateLimitType`, `resetsAt`, % 없음)가 기록되며, 이는 보조 신호 후보이며 현재 미구현이다. 한도 %를 추정하지 않는다. 메인 소스는 아래 경로다.

| 우선순위 | 방법 | 설명 | 비고 |
|---|---|---|---|
| **1 (기본)** | **Statusline 훅** | Claude Code는 statusline 스크립트에 stdin JSON으로 `rate_limits.five_hour / seven_day` 의 `used_percentage`, `resets_at`(Unix epoch)을 전달한다. 앱이 제공하는 작은 스크립트를 `statusLine`으로 등록하면, 스크립트가 해당 JSON을 앱의 캐시 파일에 기록하고 앱은 이를 감시(FSEvents)한다. | 공식 문서화된 기능. 네트워크/토큰 접근 불필요. Pro/Max 구독자 + 첫 API 응답 이후에만 값 존재. 필드 형태 확인됨(`used_percentage` 숫자(관찰값 정수, Double로 파싱), `resets_at` Unix **초**). Claude Code 2.1.295에서 존재 확인, 최소 버전은 미확인 |
| 2 (옵션, 기본 OFF) | Claude Code `get_usage` 위임 조회 (§7.5) | 설치된 `claude`를 헤드리스 자식으로 실행해 control 요청 `get_usage`를 보낸다. Claude Code가 자기 로그인으로 서버의 usage 엔드포인트를 조회한다. 앱은 Keychain·토큰에 접근하지 않는다. | **공식 지원 경로 아님**: control 요청은 실험적(SDK 메서드명 `usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET`)이고 서버 엔드포인트는 무문서. 앱이 토큰으로 엔드포인트를 직접 호출하는 방식은 약관 문구(자격증명 수집·중개 금지) 때문에 쓰지 않는다 |

- **훅 구현 규칙 (성능/정확도)**: Claude Code는 statusline 업데이트를 300ms 디바운스하고, 스크립트가 실행 중일 때 새 업데이트가 오면 진행 중인 스크립트를 **취소**한다. 따라서 (1) stdin을 먼저 읽어 **캐시 파일에 원자적으로(임시파일 → rename) 기록한 뒤**, (2) 그 다음에 기존 statusline(OMC 등)에 동일 stdin을 그대로 넘기고 출력을 전달한다. (3) 훅은 jq 의존 없이 Foundation만 사용하고 네트워크 호출은 하지 않는다. (4) **M2 구현 규칙**: 자식을 별도 프로세스 그룹으로 띄워 SIGTERM/SIGINT를 그룹 전체에 전달하고, 원본 바이트는 별도 스레드로 써서 자식이 stdin을 안 읽어도 막히지 않게 하며, 다른 파일 디스크립터는 상속하지 않는다. 지연을 줄이기 위해 fsync는 생략한다(원자적 rename만). 측정: release 빌드 p50 5.7ms / p95 7.3ms, 케이스에서 캐시 기록은 이어서 실행되는 명령보다 약 4.9ms 만에 완료. 채널 실행 시간을 측정해 예산(예: 훅 자체 < 20ms)을 테스트한다.
- **개발 환경(예시)**: oh-my-claudecode(OMC) 설치 중. **확인됨**: `~/.claude/settings.json`의 statusLine은 `{"type":"command","command":"node ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hud/omc-hud.mjs"}` (OMC HUD). command는 쉘 변수 확장(`${...:-...}`)을 포함하므로, 체이닝 시 원본 command **문자열을 그대로 저장해 쉘에서 실행**한다(경로를 직접 해석하지 말 것). 원본은 백업 파일에 보관하고 제거 시 복원한다. OMC HUD는 node 프로세스라 시작 비용이 있고(수십 ms), 한도 캐시(기본 90초)가 만료되면 Keychain과 비공식 usage API 호출을 statusline 실행 경로에서 기다리므로 **수 초**까지 걸릴 수 있다(M0 분석). 훅은 반드시 그보다 앞에서 저장을 끝낸다. OMC 내부 캐시(`.omc/state/...`, `.usage-cache-*.json`)에는 의존하지 않는다(내부 형식, 프로젝트별 분산, 경로/세션명 포함, 비원자적 쓰기). 체이닝 시 받은 stdin 바이트를 재직렬화 없이 그대로 자식 stdin에 쓰고 반드시 close(EOF)한다. 따라서 **체이닝은 P0**로 격상한다. OMC가 업데이트/재설치로 statusLine을 덮어쓸 수 있으므로 훅 상태 점검(설치됨/덮어씁움)과 재설치 버튼도 제공한다.
- 기존 statusline이 이미 설정된 사용자를 위해 **체이닝** 지원: 앱 스크립트가 stdin을 캐시에 저장한 뒤 기존 스크립트로 그대로 전달한다.
- 설정 변경(`~/.claude/settings.json`)은 **사용자 동의 후**에만, 백업을 남기고 수행한다. 앱 내 "설치/제거" 버튼 제공.
- **수치 차이**: OMC HUD는 stdin 값과 자체 비공식 API 값 중 **큰 값**을 보여주므로 Token Glance와 1%p 정도 다를 수 있다(실측: 주간 24% vs 25%, 5시간은 일치). Token Glance는 Claude Code가 제공하는 공식 stdin 값을 쓴다. 또한 HUD는 사용률을, 앱 기본 라벨은 남은 %를 보여주므로 UI에서 `N% used / M% left`를 함께 표기하고 라벨은 "남은 %/사용 %"를 설정으로 선택하게 한다.
- **캐시 갱신**: 캐시는 5시간/주간 윈도우별로 독립 갱신하고 관측 시각도 윈도우별로 기록한다. 마지막 관측 후 7일이 지나면 오래된 값으로 처리한다. 캐시 위치: `~/Library/Application Support/TokenGlance/claude-rate-limits.json`(스키마 v1, 허용 키만 기록).
- 제약: Claude Code 세션이 한 번도 실행되지 않았거나 오래 비활성이면 값이 오래될 수 있다 → 마지막 갱신 시각 표시, `resets_at`이 지났으면 "초기화됨(0%)"로 처리.

### 7.2 Claude Code - 토큰 사용량 (보조)

- `${CLAUDE_CONFIG_DIR:-~/.claude}/projects/**/*.jsonl` **(확인됨)**. 서브에이전트 로그가 `<session>/subagents/*.jsonl`에 중첩되므로 **재귀 탐색**한다.
- `type == "assistant"` 의 `message.usage`: `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens` (확인됨). 분류용 추가 필드: `cache_creation.ephemeral_5m/1h_input_tokens`, `output_tokens_details.thinking_tokens`(일부 라인에만).
- **중복 제거 (M0에서 규칙 변경)**: 한 API 응답의 콘텐츠 블록마다 라인이 기록되어 assistant 7,225줄 중 고유 키는 3,194개였고, 중복 간 `output_tokens`가 달랐다(단조 증가). 따라서 키 = `message.id` + `requestId`(없으면 `message.id`)로 **전역(파일 간 포함)** dedupe하고, 키별로 **`output_tokens`가 최대인 usage(= 마지막 줄)** 를 채택한다. 첫 줄 채택 금지. `message.model == "<synthetic>"` 줄은 제외한다.
- 집계: 오늘 / 주간(주간 윈도우 시작 = 주간 `resets_at` - 7d) / 모델별

### 7.3 Codex - 한도 잔여량 + 토큰

- **검증 이력: M1-A에서 rollout 1개(60줄)로 구조를 검증했다. PR #3에서는 새 세션·기존 세션·재시작 후 세션 재개를 실제 사용으로 추가 검증했다.** 세션이 1개라 관찰 범위가 작다. `info: null` 이벤트, 동일 누적값 반복, 누적값 감소는 관찰되지 않았으므로 파서가 모두 방어한다(`codex-edge-cases.synthetic.jsonl`). 상세는 `docs/log-schemas.md` 2장.
- 경로: `~/.codex/sessions/YYYY/MM/DD/rollout-<로컬시각>-<uuid>.jsonl` **(확인됨)**, `CODEX_HOME` 존중. 보관 세션(`archived_sessions/`)도 탐색 대상.
- `event_msg` 중 `payload.type == "token_count"`:
  - `info.total_token_usage` (세션 누적), `info.last_token_usage` (직전 턴)
  - `rate_limits.primary` / `secondary`: `used_percent`, `window_minutes`, `resets_at`. **5시간/주간은 이름이 아니라 `window_minutes`로 구분**한다(관찰값 300 / 10080).
  - **`input_tokens`는 cached를 포함한다(Claude와 다름)** → `input - cached`로 정규화.
  - 모델명은 `turn_context.payload.model`에서 가져오며, 한 세션 안에서 바뀔 수 있다(직전 turn_context 기준).
  - 신규 필드 기록(v1 미사용): 라인 타입 `token_usage_record`, `cache_write_input_tokens`, `rate_limits.limit_id`, `credits`.
  - reasoning 토큰은 output의 일부로 표시만 하고 total에 다시 더하지 않는다.
- 기본 설정에서 Codex는 **로컬 로그만으로** 한도 잔여량과 초기화 시각을 얻는다. 가장 최신 이벤트의 `rate_limits`를 사용.
- 토큰 집계는 누적값이므로 세션별 delta로 계산 (이중 집계 방지).
- 비공식 API 직접 조회는 보류한다. M5에서는 인증 파일/Keychain 접근과 네트워크 요청을 추가하지 않았다.
- 로컬 rollout에 기록되지 않는 Aside 사용분과 계정 한도 조회는 별개의 문제다. 계정 한도에 Aside가 포함되는지는 미확인이다.

### 7.4 Codex 온라인 한도 조회 (M5와 분리된 작업)

- 설정 **Codex 온라인 한도 조회**는 기본 OFF다. OFF에서는 App Server를 시작하지 않고 온라인 요청도 하지 않는다. 켜기 전 설치된 Codex 자식 프로세스가 기존 로그인을 사용해 외부 요청을 할 수 있음을 설명하고 동의를 받는다. 앱과 진단 스크립트는 인증 파일이나 Keychain을 직접 읽지 않는다.
- 설치된 codex-cli **0.162.0**의 생성 JSON 스키마에서 `account/rateLimits/read`, `account/rateLimits/updated`, `account/usage/read`가 확인됐다. 공식 [App Server 문서](https://learn.chatgpt.com/docs/app-server)의 stdio 줄 단위 JSON 연결을 사용하며 `initialize` 뒤 `initialized`를 보낸다. 설치 버전의 지원 여부를 우선 확인하고, 지원하지 않으면 업데이트 필요 버전과 대안을 안내한다. 승인 없이 Codex를 업데이트하지 않는다.
- 5분 주기와 수동 새로고침으로 `account/rateLimits/read`를 조회한다. `account/rateLimits/updated`는 보조 신호다. 다른 클라이언트의 모든 사용이 즉시 통지된다고 가정하지 않는다. 타임아웃, 동시 요청 중복 방지, 429 백오프, 연결 종료·재연결·취소 시 자식 프로세스 정리를 처리한다. 로그인/로그아웃과 상태 변경 메서드는 호출하지 않는다.
- `limitId`별 버킷을 분리한다. `primary`/`secondary` 이름 대신 윈도우 길이로 세션·주간을 구분한다. `usedPercent`가 없으면 해당 윈도우를 표시하지 않고, 윈도우 길이를 모르면 세션·주간으로 추정하지 않으며, `resetsAt`이 null이면 초기화 시각을 `--`로 표시한다. 계정 식별자도 null일 수 있다. API-key 로그인과 ChatGPT 구독 로그인을 구분하고, 로그인 필요·미지원 상태를 표시한다.
- 유효한 계정 조회 결과가 있으면 한도 표시에서 로컬 스냅샷보다 우선한다. 실패 시 사유와 함께 로컬 한도로 폴백한다. 출처와 마지막 관측 시각을 표시하고, 오래된 응답이나 다른 계정/버킷의 값을 섞지 않는다. 초기화 시각이 지났다는 이유만으로 실제 한도 복구를 확정하지 않는다.
- 로컬 rollout에는 검증된 계정 식별자가 없으므로 폴백의 계정 귀속은 미확인으로 표시한다. 온라인 버킷과 로컬 스냅샷을 합치지 않는다.
- 토큰 상세·모델별 집계는 로컬 로그만 사용한다. `account/usage/read`는 필드·기간·집계 범위 조사 대상으로만 두며 서버 토큰 합계를 로컬 합계에 더하지 않는다. Aside 귀속은 비교 검증 전까지 미확인이다.

### 7.5 Claude 온라인 한도 조회 (M5와 분리된 작업)

- 설정 **Claude 온라인 한도 조회**는 기본 OFF다. OFF에서는 자식 프로세스·네트워크 요청·자격증명 접근이 0이다. 켜기 전 동의 대화상자에 외부 요청, Claude Code 로그인의 읽기 전용 사용, 공식 지원 경로가 아님(변경 가능), 약관 확인은 사용자 책임, 끄면 즉시 중단을 명시한다.
- 조사 결과(2026-10-10, Claude Code 2.1.296): 구독 한도를 읽는 **안정적인 공식 API는 없다**. 공식 문서에는 statusline stdin `rate_limits`(현재 기본 경로)와 Agent SDK의 `/usage` → `usage_report`(experimental)가 있다. 앱이 OAuth 토큰으로 `api/oauth/usage`를 직접 호출하는 방식은 Claude Code Legal and compliance의 "developers may not collect, store, or intermediate Claude.ai credentials or session tokens" 문구에 걸리므로 쓰지 않는다.
- 구현: 조회 1회마다 `claude -p --input-format stream-json --output-format stream-json --verbose --no-session-persistence --safe-mode --strict-mcp-config`를 실행하고 `initialize`, `get_usage`(`skip_behaviors: true`)를 보낸 뒤 응답을 받으면 바로 종료한다. 프롬프트를 보내지 않으므로 모델 요청은 없다. `DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING`, `DISABLE_AUTOUPDATER`를 켠다. `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`는 usage 조회까지 막으므로 설정하지 않는다. Claude 폴더 지정이 있으면 `CLAUDE_CONFIG_DIR`로 넘긴다.
- 자격증명: 앱은 Keychain 항목(`Claude Code-credentials`)과 인증 파일을 읽거나 쓰지 않는다. 따라서 ad-hoc 서명 빌드마다 Keychain 권한 프롬프트가 생기지 않는다. 자식 Claude Code는 자기 동작대로 로그인을 갱신하고 Keychain에 다시 쓸 수 있으며, usage 스냅샷을 자기 상태에 캐시한다(엔드포인트 재요청을 스스로 줄임).
- 갱신: 시작, 웨이크, 5분 폴링, 수동 새로고침, Claude 윈도우 초기화 시각. 타임아웃 20초, 진행 중 조회 공유(중복 방지), 실패 시 지수 백오프(60초부터 두 배, 최대 30분, 성공 시 초기화), 시작·웨이크 직후 일시적 실패는 5초·15초 뒤 재시도. 옵션 OFF·Claude 비활성화 시 진행 중 조회와 자식을 취소한다. Claude Code는 429 여부를 알려주지 않고 `rate_limits: null`로 답하므로 이를 "지금 읽을 수 없음"으로 표시하고 백오프한다.
- 윈도우: `rate_limits.limits[]`의 `kind`로 구분한다(`session` → 세션, `weekly_all` → 주간). `weekly_scoped`(모델별)와 알 수 없는 kind는 무시하고, 같은 kind가 둘 이상이면 표시하지 않는다. `limits[]`가 없을 때만 `five_hour`/`seven_day`를 쓴다. 이 응답에는 윈도우 길이 필드가 없다.
- 결합: 15분 이내의 유효한 온라인 값이 있으면 한도 표시에서 훅 캐시보다 우선한다. 실패·오래됨이면 훅 캐시로 폴백하고 사유, 출처, 마지막 관측 시각을 표시한다. 두 값을 평균·합산하지 않고, 훅 캐시 값이 다르면 상세 패널에 함께 보여준다. 오래된 응답은 새 값을 덮어쓰지 않는다. 초기화 시각이 지난 윈도우는 0%로 표시하지 않고 새 관측을 기다린다(온라인·폴백 모두). 토큰 합계·모델별 집계는 로컬 로그만 쓴다.

## 8. 기능 요구사항

### 8.1 메뉴바 라벨 (P0)

- **두 줄 레이아웃**: 윗줄 Claude 아이콘 + 잔여 %, 아랫줄 Codex 아이콘 + 잔여 %. 클릭 없이 바로 확인.
  ```
  [C] 62%
  [X] 80%
  ```
- **렌더링 확정 (ADR 0001)**: SwiftUI `MenuBarExtra`는 두 줄 라벨이 첫 줄만 크게 나오고 색이 사라져 부적합. **`NSStatusItem` + 직접 그린 `NSImage`(템플릿 아님, 시스템 동적 색 사용)** 로 확정. 노치가 있는 화면은 메뉴바 높이가 약 33pt인 점을 고려한다.
- 기본 값은 세션(5h) **남은 %**. 표시 모드: 남은 %(기본) / 사용 %. 반올림 규칙: 사용 %는 반올림, 남은 % = 100 − 사용 %. 임계값: 남은 30% 이하 주황, 10% 이하 빨강. (추가 표시 모드 후보: 초기화까지 남은 시간)
- 도구별 on/off (하나만 켜면 한 줄 레이아웃으로 전환)
- 임계값 색상 (잔여 30% 이하 주황, 10% 이하 빨강)
- 데이터가 없거나 오래된 경우 `--` 표시 및 툴팁에 사유 표시
- 약 9~10pt 고정폭 숫자와 서비스 식별용 마크(윗줄 Claude 마크, 아랫줄 OpenAI Blossom, 두 줄 10pt·한 줄 13pt)를 사용한다. 마크는 공식 배포 파일의 경로를 그대로 균일 축소해 단색(labelColor)으로 채우고, 경고 색은 숫자에만 쓴다. 파일을 못 읽으면 중립 C/X 배지로 폴백한다. 출처·확인한 조건·미해결 사항(Anthropic 사전 승인 등)은 `docs/trademarks.md`. 일반/노치 메뉴바, Retina, 외관 변경을 검증한다.

### 8.2 상세 패널 (P0)

- **M5 변경**: `NSPopover` 대신 메뉴바 항목 아래에 뜨는 테두리 없는 패널(블러 배경, `.popover` 머티리얼)을 쓴다. 화살표 꼬리는 없다. Esc, 바깥 클릭, 항목 재클릭으로 닫히고, 닫히면 SwiftUI 뷰를 해제한다. 이유: `NSPopover`를 열 때마다 그래픽 메모리가 순간 115~150MB 잡혔다(AppKit 내용만 넣은 분리 실험에서도 재현, 같은 내용의 패널은 14~16MB). 상세는 `docs/perf.md`.

- M3 구현 추가 규칙: 각 윈도우는 `N% used / M% left`를 함께 표기, 초 단위 카운트다운(Date 기반, 파일 재읽기 없음), 초기화 후 문구 "Window reset — waiting for new data".

- Claude Code / Codex 두 섹션
- 각 섹션: 세션(5h) 게이지 + 잔여 % + 초기화 시각(절대시각 + 카운트다운), 주간(7d) 게이지 + 잔여 % + 초기화 시각
- 게이지 채움은 메뉴바 표시 모드를 따른다: 남은 %(기본)면 남은 양, 사용 %면 사용한 양. 색 임계값은 모드와 무관하게 남은 % 기준, 값이 없으면 빈 회색 막대(M6).
- 온라인 조회의 한도 출처와 관측 시각은 각각 별도 줄로 표시한다(긴 영어 날짜가 잘리던 문제, M6).
- 사용 토큰: 오늘 / 이번 주간 윈도우, 분류(input/output/cache), 모델별
- 데이터 신선도: "마지막 갱신 3분 전"
- 새로고침, 설정, 종료

### 8.3 갱신 (P0)

- 파일별 inode/크기/수정시각/byte offset을 유지해 추가된 바이트만 읽는다. 미완성 줄 이월, truncate/교체/삭제, Claude 전역 dedupe와 Codex 누적값 delta를 유지한다.
- 인덱스는 메모리 전용. 최초 스캔은 백그라운드에서 진행률 표시. M4 관찰: 약 1.4초, 약 175MB 읽음.
- FSEvents 이벤트를 1.5초 단위로 묶고 관련 JSONL/훅 캐시만 갱신한다. 결과가 같으면 UI 재계산을 생략한다.
- 열린 파일의 이어 쓰기 이벤트 지연은 이 머신에서 관찰한 결과이며 Apple의 일반적 보장/제약으로 단정하지 않는다.
- Codex 보완(PR #3): 2초마다 감시 대상 rollout의 크기를 stat으로 비교한다. 최근 15분 내 증가를 관찰한 파일, 첫 스캔 이후 새로 발견한 파일, 최근 24시간 내 수정된 파일을 포함한다. 변화가 있으면 증분 읽기만 한다.
- 24시간 넘게 쉬었던 세션 재개는 5분 폴백에 의존할 수 있다. 모든 세션의 2초 갱신을 보장하지 않는다.
- 5분 폴백 폴링, 수동 새로고침, 웨이크 후 재스캔 유지. 카운트다운은 Date 기반 1초 UI 타이머이며 파일 재파싱을 하지 않는다.
- PR #3 실제 검증: 새 세션 0.03초, 가장 최근 기존 세션 1.4초, 재시작 후 이전 세션 재개 1.4초. 검증한 세 경우의 결과다.
- M4 측정: CPU 평균 2.37%→0.31%, footprint 최고 208MB→47MB, 새로고침 약 0.87초→평균 12.9ms. 이후 측정의 로그 활동이 더 적었다는 조건 차이도 명시한다.
- PR #3 측정: Codex 사용 포함 5분, CPU 평균 0.25%, footprint 평균 24MB/최고 44.9MB. 방법·조건은 docs/perf.md 참조.

### 8.4 설정 (P1)

- **M4 구현 규칙**: 로그 폴더 지정이 `CLAUDE_CONFIG_DIR`/`CODEX_HOME`보다 우선하고(경로 검증 실패 시 사유 표시), 최소 한 도구는 켜져 있어야 한다. 훅의 settings.json 위치는 Claude 폴더 지정을 따른다. Install/Repair 전 동의 대화상자를 표시한다. 로그인 시 실행(SMAppService)은 ad-hoc 서명 앱에서도 등록/해제 동작을 확인했고, 앱의 현재 위치에 묶인다(이동 후 다시 켜야 함).

- 로그인 시 자동 실행 (`SMAppService`)
- Claude statusline 훅 설치/제거 (백업/복원). 구현 규칙(M2): settings.json 전체 타임스탬프 백업, `statusLine` 키만 수정(나머지 바이트 보존), 원래 권한 유지, 깨진 JSON/쓰기 불가 파일은 거부, 원본 command는 문자열 그대로 백업. 상태 5종(notInstalled / installed / overwritten / hookMissing / settingsUnreadable)과 `repair`. 훅 바이너리는 `~/Library/Application Support/TokenGlance/bin/`에 복사. CLI: `token-glance-hook install|uninstall|status|repair`.
- 현재 설정: 남은/사용 표시, 도구 켜기/끄기, 로그 경로, 로그인 시 실행, 훅 관리.
- 도구를 끄면 그 도구의 로그는 읽지 않되 인덱스는 유지한다. 다시 켜면 그동안 추가된 바이트만 읽어 즉시 표시한다(실측 21~26ms, 새로 읽은 바이트 0). 이전에는 다시 켤 때 전체 로그를 재파싱했다.
- 설정 창은 크기 조절이 가능하고 폼이 스크롤된다. 화면 높이에 맞춰 열린다.
- M5 설정: 알림 토글·임계값, 언어(시스템/한국어/영어). 비공식 API 옵션은 추가하지 않는다.
- Codex 온라인 한도 조회 옵션은 기본 OFF이며 §7.4의 별도 작업에서 추가한다.
- Claude 온라인 한도 조회 옵션은 기본 OFF이며 §7.5의 별도 작업에서 추가한다.
- 로그인 등록/해제는 확인됨. 로그아웃·재로그인 후 자동 실행은 사용자 확인이 남아 있다.

### 8.5 알림 (P1, M5 구현 완료)

- 기본 OFF. 사용자가 켰을 때만 UserNotifications 권한을 요청한다. 거부/미결정 상태와 시스템 설정 안내를 제공한다.
- 도구별·세션/주간별 남은 %가 기본 30%/10%를 하향 통과할 때 알린다. 표시 모드와 무관하게 남은 %로 판정한다.
- 최초 관측/앱 시작은 기준 상태만 설정한다. 없음/오래됨/깨진 데이터는 알림을 생성하지 않는다.
- 같은 윈도우·임계값 중복을 방지한다. 최소 상태(provider, kind, resetsAt, threshold)를 저장해 재시작에도 억제한다. 원문/경로/계정은 저장하지 않는다.
- 초기화 알림은 유효한 이전 관측과 새 관측을 바탕으로 판정한다. resetsAt 경과만으로 실제 한도 복구가 확인됐다고 알리지 않는다. 종료/슬립 중 놓친 알림은 소급 발송하지 않는다.
- 초기화 직전 알림은 이번 범위에서 제외한다. 시간과 전송 인터페이스를 주입해 테스트한다.
- 판정은 표시값(반올림한 남은 %) 기준이다. 위험 임계값을 한 번에 넘으면 경고도 처리한 것으로 기록하고 위험 알림만 보낸다. 새 윈도우 시작 알림은 이전 관측이 경고 이하였을 때만 보낸다.
- 검증 구분: 알림 권한 요청과 테스트 배너 수신은 실제 앱에서 사용자 확인. **실제 임계값 통과 알림은 자동 테스트로만 검증**했다(실제 한도를 소모해 유도하지 않음).

### 8.6 차트 / 비용 추정 (P2, M5 구현 완료)

- 별도 기록 창에 최근 14일의 도구별 일별 토큰을 막대로 표시한다. **Swift Charts를 쓰지 않고 SwiftUI 기본 도형으로 그린다**: Swift Charts는 다시 그릴 때마다(데이터 변경, 창 포커스 변경) 그래픽 메모리를 순간 약 100MB 잡았다(분리 실험에서 재현, 애니메이션 끄기·이미지 렌더링으로도 해결 안 됨). 값 축 눈금은 `AxisTicks`(테스트 대상)로 계산하고, 창은 1분마다 일별 합계 스냅샷을 비교해 바뀐 경우에만 다시 그린다. input/output/cacheRead/cacheWrite는 기존 정규화 규칙을 유지하고 reasoning을 total에 중복 가산하지 않는다.
- 날짜 경계는 주입한 Calendar/시간대를 따른다. 로그 없음과 확인된 0을 구분하고 로컬 로그 기반 집계임을 표시한다.
- 주간 집계와 별개로 14일 차트 범위를 보존한다. 메모리 정리가 오래된 날짜 합계를 지워 결과를 틀리게 만들지 않도록 회귀 테스트한다.
- 차트 열기 시 전체 재파싱하지 않는다. 최소 수치 집계만 메모리에 유지하며 이력 DB는 추가하지 않는다.
- 비용 추정·사용 페이스 예측은 제외한다.

### 8.7 로컬라이즈 (P1, M5 구현 완료)

- 한국어/영어 및 시스템 언어 기본값. 툴팁, 상세 패널, 설정, 오류, 동의 대화상자, 알림을 포함한다.
- Core는 사용자용 영어 문장 대신 상태/값을 반환하고 App에서 번역한다. 숫자·날짜·단위는 Locale 기반 표시.
- SwiftPM/번들 스크립트에서 리소스 포함을 검증한다. String Catalog가 현재 빌드 환경에서 지원되지 않으면 .strings/.stringsdict로 구현하고 이유를 기록한다.
- **구현(ADR 0002)**: Command Line Tools의 SwiftPM은 String Catalog를 컴파일하지 않으므로 `TokenGlanceText` 모듈의 `en.lproj`/`ko.lproj` `Localizable.strings`를 쓴다. 언어는 인스턴스별로 고르므로 재시작 없이 전환된다. 두 표의 키와 서식 지정자 일치를 테스트한다. 번들 스크립트가 리소스 번들을 `Contents/Resources`에 복사한다.

## 9. 비기능 요구사항

| 항목 | 요구 |
|---|---|
| 성능 | idle CPU < 1%, 메모리 < 50MB, 증분 갱신 < 200ms. 메모리는 Activity Monitor의 메모리(physical footprint) 기준이며 순간 최고치는 별도 관리(RSS는 참고용). 조건·측정 방법은 `docs/perf.md` 참조 |
| 성능 측정 정의 (M5~M6) | **CPU**: `ps` CPU 시간 증분의 평균(5초 간격). **footprint 평균/정착값**: `footprint` 1초 표본. **구간 최대**: 해당 구간 표본의 최대. **lifetime peak**: `vmmap`의 프로세스 수명 최대(시작·첫 스캔·지금까지 연 모든 창 포함). 상태는 "창을 연 적 없음"과 "창을 한 번이라도 사용함"을 구분한다. 온라인 옵션 ON의 자식 프로세스는 따로 기록한다 |
| 성능 실측 (M6 반복 사용) | 온라인 OFF, 패널·설정·기록 창 각 30회 열고 닫기(총 93회, 22분): CPU 평균 0.77%(휴식 구간 0.02~0.53%). footprint 창 사용 전 18MB → 한 번 사용 후 42MB(설정 창이 +15MB) → 90회 반복 동안 42~45MB에서 정착, 마지막 44MB. 반복에 따른 증가 없음. 1초 표본 최대 48MB, lifetime peak 48.5MB. 수천 회·수일 가동은 미측정 |
| 프라이버시 | 프롬프트/응답 내용은 저장·전송하지 않음. 수치 메타데이터만 사용. 기본 설정에서 외부 네트워크 호출 0 |
| 보안 | 앱/진단 스크립트는 인증 파일·Keychain을 직접 읽지 않음. Codex 온라인 옵션의 인증은 설치된 App Server에, Claude 온라인 옵션의 인증은 설치된 Claude Code에 위임. 토큰·계정 정보 저장 금지. 훅 관리 백업에는 사용자 설정이 포함되므로 권한 보호 |
| 안정성 | 파싱 실패 라인 skip, 스키마 변경에 방어적, 값 누락 시 graceful degrade |
| 권한 | dot-folder 읽기 필요 → App Sandbox OFF, 직접 배포 |
| UI | 다크/라이트, Dock 아이콘 없음(`LSUIElement`), 한국어/영어 |

## 10. 기술 스택

- **Swift 5.10+ / AppKit NSStatusItem + 테두리 없는 패널 안의 SwiftUI 상세 뷰·설정·기록 창**, 최소 **macOS 14** (Observation, UserNotifications). Swift Charts는 쓰지 않는다(§8.6).
- 구조: Swift Package 모노레포
  - `TokenGlanceCore` (UI 무관: Provider, Parser, Aggregator, 모델) - 유닛 테스트 대상
  - `TokenGlanceApp` (SwiftUI 메뉴바 앱)
  - `token-glance-hook` (Foundation 기반 Swift CLI)
- 번들: `scripts/bundle-app.sh` → `dist/TokenGlance.app`(ad-hoc 서명, LSUIElement), 번들 ID `io.github.yim0327.token-glance`, 훅 바이너리는 `Contents/Resources`에 포함하고 설치 시 `~/Library/Application Support/TokenGlance/bin/`에 복사. 진단용 `--print-state` 플래그 제공.
- 빌드: SwiftPM 우선 + `.app` 번들링 스크립트(또는 XcodeGen). Claude Code가 `swift build`/`swift test`로 자동 검증하기 쉽게 구성.
- 테스트: Swift Testing / XCTest, 실제 구조 기반 합성/익명 fixture로 검증. 실제 로그 파일 복사 금지
- CI: GitHub Actions (macOS runner에서 build + test)
- 배포: GitHub Releases(.zip, `ditto`로 생성 + SHA-256). 공증은 Apple Developer 계정(연 $99) 필요. **결정: 계정 없음 → 소스 빌드 + ad-hoc 서명 미공증 릴리스로 시작.** 첫 실행은 시스템 설정 › 개인정보 보호 및 보안의 "그래도 열기"로 안내하고, `xattr -cr` 같은 광범위한 해제는 권하지 않는다. 릴리스 zip은 arm64 전용이며 universal/Intel 지원으로 소개하지 않는다. Homebrew cask는 이번 범위에서 제외(미공증 앱 정책 확인 후 별도 결정).
- 라이선스: **MIT (확정)**

## 11. 아키텍처

```
~/.claude/settings.json ─(statusLine)→ token-glance-hook ─→ ~/Library/Application Support/TokenGlance/claude-rate-limits.json ─┐
~/.claude/projects/**/*.jsonl ─────────────────────────────────────────────────────────┤
~/.codex/sessions/**/*.jsonl ──────────────────────────────────────────────────────────┤
                                                                                        v
                                   [FileWatcher (FSEvents + Codex stat polling)] → [Provider: Claude | Codex]
                                                                       v
                                                    [Aggregator + Cache(offset, 일별 집계)]
                                                                       v
                                                      [UsageStore (@Observable)]
                                                                       v
                                      NSStatusItem label + details panel (SwiftUI)
```

- `UsageProvider` 프로토콜: `limits() -> [LimitWindow]`, `tokens(for: Range) -> TokenUsage`
- `LimitWindow`: kind, usedPercent, resetsAt, observedAt. 초기화 후 다음 resetsAt을 모르면 nil로 두고 새 관측을 기다린다. 시간 경과만으로 실제 한도 복구가 확인된 것으로 보지 않는다.

## 12. 마일스톤 (Claude Code 단계별 작업 단위)

| 단계 | 내용 | 완료 기준 |
|---|---|---|
| M0 | 환경 세팅(Xcode/CLT 복구), 레포 생성, `CLAUDE.md`, 실제 로그/훅 샘플 수집·익명화 | `swift build` 성공, fixture 확보, `[확인 필요]` 항목 검증 완료 |
| M1 | (선행: Codex 세션 1회 실행 후 로그 재검증) `TokenGlanceCore`: Claude 토큰 파서(전역 dedupe, 키별 최대 output), Codex 파서(한도+delta 토큰), 테스트 | 테스트 통과, 수동 검증값과 일치 |
| M2 | Claude 훅 스크립트 + 캐시 리더 + 설치/제거 로직 | 실제 Claude Code 세션에서 `rate_limits` 캐시 기록 확인 |
| M3 | 메뉴바 라벨 + 팝오버 (세션/주간 게이지, 카운트다운) | 두 도구 동시 표시 MVP |
| M4 (구현 완료) | 증분 갱신, 설정, 훅 UI, 로그인 등록/해제, CI 및 Codex 보완(PR #3) | 테스트 139개/22개 스위트, PR #3 체크 통과. 재로그인 확인·릴리스는 별도 |
| M5 (구현 완료, PR #4) | 알림, 한국어/영어, 14일 차트, 성능 수정(패널, 도형 차트, 공유 포매터). 비공식 API/로고 제외 | 테스트 176개/31개 스위트, 언어·차트·테스트 배너는 사용자 확인. 실제 임계값 통과 알림은 테스트로만 검증. §7.4·§7.5 온라인 조회는 별도 PR(#6, #7) |
| M6 (진행 중) | README 스크린샷, 반복 사용 안정성 측정, 릴리스 자동화(`package-release.sh`, `v*` 태그 → draft Release)·로컬 설치 검증. Homebrew·공증 제외 | 로컬: zip·체크섬·서명·리소스·실행·임시 프로필 훅 검증 완료. 남은 것: 승인 후 태그·워크플로 실행·draft 게시, 다운로드 후 Gatekeeper 흐름 확인 |

## 13. 오픈소스 요구사항

- README: 문제 정의, 스크린샷/GIF, 설치법, **데이터 소스와 프라이버시 설명**, 한계(비공식 API, % 단위), 아키텍처 다이어그램
- `docs/`: PRD, 설계 결정 기록(ADR), 로그 스키마 노트
- 커밋/PR 단위를 마일스톤에 맞춰 정리, CI 배지, 테스트 커버리지 언급
- 이슈 템플릿, CONTRIBUTING, LICENSE
- 외부 프로젝트 링크·비교를 새로 추가하지 않는다. 공식 데이터 소스 우선, 최소 권한, 로컬 처리, 두 도구 동시 표시라는 실제 특성을 설명한다.

## 14. 리스크 / 오픈 이슈

| 리스크 | 대응 |
|---|---|
| Claude 한도는 statusline 훅 의존: Claude Code가 실행되어야 값 갱신 | 신선도 표시. 선택 옵션으로 Claude Code `get_usage` 위임 조회(§7.5) |
| Claude 온라인 조회 경로가 실험적·무문서 (변경·중단, 약관 해석) | 기본 OFF, 동의 문구에 명시, 실패 시 훅 캐시 폴백, 미지원 상태 표시 |
| 기존 statusline 사용자 충돌 | 체이닝 + 백업/복원 + 동의 절차 |
| 훅이 SIGKILL을 받으면 이어서 실행 중인 명령(OMC HUD)이 끝까지 실행됨 (가로채지 못함). Claude Code가 실제로 쓰는 취소 시그널은 미확인 | 실사용 중 고아 프로세스 관찰, 문서화 |
| OMC 업데이트/재설치가 statusLine을 덮어쓸 수 있음 | `status()`로 감지, 앱 UI 경고 + `repair` |
| 비공식 API/로그 포맷 변경 | 방어적 파서, fixture 테스트, 버전 기록 |
| Codex 누적 토큰 이중 집계 | 세션별 delta + 테스트 |
| `rate_limits` 필드는 Pro/Max에서만, 첫 응답 후에만 존재 | 값 없을 때 안내 UI |
| 공증 비용 | 미서명 릴리스 + 소스 빌드 안내로 시작 |
| 개발 환경: Xcode CLT 경로 깨짐 | M0에서 `xcode-select --install` 또는 Xcode 설치 |
| MenuBarExtra 두 줄 표현 부적합(M3 검증) | NSStatusItem + 직접 그린 NSImage로 구현 완료 |
| 24시간 넘게 쉬었던 Codex 세션 재개 지연 | 5분 폴백·수동 새로고침, 한계 표시 |
| 알림 중복·초기화 오판정 | 윈도우별 테스트, 재시작 중복 억제, 새 관측 기반 판정 |
| Claude/OpenAI 마크 사용에 따른 상표 이슈 | 메뉴바 서비스 식별 용도로만 사용, 공식 파일 원형 유지, 비제휴·비보증 고지와 MIT 비적용 명시. Anthropic 사전 승인·단색 변환은 미해결로 기록(`docs/trademarks.md`), 승인 전제로 표현하지 않음. 문제가 되면 중립 C/X 배지로 되돌릴 수 있음(폴백 코드 유지) |
| 이름 `Token Glance` 중복 가능성 | 정확히 같은 이름은 검색에서 못 찾았으나, 출시 전 GitHub/Homebrew 재확인 |

### 네이밍 보완 체크리스트 (Token Glance)

- [x] 레포 description: "Claude Code & Codex usage limits at a glance, in your macOS menu bar"
- [x] GitHub topics: `claude-code`, `codex`, `token-usage`, `menubar`, `macos`, `swift`
- [x] README 최상단에 두 줄 메뉴바 스크린샷. README는 한국어(위)·영어(아래) 섹션과 최상단 언어 링크로 구성하고, 섹션마다 해당 언어의 상세 패널·기록 창 스크린샷만 넣는다(M6, 다크 모드·온라인 조회 ON 상태임을 캡션에 명시)
- [ ] 아이콘: 게이지/눈 모티프 + 중립 색상
- [x] README에 "Not affiliated with Anthropic or OpenAI" 고지
- [ ] 이름 중복 확인 (GitHub, Homebrew, 검색)

## 15. 결정 사항

| 항목 | 결정 |
|---|---|
| 앱 이름 | Token Glance (레포 `token-glance`) |
| Apple Developer 계정 | 없음 → 미서명 릴리스 + 소스 빌드로 시작 |
| 라이선스 | MIT |
| 기존 statusline | oh-my-claudecode HUD (`node .../hud/omc-hud.mjs`) 확인됨 → 체이닝 P0 |
| 최소 macOS | 14+ |
| 스택 | AppKit NSStatusItem + SwiftUI, Foundation 훅 |
| M5 범위 | 알림, 한국어/영어, 14일 차트. 비공식 API와 공식 로고 교체 제외 |
| 상세 UI | `NSPopover` 대신 블러 배경 패널(화살표 없음) |
| 차트 | Swift Charts 대신 SwiftUI 기본 도형 |
| 첫 릴리스 | v0.1.0, Apple Silicon(arm64) 전용, ad-hoc 서명·미공증, GitHub Release는 draft로 생성 후 승인 시 게시 |
