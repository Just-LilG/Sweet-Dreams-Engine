#!/system/bin/sh
MODDIR=${0%/*}
CORTEX="$MODDIR/cortex"

# Bug fix: this switch used to be a stale, separate copy of the renderer
# logic - 4 options (skiavk/skiagl/angle/opengl), predating the fix in
# cortex/display/apply.sh that expanded this to the real 8-value scheme
# and dropped "angle" (never a real distinct debug.hwui.renderer value -
# see that file's header comment for the full AOSP-sourced reasoning).
# Any of the 4 newer values (skiavkthreaded, skiaglthreaded,
# openglthreaded, vulkan, or "default") matched none of the old cases here,
# so this early-boot prop set silently no-op'd for them - the real apply
# only ever happened later when service.sh calls display/apply.sh. Kept in
# sync with that file's case statement now; if one changes, the other
# should too.
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
        # Same as display/apply.sh: "true" Vulkan is debug.hwui.renderer=
        # skiavk - Android has no separate top-level "vulkan" value. Kept
        # as its own case so the WebUI's "Vulkan" option and this script's
        # early-boot behavior stay in sync with display/apply.sh.
        resetprop debug.hwui.renderer skiavk 2>/dev/null
        resetprop debug.renderengine.backend skiagl 2>/dev/null
        ;;
esac
resetprop debug.renderengine.skia_use_perfetto_track_events false
