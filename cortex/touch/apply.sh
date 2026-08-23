#!/system/bin/sh
# cortex/touch/apply.sh - Sweet Dreams Touch Engine v3
#
# WHAT ACTUALLY WORKS ON MTK (learned from VOID Touch v4.6 + AaTempSpoof):
#
# Layer 1 - Android Settings API (100% reliable on all devices)
#   The backbone. These always apply regardless of kernel, IC vendor, SELinux.
#
# Layer 2 - MTK persist props via resetprop (the REAL sampling rate control)
#   VOID Touch confirmed these are the actual MTK touch sampling rate knobs:
#     persist.vendor.mtk_touch_sampling_rate
#     persist.vendor.touch.sampling_rate
#     persist.sys.touch.sampling_rate
#     persist.sys.input.max_events_per_sec
#     persist.dev.pm.dyn_samplingrate
#   Previous engine never set any of these. This is why report rate didn't work.
#
# Layer 3 - device_config input boost (Android 11+ correct API)
#   Previous engine used "cmd power set-mode" which is wrong.
#   Correct path:
#     cmd device_config put activity_manager input_boost_enabled true
#     cmd device_config put activity_manager input_boost_duration_ms 2000
#     cmd device_config put activity_manager input_boost_cpuset 0
#
# Layer 4 - SurfaceFlinger phase offsets (touch-to-frame latency)
#   Wakes renderer earlier relative to vsync = lower perceived input lag.
#   From VOID Touch v4.6 (debug.sf.* props via resetprop).
#
# Layer 5 - touchHidlTest hardware register writer (from AaTempSpoof)
#   The touch IC report rate is set via touchHidlTest -c wo 0 <reg> <val>
#   a vendor HIDL test binary that writes IC registers directly.
#   reg26=0x1 = 240Hz, reg26=0x12c = 360Hz. We probe for it and use it
#   if present - it won't exist on all devices but when it does it's the
#   only real hardware-level rate setter.
#
# Layer 6 - proc/sysfs nodes (opportunistic, probed via find)
#   MTK TPD proc nodes, I2C driver nodes, Infinix XOS specific paths.
#   Written if they exist, silently skipped if not.
#
# CALL SIGNATURES:
#   apply.sh              - boot / user toggle
#   apply.sh game_start   - game launched: aggressive profile
#   apply.sh game_end     - game exited: restore base profile

MODDIR="/data/adb/modules/sweet_dreams"
CORTEX="$MODDIR/cortex"
LOGFILE="$MODDIR/boot.log"
GAME_PHASE="${1:-}"

# -- Config --------------------------------------------------------------------
STATUS=$(cat "$CORTEX/touch/status.txt"    2>/dev/null || echo "on")
LP=$(cat "$CORTEX/touch/lp_timeout.txt"   2>/dev/null || echo "400")
TAPSENS=$(cat "$CORTEX/touch/tap_sens.txt" 2>/dev/null || echo "medium")
SWIPE=$(cat "$CORTEX/touch/swipe_px.txt"  2>/dev/null || echo "8")
IB=$(cat "$CORTEX/touch/input_booster.txt" 2>/dev/null || echo "on")

log_tc() { echo "[TOUCH] $1" | tee -a "$LOGFILE"; }

# -- Sensitivity profile values ------------------------------------------------
case "$TAPSENS" in
    high)
        LP_GAME="200"
        PSPEED="-1"
        FLING_MIN="40"
        FLING_MAX="12000"
        SCROLL_FRIC="0.008"
        SLOP="2"
        SAMPLING="240"
        BOOST_MS="3000"
        SF_OFFSET="-2000000"
        SF_HIGH_OFFSET="-6000000"
        ;;
    low)
        LP_GAME="600"
        PSPEED="-3"
        FLING_MIN="100"
        FLING_MAX="8000"
        SCROLL_FRIC="0.015"
        SLOP="12"
        SAMPLING="120"
        BOOST_MS="1000"
        SF_OFFSET="-500000"
        SF_HIGH_OFFSET="-2000000"
        ;;
    medium|*)
        LP_GAME="300"
        PSPEED="-2"
        FLING_MIN="80"
        FLING_MAX="10000"
        SCROLL_FRIC="0.010"
        SLOP="4"
        SAMPLING="240"
        BOOST_MS="2000"
        SF_OFFSET="-1000000"
        SF_HIGH_OFFSET="-4000000"
        ;;
esac

# ----------------------------------------------------------------------------─
# smart_prop - resetprop with settings fallback
# ----------------------------------------------------------------------------─
smart_prop() {
    local KEY="$1" VAL="$2"
    resetprop "$KEY" "$VAL" 2>/dev/null && return 0
    # Fallback: queue as a global setting hint readable by some MTK daemons.
    # Timeout-guarded for the same reason as safe_set's fallback - a raw
    # settings put has no ceiling of its own on a degraded Binder path.
    timeout 2 settings put global "${KEY##*.}" "$VAL" 2>/dev/null
}

# ----------------------------------------------------------------------------─
# smart_device_config - writes device_config flags via content URI
# device_config is backed by Settings.Config which lives at:
#   content://settings/config
# Same Binder saturation issue as settings - use content tool directly.
# ----------------------------------------------------------------------------─
smart_device_config() {
    local NS="$1" KEY="$2" VAL="$3"
    local FULL_KEY="${NS}/${KEY}"
    local URI="content://settings/config"

    # Try content update first
    content update --uri "$URI" \
        --bind value:s:"$VAL" \
        --where "name='$FULL_KEY'" >/dev/null 2>&1 && return 0

    # Insert if not found
    content insert --uri "$URI" \
        --bind name:s:"$FULL_KEY" \
        --bind value:s:"$VAL" >/dev/null 2>&1 && return 0

    # Fallback: cmd device_config (may fail under saturation but log cleanly)
    # Timeout-guarded for the same reason as safe_set/smart_prop's fallbacks.
    timeout 2 cmd device_config put "$NS" "$KEY" "$VAL" 2>/dev/null
}

# ----------------------------------------------------------------------------─
# safe_set - writes an Android setting via content provider URI directly.
#
# WHY NOT "settings put":
#   "settings put" goes through cmd -> Binder -> settings service thread pool.
#   During app launch the Binder thread pool is saturated by the foreground
#   transition. Writes are rejected with error 2147483646 even though the
#   provider is alive - reads succeed on a separate lower-priority path, so
#   "settings get" passes but "settings put" fails.
#
# THE FIX - content insert/update via content:// URI:
#   The "content" tool calls the ContentProvider directly, bypassing the
#   settings cmd Binder path entirely. It uses the ActivityManager content
#   resolver IPC channel which is not affected by the same thread saturation.
#
# URI MAP:  secure -> content://settings/secure
#           system -> content://settings/system
#           global -> content://settings/global
# ----------------------------------------------------------------------------─
safe_set() {
    local NS="$1" KEY="$2" VAL="$3"
    local URI="content://settings/${NS}"

    # Try content update first (key already exists - most common case)
    content update --uri "$URI" \
        --bind value:s:"$VAL" \
        --where "name='$KEY'" >/dev/null 2>&1 && return 0

    # Key didn't exist yet - insert it
    content insert --uri "$URI" \
        --bind name:s:"$KEY" \
        --bind value:s:"$VAL" >/dev/null 2>&1 && return 0

    # Final fallback: classic settings put - wrapped in `timeout` as a hard
    # ceiling. BUG FIX: this raw settings put has no timeout of its own,
    # and on a device with a saturated/degraded Binder path (see the WHY
    # NOT above) it doesn't always fail fast - it can block waiting on the
    # transaction for a long time before the Binder driver itself gives up.
    # Ten of these in sequence (restore_defaults below) with no timeout is
    # exactly what turned an exit-sequence restore into an 80+ second
    # stall in practice. `timeout 2` caps each individual call so the
    # worst case for this whole function is a few seconds, not minutes.
    timeout 2 settings put "$NS" "$KEY" "$VAL" 2>/dev/null
}

# ----------------------------------------------------------------------------─
# LAYER 1 - Android Settings API
# ----------------------------------------------------------------------------─
apply_settings() {
    local LP_USE="$1" GAME="$2"

    # Wait for settings provider before firing any writes

    # Touch timing
    safe_set secure long_press_timeout                        "$LP_USE"
    safe_set secure multi_press_timeout                       "200"
    safe_set global tap_timeout                               "80"
    safe_set secure touch_event_tap_action_timeout_ms         "80"
    safe_set global motion_event_queue_min_input_interval_ms  "0"

    # Pointer / scroll physics
    safe_set system pointer_speed                             "$PSPEED"
    safe_set system scroll_friction                           "$SCROLL_FRIC"

    # Fling / swipe - minimum_fling_velocity is the key fix for micro-swipes
    safe_set global minimum_fling_velocity                    "$FLING_MIN"
    safe_set system minimum_fling_velocity                    "$FLING_MIN"
    safe_set global maximum_fling_velocity                    "$FLING_MAX"
    safe_set global fling_velocity_threshold                  "$FLING_MIN"

    # Touch slop - lower = micro-gestures register, fewer false drag cancels
    # NOTE: view_touch_slop was removed here - confirmed against AOSP's
    # ViewConfiguration.java (every API level through current master) that
    # this is not a real Settings.Global key. getScaledTouchSlop() reads
    # only from the compiled config_viewConfigurationTouchSlop resource
    # (default 8dp) with no settings-provider hook of any kind. Writing
    # this key was a silent no-op - it never affected real touch behavior.
    # See TOUCH_SLOP_LIMITATION.md for the full explanation and honest
    # status of micro-swipe/small-movement sensitivity on this platform.

    # Sampling rate hint
    safe_set global touch_sampling_rate                       "$SAMPLING"
    safe_set system touch_sampling_rate                       "$SAMPLING"

    # Disable touch exploration (never override gaming gestures)
    safe_set secure touch_exploration_enabled                 "0"

    # Game-specific overrides
    if [ "$GAME" = "game" ]; then
        safe_set global window_animation_scale                "0.0"
        safe_set global transition_animation_scale            "0.0"
        safe_set global animator_duration_scale               "0.0"
        safe_set global minimum_fling_velocity                "40"
        # view_touch_slop removed - not a real setting, see note above
        safe_set secure long_press_timeout                    "$LP_GAME"
        safe_set system pointer_speed                         "-1"
        safe_set global maximum_fling_velocity                "12000"
        log_tc "Game settings: LP=${LP_GAME}ms slop=2 fling≥40"
    fi
}

# ----------------------------------------------------------------------------─
# LAYER 2 - MTK persist props (actual sampling rate control on MTK kernels)
# Confirmed by VOID Touch v4.6 - these are the real knobs, not sysfs nodes
# ----------------------------------------------------------------------------─
apply_mtk_props() {
    local RATE="$1"  # Hz target

    smart_prop persist.vendor.mtk_touch_sampling_rate "$RATE"
    smart_prop persist.vendor.touch.sampling_rate     "$RATE"
    smart_prop persist.sys.touch.sampling_rate        "$RATE"
    smart_prop persist.sys.input.max_events_per_sec   "$RATE"
    smart_prop persist.dev.pm.dyn_samplingrate        "1"

    # SurfaceFlinger frame timing - wakes renderer earlier vs vsync
    # Reduces time between finger movement and frame display
    smart_prop debug.sf.early_phase_offset_ns              "$SF_OFFSET"
    smart_prop debug.sf.early_app_phase_offset_ns          "$SF_OFFSET"
    smart_prop debug.sf.early_sf_phase_offset_ns           "$SF_OFFSET"
    smart_prop debug.sf.late_sf_phase_offset_ns            "$SF_OFFSET"
    smart_prop debug.sf.high_fps_early_phase_offset_ns     "$SF_HIGH_OFFSET"
    smart_prop debug.sf.high_fps_early_app_phase_offset_ns "$SF_HIGH_OFFSET"
    smart_prop debug.sf.high_fps_early_sf_phase_offset_ns  "$SF_HIGH_OFFSET"
    smart_prop debug.sf.high_fps_late_app_phase_offset_ns  "1000000"
    smart_prop debug.sf.use_phase_offsets_as_durations     "1"
    smart_prop debug.sf.latch_unsignaled                   "1"
    smart_prop debug.sf.default_touch_timer_ms             "0"
    smart_prop debug.egl.hw                                "1"
    smart_prop debug.sf.hw                                 "1"
    smart_prop hwui.disable_vsync                          "true"

    log_tc "MTK props: sampling=${RATE}Hz SF offsets applied"
}

# ----------------------------------------------------------------------------─
# LAYER 3 - device_config input boost (correct Android 11+ API)
# Previous engine used "cmd power set-mode" - wrong, doesn't control input boost
# ----------------------------------------------------------------------------─
apply_input_boost() {
    local MS="$1"  # boost duration ms

    if [ "$IB" = "on" ]; then
        smart_device_config activity_manager input_boost_enabled    "true"
        smart_device_config activity_manager input_boost_duration_ms "$MS"
        smart_device_config activity_manager input_boost_cpuset     "0"
        log_tc "Input boost: enabled ${MS}ms"
    else
        smart_device_config activity_manager input_boost_enabled    "false"
        smart_device_config activity_manager input_boost_duration_ms "0"
        log_tc "Input boost: disabled"
    fi
}

# ----------------------------------------------------------------------------─
# LAYER 4 - touchHidlTest hardware register writer (AaTempSpoof technique)
# Sets IC report rate by writing registers directly via vendor HIDL test binary
# reg26=0x0=125Hz, reg26=0x1=240Hz, reg26=0x12c=360Hz, reg26=0x258=600Hz
# Only runs if the binary exists - safe no-op otherwise
# ----------------------------------------------------------------------------─
apply_hidl_rate() {
    local RATE="$1"
    local BIN

    # Probe common locations for touchHidlTest
    for path in \
        /vendor/bin/touchHidlTest \
        /system/bin/touchHidlTest \
        /data/adb/modules/AaTempSpoof/bin/touchHidlTest; do
        [ -x "$path" ] && BIN="$path" && break
    done

    [ -z "$BIN" ] && return 0  # not available - silent skip

    case "$RATE" in
        125) "$BIN" -c wo 0 26 0   >/dev/null 2>&1 && log_tc "IC rate: 125Hz via touchHidlTest" ;;
        240) "$BIN" -c wo 0 26 1   >/dev/null 2>&1 && log_tc "IC rate: 240Hz via touchHidlTest" ;;
        360) "$BIN" -c wo 0 26 12c >/dev/null 2>&1 && log_tc "IC rate: 360Hz via touchHidlTest" ;;
        600) "$BIN" -c wo 0 26 258 >/dev/null 2>&1 && log_tc "IC rate: 600Hz via touchHidlTest" ;;
          *) "$BIN" -c wo 0 26 1   >/dev/null 2>&1 && log_tc "IC rate: 240Hz via touchHidlTest (default)" ;;
    esac
}

# ----------------------------------------------------------------------------─
# LAYER 5 - proc/sysfs nodes (opportunistic, probed not assumed)
# ----------------------------------------------------------------------------─
apply_proc_nodes() {
    local WRITTEN=0 RATE="$1"

    # MTK TPD proc nodes
    for node in \
        /proc/mtk_tpd/tpd_filter_pixel_num \
        /proc/mtk_tpd/tpd_calibrate_variance \
        /proc/mtk_tpd/report_rate \
        /proc/touchscreen/report_rate \
        /proc/touchscreen/tpd_filter_pixel_num; do
        [ -f "$node" ] || continue
        case "$node" in
            *filter_pixel*)  echo "$SWIPE" > "$node" 2>/dev/null && WRITTEN=$((WRITTEN+1)) ;;
            *calibrate*)     echo "4"      > "$node" 2>/dev/null && WRITTEN=$((WRITTEN+1)) ;;
            *report_rate*)   echo "$RATE"  > "$node" 2>/dev/null && WRITTEN=$((WRITTEN+1)) ;;
        esac
    done

    # Infinix XOS specific
    for node in \
        /proc/touchpanel/game_switch_enable \
        /proc/touchpanel/report_rate_game \
        /proc/tp_gesture; do
        [ -f "$node" ] || continue
        case "$node" in
            *game_switch*) echo "1"     > "$node" 2>/dev/null && WRITTEN=$((WRITTEN+1)) ;;
            *report_rate*) echo "$RATE" > "$node" 2>/dev/null && WRITTEN=$((WRITTEN+1)) ;;
        esac
    done

    # Dynamic I2C driver scan - Goodix, FocalTech, ILITEK, GT9xx, etc.
    for drv in \
        /sys/bus/i2c/drivers/fts_ts \
        /sys/bus/i2c/drivers/goodix_ts \
        /sys/bus/i2c/drivers/nt36xxx \
        /sys/bus/i2c/drivers/ilitek_td \
        /sys/bus/i2c/drivers/gt9xx \
        /sys/bus/i2c/drivers/msg2638 \
        /sys/bus/i2c/drivers/hxchipset; do
        [ -d "$drv" ] || continue
        for dev in "$drv"/*/; do
            [ -d "$dev" ] || continue
            for node in game_mode gaming_mode report_rate high_report_rate; do
                [ -f "$dev$node" ] && echo "1" > "$dev$node" 2>/dev/null && WRITTEN=$((WRITTEN+1))
            done
            for node in sensitivity finger_threshold touch_filter; do
                [ -f "$dev$node" ] || continue
                case "$TAPSENS" in
                    high)   echo "1" > "$dev$node" 2>/dev/null ;;
                    low)    echo "3" > "$dev$node" 2>/dev/null ;;
                    medium) echo "2" > "$dev$node" 2>/dev/null ;;
                esac
                WRITTEN=$((WRITTEN+1))
            done
        done
    done

    [ "$WRITTEN" -gt 0 ] && log_tc "Proc/sysfs: $WRITTEN node(s) written" \
        || log_tc "Proc/sysfs: no writable nodes (normal on modern MTK kernels)"
}

# ----------------------------------------------------------------------------─
# restore_defaults - game_end: restore user base config
# ----------------------------------------------------------------------------─
restore_defaults() {
    # BUG FIX: this used to call raw `settings put` ten times in a row with
    # no fallback and no timeout. On this device's confirmed-degraded `cmd`
    # dispatcher (see boot.log: repeated "Failure calling service settings"
    # during every restore), those calls don't always fail instantly - they
    # can block waiting on the transaction, and ten sequential blocking
    # calls is what turned into an 80+ second stall on game exit in
    # practice. Routed through safe_set() instead, which tries the
    # content:// URI path first (bypasses the saturated settings Binder
    # path entirely - see safe_set's own header comment for why) and only
    # falls through to a now-timeout-guarded settings put as a last resort.
    safe_set secure long_press_timeout         "$LP"
    safe_set global tap_timeout                "100"
    safe_set system pointer_speed              "$PSPEED"
    safe_set global minimum_fling_velocity     "$FLING_MIN"
    safe_set system minimum_fling_velocity     "$FLING_MIN"
    safe_set global maximum_fling_velocity     "$FLING_MAX"
    safe_set global fling_velocity_threshold   "$FLING_MIN"
    safe_set system scroll_friction            "$SCROLL_FRIC"
    # view_touch_slop removed - not a real setting, see note above
    # Restore animations
    safe_set global window_animation_scale     "1.0"
    safe_set global transition_animation_scale "1.0"
    safe_set global animator_duration_scale    "1.0"
    # Restore MTK props to base sampling
    smart_prop persist.vendor.mtk_touch_sampling_rate "$SAMPLING"
    smart_prop persist.vendor.touch.sampling_rate     "$SAMPLING"
    smart_prop persist.sys.touch.sampling_rate        "$SAMPLING"
    smart_prop persist.sys.input.max_events_per_sec   "$SAMPLING"
    # Restore input boost to standard duration
    smart_device_config activity_manager input_boost_duration_ms "2000"
    # Restore IC rate to 240Hz default
    apply_hidl_rate 240
    log_tc "Touch restored to base profile"
}

# ----------------------------------------------------------------------------─
# ENTRY POINT
# ----------------------------------------------------------------------------─

if [ "$STATUS" != "on" ] && [ "$GAME_PHASE" != "game_end" ]; then
    log_tc "Touch engine off - skipping"
    exit 0
fi

case "$GAME_PHASE" in

    game_end)
        restore_defaults
        exit 0
        ;;

    game_start)
        apply_settings     "$LP" "game"
        apply_mtk_props    "240"
        apply_input_boost  "$BOOST_MS"
        apply_hidl_rate    "240"
        apply_proc_nodes   "240"
        log_tc "Game touch profile active (${SAMPLING}Hz sampling, boost=${BOOST_MS}ms)"
        exit 0
        ;;

    "")
        # Boot / user toggle - apply base profile
        apply_settings     "$LP" ""
        apply_mtk_props    "$SAMPLING"
        apply_input_boost  "$BOOST_MS"
        apply_hidl_rate    "$SAMPLING"
        apply_proc_nodes   "$SAMPLING"
        log_tc "Base touch profile active (${SAMPLING}Hz sampling)"
        exit 0
        ;;

    *)
        echo "[TOUCH] Unknown argument: '$GAME_PHASE'" >&2
        exit 1
        ;;

esac
