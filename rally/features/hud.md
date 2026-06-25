# HUD

**Source:** `scripts/hud.gd` (extends `CanvasLayer`). Node `HUD` (layer 2) in
`main.tscn`, with `car` wired to the `Car`.

On-screen readout plus two interactive mode buttons.

## Elements

| Node | Shows | Source |
|------|-------|--------|
| `SpeedLabel` | `"<n> km/h"` | `car.linear_velocity.length() * 3.6` |
| `GearLabel` | `R` / `N` / `1`–`5` | `engine.gear` via `_gear_text()` |
| `RPMLabel` | `"<n> rpm"` | `engine.rpm()` |
| `ModeButton` | `MANUAL` / `AUTO` | `engine.auto` (clickable) |
| `DriveButton` | `RWD` / `AWD` / `FWD` | `drivetrain.drive_mode` (clickable) |
| `VersionLabel` | `"v0.<n> (<sha>)"` | `application/config/version` (read once) |

## Behavior

- `_ready()` — sets visibility from `cfg.hud_enabled`, connects button signals,
  and stamps `VersionLabel` from `application/config/version` (set once; static).
- `_on_mode_pressed()` — toggles `engine.auto` (same as pressing **T**).
- `_on_drive_pressed()` — cycles drive mode (same as pressing **Y**).
- `_process(delta)` — refreshes labels each frame.
- `_gear_text(gear)` — formats -1→`R`, 0→`N`, else the number.

## Layout

Labels/buttons are direct children of the `HUD` CanvasLayer, positioned via
`offset_*` with explicit `font_size` overrides. All sizes are deliberately
small (font 14 for labels, 10 for buttons) — the HUD is rendered at 1/2 scale.

The `VersionLabel` is anchored to the top-right (`anchor_left/right = 1.0`,
`grow_horizontal = 0`, `horizontal_alignment = 2`) so it sits in that corner
regardless of viewport width. The track-progress `ProgressLabel` sits below the
`ModeButton`/`DriveButton`/`CarButton` stack (`offset_top = 92`) so the
transmission/drive switchers don't obscure it.

## Build version

`VersionLabel` displays the build version, derived automatically as
`0.<git commit count>` with the short SHA appended (e.g. `v0.61 (b154d5c)`).
`build_web.sh` computes this from git and stamps it into
`application/config/version` in `project.godot` for the duration of the export
(reverting the file afterwards), so it is baked into the web `.pck`. Editor and
test runs fall back to the committed default `config/version="0.0-dev"`.

## Related config

`hud_enabled`. See [configuration.md](configuration.md).
