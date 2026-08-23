#!/system/bin/sh
# cortex/thermal/daemons_lib.sh - Sweet Dreams
#
# kill_thermal_daemons - dynamic resetprop scan + hardcoded set + pkill
# sweep. Extracted out of thermal/apply.sh so it can be shared by both:
#   - thermal/apply.sh itself (game_start/game_end/"" cases - sensor
#     blackout paths)
#   - thermal/kill_daemons_only.sh (boot-time only - daemon stop, no
#     sensor blackout at all; see that file and service.sh's own comment
#     on why boot no longer calls into apply.sh's blackout logic)
# Kept as one copy so a future change to how daemons are detected/killed
# only needs to happen in one place.
#
# Depends on log_t() being defined by the sourcing script.

kill_thermal_daemons() {
    # Dynamic scan - stops any init service with "thermal" in its name
    for svc in $(resetprop | awk -F'[][]' '/\[init\.svc\..*thermal/ { print $2 }'); do
        CLEAN="${svc#init.svc.}"
        if [ "$(resetprop "$svc")" = "running" ]; then
            stop "$CLEAN"                2>/dev/null
            resetprop -n "$svc" stopped  2>/dev/null
        fi
    done

    # Hardcoded set
    stop thermal-engine      2>/dev/null
    stop thermal_manager     2>/dev/null
    stop thermalloadalgod    2>/dev/null
    stop thermald            2>/dev/null
    stop mi_thermald         2>/dev/null
    stop vendor.thermal-hal  2>/dev/null
    stop vendor.thermal      2>/dev/null

    # MTK thermal app - retry loop (pm subsystem may not be ready at boot)
    local TRIES=0
    until [ "$TRIES" -ge 5 ]; do
        pm suspend      --user 0 com.mediatek.thermal >/dev/null 2>&1 && break
        pm disable-user --user 0 com.mediatek.thermal >/dev/null 2>&1 && break
        TRIES=$((TRIES + 1))
        sleep 1
    done

    # pkill sweep
    pkill -f thermal-engine  2>/dev/null
    pkill -f thermald        2>/dev/null
    pkill -f mi_thermald     2>/dev/null

    # Props
    resetprop persist.thermal.enable        0 2>/dev/null
    resetprop vendor.thermal.manager        0 2>/dev/null
    resetprop vendor.thermal.link_ready     0 2>/dev/null
    resetprop persist.vendor.thermal.enable 0 2>/dev/null

    log_t "Thermal daemons killed"
}
