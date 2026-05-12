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
CLAUDE_CALL_TIMEOUT=${CLAUDE_CALL_TIMEOUT:-300}   # claude -p 호출당 최대 5분
OPTIMIZER_MAX_AGE=${OPTIMIZER_MAX_AGE:-7200}       # 스크립트 총 실행 한도 2시간
OPTIMIZER_START_TS=$(date +%s)

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

    # 동적 출근 시간 라벨
    local ws_label
    ws_label=$(printf '%02d:%02d' "$WORK_START_HOUR" "$WORK_START_MIN")
    local pw_window
    pw_window=$(prewarm_window_label)
    # reset_1/2/3 범위 계산
    local ws_min=$((WORK_START_HOUR * 60 + WORK_START_MIN))
    local r1_lo=$((ws_min + PREWARM_MIN_BUFFER_MIN))
    local r1_hi=$((ws_min + 300))
    local r2_lo=$((r1_lo + 300))
    local r2_hi=$((r1_hi + 300))
    local r3_lo=$((r2_lo + 300))
    local r3_hi=$((r2_hi + 300))
    local r1_range r2_range r3_range
    r1_range=$(printf '(%02d:%02d, %02d:%02d]' $((r1_lo/60)) $((r1_lo%60)) $((r1_hi/60)) $((r1_hi%60)))
    r2_range=$(printf '(%02d:%02d, %02d:%02d]' $((r2_lo/60)) $((r2_lo%60)) $((r2_hi/60)) $((r2_hi%60)))
    r3_range=$(printf '(%02d:%02d, %02d:%02d]' $((r3_lo/60)) $((r3_lo%60)) $((r3_hi/60)) $((r3_hi%60)))

    local prompt
    prompt=$(cat << PROMPT_EOF
너는 Claude Code 5시간 윈도우 스케줄 최적화 전문가야.

## candy 의 핵심 전략 (이걸 먼저 이해해)
candy 의 목적은 **토큰 사용량 피크를 단일 5시간 윈도우에 가두지 않고, 세션 경계(=다음 reset 시점) 를 피크 한가운데로 옮겨서 같은 피크가 두 개의 윈도우에 걸쳐 분산되게 만드는 것**이다.

예: 사용자가 매일 09~11시에 토큰을 폭주시키는 패턴이라면
- pre-warm 을 05:00 에 두면 → 다음 reset 이 10:00
- 09~10시 사용량은 이전 윈도우가, 10~11시 사용량은 새 윈도우가 흡수
- 결과: 원래 한 윈도우에 몰리던 피크가 두 윈도우로 쪼개져서 사실상 가용 토큰이 2배

"피크를 fresh window 에 정렬" 이 아니라 **"피크 한복판에 윈도우 경계를 꽂는다"** 가 핵심이다.

부수적으로, 점심/비활성 시간이 윈도우 내부에 흡수되면 실질 토큰 밀도가 올라가는 secondary optimization 이 있다. 이 둘이 충돌하지 않을 때 함께 만족시킨다.

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
- 높은 최종 % = 해당 윈도우 시간대에 토큰 폭주 = **분산 후보**
- limit carry가 붙으면 그 시점 이후는 사실상 이미 한도 소진 상태 → 그 시점 직전이 피크 한복판
- 흐름 곡선의 기울기가 가장 가파른 구간이 실제 폭주 시간대

## 사용자 프로필
- 매일 ${ws_label} 출근, Claude Code 세션 시작
- 점심시간에는 전혀 사용하지 않음
- 사용량 피크는 데이터로 판단 (오후 쪽이 무거운 경향)

## 🚨 출근 시간 제약 (반드시 지켜야 함, 최우선 hard constraint)
사용자는 ${ws_label} 에 출근해서 Claude Code 를 쓰기 시작한다.

**pre-warm 은 반드시 ${ws_label} 이전에 실행되어야** candy 가 만든 윈도우가 사용자의 첫 활동을 흡수한다. 그렇지 않으면:
- pre-warm 이 ${ws_label} 이후이면 → 사용자가 ${ws_label} 에 자연 시작한 윈도우가 이미 active 라서 candy 의 query 는 새 윈도우를 만들지 못하고 기존 윈도우 안의 토큰만 낭비
- pre-warm 이 너무 이르면 → 그 윈도우가 ${ws_label} 이전에 만료되어 사용자 활동을 흡수 못함

따라서 **pre-warm ∈ ${pw_window} 범위 안에서만 선택**해야 한다. 이 범위를 벗어나는 답은 무효다.

## 체인 reset 으로 사고하라 (피크 분산의 핵심)
pre-warm 한 번이면 그날 하루 동안의 reset 시각이 모두 결정된다:
- reset_1 = pre-warm + 5h  ∈ ${r1_range}   ← 오전~점심 사이
- reset_2 = pre-warm + 10h ∈ ${r2_range}   ← **오후 피크 분산은 보통 이 reset 으로**
- reset_3 = pre-warm + 15h ∈ ${r3_range}   ← 저녁

피크를 분산하고 싶다면 reset_1, reset_2, reset_3 중 하나가 **피크 한가운데** 에 떨어지도록 pre-warm 을 역산해서 선택한다.

예시 (출근 09:00 기준 일반론):
- 오후 피크 17:00~19:00 (한가운데 18:00) 분산 목표 → reset_2 = 18:00 → pre-warm = 08:00
- 오전 피크 09:00~11:00 (한가운데 10:00) 분산 목표 → reset_1 = 10:00 → pre-warm = 05:00
- 점심 직후 13:00 분산 목표 → reset_1 = 13:00 → pre-warm = 08:00 (점심 흡수도 동시 만족)

## ${lunch_label}
${lunch}

## 현재 아침 pre-warm 시각
${current_morning}
(이 시각에 candy가 실행되어 5시간 윈도우가 시작됨 → 그 후 reset_1, reset_2, reset_3 가 5h 간격으로 자동 체인)

## 윈도우별 사용률 데이터
${usage_summary}

${hist_section}## 최적화 원칙
0. **출근 시간 hard constraint (위에서 설명한 그대로):** pre-warm ∈ ${pw_window}. 이 범위 밖은 무효.
1. **피크 분산 (최우선):** 윈도우 사용률 데이터에서 토큰이 가장 집중된 시간대(또는 limit carry 가 발생한 시점) 를 찾고, **reset_1/reset_2/reset_3 중 하나가 그 피크 한가운데로** 떨어지게 pre-warm 을 역산한다.
2. **점심 흡수 (보조):** 위 0/1 이 만족되는 선에서, 점심시간이 reset_1 직전 또는 윈도우 내부에 들어오면 가산점. 점심 직후가 피크라면 1번과 자연스럽게 일치한다.
3. **데이터 신호:** 윈도우 사용률 80% 이상 = 해당 시간대 토큰 부족 = 그 시간대를 두 윈도우로 쪼개야 할 후보. limit carry 가 붙은 시점은 더 강한 신호.
4. **공식:**
   - reset_N = pre-warm + N×5시간
   - pre-warm = (목표 reset 시각) - N×5시간 (분 단위 정확)
   - 결과 pre-warm 이 ${pw_window} 안에 있어야 채택 가능. 안 들어오면 다른 N 으로 다시 시도.
5. 분 단위로 HH:MM 자유롭게 최적화 가능.

## 출력 형식
반드시 아래 JSON 객체만 출력하고 다른 텍스트는 일절 쓰지 마라.
{"time": [HH, MM], "reason": "한국어 2-3줄. 어떤 시간대를 피크로 식별했고, 어떤 reset_N 을 그 피크 한가운데에 꽂았는지, 결과 pre-warm 이 ${pw_window} 안에 있는지 명시."}

time: 정확히 1개, HH=0-23 정수, MM=0-59 정수. 아침 pre-warm 시각. **반드시 ${pw_window} 범위 안의 값.**
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

    local attempt result raw_out tmp_out claude_pid killer_pid elapsed
    tmp_out=$(mktemp)
    for attempt in 1 2 3; do
        # 총 실행 시간 초과 체크
        elapsed=$(( $(date +%s) - OPTIMIZER_START_TS ))
        if [ "$elapsed" -gt "$OPTIMIZER_MAX_AGE" ]; then
            log_change "ERROR: 총 실행 시간 ${elapsed}초 초과 (한도 ${OPTIMIZER_MAX_AGE}초). Claude 호출 포기."
            rm -f "$tmp_out"
            return 1
        fi

        # claude -p 호출 + per-call timeout
        claude -p --model haiku --output-format json "$prompt" > "$tmp_out" 2>&1 &
        claude_pid=$!
        ( sleep "$CLAUDE_CALL_TIMEOUT" && kill -TERM "$claude_pid" 2>/dev/null ) &
        killer_pid=$!
        wait "$claude_pid" 2>/dev/null || true
        kill "$killer_pid" 2>/dev/null || true
        wait "$killer_pid" 2>/dev/null || true
        raw_out=$(cat "$tmp_out")

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
            rm -f "$tmp_out"
            return 0
        fi

        local preview
        preview=$(printf '%s' "$raw_out" | head -c 300 | tr '\n' ' ')
        log_change "WARN: JSON 파싱 실패 (attempt $attempt/3). Raw: $preview"
        [ "$attempt" -lt 3 ] && sleep 10
    done
    rm -f "$tmp_out"
}

# Hard constraint: pre-warm ∈ (WORK_START - 5h, WORK_START]
# WORK_START 는 lunch_schedule.conf 에서 읽음 (사용자가 candy-setup 에서 지정)
load_work_start() {
    local conf="$LUNCH_CONF"
    WORK_START_HOUR=9
    WORK_START_MIN=0
    [ -f "$conf" ] || return 0
    # grep no-match 를 set -e/pipefail 트랩에 걸리지 않도록 || true 로 흡수.
    # 구버전 conf (WORK_START 키 없음) 를 가진 업그레이드 사용자도 안전하게 fallback.
    local h m
    h=$(grep -E '^WORK_START_HOUR=' "$conf" 2>/dev/null | sed 's/^WORK_START_HOUR=//;s/"//g' | tr -d ' ' || true)
    m=$(grep -E '^WORK_START_MIN=' "$conf" 2>/dev/null  | sed 's/^WORK_START_MIN=//;s/"//g'  | tr -d ' ' || true)
    [ -n "$h" ] && WORK_START_HOUR="$h"
    [ -n "$m" ] && WORK_START_MIN="$m"
}
load_work_start
PREWARM_MIN_BUFFER_MIN=${PREWARM_MIN_BUFFER_MIN:-30}  # pre-warm + 5h 가 work_start 보다 최소 N분 이후

# pre-warm 유효 범위 라벨 (prompt + 로그용)
prewarm_window_label() {
    local ws_min=$((WORK_START_HOUR * 60 + WORK_START_MIN))
    local lower=$((ws_min + PREWARM_MIN_BUFFER_MIN - 300))
    if [ $lower -lt 0 ]; then lower=0; fi
    printf '(%02d:%02d, %02d:%02d]' \
        $((lower / 60)) $((lower % 60)) \
        $((ws_min / 60)) $((ws_min % 60))
}

validate_and_clip() {
    local claude_json="$1"
    local old_morning_ts="$2"

    export CLAUDE_JSON="$claude_json"
    export OLD_MORNING_TS="$old_morning_ts"
    export MAX_SHIFT_MIN
    export WORK_START_HOUR WORK_START_MIN PREWARM_MIN_BUFFER_MIN

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

# 출근 시간 hard constraint
ws_h = int(os.environ["WORK_START_HOUR"])
ws_m = int(os.environ["WORK_START_MIN"])
buf  = int(os.environ["PREWARM_MIN_BUFFER_MIN"])
work_start_min = ws_h * 60 + ws_m
# pre-warm + 5h > work_start + buf  ⇔  pre-warm > work_start + buf - 300
prewarm_lower = (work_start_min + buf) - 300  # exclusive lower (must be > this)
prewarm_upper = work_start_min                  # inclusive upper

new_min = nh * 60 + nm
clipped_by_window = False
if new_min <= prewarm_lower:
    new_min = prewarm_lower + 1
    clipped_by_window = True
elif new_min > prewarm_upper:
    new_min = prewarm_upper
    clipped_by_window = True

if clipped_by_window:
    nh = new_min // 60
    nm = new_min % 60
    print(f"WARN:출근 제약 클리핑 → {nh:02d}:{nm:02d}", file=sys.stderr)

old_ts = int(os.environ.get("OLD_MORNING_TS", "0") or "0")
max_allowed = int(os.environ["MAX_SHIFT_MIN"])
shift = 0

if old_ts > 0:
    old_dt = datetime.datetime.fromtimestamp(old_ts)
    old_min = old_dt.hour * 60 + old_dt.minute
    diff = new_min - old_min
    shift = abs(diff)
    if shift > max_allowed:
        new_min = old_min + (max_allowed if diff > 0 else -max_allowed)
        # 변경폭 클리핑 후에도 출근 제약 재적용
        if new_min <= prewarm_lower:
            new_min = prewarm_lower + 1
        elif new_min > prewarm_upper:
            new_min = prewarm_upper
        nh = new_min // 60
        nm = new_min % 60
        shift = abs(new_min - old_min)

print(f"{nh} {nm}")
print(reason)
print(shift)
PYEOF
}

# 다음 적용 날짜의 HH:MM → epoch timestamp 계산
# DOW 파라미터는 더 이상 사용하지 않음: 스크립트 시작 시각과 Claude 응답 시각이
# 날짜를 넘어갈 수 있으므로, 호출 시점의 today.isoweekday()로 다음 평일을 계산.
compute_morning_ts() {
    local h="$1" m="$2"
    H="$h" M="$m" python3 << 'PYEOF'
import datetime, os, time
from candy_time import get_today

today = get_today()
h = int(os.environ["H"])
m = int(os.environ["M"])

# 호출 시점의 요일 기준 (1=월 ... 7=일)
weekday = today.isoweekday()
if weekday >= 5:   # 금(5)/토(6)/일(7) → 다음 월요일
    days_ahead = 8 - weekday
else:              # 월~목 → 내일
    days_ahead = 1

next_date = today + datetime.timedelta(days=days_ahead)
dt = datetime.datetime.combine(next_date, datetime.time(h, m))
result_ts = int(dt.timestamp())

# 안전장치: 4일 초과면 경고 후 내일로 클램프
now_ts = int(time.time())
if result_ts - now_ts > 4 * 86400:
    import sys
    print(f"WARN: morning_ts가 {(result_ts - now_ts)//86400}일 후로 설정됨 — 내일로 클램프", file=sys.stderr)
    fallback = today + datetime.timedelta(days=1)
    dt = datetime.datetime.combine(fallback, datetime.time(h, m))
    result_ts = int(dt.timestamp())

print(result_ts)
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
    new_morning_ts=$(compute_morning_ts "$new_h" "$new_m")

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
