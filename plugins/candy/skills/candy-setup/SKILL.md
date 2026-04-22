---
name: candy-setup
description: Claude Candy (점심시간 포함 5시간 윈도우 자동화) 를 macOS LaunchAgent로 설치·부트스트랩하고 가상 회귀 테스트까지 돌려 정상 동작을 검증한다. 이 플러그인(candy) 에 포함된 Candy 소스(bin/, LaunchAgents/, config/, tests/) 를 사용자가 선택한 JOBS_ROOT(기본 ~/jobs)로 배포하고 LaunchAgent를 등록한다. 사용자가 "claude candy 설치", "candy 스케줄러 설정", "claude 5시간 윈도우 자동화 설치", "LaunchAgent candy 등록", "candy-setup", "점심시간 pre-warm 설정" 같은 요청을 하거나 `com.claude.candy.*` 관련 plist/agent 설치를 부탁할 때 반드시 이 스킬을 사용한다. 배포 경로를 사용자에게 확인받고, 요구 사항을 검증하며, 알림 권한처럼 사용자가 직접 해야 하는 수동 단계에서 확인을 받고, 마지막에 가상 테스트로 설치 결과를 검증하는 완전한 end-to-end 설치 플로우이다.
---

# Claude Candy Setup

이 스킬은 `candy` 플러그인에 번들된 Candy 소스를 사용자의 JOBS_ROOT로 배포하고, macOS LaunchAgent 4개를 등록하여 Claude Code의 5시간 윈도우 자동화를 시작한다.

## 배경: 소스 위치와 JOBS_ROOT

이 플러그인이 설치되면 Claude Code 런타임은 다음 경로를 제공한다:

- `${CLAUDE_PLUGIN_ROOT}` — 이 플러그인(`candy`) 의 루트. 그 안에 `bin/`, `LaunchAgents/`, `config/`, `tests/`, `README.md` 가 들어 있다.

Candy의 LaunchAgent plist는 런타임에 `${JOBS_ROOT:-$HOME/jobs}` 를 읽어 거기서 `bin/refresh_claude.sh` 등을 실행한다. `launchd` 는 셸 환경 변수를 상속하지 않으므로, **plist가 참조하는 경로에 실제로 소스가 존재해야 한다**. 따라서 플러그인 번들을 그대로 쓰는 것이 아니라, 사용자가 선택한 JOBS_ROOT로 **복사 배포**한 뒤 거기서 부트스트랩한다.

## 왜 이 스킬이 필요한가

Candy 설치는 symlink 걸기만으로 끝나지 않는다:

- 소스를 JOBS_ROOT로 배포해야 한다 (plist가 참조하는 경로)
- 기존 등록을 `bootout` 으로 먼저 해제해야 재등록이 깨끗하다
- macOS 알림 권한은 스크립트가 대신 할 수 없고 사용자 손이 필요하다
- 검증 없이 설치만 하면 "등록은 됐지만 실제로는 안 도는" 상태가 숨는다

이 스킬은 **순서 보장 + 사용자 확인 포인트 + 최종 검증** 세 가지를 중심에 둔다.

## 전체 흐름

다음 10단계를 순서대로 실행한다.

1. JOBS_ROOT 경로 결정 (사용자 확인)
2. 요구 사항 검증 (`claude`, `python3`, `launchctl`, `plutil`, `osascript`)
3. Claude CLI preflight (`claude -p --output-format json`)
4. 플러그인 번들을 JOBS_ROOT로 복사 배포
5. `~/Library/LaunchAgents` symlink 생성
6. Bootout → Bootstrap
7. **알림 권한 확인 (사용자 확인 포인트)**
8. `launchctl print`로 4개 agent 검증
9. 가상 회귀 테스트 (`tests/virtual_time_test.sh`) 실행
10. Live smoke 실행 여부 사용자에게 확인 (옵션)

각 단계에서 실패하면 멈추고, 원인과 다음 행동을 사용자에게 알린다.

## 단계별 실행

### 1. JOBS_ROOT 경로 결정

사용자가 경로를 명시적으로 말하지 않았다면 항상 먼저 물어본다:

> "Candy 소스를 어느 폴더에 배포할까요? (기본값: `~/jobs`. LaunchAgent plist가 `${JOBS_ROOT:-$HOME/jobs}` 를 참조하므로, 이 경로에 소스가 복사됩니다.)"

사용자가 "기본", "`~/jobs`" 로 답하면 `$HOME/jobs` 를 쓴다. 다른 경로를 지정하면 그것을 JOBS_ROOT로 사용한다.

**중요한 분기**: 그 경로에 이미 기존 Candy 설치가 있을 수 있다.

```bash
test -d "$JOBS_ROOT" && ls "$JOBS_ROOT/LaunchAgents"/com.claude.candy*.plist 2>/dev/null
```

존재하면 사용자에게 다시 확인한다:

> "`$JOBS_ROOT` 에 이미 Candy 소스가 있습니다. 어떻게 할까요?
>
> 1. 그대로 둠 (재부트스트랩만 — 기존 소스/로그 유지) ← 추천
> 2. 플러그인 번들로 덮어쓰기 (기존 `bin/`, `LaunchAgents/`, `config/lunch_schedule.conf`, `tests/`, `README.md` 교체. `logs/`, `config/.optimizer_phase`, `backups/` 같은 런타임 상태는 보존)"

사용자 선택을 받아 진행한다. 선택 1이면 4단계(복사)를 건너뛴다.

### 2. 요구 사항 검증

다음 명령들을 병렬로 실행해 하나라도 실패하면 멈춘다:

```bash
claude --version
python3 --version
launchctl help >/dev/null
plutil -help >/dev/null
osascript -e 'return "ok"' >/dev/null
```

실패 시 어떤 의존성이 빠졌는지 사용자에게 알린다.

### 3. Claude CLI Preflight

`claude` 바이너리가 있어도 로그인 상태가 아니면 Candy의 핵심 기능이 동작하지 않는다:

```bash
claude -p --output-format json 'Respond only ok'
```

실패하면 "Claude CLI 로그인이 필요합니다. 터미널에서 `claude` 를 실행해 로그인한 뒤 다시 시도해주세요." 라고 알리고 멈춘다.

### 4. 플러그인 번들을 JOBS_ROOT로 복사

1단계에서 "덮어쓰기" 또는 "신규 설치" 로 결정된 경우에만 실행한다.

```bash
mkdir -p "$JOBS_ROOT"

# 소스 복사 (런타임 상태는 건드리지 않음)
cp -R "${CLAUDE_PLUGIN_ROOT}/bin"           "$JOBS_ROOT/"
cp -R "${CLAUDE_PLUGIN_ROOT}/LaunchAgents"  "$JOBS_ROOT/"
cp -R "${CLAUDE_PLUGIN_ROOT}/tests"         "$JOBS_ROOT/"
mkdir -p "$JOBS_ROOT/config"
cp "${CLAUDE_PLUGIN_ROOT}/config/lunch_schedule.conf" "$JOBS_ROOT/config/"
cp "${CLAUDE_PLUGIN_ROOT}/README.md"        "$JOBS_ROOT/"

# 런타임 디렉터리는 있으면 그대로, 없으면 생성
mkdir -p "$JOBS_ROOT/logs" "$JOBS_ROOT/backups"
```

주의: `logs/`, `config/.optimizer_phase`, `backups/` 는 절대 덮어쓰지 않는다. 기존 운영 기록이 날아간다.

### 5. LaunchAgent symlinks 생성

```bash
mkdir -p ~/Library/LaunchAgents

for name in com.claude.candy com.claude.candy.progress com.claude.candy.snapshot com.claude.candy.optimizer; do
  ln -sfn "$JOBS_ROOT/LaunchAgents/${name}.plist" \
    "$HOME/Library/LaunchAgents/${name}.plist"
done
```

`ln -sfn` 이므로 기존 symlink가 있어도 안전하게 덮어쓴다.

### 6. Bootout → Bootstrap

기존 등록을 먼저 해제한다. 등록이 안 돼 있어도 에러를 무시한다:

```bash
for name in com.claude.candy com.claude.candy.progress com.claude.candy.snapshot com.claude.candy.optimizer; do
  launchctl bootout gui/$(id -u) "$HOME/Library/LaunchAgents/${name}.plist" 2>/dev/null || true
done

for name in com.claude.candy com.claude.candy.progress com.claude.candy.snapshot com.claude.candy.optimizer; do
  launchctl bootstrap gui/$(id -u) "$HOME/Library/LaunchAgents/${name}.plist"
done
```

bootstrap 실패 시 멈추고 사용자에게 알린다. 흔한 원인: plist 구문 오류, 다른 세션에 물려 있음, System Integrity Protection 관련 권한.

**JOBS_ROOT 가 기본(`~/jobs`) 이 아닌 경우 주의**: plist는 `${JOBS_ROOT:-$HOME/jobs}` 를 읽지만 launchd 는 셸 env를 상속하지 않는다. 따라서 기본값이 아닌 JOBS_ROOT 를 쓴다면, 사용자에게 "현재 plist는 `$HOME/jobs` 를 기본값으로 사용하므로 JOBS_ROOT가 다른 경우 plist의 `EnvironmentVariables` 를 직접 수정해야 합니다" 라고 알리고 사용자 동의를 받은 뒤에만 plist를 편집한다. 기본 경로(`~/jobs`) 를 쓰면 이 문제는 없다.

### 7. 알림 권한 확인 — 사용자 확인 포인트

**이 스킬의 가장 중요한 사용자 확인 포인트.** 자동화할 수 없다.

Candy의 optimizer 등이 결과를 macOS 알림으로 띄울 수 있고, macOS는 "시스템 설정 > 알림" 에서 앱별로 허용해야 실제로 표시된다.

사용자에게 다음과 같이 안내한다:

> "이제 macOS 시스템 설정에서 알림 권한을 허용해주세요.
>
> 1. **시스템 설정 > 알림** 을 엽니다
> 2. **스크립트 편집기(Script Editor)** 또는 **osascript** 항목의 알림 허용을 켭니다
> 3. 터미널 / Claude Code / iTerm 등 실제로 Candy가 호출되는 앱의 알림도 허용해주세요
>
> 설정이 끝났으면 '완료' 라고 알려주세요. 확인해야 다음 단계(검증 및 테스트)로 진행합니다."

사용자가 "했어요" / "완료" / "OK" 같이 긍정적 응답을 할 때까지 기다린다. "건너뛰겠다" 고 하면 진행하되, 알림이 안 뜰 수 있다는 점을 한 번 더 명시적으로 알린다.

### 8. `launchctl print` 로 검증

```bash
for name in com.claude.candy com.claude.candy.progress com.claude.candy.snapshot com.claude.candy.optimizer; do
  launchctl print "gui/$(id -u)/${name}"
done
```

확인 포인트:

- `Could not find service` 가 출력되지 않아야 함
- `event triggers` 섹션에 시각이 나와야 함
- `program` 이 `/bin/sh` 이거나 실행 가능한 경로

하나라도 안 맞으면 어떤 agent의 어떤 필드가 문제인지 구체적으로 보고한다.

### 9. 가상 회귀 테스트

실제 시간/실제 Claude 호출 없이 격리된 환경에서 전체 로직을 검증한다:

```bash
cd "$JOBS_ROOT"
bash tests/virtual_time_test.sh
```

이 테스트는 fake `launchctl`/`osascript`/`claude`, `FAKE_NOW_TS`, temp `HOME` 을 써서 로컬 환경을 건드리지 않는다. progress 샘플 시각, stale skip, weekend skip, limit carry-forward, optimizer skip/update 경로를 검증한다.

실패 시 마지막 수십 줄을 사용자에게 보여주고, README의 Troubleshooting 섹션을 같이 제시한다.

### 10. Live smoke — 사용자 선택

가상 테스트 통과 뒤 사용자에게 명시적으로 묻는다:

> "가상 테스트는 통과했습니다. 실제 Claude API를 호출해 optimizer end-to-end 까지 확인하는 live smoke 테스트도 돌려볼까요? (네트워크와 Claude 로그인 필요, 토큰 소모)"

동의하면:

```bash
cd "$JOBS_ROOT"
bash tests/live_claude_optimizer_smoke.sh
```

기본값은 건너뛰기다 — 토큰이 든다.

## 최종 보고

모든 단계가 끝나면 사용자에게 다음을 요약한다:

- 사용된 JOBS_ROOT
- 등록된 agent 4개와 각 `event triggers` 시각
- 가상 테스트 결과 (pass/fail)
- Live smoke 결과 (실행한 경우)
- 주요 로그 위치: `$JOBS_ROOT/logs/refresh.log`, `$JOBS_ROOT/logs/usage_snapshots.csv`, `$JOBS_ROOT/logs/schedule_changes.log`, `/tmp/claude-candy-optimizer.log`

## 실패 시 공통 대응

- bootstrap 실패 → `launchctl print-disabled gui/$(id -u)` 로 disable 여부 확인
- `claude -p` 실패 → 브라우저에서 로그인 만료 가능성
- virtual test 실패 → 실패 단계를 그대로 사용자에게 전달, README의 Troubleshooting 섹션을 가리킴
- 알림이 안 뜸 → 시스템 설정 > 알림 권한을 다시 확인하도록 안내

이 스킬은 실패를 감추지 않는다. 잘못된 상태를 "설치 완료" 로 보고하는 것이 제일 나쁘다.
