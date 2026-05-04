#!/bin/bash
set -euo pipefail
set +m  # job control 메시지 끄기

JOBS_ROOT="${JOBS_ROOT:-$HOME/jobs}"
TOOLS_BIN_DIR="${TOOLS_BIN_DIR:-}"

export PATH="${TOOLS_BIN_DIR:+$TOOLS_BIN_DIR:}$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export PYTHONPATH="$JOBS_ROOT/bin/lib${PYTHONPATH:+:$PYTHONPATH}"

# shellcheck source=/dev/null
source "$JOBS_ROOT/bin/lib/candy_time.sh"

# ==================== 상태 파일 경로 ====================
CANDY_NEXT_TS_FILE="$JOBS_ROOT/config/.candy_next_ts"
CANDY_MORNING_TS_FILE="$JOBS_ROOT/config/.candy_morning_ts"
export CANDY_NEXT_TS_FILE CANDY_MORNING_TS_FILE

# ==================== 설정 ====================
LOG_DIR="$JOBS_ROOT/logs"
LOG_FILE="$LOG_DIR/refresh.log"
PID_FILE="$LOG_DIR/refresh.pid"
LIMIT_FLAG="$LOG_DIR/.limit_until"
SNAPSHOT_CSV="$LOG_DIR/usage_snapshots.csv"
SCRIPT_TIMEOUT=600  # 10분
CLAUDE_TIMEOUT=60   # 60초
MAX_RETRIES=10
RETRY_DELAY=30

mkdir -p "$LOG_DIR"
exec 2>>"$LOG_FILE"

# ==================== 함수 정의 ====================
log() {
    echo "[$(runtime_now_fmt '%Y-%m-%d %H:%M:%S')] $*"
}

cleanup() {
    log "🧹 정리 작업..."
    [ -f "$PID_FILE" ] && rm -f "$PID_FILE"
    [ -n "${TIMEOUT_PID:-}" ] && kill "$TIMEOUT_PID" 2>/dev/null || true
}

# timeout 명령어 대체 함수 (macOS 호환)
run_with_timeout() {
    local timeout=$1
    shift
    local cmd="$@"

    # 백그라운드로 명령 실행
    eval "$cmd" &
    local cmd_pid=$!

    # 타임아웃 감시 프로세스
    (
        sleep "$timeout"
        kill -TERM "$cmd_pid" 2>/dev/null || true
    ) &
    local killer_pid=$!

    # 명령 완료 대기
    local exit_code=0
    wait "$cmd_pid" 2>/dev/null || exit_code=$?

    # 타임아웃 프로세스 정리
    kill "$killer_pid" 2>/dev/null || true
    wait "$killer_pid" 2>/dev/null || true

    return $exit_code
}

# ==================== 주말 체크 ====================
DOW=$(runtime_weekday_u)  # 1=월 ... 6=토, 7=일
if [ "$DOW" -ge 6 ]; then
    echo "[$(runtime_now_fmt '%Y-%m-%d %H:%M:%S')] 📅 주말 스킵 (DOW=$DOW)" >> "$LOG_FILE"
    exit 0
fi

# ==================== Quiet Hours 안전망 ====================
# optimizer가 morning_ts 기록에 실패한 경우에도 새벽에 candy가 도는 걸 방지
# (정상 동작 시엔 morning_ts gate가 먼저 막음)
HOUR=$(runtime_now_fmt '%H')
if [ "$HOUR" -ge 23 ] || [ "$HOUR" -lt 5 ]; then
    exit 0  # silent: 야간 quiet hours
fi

# ==================== Gate Check (분 단위 체인) ====================
# .candy_morning_ts: optimizer가 쓰는 다음 아침 시각 (이 시각 이전엔 실행 안 함)
# .candy_next_ts:    이전 candy의 resets_at (체인 연결)
if ! python3 << 'GATE_PYEOF'
import os, sys
from candy_time import get_now

def read_ts(path):
    try:
        with open(path) as f:
            v = f.read().strip()
            return int(v) if v else 0
    except (FileNotFoundError, ValueError):
        return 0

morning_ts = read_ts(os.environ.get("CANDY_MORNING_TS_FILE", ""))
next_ts    = read_ts(os.environ.get("CANDY_NEXT_TS_FILE", ""))
now_ts     = int(get_now().timestamp())

if morning_ts > now_ts:
    sys.exit(1)   # 아침 gate 아직 안 됨
if next_ts > now_ts:
    sys.exit(1)   # 체인 아직 안 됨
sys.exit(0)
GATE_PYEOF
then
    exit 0  # silent: 아직 시간 아님
fi

# ==================== API 제한 체크 ====================
if [ -f "$LIMIT_FLAG" ]; then
    RESET_TIME=$(head -1 "$LIMIT_FLAG")
    LIMIT_MSG=$(tail -1 "$LIMIT_FLAG")
    CURRENT_TIME=$(runtime_now_ts)

    if [ $CURRENT_TIME -lt $RESET_TIME ]; then
        REMAINING_HOURS=$(( ($RESET_TIME - $CURRENT_TIME) / 3600 ))
        echo "[$(runtime_now_fmt '%Y-%m-%d %H:%M:%S')] ⏸️  API 제한 중: $LIMIT_MSG" >> "$LOG_FILE"
        echo "[$(runtime_now_fmt '%Y-%m-%d %H:%M:%S')] ⏸️  약 ${REMAINING_HOURS}시간 후 자동 재시도" >> "$LOG_FILE"
        exit 0
    else
        echo "[$(runtime_now_fmt '%Y-%m-%d %H:%M:%S')] ✅ API 제한 해제됨, 플래그 파일 삭제" >> "$LOG_FILE"
        rm -f "$LIMIT_FLAG"
    fi
fi

# ==================== PID Lock 체크 ====================
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if ps -p "$OLD_PID" > /dev/null 2>&1; then
        echo "[$(runtime_now_fmt '%Y-%m-%d %H:%M:%S')] ⚠️ 이미 실행 중 (PID: $OLD_PID)" >> "$LOG_FILE"
        exit 1
    else
        echo "[$(runtime_now_fmt '%Y-%m-%d %H:%M:%S')] 🗑️ 오래된 PID 파일 삭제 (PID: $OLD_PID는 종료됨)" >> "$LOG_FILE"
        rm -f "$PID_FILE"
    fi
fi

echo $$ > "$PID_FILE"

# ==================== Trap 설정 ====================
trap cleanup EXIT

# ==================== 전체 스크립트 타임아웃 ====================
(
    sleep $SCRIPT_TIMEOUT
    log "⏰ ${SCRIPT_TIMEOUT}초 타임아웃, 프로세스 종료"
    kill -TERM $$ 2>/dev/null
) &
TIMEOUT_PID=$!

# ==================== 로그 다이어트 ====================
if [ -f "$LOG_FILE" ]; then
    tail -n 100 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi

# ==================== 메인 로직 ====================
{
    # Isolated cwd so `claude -p` doesn't load any project's CLAUDE.md / .claude settings.
    mkdir -p "$JOBS_ROOT/.candy_cwd" && cd "$JOBS_ROOT/.candy_cwd"
    log "🚀 Claude Code 깨우기 (PID: $$)"


    RETRY_COUNT=0
    SUCCESS=false

    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        log "🍬 갱신 시도 ($((RETRY_COUNT+1))/$MAX_RETRIES)..."

        TEMP_OUT=$(mktemp)

        if run_with_timeout $CLAUDE_TIMEOUT "claude -p \
            --model haiku \
            --no-session-persistence \
            --tools '' --agent '' --setting-sources '' --system-prompt 'Short' \
            --output-format json \
            'Respond only ok' > '$TEMP_OUT' 2>&1"; then

            # JSON 파싱: text 응답 + resetsAt 추출
            PARSE_RESULT=$(TEMP_OUT_PATH="$TEMP_OUT" python3 << 'PYEOF'
import sys, json, os

text_parts = []
resets_at = None

with open(os.environ["TEMP_OUT_PATH"]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            items = obj if isinstance(obj, list) else [obj]
            for item in items:
                t = item.get('type', '')
                if t == 'rate_limit_event':
                    resets_at = item.get('rate_limit_info', {}).get('resetsAt')
                elif t == 'result':
                    text_parts.append(item.get('result', ''))
        except Exception:
            text_parts.append(line)

text = ''.join(text_parts).strip()
print(f"TEXT={text}")
if resets_at is not None:
    print(f"RESETS_AT={int(resets_at)}")
PYEOF
)
            rm -f "$TEMP_OUT"

            RESPONSE=$(echo "$PARSE_RESULT" | sed -n 's/^TEXT=//p')
            RESETS_AT_VAL=$(echo "$PARSE_RESULT" | sed -n 's/^RESETS_AT=//p')
            log ">> Claude Response: $RESPONSE"

            if echo "$RESPONSE" | grep -qi "ok"; then
                log "✅ 성공! 세션 확보"
                if [ -n "$RESETS_AT_VAL" ]; then
                    RESETS_AT_INT="$RESETS_AT_VAL" SNAPSHOT_CSV="$SNAPSHOT_CSV" python3 << 'PYEOF'
import os

from candy_time import get_now
from usage_csv import append_row

csv_file = os.environ["SNAPSHOT_CSV"]
resets_at = int(os.environ["RESETS_AT_INT"])
now = get_now()

row = {
    "timestamp": int(now.timestamp()),
    "datetime": now.strftime("%Y-%m-%d %H:%M:%S"),
    "dow": now.weekday(),
    "hour": now.hour,
    "type": "candy",
    "sample_slot": "",
    "5h_used_pct": "",
    "5h_resets_at": resets_at,
    "7d_used_pct": "",
    "raw_5h_used_pct": "",
    "effective_5h_used_pct": "",
    "minutes_to_reset": "",
    "window_elapsed_min": "",
    "progress_source": "",
    "limit_hit_at": "",
}
append_row(csv_file, row)
PYEOF
                    TS_HUMAN=$(runtime_format_ts "$RESETS_AT_VAL" '%H:%M:%S' 2>/dev/null || echo "$RESETS_AT_VAL")
                    log "📊 resetsAt=$TS_HUMAN (CSV 기록)"

                    # ── 분 단위 체인: 상태 파일 + snapshot/progress plist 갱신 ──
                    RESETS_AT_INT="$RESETS_AT_VAL" \
                    CANDY_NEXT_TS_FILE="$CANDY_NEXT_TS_FILE" \
                    PLIST_SYS_DIR="${PLIST_SYS_DIR:-$HOME/Library/LaunchAgents}" \
                    JOBS_ROOT="$JOBS_ROOT" \
                    python3 << 'CHAIN_PYEOF'
import datetime, os, plistlib
from candy_time import get_now

resets_at   = int(os.environ["RESETS_AT_INT"])
jobs_root   = os.environ["JOBS_ROOT"]
plist_dir   = os.environ["PLIST_SYS_DIR"]

# chain 기록
next_file    = os.environ["CANDY_NEXT_TS_FILE"]
os.makedirs(os.path.dirname(next_file), exist_ok=True)
with open(next_file, "w") as f:
    f.write(str(resets_at))

def plist_args(script_name):
    return ["/bin/sh", "-c", f'exec "${{JOBS_ROOT:-$HOME/jobs}}/bin/{script_name}"']

def write_plist(label, script_name, intervals, jobs_root):
    data = {
        "Label": label,
        "ProgramArguments": plist_args(script_name),
        "StartCalendarInterval": intervals,
    }
    path = f"{jobs_root}/LaunchAgents/{label}.plist"
    with open(path, "wb") as f:
        plistlib.dump(data, f, fmt=plistlib.FMT_XML)
    return path

now_dt  = get_now()
now_ts  = int(now_dt.timestamp())

# snapshot: resets_at - 3분
snap_dt = datetime.datetime.fromtimestamp(resets_at - 180)
write_plist(
    "com.claude.candy.snapshot",
    "usage_snapshot.sh",
    [{"Hour": snap_dt.hour, "Minute": snap_dt.minute}],
    jobs_root,
)

# progress: candy 시작 기준 +59/119/179/239분
candy_total = now_dt.hour * 60 + now_dt.minute
progress_intervals = []
for delta in (59, 119, 179, 239):
    total = (candy_total + delta) % 1440
    progress_intervals.append({"Hour": total // 60, "Minute": total % 60})
write_plist(
    "com.claude.candy.progress",
    "usage_progress.sh",
    progress_intervals,
    jobs_root,
)
CHAIN_PYEOF

                    # snapshot / progress LaunchAgent 재로드
                    _UID=$(id -u)
                    for _label in com.claude.candy.snapshot com.claude.candy.progress; do
                        _plist_path="$JOBS_ROOT/LaunchAgents/${_label}.plist"
                        launchctl bootout "gui/${_UID}/${_label}" 2>/dev/null || true
                        launchctl bootstrap "gui/${_UID}" "$_plist_path" 2>/dev/null || true
                    done
                    log "🔗 체인 업데이트 완료: next=$(cat "$CANDY_NEXT_TS_FILE" 2>/dev/null)"
                else
                    # resetsAt 없이 ok 응답 — 5시간 폴백으로 재호출 억제
                    CANDY_NEXT_TS_FILE="$CANDY_NEXT_TS_FILE" python3 << 'FALLBACK_PYEOF'
import os
from candy_time import get_now
now_ts = int(get_now().timestamp())
next_file = os.environ["CANDY_NEXT_TS_FILE"]
os.makedirs(os.path.dirname(next_file), exist_ok=True)
with open(next_file, "w") as f:
    f.write(str(now_ts + 18000))
FALLBACK_PYEOF
                    log "⚠️ resetsAt 누락, 5시간 폴백 next_ts 기록"
                fi
                osascript -e "display notification \"$RESPONSE\" with title \"Claude Candy\" subtitle \"갱신 성공\"" 2>/dev/null || true
                SUCCESS=true
                break
            elif echo "$RESPONSE" | grep -qi "hit your limit"; then
                log "🚫 API 사용량 제한 도달 - 재시도 중단"
                log "ℹ️  응답: $RESPONSE"

                # 리셋 시간 파싱
                RESET_TIMESTAMP=""
                if RESET_STR=$(echo "$RESPONSE" | grep -oE "resets [A-Z][a-z]+ [0-9]+ at [0-9]+[ap]m"); then
                    DATE_PART=$(echo "$RESET_STR" | sed 's/resets //' | sed 's/ at.*//')
                    TIME_PART=$(echo "$RESET_STR" | sed 's/.* at //')

                    HOUR=$(echo "$TIME_PART" | sed 's/[ap]m$//')
                    if echo "$TIME_PART" | grep -q "pm"; then
                        if [ "$HOUR" -ne 12 ]; then
                            HOUR=$(( HOUR + 12 ))
                        fi
                    else
                        if [ "$HOUR" -eq 12 ]; then
                            HOUR=0
                        fi
                    fi

                    CURRENT_YEAR=$(runtime_year)

                    RESET_TIMESTAMP=$(python3 -c "
import datetime
try:
    dt = datetime.datetime.strptime('$DATE_PART $CURRENT_YEAR $HOUR:00', '%b %d %Y %H:%M')
    print(int(dt.timestamp()))
except:
    print('')
" 2>/dev/null)

                    if [ -n "$RESET_TIMESTAMP" ]; then
                        HOURS_UNTIL=$(( ($RESET_TIMESTAMP - $(runtime_now_ts)) / 3600 ))
                        log "ℹ️  리셋 시간: $(runtime_format_ts "$RESET_TIMESTAMP" '%Y-%m-%d %H:%M') (약 ${HOURS_UNTIL}시간 후)"
                    fi
                fi

                if [ -z "$RESET_TIMESTAMP" ]; then
                    RESET_TIMESTAMP=$(( $(runtime_now_ts) + 86400 ))
                    log "⚠️  리셋 시간 파싱 실패, 24시간 후로 설정"
                fi

                {
                    echo "$RESET_TIMESTAMP"
                    runtime_now_ts
                    echo "$RESPONSE"
                } > "$LIMIT_FLAG"

                log "ℹ️  제한 해제까지 모든 시도 중단됨"
                osascript -e "display notification \"제한 해제까지 시도 중단\" with title \"Claude Candy\" subtitle \"자동 재개 예정\"" 2>/dev/null || true
                break
            else
                log "⚠️ 실패 사유: $RESPONSE"
            fi
        else
            rm -f "$TEMP_OUT"
            log "⏰ Claude 명령어 타임아웃 (${CLAUDE_TIMEOUT}초)"
        fi

        RETRY_COUNT=$((RETRY_COUNT+1))
        if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
            log "⏳ ${RETRY_DELAY}초 후 재시도..."
            sleep $RETRY_DELAY
        fi
    done

    if [ "$SUCCESS" = true ]; then
        log "🎉 완료!"
        exit 0
    else
        log "❌ 최종 실패 (총 $((MAX_RETRIES * RETRY_DELAY / 60))분 시도)"
        osascript -e "display notification \"최종 실패\" with title \"Claude Candy\" subtitle \"갱신 실패\"" 2>/dev/null || true
        exit 1
    fi

} >> "$LOG_FILE" 2>&1
