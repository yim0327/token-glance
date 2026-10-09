# PRD: Token Glance - Claude Code / Codex 한도 잔여량 메뉴바 앱

> 상태: Draft v0.4 (배포/라이선스/statusline 결정 반영, 앱 이름 확정: Token Glance, 레포명 `token-glance`)
> 한 줄 설명: Claude Code & Codex usage limits at a glance, in your macOS menu bar.
> 오픈소스 공개 + 포트폴리오 목적. 개발은 Claude Code로 진행.
> `[확인 필요]`는 구현 전에 실제 로컬 데이터로 검증할 가정이다.

## 1. 배경 / 문제

- Claude Code(Pro/Max)와 Codex CLI(ChatGPT 플랜)는 **구독 플랜 기준 한도(5시간 세션 / 주간)** 로 사용량이 제한된다.
- 지금은 한도 확인을 위해 터미널에서 `/usage`, `/status`를 치거나 도구별로 따로 확인해야 한다.
- 두 도구의 "얼마나 남았고, 언제 초기화되는지"를 나란히 보여주는 상시 노출 UI가 필요하다.

## 2. 목표 (Goals)

1. 메뉴바에서 Claude Code와 Codex의 **세션(5시간) / 주간 한도 잔여량과 초기화 시각**을 한눈에 본다.
2. 별도 로그인/API 키 입력 없이 동작한다 (zero-config, 가능한 한 공식 경로 우선).
3. 가볍다 (idle CPU ~0%, 메모리 50MB 이하).
4. 오픈소스 품질: 테스트, CI, README, 데모 GIF, 릴리스 자동화. (면접관이 볼 수 있는 레포)

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

- Claude Code와 Codex CLI를 구독 플랜으로 함께 쓰는 개발자 (1차: 본인 dogfooding)
- macOS 14+ (Apple Silicon 우선)

## 6. 핵심 시나리오

1. 작업 중 메뉴바만 보고 `Claude 세션 62% 남음 / Codex 세션 80% 남음`을 확인한다.
2. 클릭하면 팝오버에서 세션/주간 잔여 게이지, 초기화까지 남은 시간(카운트다운), 오늘 사용 토큰을 본다.
3. 잔여량이 임계값(예: 20%, 5%) 이하로 내려가면 알림을 받는다. (v1.1)
4. 로그인 시 자동 실행되어 신경 쓰지 않아도 갱신된다.

## 7. 데이터 소스 전략 (핵심)

### 7.1 Claude Code - 한도 잔여량

로컬 로그(JSONL)에는 한도 정보가 없다. 대신 아래 경로를 쓴다.

| 우선순위 | 방법 | 설명 | 비고 |
|---|---|---|---|
| **1 (기본)** | **Statusline 훅** | Claude Code는 statusline 스크립트에 stdin JSON으로 `rate_limits.five_hour / seven_day` 의 `used_percentage`, `resets_at`(Unix epoch)을 전달한다. 앱이 제공하는 작은 스크립트를 `statusLine`으로 등록하면, 스크립트가 해당 JSON을 앱의 캐시 파일에 기록하고 앱은 이를 감시(FSEvents)한다. | 공식 문서화된 기능. 네트워크/토큰 접근 불필요. Pro/Max 구독자 + 첫 API 응답 이후에만 값 존재. v2.1.80+ `[확인 필요]` |
| 2 (옵션) | 비공식 OAuth Usage API | `GET api.anthropic.com/api/oauth/usage` (Keychain의 Claude Code 자격증명 사용). 응답에 `five_hour`, `seven_day`, 모델별 주간 한도 포함. | **비공식·무문서**, 429가 잦음, 자격증명 접근 필요. 기본 OFF, 사용자가 명시적으로 켤 때만 (v1.1+) |

- **훅 구현 규칙 (성능/정확도)**: Claude Code는 statusline 업데이트를 300ms 디바운스하고, 스크립트가 실행 중일 때 새 업데이트가 오면 진행 중인 스크립트를 **취소**한다. 따라서 (1) stdin을 먼저 읽어 **캐시 파일에 원자적으로(임시파일 → rename) 기록한 뒤**, (2) 그 다음에 기존 statusline(OMC 등)에 동일 stdin을 그대로 넘기고 출력을 전달한다. (3) 훅은 jq 의존 없이 최소 작업만 하고 네트워크 호출은 하지 않는다. 채널 실행 시간을 측정해 예산(예: 훅 자체 < 20ms)을 테스트한다.
- **오너 환경**: oh-my-claudecode(OMC) 설치 중. **확인됨**: `~/.claude/settings.json`의 statusLine은 `{"type":"command","command":"node ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hud/omc-hud.mjs"}` (OMC HUD). command는 쉘 변수 확장(`${...:-...}`)을 포함하므로, 체이닝 시 원본 command **문자열을 그대로 저장해 쉘에서 실행**한다(경로를 직접 해석하지 말 것). 원본은 백업 파일에 보관하고 제거 시 복원한다. OMC HUD는 node 프로세스라 시작 비용이 있으므로(수십 ms) 훅은 반드시 그보다 앞에서 저장을 끝낸다. 따라서 **체이닝은 P0**로 격상한다. OMC가 업데이트/재설치로 statusLine을 덮어쓸 수 있으므로 훅 상태 점검(설치됨/덮어씁움)과 재설치 버튼도 제공한다.
- 기존 statusline이 이미 설정된 사용자를 위해 **체이닝** 지원: 앱 스크립트가 stdin을 캐시에 저장한 뒤 기존 스크립트로 그대로 전달한다.
- 설정 변경(`~/.claude/settings.json`)은 **사용자 동의 후**에만, 백업을 남기고 수행한다. 앱 내 "설치/제거" 버튼 제공.
- 제약: Claude Code 세션이 한 번도 실행되지 않았거나 오래 비활성이면 값이 오래될 수 있다 → 마지막 갱신 시각 표시, `resets_at`이 지났으면 "초기화됨(0%)"로 처리.

### 7.2 Claude Code - 토큰 사용량 (보조)

- `~/.claude/projects/**/*.jsonl` (`CLAUDE_CONFIG_DIR` 존중) `[확인 필요]`
- `type == "assistant"` 의 `message.usage`: `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`
- 중복 제거: `message.id` + `requestId`
- 집계: 오늘 / 주간(주간 윈도우 시작 = 주간 `resets_at` - 7d) / 모델별

### 7.3 Codex - 한도 잔여량 + 토큰

- 경로: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` (`CODEX_HOME` 존중) `[확인 필요]`
- `event_msg` 중 `payload.type == "token_count"`:
  - `info.total_token_usage` (세션 누적), `info.last_token_usage` (직전 턴)
  - `rate_limits.primary` (5시간), `rate_limits.secondary` (주간): `used_percent`, `window_minutes`, `resets_at`
- 즉 Codex는 **로컬 로그만으로** 한도 잔여량과 초기화 시각을 얻을 수 있다. 가장 최신 이벤트의 `rate_limits`를 사용.
- 토큰 집계는 누적값이므로 세션별 delta로 계산 (이중 집계 방지).
- 대안(옵션, v1.1+): `~/.codex/auth.json` 토큰으로 `chatgpt.com/backend-api/wham/usage` 조회. 비공식이므로 기본 OFF.

## 8. 기능 요구사항

### 8.1 메뉴바 라벨 (P0)

- **두 줄 레이아웃**: 윗줄 Claude 아이콘 + 잔여 %, 아랫줄 Codex 아이콘 + 잔여 %. 클릭 없이 바로 확인.
  ```
  [Claude아이콘] 62%
  [Codex아이콘]  80%
  ```
- 기본 값은 세션(5h) 잔여 %. 표시 모드: 세션 잔여 % / 주간 잔여 % / 초기화까지 남은 시간 / 사용 토큰 수
- 도구별 on/off (하나만 켜면 한 줄 레이아웃으로 전환)
- 임계값 색상 (잔여 30% 이하 주황, 10% 이하 빨강)
- 데이터가 없거나 오래된 경우 `--` 표시 및 툴팁에 사유 표시
- 구현 주의: 메뉴바 높이(약 22pt)에 두 줄을 넣으려면 작은 폰트(약 9~10pt, 모노스페이스 숫자)가 필요하고, `MenuBarExtra` 라벨이 멀티라인을 지원하지 않으면 `NSImage`/`ImageRenderer`로 직접 그려 `NSStatusItem`에 넣는다. M3 초기에 프로토타입으로 검증한다. 아이콘은 템플릿 이미지(다크/라이트 자동 대응) 우선.

### 8.2 팝오버 (P0)

- Claude Code / Codex 두 섹션
- 각 섹션: 세션(5h) 게이지 + 잔여 % + 초기화 시각(절대시각 + 카운트다운), 주간(7d) 게이지 + 잔여 % + 초기화 시각
- 사용 토큰: 오늘 / 이번 주간 윈도우, 분류(input/output/cache), 모델별
- 데이터 신선도: "마지막 갱신 3분 전"
- 새로고침, 설정, 종료

### 8.3 갱신 (P0)

- FSEvents로 JSONL 및 Claude 캐시 파일 변경 감지, 파일별 byte offset 기반 증분 파싱
- 카운트다운은 1초 타이머 (UI만, 파싱 아님). 폴백 폴링 60초.

### 8.4 설정 (P1)

- 로그인 시 자동 실행 (`SMAppService`)
- Claude statusline 훅 설치/제거 (백업/복원)
- 표시 모드, 임계값, 로그 경로 오버라이드, 비공식 API 사용 여부(기본 OFF)

### 8.5 알림 (P1)

- 세션/주간 잔여가 임계값 이하일 때, 초기화 직전/직후 알림 (`UserNotifications`)

### 8.6 차트 / 비용 추정 (P2)

- 일별 토큰 막대 차트(Swift Charts), 사용 페이스 대비 잔여 가이드
- 비용 추정은 구독에서 의미가 약하므로 후순위

## 9. 비기능 요구사항

| 항목 | 요구 |
|---|---|
| 성능 | idle CPU < 1%, 메모리 < 50MB, 증분 갱신 < 200ms |
| 프라이버시 | 프롬프트/응답 내용은 저장·전송하지 않음. 수치 메타데이터만 사용. 기본 설정에서 외부 네트워크 호출 0 |
| 보안 | OAuth 토큰/Keychain은 옵션 기능에서만 접근, 로그·캐시에 토큰 저장 금지 |
| 안정성 | 파싱 실패 라인 skip, 스키마 변경에 방어적, 값 누락 시 graceful degrade |
| 권한 | dot-folder 읽기 필요 → App Sandbox OFF, 직접 배포 |
| UI | 다크/라이트, Dock 아이콘 없음(`LSUIElement`), 한국어/영어 |

## 10. 기술 스택

- **Swift 5.10+ / SwiftUI `MenuBarExtra`**, 최소 **macOS 14** (Observation 프레임워크, MenuBarExtra, Swift Charts 사용)
- 구조: Swift Package 모노레포
  - `TokenGlanceCore` (UI 무관: Provider, Parser, Aggregator, 모델) - 유닛 테스트 대상
  - `TokenGlanceApp` (SwiftUI 메뉴바 앱)
  - `token-glance-hook` (statusline 스크립트, 순수 shell 또는 작은 Swift CLI)
- 빌드: SwiftPM 우선 + `.app` 번들링 스크립트(또는 XcodeGen). Claude Code가 `swift build`/`swift test`로 자동 검증하기 쉽게 구성.
- 테스트: Swift Testing / XCTest, **실제 로그를 익명화한 fixture**로 파서 검증
- CI: GitHub Actions (macOS runner에서 build + test)
- 배포: GitHub Releases(.dmg/.zip) + Homebrew cask 탭. 공증은 Apple Developer 계정(연 $99) 필요. **결정: 계정 없음 → 소스 빌드 + 미서명 릴리스(ad-hoc 서명, 우클릭 열기/`xattr -cr` 안내)로 시작.** Homebrew cask는 미공증 앱 정책 확인 후 결정(불가 시 `brew install --build-from-source` 또는 자체 탭).
- 라이선스: **MIT (확정)**

## 11. 아키텍처

```
~/.claude/settings.json ─(statusLine)→ tokenbar-hook ─→ cache/claude-rate-limits.json ─┐
~/.claude/projects/**/*.jsonl ─────────────────────────────────────────────────────────┤
~/.codex/sessions/**/*.jsonl ──────────────────────────────────────────────────────────┤
                                                                                        v
                                   [FileWatcher (FSEvents)] → [Provider: Claude | Codex]
                                                                       v
                                                    [Aggregator + Cache(offset, 일별 집계)]
                                                                       v
                                                      [UsageStore (@Observable)]
                                                                       v
                                                 MenuBarExtra label + Popover
```

- `UsageProvider` 프로토콜: `limits() -> [LimitWindow]`, `tokens(for: Range) -> TokenUsage`
- `LimitWindow { kind: session|weekly, usedPercent, resetsAt, observedAt }`

## 12. 마일스톤 (Claude Code 단계별 작업 단위)

| 단계 | 내용 | 완료 기준 |
|---|---|---|
| M0 | 환경 세팅(Xcode/CLT 복구), 레포 생성, `CLAUDE.md`, 실제 로그/훅 샘플 수집·익명화 | `swift build` 성공, fixture 확보, `[확인 필요]` 항목 검증 완료 |
| M1 | `TokenBarCore`: Codex 파서(한도+토큰), Claude 토큰 파서, dedupe, 테스트 | 테스트 통과, 수동 검증값과 일치 |
| M2 | Claude 훅 스크립트 + 캐시 리더 + 설치/제거 로직 | 실제 Claude Code 세션에서 `rate_limits` 캐시 기록 확인 |
| M3 | 메뉴바 라벨 + 팝오버 (세션/주간 게이지, 카운트다운) | 두 도구 동시 표시 MVP |
| M4 | FSEvents 증분 갱신, 설정, 로그인 시 실행 | v0.1 릴리스 |
| M5 | 알림, 차트, 선택적 비공식 API, 로컬라이즈 | v0.2 |
| M6 | CI, README(GIF/스크린샷), 릴리스 자동화, Homebrew | v1.0 공개 |

## 13. 오픈소스 / 포트폴리오 요구사항

- README: 문제 정의, 스크린샷/GIF, 설치법, **데이터 소스와 프라이버시 설명**, 한계(비공식 API, % 단위), 아키텍처 다이어그램
- `docs/`: PRD, 설계 결정 기록(ADR), 로그 스키마 노트
- 커밋/PR 단위를 마일스톤에 맞춰 정리, CI 배지, 테스트 커버리지 언급
- 이슈 템플릿, CONTRIBUTING, LICENSE
- 선행 사례 `steipete/CodexBar`가 존재한다 → README에 비교 섹션 포함하고, 차별점은 **zero-config 공식 경로 우선(statusline 훅), 최소 권한/네트워크 0 기본값, 작고 읽기 쉬운 코드베이스, Claude+Codex 두 도구에 집중**으로 둔다.

## 14. 리스크 / 오픈 이슈

| 리스크 | 대응 |
|---|---|
| Claude 한도는 statusline 훅 의존: Claude Code가 실행되어야 값 갱신 | 신선도 표시, 비공식 API는 옵트인 폴백 |
| 기존 statusline 사용자 충돌 | 체이닝 + 백업/복원 + 동의 절차 |
| 비공식 API/로그 포맷 변경 | 방어적 파서, fixture 테스트, 버전 기록 |
| Codex 누적 토큰 이중 집계 | 세션별 delta + 테스트 |
| `rate_limits` 필드는 Pro/Max에서만, 첫 응답 후에만 존재 | 값 없을 때 안내 UI |
| 공증 비용 | 미서명 릴리스 + 소스 빌드 안내로 시작 |
| 개발 환경: Xcode CLT 경로 깨짐 | M0에서 `xcode-select --install` 또는 Xcode 설치 |
| 메뉴바 두 줄 렌더링이 `MenuBarExtra`로 불가할 수 있음 | `NSStatusItem` + 커스텀 뷰/이미지로 대체 (M3 초기 프로토타입). 팝오버도 필요 시 `NSPanel`/`NSPopover` 사용 |
| Claude/OpenAI 로고 사용에 따른 상표 이슈 | 중립적 심볼(C/X 글리프 또는 단색 아이콘) 사용, README에 비제휴(non-affiliated) 고지 |
| 이름 `Token Glance` 중복 가능성 | 정확히 같은 이름은 검색에서 못 찾았으나, 출시 전 GitHub/Homebrew 재확인 |
| 유사 앱이 이미 다수 존재 (CodexBar, ai-token-monitor, token-usage 등) | README 비교 섹션, 차별점(두 줄 %, 공식 경로 우선, 기본 네트워크 0, 작은 코드베이스) 강조 |

### 네이밍 보완 체크리스트 (Token Glance)

- [ ] 레포 description: "Claude Code & Codex usage limits at a glance, in your macOS menu bar"
- [ ] GitHub topics: `claude-code`, `codex`, `token-usage`, `menubar`, `macos`, `swift`
- [ ] README 최상단에 두 줄 메뉴바 스크린샷/GIF
- [ ] 아이콘: 게이지/눈 모티프 + 중립 색상
- [ ] README에 "Not affiliated with Anthropic or OpenAI" 고지
- [ ] 이름 중복 확인 (GitHub, Homebrew, 검색)

## 15. 결정 사항

| 항목 | 결정 |
|---|---|
| 앱 이름 | Token Glance (레포 `token-glance`) |
| Apple Developer 계정 | 없음 → 미서명 릴리스 + 소스 빌드로 시작 |
| 라이선스 | MIT |
| 기존 statusline | oh-my-claudecode HUD (`node .../hud/omc-hud.mjs`) 확인됨 → 체이닝 P0 |
| 최소 macOS | 14+ |
| 스택 | Swift/SwiftUI + 필요 시 AppKit(NSStatusItem) |
