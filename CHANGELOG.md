# Changelog

## GitHub

- **v2.5.40-skipmount** (pre-release) — [download zip](https://github.com/Just-LilG/Sweet-Dreams-Engine/releases/download/v2.5.40-skipmount/SweetDreams-v2_5_40-skipmount.zip)
- **v2.5.39-skipmount** (pre-release) — [download zip](https://github.com/Just-LilG/Sweet-Dreams-Engine/releases/download/v2.5.39-skipmount/SweetDreams-v2_5_39-skipmount.zip)
- **v2.5.38-skipmount** (pre-release) — [download zip](https://github.com/Just-LilG/Sweet-Dreams-Engine/releases/download/v2.5.38-skipmount/SweetDreams-v2_5_38-skipmount.zip)

## v2.5.40-skipmount

- Health WebUI reads `cortex/health/*.status` (the files apply scripts actually write).
- Thermal language: `armed.txt` (`armed`/`off`) with `status.txt` still written for older scripts.
- Games tab: launcher labels, icons when extractable, name search; likely-game filter instead of every user app.
- Thermal apply writes `last_verify.txt` (OS-seen zone temps vs spoof °C) and `APPLY_RESULT`.
- Optional per-game spoof °C (`cortex/games/<pkg>.spoof_c`) via session file.
- `game_monitor` session log; spoof master no longer kills a live controller just to toggle.
- Home: status pills + Games/Thermal/Spoof shortcuts; the rest sits under Tune.
- Confirm dialogs for Advanced thermal, spoof master, and kill-background.
- Logs: boot / game session / thermal verify sources.
- Empty compat / preload / sensor home rows stay hidden until they have data.
- Profile cards run CPU + GPU + scheduler (+ perf if on) in one shot.

## GitHub

- **v2.5.39-skipmount** (pre-release) — [download zip](https://github.com/Just-LilG/Sweet-Dreams-Engine/releases/download/v2.5.39-skipmount/SweetDreams-v2_5_39-skipmount.zip)
- **v2.5.38-skipmount** (pre-release) — [download zip](https://github.com/Just-LilG/Sweet-Dreams-Engine/releases/download/v2.5.38-skipmount/SweetDreams-v2_5_38-skipmount.zip)

## v2.5.39-skipmount

- Thermal engine: restore the previous-release bind-mount spoof (OS reads a fake °C) instead of chmod-000 blackout.
- Thermal Advanced: slider to set the spoofed sensor value (0–45°C, default 27°C like the last public zip). Lite still only spoofs CPU/GPU/board zones.

## v2.5.38-skipmount

- Import the current skipmount module tree (versionCode 288).
- Replace the racing-green WebUI with the lavender / vanilla glass shell and wire it to cortex (`ksu.exec`, real module paths, lite→extreme, RAM `memory_saver`, RR `locked`).
- Apply Android &lt;13 render-scale via `device_config game_overlay` + `cmd game mode 2` (`get_sdk()` was defined but unused).
- Live home / GPU / RAM / kill-bg / audio / health / conflict readouts instead of prototype dummy data.
- CPU Apply honors WebUI cluster max sliders; `cpu/apply.sh` maps little/big from cpufreq policy nodes instead of assuming A55=0–5 / A76=6–7.
- Theme persists in `localStorage` (before first paint) and `cortex/settings/theme.txt`.
- Remaining glass-shell wiring: live CPU/GPU/storage, DNS presets, spoof `cpu=<key>` tags, bypass toggle (no double-flip), daemon restart, settings schedule/smart-charge/spoof-rotate.
