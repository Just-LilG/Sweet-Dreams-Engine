#!/system/bin/sh
# Bind a fake /proc/cpuinfo into a running game's mount namespace.
# Zygisk COPG is the preferred path; this is the always-on fallback.

CORTEX="${CORTEX:-/data/adb/modules/sweet_dreams/cortex}"
MODDIR="/data/adb/modules/sweet_dreams"
COPG="/data/adb/modules/COPG"
PKG="$1"
ACTION="${2:-on}"

[ -z "$PKG" ] && exit 1

MASTER=$(cat "$CORTEX/games/spoof_master.txt" 2>/dev/null)
[ "$MASTER" = "on" ] || exit 0

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
    local pid
    for pid in $(pidof "$PKG" 2>/dev/null); do
        nsenter -t "$pid" -m -- umount -l /proc/cpuinfo >/dev/null 2>&1
    done
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
[ -n "$FILE" ] || exit 1

# Wait briefly for the process after launch/relaunch.
i=0
PIDS=""
while [ $i -lt 15 ]; do
    PIDS=$(pidof "$PKG" 2>/dev/null)
    [ -n "$PIDS" ] && break
    sleep 0.4
    i=$((i + 1))
done
[ -z "$PIDS" ] && exit 1

for pid in $PIDS; do
    nsenter -t "$pid" -m -- mount -o bind "$FILE" /proc/cpuinfo >/dev/null 2>&1
done
exit 0
