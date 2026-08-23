#!/system/bin/sh
# cortex/battery/bypass_charge.sh - Sweet Dreams Bypass Charging Engine
#
# PORTED FROM: AZenith's BypassCharge/ChargingNodes.c, ChargingUtility.c,
# and BinaryCLI/BypassCompatibility.c (Apache 2.0, Zexshia). Shell port -
# same node database, same detection algorithm, same safety checks.
#
# WHAT BYPASS CHARGING DOES:
#   Normally, when plugged in and gaming, power goes: charger -> battery ->
#   device. The battery is constantly being charged AND discharged at the
#   same time under gaming load, which heats it up and accelerates wear.
#   Bypass charging finds the OEM-specific kernel node that redirects power
#   charger -> device DIRECTLY, skipping the battery entirely while plugged
#   in. Battery stays at whatever charge it was at, doesn't heat up from
#   simultaneous charge/discharge, and wears out slower over time.
#
# WHY DETECTION INSTEAD OF ONE HARDCODED PATH:
#   There are 60+ known OEM-specific sysfs/proc nodes for this across
#   MTK/Qualcomm/Samsung/Pixel/Oppo/vivo/Xiaomi/etc, and no way to know
#   which one (if any) exists and actually works on a given device without
#   testing. AZenith's approach: for every node that EXISTS on this device,
#   enable it and watch real battery current draw for 10 seconds. If
#   current drops below 50mA while still genuinely plugged in, that node
#   successfully diverted power away from the battery - proven working,
#   not guessed. The winning node name is saved so future toggles are
#   instant (no need to re-test every time).
#
# USAGE:
#   bypass_charge.sh detect   - one-time compatibility scan (needs charger
#                               plugged in, takes up to a few minutes)
#   bypass_charge.sh on       - enable bypass using the saved working node
#   bypass_charge.sh off      - disable, charging behaves normally again
#   bypass_charge.sh status   - print current state

MODDIR="/data/adb/modules/sweet_dreams"
CORTEX="$MODDIR/cortex"
LOGFILE="$MODDIR/boot.log"
ACTION="${1:-status}"

BYPASS_PATH_FILE="$CORTEX/battery/bypass_node.txt"      # saved working node NAME
BYPASS_STATE_FILE="$CORTEX/battery/bypass_state.txt"    # on / off

log_bc() { echo "[BYPASS_CHG] $1" | tee -a "$LOGFILE"; }

# ----------------------------------------------------------------------------─
# Node database - name|path|on_value|off_value
# Ported verbatim from AZenith's ChargingNodes.c bypass_list[]. Covers
# common/generic nodes plus MTK, Qualcomm, Samsung, Pixel, Oppo/OnePlus,
# Huawei, LG, ASUS, Nubia, and other OEM-specific paths.
# ----------------------------------------------------------------------------─
NODES='
COMMON_INPUT_SUSPEND|/sys/class/power_supply/battery/input_suspend|1|0
COMMON_BATT_INPUT_SUSPEND|/sys/class/power_supply/battery/battery_input_suspend|1|0
COMMON_CHG_CONTROL|/sys/class/power_supply/battery/charger_control|0|1
COMMON_CHG_DISABLE|/sys/class/power_supply/battery/charge_disable|1|0
COMMON_CHG_ENABLED_V1|/sys/class/power_supply/battery/charging_enabled|0|1
COMMON_CHG_ENABLED_V2|/sys/class/power_supply/battery/charge_enabled|0|1
COMMON_BATT_CHG_ENABLED|/sys/class/power_supply/battery/battery_charging_enabled|0|1
COMMON_DEVICE_CHG_EN|/sys/class/power_supply/battery/device/Charging_Enable|0|1
MTK_BYPASS_CHG|/sys/devices/platform/charger/bypass_charger|1|0
MTK_CURRENT_CMD|/proc/mtk_battery_cmd/current_cmd|0 1|0 0
TRAN_AICHG_DISABLE|/sys/devices/platform/charger/tran_aichg_disable_charger|1|0
MTK_DISABLE_BATTERY_CHG|/sys/devices/platform/mt-battery/disable_charger|1|0
MTK_ADV_PATH|/proc/mtk_battery_cmd/en_power_path|0|1
OPLUS_MMI_1|/sys/class/oplus_chg/battery/mmi_charging_enable|0|1
OPLUS_MMI_2|/sys/class/power_supply/battery/mmi_charging_enable|0|1
OPLUS_MMI_3|/sys/devices/virtual/oplus_chg/battery/mmi_charging_enable|0|1
OPLUS_MMI_SOC|/sys/devices/platform/soc/soc:oplus,chg_intf/oplus_chg/battery/mmi_charging_enable|0|1
OPLUS_EXP_CHG_ENABLE|/sys/devices/platform/soc/soc:oplus,chg_intf/oplus_chg/battery/chg_enable|0|1
OPLUS_COOLDOWN_STATE|/sys/devices/platform/soc/soc:oplus,chg_intf/oplus_chg/battery/cool_down|1|0
AC_CHG_ENABLED|/sys/class/power_supply/ac/charging_enabled|0|1
CHG_DATA_ENABLE|/sys/class/power_supply/charge_data/enable_charger|0|1
DC_CHG_ENABLED|/sys/class/power_supply/dc/charging_enabled|0|1
OP_DISABLE_CHG|/sys/class/power_supply/battery/op_disable_charge|1|0
CHGALG_DISABLE_CHG|/sys/class/power_supply/chargalg/disable_charging|1|0
BATT_CONNECT_DISABLE|/sys/class/power_supply/battery/connect_disable|1|0
QPNP_SMB_BATT_EN|/sys/devices/soc/qpnp-smbcharger-18/power_supply/battery/battery_charging_enabled|0|1
QCOM_SUSPEND|/sys/class/qcom-battery/input_suspend|0|1
QCOM_EN_CHG|/sys/class/qcom-battery/charging_enabled|0|1
QCOM_COOL_MODE|/sys/class/qcom-battery/cool_mode|1|0
QCOM_PROTECT_EN|/sys/class/qcom-battery/batt_protect_en|1|0
QCOM_PMIC_GLINK_SUSPEND|/sys/devices/platform/soc/soc:qcom,pmic_glink/soc:qcom,pmic_glink:qcom,battery_charger/force_charger_suspend|1|0
PM8058_DISABLE|/sys/module/pmic8058_charger/parameters/disabled|1|0
PM8921_DISABLE|/sys/module/pm8921_charger/parameters/disabled|1|0
SMB137B_DISABLE|/sys/module/smb137b/parameters/disabled|1|0
SMB1357_DISABLE_PROC|/proc/smb1357_disable_chrg|1|0
BQ2589X_EN_CHG|/sys/class/power_supply/bq2589x_charger/enable_charging|0|1
PIXEL_CHG_DISABLE|/sys/devices/platform/soc/soc:google,charger/charge_disable|1|0
PIXEL_DEBUG_SUSPEND|/sys/kernel/debug/google_charger/chg_suspend|1|0
PIXEL_INPUT_SUSPEND|/sys/kernel/debug/google_charger/input_suspend|1|0
PIXEL_CHG_MODE|/sys/kernel/debug/google_charger/chg_mode|0|1
SAM_STORE_MODE|/sys/class/power_supply/battery/store_mode|1|0
LGE_CHG_ENABLE|/sys/devices/platform/lge-unified-nodes/charging_enable|0|1
LGE_CHG_COMPLETED|/sys/devices/platform/lge-unified-nodes/charging_completed|1|0
ASUS_LIMIT_EN|/sys/class/asuslib/charger_limit_en|1|0
ASUS_SUSPEND_EN|/sys/class/asuslib/charging_suspend_en|1|0
HUAWEI_CHG_EN_1|/sys/devices/platform/huawei_charger/enable_charger|0|1
HUAWEI_CHG_EN_2|/sys/class/hw_power/charger/charge_data/enable_charger|0|1
NUBIA_BYPASS_MODE|/sys/kernel/nubia_charge/charger_bypass|on|off
MANTA_CHG_EN|/sys/devices/virtual/power_supply/manta-battery/charge_enabled|0|1
CAT_CHG_SWITCH|/sys/devices/platform/battery/CCIChargerSwitch|0|1
SPREADTRUM_STOP_CHG|/sys/class/power_supply/battery/stop_charge|1|0
SIOP_LEVEL_CTRL|/sys/class/power_supply/battery/siop_level|0|100
CHG_LIMIT_ENABLE|/proc/driver/charger_limit_enable|1|0
QPNP_ADAPTIVE_BLOCK|/sys/module/qpnp_adaptive_charge/parameters/blocking|1|0
BATT_SLATE_MODE|/sys/class/power_supply/battery/batt_slate_mode|1|0
BATT_DEFENDER_CNT|/sys/class/power_supply/battery/bd_trickle_cnt|1|0
IDT_PIN_EN|/sys/class/power_supply/idt/pin_enabled|1|0
CHG_STATE_CTRL|/sys/class/power_supply/battery/charge_charger_state|1|0
ADAPTER_CC_MODE|/sys/class/power_supply/main/adapter_cc_mode|1|0
HMT_TA_CHG|/sys/class/power_supply/battery/hmt_ta_charge|0|1
MAXFG_OFF_CHG|/sys/class/power_supply/maxfg/offmode_charger|1|0
COOL_MODE_MAIN|/sys/class/power_supply/main/cool_mode|1|0
RESTRICTED_CHG_BATT|/sys/class/power_supply/battery/restricted_charging|1|0
RESTRICTED_CHG_WIRELESS|/sys/class/power_supply/wireless/restricted_charging|1|0
'

# ----------------------------------------------------------------------------─
# is_charging - 1 if genuinely connected to power right now
# ----------------------------------------------------------------------------─
is_charging() {
    STATUS=$(cat /sys/class/power_supply/battery/status 2>/dev/null)
    case "$STATUS" in
        *Charging*|*Full*) return 0 ;;
        *) return 1 ;;
    esac
}

# ----------------------------------------------------------------------------─
# read_current_ma - battery current draw in mA, always positive.
# Tries the two paths AZenith's C source checks, normalizes µA->mA.
# ----------------------------------------------------------------------------─
read_current_ma() {
    for NODE in \
        /sys/class/power_supply/battery/current_now \
        /sys/class/power_supply/battery/BatteryAverageCurrent; do
        [ -f "$NODE" ] || continue
        VAL=$(cat "$NODE" 2>/dev/null)
        [ -z "$VAL" ] && continue
        VAL=${VAL#-}   # abs value, POSIX-sh safe (strip leading minus)
        if [ "$VAL" -gt 1000 ] 2>/dev/null; then
            echo $((VAL / 1000))
        else
            echo "$VAL"
        fi
        return
    done
    echo "9999"
}

# ----------------------------------------------------------------------------─
# detect - the real compatibility scan, ported from BypassCompatibility.c.
# For every node that EXISTS on this device: enable it, watch current draw
# for 10s, disable it again. If current dropped below 50mA, that's our node.
# ----------------------------------------------------------------------------─
detect() {
    if ! is_charging; then
        log_bc "Charger not detected - plug in first, then run detection"
        echo "not_charging" > "$BYPASS_PATH_FILE"
        return 1
    fi

    log_bc "Starting bypass node compatibility scan (this takes a few minutes)..."
    TESTED=0
    SKIPPED=0

    echo "$NODES" | while IFS='|' read -r NAME PATHV ONV OFFV; do
        [ -z "$NAME" ] && continue
        [ -f "$PATHV" ] || { SKIPPED=$((SKIPPED + 1)); continue; }

        TESTED=$((TESTED + 1))
        log_bc "Testing $NAME ($PATHV)..."
        chmod 0644 "$PATHV" 2>/dev/null
        echo "$ONV" > "$PATHV" 2>/dev/null

        LAST_MA=9999
        i=1
        while [ "$i" -le 10 ]; do
            sleep 1
            LAST_MA=$(read_current_ma)
            i=$((i + 1))
        done

        echo "$OFFV" > "$PATHV" 2>/dev/null

        if [ "$LAST_MA" -lt 50 ] 2>/dev/null; then
            log_bc "SUCCESS - working node found: $NAME (current dropped to ${LAST_MA}mA)"
            echo "$NAME" > "$BYPASS_PATH_FILE"
            return 0
        fi
    done

    log_bc "No compatible bypass node found on this device/firmware"
    echo "UNSUPPORTED" > "$BYPASS_PATH_FILE"
    return 1
}

# ----------------------------------------------------------------------------─
# enable / disable - instant, using the already-detected node
# ----------------------------------------------------------------------------─
enable_bypass() {
    NODE_NAME=$(cat "$BYPASS_PATH_FILE" 2>/dev/null)
    if [ -z "$NODE_NAME" ] || [ "$NODE_NAME" = "UNSUPPORTED" ] || [ "$NODE_NAME" = "not_charging" ]; then
        log_bc "No detected working node - run 'detect' first (while plugged in)"
        echo "off" > "$BYPASS_STATE_FILE"
        return 1
    fi

    echo "$NODES" | while IFS='|' read -r NAME PATHV ONV OFFV; do
        [ "$NAME" = "$NODE_NAME" ] || continue
        chmod 0644 "$PATHV" 2>/dev/null
        echo "$ONV" > "$PATHV" 2>/dev/null
        chmod 0444 "$PATHV" 2>/dev/null   # lock so nothing else flips it back
        log_bc "Bypass charging enabled via $NAME"
    done
    echo "on" > "$BYPASS_STATE_FILE"
}

disable_bypass() {
    NODE_NAME=$(cat "$BYPASS_PATH_FILE" 2>/dev/null)
    if [ -z "$NODE_NAME" ] || [ "$NODE_NAME" = "UNSUPPORTED" ] || [ "$NODE_NAME" = "not_charging" ]; then
        echo "off" > "$BYPASS_STATE_FILE"
        return 0
    fi

    echo "$NODES" | while IFS='|' read -r NAME PATHV ONV OFFV; do
        [ "$NAME" = "$NODE_NAME" ] || continue
        chmod 0644 "$PATHV" 2>/dev/null
        echo "$OFFV" > "$PATHV" 2>/dev/null
        log_bc "Bypass charging disabled via $NAME - normal charging restored"
    done
    echo "off" > "$BYPASS_STATE_FILE"
}

# ----------------------------------------------------------------------------─
# ENTRY POINT
# ----------------------------------------------------------------------------─
case "$ACTION" in
    detect) detect ;;
    on)     enable_bypass ;;
    off)    disable_bypass ;;
    status)
        NODE_NAME=$(cat "$BYPASS_PATH_FILE" 2>/dev/null || echo "not_detected")
        STATE=$(cat "$BYPASS_STATE_FILE" 2>/dev/null || echo "off")
        echo "node=$NODE_NAME|state=$STATE|charging=$(is_charging && echo yes || echo no)"
        ;;
    *)
        echo "Usage: bypass_charge.sh [detect|on|off|status]" >&2
        exit 1
        ;;
esac
