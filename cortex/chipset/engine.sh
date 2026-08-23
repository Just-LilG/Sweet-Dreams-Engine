#!/system/bin/sh
# cortex/chipset/engine.sh - Sweet Dreams Chipset Engine
# Native replacement for Frieren_Chipset (system/bin/Frieren_Chipset).
#
# We pulled the binary's string table (it even ships its own source filename,
# frieren_chipset.c) and found it does two genuinely different things bundled
# into one executable:
#
#   1. Writes a set of powerHAL/graphics performance props, some MediaTek
#      (debug.mediatek.*) and some Qualcomm (vendor.qti.hardware.perf.*,
#      debug.qc.hardware). The Qualcomm ones are dead writes on this Helio
#      G200 - same mismatch we found in Frieren_FPS and Frieren_AI_Games.
#   2. On every single run, posts a system notification titled "FrierenAI"
#      via `su 2000 -c 'cmd notification post ...'`, with a Shizuku fallback
#      if su isn't available, and ALSO tries to launch a separate unrelated
#      app (`bellavita.toast`) to show a toast. That's exactly the
#      "FPS Stabilizer: 120 Hz - Frieren AI" notification you saw - it's not
#      a bug, it's the binary's deliberate self-branding on every boot.
#
# This rewrite keeps the legitimate prop tuning (MTK props only - no point
# writing Qualcomm paths on this SoC) and the backup/restore mechanism,
# and drops the notification/Shizuku/third-party-app branding entirely.
# Nothing in this module should be posting notifications under any name.

MODDIR="/data/adb/modules/sweet_dreams"
CORTEX="$MODDIR/cortex"
BACKUP_DIR="/data/local/tmp/frieren_render/backup"
BACKUP_FILE="$BACKUP_DIR/chipset_props.txt"

ACTION="${1:-activate}"

log_chip() { echo "[CHIPSET] $1"; }

# Every prop this engine manages - kept in one list so activate/backup/
# restore all stay in sync with the exact same set.
PROPS="
persist.sys.powerhal.performance
persist.sys.powerhal.gpu
persist.sys.powerhal.interactive
persist.vendor.powerhal.fpsstabilizer
persist.vendor.powerhal.adpf
persist.vendor.powerhal.rendering
persist.vendor.powerhal.graphics
persist.vendor.powerhal.smart_launch
persist.sys.ui.hw
debug.mediatek.appgamepq
debug.mediatek.appgamepq_compress
debug.mediatek.disp_decompress
debug.mediatek.high_frame_rate_sf_set_big_core_fps_threshold
debug.performance.tuning
debug.gralloc.gfx_ubwc_disable
"

backup_props() {
    [ -f "$BACKUP_FILE" ] && return  # already backed up, never overwrite with our own values
    mkdir -p "$BACKUP_DIR"
    : > "$BACKUP_FILE"
    for P in $PROPS; do
        V=$(getprop "$P" 2>/dev/null)
        echo "${P}=${V}" >> "$BACKUP_FILE"
    done
    log_chip "Original props backed up"
}

activate() {
    backup_props

    local SOC
    SOC=$(getprop ro.soc.model 2>/dev/null)
    [ -z "$SOC" ] && SOC=$(getprop ro.hardware 2>/dev/null)
    [ -z "$SOC" ] && SOC="Unknown"

    # MediaTek game/performance hints - these are the ones that actually do
    # something on this SoC.
    resetprop debug.mediatek.appgamepq                                    1     2>/dev/null
    resetprop debug.mediatek.appgamepq_compress                           1     2>/dev/null
    resetprop debug.mediatek.disp_decompress                              1     2>/dev/null
    resetprop debug.mediatek.high_frame_rate_sf_set_big_core_fps_threshold 60   2>/dev/null

    # Generic AOSP/vendor powerHAL hints - harmless to set even where the
    # vendor HAL doesn't read them, unlike the Qualcomm-specific paths we
    # deliberately left out (vendor.qti.hardware.perf.performance,
    # debug.qc.hardware - those are guaranteed no-ops on MTK).
    resetprop persist.sys.powerhal.performance      1    2>/dev/null
    resetprop persist.sys.powerhal.gpu              1    2>/dev/null
    resetprop persist.sys.powerhal.interactive      1    2>/dev/null
    resetprop persist.vendor.powerhal.fpsstabilizer 1    2>/dev/null
    resetprop persist.vendor.powerhal.adpf          1    2>/dev/null
    resetprop persist.vendor.powerhal.rendering     1    2>/dev/null
    resetprop persist.vendor.powerhal.graphics      1    2>/dev/null
    resetprop persist.vendor.powerhal.smart_launch  1    2>/dev/null
    resetprop persist.sys.ui.hw                     true 2>/dev/null
    resetprop debug.performance.tuning              1    2>/dev/null
    resetprop debug.gralloc.gfx_ubwc_disable        0    2>/dev/null

    log_chip "Processor props activated for ${SOC}"
}

restore() {
    if [ ! -f "$BACKUP_FILE" ]; then
        log_chip "No backup found, nothing to restore"
        return
    fi
    while IFS='=' read -r KEY VAL; do
        [ -z "$KEY" ] && continue
        if [ -z "$VAL" ]; then
            resetprop --delete "$KEY" 2>/dev/null
        else
            resetprop "$KEY" "$VAL" 2>/dev/null
        fi
    done < "$BACKUP_FILE"
    log_chip "Processor properties restored to original values"
}

case "$ACTION" in
    activate) activate ;;
    restore)  restore  ;;
    *)
        echo "Usage: engine.sh activate|restore" >&2
        exit 1
        ;;
esac
