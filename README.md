# Sweet Dreams // Engine

MediaTek FPS unlocker and thermal bypass engine for KernelSU / Magisk.

**Version:** v2.5.40-skipmount  
**Author:** Lil G Tech Labs

## Features

- CPU / GPU / scheduler profiles with optional per-cluster clock ceilings
- Per-game render scale via Android Game Mode (Android 13+) or `game_overlay` (Android 12 and older)
- FPS unlock + refresh-rate lock
- RAM / ZRAM modes, kill-background, game preload
- Battery charge limiter and optional bypass charging
- Touch report-rate / booster, network BBR + DNS, ping stabilizer
- Thermal spoof armed at rest (`armed.txt`), applied in-game only via bind-mount fake °C (lite / advanced). Not a boot-time sensor blackout.
- Per-game device identity spoof (Zygisk + prop hook)
- Health / capability / conflict probes
- KernelSU / MMRL WebUI (lavender / vanilla glass)

## Installation

1. Flash the module zip in KernelSU Manager or MMRL.
2. Reboot.
3. Open **WebUI** from the module card. Toggles write under `/data/adb/modules/sweet_dreams/cortex/`.

## Notes

- Thermal override is a **bind-mount spoof** while a selected game is in the foreground. Boot only stops vendor thermal daemons; it does not hide sensors.
- Render scale is **per selected game**, not a global `wm size`.
- Audio latency props apply on game launch. They are vendor-stack hints, not a force of AAudio MMAP for every app.

## Disclaimer

This module changes performance and thermal behavior at your own risk. Use on a rooted device with KernelSU or Magisk. Not affiliated with any game publisher.
