#!/system/bin/sh
# ping_stabilizer.sh - reduces latency spikes during a game session.
# Real sysctl-level tuning only; every write is existence-checked since not
# every kernel exposes every knob, and it self-reports what actually applied
# so the UI can show honest status instead of a blind "on".
CORTEX="/data/adb/modules/sweet_dreams/cortex"
STATUS="$CORTEX/net/ping_status.txt"
SAVED="$CORTEX/net/ping_saved.txt"
ACTION="${1:-boost}"

sc() { [ -f "$1" ] && cat "$1" 2>/dev/null; }
set_if_exists() {
    # $1 = sysctl path, $2 = value
    if [ -f "$1" ]; then
        echo "$2" > "$1" 2>/dev/null && return 0
    fi
    return 1
}

APPLIED=0
ATTEMPTED=0

if [ "$ACTION" = "boost" ]; then
    # Save current values once so restore is exact, not guessed.
    : > "$SAVED"
    for p in /proc/sys/net/ipv4/tcp_low_latency \
             /proc/sys/net/ipv4/tcp_slow_start_after_idle \
             /proc/sys/net/ipv4/tcp_congestion_control; do
        [ -f "$p" ] && echo "$p=$(sc "$p")" >> "$SAVED"
    done

    # Low-latency mode: prioritize latency over throughput for TCP.
    ATTEMPTED=$((ATTEMPTED + 1))
    set_if_exists /proc/sys/net/ipv4/tcp_low_latency 1 && APPLIED=$((APPLIED + 1))

    # Don't reset the congestion window after idle - the single biggest
    # cause of "ping spikes after a quiet moment" in bursty game traffic
    # (walk around doing nothing, then a firefight generates a burst).
    ATTEMPTED=$((ATTEMPTED + 1))
    set_if_exists /proc/sys/net/ipv4/tcp_slow_start_after_idle 0 && APPLIED=$((APPLIED + 1))

    # BBR reacts to real latency/loss signals rather than pure loss-based
    # algorithms (cubic) that only back off after a packet's already gone
    # missing - better for keeping ping steady on flaky mobile networks.
    ATTEMPTED=$((ATTEMPTED + 1))
    if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        set_if_exists /proc/sys/net/ipv4/tcp_congestion_control bbr && APPLIED=$((APPLIED + 1))
    fi

    echo "boosted|${APPLIED}|${ATTEMPTED}|$(date +%s)" > "$STATUS"
else
    if [ -f "$SAVED" ]; then
        while IFS='=' read -r path val; do
            [ -n "$path" ] && [ -n "$val" ] && echo "$val" > "$path" 2>/dev/null
        done < "$SAVED"
    fi
    echo "idle|0|0|$(date +%s)" > "$STATUS"
fi
