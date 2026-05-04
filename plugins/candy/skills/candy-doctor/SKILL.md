---
name: candy-doctor
description: Claude Candy 설치 상태를 진단하고 안전한 것은 바로 고쳐주는 헬스체크 스킬. 번들 진단 스크립트로 의존성, Claude 로그인, JOBS_ROOT 파일 구조, LaunchAgent 등록/스케줄 정합성, 런타임 로그/CSV stale, optimizer gate, macOS 알림 권한, snapshot/progress/optimizer/chain-gate 격리 dry-run 실행 검증까지 한 번에 점검한다. 사용자가 "candy 상태 확인", "candy 점검", "candy-doctor", "candy 진단", "candy 이상한데", "candy 왜 안 돌아", "점심 pre-warm 안 먹힘", "optimizer 왜 멈춤", "usage_snapshots.csv stale" 같은 요청을 하거나 com.claude.candy.* 관련 동작 이상을 의심할 때 반드시 이 스킬을 사용한다. 결과는 심각도(MUST/detail)로 분류되고, 수정 가능한 항목은 정책별(자동/확인/수동)로 안내되어 사용자가 위험한 변경을 모른 채 당하지 않는다.
---

# Claude Candy Doctor

Candy 설치가 실제로 잘 돌아가는지 런타임 상태를 진단하고, 안전한 이상은 바로 고치고, 위험한 변경은 사용자 확인을 받아 처리한다.

Virtual regression test (`tests/virtual_time_test.sh`) 는 돌리지 않는다 — 그건 코드 회귀 테스트이지 헬스체크가 아니다. 이 스킬은 **지금 이 순간 Candy 가 제대로 도는가** 만 본다.

정적 점검(파일/등록 상태)뿐 아니라 `usage_snapshot.sh`, `usage_progress.sh`, `schedule_optimizer.sh` 의 핵심 로직과 `refresh_claude.sh` 의 chain gate 를 **격리된 temp JOBS_ROOT 에서 실제 dry-run** 으로 실행해 결과를 검증한다 (실제 `~/jobs/logs` 는 절대 건드리지 않음). Claude API 호출은 일어나지 않는다.

## 어떻게 동작하는가

1. 번들 스크립트 `scripts/candy_doctor.py` 를 `--json` 으로 실행한다.
2. 스크립트는 50여개 체크를 돌리고, 각 체크마다 `status`, `fix_command`, `fix_policy` 를 담은 JSON 리포트를 출력한다. (정적 점검 + execution dry-run)
3. Claude 는 그 리포트를 읽고 정책별로 처리한다:
   - **자동 수정 (auto)** — 사용자에게 묻지 않고 실행, 끝나고 한 번에 요약 보고
   - **확인 수정 (confirm)** — 해당 항목들을 한 묶음으로 보여주고 "이거 고쳐도 될까요?" 한 번만 질문
   - **수동 조치 (manual)** — 사용자가 해야 할 일을 명확히 안내
4. 수정 후 다시 스크립트를 돌려서 이상이 남았는지 최종 보고.

## 스크립트 실행

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/skills/candy-doctor/scripts/candy_doctor.py" --json
```

JOBS_ROOT 는 스크립트가 자동 추론한다:
- `JOBS_ROOT` 환경변수가 있으면 그것
- 없으면 `~/Library/LaunchAgents/com.claude.candy.plist` symlink 타겟에서 역산
- 그것도 실패하면 `~/jobs`

사용자가 "다른 경로를 보고 싶다" 고 하면 `--jobs-root <path>` 를 붙인다.

execution dry-run 까지 돌면 5초 정도 더 걸린다. 빠른 정적 진단만 원하면 `--no-exec` 를 붙인다 — execution 카테고리 4개 체크가 모두 `status=skip` 으로 반환된다.

스크립트는 실제 `JOBS_ROOT` 에 대해서는 read-only 다. execution 체크는 별도의 격리된 임시 디렉터리(`/tmp/candy_doctor_exec_*`) 안에서만 파일을 만들고 실행 후 즉시 정리한다. 수정(launchctl bootstrap, symlink 재생성 등)은 Claude가 이 SKILL 의 정책에 따라 직접 한다.

## JSON 리포트 스키마

```jsonc
{
  "jobs_root": "/Users/xxx/jobs",
  "uid": 502,
  "checks": [
    {
      "id": "fs.la.com.claude.candy.symlink",
      "category": "filesystem",
      "severity": "must",              // "must" | "detail"
      "status": "pass",                // "pass" | "warn" | "fail" | "skip"
      "message": "symlink → ...",
      "fix_command": "ln -sfn ... ...", // 있을 수도 없을 수도 있음
      "fix_policy": "confirm",          // "auto" | "confirm" | "manual" | null
      "details": { ... }
    }
  ],
  "summary": { "pass": 49, "warn": 2, "fail": 0, "skip": 0 }
}
```

## 정책별 처리

### 🟢 auto — 자동 수정

무조건 바로 실행한다. 되돌릴 수 있고 시스템 상태에 위험을 주지 않는 것만 이 정책이 붙는다:

- `chmod +x` (실행 비트 복구)
- `mkdir -p` (누락 디렉터리 생성)

끝난 뒤에는 **무엇을 고쳤는지** 간단히 보고한다. 사용자 승인을 받지 않는다 — 그게 auto 의 의미다.

### 🟡 confirm — 확인 수정

`fix_policy=confirm` 인 항목을 **한 번에 묶어서** 사용자에게 보여주고 전체 동의를 받는다. 각각 따로 묻지 않는다 — 질문이 5개면 사용자가 피곤하다. 예:

> "다음 3개를 고쳐도 될까요?
> 1. `com.claude.candy.snapshot` agent 가 등록 안 돼 있어서 `launchctl bootstrap` 재실행
> 2. `com.claude.candy.optimizer` symlink 가 대상이 없어서 재생성
> 3. (...)
>
> yes/no 답만 주세요."

사용자가 yes 면 전부 실행, no 면 전부 스킵하고 이유만 보고한다. 개별 선택을 원하면 물어본 항목 안에서 "X 만", "Y 는 빼고" 같이 명시하게 한다.

**안전 룰**: confirm 항목이 3개 이상 한꺼번에 뜨면, 개별 수정보다 **"`/candy-setup` 을 다시 돌리세요"** 를 먼저 권한다. 부분 수정을 여러 번 하는 것보다 번들을 통째로 재배포하는 게 훨씬 깔끔하기 때문이다.

### 🔴 manual — 수동 조치

사용자가 직접 해야 한다. Claude 가 할 수 있는 건 **정확히 어떤 설정을 어떻게 바꿔야 하는지** 알려주는 것뿐이다. 흔한 케이스:

- Claude CLI 로그인 만료 → "터미널에서 `claude` 실행 후 로그인"
- macOS 알림 권한 → "시스템 설정 > 알림 > osascript / 터미널 허용"
- 바이너리 자체 누락 → "먼저 `python3` / `claude` 설치"
- rate limit 활성 (`.limit_until` 살아 있음) → "해당 시간까지 기다림"

## 보고 형식

스크립트가 끝나고 수정까지 마친 뒤, 다음 순서로 사용자에게 보고한다:

1. **결론 한 줄** — 전체 상태 요약 (예: "정상입니다. 1 warn 은 macOS 알림 권한 확인 필요.")
2. **자동 수정한 항목** (있을 때만)
3. **확인 받고 수정한 항목** (있을 때만)
4. **아직 남은 이상 / 사용자 조치 필요 항목**
5. **추가 점검 힌트** — virtual_time_test.sh 를 수동으로 돌리면 코드 로직 회귀도 잡을 수 있다는 한 줄 안내 (항상 마지막에)

요약은 짧게. 전체 50개 체크 모두 나열하지 않는다 — pass 는 묶어서 "N개 통과", warn/fail 만 상세히.

## 예시 흐름

**사용자**: "candy 상태 좀 봐줘"

**Claude 는 다음 순서로 행동**:

1. `python3 "${CLAUDE_PLUGIN_ROOT}/skills/candy-doctor/scripts/candy_doctor.py" --json` 실행
2. JSON 파싱
3. `fix_policy=auto` 인 warn/fail 이 있으면 먼저 실행 (예: `chmod +x /Users/x/jobs/bin/refresh_claude.sh`)
4. `fix_policy=confirm` 항목이 있으면 묶어서 사용자에게 질문. 3개 이상이면 `/candy-setup` 재실행 권고를 먼저 제시
5. `fix_policy=manual` 항목과 `auto/confirm` 으로 해결 안 된 warn 을 사용자에게 정리
6. 결과를 위 "보고 형식" 순서로 한 번에 출력

## 카테고리

- **binary / env / auth / filesystem / launchd** — MUST. 하나라도 fail 이면 Candy 가 동작 불가.
- **schedule / config / runtime / logic / housekeeping / os** — detail. 작동하지만 점검 필요한 항목.
- **execution** — detail. 격리된 temp JOBS_ROOT 에서 실제 스크립트를 실행해 검증한다:
  - `exec.snapshot.dry_run` — `usage_snapshot.sh` 실행 후 CSV 행과 resetsAt window-start 귀속 확인
  - `exec.progress.dry_run` — `usage_progress.sh` 실행 후 `type=progress`, `sample_slot ∈ {1h,2h,3h,4h}` 확인
  - `exec.optimizer.gate` — `FAKE_NOW_TS` 로 토요일/평일 시뮬레이션해 weekend-skip / 데이터부족-skip 동작 확인
  - `exec.chain.gate` — `refresh_claude.sh` 의 GATE_PYEOF 로직(미래 ts → blocked, 과거 ts → pass) 검증

  주말에 doctor 가 돌면 snapshot/progress/optimizer dry-run 은 자동으로 `skip` 처리된다 (스크립트들이 weekday-only 이므로).

## 주의 사항

- `candy_doctor.py` 의 **정적 체크는 절대 파일을 수정하지 않는다**. execution 체크는 격리된 temp 디렉터리에 한해서만 파일을 만들고 실행 후 정리한다 — 사용자의 실제 `~/jobs/logs/usage_snapshots.csv` 등은 절대 건드리지 않는다.
- 수정은 전부 Claude 가 Bash 로 실행한다. 어떤 명령을 돌리는지 사용자 화면에 그대로 보이는 편이 안전하다.
- JOBS_ROOT 가 예상과 다르면(예: `/tmp/test-jobs`) 모든 체크가 해당 경로 기준으로 돈다. 리포트 맨 위의 `jobs_root` 를 항상 사용자에게 같이 보여준다 — "어디를 봤는지" 가 중요하다.
- 체크 목록이 늘어나면 `--json` 출력이 길어진다. 전부를 사용자에게 쏟아내지 말고 요약한다.

## 실패 시 처리

- 스크립트 자체가 크래시하면: 스택트레이스를 그대로 사용자에게 보여주고 버그 리포트 경로 안내. Claude 가 임의로 "아마 이럴 겁니다" 라고 추측하지 않는다.
- JSON 파싱 실패: 스크립트 출력을 원문으로 보여주고 멈춘다.
- 특정 체크가 timeout 나면 (예: `claude -p` 가 45초 넘게 응답 없음): 해당 체크는 fail 로 기록되고 나머지는 진행된다.
