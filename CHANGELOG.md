# Changelog

## GitHub

- **v2.5.38-skipmount** — [download zip](https://github.com/Just-LilG/Sweet-Dreams-Engine/releases/download/v2.5.38-skipmount/SweetDreams-v2_5_38-skipmount.zip)

## v2.5.38-skipmount

- Import the current skipmount module tree (versionCode 288).
- Replace the racing-green WebUI with the lavender / vanilla glass shell and wire it to cortex (`ksu.exec`, real module paths, lite→extreme, RAM `memory_saver`, RR `locked`).
- Apply Android &lt;13 render-scale via `device_config game_overlay` + `cmd game mode 2` (`get_sdk()` was defined but unused).
- Live home / GPU / RAM / kill-bg / audio / health / conflict readouts instead of prototype dummy data.
- CPU Apply honors WebUI cluster max sliders; `cpu/apply.sh` maps little/big from cpufreq policy nodes instead of assuming A55=0–5 / A76=6–7.
- Theme persists in `localStorage` (before first paint) and `cortex/settings/theme.txt`.
- Remaining glass-shell wiring: live CPU/GPU/storage, DNS presets, spoof `cpu=<key>` tags, bypass toggle (no double-flip), daemon restart, settings schedule/smart-charge/spoof-rotate, honest thermal Advanced = extreme blackout.
