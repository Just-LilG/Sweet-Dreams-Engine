#!/system/bin/sh
# cortex/sensor/apply.sh - Sweet Dreams Sensor Optimizer v2
#
# WHAT CHANGED: on devices with a fully vendor-HAL-driven sensor stack (no
# sysfs/IIO/proc control surface at all - confirmed via probe.sh on this
# specific MT6789 firmware: sensors are entirely handled by closed vendor
# HALs (st/qst/mtk/eminent/transsion tagged in dumpsys, zero matching
# nodes anywhere on the filesystem), there is NO way for a root shell
# script to disable individual sensors. Not a missing path we haven't
# found yet - SensorService only exposes enable/disable through a Java-level
# registerListener()/unregisterListener() API that requires being an actual
# app process with sensor permissions, which a shell script fundamentally
# cannot do. Previous versions kept re-attempting this every game launch
# and logging a fresh "WARNING: no sensor nodes" every single time, which
# is honest about the immediate result but misleading about the bigger
# picture - implying this MIGHT work if conditions were slightly different,
# when actually it will never work on this firmware, full stop.
#
# FIX: detect support ONCE (first run), cache the verdict, and skip
# silently on every subsequent call if unsupported - instead of retrying
# and re-logging a warning every single game launch forever. Support is
# device-specific (IIO/sysfs paths vary by OEM/SoC), so this stays
# opportunistic and simply does nothing extra on devices where it doesn't
# apply - it does NOT claim a fix that isn't possible on this hardware.

CORTEX="/data/adb/modules/sweet_dreams/cortex"
SEN_CFG="$CORTEX/sensor"
SUPPORT_CACHE="$SEN_CFG/support_detected.txt"
ACTION="${1:-restore}"   # "game" = disable non-essentials | "restore" = re-enable all

log_sen() { echo "[SENSOR] $1"; }

DISABLE_SENSORS="
barometer
pressure
bmp
significant_motion
step_counter
step_detector
gravity
game_rotation_vector
geomagnetic
magnetic_field
orientation
linear_acceleration
"

# ----------------------------------------------------------------------------─
# detect_support - probes every known control surface ONCE, caches result.
# Returns via $SUPPORT_CACHE: "yes" or "no", so every future call is instant
# and silent instead of re-probing and re-logging a warning every game launch.
# ----------------------------------------------------------------------------─
detect_support() {
    [ -f "$SUPPORT_CACHE" ] && return   # already detected, nothing to do

    local FOUND=0

    # IIO devices matching a disable-list sensor name with a real buffer/enable node
    for IIO_DEV in /sys/bus/iio/devices/iio:device*; do
        [ -f "$IIO_DEV/name" ] || continue
        DEVNAME=$(cat "$IIO_DEV/name" 2>/dev/null | tr '[:upper:]' '[:lower:]')
        for SEN in $DISABLE_SENSORS; do
            case "$DEVNAME" in *"$SEN"*)
                [ -f "$IIO_DEV/buffer/enable" ] && FOUND=1
                ;;
            esac
        done
    done

    # Sensor power nodes (either naming convention)
    for NODE in \
        /sys/class/sensor/barometer/enable \
        /sys/class/sensor/magnetic/enable \
        /sys/class/sensor/step_counter/enable \
        /sys/class/sensor/significant_motion/enable \
        /sys/class/sensors/barometer/enable \
        /sys/class/sensors/magnetic/enable; do
        [ -f "$NODE" ] && FOUND=1
    done

    if [ "$FOUND" = "1" ]; then
        echo "yes" > "$SUPPORT_CACHE"
        log_sen "Support detected on this firmware - sensor toggling enabled"
    else
        echo "no" > "$SUPPORT_CACHE"
        log_sen "No root-accessible sensor control surface on this firmware (sensors are HAL-only on this SoC/vendor build) - sensor optimizer will stay inactive. This is a hardware/firmware limitation, not a bug; re-checked automatically if the module is reinstalled."
    fi
}

# -- iio device toggle ----------------------------------------------------------
toggle_iio() {
    local STATE="$1"
    local HITS=0
    for IIO_DEV in /sys/bus/iio/devices/iio:device*; do
        [ -f "$IIO_DEV/name" ] || continue
        DEVNAME=$(cat "$IIO_DEV/name" 2>/dev/null | tr '[:upper:]' '[:lower:]')
        for SEN in $DISABLE_SENSORS; do
            case "$DEVNAME" in *"$SEN"*)
                [ -f "$IIO_DEV/scan_elements/in_accel_en" ] && continue
                if [ -f "$IIO_DEV/buffer/enable" ]; then
                    echo "$STATE" > "$IIO_DEV/buffer/enable" 2>/dev/null
                    HITS=$((HITS + 1))
                    log_sen "${STATE}: $DEVNAME"
                fi
                ;;
            esac
        done
    done
    echo "$HITS"
}

# -- Sensor power nodes ----------------------------------------------------------
toggle_sensor_power() {
    local STATE="$1"
    local HITS=0
    for NODE in \
        /sys/class/sensor/barometer/enable \
        /sys/class/sensor/magnetic/enable \
        /sys/class/sensor/step_counter/enable \
        /sys/class/sensor/significant_motion/enable \
        /sys/class/sensors/barometer/enable \
        /sys/class/sensors/magnetic/enable; do
        if [ -f "$NODE" ]; then
            echo "$STATE" > "$NODE" 2>/dev/null
            HITS=$((HITS + 1))
        fi
    done
    echo "$HITS"
}

list_sensors_dumpsys() {
    local SENSOR_LIST="barometer|pressure|magnetic|significant|step_count|step_detect|gravity|orientation|linear_accel"
    dumpsys sensorservice 2>/dev/null | grep -ciE "$SENSOR_LIST"
}

# ----------------------------------------------------------------------------─
# ENTRY POINT
# ----------------------------------------------------------------------------─

detect_support
SUPPORTED=$(cat "$SUPPORT_CACHE" 2>/dev/null || echo "no")

case "$ACTION" in
    game)
        SEN_EN=$(cat "$SEN_CFG/enabled.txt" 2>/dev/null || echo "off")
        [ "$SEN_EN" != "on" ] && exit 0

        if [ "$SUPPORTED" != "yes" ]; then
            # Silent no-op - support already known to be absent, don't
            # re-probe or re-log every single game launch
            echo "unsupported|0|0|0|0" > "$SEN_CFG/verify.txt"
            echo "unsupported" > "$SEN_CFG/state.txt"
            exit 0
        fi

        log_sen "Disabling non-essential sensors for gaming"
        IIO_HIT=$(toggle_iio 0)
        POWER_HIT=$(toggle_sensor_power 0)
        DS_CANDIDATES=$(list_sensors_dumpsys)
        ACTUAL_HITS=$((${IIO_HIT:-0} + ${POWER_HIT:-0}))
        log_sen "Sensor optimizer applied (iio: ${IIO_HIT:-0}, power nodes: ${POWER_HIT:-0})"
        echo "game|${ACTUAL_HITS}|${IIO_HIT:-0}|${POWER_HIT:-0}|${DS_CANDIDATES:-0}" > "$SEN_CFG/verify.txt"
        echo "game" > "$SEN_CFG/state.txt"
        ;;

    restore)
        if [ "$SUPPORTED" != "yes" ]; then
            echo "unsupported|0|0|0|0" > "$SEN_CFG/verify.txt"
            echo "unsupported" > "$SEN_CFG/state.txt"
            exit 0
        fi
        log_sen "Restoring all sensors"
        toggle_iio 1 >/dev/null
        toggle_sensor_power 1 >/dev/null
        echo "idle|0|0|0|0" > "$SEN_CFG/verify.txt"
        echo "idle" > "$SEN_CFG/state.txt"
        ;;
esac
