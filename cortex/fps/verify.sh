#!/system/bin/sh
# cortex/fps/verify.sh - Sweet Dreams
#
# Answers "is the Render Engine actually working" with real data instead of
# trusting the toggle position. Reads back every prop cortex/fps/engine.sh
# sets via `getprop` - the same command Android itself uses to read these -
# and reports which ones are present with their real current value vs which
# ones are missing/empty (meaning the resetprop write silently failed, was
# never applied, or was reset by something else since).
#
# USAGE: sh /data/adb/modules/sweet_dreams/cortex/fps/verify.sh
#        (works whether or not a game is currently running - just reports
#        current real state either way)

MODDIR="/data/adb/modules/sweet_dreams"
OUT="$MODDIR/fps_verify.txt"

# Every prop apply_frame_pacing()/apply_adpf_overlay() sets, grouped exactly
# as they appear in engine.sh so this stays easy to keep in sync if that
# script's prop list ever changes.
SF_PROPS="
debug.sf.early_phase_offset_ns
debug.sf.early_app_phase_offset_ns
debug.sf.early_gl_phase_offset_ns
debug.sf.high_fps_early_phase_offset_ns
debug.sf.high_fps_late_app_phase_offset_ns
debug.sf.late_app_phase_offset_ns
debug.sf.use_phase_offsets_as_durations
debug.sf.enable_frame_rate_pacing
debug.sf.predict_hwc_composition_strategy
debug.sf.enable_hwc_vds
"

HWUI_PROPS="
debug.hwui.render_thread
debug.hwui.use_partial_updates
debug.hwui.use_buffer_age
debug.hwui.skip_empty_damage
debug.hwui.render_dirty_regions
debug.hwui.enable_frame_rate_limit
debug.hwui.fps_divisor
"

INPUT_PROPS="
debug.input.low_latency
touch.pressure.scale
windowsmgr.max_events_per_sec
debug.egl.swapinterval
"

POWERHAL_PROPS="
persist.vendor.powerhal.adpf
persist.vendor.powerhal.fpsstabilizer
"

echo "=== Sweet Dreams Render Engine Verification ===" > "$OUT"
echo "Generated: $(date)" >> "$OUT"
echo "" >> "$OUT"

check_group() {
    local TITLE="$1" PROPS="$2"
    local SET=0 TOTAL=0
    echo "-- $TITLE --" >> "$OUT"
    for P in $PROPS; do
        [ -z "$P" ] && continue
        TOTAL=$((TOTAL + 1))
        VAL=$(getprop "$P" 2>/dev/null)
        if [ -n "$VAL" ]; then
            SET=$((SET + 1))
            echo "  [OK] $P = $VAL" >> "$OUT"
        else
            echo "  [ ] $P = (not set)" >> "$OUT"
        fi
    done
    echo "  -> $SET/$TOTAL active" >> "$OUT"
    echo "" >> "$OUT"
    echo "$SET $TOTAL"
}

SF_RESULT=$(check_group "SurfaceFlinger phase offsets" "$SF_PROPS")
HWUI_RESULT=$(check_group "HWUI render thread" "$HWUI_PROPS")
INPUT_RESULT=$(check_group "Input / touch responsiveness" "$INPUT_PROPS")
POWERHAL_RESULT=$(check_group "Power HAL / ADPF hints" "$POWERHAL_PROPS")

# -- Scheduler - these are sysctl values, not props, checked separately ------─
echo "-- Scheduler (sysctl) --" >> "$OUT"
SCHED_SET=0
for KV in \
    "kernel.sched_child_runs_first:0" \
    "kernel.sched_latency_ns:6000000" \
    "kernel.sched_migration_cost_ns:5000000"; do
    KEY="${KV%%:*}"
    EXPECT="${KV##*:}"
    NODE="/proc/sys/$(echo "$KEY" | tr '.' '/')"
    if [ -f "$NODE" ]; then
        REAL=$(cat "$NODE" 2>/dev/null)
        if [ "$REAL" = "$EXPECT" ]; then
            echo "  [OK] $KEY = $REAL (matches gaming profile)" >> "$OUT"
            SCHED_SET=$((SCHED_SET + 1))
        else
            echo "  [ ] $KEY = $REAL (expected $EXPECT - not in gaming profile right now)" >> "$OUT"
        fi
    else
        echo "  [ ] $KEY - node doesn't exist on this kernel" >> "$OUT"
    fi
done
echo "  -> $SCHED_SET/3 matching gaming profile" >> "$OUT"
echo "" >> "$OUT"

# -- ADPF game mode - the actual Android Game Mode Intervention API ----------─
echo "-- ADPF Game Mode (Android's own Game Dashboard API) --" >> "$OUT"
HAS_GAME_SERVICE=$(cat "$MODDIR/cortex/fps/has_game_service.txt" 2>/dev/null || echo "1")
if [ "$HAS_GAME_SERVICE" = "1" ]; then
    FG_PKG=$(dumpsys activity activities 2>/dev/null | grep -E "topResumedActivity|ResumedActivity" | head -1 | grep -oE '[a-zA-Z0-9_.]+/[a-zA-Z0-9_.]+' | head -1 | cut -d/ -f1)
    if [ -n "$FG_PKG" ]; then
        GM_STATE=$(cmd game mode "$FG_PKG" 2>&1)
        echo "  Foreground package: $FG_PKG" >> "$OUT"
        echo "  cmd game mode output: $GM_STATE" >> "$OUT"
    else
        echo "  No foreground app detected right now" >> "$OUT"
    fi
else
    echo "  [ ] 'cmd game' service is NOT exposed to shell on this device/ROM" >> "$OUT"
    echo "      (detected once at boot, cached in has_game_service.txt - this" >> "$OUT"
    echo "      is a real, permanent limitation on this firmware, not a bug)" >> "$OUT"
fi
echo "" >> "$OUT"

# -- Overall summary ----------------------------------------------------------─
TOTAL_SET=$(( $(echo "$SF_RESULT" | awk '{print $1}') + $(echo "$HWUI_RESULT" | awk '{print $1}') + $(echo "$INPUT_RESULT" | awk '{print $1}') + $(echo "$POWERHAL_RESULT" | awk '{print $1}') ))
TOTAL_ALL=$(( $(echo "$SF_RESULT" | awk '{print $2}') + $(echo "$HWUI_RESULT" | awk '{print $2}') + $(echo "$INPUT_RESULT" | awk '{print $2}') + $(echo "$POWERHAL_RESULT" | awk '{print $2}') ))

echo "-- Summary --" >> "$OUT"
echo "$TOTAL_SET / $TOTAL_ALL props confirmed active on this device right now." >> "$OUT"
if [ "$TOTAL_SET" -eq 0 ]; then
    echo "WARNING: zero props active. Either the engine hasn't run yet this boot" >> "$OUT"
    echo "(run it manually or launch a selected game), or resetprop writes are" >> "$OUT"
    echo "being rejected on this build." >> "$OUT"
elif [ "$TOTAL_SET" -lt "$TOTAL_ALL" ]; then
    echo "Partial - some props active, some not. Check the [ ] lines above for" >> "$OUT"
    echo "which specific ones aren't sticking on this device." >> "$OUT"
else
    echo "All tracked props are active and confirmed on this device." >> "$OUT"
fi

cat "$OUT"
echo ""
echo "Full report saved to: $OUT"
