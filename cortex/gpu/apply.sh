#!/system/bin/sh
CORTEX="/data/adb/modules/sweet_dreams/cortex"
PROFILE=$(cat "$CORTEX/cpu/profile.txt" 2>/dev/null || echo "gaming")

# Mali-G57 MC2 (Valhall) valid governors:
# performance, simple_ondemand, mali_ondemand, coarse_demand, userspace
# "simple_ondemand" exists on some MTK kernels, "mali_ondemand" on others.
# Try each in priority order - the kernel ignores unknown governors silently.
set_gov() {
    local GOV="$1"
    local HIT=1
    for p in \
        /sys/class/misc/mali0/device/devfreq/mali0/governor \
        /sys/class/misc/mali0/device/devfreq/*/governor \
        /sys/kernel/gpu/gpu_governor \
        /sys/class/devfreq/gpufreq/governor \
        /sys/devices/platform/mali.0/devfreq/mali.0/governor; do
        # Bug fix: this used to be `[ -f "$p" ] && echo "$GOV" > "$p"` with no
        # tracked outcome, so the function's exit status was whatever the
        # LAST glob candidate's `[ -f ]` test happened to return - usually
        # false, since most devices only match one of these five paths.
        # That made every `set_gov X || set_gov Y || set_gov Z` chain below
        # always run every fallback regardless of an earlier success, with
        # the LAST one applied silently winning - the exact opposite of the
        # "try in priority order, stop at first success" the chain intends.
        # Now HIT is set only on an actual successful write, and set_gov
        # returns 0 the moment one occurs.
        if [ -f "$p" ] && echo "$GOV" > "$p" 2>/dev/null; then
            HIT=0
            # Bug fix: this loop used to keep iterating through every
            # remaining path candidate even after a successful write -
            # HIT was set correctly, but nothing actually stopped the
            # loop, so on a device where two of these five paths both
            # exist (e.g. a real path plus its own glob match), the
            # governor got written twice redundantly every call. Harmless
            # in practice (idempotent, same value both times) but didn't
            # match "stop at first success" as documented above - this
            # break makes the behavior match the comment.
            break
        fi
    done
    return "$HIT"
}

case "$PROFILE" in
    gaming)
        set_gov "performance"
        ;;
    balanced)
        # Try mali_ondemand first (G57 native), fall back to simple_ondemand
        set_gov "mali_ondemand" || set_gov "simple_ondemand" || set_gov "coarse_demand"
        ;;
    battery)
        set_gov "powersave" || set_gov "simple_ondemand"
        ;;
    *)
        set_gov "mali_ondemand" || set_gov "simple_ondemand"
        ;;
esac
