#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_HOME=$(mktemp -d /tmp/claude-candy-test.XXXXXX)

cleanup() {
    rm -rf "$TMP_HOME"
}
trap cleanup EXIT

copy_repo() {
    rm -rf "$TMP_HOME/jobs"
    cp -R "$REPO_ROOT" "$TMP_HOME/jobs"
    rm -rf "$TMP_HOME/jobs/logs"
    mkdir -p "$TMP_HOME/jobs/logs" "$TMP_HOME/.claude" "$TMP_HOME/.local/bin" "$TMP_HOME/Library/LaunchAgents"
    rm -f "$TMP_HOME/jobs/config/.optimizer_phase"
    rm -f "$TMP_HOME/jobs/config/.candy_morning_ts"
    rm -f "$TMP_HOME/jobs/config/.candy_next_ts"
}

write_fake_commands() {
    cat > "$TMP_HOME/.local/bin/launchctl" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'launchctl %s\n' "$*" >> "${JOBS_ROOT:-$HOME/jobs}/logs/fake_launchctl.log"
EOF

    cat > "$TMP_HOME/.local/bin/osascript" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'osascript %s\n' "$*" >> "${JOBS_ROOT:-$HOME/jobs}/logs/fake_osascript.log"
EOF

    cat > "$TMP_HOME/.local/bin/claude" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'claude %s\n' "$*" >> "${JOBS_ROOT:-$HOME/jobs}/logs/fake_claude.log"
if [ -n "${FAKE_CLAUDE_FILE:-}" ]; then
    cat "$FAKE_CLAUDE_FILE"
elif [ -n "${FAKE_CLAUDE_RESPONSE:-}" ]; then
    printf '%s\n' "$FAKE_CLAUDE_RESPONSE"
else
    printf '%s\n' '{"type":"result","result":"ok"}'
fi
EOF

    chmod +x "$TMP_HOME/.local/bin/launchctl" "$TMP_HOME/.local/bin/osascript" "$TMP_HOME/.local/bin/claude"
}

ts_of() {
    python3 - "$1" <<'EOF'
import datetime
import sys

print(int(datetime.datetime.fromisoformat(sys.argv[1]).timestamp()))
EOF
}

run_job_script() {
    local fake_now_ts="$1"
    shift
    HOME="$TMP_HOME" JOBS_ROOT="$TMP_HOME/jobs" PLIST_SYS_DIR="$TMP_HOME/Library/LaunchAgents" TOOLS_BIN_DIR="$TMP_HOME/.local/bin" FAKE_NOW_TS="$fake_now_ts" TEST_MODE=1 "$@"
}

write_rate_file() {
    local reset_ts="$1"
    local used_pct="$2"
    local seven_pct="${3:-40}"
    cat > "$TMP_HOME/.claude/abtop-rate-limits.json" <<EOF
{"five_hour":{"used_percentage":$used_pct,"resets_at":$reset_ts},"seven_day":{"used_percentage":$seven_pct}}
EOF
}

append_csv_row() {
    local payload="$1"
    HOME="$TMP_HOME" PYTHONPATH="$TMP_HOME/jobs/bin/lib" python3 - "$TMP_HOME/jobs/logs/usage_snapshots.csv" "$payload" <<'EOF'
import json
import sys

from usage_csv import append_row

csv_file = sys.argv[1]
row = json.loads(sys.argv[2])
append_row(csv_file, row)
EOF
}

assert_file_contains() {
    local file="$1" pattern="$2"
    if ! grep -q "$pattern" "$file"; then
        echo "assertion failed: expected $file to contain '$pattern'" >&2
        exit 1
    fi
}

assert_file_not_exists() {
    local file="$1"
    if [ -f "$file" ]; then
        echo "assertion failed: $file should not exist" >&2
        exit 1
    fi
}

assert_file_exists() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo "assertion failed: $file should exist" >&2
        exit 1
    fi
}

assert_csv_value() {
    local csv_file="$1" expr="$2"
    PYTHONPATH="$TMP_HOME/jobs/bin/lib" python3 - "$csv_file" "$expr" <<'EOF'
import csv
import sys

csv_file = sys.argv[1]
expr = sys.argv[2]
rows = list(csv.DictReader(open(csv_file)))
if not eval(expr, {"rows": rows}):
    raise SystemExit(f"assertion failed: {expr}")
EOF
}

scenario_progress_and_final() {
    copy_repo
    write_fake_commands

    local reset_ts
    reset_ts=$(ts_of "2026-04-21T14:00:00")
    write_rate_file "$reset_ts" 42

    run_job_script "$(ts_of "2026-04-21T10:00:00")" bash "$TMP_HOME/jobs/bin/usage_progress.sh"
    run_job_script "$(ts_of "2026-04-21T11:00:00")" bash "$TMP_HOME/jobs/bin/usage_progress.sh"
    run_job_script "$(ts_of "2026-04-21T12:00:00")" bash "$TMP_HOME/jobs/bin/usage_progress.sh"
    run_job_script "$(ts_of "2026-04-21T13:00:00")" bash "$TMP_HOME/jobs/bin/usage_progress.sh"
    run_job_script "$(ts_of "2026-04-21T13:57:00")" bash "$TMP_HOME/jobs/bin/usage_snapshot.sh"

    assert_csv_value "$TMP_HOME/jobs/logs/usage_snapshots.csv" "len(rows) == 5"
    assert_csv_value "$TMP_HOME/jobs/logs/usage_snapshots.csv" "[r['sample_slot'] for r in rows] == ['1h', '2h', '3h', '4h', 'final']"
    assert_csv_value "$TMP_HOME/jobs/logs/usage_snapshots.csv" "all(r['5h_resets_at'] == rows[0]['5h_resets_at'] for r in rows)"
}

scenario_stale_and_weekend() {
    copy_repo
    write_fake_commands

    local reset_ts stale_out
    reset_ts=$(ts_of "2026-04-21T14:00:00")
    write_rate_file "$reset_ts" 55

    stale_out=$(run_job_script "$(ts_of "2026-04-21T14:05:00")" bash "$TMP_HOME/jobs/bin/usage_snapshot.sh")
    [[ "$stale_out" == *"stale data"* ]]

    run_job_script "$(ts_of "2026-04-25T10:00:00")" bash "$TMP_HOME/jobs/bin/usage_snapshot.sh" >/dev/null
    run_job_script "$(ts_of "2026-04-25T10:00:00")" bash "$TMP_HOME/jobs/bin/refresh_claude.sh" >/dev/null
    run_job_script "$(ts_of "2026-04-25T23:00:00")" bash "$TMP_HOME/jobs/bin/schedule_optimizer.sh" >/dev/null

    [ ! -f "$TMP_HOME/jobs/logs/fake_claude.log" ]
}

scenario_limit_carry() {
    copy_repo
    write_fake_commands

    local reset_ts hit_ts
    reset_ts=$(ts_of "2026-04-21T14:00:00")
    hit_ts=$(ts_of "2026-04-21T12:17:00")
    cat > "$TMP_HOME/jobs/logs/.limit_until" <<EOF
$reset_ts
$hit_ts
hit your limit
EOF

    run_job_script "$(ts_of "2026-04-21T13:00:00")" bash "$TMP_HOME/jobs/bin/usage_progress.sh"
    run_job_script "$(ts_of "2026-04-21T13:57:00")" bash "$TMP_HOME/jobs/bin/usage_snapshot.sh"

    assert_csv_value "$TMP_HOME/jobs/logs/usage_snapshots.csv" "all(r['effective_5h_used_pct'] == '100' for r in rows)"
    assert_csv_value "$TMP_HOME/jobs/logs/usage_snapshots.csv" "all(r['progress_source'] == 'limit_carry' for r in rows)"
    assert_csv_value "$TMP_HOME/jobs/logs/usage_snapshots.csv" "all(r['limit_hit_at'] == rows[0]['limit_hit_at'] for r in rows)"
}

# optimizer가 데이터 부족 시 skip하고, 충분한 데이터와 valid 응답으로 .candy_morning_ts를 기록하는지 검증
scenario_optimizer_morning_ts() {
    copy_repo
    write_fake_commands

    local fake_now target_date
    fake_now=$(ts_of "2026-04-21T23:00:00")  # 화요일 23:00 (DOW=2)
    target_date="2026-04-21"                   # today = 화요일

    # 2개 snapshot (MIN_SNAPSHOTS=3 미만 → skip 확인)
    append_csv_row "{\"timestamp\":1776736800,\"datetime\":\"$target_date 11:00:00\",\"dow\":2,\"hour\":11,\"type\":\"snapshot\",\"sample_slot\":\"final\",\"5h_used_pct\":40,\"5h_resets_at\":1776744000,\"effective_5h_used_pct\":40,\"progress_source\":\"raw\"}"
    append_csv_row "{\"timestamp\":1776754800,\"datetime\":\"$target_date 16:00:00\",\"dow\":2,\"hour\":16,\"type\":\"snapshot\",\"sample_slot\":\"final\",\"5h_used_pct\":65,\"5h_resets_at\":1776762000,\"effective_5h_used_pct\":65,\"progress_source\":\"raw\"}"

    run_job_script "$fake_now" bash "$TMP_HOME/jobs/bin/schedule_optimizer.sh" >/dev/null
    assert_file_not_exists "$TMP_HOME/jobs/logs/fake_claude.log"

    # 3번째 row 추가 → 3개 = MIN_SNAPSHOTS → proceed
    append_csv_row "{\"timestamp\":1776772800,\"datetime\":\"$target_date 21:00:00\",\"dow\":2,\"hour\":21,\"type\":\"snapshot\",\"sample_slot\":\"final\",\"5h_used_pct\":72,\"5h_resets_at\":1776780000,\"effective_5h_used_pct\":72,\"progress_source\":\"raw\"}"

    # FAKE_CLAUDE_FILE: time=[7,45] 응답 (retry sleep 없이 바로 성공)
    cat > "$TMP_HOME/jobs/logs/fake_claude_response.ndjson" <<'RESP'
{"type":"result","result":"{\"time\": [7, 45], \"reason\": \"점심 12:45 종료 기준 07:45 pre-warm.\"}"}
RESP

    # FAKE_CLAUDE_FILE은 shell function prefix로 전달하면 자식 프로세스에 export 안 됨 → 직접 호출
    HOME="$TMP_HOME" JOBS_ROOT="$TMP_HOME/jobs" PLIST_SYS_DIR="$TMP_HOME/Library/LaunchAgents" \
        TOOLS_BIN_DIR="$TMP_HOME/.local/bin" FAKE_NOW_TS="$fake_now" TEST_MODE=1 \
        FAKE_CLAUDE_FILE="$TMP_HOME/jobs/logs/fake_claude_response.ndjson" \
        bash "$TMP_HOME/jobs/bin/schedule_optimizer.sh" >/dev/null

    # .candy_morning_ts 파일이 생성되어야 함
    assert_file_exists "$TMP_HOME/jobs/config/.candy_morning_ts"

    # ts가 내일(2026-04-22) 07:45에 해당해야 함
    PYTHONPATH="$TMP_HOME/jobs/bin/lib" python3 - "$TMP_HOME/jobs/config/.candy_morning_ts" <<'PYEOF'
import datetime, sys

with open(sys.argv[1]) as f:
    ts = int(f.read().strip())
dt = datetime.datetime.fromtimestamp(ts)
expected = datetime.datetime(2026, 4, 22, 7, 45)
assert dt == expected, f"expected {expected}, got {dt}"
PYEOF
}

# gate: morning_ts가 미래이면 refresh_claude.sh가 silent skip
scenario_gate_morning_blocks() {
    copy_repo
    write_fake_commands

    # morning_ts = 오늘 07:23 (현재 05:00보다 미래)
    local fake_now morning_ts
    fake_now=$(ts_of "2026-04-21T05:00:00")
    morning_ts=$(ts_of "2026-04-21T07:23:00")
    mkdir -p "$TMP_HOME/jobs/config"
    echo "$morning_ts" > "$TMP_HOME/jobs/config/.candy_morning_ts"

    run_job_script "$fake_now" bash "$TMP_HOME/jobs/bin/refresh_claude.sh" >/dev/null
    assert_file_not_exists "$TMP_HOME/jobs/logs/fake_claude.log"
}

# gate: next_ts가 미래이면 refresh_claude.sh가 silent skip
scenario_gate_next_ts_blocks() {
    copy_repo
    write_fake_commands

    local fake_now next_ts
    fake_now=$(ts_of "2026-04-21T10:00:00")
    next_ts=$(ts_of "2026-04-21T11:00:00")  # 미래
    mkdir -p "$TMP_HOME/jobs/config"
    echo "$next_ts" > "$TMP_HOME/jobs/config/.candy_next_ts"

    run_job_script "$fake_now" bash "$TMP_HOME/jobs/bin/refresh_claude.sh" >/dev/null
    assert_file_not_exists "$TMP_HOME/jobs/logs/fake_claude.log"
}

# gate: next_ts가 과거이고 morning_ts 없으면 candy 실행 + 체인 갱신 검증
scenario_gate_proceeds_when_past() {
    copy_repo
    write_fake_commands

    local fake_now past_ts resets_at
    fake_now=$(ts_of "2026-04-21T07:23:00")
    past_ts=$(ts_of "2026-04-21T06:00:00")
    resets_at=$(ts_of "2026-04-21T12:23:00")
    mkdir -p "$TMP_HOME/jobs/config"
    echo "$past_ts" > "$TMP_HOME/jobs/config/.candy_next_ts"

    # rate_limit_event 포함 응답으로 chain 갱신 경로 활성화
    cat > "$TMP_HOME/jobs/logs/fake_claude_response.ndjson" <<RESP
{"type":"result","result":"ok"}
{"type":"rate_limit_event","rate_limit_info":{"resetsAt":$resets_at}}
RESP

    HOME="$TMP_HOME" JOBS_ROOT="$TMP_HOME/jobs" PLIST_SYS_DIR="$TMP_HOME/Library/LaunchAgents" \
        TOOLS_BIN_DIR="$TMP_HOME/.local/bin" FAKE_NOW_TS="$fake_now" TEST_MODE=1 \
        FAKE_CLAUDE_FILE="$TMP_HOME/jobs/logs/fake_claude_response.ndjson" \
        bash "$TMP_HOME/jobs/bin/refresh_claude.sh" >/dev/null

    # gate를 통과해 claude가 호출되어야 함
    assert_file_exists "$TMP_HOME/jobs/logs/fake_claude.log"

    # .candy_next_ts가 resets_at으로 갱신되었는지
    local next_recorded
    next_recorded=$(cat "$TMP_HOME/jobs/config/.candy_next_ts" 2>/dev/null || echo "")
    [ "$next_recorded" = "$resets_at" ] || {
        echo "assertion failed: .candy_next_ts=$next_recorded, expected=$resets_at" >&2
        exit 1
    }

    # snapshot.plist에 resets_at - 3min(=12:20) 단일 entry 존재
    PLIST_PATH="$TMP_HOME/jobs/LaunchAgents/com.claude.candy.snapshot.plist" python3 <<'PYEOF'
import os, plistlib
with open(os.environ["PLIST_PATH"], "rb") as f:
    data = plistlib.load(f)
slots = [(i["Hour"], i["Minute"]) for i in data.get("StartCalendarInterval", [])]
assert slots == [(12, 20)], f"snapshot expected [(12, 20)], got {slots}"
PYEOF

    # progress.plist에 candy(07:23) + 59/119/179/239min = 08:22 / 09:22 / 10:22 / 11:22
    PLIST_PATH="$TMP_HOME/jobs/LaunchAgents/com.claude.candy.progress.plist" python3 <<'PYEOF'
import os, plistlib
with open(os.environ["PLIST_PATH"], "rb") as f:
    data = plistlib.load(f)
slots = sorted((i["Hour"], i["Minute"]) for i in data.get("StartCalendarInterval", []))
expected = [(8, 22), (9, 22), (10, 22), (11, 22)]
assert slots == expected, f"progress expected {expected}, got {slots}"
PYEOF
}

# quiet hours: 23:00~04:59 사이엔 silent skip
scenario_quiet_hours_blocks() {
    copy_repo
    write_fake_commands

    local fake_now
    fake_now=$(ts_of "2026-04-21T03:30:00")  # 새벽
    mkdir -p "$TMP_HOME/jobs/config"
    # next_ts는 과거 (gate는 통과해야 하지만 quiet hours가 막음)
    echo "$(ts_of "2026-04-21T03:00:00")" > "$TMP_HOME/jobs/config/.candy_next_ts"

    run_job_script "$fake_now" bash "$TMP_HOME/jobs/bin/refresh_claude.sh" >/dev/null
    assert_file_not_exists "$TMP_HOME/jobs/logs/fake_claude.log"
}

main() {
    scenario_progress_and_final
    scenario_stale_and_weekend
    scenario_limit_carry
    scenario_optimizer_morning_ts
    scenario_gate_morning_blocks
    scenario_gate_next_ts_blocks
    scenario_gate_proceeds_when_past
    scenario_quiet_hours_blocks
    echo "virtual_time_test.sh: ok"
}

main "$@"
