#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ORIG_HOME="$HOME"
TMP_HOME=$(mktemp -d /tmp/claude-candy-live.XXXXXX)

cleanup() {
    if [ -n "${KEEP_TMP_HOME:-}" ]; then
        echo "tmp home kept at: $TMP_HOME"
        return
    fi
    rm -rf "$TMP_HOME"
}
trap cleanup EXIT

copy_repo() {
    rm -rf "$TMP_HOME/jobs"
    cp -R "$REPO_ROOT" "$TMP_HOME/jobs"
    rm -rf "$TMP_HOME/jobs/logs"
    mkdir -p "$TMP_HOME/jobs/logs" "$TMP_HOME/.local/bin" "$TMP_HOME/Library/LaunchAgents" "$TMP_HOME/.config"
    rm -f "$TMP_HOME/jobs/config/.optimizer_phase"

    if [ -e "$ORIG_HOME/.claude" ]; then
        ln -s "$ORIG_HOME/.claude" "$TMP_HOME/.claude"
    fi
    if [ -e "$ORIG_HOME/.claude.json" ]; then
        ln -s "$ORIG_HOME/.claude.json" "$TMP_HOME/.claude.json"
    fi
    if [ -e "$ORIG_HOME/.config/claude" ]; then
        ln -s "$ORIG_HOME/.config/claude" "$TMP_HOME/.config/claude"
    fi
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

    chmod +x "$TMP_HOME/.local/bin/launchctl" "$TMP_HOME/.local/bin/osascript"
}

ts_of() {
    python3 - "$1" <<'EOF'
import datetime
import sys

print(int(datetime.datetime.fromisoformat(sys.argv[1]).timestamp()))
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

seed_data() {
    local target_date="$1"

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
}

main() {
    copy_repo
    write_fake_commands

    local fake_now target_date
    fake_now=$(ts_of "2026-04-21T23:00:00")
    target_date="2026-04-20"
    seed_data "$target_date"

    if ! HOME="$ORIG_HOME" JOBS_ROOT="$TMP_HOME/jobs" PLIST_SYS_DIR="$TMP_HOME/Library/LaunchAgents" TOOLS_BIN_DIR="$TMP_HOME/.local/bin" FAKE_NOW_TS="$fake_now" TEST_MODE=1 CLAUDE_RAW_DEBUG_DIR="$TMP_HOME/jobs/logs/claude_raw" \
        bash "$TMP_HOME/jobs/bin/schedule_optimizer.sh"; then
        echo "live smoke failed"
        echo
        echo "=== schedule_changes.log (tail) ==="
        tail -n 40 "$TMP_HOME/jobs/logs/schedule_changes.log" 2>/dev/null || true
        echo
        echo "=== claude_raw (tail) ==="
        for file in "$TMP_HOME"/jobs/logs/claude_raw/attempt_*.json; do
            [ -f "$file" ] || continue
            echo "--- $(basename "$file") ---"
            python3 - "$file" <<'EOF'
import sys
text = open(sys.argv[1]).read()
print(text[:2500])
EOF
        done
        echo
        echo "=== fake_launchctl.log ==="
        cat "$TMP_HOME/jobs/logs/fake_launchctl.log" 2>/dev/null || true
        exit 1
    fi

    echo
    echo "=== schedule_changes.log (tail) ==="
    tail -n 20 "$TMP_HOME/jobs/logs/schedule_changes.log"

    echo
    echo "=== generated schedules ==="
    python3 <<'EOF'
import plistlib
import os

home = os.environ["TMP_HOME"]
for name in (
    "com.claude.candy.plist",
    "com.claude.candy.progress.plist",
    "com.claude.candy.snapshot.plist",
):
    path = os.path.join(home, "jobs", "LaunchAgents", name)
    with open(path, "rb") as f:
        data = plistlib.load(f)
    times = [(item["Hour"], item["Minute"]) for item in data["StartCalendarInterval"]]
    print(name, times)
EOF
}

TMP_HOME="$TMP_HOME" main "$@"
