#!/system/bin/sh
# cortex/device/check_conflicts.sh - Sweet Dreams
#
# WHY THIS EXISTS: if another performance-tuning module is installed
# alongside Sweet Dreams, both modules' service.sh scripts run at boot and
# both will try to write the same sysfs nodes (governor, thermal zones,
# scheduler tunables). This isn't a crash - both scripts "succeed"
# individually - it's a silent, hard-to-diagnose fight where whichever
# module's service.sh happens to run last on a given boot wins, and
# behavior can flip-flop between boots with zero indication why.
#
# ALGORITHM - this used to be a hardcoded list of module IDs I expected to
# conflict ("azenith", "kyuubi", "project_atlas", etc). That approach
# failed for a real, structural reason, not just a typo: it depends on
# guessing every conflicting module's exact on-disk id= correctly, forever,
# for modules that don't exist yet. AZenith's real id (confirmed against
# its own source) is "AZenith" - a casing mismatch alone made that one
# entry silently useless, and the other six entries were never verified
# against any real module's source at all, meaning some may not even
# correspond to anything real.
#
# The actual approach now: don't guess names - read what every other
# installed module's OWN SCRIPTS actually do, and check whether they write
# to the same sysfs/proc subsystems Sweet Dreams itself controls. This
# catches a genuine conflict regardless of what the module is called, who
# wrote it, or whether it existed when this script was written - the
# detection is grounded in actual file contents, not a prediction.
#
# CONFLICT_PATTERNS below is deliberately a small set of PATH PREFIXES for
# the specific subsystems that cause real, user-visible contention when
# two modules both touch them: CPU governor, GPU governor, thermal zone
# control, scheduler tunables, and MTK's PerfService/EAS boost paths.
# Extracted directly from grepping Sweet Dreams' own cpu/gpu/thermal/sched
# apply scripts - this list IS what Sweet Dreams itself writes, not a
# separate guess of what other modules might write. Deliberately excludes
# network/RAM/battery paths: those are far less commonly fought over by
# other tuning modules in practice, and including every path Sweet Dreams
# touches would produce false positives against modules that only,say,
# tune DNS or zram - not the kind of "flip-flopping behavior" conflict
# this check exists to catch.

MODDIR="/data/adb/modules/sweet_dreams"
CORTEX="$MODDIR/cortex"
RESULT_FILE="$CORTEX/device/conflicts.txt"
MODULES_ROOT="/data/adb/modules"

CONFLICT_PATTERNS="
/sys/devices/system/cpu/cpu.*cpufreq/scaling_governor
/sys/devices/system/cpu/cpufreq/policy.*/scaling_governor
/sys/class/devfreq/gpufreq/governor
/sys/class/misc/mali0/device/devfreq/.*/governor
/sys/devices/platform/mali.0/devfreq/mali.0/governor
/sys/kernel/gpu/gpu_governor
/sys/class/thermal/thermal_zone.*/mode
/sys/class/thermal/thermal_zone.*/policy
/proc/sys/kernel/sched_
/dev/stune/.*/schedtune
/dev/cpuctl/.*/cpu.uclamp
/proc/perfmgr/legacy/perfserv_ta
/proc/perfmgr/perf_ioctl
"

: > "$RESULT_FILE.tmp"

[ -d "$MODULES_ROOT" ] || { mv "$RESULT_FILE.tmp" "$RESULT_FILE" 2>/dev/null; exit 0; }

# Build one combined extended-regex from CONFLICT_PATTERNS so each other
# module only needs a single grep pass across its scripts, not one pass
# per pattern - meaningfully cheaper across N installed modules.
COMBINED_PATTERN=$(echo "$CONFLICT_PATTERNS" | grep -v '^$' | tr '\n' '|' | sed 's/|$//')

for dir in "$MODULES_ROOT"/*/; do
    [ -d "$dir" ] || continue
    mod_id=$(basename "$dir")
    [ "$mod_id" = "sweet_dreams" ] && continue
    # Skip disabled/removed modules - a conflict warning about a module
    # the user already turned off would be actively confusing.
    [ -f "${dir}disable" ] && continue
    [ -f "${dir}remove" ] && continue

    # BUG FIX: this used to call `grep -rlE "$PATTERN" "$dir" --include="*.sh"`.
    # --include is a GNU grep extension - Android's actual on-device grep is
    # toybox (or busybox on some ROMs), and toybox's grep does not support
    # --include at all (confirmed against Android's own toybox grep flag
    # list: -HhrilLnqvsoweFEABCz, no --include anywhere in it). Depending on
    # the exact toybox build, an unrecognized long option is either silently
    # ignored or causes the whole grep invocation to fail outright - either
    # way, this flag was never reliably filtering to *.sh files on a real
    # device, which is almost certainly why conflict detection wasn't firing
    # even for a module that should have matched.
    #
    # Fixed by using `find` to locate .sh files first (find's -name is
    # POSIX-portable and universally supported by toybox), then piping
    # those paths into grep with no long-option flags at all - just -l -E,
    # both in toybox's confirmed-supported set.
    # Bug fix: `xargs` with zero input lines still runs the command once
    # with no file arguments - grep with no files reads stdin instead and
    # blocks waiting for input that never comes, silently hanging this
    # loop forever the first time it hits a module with no .sh files at
    # all. `-r` (GNU) / `--no-run-if-empty` skips invoking grep entirely
    # when find produced nothing, which is the actual intent here.
    HIT=$(find "$dir" -name "*.sh" -type f 2>/dev/null | xargs -r grep -lE "$COMBINED_PATTERN" 2>/dev/null | head -1)

    if [ -n "$HIT" ]; then
        mod_name="$mod_id"
        [ -f "${dir}module.prop" ] && mod_name=$(grep "^name=" "${dir}module.prop" 2>/dev/null | cut -d= -f2-)
        [ -z "$mod_name" ] && mod_name="$mod_id"
        # Include which specific file triggered the match - genuinely
        # useful for a user (or future debugging) to see the exact
        # evidence rather than just trusting the flag with no detail.
        HIT_RELATIVE=$(echo "$HIT" | sed "s|^$dir||")
        echo "${mod_id}|${mod_name}|${HIT_RELATIVE}" >> "$RESULT_FILE.tmp"
    fi
done

mv "$RESULT_FILE.tmp" "$RESULT_FILE" 2>/dev/null

# Diagnostic logging - if conflict detection ever silently fails again,
# this gives real evidence (how many modules were scanned, how many
# matched) instead of needing another guess-and-check cycle to debug it.
SCANNED_COUNT=$(find "$MODULES_ROOT" -maxdepth 1 -type d 2>/dev/null | wc -l)
MATCHED_COUNT=$(wc -l < "$RESULT_FILE" 2>/dev/null || echo 0)
echo "[CONFLICT_CHECK] Scanned ~${SCANNED_COUNT} module dirs, ${MATCHED_COUNT} conflict match(es)" >> "$MODDIR/boot.log" 2>/dev/null
