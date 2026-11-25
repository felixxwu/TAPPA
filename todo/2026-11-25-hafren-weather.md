# Hafren weather: drifting conditions with a smooth night fade

## Why

The Hafren level (`Scenes.WORLD`, `scripts/level_view.gd`) has no living weather. Free roam's
weather drifted, and its particle and sky cross-fades were good, but its darkening snapped in one
frame. That's because night was never a shader effect: `world.gd::_apply_overcast_look` scaled
`TerrainManager.sun_color`, which is **baked into vertex colours** when a chunk is built, and car,
trees and lakes were re-tinted on the CPU through `GameConfig.weather_lit` / `weather_sun_mult`.
A re-bake can't be animated. Goal: the same drifting weather on Hafren, with everything
(including the darkening) fading smoothly and costing nothing between fades.

## Goals

- Weather drifts on its own every few minutes, picking from a weighted pool: **dry, rain, fog,
  storm, night** (sandstorm and snow aren't drawn).
- Night is a weather (one look). It's never combined with rain or fog.
- **Rain turns into snow while the car is in the snow biome** (`level_streamer.gd` → `snow_at`,
  e.g. `> 0.5`), and back to rain when it leaves. That switch cross-fades like any other change.
- Fog colour, background, fog density, sky affect, panorama **and the world's brightness** all
  cross-fade together over one fade length.
- Dev → "Weather" button (`settings_menu.gd` → `_cycle_dev_weather` / `_refresh_dev_weather`)
  works on Hafren: Auto → each pool condition → Auto.

## Non-goals / anti-goals

- No real day/night clock and no combined conditions (night + rain).
- No terrain re-bake, and no walking materials per frame to dim them. Any per-frame shader work
  outside a fade counts as a failure.
- Don't build on legacy free roam (`BiomeDirector`); leave it working as it is.
- Grip changing instantly when the weather changes is accepted (free roam did the same).

## Approaches considered

- **A. New `LevelWeather` node on the level (chosen).** Owns the drift timer, the rain→snow swap
  and the cross-fade. It reuses the static `BiomeDirector.target_look(cfg, region_id, weather_id,
  base_env)` for the fog/sky/panorama target, and adapts `BiomeDirector._start_fade` /
  `_step_fade` (smoothstep, panorama swapped at mid-fade behind a fog swell).
- B. Reuse `BiomeDirector` directly. Rejected: it's tied to free roam's rings and streamer.
- **Darkening 1 (chosen): global shader uniform `world_light`** (float or vec3, default 1),
  declared in `project.godot` `[shader_globals]` and in `shaders/headlight_cone.gdshaderinc`.
  Every lit shader multiplies its light term by it. The headlight cone stays additive on top, e.g.
  `ALBEDO = surface * (COLOR.rgb * world_light + hl_color * headlight_lit(world))` in
  `level_ground.gdshader`, so the headlights stay bright at night. It's tweened inside the same
  fade: one `RenderingServer.global_shader_parameter_set` per frame during a fade, none between.
- Darkening 2: multiply the whole frame in `ps1_post_process.gdshader`. Rejected: it also dims
  the headlights, the car lamps and the already-dark night sky.

## Design

- **Config** (`scripts/game_config.gd`, next to `level_weather`): `level_weather_pool`
  (e.g. `"dry:4,rain:1,fog:1,storm:1,night:1"`, parsed like `BiomeDirector.parse_pool`),
  `level_weather_hold_s` (180) and `level_weather_fade_s` (4). Those are free roam's current
  `weather_hold_s` / `look_crossfade_s` values.
- **`scripts/level_weather.gd`** (`class_name LevelWeather`), added by `level_view.gd` where
  `apply_weather(Config.data.level_weather)` is called today. It counts drive time and, each hold
  slot, draws from the pool with a seeded RNG (the free-roam `weather_for` pattern). It applies
  the rain→snow swap, honours `forced_weather`, and calls `LevelView.apply_weather(id)` (particles,
  wind, headlights, `cfg.weather`) and then starts the fade. `level_weather` becomes the starting
  condition.
- **Brightness target** = the look's `sun_mult` (`target_look` already returns it). On the
  level, `weather_sun_mult` stays at 1.0 so nothing dims twice. `world_light` is the only
  dimming path there.
- **Shaders:** add `world_light` to every 3D shader the level draws. Shaders already including
  `headlight_cone.gdshaderinc` get it from there. Ones that don't (e.g. `level_tree.gdshader`,
  `log_pile.gdshader`, `billboard_*`) declare it directly. The rule: every surface dims exactly
  once. Extend `tests/headless/test_lighting_coverage.gd` so a 3D shader that doesn't reference
  `world_light` fails, like the cone rule does.
- **Reset:** `level_view.gd`'s exit path (where `HeadlightCone.reset()` runs) and
  `world.gd::_exit_tree` set `world_light` back to 1, because shader globals persist across
  scenes.
- **Dev button:** `settings_menu.gd` finds the `LevelWeather` node when there's no
  `BiomeDirector`, cycles `""` + the pool's ids, and applies the change at once (with a fade).

## Left to the builder

- Whether `world_light` is a float or a vec3. A vec3 lets night tint slightly blue; float is fine
  if nothing needs the tint.
- The exact snow threshold and the seed source.
- Whether CPU-tinted particles (`wheel_particles.gd`, `engine_smoke.gd`) take `world_light` in
  their shader or keep `weather_lit`, as long as they dim exactly once.
- Docs: `features/weather.md` (new "Hafren" section and the `world_light` rule replacing
  `weather_lit` on the level), `features/level-editor.md`, `features/rendering.md`.
- Tests (no tuning values): the drift is deterministic per seed and slot; rain becomes snow inside
  the snow biome; a fade reaches its target and stops writing; the Dev button cycles on Hafren;
  the lighting-coverage rule.
