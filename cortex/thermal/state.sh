#!/system/bin/sh
# cortex/thermal/state.sh — armed vs off, with status.txt compatibility.
#
# Historical naming: status.txt=disabled meant "stock thermal daemon disabled"
# (spoof armed). That inverted language leaked into the WebUI. New files:
#   armed.txt = armed | off
# status.txt is still written for old scripts (disabled=armed, enabled=off).

CORTEX="${CORTEX:-/data/adb/modules/sweet_dreams/cortex}"

thermal_is_armed() {
    local a s
    a=$(cat "$CORTEX/thermal/armed.txt" 2>/dev/null | tr -d '\r\n')
    case "$a" in
        armed) return 0 ;;
        off) return 1 ;;
    esac
    s=$(cat "$CORTEX/thermal/status.txt" 2>/dev/null | tr -d '\r\n')
    [ "$s" = "disabled" ]
}

thermal_set_armed() {
    mkdir -p "$CORTEX/thermal"
    case "$1" in
        armed|on|1|true)
            echo armed > "$CORTEX/thermal/armed.txt"
            echo disabled > "$CORTEX/thermal/status.txt"
            ;;
        *)
            echo off > "$CORTEX/thermal/armed.txt"
            echo enabled > "$CORTEX/thermal/status.txt"
            ;;
    esac
}
