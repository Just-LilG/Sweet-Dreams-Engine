#!/system/bin/sh
# Launch or force-stop a package from the Games tab.
# usage: control.sh launch|stop|stop_all [package]

CORTEX="${CORTEX:-/data/adb/modules/sweet_dreams/cortex}"
CMD="$1"
PKG="$2"

launch_pkg() {
    local pkg="$1" act
    [ -z "$pkg" ] && return 1
    pm path "$pkg" >/dev/null 2>&1 || return 1
    act=$(cmd package resolve-activity --brief "$pkg" 2>/dev/null | tail -n 1)
    if [ -n "$act" ] && [ "$act" != "No activity found" ]; then
        am start -n "$act" >/dev/null 2>&1 && return 0
    fi
    monkey -p "$pkg" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
}

stop_pkg() {
    [ -z "$1" ] && return 1
    am force-stop "$1" >/dev/null 2>&1
}

case "$CMD" in
    launch)
        launch_pkg "$PKG"
        ;;
    stop)
        stop_pkg "$PKG"
        ;;
    stop_all)
        while IFS= read -r p; do
            p=$(printf '%s' "$p" | tr -d '\r')
            [ -z "$p" ] && continue
            stop_pkg "$p"
        done < "$CORTEX/games/selected.txt"
        ;;
    *)
        echo "usage: control.sh launch|stop|stop_all [package]" >&2
        exit 1
        ;;
esac
