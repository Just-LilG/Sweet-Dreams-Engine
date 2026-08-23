#!/system/bin/sh
# cortex/profile/apply.sh — one shot: CPU + GPU + scheduler (+ perf if on).
CORTEX="${CORTEX:-/data/adb/modules/sweet_dreams/cortex}"

if [ -n "$1" ]; then
    echo "$1" > "$CORTEX/cpu/profile.txt"
fi

sh "$CORTEX/cpu/apply.sh"
sh "$CORTEX/gpu/apply.sh"
sh "$CORTEX/sched/apply.sh"
if [ "$(cat "$CORTEX/perf/enabled.txt" 2>/dev/null)" = "on" ]; then
    sh "$CORTEX/perf/apply.sh"
fi
echo "PROFILE_APPLIED=$(cat "$CORTEX/cpu/profile.txt" 2>/dev/null)"
