/* cpu_apply.c — Sweet Dreams CPU tuning
 * Replaces cortex/cpu/apply.sh
 * Usage: cpu_apply [gaming|balanced|battery]
 *        (reads cortex/cpu/profile.txt if no arg given)
 *
 * All work is direct open()+write() to sysfs — no fork, no exec,
 * no shell interpreter overhead. Runs in ~1ms vs ~80ms for the shell version.
 */

#include "sd_util.h"

/* ── CPU cluster layout — A55 cores 0-5, A76 cores 6-7 (MT6789) ─────────── */
#define A55_START 0
#define A55_END   5
#define A76_START 6
#define A76_END   7

static void set_governor(const char *gov) {
    char path[128];
    for (int i = A55_START; i <= A76_END; i++) {
        snprintf(path, sizeof(path),
            "/sys/devices/system/cpu/cpu%d/cpufreq/scaling_governor", i);
        write_node(path, gov);
    }
}

static void set_cluster_freq(int start, int end,
                              const char *min_khz, const char *max_khz) {
    char path[128];
    for (int i = start; i <= end; i++) {
        snprintf(path, sizeof(path),
            "/sys/devices/system/cpu/cpu%d/cpufreq/scaling_min_freq", i);
        write_node(path, min_khz);
        snprintf(path, sizeof(path),
            "/sys/devices/system/cpu/cpu%d/cpufreq/scaling_max_freq", i);
        write_node(path, max_khz);
    }
}

/* sysctl via /proc/sys — avoids forking the sysctl binary */
static void set_sysctl(const char *key, const char *value) {
    char path[128];
    /* convert "vm.swappiness" -> "/proc/sys/vm/swappiness" */
    snprintf(path, sizeof(path), "/proc/sys/");
    size_t base = strlen(path);
    strncpy(path + base, key, sizeof(path) - base - 1);
    for (size_t i = base; i < sizeof(path) && path[i]; i++)
        if (path[i] == '.') path[i] = '/';
    write_node(path, value);
}

int main(int argc, char *argv[]) {
    char profile_buf[32];
    const char *profile;

    if (argc >= 2) {
        profile = argv[1];
    } else {
        profile = read_config(CORTEX "/cpu/profile.txt",
                              profile_buf, sizeof(profile_buf), "gaming");
    }

    if (strcmp(profile, "gaming") == 0) {
        set_governor("performance");
        set_cluster_freq(A55_START, A55_END, "1800000", "2000000");
        set_cluster_freq(A76_START, A76_END, "2000000", "2200000");
        log_fmt("CPU", "gaming profile: performance governor, A55=1.8-2.0GHz, A76=2.0-2.2GHz");

    } else if (strcmp(profile, "balanced") == 0) {
        set_governor("schedutil");
        set_cluster_freq(A55_START, A55_END, "500000", "2000000");
        set_cluster_freq(A76_START, A76_END, "725000", "2200000");
        log_fmt("CPU", "balanced profile: schedutil governor");

    } else if (strcmp(profile, "battery") == 0) {
        set_governor("powersave");
        set_cluster_freq(A55_START, A55_END, "500000", "1200000");
        set_cluster_freq(A76_START, A76_END, "725000", "1500000");
        log_fmt("CPU", "battery profile: powersave governor, reduced clocks");

    } else {
        fprintf(stderr, "[CPU] Unknown profile: %s\n", profile);
        return 1;
    }

    /* VM tuning — same for all profiles, replaces the sysctl calls */
    set_sysctl("vm.swappiness",              "10");
    set_sysctl("vm.vfs_cache_pressure",      "80");
    set_sysctl("vm.dirty_expire_centisecs",  "500");
    set_sysctl("vm.dirty_writeback_centisecs", "3000");

    return 0;
}
