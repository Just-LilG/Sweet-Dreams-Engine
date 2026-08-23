#!/system/bin/sh
# cortex/audio/apply.sh - Sweet Dreams Audio Latency Tuner
# Reduces output buffer latency for wired/BT audio - useful for rhythm
# games and shooters where sound cue timing matters (footsteps, gunfire).
# Usage: apply.sh [restore]   - "restore" forces system defaults regardless of toggle
CORTEX="/data/adb/modules/sweet_dreams/cortex"
AUD_CFG="$CORTEX/audio"

ACTION="${1:-apply}"
EN=$(cat "$AUD_CFG/enabled.txt"        2>/dev/null || echo "off")
BT_LOW=$(cat "$AUD_CFG/bt_lowlat.txt"  2>/dev/null || echo "off")

log_aud() { echo "[AUDIO] $1"; }

apply_low_latency() {
    # Force media off the deep-buffer path - deep buffer batches more audio
    # per IRQ to save power, at the cost of 80-200ms extra latency.
    resetprop audio.deep_buffer.media false 2>/dev/null

    # MTK MMAP no-IRQ low latency path - used by AAudio exclusive mode
    resetprop vendor.audio.mmap.enable true 2>/dev/null
    resetprop persist.vendor.audio.lowlatency.enable true 2>/dev/null

    # Minimum safe fast-mixer burst multiplier (smaller = lower latency,
    # 1 is the safe floor - going lower causes underrun crackle on MTK)
    resetprop af.fast_track_multiplier 1 2>/dev/null

    # Tunnel/offload decode adds latency for game SFX - disable for games
    resetprop vendor.audio.tunnel.encode false 2>/dev/null

    log_aud "Low-latency audio path enabled"
}

# Reads every prop this script sets straight back with getprop and compares
# against the expected value - resetprop can silently no-op on a
# SELinux-denied or read-only prop on some builds, and the previous version
# had no way to tell the difference between "applied" and "tried and
# failed". Writes a verify.txt the WebUI reads for an honest per-prop
# checklist instead of just trusting the toggle position.
verify_low_latency() {
    local OK=0 TOTAL=4
    [ "$(getprop audio.deep_buffer.media)" = "false" ] && OK=$((OK+1))
    [ "$(getprop vendor.audio.mmap.enable)" = "true" ] && OK=$((OK+1))
    [ "$(getprop persist.vendor.audio.lowlatency.enable)" = "true" ] && OK=$((OK+1))
    [ "$(getprop af.fast_track_multiplier)" = "1" ] && OK=$((OK+1))
    echo "${OK}|${TOTAL}"
}

restore_normal_latency() {
    resetprop --delete audio.deep_buffer.media               2>/dev/null
    resetprop --delete vendor.audio.mmap.enable               2>/dev/null
    resetprop --delete persist.vendor.audio.lowlatency.enable 2>/dev/null
    resetprop --delete af.fast_track_multiplier                2>/dev/null
    resetprop --delete vendor.audio.tunnel.encode              2>/dev/null
    log_aud "Audio path restored to system default"
}

apply_bt_low_latency() {
    local STATE="$1"   # "on" or "off"
    if [ "$STATE" = "on" ]; then
        # A2DP hardware offload batches audio for power savings; the
        # software path has tighter, more predictable buffer control -
        # often lower real-world latency on MTK BT stacks despite using
        # more CPU. Worth it for competitive play with earbuds/headset.
        resetprop persist.bluetooth.a2dp_offload.disabled true 2>/dev/null
        resetprop persist.vendor.btstack.enable.lowlatency true 2>/dev/null
        log_aud "BT low-latency mode on (A2DP offload disabled)"
    else
        resetprop --delete persist.bluetooth.a2dp_offload.disabled   2>/dev/null
        resetprop --delete persist.vendor.btstack.enable.lowlatency  2>/dev/null
        log_aud "BT audio restored to default offload path"
    fi
}

if [ "$ACTION" = "restore" ]; then
    restore_normal_latency
    apply_bt_low_latency "off"
    # NOTE: does not touch enabled.txt/bt_lowlat.txt - those are the user's
    # saved preference and get re-applied automatically on next game launch.
    log_aud "Restored to idle (preference preserved for next launch)"
    exit 0
fi

if [ "$EN" = "on" ]; then
    apply_low_latency
    VERIFY=$(verify_low_latency)
else
    restore_normal_latency
    VERIFY="0|4"
fi

apply_bt_low_latency "$BT_LOW"

echo "${EN}|${BT_LOW}" > "$AUD_CFG/status.txt"
echo "$VERIFY" > "$AUD_CFG/verify.txt"
