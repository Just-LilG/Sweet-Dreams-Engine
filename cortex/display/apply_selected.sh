#!/system/bin/sh
# Arm render scale for every selected app.
# Per-package resolve_scale() reads WebUI global resolution.txt + optional profile.
MODDIR="/data/adb/modules/sweet_dreams"
CORTEX="$MODDIR/cortex"
LIST="$CORTEX/games/selected.txt"

. "$CORTEX/display/game_mode.sh"

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
    SCALE=$(resolve_scale "$pkg")
    if [ -n "$FG" ] && [ "$pkg" = "$FG" ]; then
        sh "$CORTEX/display/apply_resolution.sh" "$SCALE" "$pkg" session
    else
        SKIP_RESTART=1 sh "$CORTEX/display/apply_resolution.sh" "$SCALE" "$pkg" arm
    fi
done < "$LIST"

[ "$n" -eq 0 ] && echo "NO_GAMES"
echo "ARMED=$n FG=$FG"
