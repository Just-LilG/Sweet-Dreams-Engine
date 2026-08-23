#pragma once
/* sd_util.h — Sweet Dreams shared utilities
 * Included by every binary. No malloc, no heap, everything on the stack.
 * Designed for Android root shell context: no libc niceties, no dynamic
 * linking required if compiled with -static.
 */

#include <fcntl.h>
#include <ftw.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <errno.h>

#define MODDIR  "/data/adb/modules/sweet_dreams"
#define CORTEX  MODDIR "/cortex"
#define LOGFILE MODDIR "/boot.log"

/* ── write_node ──────────────────────────────────────────────────────────────
 * Write a string to a sysfs/proc node. Returns 1 on success, 0 on failure.
 * Silent on failure — nodes that don't exist on this kernel are expected.
 */
static inline int write_node(const char *path, const char *value) {
    int fd = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    ssize_t len = (ssize_t)strlen(value);
    int ok = (write(fd, value, (size_t)len) == len);
    close(fd);
    return ok;
}

/* ── write_node_fmt ──────────────────────────────────────────────────────────
 * write_node with printf-style value formatting.
 */
static inline int write_node_fmt(const char *path, const char *fmt, ...) {
    char buf[64];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    return write_node(path, buf);
}

/* ── read_config ─────────────────────────────────────────────────────────────
 * Read first line of a config file into buf (max len bytes).
 * Returns buf on success, fallback on failure. Strips trailing newline.
 */
static inline const char *read_config(const char *path, char *buf, size_t len,
                                       const char *fallback) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        strncpy(buf, fallback, len - 1);
        buf[len - 1] = '\0';
        return buf;
    }
    ssize_t n = read(fd, buf, len - 1);
    close(fd);
    if (n <= 0) {
        strncpy(buf, fallback, len - 1);
        buf[len - 1] = '\0';
        return buf;
    }
    buf[n] = '\0';
    /* strip trailing newline */
    char *nl = strchr(buf, '\n');
    if (nl) *nl = '\0';
    return buf;
}

/* ── write_config ────────────────────────────────────────────────────────────
 * Write a string to a module config/status file.
 */
static inline int write_config(const char *path, const char *value) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return 0;
    ssize_t len = (ssize_t)strlen(value);
    int ok = (write(fd, value, (size_t)len) == len);
    close(fd);
    return ok;
}

/* ── node_exists ─────────────────────────────────────────────────────────────
 * Returns 1 if path exists and is a regular file.
 */
static inline int node_exists(const char *path) {
    struct stat st;
    return (stat(path, &st) == 0 && S_ISREG(st.st_mode));
}

/* ── node_writable ───────────────────────────────────────────────────────────
 * Returns 1 if path exists and is writable.
 */
static inline int node_writable(const char *path) {
    return (access(path, W_OK) == 0);
}

/* ── log_msg ─────────────────────────────────────────────────────────────────
 * Append a timestamped line to boot.log. Non-fatal if log unavailable.
 */
static inline void log_msg(const char *tag, const char *msg) {
    FILE *f = fopen(LOGFILE, "a");
    if (!f) return;
    fprintf(f, "[%s] %s\n", tag, msg);
    fclose(f);
}

static inline void log_fmt(const char *tag, const char *fmt, ...) {
    char buf[256];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    log_msg(tag, buf);
}

/* ── exec_resetprop ──────────────────────────────────────────────────────────
 * Set an Android property via resetprop. Falls back to setprop.
 * resetprop is always at a known path in Magisk/KernelSU context.
 */
static inline void exec_resetprop(const char *key, const char *value) {
    pid_t pid = fork();
    if (pid == 0) {
        execl("/system/bin/resetprop", "resetprop", key, value, (char *)NULL);
        execl("/data/adb/magisk/resetprop", "resetprop", key, value, (char *)NULL);
        _exit(1);
    } else if (pid > 0) {
        int status;
        waitpid(pid, &status, 0);
    }
}
/* missing waitpid include */
