# Testing

**Runner:** `./run_tests.sh` (bash). Uses **GUT** (Godot Unit Test), vendored in
`addons/gut/`. Godot binary defaults to
`/Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot` (override with
`$GODOT`).

> Per CLAUDE.md: run `./run_tests.sh` in the **background**, wait for the
> completion notification, and never start a second run while one is active. All
> tests must pass before declaring work complete.

## Single headless pass — `tests/headless/`

GUT tests, no window. Use `tests/fixtures/test_track.tscn` (flat ground) for
deterministic physics. For per-test timing, run once with
`-gjunit_xml_file=res://test_results.xml` and read the `time` attributes (GUT
has no `-gtimes` flag).

Before the pass the runner does a `Godot --headless --import` **warmup** to
rebuild the global class cache (`.godot/global_script_class_cache.cfg`). On a
cold start that cache isn't always populated when GUT compiles scripts, which
made cross-script `class_name` references (e.g. `CarLibrary`, `Drivetrain`)
intermittently fail to resolve. `scripts/car.gd` additionally `preload`s
`CarLibrary` as a const for the same reason.

| File | Covers |
|------|--------|
| `test_smoke.gd` | scene instantiates, 4 wheels, camera, HUD, shaders load |
| `test_render_smoke.gd` | rendering setup intact: environment, mesh shader materials, post-process shader, shader sources, clean frames |
| `test_car.gd` | launch, speed, steering, reset |
| `test_car_types.gd` | every CarLibrary entry: wheel placement, grounding, suspension, cornering, drives |
| `test_engine.gd` | idle, redline under load, shift through the clutch, reverse (needs the car) |
| `test_engine_logic.gd` | pure flywheel/gearbox logic on a bare `EngineSim` — limiter bounce, shift-speed table, auto-shift decisions (no scene) |
| `test_drivetrain.gd` | wheelspin, brake lockup, handbrake, parking brake |
| `test_drive_mode.gd` | RWD/AWD/FWD torque distribution |
| `test_config_applied.gd` | config → scene propagation |
| `test_engine_audio.gd` | synth firing phases, `fill()`, clamping |
| `test_engine_library.gd` | every `EngineLibrary` catalog entry loads and `apply()` writes the expected fields |
| `test_terrain.gd` | `height_at`, seed determinism |
| `test_car_terrain.gd` | suspension on slopes |
| `test_debug_arrows.gd` | force overlay updates |
| `test_perf_overlay.gd` | frame profiler overlay toggles / samples |
| `test_hud.gd` | label updates |

### Keeping the suite fast

By default Godot's headless main loop is **paced to real time** at the tick
rate, so each `await get_tree().physics_frame` costs ~1/60 s of wall-clock
regardless of how trivial the scene is.

The runner removes that pacing with the **`--fixed-fps 60`** CLI flag (in
`run_tests.sh`'s `GUT_ARGS`). It advances the loop by a fixed 1/60 s delta each
iteration and runs at CPU speed instead of synchronising to real time — the
per-step physics delta is **unchanged**, so the sim is bit-for-bit identical to
a real-time run (verified: a 600-frame probe dropped from ~10 s to ~0.04 s wall
with the same 1/60 delta; `test_car.gd` went 28 s → 1.5 s, all assertions still
green). The flag value must equal `physics_ticks_per_second` (the default 60) so
exactly one physics tick fires per frame. This is unlike `Engine.time_scale` /
raising `physics_ticks_per_second`, which both change the per-step delta
(verified: `time_scale = 8` makes the delta 8× bigger) and so would alter the
physics the tuned assertions depend on; `Engine.max_fps` has no effect headless.

`--fixed-fps` only collapses time spent **awaiting frames** — genuine CPU work
is the remaining floor. The dominant such cost is **`main.tscn` generation**:
`world.gd._ready()` runs the full rally-track DFS search (~7 s) and scatters
trees + bushes (~7 s) synchronously, so each instantiate is ~15 s of CPU. The
levers, in order of payoff:

- **Don't generate a world you don't inspect.** `tests/headless/scene_helpers.gd`
  exposes `SceneTestHelpers.minimal_world()` — call it instead of `Config.reset()`
  right before instantiating `main.tscn`. It trims the track to 1 turn and sets
  `trees_per_turn = 0` (which zeroes bushes too — they share the scatter params),
  cutting the build from ~15 s to <1 s while still wiring up the car, HUD, cameras
  and TrackProgress. `test_hud.gd` / `test_mobile_controls.gd` / `test_car_library.gd`
  / `test_camera_manager.gd` / `test_render_smoke.gd` / `test_config_applied.gd`
  use it (each `after_each` calls `Config.reset()` so the minimal track/foliage
  doesn't leak into later files that don't reset Config). Tests that only inspect
  the car + ground (no world nodes at all) go one cheaper still and instantiate
  the flat `res://tests/fixtures/test_track.tscn` directly (`test_debug_arrows.gd`).
  Only the files that genuinely assert on the track/terrain/foliage
  (`test_car_terrain.gd`, `test_loading_screen.gd`, `test_terrain.gd`) pay the
  full generation.
- **Settle once, not per test.** `tests/headless/sim_test.gd` is the base for
  physics-scene tests. It settles the baseline car **once**, caches the resting
  `Transform3D`, and on later setups restores that pose and stabilises in
  `RESTORE_FRAMES` (~10) instead of dropping from the 2.5 m spawn clearance and
  waiting `SETTLE_FRAMES` (150). It carries `class_name SimTest`, so tests can
  `extends SimTest` (the older `extends "res://tests/headless/sim_test.gd"` path
  form still resolves to the same base). `test_car.gd` / `test_engine.gd` extend
  it; `test_car_types.gd` keeps a per-car-index settled-pose cache via the same
  mechanism.
- **Logic that doesn't need a scene** (flywheel/gearbox/clutch math) lives in
  `test_engine_logic.gd`, which builds a bare `EngineSim` and pays no settle
  cost at all. Reserve the physics fixture for behaviour that genuinely needs
  the car/driveline (idle under load, redline, shifting through the clutch).

### Test-catalogue seam — `CarFixtures`

All four content libraries — `CarLibrary`, `EngineLibrary`, `RallyLibrary`,
`UpgradeLibrary` — expose the same small seam so tests don't have to reach into
(and get broken by) the shipped catalogue:

- `all()` — returns the active roster (shipped `CARS`/`ENGINES`/`RALLIES`/
  `UPGRADES` unless overridden).
- `override_for_test(list)` — swaps the active roster to `list` for the rest
  of the process.
- `reset()` — drops the override and falls back to the shipped const.

The seam is **inert in production**: an empty/unset override is treated as
"no override" and every lookup falls straight back to the real shipped const,
so shipping code never sees a behavior change.

The seam and the stable-id lookups (`index_of`/`by_id`) are implemented once in
the shared `Registry` helper (`scripts/registry.gd`): each library owns a
`Registry.Seam` instance and delegates `all()`/`override_for_test()`/`reset()`
to it, while `index_of`/`by_id` call `Registry.index_of(all(), id)` /
`Registry.by_id(all(), id)`. `test_registry.gd` covers the helper directly with
synthetic entries. (Rally/upgrade gained the `override_for_test`/`reset` seam in
that refactor — previously only car/engine had it.)

`tests/headless/car_fixtures.gd` (`class_name CarFixtures`) is a synthetic
catalogue built on that seam — a stable, test-owned roster that can't be
broken by renaming, retuning, adding, or removing real cars/engines:

- **Cars:** `fx_light_rwd` (RWD roadster, nose-light), `fx_fwd_hatch` (FWD
  hatch, nose-heavy), `fx_rwd_coupe` (RWD coupe, tail-heavy, V8), `fx_awd`
  (AWD coupe, ~50-50). Together they span drive mode, weight bias, body size,
  and power-to-weight band — whatever axis a test needs to vary.
- **Engines:** `fx_i4` and `fx_v8`, reusing real `EngineLibrary` firing-layout
  keys (`i4`/`v8`) so `EngineLibrary.apply()` and the audio path still work
  against them.
- `CarFixtures.install()` calls `override_for_test()` on both libraries;
  `CarFixtures.restore()` calls `reset()` on both.

**Mandatory rule:** any test that calls `CarFixtures.install()` MUST call
`CarFixtures.restore()` in its `after_each`/`after_all` — an override left in
place leaks into every test file that runs after it in the same process.
Conversely, the catalogue-**contract** tests (`test_car_types.gd`,
`test_engine_library.gd`, and the roster-invariant cases in
`test_car_library.gd`) deliberately stay on the real, shipped catalogue —
their entire job is asserting every real entry is well-formed — and instead
call `CarLibrary.reset()` / `EngineLibrary.reset()` in `before_each` to guard
against a leaked override from an earlier file.

### Shared DX helpers (`save_test_helpers.gd`, `node_query.gd`)

Two additional test-only helpers factor out patterns the suite hand-rolls
repeatedly. They are **additive** — existing tests are not yet rewritten to use
them (adoption is deferred), but new tests should reach for them:

- `SaveTestHelpers` (`tests/headless/save_test_helpers.gd`) — `redirect(path)`
  points the `Save` autoload at a throwaway `user://` profile (enables saving,
  loads a fresh default) and `cleanup(path)` deletes it plus its `.bak`/`.tmp`
  siblings and restores `DEFAULT_PROFILE_PATH`. This is the same dance the nine
  save-redirect files (`test_save_manager.gd`, `test_damage_model.gd`,
  `test_start_line.gd`, `test_pause_menu.gd`, `test_menu_flow.gd`,
  `test_camera_manager.gd`, `test_rally_session.gd`, `test_menu_nav.gd`,
  `test_input_remap.gd`) currently spell out inline.
- `NodeQuery` (`tests/headless/node_query.gd`) — read-only tree queries for
  menu/UI tests: `first_of_type`/`all_of_type` (by class name),
  `button_with_text`, and `all_label_text`.

### No pixel-diff visual regression

The old golden pixel-diff test (`tests/visual/`, `tests/golden/`) was removed: a
full frame capture only works windowed (headless uses a dummy renderer that
can't read back pixels) and was chronically flaky and slow to regenerate.
`test_render_smoke.gd` covers the meaningful half — rendering setup integrity —
without pixels.

## Commands

```bash
./run_tests.sh                       # full headless suite (with class-cache warmup)
./run_tests.sh --fast engine         # only files matching "engine" (quick iteration)
./run_tests.sh --fast menu_flow rally_flag   # multiple names -> one selection pass each
./run_tests.sh --fast "menu_flow rally_flag" # same, as one whitespace-separated string
```

Performance benchmarking is **separate** from the test suite — it's an on-demand
investigation tool, not a pass/fail gate. See `run_benchmark.sh` /
`benchmark/perf_benchmark.gd` (documented in [debug-tools.md](debug-tools.md)).

## Rules of thumb (from CLAUDE.md)

- Add/update tests in the **same** piece of work as the feature change.
- If a previously-green test fails, suspect the **new code**, not the test.
  Only change a test if the user explicitly asked for the asserted behavior to
  change — never weaken thresholds/assertions to go green.
