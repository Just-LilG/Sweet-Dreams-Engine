# Sweet Dreams // Engine

MediaTek FPS unlocker and thermal bypass engine for KernelSU / Magisk.

**Version:** v2.5.38-skipmount  
**Author:** Lil G Tech Labs

## Features

- CPU / GPU / scheduler profiles with optional per-cluster clock ceilings
- Per-game render scale via Android Game Mode (Android 13+) or `game_overlay` (Android 12 and older)
- FPS unlock + refresh-rate lock
- RAM / ZRAM modes, kill-background, game preload
- Battery charge limiter and optional bypass charging
- Touch report-rate / booster, network BBR + DNS, ping stabilizer
- Thermal spoof armed at rest, applied in-game only (lite / extreme)
- Per-game device identity spoof (Zygisk + prop hook)
- Health / capability / conflict probes
- KernelSU / MMRL WebUI (lavender / vanilla glass)

## Installation

1. Flash the module zip in KernelSU Manager or MMRL.
2. Reboot.
3. Open **WebUI** from the module card. Toggles write under `/data/adb/modules/sweet_dreams/cortex/`.

## Notes

- Thermal blackout is **not** applied at boot. Boot only stops thermal daemons; sensor override runs when a selected game is in the foreground.
- Render scale is **per selected game**, not a global `wm size`.
- Audio latency props apply on game launch. They are vendor-stack hints, not a force of AAudio MMAP for every app.

## Disclaimer

This module changes performance and thermal behavior at your own risk. Use on a rooted device with KernelSU or Magisk. Not affiliated with any game publisher.
