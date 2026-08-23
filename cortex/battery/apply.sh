#!/system/bin/sh
CORTEX="/data/adb/modules/sweet_dreams/cortex"
BAT_CFG="$CORTEX/battery"

LIMIT_EN=$(cat "$BAT_CFG/limit_enabled.txt" 2>/dev/null || echo "off")
LIMIT_PCT=$(cat "$BAT_CFG/limit_pct.txt"     2>/dev/null || echo "80")

log_bat() { echo "[BAT] $1"; }

# Quietly test if a sysfs node is actually writable before attempting it -
# avoids spamming the log with guaranteed "Permission denied" lines on
# firmware that SELinux-locks these nodes even from a rooted shell.
is_writable() { [ -w "$1" ] 2>/dev/null; }

# -- MTK charge limit (try all known locations, but only if writable) --------─
set_charge_limit() {
    local PCT="$1"
    local APPLIED=""

    # Method 1: MTK batt_slate_mode (0=normal, 1=stop charge at ~80%)
    if [ "$PCT" -le 80 ] && is_writable /sys/class/power_supply/battery/batt_slate_mode; then
        echo "1" > /sys/class/power_supply/battery/batt_slate_mode 2>/dev/null && \
            APPLIED="batt_slate_mode"
    fi

    # Method 2: Infinix/Transsion specific path
    if [ -z "$APPLIED" ] && is_writable /sys/class/power_supply/battery/charge_control_limit; then
        echo "$PCT" > /sys/class/power_supply/battery/charge_control_limit 2>/dev/null && \
            APPLIED="charge_control_limit"
    fi
    if [ -z "$APPLIED" ] && is_writable /sys/class/power_supply/battery/charge_stop_level; then
        echo "$PCT" > /sys/class/power_supply/battery/charge_stop_level 2>/dev/null && \
            APPLIED="charge_stop_level"
    fi

    # Method 3: MTK charger node
    if [ -z "$APPLIED" ] && is_writable /sys/class/power_supply/mtk-gauge/charge_stop_level; then
        echo "$PCT" > /sys/class/power_supply/mtk-gauge/charge_stop_level 2>/dev/null && \
            APPLIED="mtk-gauge"
    fi

    # Method 4: vendor props - goes through init's property service, not raw
    # sysfs write, so it works even when every sysfs node above is locked by
    # SELinux. This is the most reliable path on locked-down firmware, but
    # only takes effect on the vendor's own battery HAL if it reads these
    # props - not guaranteed on every device.
    resetprop persist.vendor.battery.protect.enable 1     2>/dev/null
    resetprop persist.vendor.battery.protect.level "$PCT" 2>/dev/null
    resetprop ro.vendor.battery.charge.level "$PCT"        2>/dev/null

    if [ -n "$APPLIED" ]; then
        log_bat "Charge limit ${PCT}% applied via $APPLIED (kernel-enforced)"
    else
        log_bat "Charge limit ${PCT}% set via prop only - kernel sysfs nodes are SELinux-locked on this firmware, vendor HAL may not enforce it"
    fi
}

remove_charge_limit() {
    is_writable /sys/class/power_supply/battery/batt_slate_mode        && echo "0"   > /sys/class/power_supply/battery/batt_slate_mode        2>/dev/null
    is_writable /sys/class/power_supply/battery/charge_control_limit   && echo "100" > /sys/class/power_supply/battery/charge_control_limit   2>/dev/null
    is_writable /sys/class/power_supply/battery/charge_stop_level      && echo "100" > /sys/class/power_supply/battery/charge_stop_level      2>/dev/null
    is_writable /sys/class/power_supply/mtk-gauge/charge_stop_level    && echo "100" > /sys/class/power_supply/mtk-gauge/charge_stop_level    2>/dev/null
    resetprop persist.vendor.battery.protect.enable 0    2>/dev/null
    resetprop persist.vendor.battery.protect.level "100" 2>/dev/null
    log_bat "Charge limit removed"
}

if [ "$LIMIT_EN" = "on" ]; then
    set_charge_limit "$LIMIT_PCT"
else
    remove_charge_limit
fi

# Write status
CUR_CAP=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null || echo "-")
CHARGING=$(cat /sys/class/power_supply/battery/status   2>/dev/null || echo "Unknown")
echo "${LIMIT_EN}|${LIMIT_PCT}|${CUR_CAP}|${CHARGING}" > "$BAT_CFG/status.txt"
