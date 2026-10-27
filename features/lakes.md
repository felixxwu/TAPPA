# Lakes

**Source:** `scripts/lake_field.gd` (`LakeField`), `scripts/track_gen_params.gd`
(`TrackGenParams`), `scripts/terrain_noise.gd` (`TerrainNoise`),
`shaders/water.gdshader`, plus water-avoidance in `scripts/track_generator.gd`
and wiring in `scripts/world.gd` / `scripts/car.gd`.

**Tests:** `tests/headless/test_lake_field.gd`, `tests/headless/test_lakes_integration.gd`

Lakes are water pooled in the natural terrain basins beside the road, up to an
**authored water level** (`cfg.track_water_level_m`). The road is guaranteed never to run into water
because the track-layout DFS treats below-water cells as obstacles and routes
around them. Water is a **soft hazard** — the car gets extra drag but can drive
out (no reset). 

## Two orthogonal per-event knobs

- **`seed`** (`track_seed`) — carves the terrain landscape *and* routes the road.
  The terrain `noise_seed` is now driven from `track_seed` (world.gd, where layers
  sync to `$Floor`), so each event has its own landscape + lake layout. Because the
  road DFS does not read terrain when water is off, this changes only the visible
  elevation for water-off events, **not** the road shape or opponent times.
- **`water_level`** (`cfg.track_water_level_m`) — the world-Y flood height poured into
  whatever basins the seed produced. Independent of the seed. Higher = more/bigger lakes
  in the same valleys. `TrackGenParams.for_config` reads it straight from the config.

## `TrackGenParams` — the shape contract

`TrackGenerator.generate(params: TrackGenParams, on_progress)` takes a single
params object; there is no positional form. `TrackGenParams` holds **every**
determinant of the generated shape (`seed, turn_count, width, clearance,
reserve_behind, straightness, runoff_m, water_enabled, water_level,
shore_clearance, origin, heading, base_origin, water_sampler`) and is built only
via factories that require a water decision:

- `for_config(cfg)` — builds params straight from `cfg.track_*`.

You can't generate a shape without a water level: every `generate()` call builds its params
from `for_config`, so the shape contract can't drift.

### Why this matters (shape-determinism invariant)

Water is sampled at **world-absolute** coordinates, so the generated shape now
depends on `water_level` **and** the world origin (previously it was
pose-independent). Rules that keep the shape deterministic:

0. **The terrain seed the game actually bakes must equal `params.seed`.** `$Floor` (and
   everything `bake_track` samples to write `road_heights`) is seeded from `cfg.track_seed`,
   which is also what `for_config` reads, so the road is avoided-around-water on the same
   landscape it is baked on.
1. `water_level` is a shape parameter — carried in `TrackGenParams`, so every
   `generate()` carries it (like `straightness`).
3. The dry-start origin is computed once (in `TrackGenParams.recompute_origin`) and
   shared by both.
4. The water sampler is a **pure, headless** function of `(seed, terrain_layers)`
   (`TerrainNoise.make_sampler`) — never a live `TerrainManager` (whose cached grid
   carries road-flatten + cliff offsets by then).
5. Contrast with cliffs (`apply_cliffs`), which are applied *after* generation and
   do **not** feed target derivation. Water is the opposite.

## Road avoidance + dry start

- **Avoidance:** `TrackGenerator._collide_and_cells` rejects any footprint cell
  whose `water_sampler(centre) < water_level + shore_clearance`, treating it like an
  occupied cell so the DFS backtracks. Runoff avoidance is free (same helper). When
  `water_enabled` is false the branch is skipped and behaviour is byte-identical to
  before lakes.
- **Dry start:** the start pose + lead-in + runoff are not DFS candidates.
  `TrackGenParams.recompute_origin` runs a deterministic outward-spiral search
  (pure in `(seed, water_level)`) for a start position whose start pad + lead-in sit
  above `water_level + shore_clearance`. If it relocates the origin, `world.gd`
  translates the car + every start-anchored prop (lead-in, arches, spectators,
  `TrackProgress`) by the same delta (`origin − base_origin`) — heading is
  preserved, so it's a pure translation. If no dry origin is found in budget, it
  clamps the water level below the start (then disables water) as a fallback.
- **`params` is the source of truth for water, and `world.gd` reconciles the config
  to it.** Because that fallback can lower `water_level` (or clear `water_enabled`)
  *after* the config was seated, `world.gd::_generate_track` copies
  `params.water_enabled` / `params.water_level` back onto `cfg` once the shape is
  final (after the challenge-retry branch, which can swap in differently-clamped
  params). Everything downstream reads the config rather than `params` — the
  rendered/collided lake (`_build_lakes`), the chase camera's ground seat
  (`chase_camera.gd::_ground_height_at`), the submersion reset
  (`track_progress.gd`) — so skipping this makes them all use a waterline the
  terrain doesn't have: the lake disagrees with the loading preview (which reads
  `params` directly, via `LakeField.preview_cells`), and the camera lifts off the
  chase view over a basin it wrongly believes is flooded. Guarded by
  `test_world_water_reconcile`.

## LakeField (build + render + hazard)

Built in `world.gd._build_lakes` after foliage when `cfg.water_enabled`:

- **One flat plane, no flood-fill.** `LakeField.build` adds a single 10 km
  `PlaneMesh` (`LakeField.SPAN`) at `y = water_level`, centred on the origin (so it
  covers any stage without following the car). Wherever terrain sits below the level
  the plane shows through; higher terrain **occludes it via the depth test** — so
  there's no per-lake geometry and no flood-fill (this replaced an earlier basin
  flood-fill; the depth test does the shape work for free). 1 draw call, 2 triangles.
- **Shader** (`shaders/water.gdshader`): `unshaded`, **flat and opaque** (a solid PS1
  colour block; a screen-door dither read as noise against the low-res pixelation),
  no `hint_screen_texture` read (preserving the Compatibility no-backbuffer choice;
  see [rendering.md](rendering.md)). A **seamless (tileable) 128x128 noise texture**
  (`textures/water_noise.png`, `LakeField.WATER_TEX`) is scrolled in two directions
  for visible movement, tinted between deep/shore colours, with a sparkle glint.
- **The water dims with the weather.** The shader is `unshaded` and takes an
  authored colour straight to `ALBEDO`, so nothing dims for free: `LakeField.build`
  passes both `water_color` and `shore_color` (and their `ice_*` counterparts)
  through `GameConfig.weather_lit`, and scales `sparkle_strength` by
  `weather_sun_mult` — the sparkle is a *sun* glint, and a full-strength band on an
  otherwise dark lake reads as light from a sun that isn't there. Without this a
  lake rendered full daylight blue at night and was the brightest thing on screen.
  `weather_lit` preserves alpha on purpose: the water colours carry meaningful
  alpha, and scaling it would make a dim lake *transparent* rather than *dark*.
  See [weather.md](weather.md) → "Unshaded means nothing dims for free".
- **The water tile is a committed asset, not baked at load.** It used to be a
  `NoiseTexture2D` built by `LakeField._make_water_texture` on every stage load.
  `NoiseTexture2D` bakes on a *worker thread* — but the web export ships
  `variant/thread_support = false`, so on web there is no worker and the bake ran on
  the main loop; `seamless = true` makes Godot generate and cross-blend a larger
  buffer (~4x the samples), which is why "filling lakes" measured ~1121 ms on web vs
  ~14 ms native. The tile is seed-independent, so it's pre-baked and committed
  (import: lossy, `lossy_quality` 1.0, mipmaps on, `detect_3d/compress_to` disabled so
  3D use can't silently flip it to VRAM compression) and `preload`ed alongside the
  shader. General lesson: **engine APIs with implicit threading silently degrade on
  web** — check for one before assuming an async bake is free. To regenerate, bake a
  `NoiseTexture2D` with the settings recorded in `lake_field.gd` and save its image
  over the asset.
- **Hazard:** the "in water" query is a **direct terrain-height check** — `world.gd`
  wires `car.gd`'s `set_water_query` to `floor.height_at(x,z) < water_level`.
  `_apply_aero` adds `cfg.water_drag` linear drag while in water. No reset — the car
  can drive out.
- **Props stay dry:** `world.gd._drop_submerged` filters tree, bush, and spectator
  scatter positions, dropping any whose terrain is below `water_level`.
- **Previews:** `LakeField.submerged_cells(sampler, level, bounds, step)` is a pure
  static helper that marks below-water ground (no scene/terrain needed).

## Config (`GameConfig` "Water" group)

`water_enabled`, `track_water_level_m`, `water_shore_clearance_m`, `water_drag`,
`water_min_basin_area_m2`, `water_color`, `water_shore_color`, `water_ripple_speed`,
`water_sparkle_strength`. Off by default so shipped events without a water level are
unaffected.

## Tests

`tests/headless/`: `test_terrain_noise` (sampler matches TerrainManager),
`test_track_gen_params` (required water level + deterministic dry start),
`test_track_gen_water` (road avoids water; disabled = deterministic),
`test_track_gen_frame_consistency` (same config, same shape),
`test_lake_field` (single water plane + `submerged_cells`), `test_car_water` (drag +
recoverable).


## Frozen lakes

In a region that authors `frozen_water` (the Alps), the lake is **solid** and driven on
instead of being a soft drag hazard. `LakeField._add_ice_collider` adds a
`WorldBoundaryShape3D` — an infinite half-space plane at the waterline.

That works precisely because of the design above: there is no lake geometry, just one
plane with terrain occluding it, so there is no outline to match. The terrain collider is
still present, so above the waterline the car drives on ground and where terrain dips
below — exactly where a lake is drawn — it rests on the ice. The two colliders reproduce
the lake's shape for free, at the cost of the cheapest collider physics has.

The water-drag query is **not** wired on a frozen stage, the ice grip overrides the
surface blend in `Drivetrain.surface_tire_params`, and the look reuses this same water
shader with ice colours and `scroll_speed = 0`. The track still routes around water, so a
frozen lake is an off-road hazard or shortcut and rival times are unaffected. See
[snow-region.md](snow-region.md).

