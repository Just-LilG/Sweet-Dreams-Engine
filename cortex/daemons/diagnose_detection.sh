#!/system/bin/sh
# cortex/daemons/diagnose_detection.sh - Sweet Dreams
#
# ONE-TIME DIAGNOSTIC. Verifies which foreground-detection path is
# actually active on THIS device, and times how long each real candidate
# takes to run - instead of trusting a comment's own claim about what's
# "confirmed working". Run this once, send the output back.
#
# USAGE: su -c "sh /data/adb/modules/sweet_dreams/cortex/daemons/diagnose_detection.sh"

OUT="/data/adb/modules/sweet_dreams/detection_diagnosis.txt"
echo "=== Sweet Dreams Detection Speed Diagnosis ===" > "$OUT"
echo "Generated: $(date)" >> "$OUT"
echo "" >> "$OUT"

echo "-- Checking cpuset candidate paths --" >> "$OUT"
FOUND_CPUSET=""
for f in /dev/cpuset/top-app/cgroup.procs /dev/cpuset/top-app/tasks /sys/fs/cgroup/cpuset/top-app/cgroup.procs; do
    if [ -f "$f" ]; then
        echo "  [EXISTS] $f" >> "$OUT"
        [ -z "$FOUND_CPUSET" ] && FOUND_CPUSET="$f"
    else
        echo "  [missing] $f" >> "$OUT"
    fi
done
echo "" >> "$OUT"

if [ -n "$FOUND_CPUSET" ]; then
    echo "RESULT: cpuset path found - the FAST detection method is genuinely active on this device." >> "$OUT"
    echo "Using: $FOUND_CPUSET" >> "$OUT"
    echo "" >> "$OUT"
    echo "-- Timing a real cgroup read --" >> "$OUT"
    START=$(date +%s%N)
    cat "$FOUND_CPUSET" > /dev/null 2>&1
    END=$(date +%s%N)
    MS=$(( (END - START) / 1000000 ))
    echo "  Read took: ${MS}ms" >> "$OUT"
else
    echo "RESULT: NO cpuset path exists on this device/kernel." >> "$OUT"
    echo "This means the daemon has been falling back to the expensive" >> "$OUT"
    echo "dumpsys-based check this whole time, regardless of the v2.5.1 fix -" >> "$OUT"
    echo "the fast path was never actually reachable on this hardware." >> "$OUT"
    echo "" >> "$OUT"
    echo "-- Timing the two dumpsys fallback methods for real --" >> "$OUT"

    echo "  Method 1: dumpsys window windows | grep mCurrentFocus" >> "$OUT"
    START=$(date +%s%N)
    dumpsys window windows 2>/dev/null | grep -m1 'mCurrentFocus' > /dev/null
    END=$(date +%s%N)
    MS=$(( (END - START) / 1000000 ))
    echo "    Took: ${MS}ms" >> "$OUT"

    echo "  Method 2: dumpsys activity activities | grep ResumedActivity" >> "$OUT"
    START=$(date +%s%N)
    dumpsys activity activities 2>/dev/null | grep -E "topResumedActivity|ResumedActivity" > /dev/null
    END=$(date +%s%N)
    MS=$(( (END - START) / 1000000 ))
    echo "    Took: ${MS}ms" >> "$OUT"
fi

echo "" >> "$OUT"
echo "-- Current module version --" >> "$OUT"
grep "^version=" /data/adb/modules/sweet_dreams/module.prop >> "$OUT"

echo "" >> "$OUT"
echo "-- Is game_monitor.sh actually running right now? --" >> "$OUT"
GM_PID=$(cat /data/adb/modules/sweet_dreams/run/game_monitor.pid 2>/dev/null)
if [ -n "$GM_PID" ] && kill -0 "$GM_PID" 2>/dev/null; then
    echo "  Yes - PID $GM_PID" >> "$OUT"
    echo "  Process start time: $(stat -c '%y' "/proc/$GM_PID" 2>/dev/null)" >> "$OUT"
else
    echo "  NOT RUNNING - this would explain any detection delay entirely," >> "$OUT"
    echo "  since nothing is watching for the game launch at all." >> "$OUT"
fi

echo "" >> "$OUT"
echo "-- Timing the notification su+Binder call for real --" >> "$OUT"
echo "  (cortex/notify/post.sh su's into uid 2000 to call cmd notification -" >> "$OUT"
echo "  this was previously a SYNCHRONOUS blocking call in the detection loop," >> "$OUT"
echo "  now backgrounded, but timed here to confirm/rule out whether it was" >> "$OUT"
echo "  the actual source of any reported delay)" >> "$OUT"
START=$(date +%s%N)
su 2000 -c "cmd notification post -S bigtext -t 'Diagnostic' 'SweetDreams_diag' 'timing test'" >/dev/null 2>&1
END=$(date +%s%N)
MS=$(( (END - START) / 1000000 ))
echo "  su 2000 -c 'cmd notification post ...' took: ${MS}ms" >> "$OUT"
if [ "$MS" -gt 3000 ]; then
    echo "  >>> This is slow enough to be a real contributor to a perceived delay." >> "$OUT"
elif [ "$MS" -gt 1000 ]; then
    echo "  >>> Moderate - noticeable but unlikely to cause a full minute alone." >> "$OUT"
else
    echo "  >>> Fast - this call is not the bottleneck on this run." >> "$OUT"
fi

cat "$OUT"
echo ""
echo "Full report saved to: $OUT"
