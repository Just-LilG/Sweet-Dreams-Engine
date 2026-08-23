# Changelog

## v2.5.38-skipmount

- Import the current skipmount module tree (versionCode 288).
- Replace the racing-green WebUI with the lavender / vanilla glass shell and wire it to cortex (`ksu.exec`, real module paths, lite→extreme, RAM `memory_saver`, RR `locked`).
- Apply Android &lt;13 render-scale via `device_config game_overlay` + `cmd game mode 2` (`get_sdk()` was defined but unused).
- Live home / GPU / RAM / kill-bg / audio / health / conflict readouts instead of prototype dummy data.
- CPU Apply honors WebUI cluster max sliders; Reset restores balanced + default ceilings.
- Theme persists in `localStorage` (before first paint) and `cortex/settings/theme.txt`.
