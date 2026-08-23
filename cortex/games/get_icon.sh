#!/system/bin/sh
# cortex/games/get_icon.sh - Sweet Dreams
# Best-effort real app-icon extractor for the Games tab, replacing the
# hardcoded emoji per title with the game's actual launcher icon.
#
# WHY "BEST-EFFORT": there is no clean, universally-available way to pull an
# app icon as a PNG from pure shell on a stock rooted device. `aapt`/`aapt2`
# (which can resolve the exact icon resource id, adaptive-icon layers, and
# density) are SDK build tools - they usually aren't present on a phone.
# Without them we fall back to a heuristic: most APKs still ship an
# `ic_launcher`-named PNG under res/mipmap-*/ even when everything else is
# minified, because launcher icons are referenced by the OS by resource
# *name* pattern in some tooling and many build systems intentionally leave
# them unobfuscated for exactly this kind of external introspection. This
# works for a large chunk of real-world APKs, but NOT all of them - some
# release builds (notably ones built with aggressive resource shrinking)
# rename every PNG to a short hash and this heuristic will find nothing.
# When that happens we exit 1 and the caller (WebUI) keeps the emoji for
# that title instead of showing a broken image. Nothing regresses.
#
# Usage: get_icon.sh <package>
# On success: caches base64 PNG to cortex/games/icon_cache/<package>.b64
#             and prints the base64 content itself to stdout (so the WebUI
#             needs exactly one shell round trip per icon).
# On failure: prints nothing, exits 1. Caller should keep using the emoji.

CORTEX="/data/adb/modules/sweet_dreams/cortex"
CACHE_DIR="$CORTEX/games/icon_cache"
PKG="$1"

[ -z "$PKG" ] && exit 1
mkdir -p "$CACHE_DIR"

OUT_B64="$CACHE_DIR/${PKG}.b64"

# Already cached - icons don't change without an app update, and re-running
# this on every games-tab render would mean an unzip + base64 pass per app
# per open. Cache is invalidated manually via clear_icon_cache below.
if [ -s "$OUT_B64" ]; then
    cat "$OUT_B64"
    exit 0
fi

APK=$(pm path "$PKG" 2>/dev/null | head -1 | sed 's/^package://')
[ -z "$APK" ] || [ ! -f "$APK" ] && exit 1

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Prefer the highest-density launcher icon available, in order. Adaptive
# icon foregrounds (ic_launcher_foreground) are included as a last resort -
# they render without their background layer, but a plain foreground glyph
# still beats a generic emoji for recognizability.
CANDIDATES="
res/mipmap-xxxhdpi-v4/ic_launcher.png
res/mipmap-xxhdpi-v4/ic_launcher.png
res/mipmap-xhdpi-v4/ic_launcher.png
res/mipmap-xxxhdpi/ic_launcher.png
res/mipmap-xxhdpi/ic_launcher.png
res/mipmap-xhdpi/ic_launcher.png
res/drawable-xxxhdpi-v4/ic_launcher.png
res/drawable-xxhdpi-v4/ic_launcher.png
res/mipmap-xxhdpi-v4/ic_launcher_foreground.png
res/drawable-xxhdpi-v4/ic_launcher_foreground.png
"

FOUND=""
for CAND in $CANDIDATES; do
    if unzip -p "$APK" "$CAND" > "$WORKDIR/icon.png" 2>/dev/null; then
        [ -s "$WORKDIR/icon.png" ] && FOUND="1" && break
    fi
done

# Fallback: scan the archive listing for anything matching *ic_launcher*.png
# at all, in case the density suffix used by this particular build isn't in
# our candidate list above.
if [ -z "$FOUND" ]; then
    MATCH=$(unzip -l "$APK" 2>/dev/null | grep -oE '[^[:space:]]*ic_launcher[^[:space:]]*\.png' | head -1)
    if [ -n "$MATCH" ] && unzip -p "$APK" "$MATCH" > "$WORKDIR/icon.png" 2>/dev/null; then
        [ -s "$WORKDIR/icon.png" ] && FOUND="1"
    fi
fi

[ -z "$FOUND" ] && exit 1

# base64 -w0 is not universal across toybox/busybox builds - strip newlines
# manually instead of relying on a wrap-width flag that may not exist.
base64 "$WORKDIR/icon.png" 2>/dev/null | tr -d '\n' > "$OUT_B64"

if [ -s "$OUT_B64" ]; then
    cat "$OUT_B64"
    exit 0
else
    rm -f "$OUT_B64"
    exit 1
fi
