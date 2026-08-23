#!/system/bin/sh
# Best-effort launcher icon extractor. Prints:  mime|base64
# mime is image/png or image/webp. Empty + exit 1 if nothing found.

CORTEX="/data/adb/modules/sweet_dreams/cortex"
CACHE_DIR="$CORTEX/games/icon_cache"
PKG="$1"

[ -z "$PKG" ] && exit 1
mkdir -p "$CACHE_DIR"

OUT="$CACHE_DIR/${PKG}.icon"
if [ -s "$OUT" ]; then
    cat "$OUT"
    exit 0
fi

APK=$(pm path "$PKG" 2>/dev/null | head -1 | sed 's/^package://')
[ -z "$APK" ] || [ ! -f "$APK" ] && exit 1

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

pick_from_list() {
    local match mime
    # Prefer high-density launcher names, then any mipmap/drawable raster.
    MATCH=$(unzip -l "$APK" 2>/dev/null | awk '
        BEGIN { best=""; bestn=0 }
        /res\/(mipmap|drawable)[^ ]*\.(png|webp)$/ {
            n=$1+0
            path=$NF
            score=n
            if (path ~ /xxxhdpi/) score+=4000000
            else if (path ~ /xxhdpi/) score+=3000000
            else if (path ~ /xhdpi/) score+=2000000
            if (path ~ /ic_launcher/) score+=5000000
            if (path ~ /foreground/) score+=100000
            if (score > bestn) { bestn=score; best=path }
        }
        END { print best }
    ')
    [ -z "$MATCH" ] && return 1
    unzip -p "$APK" "$MATCH" > "$WORKDIR/icon.bin" 2>/dev/null || return 1
    [ -s "$WORKDIR/icon.bin" ] || return 1
    case "$MATCH" in
        *.webp) mime="image/webp" ;;
        *) mime="image/png" ;;
    esac
    printf '%s|' "$mime" > "$OUT"
    base64 "$WORKDIR/icon.bin" 2>/dev/null | tr -d '\n' >> "$OUT"
    echo >> "$OUT"
    cat "$OUT"
    return 0
}

if pick_from_list; then
    exit 0
fi
exit 1
