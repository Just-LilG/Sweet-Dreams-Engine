#!/system/bin/sh
# cortex/ai/engine.sh - Sweet Dreams Engine (native replacement for Frieren_AI_Games)
#
# WHY THIS EXISTS: the bundled Frieren_* binaries are closed-source ARM64
# executables written against Qualcomm sysfs paths (kgsl-3d0, msm_thermal).
# This is a MediaTek Helio G200 device - those paths don't exist here, so
# most of what Frieren_AI_Games and Frieren_Battery touch silently no-ops.
# Every lever that actually works on this SoC is already implemented
# correctly in cortex/cpu, cortex/gpu, cortex/thermal, cortex/ram - this
# engine is a thin supervisor that reads live telemetry and calls THOSE
# scripts, rather than poking sysfs directly itself. One source of truth.
#
# WHAT IT DOES:
#   - Polls battery temp, RAM pressure, and CPU throttle state every 5s
#   - Logs a single status line each cycle for the WebUI/Logs tab to read
#   - If conditions cross a hard safety threshold (overheating, critical
#     RAM), TEMPORARILY overrides the active profile to `battery` to let
#     the device recover, then automatically reverts to the user's actual
#     saved profile once things are back to normal - never leaves the
#     override in place silently.
#   - Never touches sysfs nodes directly; only ever calls the existing
#     cortex/*/apply.sh scripts so there is exactly one implementation of
#     "what battery mode means" etc.

MODDIR="/data/adb/modules/sweet_dreams"
CORTEX="$MODDIR/cortex"
AI_CFG="$CORTEX/ai"
BAT_CFG="$CORTEX/battery"
RUNDIR="$MODDIR/run"
LOGFILE="$MODDIR/boot.log"

mkdir -p "$RUNDIR"
echo "$$" > "$RUNDIR/ai_engine.pid"

log_ai() { echo "[AI] $1" >> "$LOGFILE"; }

# -- thresholds (battery temp in tenths of a degree C, e.g. 450 = 45.0C) ------
TEMP_WARN=420     # 42.0C - log a warning, no action yet
TEMP_CRIT=470     # 47.0C - override to battery profile until it cools
TEMP_RECOVER=400  # 40.0C - safe to revert override
RAM_CRIT_MB=150   # below this, force a cache drop regardless of RAM mode

OVERRIDE_ACTIVE="off"

read_battery_temp() {
    cat /sys/class/power_supply/battery/temp 2>/dev/null || echo 0
}

read_free_ram_mb() {
    local kb
    kb=$(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{print $2}')
    echo $(( ${kb:-0} / 1024 ))
}

apply_safety_override() {
    # Save the user's real profile choice exactly once, before we stomp it
    if [ "$OVERRIDE_ACTIVE" = "off" ]; then
        cp "$CORTEX/cpu/profile.txt" "$AI_CFG/saved_profile.txt" 2>/dev/null
        log_ai "Thermal override ENGAGED - forcing battery profile to cool down"
        sh "$CORTEX/notify/post.sh" thermal_override "Sweet Dreams" \
            "Cooling override: ${BATT_TEMP_C}°C - forced to Battery profile" 2>/dev/null
    fi
    echo "battery" > "$CORTEX/cpu/profile.txt"
    sh "$CORTEX/cpu/apply.sh"  2>/dev/null
    sh "$CORTEX/gpu/apply.sh"  2>/dev/null
    OVERRIDE_ACTIVE="on"
    echo "on" > "$AI_CFG/override_active.txt"
}

release_safety_override() {
    [ "$OVERRIDE_ACTIVE" = "off" ] && return
    local SAVED
    SAVED=$(cat "$AI_CFG/saved_profile.txt" 2>/dev/null || echo "balanced")
    echo "$SAVED" > "$CORTEX/cpu/profile.txt"
    sh "$CORTEX/cpu/apply.sh" 2>/dev/null
    sh "$CORTEX/gpu/apply.sh" 2>/dev/null
    log_ai "Thermal override RELEASED - restored profile: $SAVED"
    sh "$CORTEX/notify/post.sh" thermal_override "Sweet Dreams" \
        "Cooled to ${BATT_TEMP_C:--}°C - restored to ${SAVED} profile" 2>/dev/null
    OVERRIDE_ACTIVE="off"
    echo "off" > "$AI_CFG/override_active.txt"
}

# Resume cleanly if the engine restarted mid-override (e.g. WebUI reload)
[ "$(cat "$AI_CFG/override_active.txt" 2>/dev/null)" = "on" ] && OVERRIDE_ACTIVE="on"

LAST_SCHED_PROFILE=""

run_auto_schedule() {
    # Time/battery based profile switching. Deliberately skipped whenever a
    # thermal safety override is active - the AI engine's own emergency
    # cooldown always takes priority over a scheduled profile change, and
    # letting both write cpu/profile.txt in the same tick would just have
    # them fight each other every 5 seconds.
    [ "$OVERRIDE_ACTIVE" = "on" ] && return

    local NIGHT_H MORNING_H LOW_BAT HOUR TARGET
    NIGHT_H=$(cat "$AI_CFG/schedule_night_hour.txt" 2>/dev/null || echo 23)
    MORNING_H=$(cat "$AI_CFG/schedule_morning_hour.txt" 2>/dev/null || echo 7)
    LOW_BAT=$(cat "$AI_CFG/schedule_low_bat_pct.txt" 2>/dev/null || echo 15)
    HOUR=$(date +%H | sed 's/^0//')

    # Battery threshold always wins over the time window. Otherwise: if the
    # night hour is later than the morning hour (e.g. 23 -> 7), the "night"
    # window wraps past midnight, so it's active when HOUR is >= night OR
    # < morning. If night is earlier than morning (an unusual but valid
    # config, e.g. 2 -> 14), the window doesn't wrap, so it's active only
    # when HOUR is between the two directly.
    if [ "${BATT_PCT:-100}" -le "$LOW_BAT" ] 2>/dev/null; then
        TARGET="battery"
    elif [ "$NIGHT_H" -ge "$MORNING_H" ]; then
        if [ "$HOUR" -ge "$NIGHT_H" ] || [ "$HOUR" -lt "$MORNING_H" ]; then TARGET="battery"; else TARGET="balanced"; fi
    else
        if [ "$HOUR" -ge "$NIGHT_H" ] && [ "$HOUR" -lt "$MORNING_H" ]; then TARGET="battery"; else TARGET="balanced"; fi
    fi

    [ "$TARGET" = "$LAST_SCHED_PROFILE" ] && return
    CUR=$(cat "$CORTEX/cpu/profile.txt" 2>/dev/null || echo "")
    if [ "$TARGET" != "$CUR" ]; then
        echo "$TARGET" > "$CORTEX/cpu/profile.txt"
        sh "$CORTEX/cpu/apply.sh" 2>/dev/null
        sh "$CORTEX/gpu/apply.sh" 2>/dev/null
        log_ai "Auto Schedule: switched profile to $TARGET (hour=$HOUR night=$NIGHT_H morning=$MORNING_H bat=${BATT_PCT}% threshold=${LOW_BAT}%)"
    fi
    LAST_SCHED_PROFILE="$TARGET"
}

run_smart_charge() {
    local TRICKLE FULL_H HOUR CHARGING TARGET_PCT CUR_LIMIT_EN CUR_LIMIT_PCT
    TRICKLE=$(cat "$BAT_CFG/smart_charge_trickle.txt" 2>/dev/null || echo 80)
    FULL_H=$(cat "$BAT_CFG/smart_charge_full_hour.txt" 2>/dev/null || echo 7)
    HOUR=$(date +%H | sed 's/^0//')
    CHARGING=$(cat /sys/class/power_supply/battery/status 2>/dev/null || echo "Unknown")

    # Only relevant while actually plugged in/charging - no point touching
    # the charge-limit nodes while running on battery.
    case "$CHARGING" in
        Charging|"Not charging") : ;;
        *) return ;;
    esac

    # Within 1 hour of the wake hour: allow a full charge so the device is
    # at 100% when the user actually wants it, instead of stuck at the
    # trickle limit. Otherwise: hold at the trickle limit overnight to
    # reduce battery wear from sitting at 100% for hours unattended.
    if [ "$HOUR" -eq "$FULL_H" ] 2>/dev/null; then
        TARGET_PCT=100
    else
        TARGET_PCT="$TRICKLE"
    fi

    CUR_LIMIT_EN=$(cat "$BAT_CFG/limit_enabled.txt" 2>/dev/null || echo "off")
    CUR_LIMIT_PCT=$(cat "$BAT_CFG/limit_pct.txt" 2>/dev/null || echo "")
    if [ "$CUR_LIMIT_EN" != "on" ] || [ "$CUR_LIMIT_PCT" != "$TARGET_PCT" ]; then
        echo "on" > "$BAT_CFG/limit_enabled.txt"
        echo "$TARGET_PCT" > "$BAT_CFG/limit_pct.txt"
        sh "$CORTEX/battery/apply.sh" 2>/dev/null
        log_ai "Smart Charge: target ${TARGET_PCT}% (hour=$HOUR full_by=$FULL_H trickle=${TRICKLE}%)"
    fi
}

sample_telemetry() {
    BATT_TEMP=$(read_battery_temp | tr -d '\r\n ')
    case "$BATT_TEMP" in
        ''|*[!0-9-]*)
            BATT_TEMP=""
            BATT_TEMP_C="-"
            ;;
        *)
            BATT_TEMP_C=$(awk -v t="$BATT_TEMP" 'BEGIN { printf "%.1f", t/10 }')
            ;;
    esac
    FREE_RAM=$(read_free_ram_mb)
    BATT_PCT=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null | tr -d '\r\n ' || echo "-")
    [ -n "$BATT_PCT" ] || BATT_PCT="-"
    GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null | tr -d '\r\n ' || echo "-")
    [ -n "$GOV" ] || GOV="-"
    PROFILE=$(cat "$CORTEX/cpu/profile.txt" 2>/dev/null | tr -d '\r\n ' || echo "-")
    [ -n "$PROFILE" ] || PROFILE="-"
}

write_status_line() {
    local flag="$1"
    echo "${BATT_TEMP_C}|${BATT_PCT}|${FREE_RAM}|${GOV}|${PROFILE}|${flag}" > "$AI_CFG/status.txt"
}

log_ai "Engine started (PID $$) - native telemetry supervisor"

while true; do
    sample_telemetry
    EN=$(cat "$AI_CFG/enabled.txt" 2>/dev/null || echo "on")
    if [ "$EN" != "on" ]; then
        # Still publish live temp/RAM so the WebUI readout is never "off°C".
        # Safety override is released; scheduler/charge logic stays idle.
        release_safety_override
        write_status_line "idle"
        sleep 5
        continue
    fi

    # -- thermal safety state machine --------------------------------------─
    if [ "$BATT_TEMP" -ge "$TEMP_CRIT" ] 2>/dev/null; then
        apply_safety_override
    elif [ "$BATT_TEMP" -le "$TEMP_RECOVER" ] 2>/dev/null && [ "$OVERRIDE_ACTIVE" = "on" ]; then
        release_safety_override
    elif [ "$BATT_TEMP" -ge "$TEMP_WARN" ] 2>/dev/null; then
        log_ai "Temp ${BATT_TEMP_C}C - watching (warn threshold, no action yet)"
    fi

    # -- RAM safety net ----------------------------------------------------─
    if [ "$FREE_RAM" -lt "$RAM_CRIT_MB" ] 2>/dev/null; then
        sync
        echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
        log_ai "Critical RAM (${FREE_RAM}MB free) - dropped caches"
    fi

    # -- auto-profile scheduler --------------------------------------------─
    SCHED_EN=$(cat "$AI_CFG/schedule_enabled.txt" 2>/dev/null || echo "off")
    [ "$SCHED_EN" = "on" ] && run_auto_schedule

    # -- smart charge scheduler ----------------------------------------------
    SMART_CHG_EN=$(cat "$BAT_CFG/smart_charge_enabled.txt" 2>/dev/null || echo "off")
    [ "$SMART_CHG_EN" = "on" ] && run_smart_charge

    write_status_line "$OVERRIDE_ACTIVE"

    sleep 5
done
