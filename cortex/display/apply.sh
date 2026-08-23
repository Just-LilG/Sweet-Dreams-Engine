#!/system/bin/sh
CORTEX="/data/adb/modules/sweet_dreams/cortex"
MODDIR="/data/adb/modules/sweet_dreams"
# See cortex/fps/engine.sh for why this exists - `settings put` is a thin
# wrapper around the `cmd` dispatcher, which is blocked by a known,
# non-timing-related class of issue on some devices; `content update` is a
# different IPC path worth attempting alongside it.
settings_put() {
    if ! grep -qx "CMD_DISPATCHER_UNRELIABLE" "$CORTEX/device/active.txt" 2>/dev/null; then
        settings put "$1" "$2" "$3" >/dev/null 2>&1
    fi
    content update --uri content://settings/"$1" --bind value:s:"$3" --where "name='$2'" >/dev/null 2>&1
}

# -- V-Sync --------------------------------------------------------------------
VSYNC=$(cat "$CORTEX/display/vsync.txt" 2>/dev/null || echo "on")
if [ "$VSYNC" = "off" ]; then
    resetprop debug.sf.hw 1 2>/dev/null
    resetprop ro.surface_flinger.use_content_detection_for_refresh_rate false 2>/dev/null
    settings_put global debug.egl.swapinterval -1
fi

# -- Resolution ----------------------------------------------------------------
# Bug fix: this used to read resolution.txt and apply whatever scale the user
# last picked, system-wide, at every boot - meaning a non-native resolution
# stayed active for every app on the phone (home screen, other modules,
# everything), not just the games it was meant for. It's now purely a
# per-game thing, applied/reverted by cortex/daemons/game_monitor.sh on
# actual launch/exit (see cortex/display/apply_resolution.sh). Boot always
# starts clean at native.
sh "$CORTEX/display/apply_resolution.sh" native 2>/dev/null

# -- Render engine ------------------------------------------------------------─
# IMPROVED: was 4 options (skiavk, skiagl, angle, opengl). Expanded to match
# AZenith's real, confirmed 8-option set - verified against their actual
# manager source (AppSettingsScreen.kt's rendererValues array), not
# guessed: default, skiavk, skiavkthreaded, skiagl, skiaglthreaded, opengl,
# openglthreaded, vulkan.
#
# IMPORTANT correction found while implementing this: AOSP's real
# debug.hwui.renderer property only ever accepted three genuine values -
# "opengl", "skiagl", "skiavk" (confirmed against the actual AOSP source
# diff that introduced this property). There is no such thing as a fourth
# "vulkan" or "*threaded" value at the hwui.renderer level - those aren't
# separate renderer types, they're the SAME base renderer combined with a
# threaded debug.renderengine.backend value (the documented real mechanism
# is debug.hwui.renderer=skiagl + debug.renderengine.backend=skiaglthreaded
# together). Sweet Dreams' previous 4-option version was already setting
# renderengine.backend correctly but hardcoded it to skiaglthreaded
# regardless of which renderer was picked, and never exposed the
# threaded/non-threaded choice as its own setting - this fixes both:
# "angle" is dropped since it was never a real distinct backend value the
# way it was being used here - Vulkan is properly reachable through
# skiavk instead, which is what actually invokes ANGLE-equivalent behavior
# on modern Android per the AOSP source above.
RENDER=$(cat "$CORTEX/display/render.txt" 2>/dev/null || echo "skiavk")
case "$RENDER" in
    default)
        resetprop debug.hwui.renderer "" 2>/dev/null
        resetprop debug.renderengine.backend "" 2>/dev/null
        ;;
    skiavk)
        resetprop debug.hwui.renderer skiavk 2>/dev/null
        resetprop debug.renderengine.backend skiagl 2>/dev/null
        ;;
    skiavkthreaded)
        resetprop debug.hwui.renderer skiavk 2>/dev/null
        resetprop debug.renderengine.backend skiaglthreaded 2>/dev/null
        ;;
    skiagl)
        resetprop debug.hwui.renderer skiagl 2>/dev/null
        resetprop debug.renderengine.backend skiagl 2>/dev/null
        ;;
    skiaglthreaded)
        resetprop debug.hwui.renderer skiagl 2>/dev/null
        resetprop debug.renderengine.backend skiaglthreaded 2>/dev/null
        ;;
    opengl)
        resetprop debug.hwui.renderer opengl 2>/dev/null
        resetprop debug.renderengine.backend gles 2>/dev/null
        ;;
    openglthreaded)
        resetprop debug.hwui.renderer opengl 2>/dev/null
        resetprop debug.renderengine.backend glesthreaded 2>/dev/null
        ;;
    vulkan)
        # "True" Vulkan per the confirmed real mechanism (see comment
        # above) is debug.hwui.renderer=skiavk - Android has no separate
        # top-level "vulkan" hwui.renderer value. Kept as its own case
        # (rather than silently aliasing to skiavk in the case pattern
        # itself) so the WebUI's "Vulkan" option and this script's
        # behavior stay in sync even if that ever needs device-specific
        # handling later - right now it's functionally identical to
        # skiavk (non-threaded), which is correct.
        resetprop debug.hwui.renderer skiavk 2>/dev/null
        resetprop debug.renderengine.backend skiagl 2>/dev/null
        ;;
esac

# -- Refresh Rate Lock ----------------------------------------------------------
# rr_lock.txt values:
#   off       - let AOSP do its thing, just set peak
#   locked    - hard lock peak=min=target (no drops ever)
#   game      - lock only when a monitored game is running (handled in service.sh loop)
#
TARGET_FPS=$(cat "$CORTEX/display/fps.txt" 2>/dev/null || echo "90")
RR_LOCK=$(cat "$CORTEX/display/rr_lock.txt" 2>/dev/null || echo "off")

# Always set the peak to the chosen target
settings_put system peak_refresh_rate "$TARGET_FPS"

case "$RR_LOCK" in
    locked)
        # Pin min == peak -> no adaptive drops
        settings_put system min_refresh_rate "$TARGET_FPS"
        # Tell SurfaceFlinger not to auto-negotiate a lower rate
        resetprop ro.surface_flinger.use_content_detection_for_refresh_rate false 2>/dev/null
        resetprop debug.sf.use_content_detection_for_refresh_rate false 2>/dev/null
        resetprop persist.sys.disable_rrs 1 2>/dev/null
        echo "rr_locked" > "$CORTEX/display/rr_status.txt"
        ;;
    game)
        # In "game" mode, idle stays at 60; the service.sh loop pins it when game runs
        settings_put system min_refresh_rate 60
        resetprop ro.surface_flinger.use_content_detection_for_refresh_rate true 2>/dev/null
        resetprop debug.sf.use_content_detection_for_refresh_rate true 2>/dev/null
        resetprop persist.sys.disable_rrs 0 2>/dev/null
        echo "rr_game_mode" > "$CORTEX/display/rr_status.txt"
        ;;
    off|*)
        # Vanilla - just set peak, leave min at 60
        settings_put system min_refresh_rate 60
        resetprop ro.surface_flinger.use_content_detection_for_refresh_rate true 2>/dev/null
        resetprop debug.sf.use_content_detection_for_refresh_rate true 2>/dev/null
        resetprop persist.sys.disable_rrs 0 2>/dev/null
        echo "rr_off" > "$CORTEX/display/rr_status.txt"
        ;;
esac

# -- In-game FPS lock baseline (service loop handles per-game enforcement) ------
FPS_LOCK_GAME=$(cat "$CORTEX/display/fps_lock_game.txt" 2>/dev/null || echo "off")
if [ "$FPS_LOCK_GAME" != "off" ]; then
    # Pre-warm Frieren at idle target; service loop overrides when game launches
    sh "$CORTEX/fps/engine.sh" "$TARGET_FPS" 2>/dev/null
fi
