#!/bin/bash
set -euo pipefail
set +m

JOBS_ROOT="${JOBS_ROOT:-$HOME/jobs}"
TOOLS_BIN_DIR="${TOOLS_BIN_DIR:-}"

export PATH="${TOOLS_BIN_DIR:+$TOOLS_BIN_DIR:}$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export PYTHONPATH="$JOBS_ROOT/bin/lib${PYTHONPATH:+:$PYTHONPATH}"

# shellcheck source=/dev/null
source "$JOBS_ROOT/bin/lib/candy_time.sh"

SNAPSHOT_CSV="${SNAPSHOT_CSV:-$JOBS_ROOT/logs/usage_snapshots.csv}"
CHANGE_LOG="$JOBS_ROOT/logs/schedule_changes.log"
PLIST_SRC="$JOBS_ROOT/LaunchAgents/com.claude.candy.plist"
PLIST_SYS_DIR="${PLIST_SYS_DIR:-$HOME/Library/LaunchAgents}"
PLIST_SYS="$PLIST_SYS_DIR/com.claude.candy.plist"
SNAP_PLIST_SRC="$JOBS_ROOT/LaunchAgents/com.claude.candy.snapshot.plist"
SNAP_PLIST_SYS="$PLIST_SYS_DIR/com.claude.candy.snapshot.plist"
PROGRESS_PLIST_SRC="$JOBS_ROOT/LaunchAgents/com.claude.candy.progress.plist"
PROGRESS_PLIST_SYS="$PLIST_SYS_DIR/com.claude.candy.progress.plist"
LUNCH_CONF="$JOBS_ROOT/config/lunch_schedule.conf"
PHASE_FILE="$JOBS_ROOT/config/.optimizer_phase"

MIN_SNAPSHOTS=${MIN_SNAPSHOTS:-4}
MAX_HOUR_SHIFT=${MAX_HOUR_SHIFT:-2}

mkdir -p "$(dirname "$CHANGE_LOG")" "$(dirname "$PHASE_FILE")"

log_change() { echo "[$(runtime_now_fmt '%Y-%m-%d %H:%M:%S')] $*" >> "$CHANGE_LOG"; }

# symlink이면 src=sys이므로 복사 불필요
safe_copy_plist() {
    local src="$1" dst="$2"
    [ -L "$dst" ] || cp "$src" "$dst"
}

validate_schedule_plist() {
    local path="$1"
    PLIST_PATH="$path" python3 << 'PYEOF'
import os, plistlib, sys

path = os.environ["PLIST_PATH"]

try:
    with open(path, "rb") as f:
        data = plistlib.load(f)
except Exception:
    sys.exit(1)

if not isinstance(data, dict):
    sys.exit(1)

if not data.get("Label"):
    sys.exit(1)

program_args = data.get("ProgramArguments")
intervals = data.get("StartCalendarInterval")

if not isinstance(program_args, list) or len(program_args) < 3:
    sys.exit(1)

if not isinstance(intervals, list) or len(intervals) == 0:
    sys.exit(1)

for item in intervals:
    if not isinstance(item, dict):
        sys.exit(1)
    hour = item.get("Hour")
    minute = item.get("Minute")
    if not isinstance(hour, int) or not isinstance(minute, int):
        sys.exit(1)
    if not (0 <= hour <= 23 and 0 <= minute <= 59):
        sys.exit(1)
PYEOF
}

get_schedule_pairs_from_plist() {
    local path="$1"
    PLIST_PATH="$path" python3 << 'PYEOF'
import os, plistlib

with open(os.environ["PLIST_PATH"], "rb") as f:
    data = plistlib.load(f)

for item in sorted(
    data["StartCalendarInterval"],
    key=lambda entry: (entry.get("Hour", 0), entry.get("Minute", 0)),
):
    print(f"{item['Hour']} {item['Minute']}")
PYEOF
}

derive_candy_schedule_from_snapshot() {
    local path="$1"
    PLIST_PATH="$path" python3 << 'PYEOF'
import os, plistlib

with open(os.environ["PLIST_PATH"], "rb") as f:
    data = plistlib.load(f)

for item in sorted(
    data["StartCalendarInterval"],
    key=lambda entry: (entry.get("Hour", 0), entry.get("Minute", 0)),
):
    minute = item["Minute"]
    delta = (1 - minute) % 60
    if delta not in (2, 3):
        delta = 3
    total = item["Hour"] * 60 + minute + delta
    hour = (total // 60) % 24
    minute = total % 60
    print(f"{hour} {minute}")
PYEOF
}

derive_progress_schedule() {
    if [ "$#" -eq 0 ] || [ $(( $# % 2 )) -ne 0 ]; then
        return 1
    fi

    PROGRESS_PAIRS="$*" python3 << 'PYEOF'
import os

raw = [int(x) for x in os.environ["PROGRESS_PAIRS"].split()]
pairs = [(raw[i], raw[i + 1]) for i in range(0, len(raw), 2)]
results = []

for hour, minute in pairs:
    start_total = hour * 60 + minute
    for delta in (59, 119, 179, 239):
        total = (start_total + delta) % 1440
        results.append((total // 60, total % 60))

for hour, minute in sorted(set(results)):
    print(f"{hour} {minute}")
PYEOF
}

backup_valid_plist() {
    local path="$1"
    if ! validate_schedule_plist "$path"; then
        return 1
    fi

    local backup_dir backup_path
    backup_dir="$JOBS_ROOT/backups"
    mkdir -p "$backup_dir"
    backup_path=$(mktemp "$backup_dir/$(basename "$path").XXXXXX")
    cp "$path" "$backup_path"
    printf '%s\n' "$backup_path"
}

restore_plist_backup() {
    local backup_path="$1" dest="$2"
    [ -n "$backup_path" ] || return 1
    [ -f "$backup_path" ] || return 1
    cp "$backup_path" "$dest"
}

write_generated_plist() {
    local dest="$1" label="$2" program="$3" offset="$4"
    shift 4

    local tmp_path
    tmp_path=$(mktemp "$(dirname "$dest")/.$(basename "$dest").tmp.XXXXXX")

    if ! generate_plist_xml "$label" "$program" "$offset" "$@" > "$tmp_path"; then
        rm -f "$tmp_path"
        return 1
    fi

    if ! validate_schedule_plist "$tmp_path"; then
        rm -f "$tmp_path"
        return 1
    fi

    mv "$tmp_path" "$dest"
}

reload_agent() {
    local label="$1" plist="$2"
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$plist"
}

# 통합 plist 생성기: generate_plist_xml <label> <program> <offset_min> <h1 m1 h2 m2 ...>
generate_plist_xml() {
    local label="$1" program="$2" offset="$3"
    shift 3

    if [ "$#" -eq 0 ] || [ $(( $# % 2 )) -ne 0 ]; then
        return 1
    fi

    local intervals=""
    while [ $# -gt 0 ]; do
        local h=$1 m=$2
        shift 2
        if [ "$offset" -ne 0 ]; then
            local total_min=$(( h * 60 + m + offset ))
            [ "$total_min" -lt 0 ] && total_min=$(( total_min + 1440 ))
            h=$(( total_min / 60 % 24 ))
            m=$(( total_min % 60 ))
        fi
        intervals+="        <dict><key>Hour</key><integer>${h}</integer><key>Minute</key><integer>${m}</integer></dict>\n"
    done

    cat << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>-c</string>
        <string>exec "\${JOBS_ROOT:-\$HOME/jobs}/bin/${program}"</string>
    </array>
    <key>StartCalendarInterval</key>
    <array>
$(printf "$intervals")    </array>
</dict>
</plist>
PLIST_EOF
}

# offset_weeks=0: 이번주, offset_weeks=1: 다음주
_get_lunch() {
    local offset_weeks="${1:-0}"
    LUNCH_CONF="$LUNCH_CONF" OFFSET_WEEKS="$offset_weeks" python3 << 'PYEOF'
import datetime, os
from candy_time import get_today

cfg = {}
with open(os.environ["LUNCH_CONF"]) as f:
    for line in f:
        line = line.strip()
        if line and not line.startswith('#') and '=' in line:
            k, v = line.split('=', 1)
            cfg[k.strip()] = v.strip().strip('"')
anchor  = datetime.date.fromisoformat(cfg['CYCLE_ANCHOR'])
pattern = cfg['CYCLE_PATTERN'].split(',')
today = get_today()
offset  = int(os.environ["OFFSET_WEEKS"])
ref_monday  = today - datetime.timedelta(days=today.weekday()) + datetime.timedelta(weeks=offset)
anchor_monday = anchor - datetime.timedelta(days=anchor.weekday())
weeks_diff = (ref_monday - anchor_monday).days // 7
print(pattern[weeks_diff % len(pattern)])
PYEOF
}

get_lunch()           { _get_lunch 0; }
get_next_week_lunch() { _get_lunch 1; }

get_historical_summary() {
    local hist_monday="$1" hist_friday="$2"
    HIST_MONDAY="$hist_monday" HIST_FRIDAY="$hist_friday" SNAPSHOT_CSV="$SNAPSHOT_CSV" python3 << 'PYEOF'
import csv, os, datetime
from collections import defaultdict

csv_file  = os.environ["SNAPSHOT_CSV"]
hist_start = os.environ["HIST_MONDAY"]
hist_end   = os.environ["HIST_FRIDAY"]

try:
    with open(csv_file) as f:
        rows = list(csv.DictReader(f))
except FileNotFoundError:
    exit(0)

rows = [r for r in rows
        if r.get('type') == 'snapshot'
        and hist_start <= r['datetime'][:10] <= hist_end]

if not rows:
    exit(0)

window_usage = defaultdict(list)
for r in rows:
    try:
        used = int(float(r.get('effective_5h_used_pct') or r['5h_used_pct']))
        resets_at = int(float(r['5h_resets_at']))
    except (ValueError, KeyError):
        continue
    ws_dt  = datetime.datetime.fromtimestamp(resets_at - 18000 + 60)
    we_dt  = datetime.datetime.fromtimestamp(resets_at)
    label  = f"{ws_dt.strftime('%H:%M')}-{we_dt.strftime('%H:%M')}"
    window_usage[label].append(used)

print(f"{hist_start} ~ {hist_end} (n={len(rows)})")
for label in sorted(window_usage.keys()):
    pcts = window_usage[label]
    avg  = sum(pcts) / len(pcts)
    print(f"윈도우 {label}: {avg:.0f}% (n={len(pcts)})")
PYEOF
}

get_current_schedule() {
    if validate_schedule_plist "$PLIST_SRC"; then
        get_schedule_pairs_from_plist "$PLIST_SRC"
        return 0
    fi

    if validate_schedule_plist "$SNAP_PLIST_SRC"; then
        log_change "WARN: candy plist invalid. snapshot plist 기준으로 candy 스케줄 복원값 사용."
        derive_candy_schedule_from_snapshot "$SNAP_PLIST_SRC"
        return 0
    fi

    return 1
}

get_usage_summary() {
    export SNAPSHOT_CSV
    python3 << 'PYEOF'
import csv, os, datetime
from collections import defaultdict
from candy_time import get_today, format_ts

csv_file = os.environ["SNAPSHOT_CSV"]
try:
    with open(csv_file) as f:
        rows = list(csv.DictReader(f))
except FileNotFoundError:
    print("데이터 없음")
    exit(0)

if not rows:
    print("데이터 없음")
    exit(0)

rows = [r for r in rows if r.get('type') in ('progress', 'snapshot')]

# 오늘이 월요일(0)이면 금요일, 아니면 어제 데이터만 사용
today = get_today()
if today.weekday() == 0:  # 월요일
    target = today - datetime.timedelta(days=3)  # 금요일
else:
    target = today - datetime.timedelta(days=1)  # 어제

recent = [r for r in rows if r['datetime'].startswith(str(target))]

if not recent:
    print(f"데이터 없음 (대상 날짜: {target})")
    exit(0)

snapshot_rows = [r for r in recent if r.get('type') == 'snapshot']
progress_rows = [r for r in recent if r.get('type') == 'progress']

print(f"대상 날짜: {target}, final snapshot {len(snapshot_rows)}개, progress {len(progress_rows)}개")

slot_order = ["1h", "2h", "3h", "4h", "final"]
window_usage = defaultdict(lambda: {
    "snapshot": [],
    "flows": defaultdict(list),
    "limit_slots": defaultdict(bool),
    "limit_hits": [],
})

for r in recent:
    try:
        resets_at = int(float(r['5h_resets_at']))
    except (ValueError, KeyError):
        continue

    used_raw = r.get('effective_5h_used_pct') or r.get('5h_used_pct') or r.get('raw_5h_used_pct')
    try:
        used = int(float(used_raw))
    except (TypeError, ValueError):
        continue

    ws_dt = datetime.datetime.fromtimestamp(resets_at - 18000 + 60)
    we_dt = datetime.datetime.fromtimestamp(resets_at)
    label = f"{ws_dt.strftime('%H:%M')}-{we_dt.strftime('%H:%M')}"
    slot = r.get('sample_slot') or ('final' if r.get('type') == 'snapshot' else '')
    source = r.get('progress_source', '')
    limit_hit_at = r.get('limit_hit_at', '')

    if r.get('type') == 'snapshot':
        window_usage[label]["snapshot"].append(used)

    if slot:
        window_usage[label]["flows"][slot].append(used)
        if source == 'limit_carry':
            window_usage[label]["limit_slots"][slot] = True

    if limit_hit_at:
        try:
            window_usage[label]["limit_hits"].append(int(float(limit_hit_at)))
        except ValueError:
            pass

for label in sorted(window_usage.keys()):
    data = window_usage[label]
    snapshot_pcts = data["snapshot"]
    final_avg = sum(snapshot_pcts) / len(snapshot_pcts) if snapshot_pcts else None
    if final_avg is None:
        print(f"윈도우 {label}: 최종값 없음")
    else:
        print(f"윈도우 {label}: 최종 {final_avg:.0f}% (n={len(snapshot_pcts)})")

    flow_parts = []
    threshold_80 = None
    threshold_90 = None
    for slot in slot_order:
        values = data["flows"].get(slot, [])
        if not values:
            continue
        avg = sum(values) / len(values)
        suffix = "(limit carry)" if data["limit_slots"].get(slot) else ""
        flow_parts.append(f"{slot}={avg:.0f}%{suffix}")
        if threshold_80 is None and avg >= 80:
            threshold_80 = slot
        if threshold_90 is None and avg >= 90:
            threshold_90 = slot

    if flow_parts:
        print("흐름: " + ", ".join(flow_parts))

    metrics = []
    if threshold_80:
        metrics.append(f"80% 도달={threshold_80}")
    if threshold_90:
        metrics.append(f"90% 도달={threshold_90}")

    if data["limit_hits"]:
        metrics.append(f"limit={format_ts(min(data['limit_hits']), '%H:%M')}")
    elif any(data["limit_slots"].values()):
        metrics.append("limit carry 있음")
    else:
        metrics.append("limit carry 없음")

    print("지표: " + ", ".join(metrics))
PYEOF
}

# phase 읽기+쓰기 통합. 인자 없으면 읽기만, 인자 있으면 shift_minutes로 업데이트
manage_phase() {
    local shift_minutes="${1:-}"
    export PHASE_FILE
    SHIFT_MINUTES="$shift_minutes" python3 << 'PYEOF'
import json, os

pf = os.environ["PHASE_FILE"]
shift = os.environ.get("SHIFT_MINUTES", "")

data = {}
if os.path.exists(pf):
    with open(pf) as f:
        data = json.load(f)

phase = data.get("phase", 1)
stable_days = data.get("stable_days", 0)

if shift:
    shift_min = int(shift)
    stable_days = stable_days + 1 if shift_min <= 30 else 0
    if phase == 1 and stable_days >= 7:
        phase = 2
    data = {"phase": phase, "stable_days": stable_days, "last_shift_min": shift_min}
    with open(pf, 'w') as f:
        json.dump(data, f)

print(f"{phase}")
PYEOF
}

ask_claude_for_schedule() {
    local lunch="$1"
    local current_schedule="$2"
    local usage_summary="$3"
    local hist="${4:-}"
    local lunch_label="${5:-이번주 점심 시간}"

    local hist_section=""
    if [ -n "$hist" ]; then
        hist_section="## 3주 전 동일 점심 패턴 실적
${hist}
(다음주와 동일한 점심 시간대가 적용됐던 주의 실적)
"
    fi

    local prompt
    prompt=$(cat << PROMPT_EOF
너는 Claude Code 5시간 윈도우 스케줄 최적화 전문가야.

## 시스템 동작 원리
- Claude Code는 5시간 고정 윈도우로 토큰 한도를 관리함
- 윈도우가 시작되면 5시간 동안 변경 불가. 한도 소진 시 윈도우 만료까지 대기
- candy(=launchd refresh)가 실행되면 새 5시간 윈도우가 시작됨
- final snapshot은 윈도우 리셋 2분 전에 찍힘 → "해당 윈도우의 최종 누적 사용률"
- progress는 윈도우 1h/2h/3h/4h 지점의 누적 사용률 흐름을 보여줌

## 데이터 읽는 법
- "윈도우 10:01-15:00: 최종 91%" = 그 윈도우가 만료 직전에 91% 소진됨
- "흐름: 1h=18%, 2h=47%, 3h=68%, 4h=100%(limit carry), final=100%(limit carry)" = 같은 윈도우의 누적 진행률
- 높은 최종 % = 해당 윈도우의 토큰이 부족했을 가능성. 빠른 흐름 상승 = 일찍 포화됐을 가능성
- limit carry가 붙으면 그 시점 이후는 사실상 이미 한도 소진 상태였다고 봐라

## 사용자 프로필
- 매일 09:00 출근, Claude Code 세션 시작
- 오전보다 오후에 사용량이 많음
- 점심시간에는 전혀 사용하지 않음

## ${lunch_label}
${lunch}

## 현재 candy 스케줄
${current_schedule}
(각 시각에 새 5시간 윈도우 시작)

## 윈도우별 사용률 데이터
${usage_summary}

${hist_section}## Claude 윈도우 리셋 정책 (매우 중요)
Claude의 5시간 윈도우는 **시(Hour) 단위**로 리셋된다.
- 08:01에 실행해도 resetsAt = 13:00
- 08:30에 실행해도 resetsAt = 13:00 (동일!)
- 즉, 같은 시간대 안에서 분(Minute)을 바꿔도 resetsAt은 변하지 않음
- 따라서 candy 실행 시각의 **분(MM)은 최적화 대상이 아니다**
- 항상 MM=1 고정 (정시 직후 1분 → 안정적 실행 보장, 토큰 낭비 최소화)

## 최적화 원칙
1. 토큰 효율: 점심(비사용 시간)이 윈도우 안에 포함되면 실질 사용 가능 시간당 토큰 밀도가 올라감
2. 오후 보호: 오후에 사용량이 많으므로, 점심 끝 무렵에 새 윈도우가 시작되어 오후에 풀 토큰 확보
3. pre-warm: 출근 전 자동으로 candy를 실행해 윈도우 시작 시점을 조절할 수 있음
4. pre-warm 공식: 점심 끝 시각 - 5시간 = pre-warm 시각 (이러면 첫 윈도우가 점심 끝에 만료)
5. 데이터 기반: 윈도우 사용률이 80% 이상이면 해당 시간대에 토큰이 부족했다는 신호
6. 하루 4회 실행: 첫 번째=pre-warm, 나머지 3개=이후 5시간 간격으로 배치
7. HH만 최적화: MM은 항상 1 고정. HH만 최적 값을 판단해라

## 출력 형식
반드시 아래 JSON 객체만 출력하고 다른 텍스트는 일절 쓰지 마라.
{"times": [[HH, 1], [HH, 1], [HH, 1], [HH, 1]], "reason": "한국어 2-3줄"}

times: 정확히 4개, HH=0-23 정수, MM=1 고정. 시간순 정렬. 첫 번째가 pre-warm.
PROMPT_EOF
)

    # JSON 파싱 파이썬 스크립트 (공통 사용)
    local parse_script
    parse_script=$(cat << 'PYEOF'
import sys, json, re

def extract_schedule_json(text):
    """중괄호 depth 추적으로 첫 번째 유효한 JSON 객체를 추출."""
    i = 0
    while i < len(text):
        if text[i] != '{':
            i += 1
            continue
        depth = 0
        in_str = False
        escape = False
        for j in range(i, len(text)):
            c = text[j]
            if escape:
                escape = False
                continue
            if c == '\\' and in_str:
                escape = True
                continue
            if c == '"':
                in_str = not in_str
                continue
            if not in_str:
                if c == '{':
                    depth += 1
                elif c == '}':
                    depth -= 1
                    if depth == 0:
                        candidate = text[i:j+1]
                        try:
                            obj = json.loads(candidate)
                            if isinstance(obj, dict) and 'times' in obj:
                                return obj
                        except Exception:
                            pass
                        break
        i += 1
    return None

raw = sys.stdin.read()

# NDJSON 파싱: 먼저 result 타입 항목에서 텍스트 추출
result_text = ''
try:
    items = json.loads(raw)
    if not isinstance(items, list):
        items = [items]
    for item in items:
        if item.get('type') == 'result':
            result_text = item.get('result', '')
            break
except Exception:
    for line in raw.strip().split('\n'):
        try:
            item = json.loads(line)
            if item.get('type') == 'result':
                result_text = item.get('result', '')
                break
        except Exception:
            pass

# result_text에서 JSON 추출 (코드 펜스 제거 후)
if result_text:
    clean = re.sub(r'```json\s*', '', result_text)
    clean = re.sub(r'```\s*', '', clean)
    obj = extract_schedule_json(clean)
    if obj:
        print(json.dumps(obj))
        sys.exit(0)

# fallback: raw 전체에서 직접 추출
obj = extract_schedule_json(raw)
if obj:
    print(json.dumps(obj))
    sys.exit(0)

sys.exit(1)
PYEOF
)

    local attempt result raw_out
    for attempt in 1 2 3; do
        raw_out=$(claude -p --model haiku --output-format json "$prompt" 2>&1) || true

        if [ -n "${CLAUDE_RAW_DEBUG_DIR:-}" ]; then
            mkdir -p "$CLAUDE_RAW_DEBUG_DIR"
            printf '%s' "$raw_out" > "$CLAUDE_RAW_DEBUG_DIR/attempt_${attempt}.json"
        fi

        if [ -z "$raw_out" ]; then
            log_change "WARN: Claude 빈 응답 (attempt $attempt/3)"
            [ "$attempt" -lt 3 ] && sleep 10
            continue
        fi

        result=$(printf '%s' "$raw_out" | python3 -c "$parse_script" 2>/dev/null) || true

        if [ -n "$result" ]; then
            printf '%s' "$result"
            return 0
        fi

        # 파싱 실패 시 raw 출력 앞 300자 로깅 (진단용)
        local preview
        preview=$(printf '%s' "$raw_out" | head -c 300 | tr '\n' ' ')
        log_change "WARN: JSON 파싱 실패 (attempt $attempt/3). Raw: $preview"
        [ "$attempt" -lt 3 ] && sleep 10
    done
}

# Claude 응답 검증 + 변경폭 클리핑. env로 데이터 전달 (셸 인젝션 방지)
validate_and_clip() {
    local claude_json="$1"
    shift
    local old_times=("$@")  # h1 m1 h2 m2 ...

    export CLAUDE_JSON="$claude_json"
    export OLD_TIMES="${old_times[*]}"
    export MAX_HOUR_SHIFT

    python3 << 'PYEOF'
import json, os, sys

data = json.loads(os.environ["CLAUDE_JSON"])
times = data.get("times", [])
reason = data.get("reason", "")

if len(times) != 4:
    print("ERROR:슬롯 수 불일치", file=sys.stderr)
    sys.exit(1)

for h, m in times:
    if not (0 <= h <= 23) or m != 1:
        print(f"ERROR:허용 범위 외 시각 {h}:{m} (MM은 반드시 1이어야 함)", file=sys.stderr)
        sys.exit(1)

old_raw = os.environ["OLD_TIMES"].split()
old_pairs = [(int(old_raw[i]), int(old_raw[i+1])) for i in range(0, len(old_raw), 2)]
max_allowed = int(os.environ["MAX_HOUR_SHIFT"]) * 60

max_shift = 0
clipped = []
for i, (nh, nm) in enumerate(sorted(times)):
    if i < len(old_pairs):
        oh, om = old_pairs[i]
        old_min = oh * 60 + om
        new_min = nh * 60 + nm
        shift = abs(new_min - old_min)
        max_shift = max(max_shift, shift)
        diff = new_min - old_min
        if abs(diff) > max_allowed:
            new_min = old_min + (max_allowed if diff > 0 else -max_allowed)
            nh = new_min // 60
        nm = 1  # MM은 항상 1 고정 (Claude 윈도우는 시 단위로 리셋)
    clipped.append(f"{nh} {nm}")

print(" ".join(clipped))
print(reason)
print(max_shift)
PYEOF
}

main() {
    # 주말 체크: 토요일(6) = 일요일 스케줄 불필요, 일요일(7) = 월요일 스케줄은 금요일 데이터 없이 불가
    local dow
    dow=$(runtime_weekday_u)
    if [ "$dow" -ge 6 ]; then
        log_change "주말 스킵 (DOW=$dow, 월요일 스케줄은 금요일 optimizer가 담당)"
        return 0
    fi

    log_change "===== OPTIMIZER RUN START ====="

    # 월요일이면 금요일, 아니면 어제 날짜
    local target_date
    if [ "$dow" = "1" ]; then
        target_date=$(runtime_shifted_date -3 '%Y-%m-%d')
    else
        target_date=$(runtime_shifted_date -1 '%Y-%m-%d')
    fi

    local snap_count=0
    if [ -f "$SNAPSHOT_CSV" ]; then
        snap_count=$(awk -F',' -v d="$target_date" 'NR>1 && $5=="snapshot" && $2~d' "$SNAPSHOT_CSV" | wc -l | tr -d ' ')
    fi
    log_change "final snapshot: ${snap_count}개 (대상: $target_date, 최소 $MIN_SNAPSHOTS)"

    if [ "$snap_count" -lt "$MIN_SNAPSHOTS" ]; then
        log_change "SKIP - 데이터 부족 ($snap_count/$MIN_SNAPSHOTS)"
        osascript -e "display notification \"데이터 수집 중 ($snap_count/$MIN_SNAPSHOTS)\" with title \"Claude Candy\" subtitle \"스케줄 변경 없음\"" 2>/dev/null || true
        return 0
    fi

    local phase
    phase=$(manage_phase)
    log_change "Phase: $phase (1=매일, 2=주간)"

    local lunch lunch_label hist=""
    if [ "$dow" = "5" ]; then
        lunch=$(get_next_week_lunch)
        lunch_label="다음주 점심 시간 (월요일부터 적용)"
        local hist_monday hist_friday
        read -r hist_monday hist_friday < <(python3 -c "
import datetime
from candy_time import get_today
today = get_today()
next_monday = today - datetime.timedelta(days=today.weekday()) + datetime.timedelta(weeks=1)
hist_monday = next_monday - datetime.timedelta(weeks=3)
print(hist_monday.isoformat(), (hist_monday + datetime.timedelta(days=4)).isoformat())
")
        hist=$(get_historical_summary "$hist_monday" "$hist_friday")
        if [ -n "$hist" ]; then
            log_change "금요일: 다음주 점심($lunch) 기준, 3주 전 히스토리 있음 ($hist_monday ~ $hist_friday)"
        else
            log_change "금요일: 다음주 점심($lunch) 기준, 3주 전 히스토리 없음"
        fi
    else
        lunch=$(get_lunch)
        lunch_label="이번주 점심 시간"
    fi

    local current_times_raw usage_summary
    current_times_raw=$(get_current_schedule) || {
        log_change "ERROR: 현재 candy/snapshot plist를 해석할 수 없음. 변경 중단."
        return 1
    }
    usage_summary=$(get_usage_summary)

    # current_times_raw: "H M\nH M\n..." → 배열과 표시 문자열
    local old_times_arr=()
    local current_schedule_str=""
    while IFS=' ' read -r h m; do
        old_times_arr+=("$h" "$m")
        [ -n "$current_schedule_str" ] && current_schedule_str+=", "
        current_schedule_str+="$(printf '%02d:%02d' "$h" "$m")"
    done <<< "$current_times_raw"

    log_change "점심: $lunch / 현재: $current_schedule_str"

    log_change "Claude 분석 요청 중..."
    local claude_result
    claude_result=$(ask_claude_for_schedule "$lunch" "$current_schedule_str" "$usage_summary" "$hist" "$lunch_label")

    if [ -z "$claude_result" ]; then
        log_change "ERROR: Claude 응답 파싱 실패. 현재 스케줄 유지."
        osascript -e "display notification \"Claude 분석 실패\" with title \"Claude Candy\" subtitle \"스케줄 변경 없음\"" 2>/dev/null || true
        return 1
    fi
    local claude_decoded
    claude_decoded=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(json.dumps(d, ensure_ascii=False))" "$claude_result" 2>/dev/null) || claude_decoded="$claude_result"
    log_change "Claude 응답: $claude_decoded"

    local validated
    validated=$(validate_and_clip "$claude_result" "${old_times_arr[@]}") || {
        log_change "ERROR: 검증 실패. 현재 스케줄 유지."
        return 1
    }

    local new_times new_reason max_shift_min
    new_times=$(echo "$validated" | sed -n '1p')
    new_reason=$(echo "$validated" | sed -n '2p')
    max_shift_min=$(echo "$validated" | sed -n '3p')

    log_change "적용 시각: $new_times"
    log_change "판단 근거: $new_reason"
    log_change "최대 변경폭: ${max_shift_min}분"

    local new_schedule_str
    new_schedule_str=$(NEW_TIMES="$new_times" python3 -c "
import os
ts = os.environ['NEW_TIMES'].split()
pairs = [(int(ts[i]), int(ts[i+1])) for i in range(0, len(ts), 2)]
print(', '.join(f'{h:02d}:{m:02d}' for h, m in pairs))
")

    if [ "$current_schedule_str" = "$new_schedule_str" ]; then
        log_change "변경 없음 (현재와 동일): $current_schedule_str"
        manage_phase 0 >/dev/null
        return 0
    fi

    local candy_backup="" snap_backup="" progress_backup=""
    candy_backup=$(backup_valid_plist "$PLIST_SRC" 2>/dev/null || true)
    snap_backup=$(backup_valid_plist "$SNAP_PLIST_SRC" 2>/dev/null || true)
    progress_backup=$(backup_valid_plist "$PROGRESS_PLIST_SRC" 2>/dev/null || true)

    # candy plist 생성 + 검증
    if ! write_generated_plist "$PLIST_SRC" "com.claude.candy" "refresh_claude.sh" 0 $new_times; then
        log_change "ERROR: candy plist 검증 실패. 변경 중단."
        return 1
    fi
    safe_copy_plist "$PLIST_SRC" "$PLIST_SYS"

    local progress_raw progress_args=()
    progress_raw=$(derive_progress_schedule $new_times) || {
        log_change "WARN: progress 스케줄 계산 실패. progress는 변경하지 않음."
        progress_raw=""
    }
    if [ -n "$progress_raw" ]; then
        while IFS=' ' read -r h m; do
            progress_args+=("$h" "$m")
        done <<< "$progress_raw"
    fi

    if [ "${#progress_args[@]}" -gt 0 ]; then
        if ! write_generated_plist "$PROGRESS_PLIST_SRC" "com.claude.candy.progress" "usage_progress.sh" 0 "${progress_args[@]}"; then
            log_change "WARN: progress plist 검증 실패. progress는 변경하지 않음."
        else
            safe_copy_plist "$PROGRESS_PLIST_SRC" "$PROGRESS_PLIST_SYS"
            if ! reload_agent "com.claude.candy.progress" "$PROGRESS_PLIST_SYS" 2>/dev/null; then
                if restore_plist_backup "$progress_backup" "$PROGRESS_PLIST_SRC"; then
                    safe_copy_plist "$PROGRESS_PLIST_SRC" "$PROGRESS_PLIST_SYS"
                    reload_agent "com.claude.candy.progress" "$PROGRESS_PLIST_SYS" 2>/dev/null || true
                    log_change "WARN: progress 재로드 실패. 유효 백업으로 롤백."
                else
                    log_change "WARN: progress 재로드 실패. 백업이 없어 새 파일만 유지."
                fi
            else
                log_change "progress 스케줄 업데이트 완료 (1h/2h/3h/4h)"
            fi
        fi
    fi

    # snapshot plist 생성 (-3분 offset) + 검증
    # candy :01 → final snapshot을 리셋 2분 전(XX:58)에 두려면 candy 기준 -3분이 필요함
    if ! write_generated_plist "$SNAP_PLIST_SRC" "com.claude.candy.snapshot" "usage_snapshot.sh" -3 $new_times; then
        log_change "WARN: snapshot plist 검증 실패. snapshot은 변경하지 않음."
    else
        safe_copy_plist "$SNAP_PLIST_SRC" "$SNAP_PLIST_SYS"
        if ! reload_agent "com.claude.candy.snapshot" "$SNAP_PLIST_SYS" 2>/dev/null; then
            if restore_plist_backup "$snap_backup" "$SNAP_PLIST_SRC"; then
                safe_copy_plist "$SNAP_PLIST_SRC" "$SNAP_PLIST_SYS"
                reload_agent "com.claude.candy.snapshot" "$SNAP_PLIST_SYS" 2>/dev/null || true
                log_change "WARN: snapshot 재로드 실패. 유효 백업으로 롤백."
            else
                log_change "WARN: snapshot 재로드 실패. 백업이 없어 새 파일만 유지."
            fi
        else
            log_change "snapshot 스케줄 업데이트 완료 (window reset -2분 / candy -3분)"
        fi
    fi

    # candy launchctl 재로드
    if ! reload_agent "com.claude.candy" "$PLIST_SYS" 2>/dev/null; then
        if restore_plist_backup "$candy_backup" "$PLIST_SRC"; then
            safe_copy_plist "$PLIST_SRC" "$PLIST_SYS"
            reload_agent "com.claude.candy" "$PLIST_SYS" 2>/dev/null || true
            log_change "ERROR: candy launchctl 재로드 실패. 유효 백업으로 롤백."
            osascript -e "display notification \"launchctl 재로드 실패 → 이전 유효 설정으로 롤백\" with title \"Claude Candy\"" 2>/dev/null || true
            return 1
        fi

        log_change "WARN: candy launchctl 재로드 실패. 백업이 없어 새 plist만 유지 (다음 로그인 시 반영 가능)."
        osascript -e "display notification \"launchctl 재로드 실패 (새 plist 유지)\" with title \"Claude Candy\"" 2>/dev/null || true
    fi

    manage_phase "${max_shift_min:-0}" >/dev/null

    log_change "이전: $current_schedule_str"
    log_change "변경: $new_schedule_str"
    log_change "STATUS: SUCCESS"
    log_change "============================="

    osascript -e "display notification \"$current_schedule_str → $new_schedule_str\" with title \"Claude Candy\" subtitle \"스케줄 최적화 완료\"" 2>/dev/null || true
}

main "$@"
