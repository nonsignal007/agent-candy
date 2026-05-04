# Claude Candy

Claude Code의 5시간 윈도우 시작 시각을 자동으로 앞당기고, 사용 흐름을 기록한 뒤, 다음날 윈도우 시작 시각을 다시 계산하는 macOS LaunchAgent 기반 자동화입니다.

핵심 목표:

1. 점심 시간을 5시간 윈도우 안에 포함시켜 토큰 낭비를 줄입니다.
2. 오후 고사용 시간대에 새 윈도우가 시작되도록 자동 조정합니다.

## Terminology

문서 안에서 쓰는 내부 용어를 먼저 정리합니다.

- `candy`
  Claude CLI를 한 번 호출해서 새 5시간 윈도우를 시작시키는 트리거입니다.
- `pre-warm`
  출근 전에 미리 `candy`를 실행해서 첫 윈도우 종료 시각을 원하는 위치로 당기는 동작입니다.
- `progress`
  한 윈도우 안에서 1h, 2h, 3h, 4h 지점 누적 사용률입니다.
- `final snapshot`
  한 윈도우가 끝나기 직전의 최종 사용률입니다.
- `optimizer`
  전날 사용 데이터를 읽고 다음 candy 시각을 다시 계산하는 스크립트/LaunchAgent입니다.

## Overview

평일 기준으로 4개 LaunchAgent가 동작합니다.

- `com.claude.candy`
  `claude -p`를 호출해 새 5시간 윈도우를 시작하고 `resetsAt`을 기록합니다.
  문서에서는 편의상 이 윈도우 시작 트리거를 `candy`라고 부릅니다.
- `com.claude.candy.progress`
  각 윈도우의 1h, 2h, 3h, 4h 지점 누적 사용률을 기록합니다.
- `com.claude.candy.snapshot`
  각 윈도우 리셋 2분 전 최종 사용률을 기록합니다.
- `com.claude.candy.optimizer`
  전날 final snapshot과 progress 흐름을 보고 다음 candy 시각을 다시 계산합니다.

## Operator Mental Model

이 저장소는 “정적 소스”와 “런타임에 계속 바뀌는 상태”가 함께 있습니다.

- 정적 소스:
  `bin/`, `tests/`, 기본 `LaunchAgents/*.plist`, `config/lunch_schedule.conf`
- 런타임 상태:
  `logs/*`, `config/.optimizer_phase`, `backups/`, 그리고 optimizer가 다시 써 넣는 `LaunchAgents/*.plist`

중요:

- `LaunchAgents/*.plist`는 설치용 예시 파일이면서 동시에 optimizer가 실제로 다시 쓰는 운영 상태입니다.
- 따라서 repo 안 plist가 “항상 처음 체크인된 기본값”이라고 가정하면 안 됩니다.
- `logs/*`와 `.optimizer_phase`도 논리적으로는 generated state입니다. 현재 repo snapshot에 파일이 이미 보이더라도, 그건 과거 실행에서 남은 retained state일 수 있습니다.

## Runtime Flow

```text
window-start trigger (candy) -> 새 5시간 윈도우 시작 + resetsAt 기록
progress                     -> 윈도우 1h / 2h / 3h / 4h 누적 사용률 기록
final snapshot               -> 윈도우 리셋 2분 전 최종 사용률 기록
optimizer 23:00              -> 전날 데이터 분석 -> 다음 candy/progress/snapshot plist 재생성
```

예시:

```text
08:01  candy
09:00  progress (1h)
10:00  progress (2h)
11:00  progress (3h)
12:00  progress (4h)
12:58  final snapshot
```

## Why This Exists

Claude Code의 5시간 윈도우는 한 번 시작되면 고정됩니다.

```text
09:00 사용 시작 -> 09:00~14:00 윈도우 고정
14:00 이후에야 다음 윈도우 시작 가능
```

점심시간이 윈도우 안에 포함되면 실제 작업 시간당 토큰 밀도가 올라갑니다.

```text
사전 윈도우 시작(pre-warm) 없음
09:00-14:00  첫 윈도우
14:00-19:00  둘째 윈도우

사전 윈도우 시작(pre-warm) 있음
08:01-13:00  점심 포함
13:01-18:00  오후 시작과 함께 새 윈도우
```

## Schedule Rules

Claude의 5시간 윈도우는 **분 단위로 정확하게** 리셋됩니다.

```text
08:23 실행 -> resetsAt 13:23
07:45 실행 -> resetsAt 12:45
```

따라서 분 단위 정밀도가 의미를 갖습니다. candy는 다음 두 메커니즘으로 동작합니다.

### 1. 1분 폴러 (poller)

`com.claude.candy.plist`는 `StartInterval=60`으로 설정되어 매 1분마다 `refresh_claude.sh`를 호출합니다. 스크립트는 즉시 gate check를 수행해 실행 시각이 아니면 silent exit합니다.

### 2. 두 개의 상태 파일이 dispatch를 결정

| 파일 | 기록 주체 | 의미 |
| --- | --- | --- |
| `config/.candy_morning_ts` | optimizer (23:00) | 다음 아침 pre-warm 시각 (epoch). 이 시각 전엔 절대 실행 안 함 |
| `config/.candy_next_ts` | candy (성공 후) | 직전 candy의 `resets_at`. 이 시각 이후에 다음 candy 실행 |

### 3. 체인 흐름

```text
[23:00] optimizer  → .candy_morning_ts = 내일 07:23 epoch 기록 (분 단위)
[07:23] poller     → gate 통과, candy 실행 → resets_at = 12:23
                     .candy_morning_ts 삭제, .candy_next_ts = 12:23 기록
                     snapshot.plist = 12:20, progress.plist = 08:22/09:22/10:22/11:22 동적 갱신
[12:23] poller     → gate 통과 (next_ts), candy 실행 → resets_at = 17:23
                     .candy_next_ts = 17:23, snapshot/progress plist 재갱신
... (체인 반복) ...
[23:00] optimizer  → 다음 아침 시각으로 morning_ts overwrite
```

핵심: 첫 아침 시각만 정확히 세팅되면 그 뒤는 `resets_at` 체인으로 자동 전파됩니다.

- candy: 1분 폴러 + state 파일이 결정 (HH:MM 분 단위 정확)
- progress: candy 시점 기준 `+59/+119/+179/+239`분 (매 candy 실행 시 동적 갱신)
- final snapshot: `resets_at - 3분` (매 candy 실행 시 동적 갱신)

## Data Model

사용률 로그는 `logs/usage_snapshots.csv`에 저장됩니다.

### CSV Columns

| Field | Meaning |
| --- | --- |
| `timestamp` | Unix timestamp |
| `datetime` | Local time `YYYY-MM-DD HH:MM:SS` |
| `dow` | Python weekday (`0=Mon`) |
| `hour` | Local hour |
| `type` | `candy`, `progress`, `snapshot` |
| `sample_slot` | `1h`, `2h`, `3h`, `4h`, `final`, or empty |
| `5h_used_pct` | 현재 저장된 유효 5시간 사용률 |
| `5h_resets_at` | 윈도우 리셋 시각 |
| `7d_used_pct` | 7일 누적 사용률 |
| `raw_5h_used_pct` | 원본 rate-limit 파일에서 읽은 5시간 사용률 |
| `effective_5h_used_pct` | carry-forward 반영 후 사용률 |
| `minutes_to_reset` | 현재 시점에서 리셋까지 남은 분 |
| `window_elapsed_min` | 현재 윈도우에서 지난 분 |
| `progress_source` | `raw` 또는 `limit_carry` |
| `limit_hit_at` | rate limit 감지 시각 |

### Interpretation

- `progress`
  한 윈도우 안에서 누적 사용률이 얼마나 빨리 올라가는지 보여줍니다.
- `snapshot`
  그 윈도우가 끝날 때 실제로 얼마나 찼는지 보여줍니다.
- `candy`
  새 윈도우가 언제 시작됐는지 추적합니다.

예시:

```text
윈도우 08:01-13:00: 최종 99%
흐름: 1h=20%, 2h=44%, 3h=78%, 4h=95%, final=99%
```

의미:

- 최종 99%: 해당 윈도우는 거의 다 소진됨
- 4h 시점 95%: 일찍 포화되는 패턴이 있음

## Limit Carry-Forward

윈도우 중간에 rate limit이 걸리면, 남은 progress와 final snapshot은 `100%`로 저장됩니다.

예시:

```text
12:17 limit
13:00 progress -> 100%
13:58 final snapshot -> 100%
```

이때 CSV에는:

- `effective_5h_used_pct=100`
- `progress_source=limit_carry`
- `limit_hit_at=<timestamp>`

가 같이 기록됩니다.

## Optimizer Behavior

optimizer는 평일 23:00에 실행됩니다. 이전과 달리 **단 하나의 시각(다음 아침 pre-warm `HH:MM`)만 분 단위로 최적화**합니다. 이후 윈도우는 `resets_at` 체인으로 자동 결정됩니다.

- 월요일: 직전 금요일 데이터 사용
- 화요일-금요일: 어제 데이터 사용
- 금요일: 다음 주 월요일 아침 시각을 계산
- 토요일-일요일: 즉시 종료

안전장치:

- final `snapshot`이 최소 3개 미만이면 변경 안 함 (`MIN_SNAPSHOTS`)
- 시간 변경폭은 최대 120분(분 단위) (`MAX_SHIFT_MIN`)
- Claude 응답 파싱 실패 시 morning_ts 변경 없음

출력:

- optimizer는 plist를 직접 수정하지 않습니다. **`.candy_morning_ts`에 다음 아침 epoch만 기록**합니다.
- snapshot/progress plist는 candy 실행 시 동적으로 재생성됩니다.

### Lunch Rotation and Friday Branch

점심 시간대는 [lunch_schedule.conf](/Users/sms0731/jobs/config/lunch_schedule.conf:1) 에서 관리합니다.

```bash
CYCLE_ANCHOR="2026-04-13"
CYCLE_PATTERN="12:30-13:30,12:00-13:00,13:00-14:00"
```

- `CYCLE_ANCHOR`가 속한 주를 기준 주로 봅니다.
- `CYCLE_PATTERN`은 주 단위로 순환하는 점심 시간대 목록입니다.

금요일 optimizer는 평일과 다르게 동작합니다.

- 월-목: 이번 주 점심 기준으로 어제 데이터를 해석
- 금요일: 다음 주 월요일부터 적용될 점심 시간을 기준으로 스케줄 계산
- 금요일에는 같은 패턴이 적용됐던 3주 전 주간 히스토리도 같이 프롬프트에 넣어 다음 주 pre-warm 시각을 더 안정적으로 정합니다.

### Optimizer Phase State

`config/.optimizer_phase`는 optimizer의 안정화 단계를 저장하는 런타임 상태 파일입니다.

- `phase=1`
  비교적 자주 조정하는 단계
- `phase=2`
  작은 변경이 일정 기간 이어진 뒤의 안정화 단계

보통 사용자가 직접 수정하는 운영 설정이 아니라, optimizer가 내부적으로 관리하는 상태로 보는 편이 맞습니다.

## Path Model

기본 운영 경로는 `~/jobs`입니다.

하지만 스크립트는 프로젝트 산출물 경로를 env로 분리할 수 있습니다.

### Path-related Environment Variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `JOBS_ROOT` | `$HOME/jobs` | 프로젝트 루트 경로 |
| `PLIST_SYS_DIR` | `$HOME/Library/LaunchAgents` | 실제 bootstrap 대상 LaunchAgent 디렉터리 |
| `TOOLS_BIN_DIR` | empty | fake `launchctl`/`osascript`/`claude`를 PATH 앞에 주입할 때 사용 |
| `SNAPSHOT_CSV` | `$JOBS_ROOT/logs/usage_snapshots.csv` | CSV 경로 override |

의도:

- `HOME`은 Claude CLI 로그인 상태를 유지하는 데 씁니다.
- `JOBS_ROOT`는 logs, config, LaunchAgents, backups 같은 프로젝트 산출물만 분리하는 데 씁니다.

즉, 테스트에서는 `HOME`을 그대로 두고 `JOBS_ROOT=/tmp/.../jobs`만 바꾸면 실제 로그인 상태를 유지한 채 격리 실행이 가능합니다.

## Repository Layout

```text
jobs/
├── bin/
│   ├── refresh_claude.sh
│   ├── usage_progress.sh
│   ├── usage_snapshot.sh
│   ├── schedule_optimizer.sh
│   └── lib/
│       ├── candy_time.py
│       ├── candy_time.sh
│       └── usage_csv.py
├── LaunchAgents/
│   ├── com.claude.candy.plist
│   ├── com.claude.candy.progress.plist
│   ├── com.claude.candy.snapshot.plist
│   └── com.claude.candy.optimizer.plist
├── config/
│   ├── lunch_schedule.conf
│   └── .optimizer_phase
├── logs/
│   ├── refresh.log
│   ├── schedule_changes.log
│   ├── usage_snapshots.csv
│   ├── refresh.pid
│   └── .limit_until
├── backups/
├── tests/
│   ├── virtual_time_test.sh
│   └── live_claude_optimizer_smoke.sh
└── README.md
```

### Committed vs Generated Paths

저장소를 처음 받았을 때 이미 있어야 하는 것:

- `bin/`
- `LaunchAgents/`
- `config/lunch_schedule.conf`
- `tests/`
- `README.md`

논리적으로 generated/runtime state인 것:

- `logs/refresh.log`
- `logs/schedule_changes.log`
- `logs/usage_snapshots.csv`
- `logs/refresh.pid`
- `logs/.limit_until`
- `config/.optimizer_phase`
- `backups/`
- `.candy_cwd/` (candy 실행용 빈 격리 cwd. `claude -p` 가 주변 프로젝트의 `CLAUDE.md` / `.claude/` 설정을 끌어오지 못하도록, `refresh_claude.sh` 가 여기로 `cd` 한 뒤 CLI 를 호출한다.)

주의:

- 현재 repo snapshot에 위 파일 일부가 이미 존재할 수 있습니다.
- 그 경우에도 성격은 “정적 소스”가 아니라 “retained runtime state”로 보는 게 맞습니다.

## Requirements

- macOS
- GUI login session
- `claude` CLI
- `python3`
- `launchctl`
- `plutil`
- `osascript`

빠른 확인:

```bash
claude --version
python3 --version
launchctl help >/dev/null
plutil -help >/dev/null
osascript -e 'return "ok"' >/dev/null
```

실전 preflight:

```bash
claude -p --output-format json 'Respond only ok'
```

이게 성공해야 합니다.

이 프로젝트는 단순히 `claude` 바이너리가 있는 것만으로는 부족합니다.

- `claude -p --output-format json`이 실제로 동작해야 함
- 현재 CLI가 로그인된 상태여야 함
- Claude 사용 이후 `~/.claude/abtop-rate-limits.json`이 생성/갱신되어야 progress/snapshot이 의미 있게 기록됨

## Installation

### 1. Place the repo

기본 경로는 `~/jobs`입니다.

```bash
mkdir -p ~/jobs
# 예시 1: 현재 저장소를 그대로 옮길 수 있으면 이동
# mv /path/to/current/repo ~/jobs

# 예시 2: 내용을 복사
# cp -R /path/to/current/repo/. ~/jobs/
```

이 단계가 끝난 뒤에는 실제 운영 기준 정본 경로가 `~/jobs`라고 생각하면 됩니다.

### 2. Install LaunchAgent symlinks

```bash
mkdir -p ~/Library/LaunchAgents

ln -sfn ~/jobs/LaunchAgents/com.claude.candy.plist \
  ~/Library/LaunchAgents/com.claude.candy.plist
ln -sfn ~/jobs/LaunchAgents/com.claude.candy.progress.plist \
  ~/Library/LaunchAgents/com.claude.candy.progress.plist
ln -sfn ~/jobs/LaunchAgents/com.claude.candy.snapshot.plist \
  ~/Library/LaunchAgents/com.claude.candy.snapshot.plist
ln -sfn ~/jobs/LaunchAgents/com.claude.candy.optimizer.plist \
  ~/Library/LaunchAgents/com.claude.candy.optimizer.plist
```

### 3. Bootstrap

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.claude.candy.plist 2>/dev/null || true
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.claude.candy.progress.plist 2>/dev/null || true
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.claude.candy.snapshot.plist 2>/dev/null || true
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.claude.candy.optimizer.plist 2>/dev/null || true

launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.claude.candy.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.claude.candy.progress.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.claude.candy.snapshot.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.claude.candy.optimizer.plist
```

### 4. Verify

```bash
launchctl print gui/$(id -u)/com.claude.candy
launchctl print gui/$(id -u)/com.claude.candy.progress
launchctl print gui/$(id -u)/com.claude.candy.snapshot
launchctl print gui/$(id -u)/com.claude.candy.optimizer
```

확인 포인트:

- `Could not find service`가 나오지 않을 것
- `event triggers`에 시간이 보일 것
- `program = /bin/sh`
- `exec "${JOBS_ROOT:-$HOME/jobs}/bin/...` 형태 인자가 보일 것

추가로 optimizer LaunchAgent는 launchd stdout/stderr를 `/tmp`에도 남깁니다.

- `/tmp/claude-candy-optimizer.log`
- `/tmp/claude-candy-optimizer-error.log`

## Operations

### Check current chain state

candy는 1분 폴러로 동작하므로 candy.plist의 시간을 확인하는 대신 상태 파일을 봅니다.

```bash
# 다음 candy 시각 (체인)
ts=$(cat ~/jobs/config/.candy_next_ts 2>/dev/null) && python3 -c "import datetime; print('next:', datetime.datetime.fromtimestamp($ts))"

# 다음 아침 pre-warm 시각 (optimizer가 23:00에 갱신)
ts=$(cat ~/jobs/config/.candy_morning_ts 2>/dev/null) && python3 -c "import datetime; print('morning:', datetime.datetime.fromtimestamp($ts))"

# 현재 적용 중인 snapshot/progress 시각
python3 - <<'PY'
import os, plistlib
for name in ['snapshot', 'progress']:
    path = os.path.expanduser(f'~/jobs/LaunchAgents/com.claude.candy.{name}.plist')
    with open(path, 'rb') as f:
        data = plistlib.load(f)
    slots = [(i['Hour'], i['Minute']) for i in data.get('StartCalendarInterval', [])]
    print(f"{name}: {slots}")
PY
```

### Watch logs

```bash
tail -f ~/jobs/logs/refresh.log
tail -30 ~/jobs/logs/schedule_changes.log
tail -30 ~/jobs/logs/usage_snapshots.csv
```

### Manual kickstart

```bash
launchctl kickstart -k gui/$(id -u)/com.claude.candy
launchctl kickstart -k gui/$(id -u)/com.claude.candy.progress
launchctl kickstart -k gui/$(id -u)/com.claude.candy.snapshot
launchctl kickstart -k gui/$(id -u)/com.claude.candy.optimizer
```

## Testing

### Virtual regression

가짜 시간과 fake command를 사용하는 회귀 테스트입니다.

```bash
bash tests/virtual_time_test.sh
```

검증 내용:

- progress/final sample 시각
- stale skip
- weekend skip
- limit carry-forward
- optimizer skip/update 경로

전제:

- 네트워크 불필요
- 실제 Claude 로그인 불필요
- 실제 LaunchAgent 미변경

이 테스트는 temp `HOME`, fake `launchctl`/`osascript`/`claude`, `FAKE_NOW_TS`를 사용합니다.

### Live end-to-end smoke

실제 Claude API를 사용하되, 프로젝트 산출물은 temp `JOBS_ROOT`로 분리하는 테스트입니다.

```bash
bash tests/live_claude_optimizer_smoke.sh
```

검증 내용:

- 실제 Claude가 `times + reason` JSON을 반환하는지
- optimizer가 그 응답을 파싱하는지
- candy/progress/snapshot plist가 기대대로 생성되는지

중요:

- 이 테스트는 실제 Claude 로그인 상태와 네트워크에 의존합니다.
- 현재 셸에서 `claude -p`가 정상 동작해야 합니다.
- 실제 `launchctl` 대신 fake `launchctl`을 사용하므로, 설치된 사용자 LaunchAgent는 건드리지 않습니다.
- 실패 시 raw Claude 응답을 `logs/claude_raw/`에 남깁니다.

## First-Day Behavior

새 PC에서는 첫날부터 모든 기능이 풍부하게 동작하지 않을 수 있습니다.

- `~/.claude/abtop-rate-limits.json`이 아직 없을 수 있음
- progress/snapshot이 조용히 skip될 수 있음
- optimizer는 final snapshot 4개가 쌓이기 전까지 skip됨
- 주말이라면 candy/progress/snapshot/optimizer 모두 조기 종료됨

정상적인 초기 흐름:

1. 저장소를 `~/jobs`에 둠
2. LaunchAgent 등록
3. candy 실행
4. rate-limit 파일이 생김
5. progress/snapshot 누적
6. final snapshot 4개 이상 누적 후 optimizer 동작

## Troubleshooting

### candy가 안 도는 경우

1. `launchctl print gui/$(id -u)/com.claude.candy`
2. `~/jobs/LaunchAgents/com.claude.candy.plist`가 비어 있지 않은지 확인
3. `~/jobs/logs/refresh.log`
4. `~/jobs/logs/.limit_until` 존재 여부 확인

### progress나 snapshot이 안 찍히는 경우

가능한 원인:

- `~/.claude/abtop-rate-limits.json`이 아직 없음
- 현재 시각 기준 `resets_at < now`라 stale skip
- 주말
- agent가 unload됨

확인:

```bash
launchctl print gui/$(id -u)/com.claude.candy.progress
launchctl print gui/$(id -u)/com.claude.candy.snapshot
tail -30 ~/jobs/logs/usage_snapshots.csv
```

### optimizer가 스케줄을 안 바꾸는 경우

대개 정상입니다.

- final snapshot 4개 미만
- 주말
- Claude 응답 파싱 실패
- 계산 결과가 현재 스케줄과 동일
- 구조 검증 실패

먼저 확인할 로그:

```bash
tail -30 ~/jobs/logs/schedule_changes.log
tail -30 /tmp/claude-candy-optimizer.log
tail -30 /tmp/claude-candy-optimizer-error.log
```

### live smoke가 실패하는 경우

먼저 이것부터 확인:

```bash
claude --version
bash tests/live_claude_optimizer_smoke.sh
```

흔한 원인:

- Claude CLI 로그인 만료
- 네트워크 문제
- temp `JOBS_ROOT`는 분리됐지만 `HOME` 로그인 상태가 깨진 커스텀 환경

## Operational Notes

- `logs/refresh.log`는 최근 100줄만 유지
- `logs/usage_snapshots.csv`는 최근 500행만 유지
- final snapshot gate는 기본 4개
- 최대 시간 이동폭은 기본 2시간
- `backups/`는 필요할 때만 생성

## Current Defaults

| Setting | Default |
| --- | --- |
| `MIN_SNAPSHOTS` | `3` |
| `MAX_SHIFT_MIN` | `120` (분) |
| `MAX_CSV_LINES` | `500` |
| candy LaunchAgent | `StartInterval=60s` (1분 폴러) |
| snapshot slots | 1 (resets_at - 3min, 동적 갱신) |
| progress slots | 4 (candy + 1h/2h/3h/4h, 동적 갱신) |
| optimizer slots | 1 (평일 23:00) |
