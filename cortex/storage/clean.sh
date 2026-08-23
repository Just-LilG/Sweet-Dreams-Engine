#!/system/bin/sh
# Storage Cleaner - "Clear App Caches Now"
CORTEX="/data/adb/modules/sweet_dreams/cortex"

BEFORE_KB=$(df /data 2>/dev/null | awk 'NR==2{print $4}')

# pm trim-caches asks PackageManager to free up to <bytes> of space by
# evicting the least-recently-used app caches first - the same path Android
# uses internally when storage gets low. Passing a huge target makes it
# trim everything it safely can. This never touches app data, only cache.
pm trim-caches 999999999999 2>/dev/null
sync

AFTER_KB=$(df /data 2>/dev/null | awk 'NR==2{print $4}')

FREED_KB=0
if [ -n "$BEFORE_KB" ] && [ -n "$AFTER_KB" ]; then
    FREED_KB=$((AFTER_KB - BEFORE_KB))
    [ "$FREED_KB" -lt 0 ] && FREED_KB=0
fi

echo "$FREED_KB" > "$CORTEX/storage/last_freed_kb.txt" 2>/dev/null
echo "freed_kb:$FREED_KB"
