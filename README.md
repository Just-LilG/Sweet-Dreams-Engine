# Sweet Dreams // Engine

MediaTek FPS unlocker and thermal bypass engine for KernelSU / Magisk.

**Version:** v2.6.6  
**Author:** Lil G Tech Labs

## Features

- CPU / GPU / scheduler profiles with optional per-cluster clock ceilings
- Per-game render scale via the same Android Game Mode path as [AZenith](https://github.com/Liliya2727/AZenith) (`cmd game set --mode 2 --downscale` on Android 13+, `game_overlay` on older), plus session `wm size` fallback for apps Game Mode ignores
- FPS unlock + refresh-rate lock
- RAM / ZRAM modes, kill-background, game preload
- Battery charge limiter and optional bypass charging
- Touch report-rate / booster, network BBR + DNS, ping stabilizer
- Thermal spoof (Lite / Advanced / Extreme) via bind-mount fake °C. Extreme applies when armed; Lite/Advanced apply in-game. Not a boot-time sensor blackout.
- WebUI settings persist under `/data/adb/sweet_dreams_persist` across zip updates.
- Per-game device identity + CPU info spoof (Zygisk + per-app mount namespace fallback)
- Health / capability / conflict probes
- KernelSU / MMRL WebUI (lavender / vanilla glass) with Info tab and per-game profiles

## Installation

1. Flash the module zip in KernelSU Manager or MMRL.
2. Reboot.
3. Open **WebUI** from the module card. Toggles write under `/data/adb/modules/sweet_dreams/cortex/`.

## Notes

- Thermal override is a **bind-mount spoof** while a selected game is in the foreground. Boot only stops vendor thermal daemons; it does not hide sensors.
- Render scale is armed for **selected Games-tab packages**. Game Mode is preferred; if the ROM ignores it for an app, Sweet Dreams falls back to session `wm size` while that app is foreground.
- Audio latency props apply on game launch. They are vendor-stack hints, not a force of AAudio MMAP for every app.

## Disclaimer

This module changes performance and thermal behavior at your own risk. Use on a rooted device with KernelSU or Magisk. Not affiliated with any game publisher.
