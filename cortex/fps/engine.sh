#!/system/bin/sh
# cortex/fps/engine.sh - Sweet Dreams FPS Engine (native replacement for Frieren_FPS)
#
# Frieren_FPS is a closed-source binary. We pulled its full string table to
# reverse-engineer exactly what it touches (SF phase offsets, HWUI render
# thread props, cpu_boost touch params, ADPF game_overlay device_config,
# foreground-package detection, a refresh-rate backup/restore file) and
# reimplemented every legitimate piece of it here in shell, where we can
# read, audit, and modify it ourselves.
#
# THINGS WE DELIBERATELY DID NOT CARRY OVER, because the binary's string
# table revealed they aren't display tuning at all:
#   - `su 2000 -c 'cmd notification post ... FrierenAI ...'` - posts a fake
#     branded system notification. Not something this module should do.
#   - References to a third-party app `bellavita.toast` and a Shizuku
#     fallback for privilege escalation - outside this module's scope and
#     not something we want silently shelling out to.
#   - A webp asset path under another module's plugin folder - irrelevant
#     here, looked like leftover boilerplate from a template the original
#     binary was built from.
#
# Usage:
#   engine.sh <fps>        - apply full frame-pacing tuning at <fps>
#   engine.sh <fps> game    - same, plus registers the ADPF game_overlay
#                             hint for the given foreground package
#   engine.sh restore       - undo every prop this script sets, back to
#                             AOSP/vendor defaults

MODDIR="/data/adb/modules/sweet_dreams"
CORTEX="$MODDIR/cortex"
# `settings put` is a thin wrapper around `cmd settings put` - on a device
# where the `cmd` dispatcher's IPC path is blocked (matches a known,
# documented, non-timing-related class of issue - see
# https://github.com/termux/termux-app/issues/1209 and similar), it fails
# every time regardless of retries. `content update` goes through the
# ContentProvider/ContentResolver binder path instead, a genuinely different
# mechanism - worth attempting alongside, not instead of, in case one path
# works where the other doesn't. Assumes the row already exists (true for
# every key this module writes - they're all core, pre-existing settings).
settings_put() {
    if ! grep -qx "CMD_DISPATCHER_UNRELIABLE" "$CORTEX/device/active.txt" 2>/dev/null; then
        settings put "$1" "$2" "$3" >/dev/null 2>&1
    fi
    content update --uri content://settings/"$1" --bind value:s:"$3" --where "name='$2'" >/dev/null 2>&1
}
# Bug fix: apply_frame_pacing()/restore_defaults() below used to call
# `cmd game mode ...` unconditionally on every single invocation. On a
# device/ROM where the "game" service isn't exposed to shell - confirmed on
# this Infinix/XOS build via service.sh's own boot-time binder readiness
# poll, which showed game=0 across the full wait window on every boot -
# that's not an occasional failure, it's a guaranteed one, every time,
# forever. service.sh now probes this once at boot and writes the result
# here instead of everyone re-discovering it the hard way on every call.
HAS_GAME_SERVICE=$(cat "$CORTEX/fps/has_game_service.txt" 2>/dev/null || echo "1")
FPS_CFG="$CORTEX/fps"
FRPERF="/data/local/tmp/Frieren_Perf"
BACKUP_FILE="$FRPERF/fps_backup/refresh_rate.txt"

ARG1="$1"
ARG2="$2"

log_fps() { echo "[FPS] $1"; }

get_foreground_package() {
    dumpsys activity activities 2>/dev/null \
        | grep -E "topResumedActivity|ResumedActivity" \
        | head -1 \
        | grep -oE '[a-zA-Z0-9_.]+/[a-zA-Z0-9_.]+' \
        | head -1 \
        | cut -d/ -f1
}

# -- back up current peak/min refresh rate once, before we touch anything ----─
backup_refresh_rate() {
    [ -f "$BACKUP_FILE" ] && return  # already have one, don't overwrite with our own values
    mkdir -p "$FRPERF/fps_backup"
    {
        settings get system peak_refresh_rate
        settings get system min_refresh_rate
    } > "$BACKUP_FILE" 2>/dev/null
}

apply_frame_pacing() {
    local FPS="$1"

    # -- SurfaceFlinger phase offsets ------------------------------------------
    # These control when SF latches each frame relative to vsync. Tighter
    # (smaller) offsets reduce input-to-photon latency at the cost of being
    # more sensitive to frame-time jitter - acceptable trade for gaming.
    resetprop debug.sf.early_phase_offset_ns          500000  2>/dev/null
    resetprop debug.sf.early_app_phase_offset_ns       500000  2>/dev/null
    resetprop debug.sf.early_gl_phase_offset_ns        3000000 2>/dev/null
    resetprop debug.sf.high_fps_early_phase_offset_ns  500000  2>/dev/null
    resetprop debug.sf.high_fps_late_app_phase_offset_ns 500000 2>/dev/null
    resetprop debug.sf.late_app_phase_offset_ns        500000  2>/dev/null
    resetprop debug.sf.use_phase_offsets_as_durations  1       2>/dev/null
    resetprop debug.sf.enable_frame_rate_pacing        1       2>/dev/null
    # debug.sf.disable_backpressure + debug.sf.latch_unsignaled together let
    # the app race ahead of SF and force SF to use frames before their GPU
    # fence is fully signaled - shaves a little input latency at the cost of
    # consistent frame timing, which shows up as exactly the stutter/FPS-drop
    # symptom this is meant to prevent. Backpressure is what keeps frame
    # production paced to what the display can actually consume; leaving it
    # OFF AND unsignaled-latch ON was fighting our own frame pacing goal.
    # Left at system default (enabled) instead of forcing either way.
    resetprop debug.sf.predict_hwc_composition_strategy 1       2>/dev/null
    resetprop debug.sf.enable_hwc_vds                   0       2>/dev/null

    # -- HWUI render thread ----------------------------------------------------
    resetprop debug.hwui.render_thread          1     2>/dev/null
    resetprop debug.hwui.use_partial_updates    true  2>/dev/null
    resetprop debug.hwui.use_buffer_age         true  2>/dev/null
    resetprop debug.hwui.skip_empty_damage      true  2>/dev/null
    resetprop debug.hwui.render_dirty_regions   true  2>/dev/null
    resetprop debug.hwui.enable_frame_rate_limit "$FPS" 2>/dev/null
    resetprop debug.hwui.fps_divisor            1     2>/dev/null

    # -- Input / touch responsiveness ------------------------------------------
    resetprop debug.input.low_latency  true 2>/dev/null
    resetprop touch.pressure.scale     1.0  2>/dev/null
    resetprop windowsmgr.max_events_per_sec "$FPS" 2>/dev/null
    # cpu_boost kernel module isn't present on every device (confirmed absent
    # on this kernel - "nonexistent directory" on every call). Check once
    # rather than attempting blind writes that always fail here.
    if [ -d /sys/module/cpu_boost/parameters ]; then
        echo "1"  > /sys/module/cpu_boost/parameters/input_boost_enabled     2>/dev/null
        echo "40" > /sys/module/cpu_boost/parameters/input_boost_ms          2>/dev/null
        echo "40" > /sys/module/cpu_boost/parameters/dynamic_stune_boost_ms  2>/dev/null
    fi

    # -- Scheduler --------------------------------------------------------------
    sysctl -w kernel.sched_child_runs_first=0    2>/dev/null
    sysctl -w kernel.sched_latency_ns=6000000    2>/dev/null
    sysctl -w kernel.sched_migration_cost_ns=5000000 2>/dev/null
    [ -e /proc/sys/kernel/sched_cfs_boost ] && echo "1" > /proc/sys/kernel/sched_cfs_boost 2>/dev/null

    # -- Display refresh + vsync ----------------------------------------------─
    resetprop debug.egl.swapinterval -1 2>/dev/null
    settings_put system peak_refresh_rate "$FPS"

    # -- ADPF / power HAL hints ------------------------------------------------
    # Android's real Game Mode Intervention API - same one the system's own
    # Game Dashboard uses. mode=2 is PERFORMANCE.
    resetprop persist.vendor.powerhal.adpf 1            2>/dev/null
    resetprop persist.vendor.powerhal.fpsstabilizer "$FPS" 2>/dev/null
    [ "$HAS_GAME_SERVICE" = "1" ] && cmd game mode performance "$(get_foreground_package)" >/dev/null 2>&1

    log_fps "Frame pacing applied for ${FPS} fps"
}

apply_adpf_overlay() {
    local FPS="$1"
    local PKG
    PKG=$(get_foreground_package)
    [ -z "$PKG" ] && return
    # Bug fix: this used to call `device_config put` unconditionally on
    # every single tick regardless of device. `device_config` goes through
    # the exact same `cmd` dispatcher IPC path as `settings put` - on a
    # device where that path is broken (see CMD_DISPATCHER_UNRELIABLE
    # above, and settings_put()'s use of the same flag), every single call
    # here was guaranteed to fail with "Failed transaction", logged at full
    # volume every ~10-15s for the entire duration of every game session.
    # There's no ContentProvider equivalent for device_config (unlike
    # settings, which has the content:// fallback), so on a device with
    # this mitigation active we just skip it - the ADPF hint is a nice-to-have
    # for supported devices, not a required step, and this device's own
    # boot probe already told us the dispatcher doesn't work here.
    if ! grep -qx "CMD_DISPATCHER_UNRELIABLE" "$CORTEX/device/active.txt" 2>/dev/null; then
        device_config put game_overlay "$PKG" "mode=2,fps=${FPS}" 2>/dev/null
    fi
    log_fps "ADPF game overlay: ${PKG} @ ${FPS} fps"
}

restore_defaults() {
    for P in \
        debug.sf.early_phase_offset_ns debug.sf.early_app_phase_offset_ns \
        debug.sf.early_gl_phase_offset_ns debug.sf.high_fps_early_phase_offset_ns \
        debug.sf.high_fps_late_app_phase_offset_ns debug.sf.late_app_phase_offset_ns \
        debug.sf.use_phase_offsets_as_durations debug.sf.enable_frame_rate_pacing \
        debug.sf.disable_backpressure debug.sf.enable_gl_backpressure \
        debug.sf.latch_unsignaled debug.sf.predict_hwc_composition_strategy \
        debug.sf.enable_hwc_vds debug.hwui.render_thread debug.hwui.use_partial_updates \
        debug.hwui.use_buffer_age debug.hwui.skip_empty_damage debug.hwui.render_dirty_regions \
        debug.hwui.enable_frame_rate_limit debug.hwui.fps_divisor debug.input.low_latency \
        touch.pressure.scale windowsmgr.max_events_per_sec debug.egl.swapinterval \
        persist.vendor.powerhal.adpf persist.vendor.powerhal.fpsstabilizer; do
        resetprop --delete "$P" 2>/dev/null
    done

    [ -d /sys/module/cpu_boost/parameters ] && echo "0" > /sys/module/cpu_boost/parameters/input_boost_enabled 2>/dev/null
    sysctl -w kernel.sched_child_runs_first=1 2>/dev/null

    [ "$HAS_GAME_SERVICE" = "1" ] && cmd game mode standard "$(get_foreground_package)" >/dev/null 2>&1

    if [ -f "$BACKUP_FILE" ]; then
        local PEAK MIN
        PEAK=$(sed -n '1p' "$BACKUP_FILE" 2>/dev/null)
        MIN=$(sed -n '2p' "$BACKUP_FILE" 2>/dev/null)
        [ -n "$PEAK" ] && settings_put system peak_refresh_rate "$PEAK"
        [ -n "$MIN" ]  && settings_put system min_refresh_rate  "$MIN"
    fi

    log_fps "Restored to defaults"
}

case "$ARG1" in
    restore)
        restore_defaults
        ;;
    ''|*[!0-9]*)
        echo "Usage: engine.sh <fps 1-240> [game] | restore" >&2
        exit 1
        ;;
    *)
        if [ "$ARG1" -lt 1 ] || [ "$ARG1" -gt 240 ]; then
            log_fps "Invalid FPS ($ARG1), ignoring"
            exit 1
        fi
        backup_refresh_rate
        apply_frame_pacing "$ARG1"
        [ "$ARG2" = "game" ] && apply_adpf_overlay "$ARG1"
        ;;
esac
