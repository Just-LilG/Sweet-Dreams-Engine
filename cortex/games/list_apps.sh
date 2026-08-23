#!/system/bin/sh
# cortex/games/list_apps.sh — package labels for the Games tab.
# Prints pkg|label lines. Labels come from dumpsys; cache 6h.
#
# usage:
#   list_apps.sh labels pkg1 pkg2 ...
#   list_apps.sh search <query>
#   list_apps.sh likely

CORTEX="${CORTEX:-/data/adb/modules/sweet_dreams/cortex}"
CACHE="$CORTEX/games/label_cache.txt"
mkdir -p "$CORTEX/games"

pkg_label() {
    local pkg="$1" lab
    lab=$(grep -m1 "^${pkg}|" "$CACHE" 2>/dev/null | cut -d'|' -f2-)
    if [ -n "$lab" ]; then
        printf '%s\n' "$lab"
        return
    fi
    lab=$(dumpsys package "$pkg" 2>/dev/null | awk -F= '
        /applicationLabel=/ { gsub(/\r/, "", $2); print $2; exit }
        /appName=/ { gsub(/\r/, "", $2); print $2; exit }
    ')
    [ -z "$lab" ] && lab=$(dumpsys package "$pkg" 2>/dev/null | awk '
        /application-label:/ {
            gsub(/.*application-label:/, "")
            gsub(/['\''"]/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            print
            exit
        }
    ')
    [ -z "$lab" ] && lab="${pkg##*.}"
    echo "${pkg}|${lab}" >> "$CACHE"
    printf '%s\n' "$lab"
}

# Drop cache older than 6 hours (3600*6). toybox stat -c %Y is common.
if [ -f "$CACHE" ]; then
    NOW=$(date +%s)
    MT=$(stat -c %Y "$CACHE" 2>/dev/null || echo 0)
    [ $((NOW - MT)) -gt 21600 ] && : > "$CACHE"
fi

CMD="${1:-likely}"
shift

case "$CMD" in
    labels)
        for p in "$@"; do
            [ -z "$p" ] && continue
            l=$(pkg_label "$p")
            echo "${p}|${l}"
        done
        ;;
    search)
        q=$(echo "$1" | tr '[:upper:]' '[:lower:]')
        [ -z "$q" ] && exit 0
        if [ -s "$CACHE" ]; then
            grep -i "$q" "$CACHE" | head -25
        fi
        pm list packages -3 2>/dev/null | sed 's/^package://' | grep -i "$q" | head -25 | while IFS= read -r p; do
            [ -z "$p" ] && continue
            grep -q "^${p}|" "$CACHE" 2>/dev/null && continue
            l=$(pkg_label "$p")
            echo "${p}|${l}"
        done
        ;;
    likely)
        pm list packages -3 2>/dev/null | sed 's/^package://' | grep -Ei \
            'game|unity|tencent|activision|mihoyo|hoyoverse|roblox|mojang|pubg|garena|nexon|riotgames|epicgames|supercell|netease|kurogame|levelinfinite|dts\.|vng\.|mobilelegends|codm|genshin|honkai|mlbb|freefire|clash|pokemon|nintendo' \
            | while IFS= read -r p; do
            [ -z "$p" ] && continue
            l=$(pkg_label "$p")
            echo "${p}|${l}"
        done
        ;;
    *)
        echo "usage: list_apps.sh labels|search|likely" >&2
        exit 1
        ;;
esac
