/* battery_apply.c — Sweet Dreams charge limit
 * Replaces cortex/battery/apply.sh
 * Usage: battery_apply
 *        (reads cortex/battery/limit_enabled.txt and limit_pct.txt)
 */

#include "sd_util.h"
#include <stdio.h>

static void set_charge_limit(int pct) {
    char val[8];
    int applied = 0;

    /* Method 1: batt_slate_mode (MTK) — only useful at <= 80% */
    if (pct <= 80 && node_writable("/sys/class/power_supply/battery/batt_slate_mode")) {
        if (write_node("/sys/class/power_supply/battery/batt_slate_mode", "1")) {
            log_msg("BAT", "Charge limit via batt_slate_mode");
            applied = 1;
        }
    }

    /* Method 2: Infinix/Transsion specific nodes */
    snprintf(val, sizeof(val), "%d", pct);
    if (!applied && node_writable("/sys/class/power_supply/battery/charge_control_limit")) {
        if (write_node("/sys/class/power_supply/battery/charge_control_limit", val)) {
            log_fmt("BAT", "Charge limit %d%% via charge_control_limit", pct);
            applied = 1;
        }
    }
    if (!applied && node_writable("/sys/class/power_supply/battery/charge_stop_level")) {
        if (write_node("/sys/class/power_supply/battery/charge_stop_level", val)) {
            log_fmt("BAT", "Charge limit %d%% via charge_stop_level", pct);
            applied = 1;
        }
    }

    /* Method 3: MTK gauge node */
    if (!applied && node_writable("/sys/class/power_supply/mtk-gauge/charge_stop_level")) {
        if (write_node("/sys/class/power_supply/mtk-gauge/charge_stop_level", val)) {
            log_fmt("BAT", "Charge limit %d%% via mtk-gauge", pct);
            applied = 1;
        }
    }

    /* Method 4: vendor props — works even when sysfs is SELinux-locked */
    exec_resetprop("persist.vendor.battery.protect.enable", "1");
    exec_resetprop("persist.vendor.battery.protect.level",  val);
    exec_resetprop("ro.vendor.battery.charge.level",        val);

    if (!applied)
        log_fmt("BAT", "Charge limit %d%% set via prop only — sysfs locked by SELinux", pct);
}

static void remove_charge_limit(void) {
    if (node_writable("/sys/class/power_supply/battery/batt_slate_mode"))
        write_node("/sys/class/power_supply/battery/batt_slate_mode", "0");
    if (node_writable("/sys/class/power_supply/battery/charge_control_limit"))
        write_node("/sys/class/power_supply/battery/charge_control_limit", "100");
    if (node_writable("/sys/class/power_supply/battery/charge_stop_level"))
        write_node("/sys/class/power_supply/battery/charge_stop_level", "100");
    if (node_writable("/sys/class/power_supply/mtk-gauge/charge_stop_level"))
        write_node("/sys/class/power_supply/mtk-gauge/charge_stop_level", "100");
    exec_resetprop("persist.vendor.battery.protect.enable", "0");
    exec_resetprop("persist.vendor.battery.protect.level",  "100");
    log_msg("BAT", "Charge limit removed");
}

static void write_status(const char *limit_en, int pct) {
    char capacity[8] = "—";
    char charging[32] = "Unknown";
    char status[128];

    read_config("/sys/class/power_supply/battery/capacity", capacity, sizeof(capacity), "—");
    read_config("/sys/class/power_supply/battery/status",   charging, sizeof(charging), "Unknown");

    /* strip newline from charging status */
    char *nl = strchr(charging, '\n');
    if (nl) *nl = '\0';

    snprintf(status, sizeof(status), "%s|%d|%s|%s", limit_en, pct, capacity, charging);
    write_config(CORTEX "/battery/status.txt", status);
}

int main(void) {
    char en_buf[8], pct_buf[8];

    read_config(CORTEX "/battery/limit_enabled.txt", en_buf,  sizeof(en_buf),  "off");
    read_config(CORTEX "/battery/limit_pct.txt",     pct_buf, sizeof(pct_buf), "80");
    int pct = atoi(pct_buf);
    if (pct <= 0 || pct > 100) pct = 80;

    if (strcmp(en_buf, "on") == 0)
        set_charge_limit(pct);
    else
        remove_charge_limit();

    write_status(en_buf, pct);
    return 0;
}
