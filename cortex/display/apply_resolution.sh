#!/system/bin/sh
# cortex/display/apply_resolution.sh - Sweet Dreams Render Scale v3
#
# REBUILT around Android's real Game Mode Intervention API, ported from
# AZenith's ResolutionChanger.c (Apache 2.0, Zexshia) - same system API
# Samsung/Pixel's own built-in Game Booster resolution scaling uses.
#
# WHY THIS REPLACES wm size ENTIRELY:
#   v2 (wm size + wm density together) blurred the whole system UI because
#   lowering density forces every density-dependent bitmap to be upscaled.
#   v2.1.3 (wm size only, density left native) still blurred the UI -
#   because wm size is a GLOBAL logical-display override. It changes what
#   EVERY app on the system is told the screen size is, not just the game.
#   SystemUI, the status bar, and anything else on screen at the same
#   moment as the change all get relaid-out at the scaled size too.
#
#   The Game Mode Intervention API (`cmd game set --mode 2 --downscale
#   <factor> <pkg>`, Android 13+) is fundamentally different: it's scoped
#   to exactly ONE package via WindowManager's per-app Game Mode
#   framework. Only that app's render surface gets downscaled; nothing
#   else on the system is ever told the display changed size, so there's
#   nothing else to blur. This is a first-class Android API built
#   specifically for this exact use case - not a repurposed display command.
#
# ANDROID VERSION HANDLING:
#   Android 13+ : cmd game set --mode 2 --downscale <factor> <pkg>
#   Android <13 : cmd device_config put game_overlay <pkg> "mode=2,downscaleFactor=<factor>"
#                 + cmd game mode 2 <pkg>   (older two-step equivalent)
#
# DOWNSCALE FACTOR FORMAT: this API expects a decimal string like "0.5",
# "0.7", "0.9" - same format our WebUI already stores in resolution.txt,
# so no config migration needed.
#
# Usage: apply_resolution.sh <native|0.75|0.5|0.33|...> <package_name>

RES="$1"
PKG="$2"
MODDIR="/data/adb/modules/sweet_dreams"
LOGFILE="$MODDIR/boot.log"
STATE_FILE="$MODDIR/cortex/display/resolution_applied_pkg.txt"

log_res() { echo "[RESOLUTION] $1" | tee -a "$LOGFILE"; }

get_sdk() {
    _sdk=$(getprop ro.build.version.sdk 2>/dev/null)
    case "$_sdk" in
        ''|*[!0-9]*) echo "0" ;;
        *) echo "$_sdk" ;;
    esac
}

# Android 13+ (SDK 33): `cmd game set --downscale` is the per-app Game Mode
# intervention. Android 12 and older never shipped that subcommand — the
# documented two-step equivalent is device_config game_overlay + `cmd game
# mode 2`. get_sdk() existed but was never called, so <13 devices always
# took the 13+ path, logged a false "Applied", and never scaled.
restore_game_downscale() {
    _pkg="$1"
    _sdk="$(get_sdk)"
    if [ "$_sdk" -gt 0 ] && [ "$_sdk" -lt 33 ]; then
        cmd device_config delete game_overlay "$_pkg" >/dev/null 2>&1
        cmd game mode 1 "$_pkg" >/dev/null 2>&1
        BAK=$(cat "$MODDIR/cortex/display/wm_size_backup.txt" 2>/dev/null)
        if [ -n "$BAK" ]; then
            wm size "$BAK" >/dev/null 2>&1 || wm size reset >/dev/null 2>&1
            rm -f "$MODDIR/cortex/display/wm_size_backup.txt"
        fi
        log_res "Reset game_overlay for $_pkg (SDK $_sdk) - native resolution restored"
    else
        cmd game reset "$_pkg" >/dev/null 2>&1
        BAK=$(cat "$MODDIR/cortex/display/wm_size_backup.txt" 2>/dev/null)
        if [ -n "$BAK" ]; then
            wm size "$BAK" >/dev/null 2>&1 || wm size reset >/dev/null 2>&1
            rm -f "$MODDIR/cortex/display/wm_size_backup.txt"
        else
            wm size reset >/dev/null 2>&1
        fi
        log_res "Reset intervention for $_pkg - native resolution restored"
    fi
}

apply_game_downscale() {
    _res="$1"
    _pkg="$2"
    _sdk="$(get_sdk)"
    if [ "$_sdk" -gt 0 ] && [ "$_sdk" -lt 33 ]; then
        if cmd device_config put game_overlay "$_pkg" "mode=2,downscaleFactor=${_res}" >/dev/null 2>&1; then
            cmd game mode 2 "$_pkg" >/dev/null 2>&1
            log_res "Applied downscale=$_res for $_pkg via game_overlay (SDK $_sdk)"
            return 0
        fi
        log_res "WARNING: device_config game_overlay failed for $_pkg (SDK $_sdk) - downscale may not be active"
        return 1
    fi
    if cmd game set --downscale "$_res" "$_pkg" >/dev/null 2>&1; then
        log_res "Applied downscale=$_res for $_pkg via Game Mode API"
        return 0
    fi
    if cmd game set --mode 2 --downscale "$_res" "$_pkg" >/dev/null 2>&1; then
        log_res "Applied downscale=$_res for $_pkg via Game Mode --mode 2 --downscale"
        return 0
    fi
    cmd game mode 2 "$_pkg" >/dev/null 2>&1
    if cmd game set --downscale "$_res" "$_pkg" >/dev/null 2>&1; then
        log_res "Applied downscale=$_res for $_pkg after cmd game mode 2"
        return 0
    fi
    # Last resort: global wm size. Restored on native/game_end.
    PHYS=$(wm size 2>/dev/null | awk '/Physical size:/ {print $3; exit}')
    [ -z "$PHYS" ] && PHYS=$(wm size 2>/dev/null | awk '/size:/ {print $NF; exit}')
    W=${PHYS%x*}
    H=${PHYS#*x}
    case "$W$H" in
        ''|*[!0-9]*)
            log_res "WARNING: all Game Mode paths failed and wm size parse failed"
            return 1
            ;;
    esac
    # awk for float scale on toybox.
    SW=$(awk -v w="$W" -v s="$_res" 'BEGIN { printf "%d", w*s }')
    SH=$(awk -v h="$H" -v s="$_res" 'BEGIN { printf "%d", h*s }')
    if [ "$SW" -ge 240 ] && [ "$SH" -ge 240 ] && wm size "${SW}x${SH}" >/dev/null 2>&1; then
        echo "$PHYS" > "$MODDIR/cortex/display/wm_size_backup.txt"
        log_res "Applied wm size ${SW}x${SH} (from $PHYS) scale=$_res — Game Mode API unavailable"
        return 0
    fi
    log_res "WARNING: cmd game set and wm size both failed — downscale not active for $_pkg"
    return 1
}

# ----------------------------------------------------------------------------─
# CRITICAL, CONFIRMED-FROM-ANDROID'S-OWN-DOCS LIMITATION:
# "Reducing the resolution requires relaunching the app to be applied
# correctly" / "Make sure you restart the game after each game mode
# selection" - https://developer.android.com/games/gamemode/gamemode-interventions
#
# The downscale intervention is read by WindowManager ONLY at the moment
# an app's render surface is first created (cold start). Setting it while
# the target app is ALREADY the foreground/running process - which is
# exactly when game_monitor.sh was calling this, right after "Game ON" -
# has no visible effect until that process is killed and relaunched. This
# is Android's own documented behavior, not a bug in the command itself;
# our previous version applied the setting correctly but at the wrong
# moment in the app's lifecycle for it to ever take visual effect.
#
# FIX: this script now force-stops the target package immediately after
# setting the intervention, so Android relaunches it fresh with the new
# downscale factor already in effect from its very first frame - instead
# of setting a value that silently won't apply until some future,
# unpredictable relaunch the user has to trigger manually themselves.
# ----------------------------------------------------------------------------─

if [ "$RES" = "native" ] || [ -z "$RES" ]; then
    # -- Restore: revert whichever package we last applied to ----------------─
    LAST_PKG=$(cat "$STATE_FILE" 2>/dev/null)
    [ -z "$LAST_PKG" ] && [ -n "$PKG" ] && LAST_PKG="$PKG"

    if [ -n "$LAST_PKG" ]; then
        restore_game_downscale "$LAST_PKG"
    fi
    rm -f "$STATE_FILE" 2>/dev/null

else
    # -- Apply: scoped to exactly one package via Game Mode API --------------─
    if [ -z "$PKG" ]; then
        log_res "ERROR: no package specified, cannot apply per-app resolution scale"
        exit 1
    fi

    # Correct, current, non-deprecated syntax (the old `--mode 2 --downscale`
    # combined form is deprecated - "downscale" is now its own top-level
    # subcommand under `cmd game set`, confirmed against the current Game
    # Manager command reference, not just AZenith's C source which used an
    # older/different calling convention).
    # Bug fix: this used to swallow the exit status entirely
    # (`>/dev/null 2>&1` on the command, no check afterward) and log
    # "Applied" unconditionally regardless of whether the cmd dispatcher
    # actually accepted it. On a device where the `cmd game` service is
    # unreachable (confirmed via this device's own boot-time binder
    # readiness probe reporting game=0), every call here was silently
    # failing while the log claimed success - the WebUI and boot.log both
    # showed "Applied downscale=0.5" even though nothing changed on
    # screen. AZenith's own C implementation has this same blind-trust
    # gap (systemv()'s return value is never checked in
    # ResolutionChanger.c either) - checking it properly here is a real
    # improvement, not just parity.
    apply_game_downscale "$RES" "$PKG"
    echo "$PKG" > "$STATE_FILE"

    # Relaunch required - see the block comment above. Force-stop, THEN
    # relaunch via `am start -n <resolved-component>` - the exact same
    # mechanism AZenith's daemon uses (systemv "am force-stop %s && am
    # start -n $(cmd package resolve-activity --brief %s | tail -n 1)").
    #
    # This replaces a previous `monkey -p "$PKG" -c
    # android.intent.category.LAUNCHER 1` relaunch. monkey is a known
    # trouble spot on some MTK/Transsion (Infinix XOS and similar) ROMs -
    # it goes through the InputDispatcher/event-injection path rather than
    # a direct am start, and on this device family that path doesn't
    # reliably pick up a Game Mode intervention that was just applied
    # moments earlier. `am start -n` addresses the resolved launch
    # Activity directly, which is the same primitive Android's own
    # launcher uses and matches what a real cold-launch does.
    #
    # `cmd package resolve-activity` does route through the same `cmd`
    # dispatcher as the downscale call itself, so if that path is broken
    # on a given device this resolution will silently return nothing and
    # `am start -n` will fail as well - the RES_ACTIVITY capture below
    # falls back to `monkey` in that specific case so a broken `cmd`
    # dispatcher degrades to the previous (still-functional-for-launching,
    # just less state-correct) behavior instead of failing to relaunch at
    # all.
    #
    # Previous version force-stopped and stopped there, assuming the user
    # would just tap the game's icon again themselves - in practice that
    # reads as "the app randomly closed and didn't come back," which is a
    # broken experience, not a documented API limitation. Handling the
    # full relaunch here is the actual fix.
    #
    # GRACE FLAG: force-stopping here means the very next game_monitor.sh
    # loop tick would otherwise see the process gone and immediately log
    # "Game OFF" - undoing the intervention we JUST set (and every other
    # game_start effect: thermal blackout, touch profile, net tuning)
    # before the relaunch even completes. Write a timestamped flag
    # game_monitor.sh checks before declaring the game closed, so this
    # deliberate, expected restart isn't mistaken for the user actually
    # leaving the game. Grace window covers force-stop + relaunch + the
    # few seconds the app takes to come back up and get re-detected.
    echo "$(date +%s)" > "$MODDIR/cortex/display/resolution_relaunch_grace.txt"
    am force-stop "$PKG" >/dev/null 2>&1
    sleep 1
    RES_ACTIVITY=$(cmd package resolve-activity --brief "$PKG" 2>/dev/null | tail -n 1)
    if [ -n "$RES_ACTIVITY" ] && [ "$RES_ACTIVITY" != "No activity found" ]; then
        am start -n "$RES_ACTIVITY" >/dev/null 2>&1
        log_res "Restarted $PKG via am start -n $RES_ACTIVITY"
    else
        # cmd dispatcher didn't resolve an activity (broken on this device,
        # or genuinely no launcher activity) - fall back to monkey so the
        # app still comes back up even though this path is less reliable
        # for picking up the just-applied intervention on some ROMs.
        monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
        log_res "Restarted $PKG via monkey fallback (cmd package resolve-activity unavailable)"
    fi
    log_res "Restarted $PKG so the new resolution takes effect from its first frame"
fi

# No SystemUI force-stop needed anymore - the Game Mode API never touches
# global display state, so SystemUI never has stale metrics to begin with.
