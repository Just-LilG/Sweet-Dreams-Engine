#!/system/bin/sh
# cortex/display/apply_resolution.sh — per-app render scale
#
# Primary path matches AZenith ResolutionChanger.c:
#   cmd game set --mode 2 --downscale <factor> <pkg>
# plus game_overlay. Session fallback: wm size while the game is foreground
# (restored on native / game exit) for ROMs where Game Mode is stubbed.
#
# Usage: apply_resolution.sh <native|0.75|0.5|...> <package> [arm|session]
#   arm     = set intervention only (no force-stop)
#   session = set intervention + wm size fallback (no force-stop); for live game
# SKIP_RESTART=1 == arm

RES="$1"
PKG="$2"
MODE="$3"
MODDIR="/data/adb/modules/sweet_dreams"
CORTEX="$MODDIR/cortex"
LOGFILE="$MODDIR/boot.log"
STATE_FILE="$CORTEX/display/resolution_applied_pkg.txt"
FACTOR_FILE="$CORTEX/display/resolution_applied_factor.txt"
WM_BAK="$CORTEX/display/wm_size_backup.txt"
HAS_GAME=$(cat "$CORTEX/fps/has_game_service.txt" 2>/dev/null || echo "1")

. "$CORTEX/display/game_mode.sh"

log_res() { echo "[RESOLUTION] $1" | tee -a "$LOGFILE"; }

current_fps_hint() {
    _lock=$(cat "$CORTEX/display/fps_lock_game.txt" 2>/dev/null | tr -d '\r\n ')
    case "$_lock" in
        ''|off) echo "" ;;
        *) echo "$_lock" ;;
    esac
}

apply_wm_size_scale() {
    _res="$1"
    PHYS=$(wm size 2>/dev/null | awk '/Physical size:/ {print $3; exit}')
    [ -z "$PHYS" ] && PHYS=$(wm size 2>/dev/null | awk '/Physical size:/ {print $NF; exit}')
    [ -z "$PHYS" ] && PHYS=$(wm size 2>/dev/null | awk -F': ' '/size/ {print $NF; exit}' | tr -d ' ')
    W=${PHYS%x*}
    H=${PHYS#*x}
    case "$W$H" in
        ''|*[!0-9]*) return 1 ;;
    esac
    SW=$(awk -v w="$W" -v s="$_res" 'BEGIN { printf "%d", (w*s)+0.5 }')
    SH=$(awk -v h="$H" -v s="$_res" 'BEGIN { printf "%d", (h*s)+0.5 }')
    [ "$SW" -lt 240 ] && return 1
    [ "$SH" -lt 240 ] && return 1
    [ ! -f "$WM_BAK" ] && echo "$PHYS" > "$WM_BAK"
    if wm size "${SW}x${SH}" >/dev/null 2>&1; then
        log_res "Session wm size ${SW}x${SH} (physical $PHYS, scale=$_res)"
        return 0
    fi
    return 1
}

restore_wm_size() {
    BAK=$(cat "$WM_BAK" 2>/dev/null)
    if [ -n "$BAK" ]; then
        wm size "$BAK" >/dev/null 2>&1 || wm size reset >/dev/null 2>&1
        rm -f "$WM_BAK"
        log_res "Restored wm size $BAK"
    else
        wm size reset >/dev/null 2>&1
    fi
}

restart_like_azenith() {
    _pkg="$1"
    echo "$(date +%s)" > "$CORTEX/display/resolution_relaunch_grace.txt"
    log_res "Restarting $_pkg so Game Mode downscale applies on cold start"
    RES_ACTIVITY=$(cmd package resolve-activity --brief "$_pkg" 2>/dev/null | tail -n 1)
    if [ -n "$RES_ACTIVITY" ] && [ "$RES_ACTIVITY" != "No activity found" ]; then
        am force-stop "$_pkg" >/dev/null 2>&1
        sleep 0.4
        am start -n "$RES_ACTIVITY" >/dev/null 2>&1
        log_res "Restarted $_pkg via am start -n $RES_ACTIVITY"
    else
        am force-stop "$_pkg" >/dev/null 2>&1
        sleep 0.4
        monkey -p "$_pkg" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
        log_res "Restarted $_pkg via monkey fallback"
    fi
}

if [ "$RES" = "native" ] || [ -z "$RES" ]; then
    LAST_PKG=$(cat "$STATE_FILE" 2>/dev/null | tr -d '\r\n ')
    [ -z "$LAST_PKG" ] && [ -n "$PKG" ] && LAST_PKG="$PKG"
    if [ -n "$LAST_PKG" ]; then
        reset_azenith_downscale "$LAST_PKG"
        log_res "Reset Game Mode intervention for $LAST_PKG (native)"
    fi
    restore_wm_size
    rm -f "$STATE_FILE" "$FACTOR_FILE" 2>/dev/null
    exit 0
fi

if [ -z "$PKG" ]; then
    log_res "ERROR: no package specified"
    exit 1
fi

NORM=$(normalize_downscale "$RES")
if [ "$NORM" = "native" ]; then
    "$0" native "$PKG"
    exit 0
fi

FPS_HINT=$(current_fps_hint)

# Always write overlay first (works even when `cmd game set` is flaky).
write_game_overlay "$PKG" "$NORM" "$FPS_HINT"
cmd game mode 2 "$PKG" >/dev/null 2>&1

GAME_OK=0
if [ "$HAS_GAME" = "1" ] && android_has_game_set; then
    if azenith_game_set "$PKG" "$NORM" "$FPS_HINT"; then
        GAME_OK=1
        log_res "cmd game set --mode 2 --downscale $NORM $PKG"
    fi
    # Retry without fps if combined form failed.
    if [ "$GAME_OK" != "1" ]; then
        cmd game set --mode 2 --downscale "$NORM" "$PKG" >/dev/null 2>&1 && GAME_OK=1
    fi
    if [ "$GAME_OK" != "1" ]; then
        cmd game set --downscale "$NORM" "$PKG" >/dev/null 2>&1 && GAME_OK=1
    fi
fi

# device_config path for older Android / broken game set
if [ "$GAME_OK" != "1" ]; then
    write_game_overlay "$PKG" "$NORM" "$FPS_HINT"
    cmd game mode 2 "$PKG" >/dev/null 2>&1
    log_res "game_overlay downscaleFactor=$NORM for $PKG (cmd game set unavailable or failed)"
fi

ALREADY=$(cat "$FACTOR_FILE" 2>/dev/null | tr -d '\r\n ')
ALREADY_PKG=$(cat "$STATE_FILE" 2>/dev/null | tr -d '\r\n ')
echo "$PKG" > "$STATE_FILE"
echo "$NORM" > "$FACTOR_FILE"

NEED_RESTART=1
[ "$MODE" = "arm" ] && NEED_RESTART=0
[ "$MODE" = "session" ] && NEED_RESTART=0
[ "$SKIP_RESTART" = "1" ] && NEED_RESTART=0
[ "$ALREADY" = "$NORM" ] && [ "$ALREADY_PKG" = "$PKG" ] && NEED_RESTART=0

# Session fallback: always reinforce with wm size while game is live when
# Game Mode service was reported missing at boot, or when explicitly session.
if [ "$MODE" = "session" ] || [ "$HAS_GAME" != "1" ]; then
    apply_wm_size_scale "$NORM" || true
fi

if [ "$NEED_RESTART" = "1" ]; then
    if pidof "$PKG" >/dev/null 2>&1; then
        restart_like_azenith "$PKG"
    else
        log_res "Armed $PKG at $NORM — takes effect on next cold start"
    fi
fi
