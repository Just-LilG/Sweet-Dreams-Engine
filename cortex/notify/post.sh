#!/system/bin/sh
# cortex/notify/post.sh - Sweet Dreams Notifications
#
# Shared helper for posting status notifications. Replaces the old Frieren
# binaries' approach of impersonating a separate "FrierenAI" product via
# `su 2000 -c 'cmd notification post ...'` with a Shizuku fallback and a
# dependency on an unrelated third-party toast app.
#
# v1.7.0 switched this to calling `cmd notification post` directly as root,
# on the theory that service.sh already runs as root so su shouldn't be
# needed for privilege. That reasoning was wrong: NotificationManagerService's
# shell command path specifically checks for the `shell` uid (2000) and its
# SELinux context (u:r:shell:s0), not just "is this caller privileged enough".
# Being root (uid 0) doesn't automatically satisfy that - root and shell are
# different identities with different SELinux domains, and some shell-command
# paths are gated to the shell identity specifically. Confirmed via Android's
# own documented usage (`su -lp 2000 -c "cmd notification post ..."`) and
# multiple real-world reports of "Permission denied though uid=root" for
# exactly this class of shell command. Reverted to su'ing into uid 2000 -
# that was the actually-correct part of the original technique; the part we
# were right to remove was the fake "FrierenAI" branding and the Shizuku/
# third-party-app fallback, which are still gone.
#
# Usage:
#   post.sh <category> <title> <text>
#
# <category> must match one of cortex/notify/<category>.txt - if that file
# doesn't say "on", or the master switch is off, nothing is posted.

MODDIR="/data/adb/modules/sweet_dreams"
CORTEX="$MODDIR/cortex"
NOTIFY_CFG="$CORTEX/notify"
LOGFILE="$MODDIR/boot.log"

log_notify() { echo "[NOTIFY] $1" >> "$LOGFILE"; }

CATEGORY="$1"
TITLE="$2"
TEXT="$3"

if [ -z "$CATEGORY" ] || [ -z "$TITLE" ]; then
    exit 0
fi

MASTER=$(cat "$NOTIFY_CFG/enabled.txt" 2>/dev/null || echo "on")
if [ "$MASTER" != "on" ]; then
    exit 0
fi

CAT_EN=$(cat "$NOTIFY_CFG/${CATEGORY}.txt" 2>/dev/null || echo "off")
if [ "$CAT_EN" != "on" ]; then
    exit 0
fi

# Each category gets its own notification tag so a new event of the same
# kind replaces the previous one in the shade instead of stacking up.
TAG="SweetDreams_${CATEGORY}"

# Escape single quotes in the title/text since they're embedded inside a
# single-quoted string for the su -c shell.
ESCAPED_TITLE=$(printf '%s' "$TITLE" | sed "s/'/'\\\\''/g")
ESCAPED_TEXT=$(printf '%s' "$TEXT"  | sed "s/'/'\\\\''/g")

OUT=$(su 2000 -c "cmd notification post -S bigtext -t '${ESCAPED_TITLE}' '${TAG}' '${ESCAPED_TEXT}'" 2>&1)
RC=$?
if [ "$RC" -eq 0 ]; then
    log_notify "Posted [$CATEGORY]: $TITLE - $TEXT"
else
    log_notify "FAILED [$CATEGORY] (exit $RC): $OUT"
fi
