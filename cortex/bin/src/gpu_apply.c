/* gpu_apply.c — Sweet Dreams GPU tuning
 * Replaces cortex/gpu/apply.sh (Mali-G57 MC2 / Valhall)
 * Usage: gpu_apply [gaming|balanced|battery]
 *        (reads cortex/cpu/profile.txt if no arg given)
 */

#include "sd_util.h"

/* Known governor sysfs paths for Mali on MTK — tried in order, first hit wins */
static const char *GOV_PATHS[] = {
    "/sys/class/misc/mali0/device/devfreq/mali0/governor",
    "/sys/kernel/gpu/gpu_governor",
    "/sys/class/devfreq/gpufreq/governor",
    "/sys/devices/platform/mali.0/devfreq/mali.0/governor",
    NULL
};

/* Glob-style: the middle component may vary (e.g. mali0, 13000000.mali) */
static const char *GOV_GLOB_DIRS[] = {
    "/sys/class/misc/mali0/device/devfreq/",
    NULL
};

static int try_write_governor(const char *gov) {
    /* Try exact paths first */
    for (int i = 0; GOV_PATHS[i]; i++) {
        if (write_node(GOV_PATHS[i], gov)) return 1;
    }
    return 0;
}

static void set_gpu_governor(const char *primary,
                              const char *fallback1,
                              const char *fallback2) {
    if (try_write_governor(primary))   return;
    if (fallback1 && try_write_governor(fallback1)) return;
    if (fallback2 && try_write_governor(fallback2)) return;
    log_fmt("GPU", "no writable governor node found (normal if GPU not in devfreq)");
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
        set_gpu_governor("performance", NULL, NULL);
        log_fmt("GPU", "gaming: performance governor");

    } else if (strcmp(profile, "balanced") == 0) {
        /* mali_ondemand (G57 native) → simple_ondemand → coarse_demand */
        set_gpu_governor("mali_ondemand", "simple_ondemand", "coarse_demand");
        log_fmt("GPU", "balanced: adaptive governor");

    } else if (strcmp(profile, "battery") == 0) {
        set_gpu_governor("powersave", "simple_ondemand", NULL);
        log_fmt("GPU", "battery: powersave governor");

    } else {
        /* Unknown — fall back to adaptive */
        set_gpu_governor("mali_ondemand", "simple_ondemand", NULL);
        log_fmt("GPU", "unknown profile '%s', defaulting to adaptive", profile);
    }

    return 0;
}
