export const MOD_ROOT = '/data/adb/modules/sweet_dreams';
export const CORTEX   = `${MOD_ROOT}/cortex`;
export const SYSBIN   = `${MOD_ROOT}/system/bin`;
export const FRPERF   = '/data/local/tmp/Frieren_Perf';

export const FILES = {
    prop:          `${MOD_ROOT}/module.prop`,
    profile:       `${CORTEX}/cpu/profile.txt`,
    thermalArmed: `${CORTEX}/thermal/armed.txt`,
    touchStatus:   `${CORTEX}/touch/status.txt`,
    netStatus:     `${CORTEX}/net/status.txt`,
    thermalApply:  `${CORTEX}/thermal/apply.sh`,
    cpuApply:      `${CORTEX}/cpu/apply.sh`,
    gpuApply:      `${CORTEX}/gpu/apply.sh`,
    touchApply:    `${CORTEX}/touch/apply.sh`,
    netApply:      `${CORTEX}/net/apply.sh`,
    schedApply:    `${CORTEX}/sched/apply.sh`,
    bootLog:       `${MOD_ROOT}/boot.log`,
};
