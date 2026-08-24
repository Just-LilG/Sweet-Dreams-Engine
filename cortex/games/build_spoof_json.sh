#!/system/bin/sh
# build_spoof_json.sh - Sweet Dreams
# Builds COPG.json for the real COPG Zygisk controller (v5.7.1 schema).
#
# CONFIRMED schema (from the actual controller source, spoof_module.cpp,
# provided directly rather than reverse-engineered):
#   For every key "PACKAGES_<NAME>" (not itself ending in "_DEVICE"), the
#   controller looks up a matching "PACKAGES_<NAME>_DEVICE" object. The array
#   under "PACKAGES_<NAME>" holds every package name spoofed as that device.
#   ONE PACKAGES_<NAME> KEY = ONE DEVICE, MANY PACKAGES.
#
#   Package entries support colon-separated tags:
#     "com.foo.bar:cpu=sd8elite"  -> mounts CPU/cpuinfo_sd8elite for this app,
#                                    ON TOP OF this device's identity spoof
#     "com.foo.bar:with_cpu"      -> legacy/back-compat: mounts a default CPU
#                                    profile, no specific key
#     "com.foo.bar:blocked"       -> RETIRED, no effect (spoof_module.cpp's
#                                    own comment confirms this explicitly -
#                                    kept out of anything this script writes)
#   No tag = device/prop spoof only, CPU spoof stays unmounted (opt-in by
#   design - the controller's own comment explains v5.1.x's "default =
#   block" scheme caused mount races).
#
#   SEPARATELY, top-level "cpu_spoof.cpu_only_packages" is an array of
#   "pkg:cpu=<key>" entries for CPU-only spoofing - a game gets a fake
#   /proc/cpuinfo WITHOUT any device-identity change. This is what Sweet
#   Dreams' per-game "Also Spoof CPU Info" checkbox now maps to when a game
#   has no device assigned but still wants CPU spoofing (see webroot's
#   toggleSpoofCpu/assignSpoof). "cpu_spoof.blacklist" force-unmounts CPU
#   spoof for specific packages regardless of any other tag - not currently
#   exposed in the WebUI; left as an empty array for manual editing if ever
#   needed.
#
# Bug fix vs every earlier version of this script: CPU spoofing used to
# target a single flat cpuinfo_spoof file and a retired ":with_cpu" tag
# convention that (per the controller's own comment) stopped doing anything
# useful after v5.1.x. Now uses the current, correct "cpu=<key>" tag and
# mirrors the full per-chip CPU/ profile directory (bundled at the module
# root - see manifest.json there for the available keys) alongside
# COPG.json, matching exactly how the real controller looks for these files.

CORTEX="/data/adb/modules/sweet_dreams/cortex"
MODDIR="/data/adb/modules/sweet_dreams"
SPOOF_CONF="$CORTEX/games/spoof_assignments.txt"
OUT="$MODDIR/COPG.json"
TMP="${OUT}.tmp"

# The COPG Zygisk controller (zygisk/*.so) hardcodes its config path to
# /data/adb/modules/COPG/COPG.json - NOT this module's own directory, and
# has no awareness of "sweet_dreams" at all. Confirmed via the actual
# controller source this time, not just `strings` on the binary.
COPG_DIR="/data/adb/modules/COPG"
COPG_OUT="$COPG_DIR/COPG.json"
CPU_SRC_DIR="$MODDIR/CPU"
CPU_OUT_DIR="$COPG_DIR/CPU"

# Device profiles below are copied VERBATIM from the real COPG.json
# reference (community-maintained, same values a stock COPG install would
# use for these exact seven devices) rather than independently reconstructed
# ones - confirmed identical brand/manufacturer/model/fingerprint, with
# DEVICE corrected to the marketing name (some earlier versions of this
# script used the internal codename here) and PRODUCT corrected for
# Samsung. SDK_INT/ANDROID_VERSION are dropped entirely - they don't appear
# in the real schema at all, so the controller never reads them; carrying
# them was dead weight, not a functional field.
device_profile_name() {
    case "$1" in
        legion)      echo "LEGION_Y700_2023" ;;
        redmagic)    echo "REDMAGIC_11_PRO" ;;
        redmagic9)   echo "REDMAGIC_9_PRO" ;;
        rog)         echo "ROG_PHONE_6D_ULTIMATE" ;;
        blackshark)  echo "BLACK_SHARK_4" ;;
        oneplus)     echo "ONEPLUS_13" ;;
        samsung)     echo "GALAXY_Z_FOLD_5" ;;
    esac
}

device_block_json() {
    case "$1" in
        legion)
            cat <<'BLOCK'
    "BRAND": "Lenovo",
    "DEVICE": "Legion Y700 (2023)",
    "MANUFACTURER": "Lenovo",
    "MODEL": "TB-9707F",
    "FINGERPRINT": "Lenovo/TB-9707F/Lenovo TB-9707F:13/TQ3A.230805.001/20230901:user/release-keys",
    "PRODUCT": "TB-9707F"
BLOCK
            ;;
        redmagic)
            cat <<'BLOCK'
    "BRAND": "REDMAGIC",
    "DEVICE": "REDMAGIC 11 PRO",
    "MANUFACTURER": "Nubia",
    "MODEL": "NX809J",
    "FINGERPRINT": "REDMAGIC/NX809J-UN/NX809J:16/BP2A.250605.031.A3/20251017.000000:user/release-keys",
    "PRODUCT": "NX809J"
BLOCK
            ;;
        redmagic9)
            cat <<'BLOCK'
    "BRAND": "nubia",
    "DEVICE": "REDMAGIC 9 Pro",
    "MANUFACTURER": "ZTE",
    "MODEL": "NX769J",
    "FINGERPRINT": "nubia/NX769J/NX769J:14/UKQ1.230917.001/20240813.173312:user/release-keys",
    "PRODUCT": "NX769J"
BLOCK
            ;;
        rog)
            cat <<'BLOCK'
    "BRAND": "ASUS",
    "DEVICE": "ROG Phone 6D Ultimate",
    "MANUFACTURER": "ASUS",
    "MODEL": "AI2203",
    "FINGERPRINT": "ASUS/AI2203/ROG Phone 6D:14/UP1A.231005.007/20240315:user/release-keys",
    "PRODUCT": "AI2203"
BLOCK
            ;;
        blackshark)
            cat <<'BLOCK'
    "BRAND": "Black Shark",
    "DEVICE": "Black Shark 4 (China)",
    "MANUFACTURER": "Xiaomi",
    "MODEL": "2SM-X706B",
    "FINGERPRINT": "BlackShark/PRS-H0/Black Shark 4:13/TQ3A.230805.001/20230315:user/release-keys",
    "PRODUCT": "2SM-X706B"
BLOCK
            ;;
        oneplus)
            cat <<'BLOCK'
    "BRAND": "OnePlus",
    "DEVICE": "OnePlus 13",
    "MANUFACTURER": "OnePlus",
    "MODEL": "PJZ110",
    "FINGERPRINT": "OnePlus/PJZ110/OP5D0DL1:15/AP3A.240617.008/V.1bd19a1-1-2:user/release-keys",
    "PRODUCT": "PJZ110"
BLOCK
            ;;
        samsung)
            cat <<'BLOCK'
    "BRAND": "samsung",
    "DEVICE": "Galaxy Z Fold 5",
    "MANUFACTURER": "samsung",
    "MODEL": "SM-F9460",
    "FINGERPRINT": "samsung/q2qzh/q2q:15/UP1A.231005.007/F946BXXU1BWK4:user/release-keys",
    "PRODUCT": "SM-F9460"
BLOCK
            ;;
    esac
}

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# spoof_assignments.txt lines are "pkg[:cpu=<key>|:with_cpu]|device". The tag
# lives on the PACKAGE field (see webroot's assignSpoof for why - the
# controller's own IFS='|' style parsing doesn't touch colons, so a tagged
# package name flows straight into a device's array exactly as written).
CPU_ONLY_LINES="$WORKDIR/cpu_only.txt"
: > "$CPU_ONLY_LINES"

if [ -f "$SPOOF_CONF" ]; then
    while IFS='|' read -r PKGTAG DEVICE; do
        PKGTAG=$(printf '%s' "$PKGTAG" | tr -d ' \r\n')
        DEVICE=$(printf '%s' "$DEVICE" | tr -d ' \r\n')
        [ -z "$PKGTAG" ] && continue
        if [ -z "$DEVICE" ] || [ "$DEVICE" = "off" ]; then
            # No device assigned - if this package still carries a cpu= or
            # with_cpu tag, it belongs in cpu_only_packages (CPU spoof with
            # no device-identity change) rather than any device's array.
            case "$PKGTAG" in
                *:cpu=*|*:with_cpu) echo "$PKGTAG" >> "$CPU_ONLY_LINES" ;;
            esac
            continue
        fi
        case "$DEVICE" in
            legion|redmagic|redmagic9|rog|blackshark|oneplus|samsung) ;;
            *) continue ;;
        esac
        echo "$PKGTAG" >> "$WORKDIR/$DEVICE.pkgs"
    done < "$SPOOF_CONF"
fi

{
    printf '{\n'
    printf '  "cpu_spoof": {\n'
    printf '    "blacklist": [],\n'
    printf '    "cpu_only_packages": [\n'
    FIRST=1
    while IFS= read -r P; do
        [ -z "$P" ] && continue
        if [ "$FIRST" = "1" ]; then printf '      "%s"' "$P"; FIRST=0
        else printf ',\n      "%s"' "$P"; fi
    done < "$CPU_ONLY_LINES"
    [ "$FIRST" = "0" ] && printf '\n'
    printf '    ]\n'
    printf '  }'

    for DEVICE in legion redmagic redmagic9 rog blackshark oneplus samsung; do
        [ -f "$WORKDIR/$DEVICE.pkgs" ] || continue
        NAME=$(device_profile_name "$DEVICE")
        [ -z "$NAME" ] && continue

        UNIQ_PKGS=$(awk '!seen[$0]++' "$WORKDIR/$DEVICE.pkgs")

        printf ',\n  "PACKAGES_%s": [\n' "$NAME"
        FIRST=1
        while IFS= read -r P; do
            [ -z "$P" ] && continue
            if [ "$FIRST" = "1" ]; then
                printf '    "%s"' "$P"
                FIRST=0
            else
                printf ',\n    "%s"' "$P"
            fi
        done <<EOF2
$UNIQ_PKGS
EOF2
        printf '\n  ],\n'

        printf '  "PACKAGES_%s_DEVICE": {\n' "$NAME"
        device_block_json "$DEVICE"
        printf '\n  }'
    done

    printf '\n}\n'
} > "$TMP"

if [ -s "$TMP" ] && grep -q '"cpu_spoof"' "$TMP" && grep -q '^{' "$TMP"; then
    mv -f "$TMP" "$OUT"
    chmod 0644 "$OUT" 2>/dev/null
    chcon u:object_r:system_file:s0 "$OUT" 2>/dev/null

    # Mirror to the path the controller actually reads.
    mkdir -p "$COPG_DIR" 2>/dev/null
    cp -f "$OUT" "$COPG_OUT" 2>/dev/null
    chmod 0644 "$COPG_OUT" 2>/dev/null
    chcon u:object_r:system_file:s0 "$COPG_OUT" 2>/dev/null

    # Mirror the whole CPU/ profile directory the same way - the controller
    # looks for CPU/cpuinfo_<key> under the COPG module path unconditionally
    # whenever any package resolves to needs_cpu_mount, regardless of which
    # specific key ends up requested.
    CPU_SYNCED=0
    if [ -d "$CPU_SRC_DIR" ]; then
        mkdir -p "$CPU_OUT_DIR" "$COPG_DIR/CPU" 2>/dev/null
        cp -f "$CPU_SRC_DIR"/cpuinfo_* "$CPU_OUT_DIR"/ 2>/dev/null
        cp -f "$CPU_SRC_DIR"/cpuinfo_* "$COPG_DIR/CPU/" 2>/dev/null
        for f in "$CPU_OUT_DIR"/cpuinfo_*; do
            [ -f "$f" ] || continue
            chmod 0444 "$f" 2>/dev/null
            chcon u:object_r:system_file:s0 "$f" 2>/dev/null
            CPU_SYNCED=$((CPU_SYNCED + 1))
        done
    fi

    ENTRY_COUNT=$(grep -c '"PACKAGES_[A-Z0-9_]*": \[' "$OUT" 2>/dev/null || echo 0)
    CPU_ONLY_COUNT=$(grep -c '.' "$CPU_ONLY_LINES" 2>/dev/null || echo 0)
    if [ -f "$COPG_OUT" ]; then
        echo "[spoof] COPG.json built OK - ${ENTRY_COUNT} device profile(s), ${CPU_ONLY_COUNT} cpu-only package(s), ${CPU_SYNCED} CPU profile file(s) synced - synced to $COPG_DIR"
    else
        echo "[spoof] COPG.json built OK - ${ENTRY_COUNT} device profile(s) - WARNING: sync to $COPG_DIR failed, controller will not see this config"
    fi
    if [ ! -f "$COPG_DIR/module.prop" ]; then
        cat > "$COPG_DIR/module.prop" <<'EOF'
id=COPG
name=COPG (Sweet Dreams stub)
version=v5.7.1-sd
versionCode=571
author=Sweet Dreams
description=Config + CPU profiles for Sweet Dreams Zygisk spoof. Do not disable.
EOF
    fi
else
    rm -f "$TMP"
    echo "[spoof] ERROR: JSON build failed, keeping previous COPG.json"
    exit 1
fi
