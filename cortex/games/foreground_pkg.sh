#!/system/bin/sh
# cortex/games/foreground_pkg.sh - Sweet Dreams
# Prints the package name of whatever is currently in the foreground/focused,
# or nothing if it can't be determined. Used by:
#   - the WebUI's "is a selected game actually running (on-screen) right now"
#     banner, as opposed to just "is its process alive somewhere" (a
#     backgrounded/cached process is a very different thing from an open app
#     - see the comment in index.html's updateStats() for why this matters)
#   - scoping immersive/fullscreen mode to whichever app is asking for it
#
# IMPROVED: was previously 2 candidate methods (mResumedActivity, then
# mCurrentFocus/mFocusedApp). AZenith's own foreground detector
# (AppMonitor.kt) tries 7 different ActivityTaskManager methods in sequence
# via Java reflection - getFocusedRootTaskInfo, getTopActivity,
# getRunningTasks, etc - because different Android versions and vendor ROM
# forks expose different subsets of that API surface, and one method
# silently returning null/empty on a given device doesn't mean the activity
# manager itself is broken, just that that specific accessor isn't
# populated on this build. We can't call those hidden methods directly from
# shell the way AZenith's Java daemon does, but `dumpsys` surfaces most of
# the same underlying state through different subcommands, so the same
# multi-candidate philosophy applies: try more sources in sequence rather
# than trusting the first one's silence to mean "no foreground app".
#
# Candidate order, most to least universally reliable in practice:
#   1. dumpsys activity activities | mResumedActivity   (pre-Q and still
#      present on most ROMs as a legacy field even post-Q)
#   2. dumpsys activity activities | topResumedActivity  (Q+ native field,
#      multi-resume-aware - the actual AOSP 10+ replacement for #1)
#   3. dumpsys window | mCurrentFocus / mFocusedApp      (works even when
#      the activity dump is sparse - this is what most existing "get
#      current activity" community references lean on when #1/#2 fail)
#   4. dumpsys window displays | mCurrentFocus / mFocusedApp  (some
#      foldables/multi-display or vendor ROMs only populate the per-display
#      variant, not the flat `dumpsys window` output)
#   5. dumpsys activity top | ACTIVITY line              (last resort -
#      reflects the actual top-of-stack window title bar, slower to dump
#      than the others since it walks the full activity, but catches cases
#      where all four state-based dumps above come back empty)

PKG=$(dumpsys activity activities 2>/dev/null | grep -m1 "mResumedActivity" | grep -oE '[A-Za-z][A-Za-z0-9_.]*/[A-Za-z0-9_.]*' | head -1 | cut -d/ -f1)

if [ -z "$PKG" ]; then
    PKG=$(dumpsys activity activities 2>/dev/null | grep -m1 "topResumedActivity" | grep -oE '[A-Za-z][A-Za-z0-9_.]*/[A-Za-z0-9_.]*' | head -1 | cut -d/ -f1)
fi

if [ -z "$PKG" ]; then
    PKG=$(dumpsys window 2>/dev/null | grep -m1 -E "mCurrentFocus|mFocusedApp" | grep -oE '[A-Za-z][A-Za-z0-9_.]*/[A-Za-z0-9_.]*' | head -1 | cut -d/ -f1)
fi

if [ -z "$PKG" ]; then
    PKG=$(dumpsys window displays 2>/dev/null | grep -m1 -E "mCurrentFocus|mFocusedApp" | grep -oE '[A-Za-z][A-Za-z0-9_.]*/[A-Za-z0-9_.]*' | head -1 | cut -d/ -f1)
fi

if [ -z "$PKG" ]; then
    PKG=$(dumpsys activity top 2>/dev/null | grep -m1 "ACTIVITY" | grep -oE '[A-Za-z][A-Za-z0-9_.]*/[A-Za-z0-9_.]*' | head -1 | cut -d/ -f1)
fi

[ -n "$PKG" ] && echo "$PKG"
