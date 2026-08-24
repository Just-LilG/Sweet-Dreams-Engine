#!/system/bin/sh
# cortex/daemons/game_monitor.sh - "OOM Watcher"
# Watches selected games: protects their PIDs from the low-memory killer,
# re-asserts the CPU floor, RR lock, and FPS cap every 2s while one is running,
# and fires the one-shot launch/exit tasks (kill-bg, net-block, perf boost,
# sensor mode, audio mode). Runs as its own process (not an anonymous inline
# subshell) so it can be reliably detected and restarted from the WebUI.
MODDIR="/data/adb/modules/sweet_dreams"
CORTEX="$MODDIR/cortex"
LOGFILE="$MODDIR/boot.log"
RUNDIR="$MODDIR/run"
mkdir -p "$RUNDIR"
echo "$$" > "$RUNDIR/game_monitor.pid"

log_p() { echo "[$(date '+%H:%M:%S')] $1" >> "$LOGFILE"; }

. "$CORTEX/thermal/state.sh"
. "$CORTEX/display/game_mode.sh"
SESSION_LOG="$CORTEX/daemons/session.log"
mkdir -p "$CORTEX/daemons" "$CORTEX/games"
log_s() {
    local line="[$(date '+%F %H:%M:%S')] $1"
    echo "$line" >> "$SESSION_LOG"
    echo "$line" >> "$LOGFILE"
}

prepare_session_spoof() {
    local pkg="$1"
    rm -f "$CORTEX/thermal/spoof_c_session.txt"
    if [ -n "$pkg" ] && [ -f "$CORTEX/games/${pkg}.spoof_c" ]; then
        cat "$CORTEX/games/${pkg}.spoof_c" > "$CORTEX/thermal/spoof_c_session.txt"
        log_s "per-game spoof_c for $pkg: $(cat "$CORTEX/thermal/spoof_c_session.txt")"
    fi
}

# Bug fix: the [TIMING] lines below used to call `date +%s%N` (nanosecond
# epoch) directly at each measurement point. This device's `date` binary
# doesn't support %N reliably (many toybox/busybox builds on Android
# don't) - it silently returns an incorrect or non-monotonic value on
# every call, which is why timing deltas came out negative in some spots
# and inconsistent between phases. /proc/uptime is provided directly by
# the kernel, always monotonic, and universally supported - the first
# field is seconds-since-boot with two decimal places (10ms resolution),
# which is precise enough for these launch-sequence timings. Multiplying
# by 100 and stripping the decimal point gives whole centiseconds as an
# integer bash/dash arithmetic can subtract directly, then ×10 for ms.
_now_ms() {
    awk '{printf "%d", ($1 * 1000)}' /proc/uptime 2>/dev/null || echo 0
}

# -- one-time capability probe --------------------------------------------------
# This kernel doesn't expose legacy schedtune cgroups or MTK PPM hard-limit
# nodes (newer kernels use EAS/uclamp instead - confirmed by boot.log showing
# "No such file or directory" on every single 2s loop iteration while gaming,
# since the old code retried these writes unconditionally forever). Probe
# once at startup and skip whichever paths don't exist for the rest of the
# daemon's life instead of spamming the log on every loop.
HAS_SCHEDTUNE=0
[ -e /dev/stune/top-app/schedtune.boost ] && HAS_SCHEDTUNE=1
HAS_PPM=0
[ -e /proc/ppm/policy/hard_userlimit_min_cpu_freq ] && HAS_PPM=1
HAS_UCLAMP=0
[ -e /dev/cpuctl/top-app/cpu.uclamp.min ] && HAS_UCLAMP=1
log_p "Capability probe: schedtune=$HAS_SCHEDTUNE ppm=$HAS_PPM uclamp=$HAS_UCLAMP"

# -- helper: CPU freq floor - re-asserted every loop to survive thermal throttle
enforce_cpu_floor() {
    local P="$1"
    [ "$P" = "battery" ] && return
    for i in 0 1 2 3 4 5; do
        echo "1800000" > /sys/devices/system/cpu/cpu${i}/cpufreq/scaling_min_freq 2>/dev/null
    done
    for i in 6 7; do
        echo "2000000" > /sys/devices/system/cpu/cpu${i}/cpufreq/scaling_min_freq 2>/dev/null
        echo "2200000" > /sys/devices/system/cpu/cpu${i}/cpufreq/scaling_max_freq 2>/dev/null
    done
    # MTK PPM hard floor - only on kernels that expose it; survives thermal
    # policy resets where it exists, but a no-op write here would otherwise
    # spam "No such file or directory" into the log every 2s while gaming.
    if [ "$HAS_PPM" = "1" ]; then
        echo "0 1800000" > /proc/ppm/policy/hard_userlimit_min_cpu_freq 2>/dev/null
        echo "1 2000000" > /proc/ppm/policy/hard_userlimit_min_cpu_freq 2>/dev/null
    fi
}

# -- helper: boost all PIDs of a package every loop ----------------------------
# CPU nice priority and I/O priority boost added - this is the same idea as
# AZenith's native set_priority(): setpriority(PRIO_PROCESS, pid, -20) plus
# a real-time ioprio_set() class on the game's PID. We don't have raw
# syscall access from shell, but `renice` wraps setpriority() directly (it's
# present on every Android device via toybox, not something that needs a
# feature check), and `chrt`+`ionice` cover I/O class where available -
# gated behind an existence check since I/O priority tools aren't
# guaranteed present on every ROM the way renice is. This is a genuine gap
# Sweet Dreams had that AZenith's daemon already covers: without it, the
# kernel CFS scheduler treats the game's threads as equal-priority to every
# other background process still alive, and I/O requests queue FIFO/best-
# effort alongside everything else instead of jumping the line.
HAS_IONICE=""
[ -x /system/bin/ionice ] && HAS_IONICE="ionice"
HAS_CHRT=""
[ -x /system/bin/chrt ] && HAS_CHRT="chrt"

boost_pids() {
    local PKG="$1"
    for PID in $(pidof "$PKG" 2>/dev/null); do
        echo "-1000" > /proc/$PID/oom_score_adj    2>/dev/null
        echo "0"     > /proc/$PID/timerslack_ns    2>/dev/null
        echo "$PID"  > /dev/cpuset/top-app/tasks   2>/dev/null
        # Max CPU nice priority (-20) - same effect as AZenith's
        # setpriority(PRIO_PROCESS, pid, -20), just via the renice binary
        # since shell can't call setpriority() directly.
        renice -n -20 -p "$PID" >/dev/null 2>&1
        # Real-time I/O priority class, best-effort priority level 0 (highest
        # non-RT tier that doesn't risk starving the rest of the system).
        # ionice's class 1 = IOPRIO_CLASS_RT, matching AZenith's ioprio_set
        # call exactly (SYS_ioprio_set with class 1). chrt is a fallback on
        # ROMs that ship it but not ionice - sets the scheduling policy to
        # SCHED_RR at low RT priority, a different but related win (CPU
        # scheduling class rather than I/O), so it's a real fallback and not
        # a no-op placeholder.
        if [ -n "$HAS_IONICE" ]; then
            ionice -c 1 -n 0 -p "$PID" >/dev/null 2>&1
        elif [ -n "$HAS_CHRT" ]; then
            chrt -r -p 1 "$PID" >/dev/null 2>&1
        fi
        # EAS schedtune boost (legacy cgroup - only on kernels that expose it)
        if [ "$HAS_SCHEDTUNE" = "1" ]; then
            echo "100" > /dev/stune/top-app/schedtune.boost       2>/dev/null
            echo "1"   > /dev/stune/top-app/schedtune.prefer_idle 2>/dev/null
        fi
        # uclamp for kernels without schedtune (this device's actual path)
        if [ "$HAS_UCLAMP" = "1" ]; then
            echo "max" > /dev/cpuctl/top-app/cpu.uclamp.min 2>/dev/null
        fi
    done
}

# -- helper: hard-lock RR on every loop iteration ------------------------------
# `settings put` is a thin wrapper around `cmd settings put` - on a device
# where the `cmd` dispatcher's IPC path is blocked (see the SELinux finding:
# https://github.com/termux/termux-app/issues/1209 and similar - this exact
# error text is a known, non-timing-related issue), settings put fails every
# time regardless of retries. `content update` goes through the
# ContentProvider/ContentResolver binder path instead, which is a genuinely
# different mechanism, not just a retry of the same broken one - worth
# attempting alongside, not in place of, in case one path works where the
# other doesn't. This assumes the row already exists (true for
# peak_refresh_rate/min_refresh_rate on any real device - they're core
# display settings), so `content update` rather than `content insert`.
settings_put_system() {
    # Skip the cmd-dispatched attempt entirely once we know it's a guaranteed
    # failure on this device - see cortex/device/evaluate_mitigations.sh.
    # Saves a subprocess + a doomed IPC round-trip every single call, on top
    # of the log noise a failed attempt used to add before the redirect fix.
    if ! grep -qx "CMD_DISPATCHER_UNRELIABLE" "$CORTEX/device/active.txt" 2>/dev/null; then
        settings put system "$1" "$2" >/dev/null 2>&1
    fi
    content update --uri content://settings/system --bind value:s:"$2" --where "name='$1'" >/dev/null 2>&1
}

lock_rr() {
    local T="$1"
    settings_put_system peak_refresh_rate "$T"
    settings_put_system min_refresh_rate  "$T"
    resetprop ro.surface_flinger.use_content_detection_for_refresh_rate false 2>/dev/null
    resetprop debug.sf.use_content_detection_for_refresh_rate false            2>/dev/null
    resetprop persist.sys.disable_rrs 1                                        2>/dev/null
}

# -- helper: restore adaptive RR ----------------------------------------------─
unlock_rr() {
    local T="$1"
    settings_put_system peak_refresh_rate "$T"
    settings_put_system min_refresh_rate  60
    resetprop ro.surface_flinger.use_content_detection_for_refresh_rate true 2>/dev/null
    resetprop debug.sf.use_content_detection_for_refresh_rate true           2>/dev/null
    resetprop persist.sys.disable_rrs 0                                      2>/dev/null
}

# -- helper: multi-layer FPS cap - re-applied every loop ----------------------─
enforce_fps_lock() {
    local CAP="$1"
    # Layer 1: our own native frame-pacing engine (replaces Frieren_FPS)
    sh "$CORTEX/fps/engine.sh" "$CAP" game 2>/dev/null
    # Layer 2: SurfaceFlinger setFrameRate binder call
    service call SurfaceFlinger 1035 i32 "$CAP" >/dev/null 2>&1
    # Layer 3: MTK display frame rate policy node
    # Bug fix: this used to write unconditionally every 2s. On kernels
    # that don't expose this debugfs node (confirmed on this device - it
    # simply doesn't exist), `echo ... > path` still throws a shell-level
    # "can't create <path>: No such file or directory" error that bypasses
    # the command's own `2>/dev/null` entirely, because the failure happens
    # in the shell's own redirection setup before echo ever runs. That
    # error was landing in the boot.log every single loop tick for the
    # entire game session - hundreds of times per session, and to noise
    # that never went away since the check only happens on write attempt.
    # Testing for the node first with `[ -e ... ]` avoids the redirection
    # attempt entirely when it's absent, which is the common case on
    # kernels without this specific MTK debug interface.
    [ -e /sys/kernel/debug/mtk_mira/fps_limit ] && echo "$CAP" > /sys/kernel/debug/mtk_mira/fps_limit 2>/dev/null
    # Bug fix: this used to also write "$CAP" (a raw FPS number, e.g. 90) to
    # /proc/perfmgr/legacy/perfserv_ta every 2s here. cortex/perf/apply.sh
    # writes to that exact same node with a completely different value
    # space - MTK PerfService *scenario IDs* (0=idle, 1=launch, 2=game,
    # 3=touch), set once at game launch via trigger_perf_scenario(). Since
    # this loop runs every 2s while the game loop's "boost" (perf/apply.sh
    # scenario 2) only runs once at launch, the FPS-number write here was
    # clobbering the GAME_SCENARIO hint within 2 seconds of it being set -
    # two subsystems fighting over one node with incompatible semantics.
    # Removed; perf/apply.sh already owns this node exclusively.
    # NOTE: a 4th layer used to force a fixed GPU frequency ceiling here
    # (gpufreq_opp_freq) tuned per FPS target, on the theory that it would
    # prevent GPU-overheat-induced CPU throttle. In practice this directly
    # fought cortex/gpu/apply.sh (which sets the Mali governor to
    # "performance" - max clock, no scaling - on Gaming profile) and
    # cortex/perf/apply.sh (which sets highfreq_hint=1, also pushing for
    # max clock). Three different mechanisms were issuing contradictory
    # frequency directives to the same GPU every 2s while gaming, which is
    # exactly the kind of fight that produces stutter and FPS drops instead
    # of preventing them. The frame-rate cap itself is already correctly
    # enforced by layers 1-3 above (HWUI render limit, SF setFrameRate, MTK
    # display fps_limit node) without needing to also starve GPU clock -
    # removed.
}

# -- helper: release FPS cap on exit ------------------------------------------─
release_fps_lock() {
    local T="$1"
    sh "$CORTEX/fps/engine.sh" restore 2>/dev/null
    service call SurfaceFlinger 1035 i32 0 >/dev/null 2>&1
}

# -- helper: restore cpu to profile defaults + release MTK PPM ----------------─
restore_cpu() {
    [ "$HAS_PPM" = "1" ] && echo "0" > /proc/ppm/policy/hard_userlimit_min_cpu_freq 2>/dev/null
    sh "$CORTEX/cpu/apply.sh" 2>/dev/null
    if [ "$HAS_SCHEDTUNE" = "1" ]; then
        echo "0" > /dev/stune/top-app/schedtune.boost       2>/dev/null
        echo "0" > /dev/stune/top-app/schedtune.prefer_idle 2>/dev/null
    fi
}

# -- helper: is a candidate game's process actually foreground right now? ------
# Bug fix: this used to rely ENTIRELY on foreground_pkg.sh, which parses
# `dumpsys activity activities` / `dumpsys window` text output. That's
# fragile in a way that turned out to matter: on a device/Android version
# where the dump lists multiple displays/stacks and an earlier one reports
# "mResumedActivity: null" before the real foreground activity's line,
# `grep -m1` latches onto the null line first and returns nothing - forever,
# every single loop, regardless of what's actually on screen. That silently
# broke EVERY one-shot launch action (spoof, net-block, perf boost, sensor,
# audio, thermal, resolution, kill-bg) since all of them are gated behind
# this exact check succeeding.
#
# Fixed by checking real kernel cgroup membership instead of parsing text at
# all: /dev/cpuset/top-app/tasks is the exact cpuset Android's own
# ActivityManager puts foreground/perceptible processes into - and this
# module already WRITES boosted PIDs into that same file in boost_pids()
# above, so it's a confirmed-real, confirmed-working path on this device,
# not a guess. If a candidate game's PID appears in that file, it's
# foreground, full stop - no dumpsys formatting to get wrong. Falls back to
# the old foreground_pkg.sh text-parsing approach only if this cpuset path
# doesn't exist at all on a given device/kernel.
TOP_APP_CPUSET=""
for f in /dev/cpuset/top-app/cgroup.procs /dev/cpuset/top-app/tasks /sys/fs/cgroup/cpuset/top-app/cgroup.procs; do
    [ -f "$f" ] && TOP_APP_CPUSET="$f" && break
done

is_pkg_foreground() {
    local PKG="$1"
    local focus
    # Fast path: window focus (much cheaper than dumpsys activity activities).
    focus=$(dumpsys window 2>/dev/null | grep -m1 -E 'mCurrentFocus|mFocusedApp' \
        | grep -oE '[A-Za-z][A-Za-z0-9_.]*/[A-Za-z0-9_.]*' | head -1 | cut -d/ -f1)
    [ -n "$focus" ] && [ "$focus" = "$PKG" ] && return 0

    if [ -n "$TOP_APP_CPUSET" ]; then
        for PID in $(pidof "$PKG" 2>/dev/null); do
            grep -qx "$PID" "$TOP_APP_CPUSET" 2>/dev/null && return 0
        done
    fi
    [ "$(sh "$CORTEX/games/foreground_pkg.sh" 2>/dev/null)" = "$PKG" ]
}

LAST_GAME_FILE="$RUNDIR/last_game.txt"
LAST_GAME=""
LOOP_ITER=0
# Throttle for the "alive but not foregrounded yet" log line below - without
# this, a game left selected but never actually opened (common: added via
# search, still sitting backgrounded from unrelated earlier phone use) would
# print that line every single 2s loop tick forever, forever.
FG_WAIT_LOG_AT=0
# BACKGROUND_SINCE tracks when the currently-tracked game FIRST stopped
# being foreground, so a brief app-switch (checking a notification,
# glancing at another app for a few seconds) doesn't immediately trigger
# the full exit sequence - see the debounce logic in the "else" branch
# below for why this matters (force-stop+relaunch on every background
# was causing visible lag when the user returned to a game they never
# actually closed).
BACKGROUND_SINCE=0

# Recover state across a daemon restart. If a game was already running before
# this instance started (e.g. the daemon was manually restarted, or recovered
# after a crash), reconcile silently instead of logging a fresh "Game ON" and
# rerunning the whole launch sequence for a game that never actually relaunched.
RECOVERED_GAME=$(cat "$LAST_GAME_FILE" 2>/dev/null || echo "")
if [ -n "$RECOVERED_GAME" ]; then
    # Same fix as the main detection loop below: confirm the recovered
    # game is genuinely the FOREGROUND app right now, not just alive
    # somewhere in the process table (background service, cached process,
    # etc). Without this, restarting the daemon while a previously-tracked
    # game had merely exited to background (but kept a live service) would
    # make the new instance think it's still "running" and resume a watch
    # session for a game the user isn't actually in anymore.
    # IMPROVED: this used to be its own inline 2-candidate duplicate of the
    # same detection logic in foreground_pkg.sh. Now that foreground_pkg.sh
    # has a 5-candidate cascade (see that file's comments - mirrors
    # AZenith's multi-method-candidate philosophy), calling it directly here
    # keeps this recovery path exactly as resilient as the main detection
    # loop instead of silently lagging behind with fewer fallbacks, and
    # removes a second copy of the same regex logic to keep in sync.
    RECOVER_FG_PKG=$(sh "$CORTEX/games/foreground_pkg.sh" 2>/dev/null)
    if [ "$RECOVERED_GAME" = "$RECOVER_FG_PKG" ]; then
    for PID in $(pidof "$RECOVERED_GAME" 2>/dev/null); do
        STATE=$(awk '{print $3}' "/proc/$PID/stat" 2>/dev/null)
        if [ -n "$STATE" ] && [ "$STATE" != "Z" ] && [ "$STATE" != "X" ]; then
            LAST_GAME="$RECOVERED_GAME"
            log_p "Daemon (re)started - $RECOVERED_GAME already running, resuming watch silently (no relaunch sequence)"
            # Bug fix: resolution scaling used to be skipped here along with
            # every other one-shot launch task. That's correct for perf/
            # sensor/audio/kill_bg/spoof (they're already applied and
            # re-running them would be redundant or disruptive), but wrong
            # for resolution - if THIS is the first daemon instance to ever
            # see this game (e.g. the module was just updated/restarted
            # while the game was already open), resolution was never
            # applied by anyone and silently skipping it here means it
            # just never happens for the entire rest of the session.
            # apply_resolution.sh is idempotent (wm size/density to the
            # same value twice is harmless), so just always ensure it
            # matches the saved preference on recovery instead of guessing
            # whether a previous instance already got to it.
            #
            # IMPROVED: this used to only ever read the GLOBAL resolution/
            # thermal config on recovery, ignoring any per-game profile
            # override entirely - a game with a custom profile that
            # happened to be open across a daemon restart would silently
            # fall back to global settings instead of its saved profile
            # until the user closed and reopened it. Checking the profile
            # file here too keeps recovery consistent with the main loop.
            RECOVER_PROFILE_FILE="$CORTEX/games/profiles/$(echo "$RECOVERED_GAME" | tr '.' '-').txt"
            RES_TARGET_RECOVER=$(resolve_scale "$RECOVERED_GAME")
            THERMAL_MODE_RECOVER=""
            if [ -f "$RECOVER_PROFILE_FILE" ]; then
                THERMAL_MODE_RECOVER=$(grep "^thermal_mode=" "$RECOVER_PROFILE_FILE" 2>/dev/null | cut -d= -f2-)
            fi
            [ "$RES_TARGET_RECOVER" != "native" ] && SKIP_RESTART=1 sh "$CORTEX/display/apply_resolution.sh" "$RES_TARGET_RECOVER" "$RECOVERED_GAME" 2>/dev/null
            # Same reasoning applies to thermal spoof - if this daemon
            # instance is the first to ever see this session (module
            # updated/daemon restarted mid-game), nobody has mounted the
            # fake-temp override yet. mount_fake_temps() checks for an
            # existing mount before acting, so calling it again on an
            # already-recovered session that DID get it applied is a safe
            # no-op, not a double-mount.
            if thermal_is_armed; then
                prepare_session_spoof "$RECOVERED_GAME"
                sh "$CORTEX/thermal/apply.sh" game_start "$THERMAL_MODE_RECOVER" 2>/dev/null
                log_s "thermal apply (recover) $RECOVERED_GAME"
            fi
            sh "$CORTEX/touch/apply.sh" game_start 2>/dev/null
            break
        fi
    done
    fi
    [ -z "$LAST_GAME" ] && : > "$LAST_GAME_FILE"
fi

while true; do
    # Re-read all config every loop - UI changes take effect within 2s
    SELECTED=$(cat "$CORTEX/games/selected.txt" 2>/dev/null || echo "")
    PROFILE=$(cat "$CORTEX/cpu/profile.txt"         2>/dev/null || echo "gaming")
    RR_LOCK=$(cat "$CORTEX/display/rr_lock.txt"     2>/dev/null || echo "off")
    FPS_LOCK=$(cat "$CORTEX/display/fps_lock_game.txt" 2>/dev/null || echo "off")
    TARGET_FPS=$(cat "$CORTEX/display/fps.txt"      2>/dev/null || echo "90")
    KILL_BG=$(cat "$CORTEX/games/kill_bg_enabled.txt"    2>/dev/null || echo "off")

    RUNNING_GAME=""
    # Prefer a single cheap window-focus read, then match against selected list.
    # Falls back to per-pkg is_pkg_foreground (cpuset / full cascade).
    FOREGROUND_PKG=$(dumpsys window 2>/dev/null | grep -m1 -E 'mCurrentFocus|mFocusedApp' \
        | grep -oE '[A-Za-z][A-Za-z0-9_.]*/[A-Za-z0-9_.]*' | head -1 | cut -d/ -f1)
    if [ -n "$FOREGROUND_PKG" ]; then
        echo "$SELECTED" | while IFS= read -r PKG || [ -n "$PKG" ]; do
            PKG=$(printf '%s' "$PKG" | tr -d '\r')
            [ -z "$PKG" ] && continue
            [ "$PKG" = "$FOREGROUND_PKG" ] && echo "$PKG" && break
        done > "$RUNDIR/fg_match.txt"
        RUNNING_GAME=$(cat "$RUNDIR/fg_match.txt" 2>/dev/null | head -1)
    fi
    if [ -z "$RUNNING_GAME" ]; then
        echo "$SELECTED" | while IFS= read -r PKG || [ -n "$PKG" ]; do
            PKG=$(printf '%s' "$PKG" | tr -d '\r')
            [ -z "$PKG" ] && continue
            if is_pkg_foreground "$PKG"; then
                echo "$PKG"
                break
            fi
        done > "$RUNDIR/fg_match.txt"
        RUNNING_GAME=$(cat "$RUNDIR/fg_match.txt" 2>/dev/null | head -1)
    fi

    # NOTE: the old `for PKG in $SELECTED` path is replaced above so packages
    # with unusual characters still parse, and so we only pay for one focus
    # dump in the common case.

    # Per-game profiles: if this game has a saved profile (see webroot's
    # "Save Profile" action), it overrides the global PROFILE/TARGET_FPS/
    # RR_LOCK/FPS_LOCK/resolution values for as long as it's running. This
    # override is intentionally scoped to only fire while RUNNING_GAME is
    # set - the moment the game exits, RUNNING_GAME goes empty next
    # iteration and the top-of-loop re-read above already restores the
    # global defaults on its own, so no separate "restore" logic is needed
    # for the exit path (unlock_rr/release_fps_lock/restore_cpu below
    # naturally see the global values again once the game is gone).
    RES_OVERRIDE=""
    THERMAL_OVERRIDE=""
    if [ -n "$RUNNING_GAME" ]; then
        PROFILE_FILE="$CORTEX/games/profiles/$(echo "$RUNNING_GAME" | tr '.' '-').txt"
        if [ -f "$PROFILE_FILE" ]; then
            while IFS='=' read -r PKEY PVAL; do
                case "$PKEY" in
                    profile)      PROFILE="$PVAL" ;;
                    fps)          TARGET_FPS="$PVAL" ;;
                    rr_lock)      RR_LOCK="$PVAL" ;;
                    fps_lock)     FPS_LOCK="$PVAL" ;;
                    resolution)   RES_OVERRIDE="$PVAL" ;;
                    thermal_mode) THERMAL_OVERRIDE="$PVAL" ;;
                esac
            done < "$PROFILE_FILE"
        fi
    fi

    if [ -n "$RUNNING_GAME" ]; then
        # Game is confirmed foreground THIS tick - clear any in-progress
        # background debounce so a later background dip starts counting
        # fresh rather than inheriting a stale timestamp from an earlier,
        # already-resolved dip.
        BACKGROUND_SINCE=0

        # -- First detection: one-shot tasks ----------------------------------─
        if [ "$RUNNING_GAME" != "$LAST_GAME" ]; then
            # RUNNING_GAME is already focus/cpuset confirmed above — do not
            # re-check here (that double dump was a common source of multi-
            # second "boost is active" delay after the game was already open).
            log_p "Game ON: $RUNNING_GAME"
            _LAUNCH_T0=$(_now_ms)

            # Snapshot all config values up front - shared across all three
            # phases below; avoids subshells racing to cat the same files.
            GAME_LABEL=$(echo "$RUNNING_GAME" | awk -F. '{print $NF}')
            PROFILE_NOW=$(cat "$CORTEX/cpu/profile.txt"             2>/dev/null || echo "gaming")
            PING_EN=$(cat "$CORTEX/net/ping_stabilizer_enabled.txt" 2>/dev/null || echo "off")
            PERF_EN=$(cat "$CORTEX/perf/enabled.txt"               2>/dev/null || echo "on")
            SENSOR_EN=$(cat "$CORTEX/sensor/enabled.txt"           2>/dev/null || echo "off")
            AUDIO_EN=$(cat "$CORTEX/audio/enabled.txt"             2>/dev/null || echo "off")
            SPOOF_MASTER=$(cat "$CORTEX/games/spoof_master.txt"    2>/dev/null || echo "off")
            THERMAL_ARMED=0
            thermal_is_armed && THERMAL_ARMED=1

            # -- PHASE 1: Notification - immediate user feedback --------------─
            sh "$CORTEX/notify/post.sh" game_launch "Sweet Dreams" \
                "Boost active for ${GAME_LABEL} - ${TARGET_FPS}fps - ${PROFILE_NOW} profile" 2>/dev/null &
            echo "[TIMING] notification fired: $(( $(_now_ms) - _LAUNCH_T0 ))ms" >> "$LOGFILE"

            # -- PHASE 2: Resolution ------------------------------------------
            # If WebUI already armed the same factor, reinforce in session mode
            # (overlay + optional wm size) WITHOUT force-stopping the game.
            RES_TARGET=$(resolve_scale "$RUNNING_GAME")
            if [ "$RES_TARGET" != "native" ]; then
                PREV_F=$(cat "$CORTEX/display/resolution_applied_factor.txt" 2>/dev/null | tr -d '\r\n ')
                PREV_P=$(cat "$CORTEX/display/resolution_applied_pkg.txt" 2>/dev/null | tr -d '\r\n ')
                if [ "$PREV_F" = "$RES_TARGET" ] && [ "$PREV_P" = "$RUNNING_GAME" ]; then
                    sh "$CORTEX/display/apply_resolution.sh" "$RES_TARGET" "$RUNNING_GAME" session 2>/dev/null
                else
                    sh "$CORTEX/display/apply_resolution.sh" "$RES_TARGET" "$RUNNING_GAME" 2>/dev/null
                fi
            fi
            echo "[TIMING] apply_resolution.sh done (sync): $(( $(_now_ms) - _LAUNCH_T0 ))ms" >> "$LOGFILE"

            # -- PHASE 3: All other tweaks - parallel -------------------------
            {
                [ "$KILL_BG" = "on" ] && sh "$CORTEX/games/kill_bg.sh" "$RUNNING_GAME" 2>/dev/null
                echo "[TIMING] kill_bg done: $(( $(_now_ms) - _LAUNCH_T0 ))ms" >> "$LOGFILE"
            } &
            _PID_KILL=$!

            {
                sh "$CORTEX/net/apply.sh" game_start 2>/dev/null
                echo "[TIMING] net/apply.sh done: $(( $(_now_ms) - _LAUNCH_T0 ))ms" >> "$LOGFILE"
            } &
            _PID_NET=$!

            {
                if [ "$THERMAL_ARMED" = "1" ]; then
                    prepare_session_spoof "$RUNNING_GAME"
                    sh "$CORTEX/thermal/apply.sh" game_start "$THERMAL_OVERRIDE" 2>/dev/null
                    log_s "thermal apply $RUNNING_GAME $(cat "$CORTEX/thermal/last_verify.txt" 2>/dev/null)"
                fi
                echo "[TIMING] thermal/apply.sh done: $(( $(_now_ms) - _LAUNCH_T0 ))ms" >> "$LOGFILE"
            } &
            _PID_THERMAL=$!

            {
                [ "$SENSOR_EN" = "on" ] && sh "$CORTEX/sensor/apply.sh" game 2>/dev/null
                echo "[TIMING] sensor/apply.sh done: $(( $(_now_ms) - _LAUNCH_T0 ))ms" >> "$LOGFILE"
            } &
            _PID_SENSOR=$!

            {
                [ "$AUDIO_EN" = "on" ] && sh "$CORTEX/audio/apply.sh" 2>/dev/null
                echo "[TIMING] audio/apply.sh done: $(( $(_now_ms) - _LAUNCH_T0 ))ms" >> "$LOGFILE"
            } &
            _PID_AUDIO=$!

            {
                [ "$SPOOF_MASTER" = "on" ] && sh "$CORTEX/games/spoof.sh" 2>/dev/null
                echo "[TIMING] spoof.sh done: $(( $(_now_ms) - _LAUNCH_T0 ))ms" >> "$LOGFILE"
            } &
            _PID_SPOOF=$!

            {
                sh "$CORTEX/touch/apply.sh" game_start 2>/dev/null
                echo "[TIMING] touch/apply.sh done: $(( $(_now_ms) - _LAUNCH_T0 ))ms" >> "$LOGFILE"
            } &
            _PID_TOUCH=$!

            [ "$PERF_EN" = "on" ] && sh "$CORTEX/perf/apply.sh" "$RUNNING_GAME" boost 2>/dev/null
            echo "[TIMING] perf/apply.sh done (sync): $(( $(_now_ms) - _LAUNCH_T0 ))ms" >> "$LOGFILE"

            wait $_PID_KILL $_PID_NET $_PID_THERMAL $_PID_SENSOR $_PID_AUDIO $_PID_SPOOF $_PID_TOUCH
            echo "[TIMING] all phases complete: $(( $(_now_ms) - _LAUNCH_T0 ))ms total" >> "$LOGFILE"

            sh "$CORTEX/games/preload.sh" "$RUNNING_GAME" 2>/dev/null &
            sh "$CORTEX/games/cpuinfo_mount.sh" "$RUNNING_GAME" on 2>/dev/null
            LAST_GAME="$RUNNING_GAME"
            echo "$LAST_GAME" > "$LAST_GAME_FILE"
            LOOP_ITER=0
        fi

        # -- CONTINUOUS - runs every 2s while game is alive --------------------

        # Boost PIDs (OOM + timerslack + cpuset + stune every loop) - this
        # part intentionally still runs on pidof-alive alone (RUNNING_GAME),
        # not gated on confirmation. It exists specifically to protect a
        # genuinely backgrounded (already-confirmed-then-alt-tabbed-away)
        # game session from the low-memory killer, and is harmless to also
        # apply to a not-yet-confirmed one - worst case, a cached process
        # that was never really "launched" this session gets a slightly
        # lower OOM score, which has no other side effect.
        boost_pids "$RUNNING_GAME"

        # -- Persistent boost indicator ------------------------------------------
        # WHY THIS EXISTS: the launch/exit notifications are useful but
        # disappear from the shade once dismissed or replaced by something
        # else, leaving no at-a-glance way to tell "is Sweet Dreams actually
        # doing anything right now" without opening the WebUI.
        #
        # A TRUE non-dismissible notification (Notification.FLAG_ONGOING_EVENT
        # / setOngoing(true)) is a Java Notification.Builder-level flag -
        # confirmed against NotificationShellCmd.java's actual source (the
        # class backing `cmd notification post`): its complete flag set is
        # -h/-v/-t/-i/-I/-S/-c, with no ongoing/persistent flag exposed at
        # the shell command level at all. So a genuinely undismissible
        # notification isn't reachable through this mechanism - this
        # doesn't pretend otherwise.
        #
        # What IS achievable: re-posting to the same tag on a timer. Same
        # tag means each repost replaces the previous one rather than
        # stacking (post.sh already tags by category), so if the user
        # dismisses it, it reappears within ~60s as long as the game is
        # still actively being boosted - a practical stand-in for "shows
        # persistently while active" even without the real OS-level flag.
        # Gated to once per ~60s (every 30th loop tick, ~2s/tick) - frequent
        # enough to feel present, infrequent enough not to be spammy or
        # cost meaningful battery/Binder overhead.
        if [ $((LOOP_ITER % 30)) = "0" ]; then
            # Recomputed fresh here rather than reused from the one-shot
            # launch block above - GAME_LABEL/PROFILE_NOW/TARGET_FPS are
            # only ever assigned there, so on a daemon-recovery path (game
            # was already running when this daemon instance started) they
            # could be unset entirely, and even in the normal case the
            # profile/FPS target can change mid-session via the WebUI
            # without another launch event firing to refresh them.
            _IND_LABEL=$(echo "$RUNNING_GAME" | awk -F. '{print $NF}')
            _IND_PROFILE=$(cat "$CORTEX/cpu/profile.txt" 2>/dev/null || echo "gaming")
            _IND_FPS=$(cat "$CORTEX/display/fps.txt" 2>/dev/null || echo "90")
            sh "$CORTEX/notify/post.sh" boost_indicator "Sweet Dreams" \
                "Boost active for ${_IND_LABEL} - ${_IND_FPS}fps - ${_IND_PROFILE} profile" 2>/dev/null &
        fi

        # Bug fix (Kill Background Apps firing when no game is actually
        # open): everything below this point used to run whenever
        # RUNNING_GAME was merely pidof-alive - including the periodic
        # kill_bg re-enforcement. That meant a game just sitting cached in
        # the background (ticked on in the Games tab, or leftover from
        # normal phone use, never actually opened this session) could get
        # its background-app-killing enforcement applied - the exact
        # opposite of "only enforce this while a game is genuinely running".
        # Gate the rest of this block on RUNNING_GAME actually being the
        # CONFIRMED game (LAST_GAME only ever gets set once is_pkg_foreground
        # has passed, above) - not just alive somewhere.
        if [ "$RUNNING_GAME" = "$LAST_GAME" ]; then

        # Re-assert CPU freq floor every loop - the critical fix for thermal drops
        enforce_cpu_floor "$PROFILE"

        # Re-lock RR every loop - some ROMs reset it via DisplayManager
        RR_STATUS_PART=""
        if [ "$RR_LOCK" = "game" ] || [ "$RR_LOCK" = "locked" ]; then
            lock_rr "$TARGET_FPS"
            RR_STATUS_PART="rr_locked_ingame"
        fi

        # Re-apply multi-layer FPS cap every loop
        FPS_STATUS_PART=""
        if [ "$FPS_LOCK" != "off" ]; then
            enforce_fps_lock "$FPS_LOCK"
            FPS_STATUS_PART="fps_locked_${FPS_LOCK}"
        fi

        # Bug fix: these two used to each independently `echo > rr_status.txt`,
        # so whichever ran second silently clobbered the other - with both RR
        # lock and in-game FPS lock active (a common combo), the WebUI only
        # ever showed the FPS-lock status and the RR-lock indicator looked
        # like it had turned off, even though lock_rr() was still being
        # re-applied correctly every loop. Combine into one line so both are
        # visible regardless of which is active.
        if [ -n "$RR_STATUS_PART" ] || [ -n "$FPS_STATUS_PART" ]; then
            if [ -n "$RR_STATUS_PART" ] && [ -n "$FPS_STATUS_PART" ]; then
                echo "${RR_STATUS_PART}+${FPS_STATUS_PART}" > "$CORTEX/display/rr_status.txt"
            else
                echo "${RR_STATUS_PART}${FPS_STATUS_PART}" > "$CORTEX/display/rr_status.txt"
            fi
        fi

        # Re-assert COPG-style cpuinfo bind + render scale while the game is up.
        if [ $((LOOP_ITER % 5)) -eq 0 ]; then
            sh "$CORTEX/games/cpuinfo_mount.sh" "$RUNNING_GAME" on 2>/dev/null
            RES_LIVE=$(resolve_scale "$RUNNING_GAME")
            [ "$RES_LIVE" != "native" ] && sh "$CORTEX/display/apply_resolution.sh" "$RES_LIVE" "$RUNNING_GAME" session 2>/dev/null
        fi

        # Every ~10s: re-run kill_bg if it's on.
        if [ "$LOOP_ITER" -ge 10 ]; then
            [ "$KILL_BG" = "on" ] && sh "$CORTEX/games/kill_bg.sh" "$RUNNING_GAME" 2>/dev/null

            # Bypass charging safety watchdog: bypass mode means the phone
            # runs directly off wall power while plugged in - the battery
            # itself isn't being topped up. If the user unplugs while it's
            # still enabled, or the battery was already low when bypass was
            # turned on, it needs to fail safe rather than let the battery
            # keep draining unattended down toward empty. Auto-disable
            # below 15% so charging resumes normally before it becomes a
            # real problem.
            BYPASS_STATE=$(cat "$CORTEX/battery/bypass_state.txt" 2>/dev/null || echo "off")
            if [ "$BYPASS_STATE" = "on" ]; then
                BATT_LEVEL=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null || echo "100")
                if [ "$BATT_LEVEL" -lt 15 ] 2>/dev/null; then
                    sh "$CORTEX/battery/bypass_charge.sh" off 2>/dev/null
                    log_p "Bypass charging auto-disabled - battery at ${BATT_LEVEL}%, resuming normal charging"
                fi
            fi

            LOOP_ITER=0
        fi
        LOOP_ITER=$((LOOP_ITER + 1))

        fi

        sleep 1

    else
        # -- Game backgrounded or exited --------------------------------------─
        if [ -n "$LAST_GAME" ]; then
            # BUG FIX: this used to run the ENTIRE exit sequence - including
            # apply_resolution.sh's force-stop+relaunch to restore native
            # resolution - the very first loop tick (~2s) the game wasn't
            # foreground, with zero distinction between "user actually
            # closed the game" and "user briefly switched to check a
            # notification." Backgrounding a game is completely normal and
            # doesn't mean the user is done with it - but the resolution
            # restore in particular force-stops the process outright, so
            # returning to the game moments later meant Android had to
            # cold-start it from scratch: reloading assets, rebuilding game
            # state, exactly the stutter/lag being reported. is_pkg_foreground()
            # doesn't distinguish "backgrounded" from "closed" - that's a
            # real ambiguity in what's observable from a root shell, not a
            # detection bug - so the right fix is patience: wait multiple
            # consecutive ticks of confirmed non-foreground before treating
            # it as a real exit, not one.
            #
            # pidof-alive is checked each tick during this window specifically
            # so a game that WAS backgrounded and then genuinely force-closed
            # (task swiped away, crashed) still exits promptly rather than
            # waiting out the full debounce for no reason - the debounce is
            # about tolerating brief foreground loss, not about ignoring an
            # actual process death.
            if [ "$BACKGROUND_SINCE" = "0" ]; then
                BACKGROUND_SINCE=$(date +%s)
            fi
            STILL_ALIVE=0
            pidof "$LAST_GAME" >/dev/null 2>&1 && STILL_ALIVE=1

            BG_AGE=$(( $(date +%s) - BACKGROUND_SINCE ))
            # 12s tolerance: long enough to cover checking a notification,
            # replying to a message, glancing at another app - short enough
            # that a genuine "I'm done playing" still releases the boost
            # (and Sweet Dreams' own visible feedback, the exit
            # notification) within a reasonable window, not minutes later.
            if [ "$STILL_ALIVE" = "1" ] && [ "$BG_AGE" -lt 12 ]; then
                # Still within the tolerance window and the process is
                # confirmed alive - keep OOM protection actively
                # re-asserted the same as the continuous protection loop
                # normally does while foreground-confirmed. Without this,
                # a backgrounded-but-not-yet-declared-exited game had a
                # ~12s window where nothing was re-asserting oom_score_adj,
                # right when the user switching to another (possibly
                # memory-hungry) app makes the low-memory killer most
                # likely to act.
                boost_pids "$LAST_GAME"
                sleep 2
                continue
            fi

            # Grace check: if apply_resolution.sh deliberately force-stopped
            # this exact game within the last 8 seconds to make a downscale
            # setting take effect on relaunch (see that script's own header
            # comment - Android's Game Mode API only applies resolution
            # changes at an app's cold start, not to an already-running
            # process), this is an EXPECTED, self-inflicted process death,
            # not the user actually leaving the game. Skip the whole exit
            # sequence (thermal restore, touch restore, net restore,
            # "Boost released" notification) for this one tick so none of
            # that flickers on and back off again before the user even
            # sees their game relaunch. 8s is generous enough to cover the
            # force-stop-to-relaunch window with margin, tight enough that
            # a genuine close shortly after still gets caught normally.
            GRACE_TS=$(cat "$CORTEX/display/resolution_relaunch_grace.txt" 2>/dev/null || echo "0")
            NOW_TS=$(date +%s)
            GRACE_AGE=$((NOW_TS - GRACE_TS))
            if [ "$GRACE_AGE" -lt 20 ] && [ "$(cat "$CORTEX/display/resolution_applied_pkg.txt" 2>/dev/null)" = "$LAST_GAME" ]; then
                sleep 2
                continue
            fi

            BACKGROUND_SINCE=0
            log_p "Game OFF: $LAST_GAME"
            log_s "thermal restore $LAST_GAME"
            sh "$CORTEX/games/cpuinfo_mount.sh" "$LAST_GAME" off 2>/dev/null
            sh "$CORTEX/thermal/apply.sh" game_end 2>/dev/null
            rm -f "$CORTEX/thermal/spoof_c_session.txt"
            sh "$CORTEX/touch/apply.sh" game_end 2>/dev/null
            unlock_rr "$TARGET_FPS"
            release_fps_lock "$TARGET_FPS"
            restore_cpu
            sh "$CORTEX/perf/apply.sh" "" restore 2>/dev/null
            sh "$CORTEX/sensor/apply.sh" restore 2>/dev/null
            sh "$CORTEX/audio/apply.sh" restore 2>/dev/null
            sh "$CORTEX/net/apply.sh" game_end 2>/dev/null
            # Revert resolution downscale unconditionally - guarantees we
            # never leave a scaled resolution active once the game that
            # asked for it is gone. apply_resolution.sh reads its own state
            # file to know which package to reset (see script header); we
            # still pass LAST_GAME as a fallback in case that state file is
            # somehow missing (e.g. module updated mid-session).
            sh "$CORTEX/display/apply_resolution.sh" native "$LAST_GAME" 2>/dev/null
            echo "rr_game_idle" > "$CORTEX/display/rr_status.txt"
            GAME_LABEL_OFF=$(echo "$LAST_GAME" | awk -F. '{print $NF}')
            # Same fix as the launch notification above - backgrounded so a
            # slow/stuck su+Binder notification call can never delay the
            # LAST_GAME="" reset that follows.
            sh "$CORTEX/notify/post.sh" game_exit "Sweet Dreams" \
                "Boost released for ${GAME_LABEL_OFF} - back to ${PROFILE} profile" 2>/dev/null &
            LAST_GAME=""
            : > "$LAST_GAME_FILE"
            LOOP_ITER=0
        fi
        sleep 5
    fi
done
