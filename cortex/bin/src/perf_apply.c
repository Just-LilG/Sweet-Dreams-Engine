/* perf_apply.c — Sweet Dreams MTK PerfService boost
 * Replaces cortex/perf/apply.sh
 * Usage: perf_apply <game_pkg> [boost|restore]
 */

#include "sd_util.h"

int main(int argc, char *argv[]) {
    const char *pkg    = (argc >= 2) ? argv[1] : "unknown";
    const char *action = (argc >= 3) ? argv[2] : "boost";

    if (strcmp(action, "boost") == 0) {
        /* MTK PerfService scenario: 2 = GAME_SCENARIO */
        write_node("/proc/perfmgr/legacy/perfserv_ta", "2");
        write_node("/proc/perfmgr/perf_ioctl",          "2");
        write_node("/sys/devices/system/cpu/perf_boost_enable", "1");

        /* DVFS headroom — 15% slack for burst loads */
        write_node("/sys/module/mtk_freq_bound/parameters/ut_freq_bound", "15");
        write_node("/proc/mtk_dvfs/ut_headroom",                          "15");

        /* EAS game hint */
        write_node("/sys/kernel/eas/game_hint",   "1");
        write_node("/proc/mtk_eas/game_mode",     "1");

        /* Mali GPU game-mode hint */
        write_node("/sys/class/misc/mali0/device/devfreq/mali0/mali_ondemand_game_mode", "1");
        write_node("/sys/class/misc/mali0/device/power_policy",  "1");
        write_node("/sys/class/misc/mali0/device/highfreq_hint", "1");

        write_config(CORTEX "/perf/state.txt", "boost");
        log_fmt("PERF", "Game boost: %s", pkg);

    } else {
        /* Restore: scenario 0 = idle */
        write_node("/proc/perfmgr/legacy/perfserv_ta", "0");
        write_node("/proc/perfmgr/perf_ioctl",          "0");

        write_node("/sys/module/mtk_freq_bound/parameters/ut_freq_bound", "0");
        write_node("/proc/mtk_dvfs/ut_headroom",                          "0");

        write_node("/sys/kernel/eas/game_hint", "0");
        write_node("/proc/mtk_eas/game_mode",   "0");

        write_node("/sys/class/misc/mali0/device/devfreq/mali0/mali_ondemand_game_mode", "0");
        write_node("/sys/class/misc/mali0/device/power_policy",  "0");
        write_node("/sys/class/misc/mali0/device/highfreq_hint", "0");

        write_config(CORTEX "/perf/state.txt", "idle");
        log_msg("PERF", "Perf state restored");
    }

    return 0;
}
