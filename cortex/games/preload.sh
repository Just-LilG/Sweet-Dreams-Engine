#!/system/bin/sh
# cortex/games/preload.sh - Sweet Dreams Game Preload
#
# PORTED FROM: AZenith's GamePreload.c (Apache 2.0, Zexshia). The compiled
# version uses a dedicated binary (sys.azenith-preloadbin) to touch file
# pages into the OS page cache with a memory budget cap. We don't have
# that binary's source, so this is a shell-native equivalent using the
# same underlying kernel mechanism it relies on: reading a file's bytes
# forces the kernel to cache those pages in RAM (page cache), so the next
# read - the game's own loader, moments later - comes from RAM instead of
# flash storage. That's the entire trick; the compiled binary is a faster,
# more precise implementation of the same idea, not a different one.
#
# WHAT THIS DOES, SAME ALGORITHM AS THE REAL SOURCE:
#   1. Find the installed APK's path via `cmd package path`
#   2. Check if the APK folder has a native lib/arm64 directory with .so
#      files - that's the hot path (compiled game code), prefer it
#   3. If no lib folder exists, fall back to the APK/split-APK files
#      themselves (some games ship all code inside the APK, no separate
#      .so extraction)
#   4. Read every targeted file's bytes to force it into page cache,
#      respecting a memory budget so this can't evict everything else
#      cached and make things temporarily WORSE right before a game launch
#   5. Runs 5s after launch is detected (same delay as the original -
#      gives the game's own initial disk I/O a head start before we
#      compete with it, matches AZenith's own sleep(5) at function entry)
#
# BUDGET: defaults to 500MB (same default as AZenith), configurable via
# cortex/games/preload_budget_mb.txt. Stops touching files once the
# budget is hit rather than reading everything unconditionally.
#
# USAGE: preload.sh <package_name>   (called once per game launch, backgrounded)

PKG="$1"
MODDIR="/data/adb/modules/sweet_dreams"
CORTEX="$MODDIR/cortex"
LOGFILE="$MODDIR/boot.log"

log_pl() { echo "[PRELOAD] $1" | tee -a "$LOGFILE"; }

[ -z "$PKG" ] && exit 1

PRELOAD_EN=$(cat "$CORTEX/games/preload_enabled.txt" 2>/dev/null || echo "off")
[ "$PRELOAD_EN" != "on" ] && exit 0

# Same 5s delay as the real GamePreload.c - lets the game's own startup
# I/O go first instead of competing with it right at process creation.
sleep 5

BUDGET_MB=$(cat "$CORTEX/games/preload_budget_mb.txt" 2>/dev/null || echo "500")
BUDGET_BYTES=$((BUDGET_MB * 1024 * 1024))

# -- Step 1: resolve the APK's real install path ----------------------------─
APK_PATH=$(cmd package path "$PKG" 2>/dev/null | head -n1 | cut -d: -f2)
if [ -z "$APK_PATH" ]; then
    log_pl "Failed to resolve APK path for $PKG - package not installed or pm unavailable"
    exit 1
fi
APK_DIR=$(dirname "$APK_PATH")

# -- Step 2: prefer native lib/arm64 folder if it has .so files --------------
LIB_DIR="$APK_DIR/lib/arm64"
LIB_EXISTS=0
if [ -d "$LIB_DIR" ]; then
    for f in "$LIB_DIR"/*.so; do
        [ -f "$f" ] && LIB_EXISTS=1 && break
    done
fi

if [ "$LIB_EXISTS" = "1" ]; then
    TARGET_DIR="$LIB_DIR"
    TARGET_TYPE="native libs"
else
    TARGET_DIR="$APK_DIR"
    TARGET_TYPE="APK/split files"
fi

# -- Step 3: touch files into page cache, respecting the memory budget ------─
TOUCHED_BYTES=0
TOUCHED_COUNT=0

for f in "$TARGET_DIR"/*; do
    [ -f "$f" ] || continue
    case "$f" in
        *.so|*.apk|*.dm|*.odex|*.vdex|*.art) ;;
        *) continue ;;
    esac

    FSIZE=$(stat -c '%s' "$f" 2>/dev/null || echo 0)
    [ "$FSIZE" -le 0 ] && continue

    if [ $((TOUCHED_BYTES + FSIZE)) -gt "$BUDGET_BYTES" ]; then
        log_pl "Budget reached (${BUDGET_MB}MB) - stopping before $(basename "$f")"
        break
    fi

    # This is the actual page-cache warm - reading the file's bytes forces
    # the kernel to fault them into cache. Redirected to /dev/null since we
    # only care about the side effect (pages now cached), not the content.
    cat "$f" > /dev/null 2>&1

    TOUCHED_BYTES=$((TOUCHED_BYTES + FSIZE))
    TOUCHED_COUNT=$((TOUCHED_COUNT + 1))
done

TOUCHED_MB=$((TOUCHED_BYTES / 1024 / 1024))
log_pl "Preloaded $PKG: $TOUCHED_COUNT $TARGET_TYPE file(s), ~${TOUCHED_MB}MB touched into page cache (budget ${BUDGET_MB}MB)"
