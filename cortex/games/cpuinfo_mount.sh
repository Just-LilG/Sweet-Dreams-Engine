#!/system/bin/sh
# Bind a fake /proc/cpuinfo for a foreground game (COPG-style fallback).
#
# Android apps run in private mount namespaces, so a global bind of
# /proc/cpuinfo is often invisible to the game. Prefer nsenter into every
# PID that belongs to the package; keep a global bind as a best-effort
# extra for older ROMs that still share the init mount ns.
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
    fi
    rm -f "$STATE"
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

# Collect every PID whose main cmdline is the package or a :service of it.
pkg_pids() {
    local pid cmd
    for pid in /proc/[0-9]*; do
        [ -r "$pid/cmdline" ] || continue
        cmd=$(tr '\0' '\n' < "$pid/cmdline" 2>/dev/null | head -1)
        case "$cmd" in
            "$PKG"|"$PKG":*) printf '%s\n' "${pid##*/}" ;;
        esac
    done
}

unmount_cpuinfo() {
    if grep -q ' /proc/cpuinfo ' /proc/mounts 2>/dev/null; then
        umount -l /proc/cpuinfo >/dev/null 2>&1
        log_cpu "Unmounted global /proc/cpuinfo"
    fi
    for pid in $(pkg_pids); do
        nsenter -t "$pid" -m -- umount -l /proc/cpuinfo >/dev/null 2>&1
    done
    # Legacy pidof sweep for odd process names.
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

ok=0

# 1) Per-app mount namespaces (what the game actually sees).
for pid in $(pkg_pids); do
    if nsenter -t "$pid" -m -- mount -o bind "$FILE" /proc/cpuinfo >/dev/null 2>&1; then
        ok=1
    fi
done

# pidof fallback if /proc cmdline scan found nothing yet (cold start race).
if [ "$ok" != "1" ]; then
    for pid in $(pidof "$PKG" 2>/dev/null); do
        if nsenter -t "$pid" -m -- mount -o bind "$FILE" /proc/cpuinfo >/dev/null 2>&1; then
            ok=1
        fi
    done
fi

# 2) Global bind — helps older shared-ns ROMs; harmless if apps ignore it.
grep -q ' /proc/cpuinfo ' /proc/mounts 2>/dev/null && umount -l /proc/cpuinfo >/dev/null 2>&1
if mount -o bind "$FILE" /proc/cpuinfo >/dev/null 2>&1; then
    ok=1
fi

if [ "$ok" = "1" ]; then
    echo "$FILE" > "$STATE"
    log_cpu "Bound $FILE for $PKG (key=$KEY, nsenter+global)"
    exit 0
fi

log_cpu "FAILED to bind $FILE for $PKG (no PIDs yet or mount blocked)"
exit 1
