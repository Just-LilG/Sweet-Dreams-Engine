#!/system/bin/sh
# spoof.sh - Sweet Dreams
# Global system-prop spoof (affects ALL apps system-wide).
# Reads from cortex/games/spoof_assignments.txt and applies the FIRST
# assigned device as a global prop spoof via resetprop.
# This runs alongside the Zygisk per-app spoof (controller/COPG.json),
# acting as a fallback for apps that read props before Zygisk hooks.
#
# Called by service.sh at boot and by the UI on master toggle.

CORTEX="/data/adb/modules/sweet_dreams/cortex"
SPOOF_CONF="$CORTEX/games/spoof_assignments.txt"
REAL_BACKUP="$CORTEX/games/real_props_backup.txt"

# Bug fix (Master OFF not reverting to the real device): restore_props()
# used to reconstruct the "real" values from ro.product.vendor.* - a
# SEPARATE property set populated by the vendor partition's own build.prop,
# not an automatic backup of what ro.product.* held before spoofing. On
# plenty of devices those simply don't match the system partition's
# original identity (or are blank), so "restoring" from them could set
# ro.product.model to the wrong string, or to nothing at all - which is
# exactly "props don't revert to the real device" from the outside. There
# was never an actual snapshot taken before the first spoof overwrite.
# Capture one now if it doesn't already exist - this only produces correct
# values if props are genuinely unspoofed at the moment it first runs,
# which is true right after a fresh install/update (see customize.sh, which
# calls this before the module's own spoofing can ever apply) and is also
# attempted here defensively in case that file is ever missing/deleted.
backup_real_props_if_needed() {
    [ -f "$REAL_BACKUP" ] && return
    {
        echo "REAL_BRAND=$(getprop ro.product.brand)"
        echo "REAL_MANUFACTURER=$(getprop ro.product.manufacturer)"
        echo "REAL_MODEL=$(getprop ro.product.model)"
        echo "REAL_DEVICE=$(getprop ro.product.device)"
        echo "REAL_NAME=$(getprop ro.product.name)"
        echo "REAL_FINGERPRINT=$(getprop ro.build.fingerprint)"
    } > "$REAL_BACKUP"
}
backup_real_props_if_needed

restore_props() {
    # shellcheck disable=SC1090
    . "$REAL_BACKUP" 2>/dev/null
    resetprop ro.product.brand        "$REAL_BRAND"        2>/dev/null
    resetprop ro.product.manufacturer "$REAL_MANUFACTURER" 2>/dev/null
    resetprop ro.product.model        "$REAL_MODEL"        2>/dev/null
    resetprop ro.product.device       "$REAL_DEVICE"       2>/dev/null
    resetprop ro.product.name         "$REAL_NAME"         2>/dev/null
    resetprop ro.build.fingerprint    "$REAL_FINGERPRINT"  2>/dev/null
    echo "[spoof] Props restored to real device"
}

set_props() {
    # $1=brand $2=manufacturer $3=model $4=device $5=name $6=fingerprint
    resetprop ro.product.brand        "$1" 2>/dev/null
    resetprop ro.product.manufacturer "$2" 2>/dev/null
    resetprop ro.product.model        "$3" 2>/dev/null
    resetprop ro.product.device       "$4" 2>/dev/null
    resetprop ro.product.name         "$5" 2>/dev/null
    resetprop ro.build.fingerprint    "$6" 2>/dev/null
    echo "[spoof] Props set -> $1 $3"
}

MASTER=$(cat "$CORTEX/games/spoof_master.txt" 2>/dev/null || echo "off")
if [ "$MASTER" != "on" ]; then
    restore_props
    exit 0
fi

ROTATE=$(cat "$CORTEX/games/spoof_rotate.txt" 2>/dev/null || echo "off")
DEVICE=""

if [ "$ROTATE" = "on" ]; then
    # Advance through the known device pool on every call instead of always
    # using whatever the first assignment line says - gives each session a
    # different reported fingerprint rather than the same one every time.
    DEVICE_POOL="legion redmagic redmagic9 rog blackshark oneplus samsung"
    IDX_FILE="$CORTEX/games/spoof_rotate_idx.txt"
    IDX=$(cat "$IDX_FILE" 2>/dev/null || echo 0)
    case "$IDX" in (*[!0-9]*|"") IDX=0 ;; esac
    COUNT=$(printf '%s\n' $DEVICE_POOL | wc -l)
    IDX=$(( IDX % COUNT ))
    N=0
    for D in $DEVICE_POOL; do
        if [ "$N" -eq "$IDX" ]; then DEVICE="$D"; break; fi
        N=$((N + 1))
    done
    echo $(( (IDX + 1) % COUNT )) > "$IDX_FILE"
    echo "[spoof] Rotation active - using slot $IDX: $DEVICE"
else
    # Read first valid assignment from spoof_assignments.txt
    if [ -f "$SPOOF_CONF" ]; then
        while IFS='|' read -r PKG DEV; do
            PKG=$(printf '%s' "$PKG" | tr -d ' \r\n')
            DEV=$(printf '%s' "$DEV" | tr -d ' \r\n')
            [ -n "$PKG" ] && [ -n "$DEV" ] && [ "$DEV" != "off" ] && DEVICE="$DEV" && break
        done < "$SPOOF_CONF"
    fi
fi

case "$DEVICE" in
    legion)
        set_props "Lenovo" "Lenovo" "TB-9707F" "TB-9707F" "TB-9707F" \
            "Lenovo/TB-9707F/Lenovo TB-9707F:13/TQ3A.230805.001/20230901:user/release-keys"
        ;;
    redmagic)
        set_props "REDMAGIC" "Nubia" "NX809J" "NX809J" "NX809J" \
            "REDMAGIC/NX809J-UN/NX809J:16/BP2A.250605.031.A3/20251017.000000:user/release-keys"
        ;;
    redmagic9)
        set_props "nubia" "ZTE" "NX769J" "NX769J" "NX769J" \
            "nubia/NX769J/NX769J:14/UKQ1.230917.001/20240813.173312:user/release-keys"
        ;;
    rog)
        set_props "ASUS" "ASUS" "AI2203" "AI2203" "AI2203" \
            "ASUS/AI2203/ROG Phone 6D:14/UP1A.231005.007/20240315:user/release-keys"
        ;;
    blackshark)
        set_props "Black Shark" "Xiaomi" "2SM-X706B" "PRS-H0" "2SM-X706B" \
            "BlackShark/PRS-H0/Black Shark 4:13/TQ3A.230805.001/20230315:user/release-keys"
        ;;
    oneplus)
        set_props "OnePlus" "OnePlus" "PJZ110" "OP5D0DL1" "PJZ110" \
            "OnePlus/PJZ110/OP5D0DL1:15/AP3A.240617.008/V.1bd19a1-1-2:user/release-keys"
        ;;
    samsung)
        set_props "samsung" "samsung" "SM-F9460" "q2q" "q2qzh" \
            "samsung/q2qzh/q2q:15/UP1A.231005.007/F946BXXU1BWK4:user/release-keys"
        ;;
    *)
        restore_props
        ;;
esac
