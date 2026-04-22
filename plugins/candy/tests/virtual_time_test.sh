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
        echo "assertion failed: expected $file to contain $pattern" >&2
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
    run_job_script "$(ts_of "2026-04-21T13:58:00")" bash "$TMP_HOME/jobs/bin/usage_snapshot.sh"

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
    run_job_script "$(ts_of "2026-04-21T13:58:00")" bash "$TMP_HOME/jobs/bin/usage_snapshot.sh"

    assert_csv_value "$TMP_HOME/jobs/logs/usage_snapshots.csv" "all(r['effective_5h_used_pct'] == '100' for r in rows)"
    assert_csv_value "$TMP_HOME/jobs/logs/usage_snapshots.csv" "all(r['progress_source'] == 'limit_carry' for r in rows)"
    assert_csv_value "$TMP_HOME/jobs/logs/usage_snapshots.csv" "all(r['limit_hit_at'] == rows[0]['limit_hit_at'] for r in rows)"
}

scenario_optimizer_skip_and_update() {
    copy_repo
    write_fake_commands

    local target_date fake_now
    fake_now=$(ts_of "2026-04-21T23:00:00")
    target_date="2026-04-20"

    append_csv_row "{\"timestamp\": 1776650400, \"datetime\": \"$target_date 10:58:00\", \"dow\": 0, \"hour\": 10, \"type\": \"snapshot\", \"sample_slot\": \"final\", \"5h_used_pct\": 40, \"5h_resets_at\": 1776657600}"
    append_csv_row "{\"timestamp\": 1776668400, \"datetime\": \"$target_date 15:58:00\", \"dow\": 0, \"hour\": 15, \"type\": \"snapshot\", \"sample_slot\": \"final\", \"5h_used_pct\": 65, \"5h_resets_at\": 1776675600}"
    append_csv_row "{\"timestamp\": 1776686400, \"datetime\": \"$target_date 20:58:00\", \"dow\": 0, \"hour\": 20, \"type\": \"snapshot\", \"sample_slot\": \"final\", \"5h_used_pct\": 72, \"5h_resets_at\": 1776693600}"

    run_job_script "$fake_now" bash "$TMP_HOME/jobs/bin/schedule_optimizer.sh" >/dev/null
    [ ! -f "$TMP_HOME/jobs/logs/fake_claude.log" ]

    copy_repo
    write_fake_commands

    append_csv_row "{\"timestamp\": 1776649200, \"datetime\": \"$target_date 08:00:00\", \"dow\": 0, \"hour\": 8, \"type\": \"progress\", \"sample_slot\": \"1h\", \"5h_used_pct\": 20, \"effective_5h_used_pct\": 20, \"5h_resets_at\": 1776657600, \"progress_source\": \"raw\"}"
    append_csv_row "{\"timestamp\": 1776652800, \"datetime\": \"$target_date 09:00:00\", \"dow\": 0, \"hour\": 9, \"type\": \"progress\", \"sample_slot\": \"2h\", \"5h_used_pct\": 44, \"effective_5h_used_pct\": 44, \"5h_resets_at\": 1776657600, \"progress_source\": \"raw\"}"
    append_csv_row "{\"timestamp\": 1776656400, \"datetime\": \"$target_date 10:00:00\", \"dow\": 0, \"hour\": 10, \"type\": \"progress\", \"sample_slot\": \"3h\", \"5h_used_pct\": 78, \"effective_5h_used_pct\": 78, \"5h_resets_at\": 1776657600, \"progress_source\": \"raw\"}"
    append_csv_row "{\"timestamp\": 1776660000, \"datetime\": \"$target_date 11:00:00\", \"dow\": 0, \"hour\": 11, \"type\": \"progress\", \"sample_slot\": \"4h\", \"5h_used_pct\": 95, \"effective_5h_used_pct\": 95, \"5h_resets_at\": 1776657600, \"progress_source\": \"raw\"}"
    append_csv_row "{\"timestamp\": 1776663480, \"datetime\": \"$target_date 11:58:00\", \"dow\": 0, \"hour\": 11, \"type\": \"snapshot\", \"sample_slot\": \"final\", \"5h_used_pct\": 99, \"effective_5h_used_pct\": 99, \"5h_resets_at\": 1776657600, \"progress_source\": \"raw\"}"
    append_csv_row "{\"timestamp\": 1776667200, \"datetime\": \"$target_date 13:00:00\", \"dow\": 0, \"hour\": 13, \"type\": \"progress\", \"sample_slot\": \"1h\", \"5h_used_pct\": 18, \"effective_5h_used_pct\": 18, \"5h_resets_at\": 1776675600, \"progress_source\": \"raw\"}"
    append_csv_row "{\"timestamp\": 1776670800, \"datetime\": \"$target_date 14:00:00\", \"dow\": 0, \"hour\": 14, \"type\": \"progress\", \"sample_slot\": \"2h\", \"5h_used_pct\": 36, \"effective_5h_used_pct\": 36, \"5h_resets_at\": 1776675600, \"progress_source\": \"raw\"}"
    append_csv_row "{\"timestamp\": 1776674400, \"datetime\": \"$target_date 15:00:00\", \"dow\": 0, \"hour\": 15, \"type\": \"progress\", \"sample_slot\": \"3h\", \"5h_used_pct\": 61, \"effective_5h_used_pct\": 61, \"5h_resets_at\": 1776675600, \"progress_source\": \"raw\"}"
    append_csv_row "{\"timestamp\": 1776678000, \"datetime\": \"$target_date 16:00:00\", \"dow\": 0, \"hour\": 16, \"type\": \"progress\", \"sample_slot\": \"4h\", \"5h_used_pct\": 85, \"effective_5h_used_pct\": 85, \"5h_resets_at\": 1776675600, \"progress_source\": \"raw\"}"
    append_csv_row "{\"timestamp\": 1776681480, \"datetime\": \"$target_date 16:58:00\", \"dow\": 0, \"hour\": 16, \"type\": \"snapshot\", \"sample_slot\": \"final\", \"5h_used_pct\": 92, \"effective_5h_used_pct\": 92, \"5h_resets_at\": 1776675600, \"progress_source\": \"raw\"}"
    append_csv_row "{\"timestamp\": 1776685200, \"datetime\": \"$target_date 18:00:00\", \"dow\": 0, \"hour\": 18, \"type\": \"progress\", \"sample_slot\": \"1h\", \"5h_used_pct\": 15, \"effective_5h_used_pct\": 15, \"5h_resets_at\": 1776693600, \"progress_source\": \"raw\"}"
    append_csv_row "{\"timestamp\": 1776688800, \"datetime\": \"$target_date 19:00:00\", \"dow\": 0, \"hour\": 19, \"type\": \"progress\", \"sample_slot\": \"2h\", \"5h_used_pct\": 33, \"effective_5h_used_pct\": 33, \"5h_resets_at\": 1776693600, \"progress_source\": \"raw\"}"
    append_csv_row "{\"timestamp\": 1776692400, \"datetime\": \"$target_date 20:00:00\", \"dow\": 0, \"hour\": 20, \"type\": \"progress\", \"sample_slot\": \"3h\", \"5h_used_pct\": 57, \"effective_5h_used_pct\": 57, \"5h_resets_at\": 1776693600, \"progress_source\": \"raw\"}"
    append_csv_row "{\"timestamp\": 1776696000, \"datetime\": \"$target_date 21:00:00\", \"dow\": 0, \"hour\": 21, \"type\": \"progress\", \"sample_slot\": \"4h\", \"5h_used_pct\": 88, \"effective_5h_used_pct\": 88, \"5h_resets_at\": 1776693600, \"progress_source\": \"raw\"}"
    append_csv_row "{\"timestamp\": 1776699480, \"datetime\": \"$target_date 21:58:00\", \"dow\": 0, \"hour\": 21, \"type\": \"snapshot\", \"sample_slot\": \"final\", \"5h_used_pct\": 94, \"effective_5h_used_pct\": 94, \"5h_resets_at\": 1776693600, \"progress_source\": \"raw\"}"
    append_csv_row "{\"timestamp\": 1776703200, \"datetime\": \"$target_date 23:00:00\", \"dow\": 0, \"hour\": 23, \"type\": \"progress\", \"sample_slot\": \"1h\", \"5h_used_pct\": 12, \"effective_5h_used_pct\": 12, \"5h_resets_at\": 1776711600, \"progress_source\": \"raw\"}"
    append_csv_row "{\"timestamp\": 1776706800, \"datetime\": \"$target_date 23:58:00\", \"dow\": 0, \"hour\": 23, \"type\": \"snapshot\", \"sample_slot\": \"final\", \"5h_used_pct\": 48, \"effective_5h_used_pct\": 48, \"5h_resets_at\": 1776711600, \"progress_source\": \"raw\"}"

    cat > "$TMP_HOME/jobs/logs/fake_claude_response.ndjson" <<'EOF'
{"type":"result","result":"{\"times\": [[7, 1], [12, 1], [17, 1], [22, 1]], \"reason\": \"오후 보호를 위해 한 시간씩 뒤로 민다.\"}"}
EOF

    HOME="$TMP_HOME" FAKE_NOW_TS="$fake_now" TEST_MODE=1 FAKE_CLAUDE_FILE="$TMP_HOME/jobs/logs/fake_claude_response.ndjson" \
        bash "$TMP_HOME/jobs/bin/schedule_optimizer.sh" >/dev/null

    assert_file_contains "$TMP_HOME/jobs/logs/fake_launchctl.log" "com.claude.candy.progress"
    assert_file_contains "$TMP_HOME/jobs/logs/fake_launchctl.log" "com.claude.candy.snapshot"
    assert_file_contains "$TMP_HOME/jobs/logs/fake_launchctl.log" "com.claude.candy"
    assert_file_contains "$TMP_HOME/jobs/LaunchAgents/com.claude.candy.snapshot.plist" "<integer>6</integer><key>Minute</key><integer>58</integer>"
    assert_file_contains "$TMP_HOME/jobs/LaunchAgents/com.claude.candy.progress.plist" "<integer>8</integer><key>Minute</key><integer>0</integer>"
}

main() {
    scenario_progress_and_final
    scenario_stale_and_weekend
    scenario_limit_carry
    scenario_optimizer_skip_and_update
    echo "virtual_time_test.sh: ok"
}

main "$@"
