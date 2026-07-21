# Lakes

**Source:** `scripts/lake_field.gd` (`LakeField`), `scripts/track_gen_params.gd`
(`TrackGenParams`), `scripts/terrain_noise.gd` (`TerrainNoise`),
`shaders/water.gdshader`, plus water-avoidance in `scripts/track_generator.gd`
and wiring in `scripts/world.gd` / `scripts/rally_session.gd` / `scripts/car.gd`.

Lakes are water pooled in the natural terrain basins beside the road, up to an
**authored per-event water level**. The road is guaranteed never to run into water
because the track-layout DFS treats below-water cells as obstacles and routes
around them. Water is a **soft hazard** — the car gets extra drag but can drive
out (no reset). Water also renders in the loading-screen preview and the dev
seed-lab.

## Two orthogonal per-event knobs

- **`seed`** (`track_seed`) — carves the terrain landscape *and* routes the road.
  The terrain `noise_seed` is now driven from `track_seed` (world.gd, where layers
  sync to `$Floor`), so each event has its own landscape + lake layout. Because the
  road DFS does not read terrain when water is off, this changes only the visible
  elevation for water-off events, **not** the road shape or opponent times.
- **`water_level`** (`event["water_level"]` → `cfg.track_water_level_m`) — the
  world-Y flood height poured into whatever basins the seed produced. Independent
  of the seed. Higher = more/bigger lakes in the same valleys.

Both are applied per event in `RallySession._load_event_scene` (real run) and read
by `TrackGenParams.for_event` (both the run scene and target derivation).

## `TrackGenParams` — the shape contract

`TrackGenerator.generate(params: TrackGenParams, on_progress)` takes a single
params object; there is no positional form. `TrackGenParams` holds **every**
determinant of the generated shape (`seed, turn_count, width, clearance,
reserve_behind, straightness, runoff_m, water_enabled, water_level,
shore_clearance, origin, heading, base_origin, water_sampler`) and is built only
via factories that require a water decision:

- `for_event(event, cfg)` — the single source of truth used by the run scene
  (`world.gd`), target-time derivation (`RallySession._generate_event_tracks`), and
  the loading preview.
- `for_config(cfg)` — free-roam / benchmark / editor (cfg-driven, reproduces the
  pre-lakes behaviour).
- `for_trial(seed, water_level, turns, straight, cfg)` — the dev seed-lab.

This makes the opponent-time desync bug **structurally impossible**: you can't
generate a shape without a water level, and both the run scene and target
derivation build params from the same `for_event`, so they can't drift.

### Why this matters (shape-determinism invariant)

Water is sampled at **world-absolute** coordinates, so the generated shape now
depends on `water_level` **and** the world origin (previously it was
pose-independent). Rules that keep opponent times correct:

1. `water_level` is a shape parameter — carried in `TrackGenParams`, so every
   `generate()` carries it (like `straightness`).
2. Target derivation and the run scene use the same origin — both go through
   `for_event`, which seats the staged lead-in origin from cfg identically.
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
  see [rendering.md](rendering.md)). A **seamless generated tiling texture**
  (`LakeField._make_water_texture`, a `NoiseTexture2D`) is scrolled in two directions
  for visible movement, tinted between deep/shore colours, with a sparkle glint.
- **Hazard:** the "in water" query is a **direct terrain-height check** — `world.gd`
  wires `car.gd`'s `set_water_query` to `floor.height_at(x,z) < water_level`.
  `_apply_aero` adds `cfg.water_drag` linear drag while in water. No reset — the car
  can drive out.
- **Props stay dry:** `world.gd._drop_submerged` filters tree, bush, and spectator
  scatter positions, dropping any whose terrain is below `water_level`.
- **Previews:** `LakeField.submerged_cells(sampler, level, bounds, step)` is a pure
  static helper that marks below-water ground for the 2D loading + seed-lab previews
  (no scene/terrain needed).

## Preview + dev seed-lab

- `scripts/track_preview.gd` (`TrackPreview`) is the shared preview Control
  (extracted from the loading screen). It paints a black backdrop, draws below-water
  cells as blue blocks (`set_water`), and the road line over them; chunk squares are
  near-transparent white (0.05 alpha) so water reads through during the precompute stage.
- The **loading screen** (`loading_screen.gd.update_water`) paints the waterline
  up-front (before generation) over the track bounds, so the road animates over it —
  eye-candy + authoring/debug aid.
- **Water fills the panel edge-to-edge.** The 2D fit preserves aspect ratio, so
  sampling water over just the track's bounding box left dry letterbox bands wherever
  the track's aspect differed from the panel's — the water looked "cut off" at a fixed
  distance, unlike the real game's full 10 km plane. Both callers expand the sample
  bounds to the panel aspect via `LoadingScreen.expand_to_aspect(bounds, w/h)` and pass
  that rect to `set_water(cells, size, frame)`; `TrackPreview` fits to the explicit
  `frame` so the sampled water reaches the container edges (`world.gd._preview_aspect`,
  `settings_menu.gd._seedlab_aspect`).
- The **dev seed-lab** (Settings → Seed lab, `settings_menu.gd`) trials track
  parameters via typeable SpinBox fields against a large live `TrackPreview` that
  **animates the generation** (on_progress, like the loading screen), with a
  generation token dropping stale runs. Bottom action row: **Load event…** /
  **Terrain…** / Randomize / Back (`go_back` returns to the category list).
- **Faithful generation.** `_regen_seedlab` builds an EventDef from the inputs
  (`_seedlab_event`) and generates through the **exact career path** —
  `RallySession.canonical_event_config(ev)` → `TrackGenParams.for_event(ev, cfg)` —
  NOT `for_trial`. This matters: `for_trial` skipped start-line staging (no lead-in
  `reserve_behind`, origin at nominal) and used `cfg.track_width` (7.0) instead of the
  event width (`DEFAULT_WIDTH` 6.0), so its shapes disagreed with the cached career
  tracks. `for_event` reserves the lead-in corridor, uses the event width, and samples
  terrain from the canonical config, so the preview equals the real stage (verified by
  `test_seedlab.gd` → `test_loaded_event_matches_career_cache_key`, which compares the
  lab's and career's `TrackCache.key_for`).
- **Load event…** (`_open_event_picker` → `_build_event_picker`) opens a keyboard/
  gamepad-navigable popup listing every rally (`RallyLibrary.all()`) and its 3 events.
  Picking one (`_load_event`) copies the event's fields — the four core inputs + the
  six terrain-noise fields — into the spinboxes; the inputs stay the single source of
  truth. The picker remembers the last-focused row (`_event_focus`) and re-seats the
  cursor there on reopen. `forestiness` / `surface_mix` / `cliffiness` are omitted —
  they drive trees / surface / elevation, none of which the centerline+water view shows.
- **Terrain…** (`_open_terrain_editor` → `_build_terrain_editor`) opens a second popup
  docked below the preview (which stays visible for live feedback) exposing the six
  terrain-noise fields (3 layers × wavelength+amplitude). These shape the track too —
  the generator routes the road around below-water cells and relocates the dry start —
  so exposing them is what lets the lab's lakes match career. All authored terrain
  values are whole numbers (`game_config.tres` + the `RALLIES` overrides), so the
  fields use an integer step (SpinBox snaps to step).
- **Focus nav** (`_wire_seedlab_nav`): left/right is contained — within the 2-column
  field grid it only swaps columns (stops at the outer edges), and on the bottom button
  row it chains between the buttons and stops at the ends; it never leaks between the
  grid and the row. Up/down walks the rows (and off the last field row into the
  buttons) via Godot's geometric default.

## Config (`GameConfig` "Water" group)

`water_enabled`, `track_water_level_m`, `water_shore_clearance_m`, `water_drag`,
`water_min_basin_area_m2`, `water_color`, `water_shore_color`, `water_ripple_speed`,
`water_sparkle_strength`. Off by default so shipped events without a water level are
unaffected.

## Tests

`tests/headless/`: `test_terrain_noise` (sampler matches TerrainManager),
`test_track_gen_params` (required water level + deterministic dry start),
`test_track_gen_water` (road avoids water; disabled = deterministic),
`test_track_gen_frame_consistency` (run-scene vs derivation shape),
`test_lake_field` (single water plane + `submerged_cells`), `test_car_water` (drag +
recoverable), `test_track_preview`, `test_seedlab`.
