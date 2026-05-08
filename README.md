# agent-candy

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](https://opensource.org/licenses/MIT)
[![Platform: macOS](https://img.shields.io/badge/Platform-macOS-blue.svg)](https://www.apple.com/macos/)
[![Plugin: candy](https://img.shields.io/badge/Plugin-candy-pink.svg)](plugins/candy/README.md)

Claude Code 세션 초기화 시점을 자동으로 재배치해서,
토큰 사용량 피크가 하나의 5시간 윈도우에 몰리지 않게 분산시키는 플러그인.

[왜 필요한가?](#왜-필요한가) • [핵심 아이디어](#candy의-핵심-아이디어) • [빠른 시작](#빠른-시작) • [내부 동작](plugins/candy/README.md) • [개발 워크플로](#개발-워크플로-기여자용)

---

## 빠른 시작

### Step 1: 마켓플레이스 등록

```
/plugin marketplace add nonsignal007/agent-candy
```

### Step 2: 플러그인 설치

```
/plugin install candy@agent-candy
```

### Step 3: 설치 스킬 실행

Claude Code 에 다음처럼 요청:

- "claude candy 설치해줘"
- "candy 스케줄러 설정"
- "candy 최적화 설정"

`candy-setup` 스킬이 자동으로:

1. JOBS_ROOT 확인 (기본 `~/jobs`)
2. 의존성 검증 (`claude`, `python3`, `launchctl`, `plutil`, `osascript`)
3. Claude CLI preflight
4. 번들 배포 + `~/Library/LaunchAgents` symlink
5. LaunchAgent bootstrap
6. macOS 알림 권한 확인 (사용자 수동 단계)
7. `launchctl print` 검증
8. 가상 회귀 테스트
9. (옵션) Live smoke test

를 수행한다.

---

## 자동 업데이트

설치 후에는 별도 관리가 필요 없다. 새 버전이 배포되면:

- SessionStart hook 이 version 을 비교하고
- 필요한 파일만 자동 sync 하며
- LaunchAgent 를 재부트스트랩한다

런타임 상태는 유지된다:

- `logs/`
- optimizer state
- next reset timestamp
- usage snapshots

자동 sync 를 끄고 싶다면:

```bash
touch ~/.candy_no_sync
```

---

## 왜 필요한가?

Claude 는 5시간 단위 세션 제한을 사용한다.

문제는 실제 업무 패턴은 균등하지 않다는 점이다.

대부분의 사용자는 특정 시간대에 집중적으로 작업하고,
그 몇 시간 동안 토큰 사용량이 폭발적으로 증가한다.

예를 들어:

| 시간 | 상태 |
|---|---|
| 09:00 | 출근 + 세션 시작 |
| 09:00~11:00 | 집중 작업 |
| 11:00 | 대부분의 토큰 소진 |
| 11:00~14:00 | 사실상 작업 불가 |
| 14:00 | 세션 초기화 |

문제는:

> 토큰 사용량 피크가 하나의 5시간 윈도우 안에 압축된다는 것.

즉 실제로 가장 중요한 시간대에
세션이 exhausted 상태가 되어버린다.

---

## candy의 핵심 아이디어

candy 는 사용 패턴을 분석해서:

- 토큰 사용량이 폭주하는 시간대를 찾고
- 세션 초기화 시점을 그 피크 한가운데로 이동시킨다

예를 들어 사용자가 매일 09:00~11:00 사이에 토큰을 많이 사용한다면:

| 시간 | 세션 상태 |
|---|---|
| 05:00 | 짧은 pre-warm 세션 소비 |
| 09:00~10:00 | 이전 윈도우 사용 |
| 10:00 | 세션 초기화 |
| 10:00~11:00 | 새로운 윈도우 사용 |

결과적으로:

- 원래 하나의 윈도우에 몰리던 사용량이
- 두 개의 세션 윈도우로 분산된다

즉:

- 09~10시는 이전 윈도우
- 10~11시는 다음 윈도우

를 사용하게 된다.

candy 의 목적은:

> 토큰 폭주 시간을 세션 경계로 분리해서,
> 특정 시간대에 토큰이 한 번에 고갈되는 현상을 줄이는 것.

---

## candy가 하는 일

### 1. 사용량 패턴 분석

`usage_snapshots.csv` 를 기반으로:

- 언제 토큰 사용량이 집중되는지
- 어떤 시간대에 exhaustion 이 발생하는지
- 세션 경계가 비효율적으로 배치되어 있는지

를 추적한다.

### 2. 세션 경계 재배치

candy 는:

- pre-warm 세션을 일부러 미리 소비하거나
- 점심/비활성 시간을 윈도우 안으로 흡수해서

다음 세션 초기화 시점을 이동시킨다.

핵심 목표는:

> "사용량 피크"와 "세션 경계"를 겹치게 만드는 것.

### 3. 자동 최적화

사용자는 시간을 계산할 필요가 없다.

candy 가 자동으로:

- 다음 세션 시작 시점
- pre-warm 타이밍
- optimizer phase
- reset alignment

를 조정한다.

---

## 특징

- 사용량 기반 세션 재배치
- 토큰 피크 분산
- 세션 exhaustion 감소
- 점심/비활성 시간 흡수
- 자동 pre-warm
- LaunchAgent 기반 자동 실행
- SessionStart 자동 sync
- 런타임 상태 보존
- 셀프 진단 (`candy-doctor`)

---


## 구성 요소

| 컴포넌트 | 역할 |
|---|---|
| `candy-setup` | 설치 / 재배포 |
| `candy-doctor` | 헬스체크 / 자동 수정 |
| `sync_jobs.sh` | SessionStart 자동 버전 sync |
| LaunchAgent 4개 | snapshot / progress / optimizer / chain-gate |
| `usage_snapshots.csv` | 사용 패턴 분석 데이터 |

---

## 요구 사항

- macOS (GUI 로그인 세션)
- Claude CLI (로그인된 상태)
- `python3`, `launchctl`, `plutil`, `osascript`

---

## 저장소 구조

```text
agent-candy/
├── .claude-plugin/
│   └── marketplace.json
└── plugins/
    └── candy/
        ├── .claude-plugin/
        │   └── plugin.json
        ├── skills/
        │   ├── candy-setup/
        │   └── candy-doctor/
        ├── hooks/
        │   ├── hooks.json
        │   └── sync_jobs.sh
        ├── bin/
        ├── LaunchAgents/
        ├── config/
        │   └── lunch_schedule.conf
        ├── tests/
        └── README.md
```

---

## 개발 워크플로 (기여자용)

이 저장소를 직접 수정/배포하는 사람이 따라야 할 규칙. Claude Code 세션이 이 저장소에서 작업할 때도 동일하게 적용한다.

### 로컬 환경

- 개발 머신에서는 `~/jobs` 가 `~/agent-candy/plugins/candy` 로 가는 **심링크**로 구성한다 (선택). 그러면 `~/jobs/bin/refresh_claude.sh` 를 직접 수정해도 그 파일은 이 저장소의 같은 파일이다.
- LaunchAgent 4개는 `${JOBS_ROOT:-$HOME/jobs}` 로 이 저장소를 바라본다. 셸 스크립트 변경은 다음 candy 실행 시 즉시 반영된다.

### 🚨 push 전 필수 체크리스트

#### 1. 버전 bump (사용자 자동 동기화의 핵심)

`plugins/candy/{bin,LaunchAgents,tests}/` 또는 `plugins/candy/config/lunch_schedule.conf` 중 하나라도 바뀐 commit 이 `main` 으로 가면 **반드시** 다음 세 군데의 `version` 필드를 같이 올린다:

- `plugins/candy/.claude-plugin/plugin.json` 의 `"version"`
- `.claude-plugin/marketplace.json` 의 `metadata.version`
- `.claude-plugin/marketplace.json` 의 `plugins[0].version`

세 군데가 모두 일치해야 한다.

**왜 필수인가:** `hooks/sync_jobs.sh` 가 SessionStart 마다 `plugin.json` 의 version 과 사용자의 `~/jobs/.candy_version` 을 비교한다. 다르면 자동으로 사용자의 `~/jobs/` 를 새 번들로 동기화하고 LaunchAgent 를 재부트스트랩한다. **version 을 안 올리면 사용자는 옛 코드를 영원히 돌리게 된다.**

**semver 가이드:**

| Bump | 예시 | 기준 |
|------|------|------|
| **patch** | 0.2.0 → 0.2.1 | 버그 픽스, 사용자 동작 무변화 |
| **minor** | 0.2.0 → 0.3.0 | 새 기능, plist 구조 변경, 새 스크립트 추가 |
| **major** | 0.2.0 → 1.0.0 | config 포맷 변경, 런타임 상태 schema 변경 등 backward-incompatible |

다음은 version bump 를 **건너뛰어도 된다**:

- `skills/`, `hooks/` 만 바뀐 경우 (Claude Code 가 cache 에서 직접 실행)
- `.gitignore`, `README.md`, `LICENSE` 만 바뀐 경우

#### 2. 런타임 상태 파일 staging 금지

다음은 candy 가 실행되며 `plugins/candy/` 안에 자동 생성한다. **절대 commit 하지 않는다** (대부분 `.gitignore` 로 막혀 있다):

- `plugins/candy/logs/` (refresh.log, usage_snapshots.csv, schedule_changes.log)
- `plugins/candy/config/.optimizer_phase`, `.candy_next_ts`, `.candy_morning_ts`
- `plugins/candy/.candy_cwd/`, `plugins/candy/backups/`

가장 자주 실수하는 두 파일:

- `plugins/candy/LaunchAgents/com.claude.candy.snapshot.plist`
- `plugins/candy/LaunchAgents/com.claude.candy.progress.plist`

이 두 plist 는 candy 가 매 5시간 윈도우마다 동적으로 덮어쓴다. `git status` 에 항상 dirty 로 나오는데, **commit 하지 말고** `git checkout` 으로 버리거나 stash 한다. 진짜 plist 구조 변경(예: 새 key 추가)일 때만 의도적으로 커밋한다.

#### 3. 회귀 테스트

번들 동작에 영향 가는 변경(`bin/`, `LaunchAgents/`)이면 push 전에 한 번 돌린다:

```bash
bash plugins/candy/tests/virtual_time_test.sh
```

마지막 줄이 `virtual_time_test.sh: ok` 이면 통과.

### Doctor / Setup / Hook 의 역할 분담

| 도구 | 언제 |
|------|------|
| `candy-doctor` | 헬스체크 + 실행 검증. `runtime.version_sync` 체크로 사용자의 `~/jobs/.candy_version` 이 plugin.json 과 다르면 warn |
| `candy-setup` | 첫 설치 / 강제 재배포 용. 자동 sync 도입 후로는 사용자가 다시 돌릴 일이 거의 없다 |
| `hooks/sync_jobs.sh` | SessionStart 마다 자동 sync |

### 커밋 메시지

영어로 작성, 본문은 "왜" 중심. version bump 가 포함된 커밋은 메시지 첫 줄에 `(v0.X.Y)` 또는 본문에 `Bump version to 0.X.Y` 한 줄을 명시.

---

## 라이선스

MIT
