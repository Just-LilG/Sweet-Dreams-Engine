# cortex/display/game_mode.sh — shared Game Mode / overlay helpers
#
# Command shape matches AZenith's ResolutionChanger.c (Apache 2.0, Zexshia):
#   cmd game set --mode 2 --downscale <factor> [--fps <n>] <pkg>
#   (Android 13+ via ro.build.version.release, same check as AZenith)
#   cmd device_config put game_overlay <pkg> "mode=2,downscaleFactor=...,fps=..."
#   cmd game mode 2 <pkg>
#
# Sourced by apply_resolution.sh, fps/engine.sh, and game_monitor.sh.

[ -n "$MODDIR" ] || MODDIR="/data/adb/modules/sweet_dreams"
[ -n "$CORTEX" ] || CORTEX="$MODDIR/cortex"

normalize_downscale() {
    echo "$1" | awk '{
        v = $1 + 0
        if (v <= 0 || v >= 0.995) { print "native"; exit }
        printf "%.2f", v
    }'
}

android_release_major() {
    getprop ro.build.version.release 2>/dev/null | awk -F. '{ print $1 + 0 }'
}

android_sdk() {
    _s=$(getprop ro.build.version.sdk 2>/dev/null)
    case "$_s" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo "$_s" ;;
    esac
}

android_has_game_set() {
    _rel=$(android_release_major)
    _sdk=$(android_sdk)
    [ "$_rel" -ge 13 ] && return 0
    [ "$_sdk" -ge 33 ] && return 0
    return 1
}

# Per-game profile: missing/default/seeded-native inherit the WebUI global.
# Explicit numeric or user-set native (no seeded=1) wins.
resolve_scale() {
    _pkg="$1"
    _global=$(cat "$CORTEX/display/resolution.txt" 2>/dev/null | tr -d '\r\n ')
    [ -n "$_global" ] || _global="native"
    _file="$CORTEX/games/profiles/$(echo "$_pkg" | tr '.' '-').txt"
    _val=""
    _seeded=""
    if [ -f "$_file" ]; then
        _val=$(grep '^resolution=' "$_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r\n ')
        _seeded=$(grep '^seeded=' "$_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r\n ')
    fi
    _chosen="$_global"
    case "$_val" in
        ''|default|inherit) _chosen="$_global" ;;
        native)
            if [ "$_seeded" = "1" ]; then
                _chosen="$_global"
            else
                _chosen="native"
            fi
            ;;
        *) _chosen="$_val" ;;
    esac
    normalize_downscale "$_chosen"
}

write_game_overlay() {
    _pkg="$1"
    _res="$2"
    _fps="$3"
    _cfg="mode=2"
    _norm=$(normalize_downscale "$_res")
    [ "$_norm" != "native" ] && _cfg="${_cfg},downscaleFactor=${_norm}"
    case "$_fps" in
        ''|off|native) ;;
        *) _cfg="${_cfg},fps=${_fps}" ;;
    esac
    cmd device_config put game_overlay "$_pkg" "$_cfg" >/dev/null 2>&1
}

# Exact AZenith apply string for Android 13+.
azenith_game_set() {
    _pkg="$1"
    _res="$2"
    _fps="$3"
    _norm=$(normalize_downscale "$_res")
    if [ "$_norm" = "native" ]; then
        case "$_fps" in
            ''|off|native) cmd game set --mode 2 "$_pkg" >/dev/null 2>&1 ;;
            *) cmd game set --mode 2 --fps "$_fps" "$_pkg" >/dev/null 2>&1 ;;
        esac
        return $?
    fi
    case "$_fps" in
        ''|off|native)
            cmd game set --mode 2 --downscale "$_norm" "$_pkg" >/dev/null 2>&1
            ;;
        *)
            cmd game set --mode 2 --downscale "$_norm" --fps "$_fps" "$_pkg" >/dev/null 2>&1
            ;;
    esac
}

apply_azenith_downscale() {
    _pkg="$1"
    _res="$2"
    _fps="$3"
    write_game_overlay "$_pkg" "$_res" "$_fps"
    cmd game mode 2 "$_pkg" >/dev/null 2>&1
    if android_has_game_set; then
        azenith_game_set "$_pkg" "$_res" "$_fps"
        return 0
    fi
    cmd game mode 2 "$_pkg" >/dev/null 2>&1
    return 0
}

reset_azenith_downscale() {
    _pkg="$1"
    cmd device_config delete game_overlay "$_pkg" >/dev/null 2>&1
    if android_has_game_set; then
        cmd game reset --mode 2 "$_pkg" >/dev/null 2>&1
        cmd game reset "$_pkg" >/dev/null 2>&1
    else
        cmd game mode 1 "$_pkg" >/dev/null 2>&1
        cmd game reset "$_pkg" >/dev/null 2>&1
    fi
}
