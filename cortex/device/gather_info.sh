#!/system/bin/sh
# cortex/device/gather_info.sh - Sweet Dreams
# Shell port of the device-identification half of Encore Tweaks'
# DeviceMitigationStore concept (github.com/rem01gaming/encore, Apache-2.0).
# Collects the same three identity fields Encore uses for device-rule
# matching, via the same underlying sources, just through shell tools
# instead of NDK calls (uname(2), /proc/device-tree/model, __system_property_get
# all have a plain-shell equivalent - no native code needed for this part).
#
# Output: cortex/device/info.txt, one KEY=VALUE per line.

CORTEX="/data/adb/modules/sweet_dreams/cortex"
OUT="$CORTEX/device/info.txt"
mkdir -p "$CORTEX/device"

KERNEL_RELEASE=$(uname -r 2>/dev/null || echo "unknown")
DEVICE_MODEL=$(getprop ro.product.model 2>/dev/null)
[ -z "$DEVICE_MODEL" ] && DEVICE_MODEL="unknown"
SOC_MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)
[ -z "$SOC_MODEL" ] && SOC_MODEL=$(getprop ro.board.platform 2>/dev/null)
[ -z "$SOC_MODEL" ] && SOC_MODEL="unknown"
ANDROID_VERSION=$(getprop ro.build.version.release 2>/dev/null || echo "unknown")
SECURITY_PATCH=$(getprop ro.build.version.security_patch 2>/dev/null || echo "unknown")
SELINUX_STATE=$(getenforce 2>/dev/null || echo "unknown")

{
    echo "KERNEL_RELEASE=$KERNEL_RELEASE"
    echo "DEVICE_MODEL=$DEVICE_MODEL"
    echo "SOC_MODEL=$SOC_MODEL"
    echo "ANDROID_VERSION=$ANDROID_VERSION"
    echo "SECURITY_PATCH=$SECURITY_PATCH"
    echo "SELINUX_STATE=$SELINUX_STATE"
} > "$OUT"
