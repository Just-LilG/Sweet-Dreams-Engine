#!/system/bin/sh
# cortex/thermal/kill_daemons_only.sh - Sweet Dreams
#
# WHY THIS EXISTS: service.sh used to call thermal/apply.sh directly at
# boot with no phase argument, which hits the same "" case the WebUI's
# manual Thermal Spoof toggle uses to arm sensor blackout immediately.
# That meant every boot blinded every temp sensor node (including
# battery) system-wide and left them blind permanently - regardless of
# whether Thermal Spoof was even armed in status.txt, and regardless of
# whether a game was ever launched. That directly contradicted the
# WebUI's own description of the feature ("Only overrides sensor
# readings while a selected game is actually running" / the toggle's own
# toast: "Armed - activates when a game launches").
#
# The actual intended design (confirmed from status.txt's default
# ("disabled" = armed) and game_monitor.sh only ever calling
# thermal/apply.sh game_start when status.txt is "disabled") was always
# session-scoped - sensor blackout is only supposed to happen while a
# selected game is actually running, applied by game_monitor.sh's own
# game_start/game_end calls into apply.sh. Boot itself should never
# blind a sensor node on its own.
#
# What boot SHOULD still do unconditionally: stop the vendor thermal
# daemons. Leaving thermal-engine/thermald/com.mediatek.thermal running
# would fight this module's own cpu/gpu/thermal tuning regardless of
# whether Thermal Spoof is armed - that part of the original behavior
# was correct and is preserved here. What changed is narrowing this
# boot-time call to ONLY that - no chmod 000 on any sensor node, ever,
# from this script. Sensor blackout now only ever happens via
# game_monitor.sh's game_start call into thermal/apply.sh, gated on
# status.txt being "disabled" (armed) - exactly like every other
# game-session effect (kill_bg, net tuning, touch profile) already works.

MODDIR="/data/adb/modules/sweet_dreams"
CORTEX="$MODDIR/cortex"
LOGFILE="$MODDIR/boot.log"

log_t() { echo "[THERMAL] $1" | tee -a "$LOGFILE"; }

. "$CORTEX/thermal/daemons_lib.sh"

kill_thermal_daemons
log_t "Boot: vendor thermal daemons stopped, sensors left readable (blackout only applies when a game launches, if Thermal Spoof is armed)"
