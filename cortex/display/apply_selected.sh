#!/system/bin/sh
# Arm (or apply+relaunch foreground) Game Mode downscale for every selected game.
RES="$1"
MODDIR="/data/adb/modules/sweet_dreams"
CORTEX="$MODDIR/cortex"
LIST="$CORTEX/games/selected.txt"

n=0
FG=$(sh "$CORTEX/games/foreground_pkg.sh" 2>/dev/null | tr -d '\r\n ')

if [ ! -s "$LIST" ]; then
    echo "NO_GAMES"
    exit 0
fi

while IFS= read -r pkg || [ -n "$pkg" ]; do
    pkg=$(echo "$pkg" | tr -d '\r\n ')
    [ -z "$pkg" ] && continue
    n=$((n + 1))
    if [ -n "$FG" ] && [ "$pkg" = "$FG" ]; then
        sh "$CORTEX/display/apply_resolution.sh" "$RES" "$pkg"
    else
        SKIP_RESTART=1 sh "$CORTEX/display/apply_resolution.sh" "$RES" "$pkg"
    fi
done < "$LIST"

[ "$n" -eq 0 ] && echo "NO_GAMES"
echo "ARMED=$n FG=$FG"
