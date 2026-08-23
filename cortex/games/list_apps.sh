#!/system/bin/sh
# cortex/games/list_apps.sh — package labels for the Games tab.
# Only reports packages that are actually installed (pm path).
#
# usage:
#   list_apps.sh labels pkg1 pkg2 ...
#   list_apps.sh search <query>
#   list_apps.sh likely
#   list_apps.sh prune

CORTEX="${CORTEX:-/data/adb/modules/sweet_dreams/cortex}"
CACHE="$CORTEX/games/label_cache.txt"
SELECTED="$CORTEX/games/selected.txt"
mkdir -p "$CORTEX/games"

pkg_installed() {
    pm path "$1" >/dev/null 2>&1
}

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

if [ -f "$CACHE" ]; then
    NOW=$(date +%s)
    MT=$(stat -c %Y "$CACHE" 2>/dev/null || echo 0)
    [ $((NOW - MT)) -gt 21600 ] && : > "$CACHE"
fi

CMD="${1:-likely}"
shift

case "$CMD" in
    prune)
        [ -f "$SELECTED" ] || exit 0
        TMP=$(mktemp)
        while IFS= read -r p; do
            p=$(printf '%s' "$p" | tr -d '\r')
            [ -z "$p" ] && continue
            pkg_installed "$p" && echo "$p" >> "$TMP"
        done < "$SELECTED"
        mv -f "$TMP" "$SELECTED"
        ;;
    labels)
        for p in "$@"; do
            [ -z "$p" ] && continue
            pkg_installed "$p" || continue
            l=$(pkg_label "$p")
            echo "${p}|${l}"
        done
        ;;
    search)
        q=$(echo "$1" | tr '[:upper:]' '[:lower:]')
        [ -z "$q" ] && exit 0
        if [ -s "$CACHE" ]; then
            grep -i "$q" "$CACHE" | while IFS='|' read -r p l; do
                pkg_installed "$p" && echo "${p}|${l}"
            done | head -25
        fi
        pm list packages -3 2>/dev/null | sed 's/^package://' | grep -i "$q" | head -25 | while IFS= read -r p; do
            [ -z "$p" ] && continue
            pkg_installed "$p" || continue
            grep -q "^${p}|" "$CACHE" 2>/dev/null && continue
            l=$(pkg_label "$p")
            echo "${p}|${l}"
        done
        ;;
    likely)
        pm list packages -3 2>/dev/null | sed 's/^package://' | grep -Ei \
            'game|unity|tencent|mihoyo|hoyoverse|roblox|mojang|pubg|garena|nexon|riotgames|epicgames|supercell|netease|kurogame|levelinfinite|mobilelegends|genshin|honkai|mlbb|freefire|clash|pokemon|nintendo' \
            | while IFS= read -r p; do
            [ -z "$p" ] && continue
            pkg_installed "$p" || continue
            l=$(pkg_label "$p")
            echo "${p}|${l}"
        done
        ;;
    *)
        echo "usage: list_apps.sh labels|search|likely|prune" >&2
        exit 1
        ;;
esac
