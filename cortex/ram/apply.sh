#!/system/bin/sh
# cortex/ram/apply.sh - Sweet Dreams RAM Management
# Handles ZRAM setup, VM kernel tuning, and LMK configuration
CORTEX="/data/adb/modules/sweet_dreams/cortex"
RAM_CFG="$CORTEX/ram"

MODE=$(cat "$RAM_CFG/mode.txt" 2>/dev/null || echo "balanced")
ZRAM_EN=$(cat "$RAM_CFG/zram_enabled.txt" 2>/dev/null || echo "on")
ZRAM_SIZE=$(cat "$RAM_CFG/zram_size.txt" 2>/dev/null || echo "2")
COMP=$(cat "$RAM_CFG/compressor.txt" 2>/dev/null || echo "lz4")

# -- Detect total physical RAM --------------------------------------------------
TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_MB=$((TOTAL_KB / 1024))

log_ram() { echo "[RAM] $1"; }

# -- ZRAM setup ----------------------------------------------------------------─
setup_zram() {
    local SIZE_GB="$1"
    local SIZE_BYTES=$((SIZE_GB * 1024 * 1024 * 1024))

    # Find the zram block device
    local ZRAM_DEV=""
    [ -b /dev/block/zram0 ] && ZRAM_DEV="/dev/block/zram0"
    [ -b /dev/zram0       ] && ZRAM_DEV="/dev/zram0"
    [ -z "$ZRAM_DEV" ] && { log_ram "No zram device found"; return 1; }

    # -- Check if vold/init already owns this zram as active swap --------------
    # Stock Android fstab often has zram with swapAvailable, managed by vold
    # at boot. If it's already active with a DIFFERENT size than requested,
    # our swapon will fail (EBUSY) after our mkswap rewrites its header -
    # which is exactly the symptom: mkswap succeeds (fresh UUID), swapon fails.
    local ALREADY_ON=$(grep -c "$ZRAM_DEV" /proc/swaps 2>/dev/null)
    local CUR_DISKSIZE_BYTES=$(cat /sys/block/zram0/disksize 2>/dev/null || echo 0)
    local CUR_DISKSIZE_GB=$((CUR_DISKSIZE_BYTES / 1024 / 1024 / 1024))

    if [ "$ALREADY_ON" -gt 0 ] 2>/dev/null; then
        if [ "$CUR_DISKSIZE_GB" = "$SIZE_GB" ]; then
            log_ram "ZRAM already active at requested ${SIZE_GB}GB (vold-managed) - leaving as-is"
            return 0
        else
            log_ram "ZRAM active under vold at ${CUR_DISKSIZE_GB}GB, requested ${SIZE_GB}GB - resize requires reboot (vold owns the swap lifecycle on this firmware)"
            return 0
        fi
    fi

    # Not currently active - safe to take over and configure ourselves
    swapoff /dev/block/zram0 2>/dev/null
    swapoff /dev/zram0       2>/dev/null

    # Set compressor - try preferred, fall back
    for algo in "$COMP" lz4 lzo; do
        if echo "$algo" > /sys/block/zram0/comp_algorithm 2>/dev/null; then
            log_ram "Compressor: $algo"; break
        fi
    done

    # Reset and resize
    echo "1" > /sys/block/zram0/reset 2>/dev/null
    sleep 0.5
    if ! echo "$SIZE_BYTES" > /sys/block/zram0/disksize 2>/dev/null; then
        log_ram "ZRAM resize failed - disksize node rejected write (check SELinux context)"
        return 1
    fi

    # Format and enable - diagnose each step instead of silently chaining
    if ! mkswap "$ZRAM_DEV" 2>"$RAM_CFG/.mkswap_err"; then
        log_ram "ZRAM mkswap failed: $(cat "$RAM_CFG/.mkswap_err" 2>/dev/null)"
        rm -f "$RAM_CFG/.mkswap_err"
        return 1
    fi
    rm -f "$RAM_CFG/.mkswap_err"

    if ! swapon -p 100 "$ZRAM_DEV" 2>"$RAM_CFG/.swapon_err"; then
        log_ram "ZRAM swapon failed: $(cat "$RAM_CFG/.swapon_err" 2>/dev/null || echo 'unknown - likely EBUSY from vold ownership')"
        rm -f "$RAM_CFG/.swapon_err"
        return 1
    fi
    rm -f "$RAM_CFG/.swapon_err"

    log_ram "ZRAM ${SIZE_GB}GB active on $ZRAM_DEV"
}

# -- VM kernel parameters per mode --------------------------------------------─
apply_vm_mode() {
    local M="$1"
    case "$M" in
        gaming)
            # Prioritise keeping game in RAM - very low swappiness
            # Low dirty ratios = frequent flushes = less stall on game exit
            # High vfs_cache_pressure = free dentry/inode cache fast when RAM needed
            sysctl -w vm.swappiness=10                   2>/dev/null
            sysctl -w vm.vfs_cache_pressure=150          2>/dev/null
            sysctl -w vm.dirty_ratio=5                   2>/dev/null
            sysctl -w vm.dirty_background_ratio=2        2>/dev/null
            sysctl -w vm.page-cluster=0                  2>/dev/null
            sysctl -w vm.min_free_kbytes=32768           2>/dev/null
            sysctl -w vm.extra_free_kbytes=16384         2>/dev/null
            sysctl -w vm.watermark_scale_factor=200      2>/dev/null
            sysctl -w vm.stat_interval=10                2>/dev/null
            ;;
        balanced)
            sysctl -w vm.swappiness=60                   2>/dev/null
            sysctl -w vm.vfs_cache_pressure=100          2>/dev/null
            sysctl -w vm.dirty_ratio=10                  2>/dev/null
            sysctl -w vm.dirty_background_ratio=5        2>/dev/null
            sysctl -w vm.page-cluster=1                  2>/dev/null
            sysctl -w vm.min_free_kbytes=16384           2>/dev/null
            sysctl -w vm.extra_free_kbytes=8192          2>/dev/null
            sysctl -w vm.watermark_scale_factor=150      2>/dev/null
            sysctl -w vm.stat_interval=5                 2>/dev/null
            ;;
        memory_saver)
            # Aggressively reclaim - maximum effective RAM via compression
            sysctl -w vm.swappiness=120                  2>/dev/null
            sysctl -w vm.vfs_cache_pressure=200          2>/dev/null
            sysctl -w vm.dirty_ratio=20                  2>/dev/null
            sysctl -w vm.dirty_background_ratio=10       2>/dev/null
            sysctl -w vm.page-cluster=2                  2>/dev/null
            sysctl -w vm.min_free_kbytes=8192            2>/dev/null
            sysctl -w vm.extra_free_kbytes=4096          2>/dev/null
            sysctl -w vm.watermark_scale_factor=125      2>/dev/null
            sysctl -w vm.stat_interval=1                 2>/dev/null
            ;;
    esac
    log_ram "VM tuned: $M"
}

# -- LMKD tuning (Android Low Memory Killer Daemon) ----------------------------
tune_lmkd() {
    local M="$1"
    # lmkd uses /sys/module/lowmemorykiller or properties on Android 13
    case "$M" in
        gaming)
            # Kill background apps more aggressively to protect game
            resetprop ro.lmk.low 1001              2>/dev/null
            resetprop ro.lmk.medium 800            2>/dev/null
            resetprop ro.lmk.critical 0            2>/dev/null
            resetprop ro.lmk.critical_upgrade true 2>/dev/null
            resetprop ro.lmk.upgrade_pressure 40   2>/dev/null
            resetprop ro.lmk.downgrade_pressure 60 2>/dev/null
            resetprop ro.lmk.kill_heaviest_task true 2>/dev/null
            resetprop ro.lmk.kill_timeout_ms 100  2>/dev/null
            ;;
        balanced)
            resetprop ro.lmk.low 1001              2>/dev/null
            resetprop ro.lmk.medium 700            2>/dev/null
            resetprop ro.lmk.critical 0            2>/dev/null
            resetprop ro.lmk.kill_heaviest_task true 2>/dev/null
            resetprop ro.lmk.kill_timeout_ms 100  2>/dev/null
            ;;
        memory_saver)
            # Most aggressive - kill early to keep RAM free
            resetprop ro.lmk.low 1001              2>/dev/null
            resetprop ro.lmk.medium 900            2>/dev/null
            resetprop ro.lmk.critical 0            2>/dev/null
            resetprop ro.lmk.critical_upgrade true 2>/dev/null
            resetprop ro.lmk.upgrade_pressure 20   2>/dev/null
            resetprop ro.lmk.downgrade_pressure 80 2>/dev/null
            resetprop ro.lmk.kill_heaviest_task true 2>/dev/null
            resetprop ro.lmk.kill_timeout_ms 50   2>/dev/null
            ;;
    esac
    log_ram "LMKD tuned: $M"
}

# -- Drop caches (safe - only page/slab cache, not needed data) ----------------
drop_caches() {
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    log_ram "Caches dropped"
}

# -- Main ----------------------------------------------------------------------─
log_ram "Total RAM: ${TOTAL_MB}MB | Mode: $MODE | ZRAM: $ZRAM_EN ${ZRAM_SIZE}GB | Comp: $COMP"

# Set up ZRAM
if [ "$ZRAM_EN" = "on" ]; then
    setup_zram "$ZRAM_SIZE"
else
    swapoff /dev/block/zram0 2>/dev/null
    swapoff /dev/zram0       2>/dev/null
    log_ram "ZRAM disabled"
fi

# Apply VM tuning
apply_vm_mode "$MODE"

# Tune LMKD
tune_lmkd "$MODE"

# Initial cache drop
drop_caches

# Write status file for WebUI
FREE_KB=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
FREE_MB=$((FREE_KB / 1024))
# /proc/swaps reports Used in KB already, not 4KB pages - the old *4 here
# overstated ZRAM usage 4x in the WebUI RAM gauge (same bug as the RAM
# watchdog in service.sh).
SWAP_USED=$(grep -i "zram" /proc/swaps 2>/dev/null | awk '{print $4}')
SWAP_USED_MB=$(( (${SWAP_USED:-0}) / 1024 ))
echo "${MODE}|${TOTAL_MB}|${FREE_MB}|${ZRAM_EN}|${ZRAM_SIZE}|${COMP}|${SWAP_USED_MB}" > "$RAM_CFG/status.txt"
log_ram "RAM management applied OK"
