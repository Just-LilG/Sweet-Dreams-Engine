#!/system/bin/sh
# kill_bg.sh - Sweet Dreams
# Forcibly closes every other app so the game is the only thing running.
#
# THE BUG THIS FIXES: the previous version used `am kill`. `am kill` is
# Android's *gentle* memory-trim call - ActivityManager explicitly refuses to
# kill anything that currently holds a foreground service, a visible/recent
# activity, or a process the system doesn't consider safely "cached". In
# practice this meant it silently no-op'd for most apps people actually
# wanted closed (chat apps with a notification service running, music apps,
# anything recently switched away from) - the call succeeds, logs nothing,
# and the app just... doesn't close. `am force-stop` is the same primitive
# Settings > App Info > Force Stop uses: it unconditionally kills every
# process for that package and cancels its alarms/services, regardless of
# state. That's what "only the game should run" actually requires.
GAME_PKG="$1"
CORTEX="/data/adb/modules/sweet_dreams/cortex"
LOGFILE="/data/adb/modules/sweet_dreams/boot.log"
WHITELIST="$CORTEX/games/kill_bg_whitelist.txt"

log_k() { echo "[$(date '+%H:%M:%S')] [KILL_BG] $1" >> "$LOGFILE"; }

# Core system / launcher / IME / connectivity packages that must never be
# force-stopped - killing these can black-screen the device or drop the
# ability to get back to the home screen.
HARDCODED_SAFE="
com.android.systemui
com.google.android.gms
com.google.android.gsf
com.android.phone
com.android.dialer
com.android.inputmethod.latin
com.google.android.inputmethod.latin
com.samsung.android.honeyboard
com.touchtype.swiftkey
com.android.vending
com.google.android.gmscore
com.mediatek.gba
com.mediatek.ims
com.android.server.telecom
com.android.providers.telephony
com.android.providers.settings
com.android.providers.contacts
com.android.settings
android
com.android.bluetooth
com.transsion.hilauncher
com.itel.launcher
com.infinix.launcher
"

is_safe() {
    PKG="$1"
    [ "$PKG" = "$GAME_PKG" ] && return 0
    echo "$HARDCODED_SAFE" | grep -qxF "$PKG" && return 0
    [ -f "$WHITELIST" ] && grep -qxF "$PKG" "$WHITELIST" && return 0
    [ "$PKG" = "$DEFAULT_LAUNCHER" ] && [ -n "$DEFAULT_LAUNCHER" ] && return 0
    [ "$PKG" = "$DEFAULT_IME" ] && [ -n "$DEFAULT_IME" ] && return 0
    [ "$PKG" = "$DEFAULT_WALLPAPER" ] && [ -n "$DEFAULT_WALLPAPER" ] && return 0
    return 1
}

# IMPROVED: the hardcoded safe-list above only covers launchers/IMEs known
# at the time this script was written - any third-party launcher or
# keyboard app not on that exact list (a user's custom launcher, a keyboard
# app that isn't Gboard/SwiftKey/Samsung's) was fair game to get
# force-stopped. Note this is scoped to third-party risk specifically:
# `pm list packages -3` below already excludes every OEM/system package by
# definition, so this was never a risk of killing core Android - it was a
# risk of killing whatever launcher/keyboard the USER actually chose to
# install, which the static list can't know about in advance.
#
# `cmd package resolve-activity` for the HOME intent reveals the actual
# current default launcher regardless of what it's called; the current
# default IME is a direct settings read (Android maintains this as a
# single source of truth, no ambiguity). Both are resolved once per
# kill_bg run - cheap, and correctness matters more than a handful of ms
# here since force-stopping the active launcher/keyboard has real UX cost.
#
# `cmd package resolve-activity` goes through the same `cmd` service
# dispatcher this whole module has already found to be unreliable on some
# devices (see device/evaluate_mitigations.sh). If it comes back empty,
# fall back to reading it directly from PackageManager's own persisted
# preferred-activity XML - a different code path entirely, no `cmd`
# dispatcher involved, just a straight file read of state Android already
# maintains on disk.
DEFAULT_LAUNCHER=$(cmd package resolve-activity --brief -c android.intent.category.HOME 2>/dev/null | tail -n 1 | cut -d/ -f1)
if [ -z "$DEFAULT_LAUNCHER" ]; then
    DEFAULT_LAUNCHER=$(grep -A1 'android.intent.category.HOME' \
        /data/system/packages.xml 2>/dev/null \
        | grep -oE 'name="[a-zA-Z0-9_.]+/' \
        | head -1 \
        | cut -d'"' -f2 | cut -d/ -f1)
fi
DEFAULT_IME=$(settings get secure default_input_method 2>/dev/null | cut -d/ -f1)

# BUG FIX: force-stopping a third-party live wallpaper engine or theme
# service was resetting the wallpaper to default and, on at least one
# report, also disabling rotation lock - most likely because that same
# app's process also hosts a settings-observer or accessibility-adjacent
# component whose sudden death left Android in an inconsistent state for
# THAT specific setting until something else re-wrote it. `pm list
# packages -3` already excludes true system packages, but on OEM skins
# like Transsion's XOS the wallpaper/theme engine is frequently shipped as
# an ordinary installable APK rather than baked into /system - meaning it
# was previously fair game to force-stop like any other third-party app
# with no protection at all.
#
# `dumpsys wallpaper` reports the actual currently-active wallpaper
# component if a LIVE wallpaper is set (static/image wallpapers have no
# running process to protect, so this naturally no-ops for those - nothing
# extra needed there since there's no service to kill in the first place).
DEFAULT_WALLPAPER=$(dumpsys wallpaper 2>/dev/null | grep -m1 "Wallpaper.*component" | grep -oE '[a-zA-Z0-9_.]+/[a-zA-Z0-9_.]+' | head -1 | cut -d/ -f1)

if [ -z "$GAME_PKG" ]; then
    log_k "ERROR: no game package passed, aborting"
    exit 1
fi

KILLED=0
SKIPPED=0
for pkg in $(pm list packages -3 2>/dev/null | cut -d: -f2); do
    if is_safe "$pkg"; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi
    # Only worth logging/counting apps that were actually alive - force-stop
    # is harmless to call on an already-dead package, but no point claiming
    # credit for "killing" something that wasn't running.
    if pidof "$pkg" >/dev/null 2>&1; then
        # Bug fix: `am force-stop` is a real, correct primitive semantically
        # (unlike `am kill`) - but it's STILL routed through the same `cmd`
        # dispatcher IPC path that this whole device has confirmed blocked
        # by SELinux (see fps/engine.sh's header comment for the full
        # story - every `cmd`/`am`/`wm`/`settings` call on this specific
        # phone fails with "Failed transaction (2147483646)", verified via
        # `getenforce` returning Enforcing). Skip the doomed attempt
        # entirely once cortex/device/evaluate_mitigations.sh has confirmed
        # it, rather than always trying it and always eating the failure.
        # `kill -9` is a raw POSIX signal, not an IPC call at all - it
        # doesn't go anywhere near the cmd dispatcher, so it isn't subject
        # to the same restriction, and is what's actually guaranteed to
        # work on this device either way.
        if ! grep -qx "CMD_DISPATCHER_UNRELIABLE" "$CORTEX/device/active.txt" 2>/dev/null; then
            am force-stop "$pkg" >/dev/null 2>&1
        fi
        for PID in $(pidof "$pkg" 2>/dev/null); do
            kill -9 "$PID" 2>/dev/null
        done
        KILLED=$((KILLED + 1))
    fi
done

echo "${GAME_PKG}|${KILLED}|${SKIPPED}" > "$CORTEX/games/kill_bg_last.txt" 2>/dev/null
log_k "Force-stopped ${KILLED} app(s), ${SKIPPED} whitelisted/skipped - only ${GAME_PKG} left running"
