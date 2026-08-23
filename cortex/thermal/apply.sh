#!/system/bin/sh
# cortex/thermal/apply.sh - Sweet Dreams Thermal Engine v6
#
# Same engine as the previous public release (v1.9.2 / skipmount v5):
#   1. Stop vendor thermal daemons
#   2. Disable thermal-zone governors
#   3. Bind-mount a fake temperature file over sysfs temp nodes so userspace
#      (Android, games, thermald) reads a chosen °C instead of the real one.
#      That is the fake-27°C bind-mount technique from the previous zip —
#      chmod 000 blackout hid the sensors; spoofing makes them report a value.
#
# v6: Advanced mode lets the user set that spoof temperature (spoof_c.txt).
# Lite still only covers CPU/GPU/board thermal_zone nodes (battery/IIO/I2C
# stay real). Advanced/extreme covers every temp bus, same coverage as v5.
#
# Session-scoped: game_start / game_end. Boot never spoofs (kill_daemons_only.sh).

MODDIR="/data/adb/modules/sweet_dreams"
CORTEX="$MODDIR/cortex"
LOGFILE="$MODDIR/boot.log"
GAME_PHASE="$1"
FAKE_DIR="$CORTEX/thermal/fake"
MOUNT_LIST="$CORTEX/thermal/mounted.list"

. "$CORTEX/health/track.sh"
. "$CORTEX/thermal/state.sh"

THERMAL_MODE="${2:-$(cat "$CORTEX/thermal/mode.txt" 2>/dev/null || echo "extreme")}"

log_t() { echo "[THERMAL] $1" | tee -a "$LOGFILE"; }

. "$CORTEX/thermal/daemons_lib.sh"

# ----------------------------------------------------------------------------─
# spoof_c.txt: integer °C the OS should see while spoofing is active.
# Previous release hardcoded ~27°C via bind-mount. Clamp 0–45.
# ----------------------------------------------------------------------------─
read_spoof_c() {
    local C
    C=$(cat "$CORTEX/thermal/spoof_c_session.txt" 2>/dev/null | tr -dc '0-9')
    [ -z "$C" ] && C=$(cat "$CORTEX/thermal/spoof_c.txt" 2>/dev/null | tr -dc '0-9')
    [ -z "$C" ] && C=27
    [ "$C" -gt 45 ] 2>/dev/null && C=45
    [ "$C" -lt 0 ] 2>/dev/null && C=0
    echo "$C"
}

prepare_fake_files() {
    mkdir -p "$CORTEX/thermal" "$FAKE_DIR"
    local C MILLI TENTH
    C=$(read_spoof_c)
    MILLI=$((C * 1000))
    TENTH=$((C * 10))
    mkdir -p "$FAKE_DIR"
    printf '%s\n' "$MILLI" > "$FAKE_DIR/milli"
    printf '%s\n' "$TENTH" > "$FAKE_DIR/tenth"
    chmod 644 "$FAKE_DIR/milli" "$FAKE_DIR/tenth" 2>/dev/null
    SPOOF_C="$C"
}

already_mounted() {
    grep -qF " $1 " /proc/mounts 2>/dev/null
}

bind_in_ns() {
    local src="$1" target="$2"
    mount --bind "$src" "$target" 2>/dev/null && return 0
    mount -o bind "$src" "$target" 2>/dev/null && return 0
    # KernelSU/Magisk may isolate this script's mount ns from apps.
    nsenter -t 1 -m -- mount --bind "$src" "$target" 2>/dev/null && return 0
    nsenter -t 1 -m -- mount -o bind "$src" "$target" 2>/dev/null && return 0
    return 1
}

bind_spoof() {
    local target="$1" src="$2"
    [ -f "$target" ] || return 1
    already_mounted "$target" && return 0
    if bind_in_ns "$src" "$target"; then
        echo "$target" >> "$MOUNT_LIST"
        return 0
    fi
    if cat "$src" > "$target" 2>/dev/null; then
        return 0
    fi
    return 1
}

verify_spoof_readback() {
    local C milli z v match=0 seen=0
    C=${SPOOF_C:-$(read_spoof_c)}
    milli=$((C * 1000))
    for z in /sys/class/thermal/thermal_zone0/temp /sys/class/thermal/thermal_zone1/temp /sys/class/thermal/thermal_zone2/temp; do
        [ -r "$z" ] || continue
        seen=$((seen + 1))
        v=$(tr -dc '0-9-' < "$z" | head -c 16)
        [ "$v" = "$milli" ] && match=$((match + 1))
    done
    printf 'target_c=%s milli=%s zones_ok=%s zones_seen=%s\n' "$C" "$milli" "$match" "$seen" > "$CORTEX/thermal/last_verify.txt"
    echo "APPLY_RESULT target=${C}C match=${match}/${seen}"
    if [ "$seen" -gt 0 ] && [ "$match" -eq 0 ]; then
        health_check "spoof_verify" 1 "OS not reading ${C}C (0/${seen} zones)"
    else
        health_check "spoof_verify" 0 "match ${match}/${seen} at ${C}C"
    fi
}

unmount_spoofs() {
    local t
    if [ -f "$MOUNT_LIST" ]; then
        while IFS= read -r t; do
            [ -n "$t" ] || continue
            umount -l "$t" 2>/dev/null
            nsenter -t 1 -m --             umount -l "$t" 2>/dev/null
            nsenter -t 1 -m -- umount -l "$t" 2>/dev/null
        done < "$MOUNT_LIST"
    fi
    # Sweep in case the list was lost (module update mid-game).
    for t in \
        /sys/class/thermal/thermal_zone*/temp \
        /sys/devices/virtual/thermal/thermal_zone*/temp \
        /sys/class/power_supply/*/temp \
        /sys/class/hwmon/hwmon*/temp*_input \
        /sys/devices/virtual/hwmon/hwmon*/temp*_input; do
        [ -e "$t" ] || continue
        already_mounted "$t" && umount -l "$t" 2>/dev/null
    done
    find /sys/bus/iio/devices/ /sys/bus/i2c/devices/ /sys/devices/platform/ \
        \( -name 'in_temp*' -o -name 'temp' -o -name 'temperature' -o -name 'temp*' \) \
        -type f 2>/dev/null | while IFS= read -r t; do
        already_mounted "$t" && umount -l "$t" 2>/dev/null
    done
    : > "$MOUNT_LIST"
}

disable_zone_governors() {
    local node
    for node in /sys/class/thermal/thermal_zone*/mode; do
        [ -f "$node" ] && echo "disabled" > "$node" 2>/dev/null
    done
    for node in /sys/class/thermal/thermal_zone*/policy; do
        [ -f "$node" ] && echo "user_space" > "$node" 2>/dev/null
    done
    # Raise trip points so leftover kernel trips do not fire at real temps.
    for node in /sys/class/thermal/thermal_zone*/trip_point_*_temp; do
        [ -f "$node" ] && echo "125000" > "$node" 2>/dev/null
    done
    echo "disabled" > /sys/class/thermal/thermal_zone0/mode 2>/dev/null
    echo "0" > /proc/mtk_thermal/tzcpu 2>/dev/null
    echo "0" > /proc/mtk_thermal/tz_log 2>/dev/null
    echo "0" > /proc/driver/thermal/tm_pid 2>/dev/null
    echo "0" > /sys/class/thermal/cooling_device0/cur_state 2>/dev/null
    echo "0" > /sys/class/thermal/cooling_device1/cur_state 2>/dev/null
}

enable_zone_governors() {
    local node
    for node in /sys/class/thermal/thermal_zone*/mode; do
        [ -f "$node" ] && echo "enabled" > "$node" 2>/dev/null
    done
    for node in /sys/class/thermal/thermal_zone*/policy; do
        [ -f "$node" ] && echo "step_wise" > "$node" 2>/dev/null
    done
    echo "1" > /proc/mtk_thermal/tzcpu 2>/dev/null
    echo "1" > /proc/driver/thermal/tm_pid 2>/dev/null
}

# ----------------------------------------------------------------------------─
# spoof_temp_nodes — bind-mount fake °C over the same buses v5 used to blind.
# ----------------------------------------------------------------------------─
spoof_temp_nodes() {
    local OK=0 FAIL=0 f
    IIO_COUNT=0
    I2C_COUNT=0
    HWMON_COUNT=0

    prepare_fake_files
    unmount_spoofs
    : > "$MOUNT_LIST"

    # Thermal zones — always (this is what stops userspace throttle).
    for f in \
        /sys/class/thermal/thermal_zone*/temp \
        /sys/devices/virtual/thermal/thermal_zone*/temp; do
        [ -f "$f" ] || continue
        bind_spoof "$f" "$FAKE_DIR/milli" && OK=$((OK + 1)) || FAIL=$((FAIL + 1))
    done

    disable_zone_governors

    if [ "$THERMAL_MODE" = "lite" ]; then
        log_t "Lite: thermal_zone spoofed to ${SPOOF_C}°C — battery/IIO/I2C/hwmon left real"
        health_check "sensor_spoof" 0 "lite ${SPOOF_C}C zones=$OK fail=$FAIL"
        verify_spoof_readback
        return
    fi

    # Battery / charger — tenths of a degree.
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
        bind_spoof "$f" "$FAKE_DIR/tenth" && OK=$((OK + 1)) || FAIL=$((FAIL + 1))
    done

    # IIO — millidegree input nodes; skip offset/scale.
    if [ -d /sys/bus/iio/devices ]; then
        find /sys/bus/iio/devices/ \( -name 'in_temp_input' -o -name 'in_temp_raw' \) -type f 2>/dev/null | while IFS= read -r f; do
            bind_spoof "$f" "$FAKE_DIR/milli"
        done
        IIO_COUNT=$(find /sys/bus/iio/devices/ \( -name 'in_temp_input' -o -name 'in_temp_raw' \) -type f 2>/dev/null | wc -l)
        OK=$((OK + IIO_COUNT))
    fi

    if [ -d /sys/bus/i2c/devices ]; then
        find /sys/bus/i2c/devices/ -name 'temp*' -type f 2>/dev/null | while IFS= read -r f; do
            bind_spoof "$f" "$FAKE_DIR/milli"
        done
        I2C_COUNT=$(find /sys/bus/i2c/devices/ -name 'temp*' -type f 2>/dev/null | wc -l)
        OK=$((OK + I2C_COUNT))
    fi

    find /sys/devices/virtual/hwmon/ /sys/class/hwmon/ -name 'temp*_input' -type f 2>/dev/null | while IFS= read -r f; do
        bind_spoof "$f" "$FAKE_DIR/milli"
    done
    HWMON_COUNT=$(find /sys/devices/virtual/hwmon/ /sys/class/hwmon/ -name 'temp*_input' -type f 2>/dev/null | wc -l)
    OK=$((OK + HWMON_COUNT))

    find /sys/devices/platform/ \( -name 'temp' -o -name 'temperature' \) -type f 2>/dev/null | while IFS= read -r f; do
        bind_spoof "$f" "$FAKE_DIR/milli"
    done

    if [ "$OK" -gt 0 ]; then
        health_check "sensor_spoof" 0 "advanced ${SPOOF_C}C nodes=$OK fail=$FAIL"
    else
        health_check "sensor_spoof" 1 "0 nodes spoofed — thermal bypass likely non-functional"
    fi

    log_t "Advanced spoof ${SPOOF_C}°C: ok=$OK iio=$IIO_COUNT i2c=$I2C_COUNT hwmon=$HWMON_COUNT fail=$FAIL"
    verify_spoof_readback
}

restore_all_temp_nodes() {
    local N=0 f svc CLEAN

    unmount_spoofs

    for f in \
        /sys/class/thermal/thermal_zone*/temp \
        /sys/devices/virtual/thermal/thermal_zone*/temp; do
        [ -f "$f" ] || continue
        chmod 644 "$f" 2>/dev/null && N=$((N + 1))
    done

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
        chmod 644 "$f" 2>/dev/null && N=$((N + 1))
    done

    find /sys/bus/iio/devices/ -name "in_temp*" -type f -exec chmod 644 {} \; 2>/dev/null
    find /sys/bus/i2c/devices/ -name "temp*" -type f -exec chmod 644 {} \; 2>/dev/null
    find /sys/devices/virtual/hwmon/ /sys/class/hwmon/ -name "temp*_input" -type f \
        -exec chmod 644 {} \; 2>/dev/null
    find /sys/devices/platform/ \( -name "temp" -o -name "temperature" \) -type f \
        -exec chmod 644 {} \; 2>/dev/null

    enable_zone_governors

    for svc in $(resetprop | awk -F'[][]' '/\[init\.svc\..*thermal/ { print $2 }'); do
        CLEAN="${svc#init.svc.}"
        if [ "$(resetprop "$svc")" = "stopped" ]; then
            start "$CLEAN" 2>/dev/null
            resetprop -n "$svc" running 2>/dev/null
        fi
    done

    start thermal-engine 2>/dev/null
    start thermal_manager 2>/dev/null
    start thermalloadalgod 2>/dev/null
    start thermald 2>/dev/null

    resetprop persist.thermal.enable 1 2>/dev/null
    resetprop vendor.thermal.manager 1 2>/dev/null
    resetprop vendor.thermal.link_ready 1 2>/dev/null
    resetprop persist.vendor.thermal.enable 1 2>/dev/null

    pm enable --user 0 com.mediatek.thermal 2>/dev/null

    log_t "Thermal restored: $N zone nodes + buses unmounted, daemons restarted"
}

case "$GAME_PHASE" in
    game_end|restore|game_end)
        health_start "thermal"
        restore_all_temp_nodes
        rm -f "$CORTEX/thermal/spoof_c_session.txt"
        health_finish
        log_t "Game ended — thermal protection active"
        exit 0
        ;;
    game_start|game_start)
        health_start "thermal"
        kill_thermal_daemons
        spoof_temp_nodes
        health_finish
        log_t "Game started — thermal spoof active (mode: $THERMAL_MODE, ${SPOOF_C:-?}°C)"
        exit 0
        ;;
    "")
        health_start "thermal"
        kill_thermal_daemons
        spoof_temp_nodes
        health_finish
        log_t "Thermal engine armed + active (manual WebUI, mode: $THERMAL_MODE, ${SPOOF_C:-?}°C)"
        exit 0
        ;;
    *)
        echo "[THERMAL] Unknown argument: '$GAME_PHASE'" >&2
        echo "Usage: apply.sh [game_start|game_end]" >&2
        exit 1
        ;;
esac
