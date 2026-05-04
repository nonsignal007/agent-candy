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
LUNCH_CONF="$JOBS_ROOT/config/lunch_schedule.conf"
PHASE_FILE="$JOBS_ROOT/config/.optimizer_phase"
CANDY_MORNING_TS_FILE="${CANDY_MORNING_TS_FILE:-$JOBS_ROOT/config/.candy_morning_ts}"

MIN_SNAPSHOTS=${MIN_SNAPSHOTS:-3}
MAX_SHIFT_MIN=${MAX_SHIFT_MIN:-120}

mkdir -p "$(dirname "$CHANGE_LOG")" "$(dirname "$PHASE_FILE")" "$(dirname "$CANDY_MORNING_TS_FILE")"

log_change() { echo "[$(runtime_now_fmt '%Y-%m-%d %H:%M:%S')] $*" >> "$CHANGE_LOG"; }

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

def _window_date_str(row):
    try:
        return datetime.datetime.fromtimestamp(int(float(row['5h_resets_at'])) - 18000).strftime('%Y-%m-%d')
    except (ValueError, KeyError, OSError):
        return ''

rows = [r for r in rows
        if r.get('type') == 'snapshot'
        and hist_start <= _window_date_str(r) <= hist_end]

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

today = get_today()
if today.weekday() == 0:
    target = today - datetime.timedelta(days=3)
else:
    target = today - datetime.timedelta(days=1)

def _window_date(row):
    try:
        return datetime.datetime.fromtimestamp(int(float(row['5h_resets_at'])) - 18000).date()
    except (ValueError, KeyError, OSError):
        return None

recent = [r for r in rows if _window_date(r) == target]

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

# phase 읽기+쓰기. 인자 없으면 읽기만, 인자 있으면 shift_minutes로 업데이트
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

# 현재 morning pre-warm 시각 읽기 (HH:MM 문자열 반환)
get_current_morning_str() {
    CANDY_MORNING_TS_FILE="$CANDY_MORNING_TS_FILE" python3 << 'PYEOF'
import os, datetime

path = os.environ.get("CANDY_MORNING_TS_FILE", "")
try:
    with open(path) as f:
        ts = int(f.read().strip())
    dt = datetime.datetime.fromtimestamp(ts)
    print(f"{dt.hour:02d}:{dt.minute:02d}")
except (FileNotFoundError, ValueError):
    print("미설정")
PYEOF
}

ask_claude_for_schedule() {
    local lunch="$1"
    local current_morning="$2"
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
- 윈도우 시작 시각이 정확히 분 단위로 기록됨 (예: 07:23 시작 → resets_at = 12:23)
- candy(=launchd refresh)가 실행되면 새 5시간 윈도우 시작
- 이후 윈도우는 resets_at에서 자동 체인됨: 첫 candy 시각만 최적화하면 됨
- final snapshot은 윈도우 리셋 3분 전에 찍힘 → "해당 윈도우의 최종 누적 사용률"
- progress는 윈도우 1h/2h/3h/4h 지점의 누적 사용률 흐름을 보여줌

## 데이터 읽는 법
- "윈도우 07:24-12:23: 최종 91%" = 그 윈도우가 만료 직전에 91% 소진됨
- "흐름: 1h=18%, 2h=47%, 3h=68%, 4h=100%(limit carry)" = 같은 윈도우의 누적 진행률
- 높은 최종 % = 해당 윈도우의 토큰이 부족했을 가능성
- limit carry가 붙으면 그 시점 이후는 사실상 이미 한도 소진 상태

## 사용자 프로필
- 매일 09:00 출근, Claude Code 세션 시작
- 오전보다 오후에 사용량이 많음
- 점심시간에는 전혀 사용하지 않음

## ${lunch_label}
${lunch}

## 현재 아침 pre-warm 시각
${current_morning}
(이 시각에 candy가 실행되어 5시간 윈도우가 시작됨)

## 윈도우별 사용률 데이터
${usage_summary}

${hist_section}## 최적화 원칙
1. 토큰 효율: 점심(비사용 시간)이 윈도우 안에 포함되면 실질 사용 가능 시간당 토큰 밀도 상승
2. 오후 보호: 점심 끝 무렵에 새 윈도우가 시작되어 오후에 풀 토큰 확보
3. pre-warm 공식: pre-warm = 점심 끝 시각 - 5시간 (분 단위 정확)
   - 예: 점심 13:00 종료 → pre-warm 08:00 (정확히!)
   - 예: 점심 12:45 종료 → pre-warm 07:45
4. 데이터 기반: 윈도우 사용률이 80% 이상이면 해당 시간대에 토큰이 부족했다는 신호
5. 분 단위로 HH:MM 자유롭게 최적화 가능 (더 이상 MM=01 고정 아님)

## 출력 형식
반드시 아래 JSON 객체만 출력하고 다른 텍스트는 일절 쓰지 마라.
{"time": [HH, MM], "reason": "한국어 2-3줄"}

time: 정확히 1개, HH=0-23 정수, MM=0-59 정수. 아침 pre-warm 시각.
PROMPT_EOF
)

    local parse_script
    parse_script=$(cat << 'PYEOF'
import sys, json, re

def extract_schedule_json(text):
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
                            if isinstance(obj, dict) and 'time' in obj:
                                return obj
                        except Exception:
                            pass
                        break
        i += 1
    return None

raw = sys.stdin.read()

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

if result_text:
    clean = re.sub(r'```json\s*', '', result_text)
    clean = re.sub(r'```\s*', '', clean)
    obj = extract_schedule_json(clean)
    if obj:
        print(json.dumps(obj))
        sys.exit(0)

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

        local preview
        preview=$(printf '%s' "$raw_out" | head -c 300 | tr '\n' ' ')
        log_change "WARN: JSON 파싱 실패 (attempt $attempt/3). Raw: $preview"
        [ "$attempt" -lt 3 ] && sleep 10
    done
}

# Claude 응답 검증 + 변경폭 클리핑 (1개 시각)
validate_and_clip() {
    local claude_json="$1"
    local old_morning_ts="$2"

    export CLAUDE_JSON="$claude_json"
    export OLD_MORNING_TS="$old_morning_ts"
    export MAX_SHIFT_MIN

    python3 << 'PYEOF'
import json, os, sys, datetime

data = json.loads(os.environ["CLAUDE_JSON"])
time_val = data.get("time", [])
reason = data.get("reason", "")

if not isinstance(time_val, list) or len(time_val) != 2:
    print("ERROR:time 형식 오류", file=sys.stderr)
    sys.exit(1)

nh, nm = int(time_val[0]), int(time_val[1])
if not (0 <= nh <= 23 and 0 <= nm <= 59):
    print(f"ERROR:허용 범위 외 시각 {nh}:{nm}", file=sys.stderr)
    sys.exit(1)

old_ts = int(os.environ.get("OLD_MORNING_TS", "0") or "0")
max_allowed = int(os.environ["MAX_SHIFT_MIN"])
shift = 0

if old_ts > 0:
    old_dt = datetime.datetime.fromtimestamp(old_ts)
    old_min = old_dt.hour * 60 + old_dt.minute
    new_min = nh * 60 + nm
    diff = new_min - old_min
    shift = abs(diff)
    if shift > max_allowed:
        new_min = old_min + (max_allowed if diff > 0 else -max_allowed)
        new_min = new_min % 1440
        nh = new_min // 60
        nm = new_min % 60
        shift = max_allowed

print(f"{nh} {nm}")
print(reason)
print(shift)
PYEOF
}

# 다음 적용 날짜의 HH:MM → epoch timestamp 계산
compute_morning_ts() {
    local h="$1" m="$2" dow="$3"
    H="$h" M="$m" DOW="$dow" python3 << 'PYEOF'
import datetime, os
from candy_time import get_today

today = get_today()
dow = int(os.environ["DOW"])
h = int(os.environ["H"])
m = int(os.environ["M"])

# 금요일(5)이면 다음 월요일, 아니면 내일
if dow == 5:
    days_ahead = 3  # 월요일
else:
    days_ahead = 1

next_date = today + datetime.timedelta(days=days_ahead)
dt = datetime.datetime.combine(next_date, datetime.time(h, m))
print(int(dt.timestamp()))
PYEOF
}

main() {
    local dow
    dow=$(runtime_weekday_u)
    if [ "$dow" -ge 6 ]; then
        log_change "주말 스킵 (DOW=$dow)"
        return 0
    fi

    log_change "===== OPTIMIZER RUN START ====="

    local target_date
    if [ "$dow" = "1" ]; then
        target_date=$(runtime_shifted_date -3 '%Y-%m-%d')
    else
        target_date=$(runtime_shifted_date -1 '%Y-%m-%d')
    fi

    local snap_count=0
    if [ -f "$SNAPSHOT_CSV" ]; then
        snap_count=$(TARGET_DATE="$target_date" SNAPSHOT_CSV="$SNAPSHOT_CSV" python3 << 'PYEOF'
import csv, datetime, os
target = os.environ["TARGET_DATE"]
count = 0
with open(os.environ["SNAPSHOT_CSV"]) as f:
    for row in csv.DictReader(f):
        if row.get('type') != 'snapshot':
            continue
        try:
            ws = datetime.datetime.fromtimestamp(int(float(row['5h_resets_at'])) - 18000)
        except (ValueError, KeyError, OSError):
            continue
        if ws.strftime('%Y-%m-%d') == target:
            count += 1
print(count)
PYEOF
        )
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
            log_change "금요일: 다음주 점심($lunch) 기준, 3주 전 히스토리 있음"
        else
            log_change "금요일: 다음주 점심($lunch) 기준, 3주 전 히스토리 없음"
        fi
    else
        lunch=$(get_lunch)
        lunch_label="이번주 점심 시간"
    fi

    local current_morning_str
    current_morning_str=$(get_current_morning_str)

    local current_morning_ts=0
    if [ -f "$CANDY_MORNING_TS_FILE" ]; then
        current_morning_ts=$(cat "$CANDY_MORNING_TS_FILE" 2>/dev/null || echo "0")
    fi

    local usage_summary
    usage_summary=$(get_usage_summary)

    log_change "점심: $lunch / 현재 morning: $current_morning_str"

    log_change "Claude 분석 요청 중..."
    local claude_result
    claude_result=$(ask_claude_for_schedule "$lunch" "$current_morning_str" "$usage_summary" "$hist" "$lunch_label")

    if [ -z "$claude_result" ]; then
        log_change "ERROR: Claude 응답 파싱 실패. morning_ts 변경 없음."
        osascript -e "display notification \"Claude 분석 실패\" with title \"Claude Candy\" subtitle \"스케줄 변경 없음\"" 2>/dev/null || true
        return 1
    fi

    local claude_decoded
    claude_decoded=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(json.dumps(d, ensure_ascii=False))" "$claude_result" 2>/dev/null) || claude_decoded="$claude_result"
    log_change "Claude 응답: $claude_decoded"

    local validated
    validated=$(validate_and_clip "$claude_result" "$current_morning_ts") || {
        log_change "ERROR: 검증 실패. morning_ts 변경 없음."
        return 1
    }

    local new_h new_m new_reason shift_min
    new_h=$(echo "$validated" | sed -n '1p' | awk '{print $1}')
    new_m=$(echo "$validated" | sed -n '1p' | awk '{print $2}')
    new_reason=$(echo "$validated" | sed -n '2p')
    shift_min=$(echo "$validated" | sed -n '3p')

    local new_morning_ts
    new_morning_ts=$(compute_morning_ts "$new_h" "$new_m" "$dow")

    local new_morning_str
    new_morning_str=$(printf '%02d:%02d' "$new_h" "$new_m")

    echo "$new_morning_ts" > "$CANDY_MORNING_TS_FILE"

    manage_phase "${shift_min:-0}" >/dev/null

    log_change "이전 morning: $current_morning_str"
    log_change "새 morning: $new_morning_str (ts=$new_morning_ts)"
    log_change "판단 근거: $new_reason"
    log_change "변경폭: ${shift_min}분"
    log_change "STATUS: SUCCESS"
    log_change "============================="

    osascript -e "display notification \"morning pre-warm: $new_morning_str\" with title \"Claude Candy\" subtitle \"스케줄 최적화 완료\"" 2>/dev/null || true
}

main "$@"
