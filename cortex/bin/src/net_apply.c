/* net_apply.c — Sweet Dreams network tuning
 * Replaces cortex/net/apply.sh
 * Usage: net_apply [game_start|game_end]
 *        (no arg = boot/toggle)
 *
 * All sysctl writes go directly to /proc/sys/ — no fork of the sysctl
 * binary. DNS and settings writes still exec child processes since those
 * require Binder/content-provider paths, but that's unavoidable.
 */

#include "sd_util.h"
#include <stdio.h>

#define SAVED_FILE CORTEX "/net/saved_values.txt"

/* ── sysctl write via /proc/sys ──────────────────────────────────────────── */
static void sc(const char *key, const char *value) {
    char path[128];
    snprintf(path, sizeof(path), "/proc/sys/");
    size_t base = strlen(path);
    strncpy(path + base, key, sizeof(path) - base - 1);
    for (size_t i = base; i < sizeof(path) && path[i]; i++)
        if (path[i] == '.') path[i] = '/';
    write_node(path, value);
}

/* ── read a /proc/sys node value into buf ─────────────────────────────────── */
static int sc_read(const char *key, char *buf, size_t len) {
    char path[128];
    snprintf(path, sizeof(path), "/proc/sys/");
    size_t base = strlen(path);
    strncpy(path + base, key, sizeof(path) - base - 1);
    for (size_t i = base; i < sizeof(path) && path[i]; i++)
        if (path[i] == '.') path[i] = '/';
    return (int)(read_config(path, buf, len, "") != NULL &&
                 buf[0] != '\0');
}

/* ── save current values for restore ─────────────────────────────────────── */
static const char *SAVE_KEYS[] = {
    "net.ipv4.tcp_congestion_control",
    "net.ipv4.tcp_low_latency",
    "net.ipv4.tcp_slow_start_after_idle",
    "net.ipv4.tcp_rmem",
    "net.ipv4.tcp_wmem",
    "net.core.rmem_max",
    "net.core.wmem_max",
    "net.core.rmem_default",
    "net.core.wmem_default",
    "net.core.netdev_max_backlog",
    "net.ipv4.tcp_fastopen",
    "net.ipv4.tcp_no_metrics_save",
    "net.ipv4.udp_rmem_min",
    "net.ipv4.udp_wmem_min",
    NULL
};

static void save_current(void) {
    int fd = open(SAVED_FILE, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return;
    char val[256];
    for (int i = 0; SAVE_KEYS[i]; i++) {
        if (sc_read(SAVE_KEYS[i], val, sizeof(val))) {
            char line[384];
            snprintf(line, sizeof(line), "%s=%s\n", SAVE_KEYS[i], val);
            write(fd, line, strlen(line));
        }
    }
    close(fd);
}

static void restore_saved(void) {
    FILE *f = fopen(SAVED_FILE, "r");
    if (!f) return;
    char line[384];
    while (fgets(line, sizeof(line), f)) {
        char *eq = strchr(line, '=');
        if (!eq) continue;
        *eq = '\0';
        char *val = eq + 1;
        /* strip trailing newline */
        char *nl = strchr(val, '\n');
        if (nl) *nl = '\0';
        sc(line, val);
    }
    fclose(f);
    log_msg("NET", "Values restored from snapshot");
}

/* ── read available CC algorithms from kernel ─────────────────────────────── */
static int cc_available(const char *cc) {
    char avail[256];
    sc_read("net.ipv4.tcp_available_congestion_control", avail, sizeof(avail));
    /* simple substring search — cc names don't overlap (bbr, cubic, westwood) */
    return (strstr(avail, cc) != NULL);
}

static void apply_cc(const char *target) {
    const char *fallbacks[] = {"bbr", "westwood", "cubic", NULL};
    if (cc_available(target)) {
        sc("net.ipv4.tcp_congestion_control", target);
        log_fmt("NET", "CC: %s", target);
        return;
    }
    for (int i = 0; fallbacks[i]; i++) {
        if (cc_available(fallbacks[i])) {
            sc("net.ipv4.tcp_congestion_control", fallbacks[i]);
            log_fmt("NET", "CC: %s unavailable, using %s", target, fallbacks[i]);
            return;
        }
    }
}

static void apply_base_tuning(const char *cc) {
    apply_cc(cc);
    sc("net.ipv4.tcp_low_latency",           "1");
    sc("net.ipv4.tcp_no_metrics_save",       "1");
    sc("net.ipv4.tcp_timestamps",            "0");
    sc("net.ipv4.tcp_sack",                  "1");
    sc("net.ipv4.tcp_fastopen",              "3");
    sc("net.ipv4.tcp_mtu_probing",           "1");
    sc("net.ipv4.tcp_slow_start_after_idle", "0");
    sc("net.ipv4.tcp_rmem",                  "4096 87380 16777216");
    sc("net.ipv4.tcp_wmem",                  "4096 65536 16777216");
    sc("net.ipv4.udp_rmem_min",              "16384");
    sc("net.ipv4.udp_wmem_min",              "16384");
    sc("net.core.rmem_max",                  "16777216");
    sc("net.core.wmem_max",                  "16777216");
    sc("net.core.rmem_default",              "262144");
    sc("net.core.wmem_default",              "262144");
    sc("net.core.netdev_max_backlog",        "5000");
    sc("net.core.optmem_max",               "65536");
    sc("net.core.netdev_budget",             "600");
    sc("net.core.netdev_budget_usecs",       "8000");
    log_msg("NET", "Base TCP/UDP tuning applied");
}

static void apply_game_tuning(void) {
    apply_cc("bbr");
    sc("net.ipv4.udp_rmem_min",              "32768");
    sc("net.ipv4.udp_wmem_min",              "32768");
    sc("net.core.rmem_max",                  "33554432");
    sc("net.core.wmem_max",                  "33554432");
    sc("net.core.rmem_default",              "524288");
    sc("net.core.wmem_default",              "524288");
    sc("net.ipv4.tcp_slow_start_after_idle", "0");
    sc("net.core.netdev_budget",             "1000");
    sc("net.core.netdev_budget_usecs",       "4000");
    log_msg("NET", "Game network tuning active (UDP boosted, BBR)");
}

/* exec a child and wait — for DNS commands that require Binder */
static void run_cmd(const char *cmd, char *const argv[]) {
    pid_t pid = fork();
    if (pid == 0) {
        execv(cmd, argv);
        _exit(1);
    } else if (pid > 0) {
        int status;
        waitpid(pid, &status, 0);
    }
}

int main(int argc, char *argv[]) {
    const char *phase = (argc >= 2) ? argv[1] : "";

    char status_buf[8], cc_buf[32];
    read_config(CORTEX "/net/status.txt",      status_buf, sizeof(status_buf), "on");
    read_config(CORTEX "/net/congestion.txt",  cc_buf,     sizeof(cc_buf),     "bbr");

    if (strcmp(phase, "game_end") == 0) {
        restore_saved();
        log_msg("NET", "Game network tuning released");
        return 0;
    }

    if (strcmp(phase, "game_start") == 0) {
        if (strcmp(status_buf, "on") != 0) return 0;
        save_current();
        apply_game_tuning();
        return 0;
    }

    /* Boot / toggle */
    if (strcmp(status_buf, "on") != 0) {
        log_msg("NET", "Network boost off — defaults");
        return 0;
    }
    save_current();
    apply_base_tuning(cc_buf);

    /* Write live status for WebUI */
    char cur_cc[32] = "—";
    sc_read("net.ipv4.tcp_congestion_control", cur_cc, sizeof(cur_cc));
    char avail_cc[256] = "—";
    sc_read("net.ipv4.tcp_available_congestion_control", avail_cc, sizeof(avail_cc));

    char dns_mode[16], dns1[64], dns2[64];
    read_config(CORTEX "/net/dns_mode.txt", dns_mode, sizeof(dns_mode), "off");
    read_config(CORTEX "/net/dns1.txt",     dns1,     sizeof(dns1),     "1.1.1.1");
    read_config(CORTEX "/net/dns2.txt",     dns2,     sizeof(dns2),     "1.0.0.1");

    char live[512];
    snprintf(live, sizeof(live), "%s|%s|%s|%s|%s|%s",
             status_buf, cur_cc, avail_cc, dns_mode, dns1, dns2);
    write_config(CORTEX "/net/status_live.txt", live);

    return 0;
}
