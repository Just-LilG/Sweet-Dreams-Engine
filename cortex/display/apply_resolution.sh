#!/system/bin/sh
# cortex/display/apply_resolution.sh — per-app render scale
#
# Applies Android Game Mode downscale the same way AZenith does
# (ResolutionChanger.c + restart_target_app, Apache 2.0, Zexshia):
#   cmd game set --mode 2 --downscale <factor> <pkg>
# then force-stops and cold-starts the package so WindowManager picks it up.
#
# Usage: apply_resolution.sh <native|0.75|0.5|...> <package> [arm]
#   arm = write overlay / cmd game set only (no force-stop). Used from WebUI
#   so picking a card does not launch every selected game.
# SKIP_RESTART=1 in the environment is the same as arm.

RES="$1"
PKG="$2"
MODE="$3"
MODDIR="/data/adb/modules/sweet_dreams"
CORTEX="$MODDIR/cortex"
LOGFILE="$MODDIR/boot.log"
STATE_FILE="$CORTEX/display/resolution_applied_pkg.txt"
FACTOR_FILE="$CORTEX/display/resolution_applied_factor.txt"

. "$CORTEX/display/game_mode.sh"

log_res() { echo "[RESOLUTION] $1" | tee -a "$LOGFILE"; }

current_fps_hint() {
    _lock=$(cat "$CORTEX/display/fps_lock_game.txt" 2>/dev/null | tr -d '\r\n ')
    case "$_lock" in
        ''|off) echo "" ;;
        *) echo "$_lock" ;;
    esac
}

restart_like_azenith() {
    _pkg="$1"
    echo "$(date +%s)" > "$CORTEX/display/resolution_relaunch_grace.txt"
    log_res "Restarting $_pkg so Game Mode downscale applies on cold start"
    RES_ACTIVITY=$(cmd package resolve-activity --brief "$_pkg" 2>/dev/null | tail -n 1)
    if [ -n "$RES_ACTIVITY" ] && [ "$RES_ACTIVITY" != "No activity found" ]; then
        am force-stop "$_pkg" >/dev/null 2>&1
        am start -n "$RES_ACTIVITY" >/dev/null 2>&1
        log_res "Restarted $_pkg via am start -n $RES_ACTIVITY"
    else
        am force-stop "$_pkg" >/dev/null 2>&1
        monkey -p "$_pkg" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
        log_res "Restarted $_pkg via monkey fallback"
    fi
}

if [ "$RES" = "native" ] || [ -z "$RES" ]; then
    LAST_PKG=$(cat "$STATE_FILE" 2>/dev/null | tr -d '\r\n ')
    [ -z "$LAST_PKG" ] && [ -n "$PKG" ] && LAST_PKG="$PKG"
    if [ -n "$LAST_PKG" ]; then
        reset_azenith_downscale "$LAST_PKG"
        BAK=$(cat "$CORTEX/display/wm_size_backup.txt" 2>/dev/null)
        if [ -n "$BAK" ]; then
            wm size "$BAK" >/dev/null 2>&1 || wm size reset >/dev/null 2>&1
            rm -f "$CORTEX/display/wm_size_backup.txt"
        fi
        log_res "Reset Game Mode intervention for $LAST_PKG (native)"
    fi
    rm -f "$STATE_FILE" "$FACTOR_FILE" 2>/dev/null
    exit 0
fi

if [ -z "$PKG" ]; then
    log_res "ERROR: no package specified, cannot apply per-app resolution scale"
    exit 1
fi

NORM=$(normalize_downscale "$RES")
if [ "$NORM" = "native" ]; then
    "$0" native "$PKG"
    exit 0
fi

FPS_HINT=$(current_fps_hint)
apply_azenith_downscale "$PKG" "$NORM" "$FPS_HINT"
ALREADY=$(cat "$FACTOR_FILE" 2>/dev/null | tr -d '\r\n ')
ALREADY_PKG=$(cat "$STATE_FILE" 2>/dev/null | tr -d '\r\n ')
echo "$PKG" > "$STATE_FILE"
echo "$NORM" > "$FACTOR_FILE"
log_res "Applied AZenith-style downscale=$NORM for $PKG (overlay + cmd game set --mode 2)"

NEED_RESTART=1
[ "$MODE" = "arm" ] && NEED_RESTART=0
[ "$SKIP_RESTART" = "1" ] && NEED_RESTART=0
[ "$ALREADY" = "$NORM" ] && [ "$ALREADY_PKG" = "$PKG" ] && NEED_RESTART=0

if [ "$NEED_RESTART" = "1" ]; then
    if pidof "$PKG" >/dev/null 2>&1; then
        restart_like_azenith "$PKG"
    else
        log_res "Armed $PKG at $NORM — will take effect on next cold start"
    fi
fi
