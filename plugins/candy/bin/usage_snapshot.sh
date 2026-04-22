#!/bin/bash
set -euo pipefail

# usage_snapshot.sh — 현재 5시간 윈도우 사용률을 progress/final CSV로 기록

JOBS_ROOT="${JOBS_ROOT:-$HOME/jobs}"
RATE_FILE="$HOME/.claude/abtop-rate-limits.json"
LIMIT_FLAG="$JOBS_ROOT/logs/.limit_until"
CSV_FILE="$JOBS_ROOT/logs/usage_snapshots.csv"
MAX_CSV_LINES=500
SNAPSHOT_TYPE="${SNAPSHOT_TYPE:-snapshot}"

export RATE_FILE LIMIT_FLAG CSV_FILE MAX_CSV_LINES SNAPSHOT_TYPE
export PYTHONPATH="$JOBS_ROOT/bin/lib${PYTHONPATH:+:$PYTHONPATH}"

# shellcheck source=/dev/null
source "$JOBS_ROOT/bin/lib/candy_time.sh"

# 주말 체크
DOW=$(runtime_weekday_u)
if [ "$DOW" -ge 6 ]; then
    echo "[$SNAPSHOT_TYPE] skip: weekend (DOW=$DOW)"
    exit 0
fi

python3 << 'EOF'
import json
import os
import sys

from candy_time import get_now
from usage_csv import append_row


def parse_limit_flag(path):
    try:
        with open(path) as f:
            lines = [line.rstrip("\n") for line in f if line.strip()]
    except FileNotFoundError:
        return None, None, None

    if not lines:
        return None, None, None

    try:
        reset_at = int(lines[0])
    except ValueError:
        return None, None, None

    hit_at = None
    if len(lines) >= 2:
        try:
            hit_at = int(lines[1])
        except ValueError:
            hit_at = None

    message = lines[-1] if len(lines) >= 2 else ""
    return reset_at, hit_at, message


def read_rate_file(path):
    try:
        with open(path) as f:
            return json.load(f), None
    except (FileNotFoundError, json.JSONDecodeError) as exc:
        return None, exc


def normalize_pct(value):
    if value in ("", None):
        return ""
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return ""


def infer_sample_slot(sample_type, minutes_to_reset):
    if sample_type == "snapshot":
        return "final"

    candidates = [
        (240, "1h"),
        (180, "2h"),
        (120, "3h"),
        (60, "4h"),
    ]
    return min(candidates, key=lambda item: abs(minutes_to_reset - item[0]))[1]


sample_type = os.environ["SNAPSHOT_TYPE"]
rate_file = os.environ["RATE_FILE"]
limit_flag = os.environ["LIMIT_FLAG"]
csv_file = os.environ["CSV_FILE"]
max_lines = int(os.environ.get("MAX_CSV_LINES", "500"))

now = get_now()
now_ts = int(now.timestamp())

data, err = read_rate_file(rate_file)
five = (data or {}).get("five_hour", {})
seven = (data or {}).get("seven_day", {})
seven_used = normalize_pct(seven.get("used_percentage", ""))

limit_reset_at, limit_hit_at, _ = parse_limit_flag(limit_flag)
limit_active = bool(limit_reset_at and now_ts < limit_reset_at)

if limit_active:
    resets_at = int(limit_reset_at)
    raw_used = normalize_pct(five.get("used_percentage", ""))
    effective_used = 100
    progress_source = "limit_carry"
elif data is None:
    print(f"[{sample_type}] skip: {err}", file=sys.stderr)
    sys.exit(0)
else:
    resets_at = int(five.get("resets_at", 0) or 0)
    if resets_at < now_ts:
        print(f"[{sample_type}] skip: stale data (resets_at={resets_at} < now={now_ts})")
        sys.exit(0)
    raw_used = normalize_pct(five.get("used_percentage", ""))
    effective_used = raw_used if raw_used != "" else 0
    progress_source = "raw"

minutes_to_reset = max(0, int(round((resets_at - now_ts) / 60)))
window_elapsed_min = max(0, int(round((300 * 60 - max(0, resets_at - now_ts)) / 60)))

row = {
    "timestamp": now_ts,
    "datetime": now.strftime("%Y-%m-%d %H:%M:%S"),
    "dow": now.weekday(),
    "hour": now.hour,
    "type": sample_type,
    "sample_slot": infer_sample_slot(sample_type, minutes_to_reset),
    "5h_used_pct": effective_used,
    "5h_resets_at": resets_at,
    "7d_used_pct": seven_used,
    "raw_5h_used_pct": raw_used,
    "effective_5h_used_pct": effective_used,
    "minutes_to_reset": minutes_to_reset,
    "window_elapsed_min": window_elapsed_min,
    "progress_source": progress_source,
    "limit_hit_at": limit_hit_at or "",
}

append_row(csv_file, row, max_lines=max_lines)

print(
    f"[{sample_type}] {row['datetime']} "
    f"slot={row['sample_slot']} 5h={row['5h_used_pct']}% "
    f"source={progress_source}"
)
EOF
