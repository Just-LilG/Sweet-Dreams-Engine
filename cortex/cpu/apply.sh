#!/system/bin/sh
CORTEX="/data/adb/modules/sweet_dreams/cortex"
PROFILE=$(cat "$CORTEX/cpu/profile.txt" 2>/dev/null || echo "gaming")

set_gov() {
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo "$1" > "$f" 2>/dev/null
    done
}

# Detect little/big from cpufreq policy max, instead of assuming A55=0-5 / A76=6-7.
# The WebUI labels are illustrative; this is the mapping actually applied.
LITTLE_POL=""
BIG_POL=""
LITTLE_MAX_HW=0
BIG_MAX_HW=0
for p in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$p" ] || continue
    mx=$(cat "$p/cpuinfo_max_freq" 2>/dev/null || echo 0)
    case "$mx" in
        ''|*[!0-9]*) continue ;;
    esac
    [ "$mx" -gt 0 ] || continue
    if [ -z "$LITTLE_POL" ] || [ "$mx" -lt "$LITTLE_MAX_HW" ]; then
        LITTLE_POL="$p"
        LITTLE_MAX_HW="$mx"
    fi
    if [ -z "$BIG_POL" ] || [ "$mx" -gt "$BIG_MAX_HW" ]; then
        BIG_POL="$p"
        BIG_MAX_HW="$mx"
    fi
done

set_pol() {
    _pol="$1"
    _min="$2"
    _max="$3"
    [ -n "$_pol" ] && [ -d "$_pol" ] || return
    [ -n "$_min" ] && echo "$_min" > "$_pol/scaling_min_freq" 2>/dev/null
    [ -n "$_max" ] && echo "$_max" > "$_pol/scaling_max_freq" 2>/dev/null
}

# Fallback if this kernel has no policy nodes.
set_range() {
    _first="$1"
    _last="$2"
    _min="$3"
    _max="$4"
    i="$_first"
    while [ "$i" -le "$_last" ]; do
        echo "$_min" > /sys/devices/system/cpu/cpu${i}/cpufreq/scaling_min_freq 2>/dev/null
        echo "$_max" > /sys/devices/system/cpu/cpu${i}/cpufreq/scaling_max_freq 2>/dev/null
        i=$((i + 1))
    done
}

USER_LITTLE_MAX=$(cat "$CORTEX/cpu/a55_max_khz.txt" 2>/dev/null)
USER_BIG_MAX=$(cat "$CORTEX/cpu/a76_max_khz.txt" 2>/dev/null)
pick_max() {
    DEF="$1"
    USER="$2"
    HW="$3"
    case "$USER" in
        ''|*[!0-9]*) CHOSEN="$DEF" ;;
        *) CHOSEN="$USER" ;;
    esac
    if [ -n "$HW" ] && [ "$HW" -gt 0 ] 2>/dev/null && [ "$CHOSEN" -gt "$HW" ] 2>/dev/null; then
        echo "$HW"
    else
        echo "$CHOSEN"
    fi
}

case "$PROFILE" in
    gaming)
        set_gov "performance"
        LMIN=1800000 LDEF=2000000
        BMIN=2000000 BDEF=2200000
        ;;
    balanced)
        set_gov "schedutil"
        LMIN=500000 LDEF=2000000
        BMIN=725000 BDEF=2200000
        ;;
    battery)
        set_gov "powersave"
        LMIN=500000 LDEF=1200000
        BMIN=725000 BDEF=1500000
        ;;
    *)
        set_gov "schedutil"
        LMIN=500000 LDEF=2000000
        BMIN=725000 BDEF=2200000
        ;;
esac

LMAX=$(pick_max "$LDEF" "$USER_LITTLE_MAX" "$LITTLE_MAX_HW")
BMAX=$(pick_max "$BDEF" "$USER_BIG_MAX" "$BIG_MAX_HW")

if [ -n "$LITTLE_POL" ] && [ -n "$BIG_POL" ]; then
    set_pol "$LITTLE_POL" "$LMIN" "$LMAX"
    set_pol "$BIG_POL" "$BMIN" "$BMAX"
else
    set_range 0 5 "$LMIN" "$LMAX"
    set_range 6 7 "$BMIN" "$BMAX"
fi

sysctl -w vm.swappiness=10 2>/dev/null
sysctl -w vm.vfs_cache_pressure=80 2>/dev/null
sysctl -w vm.dirty_expire_centisecs=500 2>/dev/null
sysctl -w vm.dirty_writeback_centisecs=3000 2>/dev/null
