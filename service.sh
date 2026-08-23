#!/system/bin/sh
MODDIR="/data/adb/modules/sweet_dreams"
CORTEX="$MODDIR/cortex"
LOGFILE="$MODDIR/boot.log"

# Bug fix: the two boot-log lines below used to hardcode "v1.9.2" as a
# literal string, so every log from v1.9.3 onward kept claiming to be
# v1.9.2 - completely useless for correlating a bug report against the
# actual version running. Read it from module.prop instead, which is the
# one place the version is guaranteed correct (customize.sh/the packaging
# process is what keeps it up to date).
MOD_VERSION=$(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2-)
[ -z "$MOD_VERSION" ] && MOD_VERSION="unknown"
# See cortex/fps/engine.sh for why this exists - `settings put` is a thin
# wrapper around the `cmd` dispatcher, which is blocked by a known,
# non-timing-related class of issue on some devices; `content update` is a
# different IPC path worth attempting alongside it.
settings_put() {
    if ! grep -qx "CMD_DISPATCHER_UNRELIABLE" "$CORTEX/device/active.txt" 2>/dev/null; then
        settings put "$1" "$2" "$3" >/dev/null 2>&1
    fi
    content update --uri content://settings/"$1" --bind value:s:"$3" --where "name='$2'" >/dev/null 2>&1
}

rm -f "$LOGFILE"
log_p() { echo "[$(date '+%H:%M:%S')] $1" >> "$LOGFILE"; }

# Restore WebUI settings saved outside the module (survives zip updates).
sh "$CORTEX/persist.sh" restore 2>/dev/null
log_p "Persisted settings restored"

until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done

# -- Wait for SystemServer's binder services to actually accept transactions --
# sys.boot_completed=1 fires before all framework services finish registering,
# so this loop is still worth keeping - but the "Failed transaction
# (2147483646)" error itself turned out NOT to be a not-ready-yet timing
# issue on every device. On this module's original test device it persisted
# for the entire session, including hours after boot, on every `cmd`-family
# call (settings/window/activity/package/game) - confirmed via `getenforce`
# returning Enforcing, matching a known SELinux restriction on the `cmd`
# dispatcher's IPC path specifically (raw `service call` isn't affected -
# see fps/engine.sh's header comment for the full story). This loop still
# has real value for genuinely slow-booting devices; it just isn't the
# whole explanation for this error on every device.
WAIT_TRIES=0
while [ "$WAIT_TRIES" -lt 20 ]; do
    SETTINGS_OK=0; PACKAGE_OK=0; GAME_OK=0
    cmd settings get global airplane_mode_on >/dev/null 2>&1 && SETTINGS_OK=1
    pm path android >/dev/null 2>&1 && PACKAGE_OK=1
    cmd game list >/dev/null 2>&1 && GAME_OK=1
    # Bug fix: this loop's break condition used to require GAME_OK too. On
    # devices/ROMs where the "game" service either doesn't exist or isn't
    # exposed to shell (confirmed on this Infinix/XOS build - GAME_OK never
    # went to 1 across the full 20s window in testing), that meant every
    # single boot burned its entire 20s timeout here for nothing, since
    # settings+package were almost always ready within 1-3s. Game readiness
    # is still polled and logged below for visibility, just no longer
    # blocks the rest of boot.
    if [ "$SETTINGS_OK" = "1" ] && [ "$PACKAGE_OK" = "1" ]; then
        break
    fi
    sleep 1
    WAIT_TRIES=$((WAIT_TRIES + 1))
done
sleep 1
log_p "Early binder readiness: settings=$SETTINGS_OK package=$PACKAGE_OK game=$GAME_OK (waited ${WAIT_TRIES}s)"

# -- Device mitigations --------------------------------------------------------─
# Shell port of Encore Tweaks' DeviceMitigationStore concept (Apache-2.0,
# github.com/rem01gaming/encore) - gathers device identity, checks it against
# editable rules, and adds an empirical probe for the cmd-dispatcher issue
# specifically (see cortex/device/evaluate_mitigations.sh for the full
# reasoning). Any script in this module can check
# `grep -qx "ITEM_NAME" "$CORTEX/device/active.txt"` to adapt behavior for a
# known-quirky device without needing a code change for every new one.
sh "$CORTEX/device/gather_info.sh" 2>/dev/null
sh "$CORTEX/device/evaluate_mitigations.sh" 2>/dev/null

# Conflict detection - runs every boot (not one-time like the capability
# probe) since which modules are installed can change between any two
# boots. Backgrounded since nothing else depends on its result at boot
# time; the WebUI reads it whenever it's ready.
sh "$CORTEX/device/check_conflicts.sh" >> "$LOGFILE" 2>&1 &

# One-time capability probe - see capability_probe.sh header for full
# rationale. Backgrounded since none of its individual checks are needed
# for boot to proceed; the WebUI reads its result file whenever it's ready.
sh "$CORTEX/device/capability_probe.sh" >> "$LOGFILE" 2>&1 &
ACTIVE_MITIGATIONS=$(cat "$CORTEX/device/active.txt" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
log_p "Device mitigations active: ${ACTIVE_MITIGATIONS:-none}"

log_p "Boot - Sweet Dreams $MOD_VERSION"
# Every "cmd: Failure calling service X: Failed transaction (2147483646)"
# throughout this log is consistent with a known, documented, non-timing
# class of issue where SELinux blocks the `cmd` dispatcher's IPC path
# specifically (raw `service call` still works - see the one successful
# SurfaceFlinger call elsewhere in this log). Logging this directly instead
# of asking for a separate manual `getenforce` check every time.
SELINUX_STATE=$(getenforce 2>/dev/null || echo "unknown")
log_p "SELinux: $SELINUX_STATE"

find "$MODDIR/system/bin" -type f ! -name "*.txt" ! -name "*.webp" -exec chmod 0755 {} \;
find "$CORTEX" -name "*.sh" -exec chmod 0755 {} \;
chmod 0755 "$MODDIR/controller" 2>/dev/null
chmod 0644 "$MODDIR/COPG.json" 2>/dev/null
chcon u:object_r:system_file:s0 "$MODDIR/COPG.json" 2>/dev/null

# Bug fix: this used to call thermal/apply.sh with no phase argument,
# which hits the same "" case the WebUI's manual Thermal Spoof toggle
# uses to arm immediately - meaning every boot blacked out every temp
# sensor (including battery), system-wide, permanently, regardless of
# whether Thermal Spoof was even armed in status.txt (status.txt=
# "disabled" means the STOCK daemon is disabled, i.e. spoofing is armed -
# see webroot's toggleThermal() for the same inverted-naming note) and
# regardless of whether a game was ever launched. That directly
# contradicted what both the WebUI's toast ("Armed - activates when a
# game launches") and its explainer text promise - the code and the
# UI's own description of it had drifted apart.
#
# Stopping the vendor thermal daemons at boot is still correct
# unconditionally - this module's own cpu/gpu/thermal tuning above
# replaces them regardless of Thermal Spoof being armed, so leaving the
# stock daemon running would just fight it. But blinding any sensor node
# should never happen here - only game_monitor.sh's game_start call
# should do that, and only when status.txt is actually "disabled"
# (armed). This restores the boot-time call to daemon-stop only, so a
# fresh boot with Thermal Spoof armed leaves sensors reading real values
# until the first game actually launches, matching the UI's promise.
sh "$CORTEX/thermal/kill_daemons_only.sh" >> "$LOGFILE" 2>&1 && log_p "Thermal daemons stopped (sensors untouched until a game actually launches)"
sh "$CORTEX/cpu/apply.sh"      >> "$LOGFILE" 2>&1 && log_p "CPU done"
sh "$CORTEX/gpu/apply.sh"      >> "$LOGFILE" 2>&1 && log_p "GPU done"
sh "$CORTEX/net/apply.sh"      >> "$LOGFILE" 2>&1 && log_p "Net done"
sh "$CORTEX/sched/apply.sh"    >> "$LOGFILE" 2>&1 && log_p "Sched done"

sh "$CORTEX/chipset/engine.sh" activate >> "$LOGFILE" 2>&1
log_p "Chipset tuning done"

TARGET_FPS=$(cat "$CORTEX/display/fps.txt" 2>/dev/null || echo "90")
sh "$CORTEX/fps/engine.sh" "$TARGET_FPS" >> "$LOGFILE" 2>&1
log_p "FPS engine done"

SPOOF_ON=$(cat "$CORTEX/games/spoof_master.txt" 2>/dev/null || echo "off")
if [ "$SPOOF_ON" = "on" ]; then
    sh "$CORTEX/games/build_spoof_json.sh" >> "$LOGFILE" 2>&1
    log_p "Spoof JSON built"
    # Apply global prop spoof as fallback for apps that read props before Zygisk hooks
    sh "$CORTEX/games/spoof.sh" >> "$LOGFILE" 2>&1
    log_p "Global prop spoof applied"
    # Kill any stale controller, wait for it to die, then relaunch (Bug 4 - race condition)
    pkill -f "$MODDIR/controller" 2>/dev/null
    sleep 1
    nohup "$MODDIR/controller" > /dev/null 2>&1 &
    log_p "LGTL Spoof Engine PID $!"
else
    # Master off - ensure props are restored to real device values
    sh "$CORTEX/games/spoof.sh" >> "$LOGFILE" 2>&1
fi

until [ "$(getprop init.svc.bootanim)" = "stopped" ]; do sleep 2; done
sleep 5
log_p "System settled"

# The previous wait here polled sys.db.initialized - that prop is specific
# to telephony/contacts provider DB init, not a general signal that binder
# services are ready, and it was hitting its 60s timeout and proceeding
# anyway on this device, which is exactly why window/activity/game/settings
# calls right after this point were still failing with "Failed transaction
# (2147483646)". Replaced with a direct check on the actual services this
# script calls below (settings, window, activity, game), each polled up to
# 20s - short-circuits the moment all four respond instead of either
# guessing a fixed sleep or waiting on an unrelated prop.
WAIT=0
while [ "$WAIT" -lt 20 ]; do
    S_OK=0; W_OK=0; A_OK=0; G_OK=0
    cmd settings get global airplane_mode_on >/dev/null 2>&1 && S_OK=1
    dumpsys window displays >/dev/null 2>&1 && W_OK=1   # read-only, confirms WindowManager binder is up
    dumpsys activity activities >/dev/null 2>&1 && A_OK=1
    cmd game list >/dev/null 2>&1 && G_OK=1
    # Same fix as the early readiness loop above: don't gate on G_OK, since
    # on this device it never comes up and would otherwise burn the full
    # 20s here too - 40s of pure wasted boot time across both loops before
    # this fix, for a service this ROM apparently doesn't expose to shell.
    if [ "$S_OK" = "1" ] && [ "$W_OK" = "1" ] && [ "$A_OK" = "1" ]; then
        break
    fi
    sleep 1
    WAIT=$((WAIT + 1))
done
log_p "Binder readiness: settings=$S_OK window=$W_OK activity=$A_OK game=$G_OK (waited ${WAIT}s)"
# Persist the final game-service reading so cortex/fps/engine.sh can skip
# its `cmd game mode ...` calls entirely instead of calling them every
# single time and eating a guaranteed "Failed transaction" - see its
# header comment for the full story (this is also why 22 near-identical
# Parcel errors showed up in the log on every game launch: sensor/apply.sh
# has the exact same problem, see its own comment for that one).
echo "$G_OK" > "$CORTEX/fps/has_game_service.txt"

settings_put system pointer_speed 0
settings_put secure long_press_timeout "$(cat "$CORTEX/touch/lp_timeout.txt" 2>/dev/null || echo 400)"
settings_put secure multi_press_timeout 300
settings_put system peak_refresh_rate "$TARGET_FPS"
settings_put system min_refresh_rate 60
log_p "System settings applied"

ANIM=$(cat "$CORTEX/display/anim_scale.txt" 2>/dev/null || echo "0.5")
settings_put global window_animation_scale "$ANIM"
settings_put global transition_animation_scale "$ANIM"
settings_put global animator_duration_scale "$ANIM"

log_p "Display done"

sh "$CORTEX/touch/apply.sh" >> "$LOGFILE" 2>&1 && log_p "Touch done"

sh "$CORTEX/display/apply.sh" >> "$LOGFILE" 2>&1 && log_p "Display RR/lock done"

sh "$CORTEX/ram/apply.sh" >> "$LOGFILE" 2>&1 && log_p "RAM management applied"

sh "$CORTEX/battery/apply.sh" >> "$LOGFILE" 2>&1 && log_p "Battery charge limiter applied"

# -- Battery watchdog daemon --------------------------------------------------─
# Re-checks charge state every 60s - re-applies cap if it drifted (some MTK
# firmware resets the slate_mode node on charger plug/unplug events)
(
BAT_CFG="$CORTEX/battery"
while true; do
    LIMIT_EN=$(cat "$BAT_CFG/limit_enabled.txt" 2>/dev/null || echo "off")
    if [ "$LIMIT_EN" = "on" ]; then
        sh "$CORTEX/battery/apply.sh" 2>/dev/null
    fi
    sleep 60
done
) &

# -- RAM watchdog daemon --------------------------------------------------------
# Runs every 30s idle / 10s during gaming
# - Drops caches when free RAM < threshold
# - Updates status.txt for WebUI live gauge
# - Trims app heaps via ActivityManager
(
RAM_CFG="$CORTEX/ram"
while true; do
    MODE=$(cat "$RAM_CFG/mode.txt" 2>/dev/null || echo "balanced")
    FREE_KB=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    FREE_MB=$((FREE_KB / 1024))
    TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    TOTAL_MB=$((TOTAL_KB / 1024))
    ZRAM_EN=$(cat "$RAM_CFG/zram_enabled.txt" 2>/dev/null || echo "on")
    ZRAM_SIZE=$(cat "$RAM_CFG/zram_size.txt" 2>/dev/null || echo "2")
    COMP=$(cat "$RAM_CFG/compressor.txt" 2>/dev/null || echo "lz4")

    # ZRAM usage - /proc/swaps reports Size/Used in KB already (not 4KB
    # pages), so this used to be off by 4x. The $4/$3 fields don't need a
    # *4 multiplier before converting to MB.
    SWAP_USED_KB=$(awk '/zram/ {print $4}' /proc/swaps 2>/dev/null | head -1)
    SWAP_USED_MB=$(( (${SWAP_USED_KB:-0}) / 1024 ))
    SWAP_TOTAL_KB=$(awk '/zram/ {print $3}' /proc/swaps 2>/dev/null | head -1)
    SWAP_TOTAL_MB=$(( (${SWAP_TOTAL_KB:-0}) / 1024 ))

    # Write live status for WebUI - pipe-separated
    echo "${MODE}|${TOTAL_MB}|${FREE_MB}|${ZRAM_EN}|${ZRAM_SIZE}|${COMP}|${SWAP_USED_MB}|${SWAP_TOTAL_MB}" \
        > "$RAM_CFG/status.txt"

    # Thresholds differ by mode
    case "$MODE" in
        gaming)       LOW_MB=600  ; CRIT_MB=350  ;;
        balanced)     LOW_MB=400  ; CRIT_MB=200  ;;
        memory_saver) LOW_MB=300  ; CRIT_MB=150  ;;
        *)            LOW_MB=400  ; CRIT_MB=200  ;;
    esac

    if [ "$FREE_MB" -lt "$CRIT_MB" ]; then
        # Critical - drop caches + trim all app heaps
        sync
        echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
        cmd activity send-trim-memory 0 COMPLETE >/dev/null 2>&1
        am send-trim-memory 0 2>/dev/null || true
    elif [ "$FREE_MB" -lt "$LOW_MB" ]; then
        # Low - drop page cache only
        sync
        echo 1 > /proc/sys/vm/drop_caches 2>/dev/null
    fi

    # Check if game running - faster poll during gaming
    SELECTED=$(cat "$CORTEX/games/selected.txt" 2>/dev/null || echo "")
    IN_GAME=0
    for PKG in $SELECTED; do
        [ -z "$PKG" ] && continue
        for PID in $(pidof "$PKG" 2>/dev/null); do
            ST=$(awk '{print $3}' "/proc/$PID/stat" 2>/dev/null)
            if [ -n "$ST" ] && [ "$ST" != "Z" ] && [ "$ST" != "X" ]; then
                IN_GAME=1
                break 2
            fi
        done
    done

    [ "$IN_GAME" = "1" ] && sleep 10 || sleep 30
done
) &

# Frieren_Thermal/Frieren_AI_Games are closed-source binaries written for
# Qualcomm hardware (kgsl-3d0, msm_thermal) that mostly no-op on this MTK
# device. cortex/thermal/apply.sh already disables thermal-engine correctly
# for this SoC, so the Frieren_Thermal call here was redundant - removed.
# -- Stale intervention safety net ------------------------------------------─
# WHY THIS EXISTS: apply_resolution.sh writes resolution_applied_pkg.txt the
# moment a downscale/FPS-cap intervention is applied, and only clears it on
# a clean game_end (see restore_resolution_target in apply_resolution.sh).
# If the daemon that would have called that clean exit gets killed instead
# of exiting normally - OOM killer, a crash, the user force-stopping the
# module process, a bad update replacing the daemon mid-session - nothing
# ever runs the restore, and the file (and the actual live Game Mode
# intervention on that package) stays stuck. The daemon's own game_monitor
# loop can't defend against this: a trap can't catch SIGKILL, which is
# exactly the signal an OOM kill sends. The only reliable place to catch
# "did we boot into a dirty state" is right here, before anything new
# starts, checking whether last session's state file still points at a
# package whose intervention was never torn down.
if [ -f "$CORTEX/display/resolution_applied_pkg.txt" ]; then
    STALE_PKG=$(cat "$CORTEX/display/resolution_applied_pkg.txt" 2>/dev/null)
    if [ -n "$STALE_PKG" ]; then
        log_p "Stale resolution intervention found for $STALE_PKG from a previous session - resetting"
        cmd game reset --mode 2 "$STALE_PKG" >/dev/null 2>&1
        cmd device_config delete game_overlay "$STALE_PKG" >/dev/null 2>&1
        cmd game reset "$STALE_PKG" >/dev/null 2>&1
        rm -f "$CORTEX/display/resolution_applied_pkg.txt"
    fi
fi

mkdir -p "$MODDIR/run"
pkill -f "$CORTEX/ai/engine.sh" 2>/dev/null
nohup sh "$CORTEX/ai/engine.sh" >> "$LOGFILE" 2>&1 &
log_p "Sweet Dreams Engine PID $!"

mkdir -p "$MODDIR/run"
nohup sh "$CORTEX/daemons/game_monitor.sh" >> "$LOGFILE" 2>&1 &
log_p "OOM Watcher / Game Monitor PID $!"

log_p "Sweet Dreams $MOD_VERSION fully running"
