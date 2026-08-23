#!/system/bin/sh
MODDIR="/data/adb/modules/sweet_dreams"
CORTEX="$MODDIR/cortex"

# -- Kill all module daemons ----------------------------------------------------
pkill -f "$MODDIR/controller"              2>/dev/null
pkill -f "$CORTEX/ai/engine.sh"            2>/dev/null
pkill -f "$CORTEX/daemons/game_monitor.sh" 2>/dev/null
sleep 1

# -- Remove the standalone-spoof COPG folder ----------------------------------─
# Sweet Dreams creates /data/adb/modules/COPG/ itself at install time (see
# customize.sh) so the bundled Zygisk .so has a valid target from boot 1,
# without the user separately installing a COPG module. Since Sweet Dreams
# owns the full lifecycle of that folder, it's removed here on uninstall too
# - otherwise it would silently survive as an orphaned "phantom module"
# folder that Magisk/KernelSU would keep loading Zygisk hooks from forever,
# with no UI anywhere to know it's there or why. rm -rf is safe here
# specifically because Sweet Dreams is the sole creator/owner of this exact
# path - this is NOT run if the user had separately, deliberately installed
# their own actual COPG module (that install would use Magisk's own module
# management, live at the same path, and get correctly removed by ITS OWN
# uninstall.sh through Magisk's normal module removal flow, not this one).
# The only way to accidentally hit that case is installing COPG standalone
# AFTER Sweet Dreams already created this folder, which would leave COPG's
# own files sitting on top of Sweet Dreams' seed - a rare edge case, but
# checked for below rather than blindly nuked.
COPG_DIR="/data/adb/modules/COPG"
if [ -d "$COPG_DIR" ]; then
    # If a real, separately-installed COPG module is present, it will have
    # its own module.prop with id=COPG written by Magisk's module manager
    # at ITS OWN install time - Sweet Dreams never writes that file into
    # this folder. Its absence means this folder only ever contained Sweet
    # Dreams' own seeded copy, safe to remove in full.
    if [ ! -f "$COPG_DIR/module.prop" ]; then
        rm -rf "$COPG_DIR" 2>/dev/null
    fi
    # If module.prop DOES exist, a real COPG install is present - leave it
    # alone entirely and let Magisk's own removal flow handle it.
fi

# -- Flush iptables rules (both IPv4 and IPv6) --------------------------------─
# Remove ALL lgtl net-block rules regardless of which UID was blocked
iptables-save 2>/dev/null | grep -- "--uid-owner" | while read rule; do
    iptables ${rule#-A } 2>/dev/null || true
    iptables -D ${rule#-A } 2>/dev/null || true
done
ip6tables-save 2>/dev/null | grep -- "--uid-owner" | while read rule; do
    ip6tables -D ${rule#-A } 2>/dev/null || true
done

# -- Restore battery charge limit to unrestricted ------------------------------
sh "$CORTEX/battery/bypass_charge.sh" off 2>/dev/null
echo "0"   > /sys/class/power_supply/battery/batt_slate_mode             2>/dev/null
echo "100" > /sys/class/power_supply/battery/charge_control_limit        2>/dev/null
echo "100" > /sys/class/power_supply/battery/charge_stop_level           2>/dev/null
echo "100" > /sys/class/power_supply/mtk-gauge/charge_stop_level         2>/dev/null
resetprop persist.vendor.battery.protect.enable 0    2>/dev/null
resetprop persist.vendor.battery.protect.level "100" 2>/dev/null

# -- Restore audio to system default ------------------------------------------
resetprop --delete audio.deep_buffer.media               2>/dev/null
resetprop --delete vendor.audio.mmap.enable               2>/dev/null
resetprop --delete persist.vendor.audio.lowlatency.enable 2>/dev/null
resetprop --delete af.fast_track_multiplier                2>/dev/null
resetprop --delete vendor.audio.tunnel.encode              2>/dev/null
resetprop --delete persist.bluetooth.a2dp_offload.disabled  2>/dev/null
resetprop --delete persist.vendor.btstack.enable.lowlatency 2>/dev/null

# -- Restore sensors ------------------------------------------------------------
for IIO_DEV in /sys/bus/iio/devices/iio:device*; do
    [ -f "$IIO_DEV/buffer/enable" ] && echo "1" > "$IIO_DEV/buffer/enable" 2>/dev/null
done

# -- Restore ZRAM to system defaults ------------------------------------------
swapoff /dev/block/zram0 2>/dev/null
swapoff /dev/zram0       2>/dev/null
# Restore VM defaults
sysctl -w vm.swappiness=100           2>/dev/null
sysctl -w vm.vfs_cache_pressure=100   2>/dev/null
sysctl -w vm.dirty_ratio=30           2>/dev/null
sysctl -w vm.dirty_background_ratio=10 2>/dev/null
sysctl -w vm.page-cluster=3           2>/dev/null

# -- Release MTK PPM CPU freq floor ------------------------------------------─
echo "0" > /proc/ppm/policy/hard_userlimit_min_cpu_freq 2>/dev/null

# -- Restore CPU governor and freq limits to kernel defaults ------------------
for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo "schedutil" > "$f" 2>/dev/null
done
for i in 0 1 2 3 4 5; do
    echo "500000"  > /sys/devices/system/cpu/cpu${i}/cpufreq/scaling_min_freq 2>/dev/null
    echo "2000000" > /sys/devices/system/cpu/cpu${i}/cpufreq/scaling_max_freq 2>/dev/null
done
for i in 6 7; do
    echo "725000"  > /sys/devices/system/cpu/cpu${i}/cpufreq/scaling_min_freq 2>/dev/null
    echo "2200000" > /sys/devices/system/cpu/cpu${i}/cpufreq/scaling_max_freq 2>/dev/null
done

# -- Restore stune / cpuctl --------------------------------------------------─
echo "0"   > /dev/stune/top-app/schedtune.boost       2>/dev/null
echo "0"   > /dev/stune/top-app/schedtune.prefer_idle 2>/dev/null

# -- Re-enable system thermal engine ------------------------------------------
# Unmount any fake-27°C bind mounts FIRST - if the module is removed while
# gaming, the fake-temp mounts may still be active. Lazy umount (-l) ensures
# the unmount goes through even if a process is actively reading the node.
for tz in /sys/class/thermal/thermal_zone*/temp; do
    mount | grep -qF " on $tz " && umount -l "$tz" 2>/dev/null
done
# Re-enable every thermal zone mode + policy node
for tz in /sys/class/thermal/thermal_zone*/mode; do
    echo "enabled" > "$tz" 2>/dev/null
done
for tz in /sys/class/thermal/thermal_zone*/policy; do
    echo "step_wise" > "$tz" 2>/dev/null
done
# Restore MTK-specific thermal control nodes
echo "1" > /proc/mtk_thermal/tzcpu_rl         2>/dev/null
echo "1" > /proc/mtk_thermal/atm_enabled       2>/dev/null
echo "1" > /sys/devices/virtual/thermal/thermal_message/thermal_sconfig 2>/dev/null
# Restart thermal daemons
start thermal-engine          2>/dev/null
start thermal_manager         2>/dev/null
start thermalloadalgod        2>/dev/null
start thermald                2>/dev/null
# Restore thermal props
resetprop persist.thermal.enable        1  2>/dev/null
resetprop vendor.thermal.manager        1  2>/dev/null
resetprop vendor.thermal.link_ready     1  2>/dev/null
resetprop persist.vendor.thermal.enable 1  2>/dev/null

# -- Re-enable MTK thermal package (was disabled by apply.sh) ----------------─
pm enable --user 0 com.mediatek.thermal 2>/dev/null

# -- Restore display settings ------------------------------------------------─
settings delete system peak_refresh_rate      2>/dev/null
settings delete system min_refresh_rate       2>/dev/null
settings delete global window_animation_scale 2>/dev/null
settings delete global transition_animation_scale 2>/dev/null
settings delete global animator_duration_scale 2>/dev/null
settings delete system pointer_speed          2>/dev/null
settings delete secure long_press_timeout     2>/dev/null
settings delete secure multi_press_timeout    2>/dev/null
wm size reset    >/dev/null 2>&1
wm density reset >/dev/null 2>&1
resetprop --delete persist.sys.disable_rrs            2>/dev/null
resetprop ro.surface_flinger.use_content_detection_for_refresh_rate true 2>/dev/null

# -- Restore render engine to system default ----------------------------------─
resetprop --delete debug.hwui.renderer          2>/dev/null
resetprop --delete debug.renderengine.backend   2>/dev/null
resetprop --delete persist.sys.sf.render_scale_factor 2>/dev/null

# -- Restore chipset/powerHAL props --------------------------------------------
sh "$CORTEX/chipset/engine.sh" restore 2>/dev/null

# -- Restore FPS engine props (SF phase offsets, HWUI, cpu_boost, ADPF) --------
sh "$CORTEX/fps/engine.sh" restore 2>/dev/null

# -- Restore prop spoof --------------------------------------------------------
resetprop ro.product.brand        "$(getprop ro.product.vendor.brand)"        2>/dev/null
resetprop ro.product.manufacturer "$(getprop ro.product.vendor.manufacturer)" 2>/dev/null
resetprop ro.product.model        "$(getprop ro.product.vendor.model)"        2>/dev/null
resetprop ro.product.device       "$(getprop ro.product.vendor.device)"       2>/dev/null
resetprop ro.build.fingerprint    "$(getprop ro.vendor.build.fingerprint)"    2>/dev/null

# -- GPU freq unlock ----------------------------------------------------------─
echo "0" > /proc/gpufreq/gpufreq_opp_freq 2>/dev/null

# -- Clean up temp files ------------------------------------------------------─
rm -rf /data/local/tmp/sweet_dreams_tmp 2>/dev/null

# -- Clear any pending Sweet Dreams notifications ----------------------------─
for TAG in SweetDreams_game_launch SweetDreams_game_exit SweetDreams_thermal_override SweetDreams_spoof_active; do
    su 2000 -c "cmd notification cancel $TAG" >/dev/null 2>&1
done

echo "[LGTL] Uninstall cleanup complete"
