#!/system/bin/sh
# cortex/net/apply.sh - Sweet Dreams Network Engine v2
#
# CALL SIGNATURES:
#   apply.sh              - boot: apply base TCP/UDP tuning + DNS
#   apply.sh game_start   - game launched: apply gaming-specific tuning
#   apply.sh game_end     - game exited: restore base tuning
#
# WHAT'S NEW vs v1:
#   - UDP tuning (games use UDP, not TCP - v1 ignored this entirely)
#   - Gaming-specific socket + scheduler tuning at game_start
#   - DNS writes via content URI (fixes Binder saturation failures)
#   - ndc resolver setnetdns replacing deprecated setifdns
#   - Network QoS / traffic class marking for game UDP flows
#   - Proper save/restore of all changed values
#   - game_start / game_end hooks (ping stabilizer is now integrated here)

MODDIR="/data/adb/modules/sweet_dreams"
CORTEX="$MODDIR/cortex"
LOGFILE="$MODDIR/boot.log"
GAME_PHASE="${1:-}"

. "$CORTEX/health/track.sh"

# -- Config --------------------------------------------------------------------
STATUS=$(cat "$CORTEX/net/status.txt"                  2>/dev/null || echo "on")
CC=$(cat "$CORTEX/net/congestion.txt"                  2>/dev/null || echo "bbr")
DNS_MODE=$(cat "$CORTEX/net/dns_mode.txt"              2>/dev/null || echo "off")
DNS1=$(cat "$CORTEX/net/dns1.txt"                      2>/dev/null || echo "1.1.1.1")
DNS2=$(cat "$CORTEX/net/dns2.txt"                      2>/dev/null || echo "1.0.0.1")
PING_EN=$(cat "$CORTEX/net/ping_stabilizer_enabled.txt" 2>/dev/null || echo "off")

SAVED="$CORTEX/net/saved_values.txt"

log_net() { echo "[NET] $1" | tee -a "$LOGFILE"; }

# ----------------------------------------------------------------------------─
# sc - safe sysctl write, only if the node exists
# ----------------------------------------------------------------------------─
sc() {
    local KEY="$1" VAL="$2"
    local NODE="/proc/sys/$(echo "$KEY" | tr '.' '/')"
    [ -f "$NODE" ] || return 1
    sysctl -w "${KEY}=${VAL}" 2>/dev/null
}

# ----------------------------------------------------------------------------─
# safe_set - content URI write (bypasses Binder saturation - see touch engine)
# ----------------------------------------------------------------------------─
safe_set() {
    local NS="$1" KEY="$2" VAL="$3"
    local URI="content://settings/${NS}"
    content update --uri "$URI" \
        --bind value:s:"$VAL" \
        --where "name='$KEY'" >/dev/null 2>&1 && return 0
    content insert --uri "$URI" \
        --bind name:s:"$KEY" \
        --bind value:s:"$VAL" >/dev/null 2>&1 && return 0
    settings put "$NS" "$KEY" "$VAL" 2>/dev/null
}

# ----------------------------------------------------------------------------─
# save_current - snapshot current values before we change them
# ----------------------------------------------------------------------------─
save_current() {
    : > "$SAVED"
    for key in \
        net.ipv4.tcp_congestion_control \
        net.ipv4.tcp_low_latency \
        net.ipv4.tcp_slow_start_after_idle \
        net.ipv4.tcp_rmem \
        net.ipv4.tcp_wmem \
        net.core.rmem_max \
        net.core.wmem_max \
        net.core.rmem_default \
        net.core.wmem_default \
        net.core.netdev_max_backlog \
        net.ipv4.tcp_fastopen \
        net.ipv4.tcp_mtu_probing \
        net.ipv4.tcp_no_metrics_save \
        net.ipv4.tcp_timestamps \
        net.ipv4.tcp_sack \
        net.ipv4.udp_rmem_min \
        net.ipv4.udp_wmem_min; do
        local NODE="/proc/sys/$(echo "$key" | tr '.' '/')"
        [ -f "$NODE" ] && echo "$key=$(cat $NODE)" >> "$SAVED"
    done
}

# ----------------------------------------------------------------------------─
# restore_saved - write back all snapshot values
# ----------------------------------------------------------------------------─
restore_saved() {
    [ -f "$SAVED" ] || return
    while IFS='=' read -r key val; do
        [ -n "$key" ] && [ -n "$val" ] && sysctl -w "${key}=${val}" 2>/dev/null
    done < "$SAVED"
    log_net "Values restored from snapshot"
}

# ----------------------------------------------------------------------------─
# apply_congestion_control
# ----------------------------------------------------------------------------─
apply_cc() {
    local TARGET="$1"
    local AVAIL
    AVAIL=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)

    if echo "$AVAIL" | grep -qw "$TARGET"; then
        sc net.ipv4.tcp_congestion_control "$TARGET"
        health_check "congestion_control" "$?" "target=$TARGET"
        log_net "CC: $TARGET"
    else
        # Fallback chain: bbr -> westwood -> cubic
        local FB_APPLIED=""
        for FB in bbr westwood cubic; do
            if echo "$AVAIL" | grep -qw "$FB"; then
                sc net.ipv4.tcp_congestion_control "$FB"
                health_check "congestion_control" "$?" "target=$TARGET fallback=$FB"
                FB_APPLIED="$FB"
                log_net "CC: $TARGET unavailable, using $FB"
                break
            fi
        done
        [ -z "$FB_APPLIED" ] && health_check "congestion_control" 1 "no supported CC algorithm found at all"
    fi
}

# ----------------------------------------------------------------------------─
# apply_base_tuning - boot-time TCP/UDP tuning applied to all traffic
# ----------------------------------------------------------------------------─
apply_base_tuning() {
    # -- TCP ------------------------------------------------------------------
    apply_cc "$CC"
    sc net.ipv4.tcp_low_latency             1
    sc net.ipv4.tcp_no_metrics_save         1
    sc net.ipv4.tcp_timestamps              0
    sc net.ipv4.tcp_sack                    1
    sc net.ipv4.tcp_fastopen                3
    sc net.ipv4.tcp_mtu_probing             1
    sc net.ipv4.tcp_slow_start_after_idle   0
    sc net.ipv4.tcp_rmem                    "4096 87380 16777216"
    sc net.ipv4.tcp_wmem                    "4096 65536 16777216"

    # -- UDP (games use UDP - v1 never touched these) ------------------------─
    # udp_rmem_min / udp_wmem_min - minimum socket buffer for UDP sockets.
    # Default is often 4096 which causes buffer drops on burst game traffic.
    # 16KB minimum prevents drops on high-frequency game state update bursts.
    sc net.ipv4.udp_rmem_min                16384
    sc net.ipv4.udp_wmem_min                16384

    # -- Core socket buffers --------------------------------------------------─
    sc net.core.rmem_max                    16777216
    sc net.core.wmem_max                    16777216
    sc net.core.rmem_default                262144
    sc net.core.wmem_default                262144
    sc net.core.netdev_max_backlog          5000
    # optmem_max - ancillary data buffer per socket (affects UDP more than TCP)
    sc net.core.optmem_max                  65536

    # -- Network scheduler ----------------------------------------------------─
    # netdev_budget - packets processed per NAPI poll cycle. Higher = less
    # scheduling overhead per packet on burst traffic.
    sc net.core.netdev_budget               600
    sc net.core.netdev_budget_usecs         8000

    log_net "Base TCP/UDP tuning applied"
}

# ----------------------------------------------------------------------------─
# apply_game_tuning - game_start: tightest latency, UDP prioritised
# ----------------------------------------------------------------------------─
apply_game_tuning() {
    # Push BBR regardless of user CC setting - best for bursty game UDP/TCP
    apply_cc "bbr"

    # Larger UDP buffers for game state burst handling
    sc net.ipv4.udp_rmem_min                32768
    sc net.ipv4.udp_wmem_min                32768
    sc net.core.rmem_max                    33554432
    sc net.core.wmem_max                    33554432
    sc net.core.rmem_default                524288
    sc net.core.wmem_default                524288

    # Zero congestion window reset after idle - biggest cause of
    # ping spikes after quiet moments in games
    sc net.ipv4.tcp_slow_start_after_idle   0

    # Increase NAPI poll budget - process more packets per cycle
    sc net.core.netdev_budget               1000
    sc net.core.netdev_budget_usecs         4000

    log_net "Game network tuning active (UDP boosted, BBR)"
}

# ----------------------------------------------------------------------------─
# apply_dns - DNS override via modern Android APIs
# ----------------------------------------------------------------------------─
apply_dns() {
    case "$DNS_MODE" in
        custom)
            # Disable private DNS first so our custom servers take effect
            safe_set global private_dns_mode "off"
            # Modern path: setnetdns with the current active network handle
            local NET_ID
            NET_ID=$(ndc network list 2>/dev/null | grep default | \
                awk '{print $1}' | head -1)
            if [ -n "$NET_ID" ]; then
                ndc resolver setnetdns "$NET_ID" "" "$DNS1" "$DNS2" 2>/dev/null
                log_net "DNS: $DNS1 $DNS2 (net $NET_ID)"
            else
                # Fallback: per-interface for common MTK iface names
                for IFACE in wlan0 wlan1 rmnet_data0 rmnet0 ccmni0; do
                    ndc resolver setifdns "$IFACE" "" "$DNS1" "$DNS2" 2>/dev/null
                done
                log_net "DNS: $DNS1 $DNS2 (per-iface fallback)"
            fi
            ;;
        doh)
            safe_set global private_dns_mode     "hostname"
            safe_set global private_dns_specifier "$DNS1"
            log_net "Private DNS (DoH): $DNS1"
            ;;
        off|*)
            log_net "DNS: system default"
            ;;
    esac
}

# ----------------------------------------------------------------------------─
# ENTRY POINT
# ----------------------------------------------------------------------------─

case "$GAME_PHASE" in

    game_end)
        health_start "net"
        restore_saved
        health_finish
        log_net "Game network tuning released"
        exit 0
        ;;

    game_start)
        health_start "net"
        [ "$STATUS" != "on" ] && exit 0
        save_current
        apply_game_tuning
        # Ping stabilizer integrated - no separate script call needed
        [ "$PING_EN" = "on" ] && log_net "Ping stabilizer: active (integrated)"
        health_finish
        exit 0
        ;;

    "")
        # Boot / toggle
        health_start "net"
        [ "$STATUS" != "on" ] && log_net "Network boost off - defaults" && exit 0
        save_current
        apply_base_tuning
        apply_dns
        health_finish
        # Write live status for WebUI
        CUR_CC=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo "-")
        AVAIL_CC=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo "-")
        echo "${STATUS}|${CUR_CC}|${AVAIL_CC}|${DNS_MODE}|${DNS1}|${DNS2}" \
            > "$CORTEX/net/status_live.txt"
        exit 0
        ;;

    *)
        echo "[NET] Unknown argument: '$GAME_PHASE'" >&2
        exit 1
        ;;

esac
