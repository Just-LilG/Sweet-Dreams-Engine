#!/system/bin/sh
# Bind a fake /proc/cpuinfo the way COPG's controller does for a foreground game:
# system-level MS_BIND onto /proc/cpuinfo (not a private game mount ns via nsenter).
# Zygisk companion is still preferred when it loads; this is the always-on fallback
# that re-asserts every game_monitor tick while the game is up.
#
# Usage: cpuinfo_mount.sh <package> [on|off]

CORTEX="${CORTEX:-/data/adb/modules/sweet_dreams/cortex}"
MODDIR="/data/adb/modules/sweet_dreams"
COPG="/data/adb/modules/COPG"
PKG="$1"
ACTION="${2:-on}"
STATE="$CORTEX/games/cpuinfo_mounted.txt"
LOGFILE="$MODDIR/boot.log"

[ -z "$PKG" ] && exit 1

log_cpu() { echo "[CPUINFO] $1" >> "$LOGFILE"; }

MASTER=$(cat "$CORTEX/games/spoof_master.txt" 2>/dev/null | tr -d '\r\n ')
if [ "$MASTER" != "on" ]; then
    if grep -q ' /proc/cpuinfo ' /proc/mounts 2>/dev/null; then
        umount -l /proc/cpuinfo >/dev/null 2>&1
        rm -f "$STATE"
        log_cpu "Master off — unmounted /proc/cpuinfo"
    fi
    exit 0
fi

cpu_key_for() {
    local line tag
    line=$(grep -E "^${PKG}(:|$|\|)" "$CORTEX/games/spoof_assignments.txt" 2>/dev/null | head -1)
    [ -z "$line" ] && return 1
    tag=$(printf '%s' "$line" | cut -d'|' -f1)
    case "$tag" in
        *:cpu=*) printf '%s' "$tag" | sed 's/.*:cpu=//' | cut -d: -f1 ;;
        *) return 1 ;;
    esac
}

unmount_cpuinfo() {
    if grep -q ' /proc/cpuinfo ' /proc/mounts 2>/dev/null; then
        umount -l /proc/cpuinfo >/dev/null 2>&1
        log_cpu "Unmounted /proc/cpuinfo"
    fi
    # Legacy per-ns leftovers from older builds.
    for pid in $(pidof "$PKG" 2>/dev/null); do
        nsenter -t "$pid" -m -- umount -l /proc/cpuinfo >/dev/null 2>&1
    done
    rm -f "$STATE"
}

if [ "$ACTION" = "off" ]; then
    unmount_cpuinfo
    exit 0
fi

KEY=$(cpu_key_for) || exit 0
FILE=""
for d in "$COPG/CPU" "$MODDIR/CPU"; do
    [ -f "$d/cpuinfo_$KEY" ] && FILE="$d/cpuinfo_$KEY" && break
done
if [ -z "$FILE" ]; then
    log_cpu "Missing CPU/cpuinfo_$KEY for $PKG"
    exit 1
fi

chmod 0444 "$FILE" 2>/dev/null
chcon u:object_r:system_file:s0 "$FILE" 2>/dev/null

# Already mounted to the same file — nothing to do.
CUR=$(cat "$STATE" 2>/dev/null)
if [ "$CUR" = "$FILE" ] && grep -q ' /proc/cpuinfo ' /proc/mounts 2>/dev/null; then
    exit 0
fi

# Remount cleanly (COPG-style foreground reconcile).
grep -q ' /proc/cpuinfo ' /proc/mounts 2>/dev/null && umount -l /proc/cpuinfo >/dev/null 2>&1

if mount -o bind "$FILE" /proc/cpuinfo >/dev/null 2>&1; then
    echo "$FILE" > "$STATE"
    log_cpu "Bound $FILE -> /proc/cpuinfo for $PKG (key=$KEY)"
    exit 0
fi

# Fallback: per-process mount ns (older Sweet Dreams path). Works on some
# ROMs where global /proc bind is blocked; COPG prefers the global path above.
ok=0
for pid in $(pidof "$PKG" 2>/dev/null); do
    if nsenter -t "$pid" -m -- mount -o bind "$FILE" /proc/cpuinfo >/dev/null 2>&1; then
        ok=1
    fi
done
if [ "$ok" = "1" ]; then
    echo "$FILE" > "$STATE"
    log_cpu "nsenter-bound $FILE for $PKG PIDs (global bind failed)"
    exit 0
fi

log_cpu "FAILED to bind $FILE for $PKG"
exit 1
