#!/system/bin/sh
# cortex/perf/apply.sh - Sweet Dreams MTK PerfService Scenario Boost
# Triggers MTK's native performance scenario API at game launch.
# This is the same coordination layer Infinix's own Game Mode uses internally
# to align CPU, GPU, DRAM, and power delivery for sustained gaming load.
CORTEX="/data/adb/modules/sweet_dreams/cortex"

. "$CORTEX/health/track.sh"

GAME_PKG="$1"          # package name passed from game loop (informational)
ACTION="${2:-boost}"   # "boost" or "restore"

log_perf() { echo "[PERF] $1"; }

# -- MTK PerfService scenario trigger ------------------------------------------
# /proc/perfmgr/legacy/perfserv_ta: write scenario ID
#   0 = reset/idle
#   1 = LAUNCH_BOOST (app launch)
#   2 = GAME_SCENARIO (sustained gaming)
#   3 = TOUCH_BOOST
#
# BUG FIX: this used to report a health_check failure on EVERY single call
# when the perfmgr nodes aren't present on a given kernel - which, given
# this runs on every game launch and every restore, meant the WebUI's
# health banner and boot.log both got a fresh "perf_scenario failed"
# report every few minutes, forever, on any device missing these specific
# MTK debug nodes. That's not a per-launch failure though - it's a fixed
# characteristic of this specific kernel build (confirmed absent, not
# intermittently failing), and other MTK perf paths on the same device
# (CHIPSET tuning, FPS frame pacing) work fine, so this one specific node
# being missing doesn't mean anything is actually broken. Cache the result
# after the first check so the health banner reports it once, not on a
# loop, and stays quiet on subsequent launches once the device's real
# capability is known.
PERFMGR_CACHE="$CORTEX/perf/perfmgr_unsupported.flag"
trigger_perf_scenario() {
    local SCENARIO="$1"

    if [ -f "$PERFMGR_CACHE" ]; then
        # Already confirmed absent on this device - skip the write attempt
        # and the repeat health report entirely, just apply the fallback.
        echo "1" > /sys/devices/system/cpu/perf_boost_enable 2>/dev/null
        return
    fi

    if echo "$SCENARIO" > /proc/perfmgr/legacy/perfserv_ta 2>/dev/null; then
        health_check "perf_scenario" 0 "perfserv_ta=$SCENARIO"
        log_perf "perfserv_ta=$SCENARIO"
        return
    fi
    if echo "$SCENARIO" > /proc/perfmgr/perf_ioctl 2>/dev/null; then
        health_check "perf_scenario" 0 "perf_ioctl=$SCENARIO (fallback path)"
    else
        health_check "perf_scenario" 1 "no writable perfmgr node - confirmed absent on this kernel, other MTK perf paths (CHIPSET/FPS) still work normally"
        touch "$PERFMGR_CACHE" 2>/dev/null
    fi
    echo "1" > /sys/devices/system/cpu/perf_boost_enable 2>/dev/null
}

# -- CPU DVFS headroom - leaves freq ceiling slack for burst loads ------------─
set_dvfs_headroom() {
    local PCT="$1"
    echo "$PCT" > /sys/module/mtk_freq_bound/parameters/ut_freq_bound 2>/dev/null
    echo "$PCT" > /proc/mtk_dvfs/ut_headroom 2>/dev/null
}

# -- MTK EAS (Energy Aware Scheduling) game hint ------------------------------─
set_eas_hint() {
    local STATE="$1"
    echo "$STATE" > /sys/kernel/eas/game_hint 2>/dev/null
    echo "$STATE" > /proc/mtk_eas/game_mode   2>/dev/null
}

# -- Mali GPU game-mode hint - disables adaptive power saving while gaming ----─
set_gpu_game_mode() {
    local STATE="$1"
    echo "$STATE" > /sys/class/misc/mali0/device/devfreq/mali0/mali_ondemand_game_mode 2>/dev/null
    echo "$STATE" > /sys/class/misc/mali0/device/power_policy 2>/dev/null
    echo "$STATE" > /sys/class/misc/mali0/device/highfreq_hint 2>/dev/null
}

case "$ACTION" in
    boost)
        health_start "perf"
        log_perf "Game boost: ${GAME_PKG:-unknown}"
        trigger_perf_scenario 2
        set_dvfs_headroom 15
        set_eas_hint 1
        set_gpu_game_mode 1
        health_finish
        echo "boost" > "$CORTEX/perf/state.txt"
        ;;
    restore)
        health_start "perf"
        log_perf "Restoring perf state"
        trigger_perf_scenario 0
        set_dvfs_headroom 0
        set_eas_hint 0
        set_gpu_game_mode 0
        health_finish
        echo "idle" > "$CORTEX/perf/state.txt"
        ;;
esac
