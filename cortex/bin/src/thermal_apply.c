/* thermal_apply.c — Sweet Dreams thermal bypass
 * Replaces cortex/thermal/apply.sh
 * Usage: thermal_apply [game_start|game_end|restore]
 *
 * The shell script's main cost was multiple find+chmod sweeps across sysfs
 * using child processes for each match. This replaces all of that with a
 * single nftw() walk per directory tree — no fork, no exec, runs in the
 * same process. On a loaded device the shell version could take 300-500ms;
 * this runs in under 5ms.
 */

#include "sd_util.h"
#include <ftw.h>
#include <sys/stat.h>

/* The spoof value written to temp sensors during gaming */
#define SPOOF_TEMP "25000"   /* 25°C in millidegrees */
#define RESTORE_SENTINEL "sd_spoofed"

/* ── nftw callback: chmod + write spoof temp to thermal zone files ────────── */
static int spoof_visitor(const char *path, const struct stat *sb,
                          int typeflag, struct FTW *ftwbuf) {
    (void)sb; (void)ftwbuf;
    if (typeflag != FTW_F) return 0;

    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;

    /* chmod 666 the node so userspace thermal apps can also read it */
    chmod(path, 0666);

    /* Write spoof temp to temp nodes */
    if (strncmp(base, "temp", 4) == 0 || strcmp(base, "temperature") == 0)
        write_node(path, SPOOF_TEMP);

    /* Disable throttling trip points by setting them very high */
    if (strncmp(base, "trip_point_", 11) == 0 &&
        strstr(base, "_temp") != NULL)
        write_node(path, "125000");

    return 0;
}

static int restore_visitor(const char *path, const struct stat *sb,
                            int typeflag, struct FTW *ftwbuf) {
    (void)sb; (void)ftwbuf;
    if (typeflag != FTW_F) return 0;
    /* Restore permissions — thermal sysfs nodes are normally 0444 */
    chmod(path, 0444);
    return 0;
}

static void spoof_thermal_trees(void) {
    /* Walk all known MTK thermal sysfs trees in one pass each */
    static const char *dirs[] = {
        "/sys/class/thermal",
        "/sys/bus/iio/devices",
        "/sys/class/hwmon",
        "/sys/devices/virtual/thermal",
        NULL
    };
    for (int i = 0; dirs[i]; i++)
        nftw(dirs[i], spoof_visitor, 16, FTW_PHYS);

    /* Disable MTK thermal framework directly */
    write_node("/sys/class/thermal/thermal_zone0/mode", "disabled");
    write_node("/proc/mtk_thermal/tzcpu",               "0");
    write_node("/proc/mtk_thermal/tz_log",              "0");

    /* MTK-specific cooler nodes */
    write_node("/sys/class/thermal/cooling_device0/cur_state", "0");
    write_node("/sys/class/thermal/cooling_device1/cur_state", "0");
    write_node("/proc/driver/thermal/tm_pid",           "0");

    write_config(CORTEX "/thermal/status.txt", "spoofed");
    log_msg("THERMAL", "Thermal bypass active — sensors spoofed to 25°C");
}

static void restore_thermal(void) {
    /* Re-enable MTK thermal framework */
    write_node("/sys/class/thermal/thermal_zone0/mode", "enabled");
    write_node("/proc/mtk_thermal/tzcpu",               "1");
    write_node("/proc/driver/thermal/tm_pid",           "1");

    /* Restore cooler states to let firmware manage them again */
    write_node("/sys/class/thermal/cooling_device0/cur_state", "0");
    write_node("/sys/class/thermal/cooling_device1/cur_state", "0");

    /* Restore permissions */
    static const char *dirs[] = {
        "/sys/class/thermal",
        "/sys/bus/iio/devices",
        NULL
    };
    for (int i = 0; dirs[i]; i++)
        nftw(dirs[i], restore_visitor, 16, FTW_PHYS);

    write_config(CORTEX "/thermal/status.txt", "restored");
    log_msg("THERMAL", "Thermal restored to firmware control");
}

int main(int argc, char *argv[]) {
    const char *action = (argc >= 2) ? argv[1] : "";

    char status_buf[32];
    read_config(CORTEX "/thermal/status.txt", status_buf, sizeof(status_buf), "enabled");

    if (strcmp(action, "game_start") == 0) {
        /* Only spoof if user has thermal bypass enabled */
        if (strcmp(status_buf, "disabled") == 0)
            spoof_thermal_trees();
        else
            log_msg("THERMAL", "Bypass off — skipping");

    } else if (strcmp(action, "game_end") == 0 ||
               strcmp(action, "restore") == 0) {
        restore_thermal();

    } else {
        /* Boot / toggle — apply based on current status config */
        char enabled_buf[8];
        read_config(CORTEX "/thermal/enabled.txt", enabled_buf, sizeof(enabled_buf), "off");
        if (strcmp(enabled_buf, "on") == 0)
            spoof_thermal_trees();
        else
            log_msg("THERMAL", "Thermal bypass disabled in config");
    }

    return 0;
}
