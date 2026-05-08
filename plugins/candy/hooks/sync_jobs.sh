#!/bin/bash
# hooks/sync_jobs.sh — SessionStart 마다 ~/jobs/ 가 plugin bundle 의 최신 버전과
# 같은지 확인하고, 다르면 자동으로 동기화한다.
#
# 핵심 안전 원칙:
#   - 어떤 실패도 세션을 깨뜨리지 않는다 (항상 exit 0)
#   - 같은 버전이면 즉시 종료 (~50ms, 매 세션 부담 없음)
#   - 심링크된 ~/jobs (개발자 환경) 는 절대 건드리지 않는다
#   - 런타임 상태(logs/, .candy_*) 는 보존, 번들 파일만 교체한다

set -uo pipefail

JOBS_ROOT="${JOBS_ROOT:-$HOME/jobs}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
LOG="$HOME/Library/Logs/candy-sync.log"

# 로그 디렉터리 확보 실패 시 silent 모드로 폴백
mkdir -p "$(dirname "$LOG")" 2>/dev/null || LOG=/dev/null

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG" 2>/dev/null || true; }

# ── 가드: hook 컨텍스트가 아니면 종료 ──
[ -z "$PLUGIN_ROOT" ] && exit 0

# ── 가드: kill switch ──
[ -f "$HOME/.candy_no_sync" ] && exit 0

# ── 가드: candy 가 아직 설치되지 않음 ──
[ ! -d "$JOBS_ROOT" ] && exit 0

# ── 가드: dev mode (~/jobs 가 심링크) — 자동 sync 비활성화 ──
# 개발자가 작업 중인 소스를 cached 버전으로 덮어쓰면 안 된다.
if [ -L "$JOBS_ROOT" ]; then
    exit 0
fi

# ── 버전 비교 ──
PLUGIN_VERSION=$(python3 -c "
import json
try:
    print(json.load(open('$PLUGIN_ROOT/.claude-plugin/plugin.json'))['version'])
except Exception:
    pass
" 2>/dev/null)

[ -z "$PLUGIN_VERSION" ] && { log "plugin.json 에서 version 을 못 읽음"; exit 0; }

INSTALLED_VERSION=$(cat "$JOBS_ROOT/.candy_version" 2>/dev/null || echo "")

# fast path: 같은 버전이면 즉시 종료
if [ "$PLUGIN_VERSION" = "$INSTALLED_VERSION" ]; then
    exit 0
fi

# ── 가드: launchctl 없으면 sync 의미 없음 ──
if ! command -v launchctl >/dev/null 2>&1; then
    log "launchctl 없음 — sync 건너뜀"
    exit 0
fi

log "sync 시작: '${INSTALLED_VERSION:-신규}' → $PLUGIN_VERSION (JOBS_ROOT=$JOBS_ROOT)"

# ── 번들 파일 교체 (런타임 상태는 건드리지 않음) ──
COPY_FAILED=0
for dir in bin LaunchAgents tests; do
    if [ -d "$PLUGIN_ROOT/$dir" ]; then
        rm -rf "$JOBS_ROOT/$dir"
        if ! cp -R "$PLUGIN_ROOT/$dir" "$JOBS_ROOT/" 2>>"$LOG"; then
            log "복사 실패: $dir"
            COPY_FAILED=1
        fi
    fi
done

# config: lunch_schedule.conf 만 교체, 런타임 파일은 건드리지 않음
mkdir -p "$JOBS_ROOT/config"
[ -f "$PLUGIN_ROOT/config/lunch_schedule.conf" ] && cp "$PLUGIN_ROOT/config/lunch_schedule.conf" "$JOBS_ROOT/config/" 2>>"$LOG"

# README
[ -f "$PLUGIN_ROOT/README.md" ] && cp "$PLUGIN_ROOT/README.md" "$JOBS_ROOT/" 2>>"$LOG"

if [ "$COPY_FAILED" = "1" ]; then
    log "복사 단계에서 일부 실패 — sync 중단, 버전 마킹 안 함"
    exit 0
fi

# ── LaunchAgent 4개 재부트스트랩 ──
UID_VAL=$(id -u)
BOOTSTRAP_FAILED=0
for label in com.claude.candy com.claude.candy.progress com.claude.candy.snapshot com.claude.candy.optimizer; do
    plist="$HOME/Library/LaunchAgents/${label}.plist"
    if [ ! -e "$plist" ]; then
        log "skip: $label (plist 심링크 없음)"
        continue
    fi
    launchctl bootout "gui/$UID_VAL/$label" 2>/dev/null || true
    if ! launchctl bootstrap "gui/$UID_VAL" "$plist" 2>>"$LOG"; then
        log "bootstrap 실패: $label"
        BOOTSTRAP_FAILED=1
    fi
done

# ── 버전 파일 갱신 ──
echo "$PLUGIN_VERSION" > "$JOBS_ROOT/.candy_version"

# ── 사용자 알림 (SessionStart 출력 = system-reminder 로 Claude 에게 전달) ──
if [ "$BOOTSTRAP_FAILED" = "1" ]; then
    echo "⚠️  candy v$PLUGIN_VERSION 동기화 완료 — 일부 LaunchAgent 재부트스트랩 실패 ($LOG 참고)"
else
    echo "🍬 candy 자동 업데이트: ${INSTALLED_VERSION:-신규 설치} → v$PLUGIN_VERSION"
fi

log "sync 완료"
exit 0
