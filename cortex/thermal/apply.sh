#!/system/bin/sh
# cortex/thermal/apply.sh - Sweet Dreams Thermal Engine v5
#
# WHAT'S NEW IN v5:
#   Added IIO (Industrial I/O) and I2C hardware sensor bus coverage.
#   The lsm6dso IMU (gyroscope/accelerometer) reports temperature through
#   /sys/bus/iio/devices/iio:deviceN/in_temp_raw (or in_temp_input) -
#   completely separate from the thermal_zone sysfs tree. Previous versions
#   missed this entirely. v5 blinds every temp node across ALL sysfs buses:
#     - /sys/class/thermal/thermal_zone*/temp        (CPU/GPU/board zones)
#     - /sys/devices/virtual/thermal/*/temp          (same, alt path)
#     - /sys/class/power_supply/*/temp               (battery/charger - works, 0°C confirmed)
#     - /sys/bus/iio/devices/iio:device*/in_temp*    (IMU/barometer/ambient sensors)
#     - /sys/bus/i2c/devices/*/temp*                 (raw I2C temp registers)
#     - /sys/devices/platform/*/temp*                (platform driver temp nodes)
#     - /sys/devices/virtual/hwmon/hwmon*/temp*_input (hwmon subsystem)
#
# APPROACH: chmod 000 - removes read permission, nothing can read = nothing
# can throttle. Works under SELinux Enforcing (DAC not MAC).
# Battery confirmed working (0°C in DevInfo). lsm6dso_temp still at 40.9°C
# because it was not covered. This version fixes that.

MODDIR="/data/adb/modules/sweet_dreams"
CORTEX="$MODDIR/cortex"
LOGFILE="$MODDIR/boot.log"
GAME_PHASE="$1"

. "$CORTEX/health/track.sh"

# THERMAL_MODE: "extreme" (full blackout, every sensor bus) or "lite"
# (CPU/GPU/board thermal zones only - the paths that actually cause
# performance throttling - leaving battery/IIO/I2C/hwmon/platform sensors
# readable). Bug fix: mode.txt existed and the WebUI had a working
# Extreme/Lite toggle, but this script never actually read the file - both
# options did the exact same full blackout. This was a dead setting.
#
# Second positional arg ($2) lets game_monitor.sh pass a per-game thermal
# mode override without needing to touch the global mode.txt file - same
# pattern already used by apply_resolution.sh accepting a resolution value
# directly rather than only reading the global config.
THERMAL_MODE="${2:-$(cat "$CORTEX/thermal/mode.txt" 2>/dev/null || echo "extreme")}"

log_t() { echo "[THERMAL] $1" | tee -a "$LOGFILE"; }

# ----------------------------------------------------------------------------─
# kill_thermal_daemons - extracted to daemons_lib.sh (sourced below) so
# service.sh's boot-time daemon-stop-only call (cortex/thermal/
# kill_daemons_only.sh) can reuse this exact function instead of a
# separate, driftable copy. See that file for why boot no longer calls
# into this script's blackout logic directly.
# ----------------------------------------------------------------------------─
. "$CORTEX/thermal/daemons_lib.sh"

# ----------------------------------------------------------------------------─
# blackout_all_temp_nodes
# chmod 000 across ALL sysfs subsystems that expose temperature readings.
# Each subsystem uses a different node naming convention - we cover them all.
# ----------------------------------------------------------------------------─
blackout_all_temp_nodes() {
    local OK=0 FAIL=0
    IIO_COUNT=0
    I2C_COUNT=0
    HWMON_COUNT=0

    # -- 1. Thermal zones (CPU/GPU/board/skin) --------------------------------
    # Both sysfs paths - /sys/class/thermal symlinks to /sys/devices/virtual/thermal
    # We hit both to guarantee coverage regardless of kernel symlink state
    # ALWAYS done regardless of mode - this is the actual throttle-causing
    # path, and is what distinguishes "thermal bypass on" from "off" at all.
    for f in \
        /sys/class/thermal/thermal_zone*/temp \
        /sys/devices/virtual/thermal/thermal_zone*/temp; do
        [ -f "$f" ] || continue
        chmod 000 "$f" 2>/dev/null && OK=$((OK+1)) || FAIL=$((FAIL+1))
    done

    # -- 7. Disable thermal zone governors ------------------------------------
    # ALWAYS done - same reasoning as section 1, this is what actually stops
    # the kernel's own thermal governor from throttling based on whatever it
    # can still read elsewhere, and is cheap/reversible either way.
    for node in /sys/class/thermal/thermal_zone*/mode; do
        [ -f "$node" ] && echo "disabled"   > "$node" 2>/dev/null
    done
    for node in /sys/class/thermal/thermal_zone*/policy; do
        [ -f "$node" ] && echo "user_space" > "$node" 2>/dev/null
    done

    if [ "$THERMAL_MODE" = "lite" ]; then
        # LITE MODE: stop here. Battery temp, IMU/barometer sensors, I2C
        # raw registers, hwmon, and misc platform temp nodes are left
        # untouched - anything reading battery health or ambient sensor
        # data (including Android's own battery-safety logic) still sees
        # real numbers. Trade-off: any throttling path that keys off one
        # of THOSE nodes rather than the main thermal_zone tree can still
        # engage under Lite mode. That's the intentional difference from
        # Extreme - less aggressive, but leaves real safety-relevant
        # sensors (battery temp especially) intact.
        log_t "Lite mode: CPU/GPU thermal zones blinded only - battery/IIO/I2C/hwmon left readable"
        health_check "sensor_blackout" 0 "lite mode: thermal_zone only, OK=$OK FAIL=$FAIL"
        return
    fi

    # -- 2. Battery / power supply thermal ------------------------------------
    # EXTREME MODE ONLY - Confirmed working - DevInfo shows 0°C on battery
    for f in \
        /sys/class/power_supply/battery/temp \
        /sys/class/power_supply/Battery/temp \
        /sys/class/power_supply/usb/temp \
        /sys/class/power_supply/USB/temp \
        /sys/class/power_supply/ac/temp \
        /sys/class/power_supply/charger/temp \
        /sys/devices/platform/battery/power_supply/battery/temp \
        /sys/devices/platform/mtk-gauge/power_supply/battery/temp \
        /sys/devices/platform/charger/power_supply/charger/temp; do
        [ -f "$f" ] || continue
        chmod 000 "$f" 2>/dev/null && OK=$((OK+1)) || FAIL=$((FAIL+1))
    done

    # -- 3. IIO subsystem (IMU / barometer / ambient sensors) ----------------─
    # EXTREME MODE ONLY - lsm6dso lives here - /sys/bus/iio/devices/iio:deviceN/
    # Different sensors use different node names:
    #   in_temp_raw    - raw ADC count (lsm6dso, bmi160, etc)
    #   in_temp_input  - millidegrees (some barometers)
    #   in_temp_offset - calibration offset (also readable)
    # We use find so we catch whatever device index the kernel assigned
    find /sys/bus/iio/devices/ -name "in_temp*" -type f \
        -exec chmod 000 {} \; 2>/dev/null
    # Count how many we found
    IIO_COUNT=$(find /sys/bus/iio/devices/ -name "in_temp*" -type f 2>/dev/null | wc -l)
    OK=$((OK + IIO_COUNT))

    # -- 4. I2C bus raw temp registers ----------------------------------------
    # EXTREME MODE ONLY - Some MTK platform drivers expose temp directly on the I2C device node
    find /sys/bus/i2c/devices/ -name "temp*" -type f \
        -exec chmod 000 {} \; 2>/dev/null
    I2C_COUNT=$(find /sys/bus/i2c/devices/ -name "temp*" -type f 2>/dev/null | wc -l)
    OK=$((OK + I2C_COUNT))

    # -- 5. hwmon subsystem --------------------------------------------------─
    # EXTREME MODE ONLY - Some MTK kernels expose thermal through hwmon (temp1_input, temp2_input...)
    find /sys/devices/virtual/hwmon/ -name "temp*_input" -type f \
        -exec chmod 000 {} \; 2>/dev/null
    find /sys/class/hwmon/ -name "temp*_input" -type f \
        -exec chmod 000 {} \; 2>/dev/null
    HWMON_COUNT=$(find /sys/devices/virtual/hwmon/ /sys/class/hwmon/ \
        -name "temp*_input" -type f 2>/dev/null | wc -l)
    OK=$((OK + HWMON_COUNT))

    # -- 6. Platform driver temp nodes ----------------------------------------
    # EXTREME MODE ONLY - MTK-specific platform drivers sometimes have their own temp sysfs attrs
    find /sys/devices/platform/ -name "temp" -o -name "temperature" \
        2>/dev/null | while read f; do
        [ -f "$f" ] && chmod 000 "$f" 2>/dev/null
    done

    # Health tracking: report whether ANY node was successfully blinded.
    # A device where every single one of these fails (all zero counts) is
    # a real, actionable problem worth surfacing in the WebUI - most
    # devices will have at least the thermal_zone and battery paths work.
    # Bug fix: this used to subtract IIO_COUNT/I2C_COUNT/HWMON_COUNT from
    # OK and then immediately add all three straight back - net effect was
    # always just $OK, since every category is already folded into OK as
    # it's counted above. Simplified to what it actually computes; no
    # behavior change, just removes confusing dead arithmetic (likely
    # copy-pasted from the log_p line below, where the same subtraction is
    # used for a genuinely different purpose - isolating the thermal-zone-
    # only sub-count for that specific log line).
    TOTAL_BLINDED="$OK"
    if [ "$TOTAL_BLINDED" -gt 0 ]; then
        health_check "sensor_blackout" 0 "extreme mode: $TOTAL_BLINDED nodes blinded, $FAIL failed"
    else
        health_check "sensor_blackout" 1 "0 nodes blinded - thermal bypass likely non-functional on this device"
    fi

    log_t "Thermal blackout: thermal=$((OK - IIO_COUNT - I2C_COUNT - HWMON_COUNT)) iio=$IIO_COUNT i2c=$I2C_COUNT hwmon=$HWMON_COUNT failed=$FAIL"
}

# ----------------------------------------------------------------------------─
# restore_all_temp_nodes
# chmod 644 across all the same paths, then restart daemons
# ----------------------------------------------------------------------------─
restore_all_temp_nodes() {
    local N=0

    # Thermal zones
    for f in \
        /sys/class/thermal/thermal_zone*/temp \
        /sys/devices/virtual/thermal/thermal_zone*/temp; do
        [ -f "$f" ] || continue
        chmod 644 "$f" 2>/dev/null && N=$((N+1))
    done

    # Battery / power supply
    for f in \
        /sys/class/power_supply/battery/temp \
        /sys/class/power_supply/Battery/temp \
        /sys/class/power_supply/usb/temp \
        /sys/class/power_supply/USB/temp \
        /sys/class/power_supply/ac/temp \
        /sys/class/power_supply/charger/temp \
        /sys/devices/platform/battery/power_supply/battery/temp \
        /sys/devices/platform/mtk-gauge/power_supply/battery/temp \
        /sys/devices/platform/charger/power_supply/charger/temp; do
        [ -f "$f" ] || continue
        chmod 644 "$f" 2>/dev/null && N=$((N+1))
    done

    # IIO sensors
    find /sys/bus/iio/devices/ -name "in_temp*" -type f \
        -exec chmod 644 {} \; 2>/dev/null

    # I2C
    find /sys/bus/i2c/devices/ -name "temp*" -type f \
        -exec chmod 644 {} \; 2>/dev/null

    # hwmon
    find /sys/devices/virtual/hwmon/ -name "temp*_input" -type f \
        -exec chmod 644 {} \; 2>/dev/null
    find /sys/class/hwmon/ -name "temp*_input" -type f \
        -exec chmod 644 {} \; 2>/dev/null

    # Platform
    find /sys/devices/platform/ -name "temp" -o -name "temperature" \
        2>/dev/null | while read f; do
        [ -f "$f" ] && chmod 644 "$f" 2>/dev/null
    done

    # Re-enable thermal zone modes
    for node in /sys/class/thermal/thermal_zone*/mode; do
        [ -f "$node" ] && echo "enabled"   > "$node" 2>/dev/null
    done
    for node in /sys/class/thermal/thermal_zone*/policy; do
        [ -f "$node" ] && echo "step_wise" > "$node" 2>/dev/null
    done

    # Restart daemons - dynamic scan
    for svc in $(resetprop | awk -F'[][]' '/\[init\.svc\..*thermal/ { print $2 }'); do
        CLEAN="${svc#init.svc.}"
        if [ "$(resetprop "$svc")" = "stopped" ]; then
            start "$CLEAN"               2>/dev/null
            resetprop -n "$svc" running  2>/dev/null
        fi
    done

    # Hardcoded restart set
    start thermal-engine     2>/dev/null
    start thermal_manager    2>/dev/null
    start thermalloadalgod   2>/dev/null
    start thermald           2>/dev/null

    # Restore props
    resetprop persist.thermal.enable        1 2>/dev/null
    resetprop vendor.thermal.manager        1 2>/dev/null
    resetprop vendor.thermal.link_ready     1 2>/dev/null
    resetprop persist.vendor.thermal.enable 1 2>/dev/null

    # Re-enable MTK thermal app
    pm enable --user 0 com.mediatek.thermal 2>/dev/null

    log_t "Thermal restored: $N nodes readable + IIO/I2C/hwmon restored, daemons restarted"
}

# ----------------------------------------------------------------------------─
# ENTRY POINT
# ----------------------------------------------------------------------------─

case "$GAME_PHASE" in

    game_end)
        health_start "thermal"
        restore_all_temp_nodes
        health_finish
        log_t "Game ended - thermal protection active"
        exit 0
        ;;

    game_start)
        health_start "thermal"
        kill_thermal_daemons
        blackout_all_temp_nodes
        health_finish
        log_t "Game started - thermal bypass active (mode: $THERMAL_MODE)"
        exit 0
        ;;

    "")
        # Bug fix: this comment used to say "Boot / WebUI toggle - blackout
        # immediately at boot", which was the actual bug - service.sh
        # called this exact case at every boot regardless of arm state.
        # Boot now goes through kill_daemons_only.sh instead (daemon-stop
        # only, never touches a sensor node) - see that file and
        # service.sh's own comment for the full story. This "" case is
        # reached ONLY from the WebUI's manual Thermal Spoof toggle
        # (toggleThermal() in webroot) and its "restore all" call, both of
        # which are genuine user-initiated immediate actions, not boot.
        health_start "thermal"
        kill_thermal_daemons
        blackout_all_temp_nodes
        health_finish
        log_t "Thermal engine armed + active (manual WebUI toggle, mode: $THERMAL_MODE)"
        exit 0
        ;;

    *)
        echo "[THERMAL] Unknown argument: '$GAME_PHASE'" >&2
        echo "Usage: apply.sh [game_start|game_end]" >&2
        exit 1
        ;;

esac
