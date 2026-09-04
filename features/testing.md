# Testing

**Runner:** `./run_tests.sh` (bash). Uses **GUT** (Godot Unit Test), vendored in
`addons/gut/`. Godot binary defaults to
`/Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot` (override with
`$GODOT`).

**Tests:** `tests/headless/test_smoke.gd`

> Per CLAUDE.md: run `./run_tests.sh` in the **background**, wait for the
> completion notification, and never start a second run while one is active. All
> tests must pass before declaring work complete.

## Single headless pass — `tests/headless/`

GUT tests, no window. Use `tests/fixtures/test_track.tscn` (flat ground) for
deterministic physics. For per-test timing, run once with
`-gjunit_xml_file=user://test_results.xml` and read the `time` attributes (GUT has
no `-gtimes` flag; write to `user://`, since `test_results.xml` isn't gitignored).
Those `time` attributes cover **test bodies only** — `before_all` and script
loading are not attributed, and on the 2026-08 baseline that was ~170 s of a 655 s
run, so always reconcile the per-test sum against the wall-clock. The
`/optimise-test-suite` skill (`.claude/skills/optimise-test-suite/`) automates this
measure-then-cut loop; `CLAUDE.md` points at it whenever a full run exceeds ~5 min.

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

**Re-measured 2026-09-04**, at the end of the roguelike pivot. The previous table
(2026-08-18) is void: the demolition stage deleted roughly **40,000 lines** — the diegetic
HQ, the rival field, the star economy, the persistent parts model, the overworld map, and
every test that existed only to cover them — while region runs, `RunSession` and the flat
shell brought new ones. Re-measure with `/optimise-test-suite` (or a full `./run_tests.sh`
plus the JUnit XML) rather than reasoning from a stale table; that skill's §0 has the exact
invocation.

| Cost (2026-09-04, POST-PIVOT — measured) | Measured | Reducible? |
|---|---|---|
| `test_track_generator.gd` → `test_every_rally_event_generates_a_complete_track_quickly` | **94 s** | **No** — see *The irreducible sweeps* below. It grew with the roster: stage 4 authored 20 more events, and this generates every one of them live |
| `test_smoke.gd` | 32 s | Partly done. Its two challenge-stage world builds were merged into one (a challenge track is generated LIVE — the seed is rolled from the period hash, so no lockfile covers it and `minimal_world()` cannot trim it either, because `TrackGenParams.for_event` overrides the turn count). ~25 s recovered; the remaining build is load-bearing |
| `test_terrain_memory.gd` | 24 s | **No cheap lever.** 21 tests, each baking a road into its own `TerrainManager` — and what they assert IS what the cache keeps and drops between builds, so sharing one manager would destroy the subject |
| `test_world_fielding.gd` | 18 s | Partly done. Every test here boots `main.tscn` because the seam under test (`world.gd::_field_car`) is only reachable that way. Two tests were merged into one build, one was deleted as duplicate coverage of `test_perk_library.gd`, and its challenge-fallback case was re-pointed at a NO-SESSION boot — the identical `region_id` branch for ~5 s instead of ~25 s |
| `test_car_types.gd` / `test_car_library.gd` / `test_retune.gd` / `test_car.gd` | 16 / 12 / 14 / 7 s | **No** — per-car physics sweeps over the whole roster, already on `SimTest`'s cached settle where applicable |
| `test_terrain_precompute.gd` | 10 s | **No** — chunk prebake work it asserts on directly |
| The flat tail — ~175 further files | ~90 s | **No cheap lever found** (2026-09-04) |
| `before_all` builds + loading 189 test scripts | ~36 s | No — `minimal_world()` per file is already minimal. Note this is INVISIBLE in the JUnit XML: per-test times summed to 314 s against a 350 s wall-clock |

**Full-suite baseline: 350 s** (2553 tests, 161164 asserts, 189 scripts), plus a ~6 s
class-cache warmup that is not test cost. **That is over the ~5 minute budget by ~50 s**,
and the gap is structural rather than wasteful — see the sweeps below.

**The irreducible sweeps.** `test_every_rally_event_generates_a_complete_track_quickly`
generates every authored rally event live (~0.7 s each). It is the regression guard
for the seed-3002 blow-up, where one seed once took ~474 s. Sampling a subset
defeats it (the original bug was a *single* seed), and it covers what
`data/track_cache.json` cannot: a DFS **control-flow** regression that
`constants_fingerprint()` does not capture, so a fresh lockfile does not imply live
generation is still fast. **Do not weaken it to hit the budget.** If the ~5 min
budget must be met, the structural options are to move these sweeps into a slow
CI/pre-release lane (as `run_benchmark.sh` is to the suite), or to re-base the
budget here and in `CLAUDE.md` with the measured floor. **Both are the user's call**, so
neither has been taken: as of 2026-09-04 the suite runs 350 s and the sweeps alone are
~140 s of it (94 s track generator + 28 s of `test_smoke`'s live challenge build + 7 s
lakes + 5 s frame-consistency). Roughly 210 s of ordinary test cost sits under a 300 s
budget; the sweeps are what put it over.

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
  Only the files that genuinely assert on the track/terrain/**foliage** pay the
  full generation: `test_loading_screen.gd`, and `test_smoke.gd` — whose shared
  `before_all` scene is read by a test counting colliding vs non-colliding
  `TreeMeshField` children, so zeroing `trees_per_turn` there would quietly make
  that assertion vacuous. `test_terrain.gd` does **not**: its one scene test
  (`test_car_spawns_just_above_terrain`) asserts on the `$Floor` heightfield and a
  chunk's material, both of which `minimal_world()` leaves untouched, so it takes
  the cheap route and resets Config in `after_each`.
- **Skip foliage but keep real terrain.** `SceneTestHelpers` exposes exactly two
  helpers — `use_test_config()` and `minimal_world()`. There is no
  `no_foliage_world()`; a foliage-only knob that left `track_turn_count` at its
  authored value has never existed, so don't go looking for one.
  `minimal_world()` zeroes the trees **and** shortens the track, which is what
  makes it cheap (<1 s vs ~15 s). Crucially it does not touch the `$Floor`
  heightfield — that is generated identically — so a terrain-regression test can
  still use it and get real terrain to settle on. `test_car_terrain.gd` is the
  canary that relies on exactly that property, and says so in its own
  `before_each` comment.
- **Generate once per file, not per test.** When several tests in a file share
  one generated world, build it in `before_all` (plain `add_child`, freed in
  `after_all`) and restore per-test state in `before_each` rather than
  re-instantiating `main.tscn` each time. Many files do this — `test_hud.gd`,
  `test_config_applied.gd`, `test_garage.gd`, `test_smoke.gd` among them. The
  cached-resting-pose variant of the idea (cold-settle once, then restore the
  `Transform3D` and re-stabilise in a handful of frames) lives in
  `sim_test.gd` → `setup_settled_car`, described in the next bullet;
  `test_car_terrain.gd` does NOT use it, it takes the cheap
  `minimal_world()` + `before_each` route instead.
- **Hand the authored config back in teardown.** `Config.data` is a single global
  that outlives the script that mutated it, so a file which installs a different
  baseline (`use_test_config()`, `minimal_world()`) and never restores it silently
  re-tunes every LATER file that reads the *ambient* config. That is an
  order-dependent failure — green under `--fast <one file>`, red in a full run.
  The frozen physics baseline is the worst offender because it authors ~37
  properties against the shipped config's ~239, so everything it does not author
  falls back to the `GameConfig` script default (`com_height`,
  `wheel_roll_influence`, `wheel_friction_slip_rear`, `tire_load_sensitivity`, …)
  — enough to move where Godot's `VehicleWheel3D` solver actually settles a car
  and how the load splits front/rear. So **any file that installs a non-authored
  baseline calls `Config.reset()` in its teardown**: `sim_test.gd` (`after_all` —
  a subclass that defines its own `after_all` shadows it and must reset too),
  `test_drivetrain.gd`, `test_drive_mode.gd`, `test_car_terrain.gd`. The contract
  is pinned by `test_config_isolation.gd` → `test_reset_restores_the_authored_baseline_after_a_swap`
  (and its non-vacuity partner), which compares field-for-field against a freshly
  loaded duplicate rather than pinning any value.
- **Settle once, not per test.** `tests/headless/sim_test.gd` is the base for
  physics-scene tests. It settles the baseline car **once**, caches the resting
  `Transform3D`, and on later setups restores that pose and stabilises in
  `RESTORE_FRAMES` (~10) instead of dropping from the 2.5 m spawn clearance and
  waiting `SETTLE_FRAMES` (150). It carries `class_name SimTest`, so tests can
  `extends SimTest` (the older `extends "res://tests/headless/sim_test.gd"` path
  form still resolves to the same base). `test_car.gd` / `test_engine.gd` extend
  it; `test_car_types.gd` keeps a per-car-index settled-pose cache via the same
  mechanism.

  **The warm restore must go through `car.gd`'s `reset_to`, never a bare
  `global_transform` write.** The physics server *discards* a plain
  `global_transform` assignment made outside the physics step — `reset_to` exists
  precisely because of that, and queues the pose for `_integrate_forces`, the
  authoritative write point (it also wakes the body, since a sleeping body never
  runs `_integrate_forces`, and zeroes the velocities, steering, wheel omegas and
  engine sim). The warm path originally wrote the transform directly, so whether
  the car actually moved to the cached pose depended on the frame phase
  `setup_settled_car` happened to be called from. **This is a flake generator, and
  a nasty one:** the car is still a settled car on flat ground either way, so
  almost every assertion still passes and only a pose-sensitive reading notices.
  It cost one — `test_grip_servo_steering.gd`'s climbing-FWD test read a yaw rate
  of ~1e-10 in one full-suite run while passing in isolation and on re-run. If a
  physics test ever fails only inside a full run, suspect the shared settle cache
  first.
- **Logic that doesn't need a scene** (flywheel/gearbox/clutch math) lives in
  `test_engine_logic.gd`, which builds a bare `EngineSim` and pays no settle
  cost at all. Reserve the physics fixture for behaviour that genuinely needs
  the car/driveline (idle under load, redline, shifting through the clutch).

- **Audio does not PLAY under headless.** All three AudioStreamPlayers gate their
  `play()` on `not Platform.is_headless()`: the `Music` autoload
  (`music_director.gd`), the car's `EngineAudio` (`engine_audio.gd`), and the HQ
  `CarPreviewAudio` (`car_preview_audio.gd`). Godot's headless `AudioDriverDummy`
  still runs a mix thread, and a *playing* stream freed underneath it at engine
  teardown (`-gexit`) SIGSEGV'd in `AudioStreamPlaybackResampled::mix` — the
  ~1-in-3 crash-and-retry flake the runner used to absorb. Not playing means not
  mixed, so the crash is gone (and the per-frame engine-audio synthesis is
  skipped). Test the audio DSP/scheduling directly instead: `EngineAudioSynth`
  (`test_engine_audio.gd`), the `MusicDirector` schedule via `.new()` never added
  to the tree (`test_music_director.gd`) — never assert on a *playing* stream in a
  headless test.

- **A `Platform.is_headless()` gate must skip only the ANIMATION, never the
  final visible state — the audio gate above is the safe shape, and it is
  safe specifically because "not played" is genuinely the correct end state
  in both paths.** The deleted global standings page (`GlobalStandings`) got this
  wrong: it built
  its body nodes hidden and relied on a `_reveal()` coroutine to un-hide them
  one at a time, with the coroutine itself skipped headless — so headless saw
  the nodes (never hidden in the first place) while a real player saw a
  genuinely blank page whenever the reveal didn't run to completion. Headless
  and the real game were rendering through different code, so a green suite
  could not have caught it. The fix deleted the reveal outright rather than
  patching the gate. When a gate like this is unavoidable, prefer asserting
  `is_visible_in_tree()`, not mere node existence — existence is exactly what
  passed here while the screen was blank. For the fix *shape* rather than the
  failure shape, see `hq.gd`'s cloud boot gate ([cloud-save.md](cloud-save.md)
  → "Boot-time race"): `_await_cloud_restore` now decides and waits
  unconditionally, with only the visual (`_show_restore_cover`) gated headless
  — and a `cloud_restore_wait_sec` seam lets a test set the budget instead of
  spending real seconds — so `test_cloud_boot_gate.gd` can actually prove HQ
  waits for a pending pull and proceeds once it settles, on the same code path
  the player runs.

### Synthetic centerlines — `TrackFixtures`

`tests/headless/track_fixtures.gd` (`class_name TrackFixtures`) supplies the
`{"centerline", "pieces"}` dicts that `LapTimeModel` / `RivalPace` consume, so no test has
to reach into a generated track: `straight(length)`, `arc(radius, sweep)` (densely sampled
POINTS, no handles), `handled_arc(radius, sweep, steps)` (few points with real Bezier
handles) and `straight_then_arc(...)`.

The distinction between `arc` and `handled_arc` matters and is easy to get wrong: `arc` is
already a handle-free polyline, so resampling it is near-lossless by construction. Any test
asserting that a **resample** preserves curvature must use `handled_arc`, or it will pass
against a broken implementation. See the deleted rival ghost → *The timed-span
curve*.

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

### Never let a `change_scene_to_file` escape

Under the headless runner a real scene change is **not** scoped to the test that
triggered it: the scene is instantiated into `/root`, nothing ever frees it, and it
shares the one `World3D` / physics space with every later test. A leaked `main.tscn`
makes a settling car land on its terrain instead of the fixture ground (crooked
attitude, asymmetric wheel loads, never at rest) and makes camera pick rays hit it
first — silent, order-dependent failures that are green under `--fast <file>` and red in
a full run.

So before driving anything that can change scene, switch the seam off or capture it:

- `RunSession.auto_load_scenes = false` — `begin()` and `continue_to_next_stage()` end in
  `change_scene_to_file("res://main.tscn")`, and the seam **defaults to `true`**.
- `world.gd` → `scene_change_hook` — capture the requested path instead of loading it.
- `Scenes.block_real_changes` — the run-scoped backstop the pre-run hook arms, which
  swallows every transition and records where it was headed
  (`Scenes.last_blocked_path`).

Restore the seam (and end any run you started — `RunSession.pause_run()` /
`Save.clear_run()`) in `after_all`. `tests/headless/test_world_isolation.gd` is the backstop: it fails if any
game scene is parked under `/root`, and it is named `world_*` so it sorts late enough
to see almost every polluter.

`tests/headless/rally_fixtures.gd` (`class_name RallyFixtures`) and
`tests/headless/upgrade_fixtures.gd` (`class_name UpgradeFixtures`) are the
same pattern for the rally and upgrade catalogues:

- **RallyFixtures:** `fx_open` (open restriction, 3 events — the "any rally with
  events" workhorse), `fx_rwd_band` / `fx_fwd_band` (drive-mode + power-band
  gates), `fx_country_us` (country gate), `fx_gated` (a MAP-REVEAL gate — its
  `map_pos` sits outside HQ's lit circle, and `fx_open` authors a wide
  `reveal_radius` that reaches it, so completing `fx_open` reveals `fx_gated`), and
  `fx_showdown` — all in the real `home` region so reveal/region grouping
  resolves. Events use a very low `water_level` so track generation never has to
  route around lakes (fast, deterministic). Eligibility reads `CarLibrary`, so a
  test checking eligibility should `CarFixtures.install()` its cars too.
- **UpgradeFixtures:** now an **effect** table, not a catalogue — `UpgradeLibrary` stopped
  being a catalogue with the parts model (see
  [upgrade-catalogue.md](upgrade-catalogue.md)). One synthetic entry per effect shape the
  `apply` / `effective_meta` pipeline reads: the induction pair
  (`fx_turbo_small`/`fx_turbo_big`), `fx_supercharger`, `fx_gearbox` (the `set` op),
  `fx_aero` (`add`), `fx_tires` / `fx_snow_tires` (`mult`, one of them surface-dependent),
  `fx_lightweight` (`mass_mult < 1`) and `fx_ballast` (`mass_mult > 1`).
  `UpgradeFixtures.boosts([...])` builds the `boosts` list a test hands to a car dict, so a
  logic test never reaches into the real catalogue for an effect shape.
- The fixture owning its own ids, rather than re-exporting catalogue constants, is
  load-bearing: an earlier version re-exported the real engine-swap-token id and broke when
  that token was deleted.
- The seam mechanics for the catalogue libraries are covered by `test_catalogue_seam.gd`;
  `CarFixtures` keeps the `install()` / `restore()` contract and the **mandatory-restore**
  rule.

### Shared DX helpers (`save_test_helpers.gd`, `node_query.gd`)

Two additional test-only helpers factor out patterns the suite hand-rolls
repeatedly. They are **additive** — existing tests are not yet rewritten to use
them (adoption is deferred), but new tests should reach for them:

- `SaveTestHelpers` (`tests/headless/save_test_helpers.gd`) — `redirect(path)`
  points the `Save` autoload at a throwaway `user://` profile (enables saving,
  loads a fresh default) and `cleanup(path)` deletes it plus its `.bak`/`.tmp`
  siblings and restores `DEFAULT_PROFILE_PATH`. This is the same dance the nine
  save-redirect files (`test_save_manager.gd`, `test_damage_model.gd`,
  `test_start_line.gd`, `test_pause_menu.gd`, `test_camera_manager.gd`,
  `test_menu_nav.gd`, `test_input_remap.gd`) currently spell out inline.

#### The profile sandbox (why a forgotten redirect is no longer fatal)

A headless run once **overwrote the developer's real `user://profile.json`** with a
blank default carrying synthetic fixture cars (`fx_light_rwd`): two test files granted
cars through the live `Save` autoload while it was still pointed at the real path, and `Save.save()` duly wrote it. Only the next
launch's cloud pull restored the career.

Per-test redirects are therefore backed by a **run-scoped sandbox**:

- `run_tests.sh` passes GUT `-gpre_run_script=tests/headless/save_sandbox_pre_hook.gd`,
  which sets `Save.test_sandbox_path` to a throwaway `user://` file.
- While that field is non-empty, `SaveManager.profile_path`'s setter remaps any
  assignment of `DEFAULT_PROFILE_PATH` onto it (`scripts/save_manager.gd` →
  `test_sandbox_path`). So an unredirected test — or one that "restores" the real
  path in teardown, which every save-redirect file does — cannot reach the player's
  profile. The field is empty in every real build, making the setter the identity
  function there.
- `-gpost_run_script=tests/headless/save_sandbox_post_hook.gd` compares the real
  file's mtime before/after the run and prints `PROFILE SANDBOX VIOLATION`, which is
  in `run_tests.sh`'s `TEST_ERROR_PATTERN` and fails the run.
- `test_save_sandbox.gd` covers the seam itself (remap, explicit-redirect wins, no
  sandbox = no remap) and that a live run is sandboxed.

Explicit `SaveTestHelpers.redirect` is still expected of any test that mutates the
profile — the sandbox is a backstop, and per-file isolation is what keeps tests from
reading each other's leftovers.

- `NodeQuery` (`tests/headless/node_query.gd`) — read-only tree queries for
  menu/UI tests: `first_of_type`/`all_of_type` (by class name),
  `button_with_text`, and `all_label_text`.

### No pixel-diff visual regression

The old golden pixel-diff test (`tests/visual/`, `tests/golden/`) was removed: a
full frame capture only works windowed (headless uses a dummy renderer that
can't read back pixels) and was chronically flaky and slow to regenerate.
`test_render_smoke.gd` covers the meaningful half — rendering setup integrity —
without pixels.

## The `test_menu_flow.gd` salvage

`tests/headless/test_menu_flow.gd` — 5,880 lines, 207 tests, the single biggest file in
the suite — is **deleted**. It drove the diegetic hub end to end (`hq.gd`, `hq_carpark.gd`,
`hq_table.gd`, `hq_challenge.gd`, `GlobalStandings`, `podium.gd`, `standings.gd`,
`RallySession`), all of which the pivot removed, so it had stopped parsing at all: 146
parse errors, and GUT skipped the file wholesale. A test file that cannot load is worse
than no file — it reads as coverage and provides none.

`todo/roguelike-pivot.md` decision 47 called for salvage rather than deletion, and that is
what happened: **everything host-free was re-homed first**, and only then was the husk
removed.

| Salvaged into | What moved |
| --- | --- |
| `test_username_popup.gd` (new) | The `UsernamePopup` sanitiser rules and the name's profile round-trip — `UsernamePopup` is live and had no other coverage |
| `test_settings_menu.gd` | The two dev-tooling visibility tests (`dev_tools_override` gating Benchmark / Dev / Seed lab out of the category list) |
| `test_tuning_panel.gd` | The slider-alignment case (every handling-axis slider is the same width) |
| `test_world_fielding.gd` (new) | "the run scene fields the bound session car", ported off `RallySession` onto `RunSession` — and extended to cover the perk/boost merge at the same seam |

**What was lost, and it is worth knowing.** Roughly 190 tests went with their subjects and
could not be ported, because the thing they asserted no longer exists: the HQ's station
routing and camera framing, the 3D map table (panning, clamping, pin rebuilds, the
new-rally reveal parade), the car park (lineup building, eligibility marking, swap mode,
the wheel view), the tuning lift, the upgrades grid, the starter picker, the podium's
reward beats, the standings page's two leaderboards, and the challenge entry screen's
board queries. Several were regression guards for real reported bugs; where the reasoning
outlives the screen, it has been written into the relevant `features/` doc rather than
lost with the test — see [world-panel.md](world-panel.md),
[ui-design-system.md](ui-design-system.md) and
[wheel-customization.md](wheel-customization.md), each of which now says which behaviours
a rebuild owes.

**Two other files were quietly broken the same way** and are fixed rather than deleted,
because most of each was still live:

- `test_cloud_boot_gate.gd` — 15 of its 20 tests booted `hq.tscn` and errored at runtime
  (it PARSED, so nothing caught it until stage 9). The 5 `Cloud`-level gate tests remain.
  Its header now records that the gate has **no consumer**: `HubShell` does not await the
  initial sync, so the hazard those 15 tests guarded is real and currently unguarded.
- `test_wheel_customization.gd` — 17 HQ wheel-view tests, same failure mode. The 20
  host-free tests (catalogue, eligibility, resolution, save round-trip, cosmetic-only
  guarantee) remain and are the whole feature minus its UI.

The lesson worth keeping: **a test file that fails to PARSE is caught by the runner; one
that parses and errors at runtime is not** — it just fails, and a suite nobody has run in
full since a large deletion will be hiding several. Sweep with
`godot --headless --check-only --script <file>` for the first class, and an actual run for
the second.

## Commands

```bash
./run_tests.sh                       # full headless suite (with class-cache warmup)
./run_tests.sh --fast engine         # only files matching "engine" (quick iteration)
./run_tests.sh --fast menu_flow rally_flag   # multiple names -> one selection pass each
./run_tests.sh --fast "menu_flow rally_flag" # same, as one whitespace-separated string
```

### Analysis scripts (not tests)

Some questions are measurements, not assertions — "how steep is the ground the car actually drives
on?" has no pass/fail, and a test that pinned a number would just be a tunable in disguise. Those
live in `tools/` and run standalone:

```bash
$GODOT --headless --path . -s tools/analyse_road_grades.gd            # every overworld road's grade
$GODOT --headless --path . -s tools/analyse_road_grades.gd ++nopads   # ...with the flat pads off
$GODOT --headless --path . -s tools/analyse_road_grades.gd ++probe=-25,-17   # dump one spot's pipeline
```

Two traps worth knowing before writing another one:

- **`_initialize`, never `_init`.** `-s` compiles the script before the SceneTree exists, so the
  autoloads (`Config`, `PerfLog`, …) that `scripts/*.gd` reference at class scope are missing and
  the compile fails. Await a frame in `_initialize`, and `load()` the classes you need rather than
  naming their types — naming `TerrainManager` at class scope drags the same problem back in.
- **Always `quit()`.** A SceneTree that finishes its work and does not quit idles forever, and the
  run has to be killed by hand. Put the `quit()` outside the body that can fail.

`analyse_road_grades.gd` in particular measures the **grid** pipeline (`compute_chunk_data`), not
`height_at`: the road carve exists only in the grid pass, so sampling the scalar generator measures
the raw ground along the road's path rather than the road. See its header.

Performance benchmarking is **separate** from the test suite — it's an on-demand
investigation tool, not a pass/fail gate. See `run_benchmark.sh` /
`benchmark/perf_benchmark.gd` (documented in [debug-tools.md](debug-tools.md)).

### Known engine flake: audio-thread SIGSEGV on teardown

The full headless suite intermittently crashes with **signal 11 (SIGSEGV)** —
backtrace `AudioStreamPlaybackResampled::mix` → `AudioServer::_mix_step` →
`AudioDriverDummy::thread_func`, error "The caller thread can't call
`propagate_notification()` … Use `call_deferred()`". It's a **Godot engine race**
between the dummy audio driver's mix thread and scene teardown while a
sample-based (resampled) `AudioStreamPlayer` is still playing — **not our code**:
it reproduces on clean `main` at ~1-in-3 full runs (measured 3/8), the same rate
as with local changes, and never in a single-file `--fast` run (audio state only
accumulates across the whole suite). There are **zero assertion failures** when
it hits.

`run_tests.sh` (`run_pass`) **auto-retries this specific case**: a crash exits by
*signal* and prints "Program crashed with signal", whereas a genuine test failure
exits cleanly through GUT (status 1) and a timeout is 124/137 — none of those are
retried, so the retry can never mask a real failure. Budget is
`TEST_CRASH_RETRIES` (default 2; a crash that persists past it still fails the
run). If you see a `retrying (n/2)` warning, that's this flake being absorbed.

## Invariant: never `play()` audio headless

**Any node that calls `play()` on an `AudioStreamPlayer` / `-2D` / `-3D` MUST first
guard on `Platform.is_headless()` and skip playback entirely.** This is a project-wide
rule, not a quirk of one file.

Why: Godot's headless `AudioDriverDummy` still runs a background mix thread. A
*playing* playback object (notably `AudioStreamGeneratorPlayback` and
`AudioStreamPlaybackPolyphonic`, both `AudioStreamPlaybackResampled`) is freed
underneath that thread at engine teardown (`-gexit`) — a use-after-free that SIGSEGVs
in `AudioStreamPlaybackResampled::mix`. It is **intermittent** (historically ~1 in 3
full runs before the existing guards landed), so the cost lands on whoever runs the
suite next, not on the author. A *stopped* player is never mixed, so simply not
calling `play()` is the whole fix; the bus graph and `AudioServer` calls are safe.

The shape to copy — build the stream, then return before `play()`:

```gdscript
if Platform.is_headless():
    return
play()
_playback = get_stream_playback() as AudioStreamGeneratorPlayback  # play() FIRST
```

Leaving the playback reference `null` makes every downstream path no-op through the
`if _playback == null: return` guard it already has, so the logic still runs and only
the mixing is skipped. Shipping builds are never headless.

Live examples: `scripts/audio.gd` (`_ready`), `scripts/engine_audio.gd` (`_ready`),
`scripts/music_director.gd` (`_ready`). For sound effects you should not be writing
this at all — call `Audio.play_beep(...)` and inherit the guard (`features/sfx.md`).

## Trap: assert on what the feature reported, not on the whole inventory

There is no longer a random per-event upgrade draw, so driving a rally no longer
sprays RNG-chosen items into the profile — an exact inventory total after driving
events is a fair assertion again. The habit the old draw forced is still the
better one, though, and `test_rally_session.gd` keeps it: **assert on what the
feature itself reported** (e.g. `special_unlock.granted` says what the unlock
granted) rather than on a derived count that any future grant path could also
move. It keeps the test pointed at the code under test instead of at the sum of
everything that ran.

## Trap: async work that outlives the node that started it

`settings_menu.gd`'s seed lab starts an **async** `TrackGenerator.generate()` and hands
it two lambdas — `on_prog` and `abort` — which capture the menu (they read `_sl_gen` /
`_seedlab_preview`). The generator polls those callables *across its own `await`
boundaries*, so if the menu is freed while a search is still in flight, the generator
calls a lambda whose owner is half-destroyed:

```
SCRIPT ERROR: Attempt to call function '<anonymous lambda>(self lambda) (Callable)'
              on a null instance.   at: _search (res://scripts/track_generator.gd)
SCRIPT ERROR: Invalid access to property or key 'complete' … at: generate (…)
```

`test_seedlab.gd` hit exactly this: it awaits only a frame or two after
`show_seedlab()`, and GUT's `add_child_autofree` then frees the menu mid-search. The
consequences are nastier than a failed assertion — the corrupted return value aborts
the **whole run** with no `Totals` block, and since `GUT`'s exit status is still 0 the
run masquerades as a fast pass (`run_tests.sh` only catches it via
`TEST_ERROR_PATTERN`). It is timing-dependent and never reproduces under
`--fast seedlab`, so it reads as random CI death.

The fix, in `test_seedlab.gd`'s `after_each`: bump `_menu._sl_gen` so any in-flight
search aborts **while the menu is still alive**, then await a few frames to let it
unwind. Generalise it: **a test that kicks off async work must settle or cancel that
work before its nodes are freed** — awaiting "a frame or two" is not the same as
awaiting completion. Note also that a dangling-callable guard inside the generator
cannot save you: a lambda whose captured owner has been freed reports
`is_valid() == false` and `get_object_id() == 0`, indistinguishable from an unset
`Callable()`, so the only reliable fix is not to leave the work in flight.

## Rules of thumb (from CLAUDE.md)

- Add/update tests in the **same** piece of work as the feature change.
- If a previously-green test fails, suspect the **new code**, not the test.
  Only change a test if the user explicitly asked for the asserted behavior to
  change — never weaken thresholds/assertions to go green.

## Runner timeouts (`run_tests.sh`)

Two independent caps, both of which exist because a wedged headless Godot otherwise sits there for
tens of minutes eating CPU and looking like a hung agent:

| Env | Default | What it caps |
|-----|---------|--------------|
| `TEST_TIMEOUT` | 1800 s | wall clock for the whole run |
| `TEST_STALL` | 120 s | **per test**: no test output for this long = something is stuck |
| `WARMUP_TIMEOUT` | 300 s | the `--import` class-cache warmup |

**`TEST_STALL` is the useful one.** GUT streams a line per test as it starts, so a healthy run never
goes quiet for long; if the captured output stops growing, a test is wedged (an infinite layout/resize
loop, an await that never resolves). When it fires it **names the last test seen**, which is the thing
you actually want and which neither a wall-clock cap nor GUT itself will tell you:

```
error: no test output for 15s — a test is STUCK. Killing the run.
error: last test seen: test_this_one_hangs_on_purpose
```

Raise it (`TEST_STALL=300 ./run_tests.sh`) for a legitimately slow test rather than removing it.

**Note the wall-clock cap needs a `timeout` binary — and stock macOS has none.** It used to warn and
then run *uncapped*, which is exactly how the long hangs happened. There is now a pure-bash
`builtin_timeout` fallback, so the cap applies everywhere.

**One subtlety if you touch `run_pass`:** the Godot run must stay in the FOREGROUND so
`PIPESTATUS[0]` is its exit status. Backgrounding the pipeline and `wait`-ing returns *tee's* status
(always 0), which would report a failing run as passing.
