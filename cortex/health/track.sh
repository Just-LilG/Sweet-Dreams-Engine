#!/system/bin/sh
# cortex/health/track.sh - Sweet Dreams Health Tracking
#
# WHY THIS EXISTS: every apply script (thermal, net, perf, cpu, gpu, etc)
# was writing 2>/dev/null on every command and never recording whether it
# actually worked. This session alone found three confirmed silent-failure
# classes on this specific device (dead `cmd` service dispatcher, a missing
# debugfs node, unreliable `date +%N`) that were invisible anywhere except
# grepping boot.log by hand. This module gives every apply script a
# 3-line way to report "did this specific check actually succeed" into one
# shared, structured file the WebUI can read and show a real status from,
# instead of just assuming success like the scripts did before.
#
# USAGE (source this at the top of any apply script):
#   . "$CORTEX/health/track.sh"
#   health_start "thermal"                    # begin a report for this subsystem
#   health_check "kill_daemons" "$RESULT"      # RESULT: 0=ok, nonzero=failed
#   health_check "blind_sensors" "$RESULT"
#   health_finish                              # writes the accumulated report
#
# STORAGE FORMAT (cortex/health/<subsystem>.status - one file per subsystem,
# avoids concurrent writers from different scripts stepping on each other):
#   timestamp|check_name|0_or_1|optional_detail
#   (one line per check from the most recent run of that subsystem)
#
# The WebUI reads all cortex/health/*.status files and surfaces a single
# "N optimizations failed to apply" banner instead of the user needing to
# grep boot.log to discover something's silently broken.

HEALTH_DIR="/data/adb/modules/sweet_dreams/cortex/health"
mkdir -p "$HEALTH_DIR" 2>/dev/null

_HEALTH_SUBSYSTEM=""
_HEALTH_BUF=""

health_start() {
    _HEALTH_SUBSYSTEM="$1"
    _HEALTH_BUF=""
}

# health_check <name> <exit_status> [detail]
# exit_status: 0 = success, anything else = failure. Pass "$?" directly
# right after the command you're checking, or the return of a function
# that itself returns a real status.
health_check() {
    local NAME="$1"
    local STATUS="$2"
    local DETAIL="${3:-}"
    local OK=1
    [ "$STATUS" = "0" ] && OK=1 || OK=0
    # OK=1 means success in our stored format (readable as "1=passed"),
    # inverted from shell's 0=success convention on purpose - this file is
    # read by JS in the WebUI, where truthy-1-means-good reads more
    # naturally than shell's 0-means-good when displayed directly.
    _HEALTH_BUF="${_HEALTH_BUF}$(date +%s)|${NAME}|${OK}|${DETAIL}
"
}

health_finish() {
    [ -z "$_HEALTH_SUBSYSTEM" ] && return
    printf '%s' "$_HEALTH_BUF" > "$HEALTH_DIR/${_HEALTH_SUBSYSTEM}.status"
    _HEALTH_SUBSYSTEM=""
    _HEALTH_BUF=""
}
