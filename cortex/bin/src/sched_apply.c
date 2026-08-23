/* sched_apply.c — Sweet Dreams scheduler tuning
 * Replaces cortex/sched/apply.sh
 * Usage: sched_apply
 */

#include "sd_util.h"

static void set_sysctl(const char *key, const char *value) {
    char path[128];
    snprintf(path, sizeof(path), "/proc/sys/");
    size_t base = strlen(path);
    strncpy(path + base, key, sizeof(path) - base - 1);
    for (size_t i = base; i < sizeof(path) && path[i]; i++)
        if (path[i] == '.') path[i] = '/';
    write_node(path, value);
}

int main(void) {
    /* Scheduler latency tuning — same values as the shell script */
    set_sysctl("kernel.sched_latency_ns",                 "1000000");
    set_sysctl("kernel.sched_wakeup_granularity_ns",      "500000");
    set_sysctl("kernel.sched_migration_cost_ns",          "500000");
    set_sysctl("kernel.sched_nr_migrate",                 "64");
    set_sysctl("kernel.sched_min_task_util_for_colocation","0");
    set_sysctl("kernel.sched_min_task_util_for_boost",    "0");

    /* cpuset topology — give top-app all cores */
    write_node("/dev/cpuset/top-app/cpus",           "0-7");
    write_node("/dev/cpuset/foreground/cpus",         "0-7");
    write_node("/dev/cpuset/background/cpus",         "0-3");
    write_node("/dev/cpuset/system-background/cpus",  "0-3");

    /* perf_event_paranoid — 1 = allow user perf events (helps game profilers) */
    write_node("/proc/sys/kernel/perf_event_paranoid", "1");

    log_msg("SCHED", "Scheduler tuning applied");
    return 0;
}
