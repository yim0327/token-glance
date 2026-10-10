# CLAUDE.md - Token Glance

macOS 메뉴바 앱. Claude Code와 Codex CLI의 5시간 세션 / 주간 한도 잔여 %와 초기화 시각을 두 줄로 보여준다.
오픈소스(MIT) + 포트폴리오 프로젝트. 상세 요구사항은 `docs/PRD.md`를 항상 먼저 참고한다.

## 핵심 원칙

1. **읽기 전용, 프라이버시 우선**: 프롬프트/응답 내용은 읽더라도 저장·로그·전송하지 않는다. 수치 메타데이터만 사용한다.
2. **기본 네트워크 호출 0**: 온라인 옵션이 꺼져 있으면 로컬 로그와 Claude 훅 캐시만 사용한다. Codex 온라인 한도 조회를 켜면 설치된 Codex App Server 자식 프로세스가 기존 로그인으로 네트워크 요청을 할 수 있다. 앱과 진단 스크립트는 인증 파일/Keychain을 직접 읽지 않고, 토큰·계정 식별자를 로그·캐시에 저장하지 않는다. Claude 온라인 조회는 별도 범위다.
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
- M5와 분리된 Codex 온라인 한도 조회는 별도 작업이다. 기본 OFF, stdio App Server, 계정 한도 %·초기화 시각만 조회한다. 토큰 상세·모델별 집계는 로컬 로그만 사용하며 서버 사용량을 합산하지 않는다. 여러 `limitId` 버킷을 임의로 합치지 않고 조회 실패 시 사유를 표시하며 로컬 한도로 폴백한다. Aside 사용분의 귀속은 검증 전까지 미확인이다.
- 훅(`token-glance-hook`)은 stdin을 읽자마자 캐시에 **원자적으로(임시파일 -> rename)** 쓰고, 그 다음에 기존 statusline을 실행한다. Claude Code는 실행 중 스크립트를 취소할 수 있으므로 순서를 바꾸지 않는다. 훅 자체 실행 시간은 20ms 이하를 목표로 한다.
- 주석/문서는 한국어 또는 영어 모두 가능하나 코드 식별자는 영어. README는 한국어(위)·영어(아래) 두 섹션을 같은 내용으로 유지하고, 최상단 언어 링크로 이동하게 하며, 각 섹션에는 해당 언어 스크린샷만 넣는다.

## 작업 방식

- 한 번에 한 마일스톤(M0~M6)만 진행한다. 시작 전에 계획을 짧게 제시하고, 끝나면 완료 기준 충족 여부를 보고한다.
- 테스트 먼저(또는 함께). 파서 버그를 고칠 때는 재현 fixture/테스트를 먼저 추가한다.
- 커밋은 작은 단위로, 메시지는 `feat:`, `fix:`, `test:`, `docs:`, `chore:`, `perf:` 접두사를 사용한다.
- 실제 `~/.claude`, `~/.codex` 파일을 커밋하지 않는다. fixture는 반드시 익명화한다.
- 모르는 것은 추측하지 말고 질문하거나 `docs/log-schemas.md`에 "미확인"으로 기록한다.

### 진행 기록 / 세션 정리

- 마일스톤 완료, 테스트 전체 통과, 커밋 직후 등 작업 단위가 끝나면 `docs/PROGRESS.md`에 **완료 항목**과 **다음 할 일**을 기록(갱신)한다.
- 기록 후 사용자에게 "/clear 후 새 세션 시작을 권장합니다"라고 알린다.
- 컨텍스트 압축 전 상태는 PreCompact 훅(`.claude/scripts/backup-state.sh`)이 `docs/PRE_COMPACT_STATE.md`에 자동 저장하고, 압축 후 SessionStart 훅이 다시 읽어 준다.

### Git / PR 규칙

1. 작업마다 `git fetch` 후 **최신 `origin/main`에서 새 브랜치**를 만든다 (`feat/…`, `fix/…`, `docs/…`, `chore/…`).
2. 브랜치에서 작은 단위로 커밋한다. 커밋 전 `./scripts/test.sh`의 **종료 코드**로 통과를 확인한다(파이프로 종료 코드를 가리지 않는다).
3. 커밋 메시지에 `Co-Authored-By` 등 AI 작성 표기를 넣지 않는다. 커밋 이메일은 GitHub noreply 주소를 유지한다.
4. 브랜치를 push하고 `gh pr create --base main`으로 PR을 만든다. **`main`에 직접 push하지 않는다.** "push 해줘"도 작업 브랜치/PR 갱신을 뜻한다.
5. PR 병합은 **사용자 승인 후 squash merge**(`gh pr merge --squash`)로만 한다.
6. force push와 히스토리 재작성은 사용자가 명시적으로 요청한 경우에만 한다.
7. 사용자가 작업 트리에 남겨 둔 미커밋 변경(예: `docs/PRD.md`)은 스테이징하지 않는다.

## 상표/고지

- Claude, OpenAI 로고를 번들에 포함하지 않는다. 중립 심볼(C/X 글리프 또는 단색 아이콘)을 사용한다.
- README에 "Not affiliated with Anthropic or OpenAI"를 명시한다.
