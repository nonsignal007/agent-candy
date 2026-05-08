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

다음 11단계를 순서대로 실행한다.

1. JOBS_ROOT 경로 결정 (사용자 확인)
2. 요구 사항 검증 (`claude`, `python3`, `launchctl`, `plutil`, `osascript`)
3. Claude CLI preflight (`claude -p --output-format json`)
4. 플러그인 번들을 JOBS_ROOT로 복사 배포
5. **점심 시간 설정 (`config/lunch_schedule.conf` — 사용자 확인 포인트)**
6. `~/Library/LaunchAgents` symlink 생성
7. Bootout → Bootstrap
8. **스크립트 편집기 1회 실행 + 알림 권한 설정 + 가상 알림 검증 (사용자 확인 포인트)**
9. `launchctl print`로 4개 agent 검증
10. 가상 회귀 테스트 (`tests/virtual_time_test.sh`) 실행
11. Live smoke 실행 여부 사용자에게 확인 (옵션)

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

### 5. 점심 시간 설정 — 사용자 확인 포인트

Candy 의 핵심 목적은 **점심시간을 5시간 윈도우 안에 포함시키는 것**이다. optimizer 는 `$JOBS_ROOT/config/lunch_schedule.conf` 의 점심 시간대를 보고 다음 아침 pre-warm 시각을 계산한다. 이 값이 사용자의 실제 점심 시간과 다르면 자동화의 의미가 사라지므로, setup 시점에 반드시 확인을 받는다.

```
CYCLE_ANCHOR="YYYY-MM-DD"          # 패턴 첫 항목이 적용되는 기준 주의 임의 날짜
CYCLE_PATTERN="HH:MM-HH:MM,..."    # 쉼표 구분, 1~N개 시간대. N주 단위 순환
```

#### 5a. 기존 설정 확인

`$JOBS_ROOT/config/lunch_schedule.conf` 가 이미 있고 1단계에서 "그대로 둠" 을 선택했다면, 현재 값을 사용자에게 보여준다:

```bash
grep -E '^(CYCLE_ANCHOR|CYCLE_PATTERN)=' "$JOBS_ROOT/config/lunch_schedule.conf"
```

> "현재 점심 설정은 다음과 같습니다.
>
> - ANCHOR: `2026-04-13`
> - PATTERN: `12:30-13:30, 12:00-13:00, 13:00-14:00`
>
> 이대로 둘까요? 변경할까요?"

"그대로" 를 선택하면 이 단계 종료. "변경" 이면 5b 진행.

신규 설치 / 덮어쓰기 인 경우는 항상 5b 부터 진행한다 (번들 기본값을 덮어쓰는 흐름).

#### 5b. 점심 패턴 결정

사용자에게 다음 세 가지 옵션을 제시한다:

> "점심 시간을 알려주세요. Candy 는 이 시간대를 5시간 윈도우 안에 포함시키도록 pre-warm 시각을 계산합니다.
>
> 1. **매일 같은 시간** (예: `12:00-13:00`) — 가장 일반적
> 2. **주별로 순환** (예: 1주차 `12:30-13:30`, 2주차 `12:00-13:00`, 3주차 `13:00-14:00`) — 점심 시간이 주별로 바뀌는 회사
> 3. **직접 입력** — `HH:MM-HH:MM` 형식, 쉼표로 여러 개
>
> 어떻게 하시겠어요?"

옵션별 후속 질문:

- **옵션 1**: "점심 시간을 알려주세요 (`HH:MM-HH:MM`)." → 한 항목짜리 PATTERN 으로 사용
- **옵션 2**: "1주차부터 순서대로 점심 시간을 알려주세요. 보통 2~4개입니다." → 모두 받아 쉼표로 결합
- **옵션 3**: 자유 입력을 그대로 받음

검증:

```python
import re
ITEM_RE = re.compile(r'^([01]?\d|2[0-3]):[0-5]\d-([01]?\d|2[0-3]):[0-5]\d$')
for item in pattern.split(','):
    item = item.strip()
    assert ITEM_RE.match(item), f"형식 오류: {item}"
    s, e = item.split('-')
    assert s < e, f"시작이 종료보다 늦거나 같음: {item}"
```

검증 실패 시 사용자에게 어느 항목이 왜 잘못됐는지 보여주고 다시 입력받는다.

#### 5c. ANCHOR 결정

- **옵션 1 (단일 시간)**: ANCHOR 는 의미가 없으므로 오늘 날짜로 둔다.
- **옵션 2/3 (다항목)**: 1주차 패턴이 적용될 주를 정해야 한다.

> "방금 입력하신 패턴의 **첫 번째 시간 (`<첫 항목>`)** 이 적용되는 주는 언제인가요? 그 주에 속한 임의 날짜를 `YYYY-MM-DD` 로 알려주세요. 기본값은 오늘 날짜 (`<오늘>`) 입니다."

검증: `datetime.date.fromisoformat()` 로 파싱 가능해야 한다.

#### 5d. 출근 시간 결정 — pre-warm hard constraint

candy 의 pre-warm 은 **반드시 출근 시간 이전** 에 실행되어야 candy 가 만든 윈도우가 사용자의 첫 활동을 흡수한다 (출근 시각 이후에 pre-warm 이 잡히면 사용자의 자연 윈도우가 이미 시작된 상태라 candy query 가 새 윈도우를 만들지 못하고 토큰만 낭비한다).

따라서 pre-warm 유효 범위 = `(WORK_START - 5h, WORK_START]` 가 되도록 출근 시각을 받아 `WORK_START_HOUR/WORK_START_MIN` 으로 저장한다.

> "Claude Code 를 처음 켜는 시각, 즉 **출근(or 작업 시작) 시각** 을 알려주세요.
> 이 시각을 기준으로 candy 가 그 이전 시간대에서 pre-warm 시각을 결정합니다.
>
> 형식: `HH:MM` (24시간). 기본값: `09:00`."

검증:

```python
import re
M = re.match(r'^([01]?\d|2[0-3]):([0-5]\d)$', work_start_input.strip())
assert M, "형식 오류 — HH:MM 으로 입력해주세요"
WORK_START_HOUR = int(M.group(1))
WORK_START_MIN  = int(M.group(2))
```

기존 conf 가 있고 1단계에서 "그대로 둠" 을 선택했고 `WORK_START_HOUR` 키가 이미 있다면 5d 도 스킵 가능. 키가 없으면 (구버전 conf) 반드시 묻는다.

#### 5e. conf 파일 작성

확정된 lunch + work_start 값으로 conf 파일을 작성한다 (기존 파일 덮어쓰기):

```bash
cat > "$JOBS_ROOT/config/lunch_schedule.conf" <<EOF
# Claude Candy 사용자 스케줄 설정
# candy-setup 시 사용자 입력으로 채워진다.
# sync 시에도 보존된다 (사용자 파일이 있으면 번들이 덮어쓰지 않음).

# ─── 점심 시간 (5h 윈도우 안으로 흡수) ───
# CYCLE_ANCHOR: 이 날짜가 속한 주의 점심 = CYCLE_PATTERN 첫 번째 값
# CYCLE_PATTERN: 쉼표 구분, 1~N 항목, N주 단위 순환 (HH:MM-HH:MM)
CYCLE_ANCHOR="$ANCHOR"
CYCLE_PATTERN="$PATTERN"

# ─── 출근 시간 (pre-warm hard constraint) ───
# pre-warm 유효 범위: (WORK_START - 5h, WORK_START]
WORK_START_HOUR=$WORK_START_HOUR
WORK_START_MIN=$WORK_START_MIN
EOF
```

작성 후 사용자에게 최종 결과를 다시 보여주고 한 번 더 확인한다:

> "다음 내용으로 `$JOBS_ROOT/config/lunch_schedule.conf` 를 작성했습니다.
>
> - 점심 ANCHOR: `<ANCHOR>` (이 주에 첫 번째 패턴 적용)
> - 점심 PATTERN: `<PATTERN>`
> - 출근 시각: `<WORK_START_HOUR>:<WORK_START_MIN>` (pre-warm 은 이 시각 이전으로만 잡힘)
>
> 이대로 진행할까요?"

"틀렸다" 고 하면 어느 항목인지 물어 5b (점심) 또는 5d (출근) 부터 다시 받는다.

### 6. LaunchAgent symlinks 생성

```bash
mkdir -p ~/Library/LaunchAgents

for name in com.claude.candy com.claude.candy.progress com.claude.candy.snapshot com.claude.candy.optimizer; do
  ln -sfn "$JOBS_ROOT/LaunchAgents/${name}.plist" \
    "$HOME/Library/LaunchAgents/${name}.plist"
done
```

`ln -sfn` 이므로 기존 symlink가 있어도 안전하게 덮어쓴다.

### 7. Bootout → Bootstrap

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

### 8. 스크립트 편집기 1회 실행 + 알림 권한 설정 + 가상 알림 검증 — 사용자 확인 포인트

**이 스킬의 가장 중요한 사용자 확인 포인트.** 자동화할 수 없는 부분이 있다.

Candy의 `refresh_claude.sh` / `schedule_optimizer.sh` 는 결과를 `osascript -e 'display notification ...'` 로 macOS 알림에 띄운다. macOS는 osascript 알림을 **스크립트 편집기(Script Editor)** 앱 명의로 게시하므로, 두 가지가 모두 충족되어야 실제로 알림이 보인다:

1. 스크립트 편집기가 최소 한 번은 실행되어 시스템 알림 목록에 등록될 것
2. 그 항목의 "알림 허용" 이 켜져 있을 것

이 단계는 그래서 4개 하위 단계로 나뉜다.

#### 8a. 스크립트 편집기 1회 실행

Claude 가 직접 띄울 수 있다:

```bash
open -a "Script Editor"
```

사용자에게:

> "응용프로그램 > 스크립트 편집기를 한 번 띄웠습니다. 빈 새 스크립트 창이 떠야 합니다. 창이 떴는지 확인해주세요. (스크립트 편집기에서 무엇을 할 필요는 없습니다 — 단지 macOS 가 이 앱을 알림 대상으로 등록하려면 1번 실행된 적이 있어야 합니다.)"

사용자가 "떴어요" / "확인" 등으로 긍정 응답할 때까지 기다린다. 안 뜬다고 하면 응용프로그램 폴더에서 직접 실행하도록 안내한다.

#### 8b. 알림 권한 설정 안내

알림 패널을 직접 열어준다:

```bash
open "x-apple.systempreferences:com.apple.preference.notifications"
```

사용자에게:

> "시스템 설정의 알림 패널을 열었습니다.
>
> 1. 앱 목록에서 **스크립트 편집기(Script Editor)** 항목을 찾으세요. (방금 8a 에서 실행했으므로 목록에 있어야 합니다. 없다면 8a 로 돌아가 다시 실행하세요.)
> 2. 그 항목을 클릭하고 **알림 허용** 을 켭니다.
> 3. 알림 스타일은 **배너** 또는 **알림 센터** 중 원하는 대로 선택합니다.
>
> 설정이 끝났으면 '완료' 라고 알려주세요."

#### 8c. 가상 알림 실행

알림 권한이 실제로 작동하는지는 종료 코드로 확인할 수 없다 — macOS 는 권한이 없을 때도 osascript 에 0 을 반환한다. 그래서 setup 도중에 진짜 알림을 한 번 띄워서 사용자 눈으로 확인해야 한다.

```bash
osascript -e 'display notification "Candy 알림 테스트입니다" with title "Claude Candy" subtitle "설치 검증"'
```

이 명령은 즉시 알림 센터에 띄워야 한다.

#### 8d. 알림 표시 확인 — 사용자 확인 포인트

사용자에게 명확하게 묻는다:

> "방금 화면 우측 상단에 다음 알림이 떴습니까?
>
> > Claude Candy
> > 설치 검증
> > Candy 알림 테스트입니다
>
> - 떴어요 → 알림 설정 OK, 다음 단계로 진행
> - 안 떴어요 → 8a/8b 로 돌아가서 스크립트 편집기 실행 + 권한 허용 재확인"

사용자가 "안 떴다" 고 답하면 8a/8b 부터 다시 안내한다. 1회 재시도까지 기다리고, 그래도 안 뜨면:

- 진행은 하되, "Candy 자체 동작은 정상이지만 알림은 뜨지 않을 수 있다" 고 명시한다.
- README 의 Troubleshooting / 알림 섹션을 가리킨다.
- 흔한 원인: 집중 모드(Do Not Disturb) 활성화, 화면 잠금 중에는 잠금 해제 후 알림 센터에 누적, 스크립트 편집기 항목 자체가 패널에 안 보이는 경우 (이때는 다시 8a 강제 실행).

사용자가 "건너뛰겠다" 고 하면 진행하되, 알림이 안 뜬다는 점을 한 번 더 명시적으로 알린다.

### 9. `launchctl print` 로 검증

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

### 10. 가상 회귀 테스트

실제 시간/실제 Claude 호출 없이 격리된 환경에서 전체 로직을 검증한다:

```bash
cd "$JOBS_ROOT"
bash tests/virtual_time_test.sh
```

이 테스트는 fake `launchctl`/`osascript`/`claude`, `FAKE_NOW_TS`, temp `HOME` 을 써서 로컬 환경을 건드리지 않는다. progress 샘플 시각, stale skip, weekend skip, limit carry-forward, optimizer skip/update 경로를 검증한다.

실패 시 마지막 수십 줄을 사용자에게 보여주고, README의 Troubleshooting 섹션을 같이 제시한다.

### 11. Live smoke — 사용자 선택

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
