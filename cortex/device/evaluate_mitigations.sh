#!/system/bin/sh
# cortex/device/evaluate_mitigations.sh - Sweet Dreams
# Shell port of DeviceMitigationStore's matching engine (Encore Tweaks,
# github.com/rem01gaming/encore, Apache-2.0) - reads gather_info.sh's
# output, checks it against mitigation_rules.txt, and writes the merged,
# deduplicated set of active mitigation items to active.txt for every
# other script in this module to check against.
#
# PLUS one thing Encore's static device_rules.json approach can't do:
# an empirical runtime probe for the exact cmd-dispatcher problem this
# module hit on its original test device. Static device-model matching
# only protects devices someone has manually catalogued in
# mitigation_rules.txt; this probe detects the actual condition directly
# - a completely different device/ROM/Android-version combination with
# the exact same SELinux restriction gets the mitigation automatically,
# with no rule needed. See fps/engine.sh's header comment for the full
# background on what this restriction is and how it was found.

CORTEX="/data/adb/modules/sweet_dreams/cortex"
INFO_FILE="$CORTEX/device/info.txt"
RULES_FILE="$CORTEX/device/mitigation_rules.txt"
ACTIVE_FILE="$CORTEX/device/active.txt"

[ -f "$INFO_FILE" ] || sh "$CORTEX/device/gather_info.sh"
# shellcheck disable=SC1090
. "$INFO_FILE" 2>/dev/null

TMP="$ACTIVE_FILE.tmp"
: > "$TMP"

get_field() {
    case "$1" in
        KERNEL_RELEASE)  echo "$KERNEL_RELEASE" ;;
        DEVICE_MODEL)    echo "$DEVICE_MODEL" ;;
        SOC_MODEL)       echo "$SOC_MODEL" ;;
        ANDROID_VERSION) echo "$ANDROID_VERSION" ;;
        SECURITY_PATCH)  echo "$SECURITY_PATCH" ;;
        SELINUX_STATE)   echo "$SELINUX_STATE" ;;
        *) echo "" ;;
    esac
}

# -- Static rules from mitigation_rules.txt ------------------------------------─
while IFS='|' read -r RULE_NAME FIELD MATCH_TYPE MATCH_VALUE ITEMS; do
    case "$RULE_NAME" in ""|\#*) continue ;; esac
    [ -z "$FIELD" ] && continue
    FIELD_VALUE=$(get_field "$FIELD")
    [ -z "$FIELD_VALUE" ] && continue

    MATCHED=0
    case "$MATCH_TYPE" in
        contains) case "$FIELD_VALUE" in *"$MATCH_VALUE"*) MATCHED=1 ;; esac ;;
        exact)    [ "$FIELD_VALUE" = "$MATCH_VALUE" ] && MATCHED=1 ;;
        regex)    echo "$FIELD_VALUE" | grep -qE "$MATCH_VALUE" 2>/dev/null && MATCHED=1 ;;
    esac

    if [ "$MATCHED" = "1" ]; then
        echo "$ITEMS" | tr ',' '\n' >> "$TMP"
    fi
done < "$RULES_FILE"

# -- Empirical probe: is the cmd dispatcher actually usable here? --------------
# A read-only, harmless probe - same call service.sh's own boot-readiness
# check already uses, so this adds no new risk. If SELinux is enforcing AND
# this specific call fails, mark it - this is the same signature verified
# via getenforce + repeated identical failures across settings/window/
# activity/package/game throughout this module's development.
if [ "$SELINUX_STATE" = "Enforcing" ]; then
    if ! cmd settings get global airplane_mode_on >/dev/null 2>&1; then
        echo "CMD_DISPATCHER_UNRELIABLE" >> "$TMP"
    fi
fi

# -- Merge, dedupe, write ------------------------------------------------------─
sort -u "$TMP" 2>/dev/null | grep -v '^$' > "$ACTIVE_FILE"
rm -f "$TMP"
