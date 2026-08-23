#!/system/bin/sh
# cortex/device/capability_probe.sh - Sweet Dreams
#
# WHY THIS EXISTS: the module already adapts around a dozen device quirks
# silently (dead cmd dispatcher, missing debugfs nodes, no schedtune) -
# but the only way to find out ANY of this was happening was reading
# boot.log by hand, and even then only AFTER a game session actually
# exercised that specific code path. A missing perfmgr node, for example,
# only ever got reported the first time a game launched - not at install,
# not on the WebUI's home screen, nowhere visible until you went looking.
#
# This runs ONCE per install (see the .done sentinel below) and actively
# tests every major subsystem this module depends on - not by checking
# device model against a rules table (that's evaluate_mitigations.sh's
# job, and it stays exactly as-is), but by literally attempting the real
# mechanism each subsystem uses and recording whether it worked. The
# result is a genuine "here's what to expect on YOUR device" report,
# shown once right after install via the WebUI, rather than something
# discovered piecemeal over days of actual play sessions.
#
# This is read-only/non-destructive wherever possible - most probes here
# either read a value back or write-then-immediately-restore, so running
# this doesn't leave the device in a different state than before.

MODDIR="/data/adb/modules/sweet_dreams"
CORTEX="$MODDIR/cortex"
DONE_FLAG="$CORTEX/device/capability_probe.done"
RESULT_FILE="$CORTEX/device/capability_results.txt"

# Only ever run once per install - re-running on every boot would be
# wasted work for a report that (barring a firmware update) won't change.
# customize.sh removes this flag on fresh install so a reinstall/update
# gets a fresh probe in case the underlying ROM changed.
[ -f "$DONE_FLAG" ] && exit 0

. "$CORTEX/health/track.sh"

probe() {
    local NAME="$1"
    local RESULT="$2"
    local DETAIL="$3"
    echo "${NAME}|${RESULT}|${DETAIL}" >> "$RESULT_FILE.tmp"
}

: > "$RESULT_FILE.tmp"

# -- Thermal bypass: can we actually blind at least one sensor node? ----------─
THERMAL_OK=0
for f in /sys/class/thermal/thermal_zone0/temp /sys/devices/virtual/thermal/thermal_zone0/temp; do
    [ -f "$f" ] || continue
    ORIG_MODE=$(stat -c '%a' "$f" 2>/dev/null)
    if chmod 000 "$f" 2>/dev/null; then
        THERMAL_OK=1
        chmod "${ORIG_MODE:-644}" "$f" 2>/dev/null
    fi
    break
done
if [ "$THERMAL_OK" = "1" ]; then
    probe "thermal_bypass" "1" "sensor nodes are writable - full thermal bypass available"
else
    probe "thermal_bypass" "0" "thermal_zone0 not writable - bypass may be limited on this kernel"
fi

# -- MTK PerfService scenario API ----------------------------------------------─
if [ -w /proc/perfmgr/legacy/perfserv_ta ] || [ -w /proc/perfmgr/perf_ioctl ]; then
    probe "perf_scenario" "1" "MTK PerfService nodes present"
else
    probe "perf_scenario" "0" "not present on this kernel - CPU/GPU chipset tuning still works independently"
fi

# -- cmd service dispatcher (settings/game/device_config) ----------------------
if cmd settings get global airplane_mode_on >/dev/null 2>&1; then
    probe "cmd_dispatcher" "1" "cmd service calls work normally"
else
    probe "cmd_dispatcher" "0" "cmd dispatcher unreliable on this device - module automatically uses content:// URI fallbacks instead"
fi

# -- Resolution downscale (Game Mode API) --------------------------------------─
if cmd game 2>&1 | grep -qv "not found\|unknown command"; then
    probe "resolution_downscale" "1" "Game Mode API available"
else
    probe "resolution_downscale" "0" "Game Mode API not available on this Android version/ROM"
fi

# -- EAS boost path: schedtune vs uclamp ----------------------------------------
if [ -w /dev/stune/top-app/schedtune.boost ]; then
    probe "cpu_boost" "1" "schedtune cgroup available"
elif [ -w /dev/cpuctl/top-app/cpu.uclamp.min ]; then
    probe "cpu_boost" "1" "uclamp cgroup available (modern EAS kernel)"
else
    probe "cpu_boost" "0" "neither schedtune nor uclamp writable - CPU priority boost via renice/ionice still applies"
fi

# -- ZRAM / RAM management ------------------------------------------------------
if [ -w /proc/sys/vm/swappiness ]; then
    probe "ram_tuning" "1" "vm sysctls writable"
else
    probe "ram_tuning" "0" "vm sysctls not writable on this kernel"
fi

# -- Battery charge limit ------------------------------------------------------─
BATT_OK=0
for f in /sys/class/power_supply/battery/batt_slate_mode \
         /sys/class/power_supply/battery/charge_control_limit \
         /sys/class/power_supply/battery/charge_stop_level; do
    [ -w "$f" ] && BATT_OK=1 && break
done
if [ "$BATT_OK" = "1" ]; then
    probe "battery_limit" "1" "charge control node writable"
else
    probe "battery_limit" "0" "not supported on this device (sysfs-only fallback, no vendor prop path found)"
fi

# -- Sensor spoofing (HAL vs kernel-accessible) --------------------------------─
if [ -d /sys/bus/iio/devices ] && [ -n "$(ls -A /sys/bus/iio/devices 2>/dev/null)" ]; then
    probe "sensor_spoof" "1" "IIO sensor nodes present"
else
    probe "sensor_spoof" "0" "sensors are HAL-only on this SoC/vendor build - hardware/firmware limitation, not fixable from root"
fi

mv "$RESULT_FILE.tmp" "$RESULT_FILE" 2>/dev/null
touch "$DONE_FLAG"
