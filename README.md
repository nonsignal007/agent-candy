# agent-candy

Claude Code 플러그인 마켓플레이스. `candy` 플러그인 하나를 제공한다.

## candy — 5시간 윈도우 자동화

점심시간을 Claude Code 의 5시간 사용 윈도우 안에 포함시켜 토큰 낭비를 줄이고, 오후 고사용 시간대에 새 윈도우가 시작되도록 자동 조정하는 macOS LaunchAgent 번들이다.

자세한 내부 동작은 [plugins/candy/README.md](plugins/candy/README.md) 를 참고.

## 설치

### 1. 이 마켓플레이스 등록

Claude Code 에서:

```
/plugin marketplace add nonsignal007/agent-candy
```

### 2. 플러그인 설치

```
/plugin install candy@agent-candy
```

### 3. 설치 스킬 실행

플러그인이 설치되면 `candy-setup` 스킬이 자동 등록된다. 설치하려면 다음과 같이 요청한다:

- "claude candy 설치해줘"
- "candy 스케줄러 설정"
- "점심시간 pre-warm 설정"

스킬이 다음을 자동으로 수행한다:

1. JOBS_ROOT 경로 확인 (기본 `~/jobs`)
2. 의존성 검증 (`claude`, `python3`, `launchctl`, `plutil`, `osascript`)
3. Claude CLI preflight
4. 플러그인 번들을 JOBS_ROOT 로 복사
5. `~/Library/LaunchAgents` symlink 생성
6. LaunchAgent 부트스트랩
7. **macOS 알림 권한 확인 (사용자 수동 단계)**
8. `launchctl print` 로 검증
9. 가상 회귀 테스트 실행
10. (옵션) Live smoke 테스트

## 자동 업데이트

설치 후엔 사용자가 별도로 무엇을 할 필요가 없다. 마켓플레이스가 새 버전을 올리면 다음 Claude Code 세션 시작 시 `hooks/sync_jobs.sh` 가 자동으로:

1. `plugin.json` 의 새 version 과 사용자의 `~/jobs/.candy_version` 비교
2. 다르면 `bin/`, `LaunchAgents/`, `tests/` 와 `lunch_schedule.conf` 새 번들로 갱신
3. LaunchAgent 4개 재부트스트랩
4. 버전 파일 갱신 + 알림 표시

`logs/`, `config/.optimizer_phase` 등 런타임 상태는 보존된다. 자동 sync 를 끄고 싶으면 `~/.candy_no_sync` 빈 파일을 만든다.

## 요구 사항

- macOS (GUI 로그인 세션)
- `claude` CLI (로그인된 상태)
- `python3`, `launchctl`, `plutil`, `osascript`

## 저장소 구조

```
agent-candy/
├── .claude-plugin/
│   └── marketplace.json          # 마켓플레이스 매니페스트
└── plugins/
    └── candy/
        ├── .claude-plugin/
        │   └── plugin.json       # 플러그인 매니페스트
        ├── skills/
        │   ├── candy-setup/
        │   │   └── SKILL.md      # 설치 스킬
        │   └── candy-doctor/
        │       ├── SKILL.md      # 헬스체크/진단 스킬
        │       └── scripts/      # candy_doctor.py 진단 스크립트
        ├── hooks/                 # SessionStart 자동 sync 훅
        │   ├── hooks.json
        │   └── sync_jobs.sh
        ├── bin/                   # Candy 실행 스크립트
        ├── LaunchAgents/          # plist 템플릿 4개
        ├── config/
        │   └── lunch_schedule.conf
        ├── tests/                 # 가상/실제 테스트
        └── README.md              # Candy 상세 문서
```

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
- **patch** (0.2.0 → 0.2.1): 버그 픽스, 사용자 동작 무변화
- **minor** (0.2.0 → 0.3.0): 새 기능, plist 구조 변경, 새 스크립트 추가
- **major** (0.2.0 → 1.0.0): config 포맷 변경, 런타임 상태 schema 변경 등 backward-incompatible

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

- `candy-doctor` — 헬스체크 + 실행 검증. `runtime.version_sync` 체크로 사용자의 `~/jobs/.candy_version` 이 plugin.json 과 다르면 warn.
- `candy-setup` — 첫 설치 / 강제 재배포 용. 자동 sync 도입 후로는 사용자가 다시 돌릴 일이 거의 없다.
- `hooks/sync_jobs.sh` — SessionStart 마다 자동 sync.

### 커밋 메시지

영어로 작성, 본문은 "왜" 중심. version bump 가 포함된 커밋은 메시지 첫 줄에 `(v0.X.Y)` 또는 본문에 `Bump version to 0.X.Y` 한 줄을 명시.

## 라이선스

MIT
