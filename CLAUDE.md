# CLAUDE.md - Token Glance

macOS 메뉴바 앱. Claude Code와 Codex CLI의 5시간 세션 / 주간 한도 잔여 %와 초기화 시각을 두 줄로 보여준다.
오픈소스(MIT) + 포트폴리오 프로젝트. 상세 요구사항은 `docs/PRD.md`를 항상 먼저 참고한다.

## 핵심 원칙

1. **읽기 전용, 프라이버시 우선**: 프롬프트/응답 내용은 읽더라도 저장·로그·전송하지 않는다. 수치 메타데이터만 사용한다.
2. **기본 네트워크 호출 0**: 비공식 API(Claude OAuth usage, Codex wham/usage)는 사용자가 설정에서 켠 경우에만 호출한다. Keychain/토큰은 그 옵션에서만 접근하고 로그·캐시에 절대 저장하지 않는다.
3. **방어적 파싱**: 로그/훅 스키마는 비공식이고 바뀔 수 있다. 알 수 없는 필드는 무시, 파싱 실패 라인은 skip, 앱은 죽지 않는다. 값이 없으면 `--`로 표시한다.
4. **추측 금지**: 로그 필드/경로는 `[확인 필요]`가 붙은 항목을 실제 샘플로 검증한 뒤 구현한다. 검증 결과는 `docs/log-schemas.md`에 기록한다.
5. **사용자 설정 보호**: `~/.claude/settings.json` 수정은 사용자 동의 후 백업을 남기고만 한다. 기존 statusLine(oh-my-claudecode 등)은 반드시 체이닝한다.

## 구조

```
Package.swift
Sources/
  TokenGlanceCore/   # UI 무관 로직: Provider, Parser, Aggregator, 모델 (테스트 대상)
  TokenGlanceApp/    # AppKit/SwiftUI 메뉴바 앱 (NSStatusItem 두 줄 라벨 + 팝오버)
  token-glance-hook/ # Claude statusline 훅 (stdin -> 캐시 기록 -> 기존 statusline 체이닝)
Tests/
  TokenGlanceCoreTests/
  Fixtures/          # 익명화된 실제 로그 샘플 (내용/경로/이메일 제거)
docs/                # PRD.md, log-schemas.md, ADR
scripts/             # .app 번들링, 릴리스
```

## 빌드 / 테스트 명령

```
swift build
swift test                # Xcode 환경 / CI
./scripts/test.sh         # Command Line Tools만 있는 환경 (swift test는 테스트 0개로 거짓 통과함)
./scripts/bundle-app.sh   # .app 생성 (M3 이후)
```

변경 후에는 항상 `swift build && ./scripts/test.sh`를 실행해 테스트가 실제로 실행·통과했는지(테스트 개수 포함) 확인한 뒤 완료를 보고한다.

## 코드 규칙

- Swift 5.10+, macOS 14+. 외부 의존성은 최소화(가능하면 0). 추가 시 이유를 ADR에 기록.
- Core에는 UI 코드(AppKit/SwiftUI)를 넣지 않는다. 파일 I/O는 프로토콜로 추상화해 테스트에서 fixture를 주입한다.
- 시간은 `Date` 주입으로 테스트 가능하게 한다 (카운트다운, resets_at 만료 처리).
- Codex 토큰은 세션 누적값이므로 delta로 집계한다 (이중 집계 금지). Claude는 `message.id`+`requestId`로 dedupe.
- 훅(`token-glance-hook`)은 stdin을 읽자마자 캐시에 **원자적으로(임시파일 -> rename)** 쓰고, 그 다음에 기존 statusline을 실행한다. Claude Code는 실행 중 스크립트를 취소할 수 있으므로 순서를 바꾸지 않는다. 훅 자체 실행 시간은 20ms 이하를 목표로 한다.
- 주석/문서는 한국어 또는 영어 모두 가능하나 README와 코드 식별자는 영어.

## 작업 방식

- 한 번에 한 마일스톤(M0~M6)만 진행한다. 시작 전에 계획을 짧게 제시하고, 끝나면 완료 기준 충족 여부를 보고한다.
- 테스트 먼저(또는 함께). 파서 버그를 고칠 때는 재현 fixture/테스트를 먼저 추가한다.
- 커밋은 작은 단위로, 메시지는 `feat:`, `fix:`, `test:`, `docs:`, `chore:` 접두사를 사용한다.
- 실제 `~/.claude`, `~/.codex` 파일을 커밋하지 않는다. fixture는 반드시 익명화한다.
- 모르는 것은 추측하지 말고 질문하거나 `docs/log-schemas.md`에 "미확인"으로 기록한다.

## 상표/고지

- Claude, OpenAI 로고를 번들에 포함하지 않는다. 중립 심볼(C/X 글리프 또는 단색 아이콘)을 사용한다.
- README에 "Not affiliated with Anthropic or OpenAI"를 명시한다.
