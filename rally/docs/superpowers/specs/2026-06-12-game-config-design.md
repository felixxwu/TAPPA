# Central GameConfig — Design

**Date:** 2026-06-12
**Project:** rally (Godot 4.6, not under git)

## Goal

Move every tunable "magic number" into one Inspector-editable file,
`config/game_config.tres`, so the feel of the whole game can be tuned in one
place. Values apply at startup (no live reload). Behavior must be identical
before and after the refactor — the .tres starts with today's exact values.

## Components

### `scripts/game_config.gd`
`class_name GameConfig extends Resource`. Exported properties with
`@export_group` headers and sensible `@export_range` hints:

| Group | Property | Type | Current value |
|---|---|---|---|
| Car | `mass` | float | 120.0 |
| Car | `engine_force` | float | 1000.0 |
| Car | `brake_force` | float | 6.0 |
| Car | `steer_limit` | float | 0.5 |
| Car | `steer_speed` | float | 5.0 |
| Car | `wheel_friction_slip` | float | 3.0 |
| Car | `suspension_travel` | float | 0.25 |
| Car | `wheel_radius` | float | 0.35 |
| Camera | `follow_distance` | float | 6.0 |
| Camera | `follow_height` | float | 3.0 |
| Camera | `smoothing` | float | 5.0 |
| World | `fog_density` | float | 0.02 |
| World | `background_color` | Color | 0.35, 0.3, 0.45 |
| World | `terrain_tile_per_meter` | float | 0.125 |
| PS1 look | `virtual_resolution` | Vector2 | (640, 480) |
| PS1 look | `chassis_color` | Color | 0.85, 0.2, 0.15 |
| PS1 look | `cabin_color` | Color | 0.25, 0.3, 0.4 |
| PS1 look | `wheel_color` | Color | 0.12, 0.12, 0.12 |

### `config/game_config.tres`
The single file to edit. A `GameConfig` resource instance carrying the values
above. Editable in the Inspector (with groups/sliders) or as plain text.

### `Config` autoload (`scripts/config.gd`)
`extends Node`; loads `res://config/game_config.tres` once into
`var data: GameConfig`. Registered as autoload "Config" in project.godot.
If the .tres is missing or fails to load, push an error and fall back to
`GameConfig.new()` (code defaults = same values), so the game still runs.

### Application points (each owner applies its own values in `_ready()`)
- **`car.gd`**: delete the four constants; read `Config.data` for engine /
  brake / steering each physics frame (cheap property reads) or cache in
  `_ready()`; in `_ready()` also apply `mass`, and per wheel
  `wheel_friction_slip`, `suspension_travel`, `wheel_radius`.
- **`chase_camera.gd`**: replace the three `@export`s with `_ready()` reads
  of `follow_distance` / `follow_height` / `smoothing` into instance vars.
- **`scripts/world.gd`** (new, attached to the Main root node): in
  `_ready()` apply `fog_density` + `background_color` (also fog color) to the
  WorldEnvironment, `terrain_tile_per_meter` to the Floor node's terrain
  script (only when it differs from the current value — the setter triggers a
  full terrain regeneration), `virtual_resolution`
  to the post-process material, and the three car-part colors to the
  chassis/cabin/wheel materials.
- The `.tscn` keeps its current literal values as defaults; runtime config
  wins. (Materials are shared subresources, so setting a shader param once
  applies to all four wheels.)

## Known exceptions (documented, not configurable here)

- Viewport size (640×480), window override, stretch mode: live in
  `project.godot` `[display]` — Godot consumes them before scripts run.
  `virtual_resolution` in the config must be kept matching by hand.
- Shader-internal constants (dither matrix, 5-bit quantization, visual-test
  tolerances): code, not tuning knobs.

## Testing (per CLAUDE.md)

- Smoke: `game_config.tres` loads as a `GameConfig`; spot-check sane ranges
  (engine_force > 0, wheel_radius > 0).
- New `test_config_applied.gd` (headless): instantiate `main.tscn`, after
  ready assert the car's `mass` == config mass, each wheel's
  `wheel_friction_slip` == config value, environment `fog_density` == config
  value, terrain `texture_tile_per_meter` == config value (catches
  "forgot to apply" regressions).
- Existing behavior tests and the visual golden must pass unchanged — the
  config carries today's values, so physics and rendering are identical.

## Out of scope (YAGNI)

- Live reload while running; per-level/per-car config variants; user-facing
  settings menu; persisting changes from in-game.
