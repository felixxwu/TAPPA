# Phase 1.1 — Deterministic replays: implementation plan

**Depends on:** `todo/2026-11-27-rust-native-migration.md` Phase 1.1 ("Make the level deterministic under
replay"). This file is the audit and the plan for that step; tick 1.1 there when this lands.

The spec's list of sources is mostly right, but it misses the most important hole: **the replay runs on the
player's real `user://profile.json`.** In `benchmark/level_replay.gd` → `_ready`, nothing swaps the profile or
sets `Save.save_disabled`. The comment on `save_disabled` in `save_manager.gd` says "Switched on by a
benchmark", but no code does that. So the money, cars, deliveries, discovery and settings a replay starts from
differ per machine, and the replay can write back to the real profile.

## 1. Audit: every non-deterministic source

### A. Global or unseeded randomness
| File → function | Today | Fix |
|---|---|---|
| `damage_model.gd` → `nudge_wheels` | `randf()`, `randf_range` (changes wheel toe, which is game state) | `var _rng := RngStreams.make("damage")` on `DamageModel`, then `_rng.randf…` |
| `level_weather.gd` → `attach` | `seed_value = randi() \| 1` (static) | `RngStreams.make("weather").randi() \| 1` |
| `dust_puffs.gd` → `_emit_puff` | 13 `randf_range` calls | instance `_rng := RngStreams.make("dust_puffs")` |
| `wheel_particles.gd` → `_jittered` (a **static** func) and the emit around lines 355–369 | `randf_range` | instance `_rng := RngStreams.make("wheel_particles")`; add an `rng` parameter to `_jittered` |
| `engine_smoke.gd` → `_puff` | `randf_range` | `RngStreams.make("engine_smoke")` |
| `exhaust_flames.gd` → `var _rng` (line 61) | never seeded, so a random seed (used in `next_frame`) | `var _rng := RngStreams.make("exhaust_flames")` |
| `engine.gd` → `_init` | `Benchmark.active ? RNG_SEED : _rng.randomize()`. Rechecked: the `Benchmark` autoload still exists (`benchmark_mode.gd`, with `active` and `RNG_SEED`) | `_rng = RngStreams.make("engine")`. Drop the `Benchmark` branch |
| `loading_tips.gd` → `_pick_avoiding` (static) | `randi_range` | `RngStreams.shared("loading_tips")` |
| `music_library.gd` → `_random_from_pool` (static) | `randi()` | `RngStreams.shared("music")` |
| `cloud/cloud_sync.gd` → `_go_offline` | `randf_range` backoff jitter | `RngStreams.make("cloud_sync")` instance var |
| **Not in the spec:** `title_boot.gd` → `_ready` | `WorldSession.new_world(randi(), …)` | `RngStreams.make("world").randi()` |

These are already seeded and need no change: `engine_audio_synth.gd` (`_rng.seed = 1`), `spectator_group.gd`
(`_rng.seed = params.seed`), and the local `rng.seed =` in `ground_cover.build_tuft`, `log_pile.build`,
`level_spectators.place`, `dust_puffs` blob and `exhaust_flames.build_frames`. Spectator group seeds come from
`ScatterMath.hash01(i,…)`.

**Portability note:** `exhaust_flames.build_frames` seeds with Godot's `hash("exhaust_flame_%d")`. Rust would
have to copy Godot's String hash, so see open question 6.

### B. Wall clock in game logic
| File → function | What | Fix |
|---|---|---|
| `level_streamer.gd` → `_plan` (`_plan_us`, `ts.wanted_us` against `NEAR_WANT_HOLD_US`), `_path_due` (`since_s`), `_run_queue` / `_dispatch_build` (`job.started_us`), `near_build_s` measured near line 970 | Which near tiles are held or dropped, and the build order (starvation through `near_overdue`), depend on real microseconds | Add `var _clock_us := 0` and `func _now_us()`, which returns `_clock_us` when `Benchmark.golden`, else `Time.get_ticks_usec()`. Use it at those four sites. `_clock_us += int(delta * 1e6)` in `_process` |
| `level_streamer.gd` → `_process` / `budget_us`, `_atomic`/`_est`, `_peak_us`; `ground_cover.gd` → `stream` (deadline) | How much work gets done per frame | Golden drains everything (see D) |
| `level_streamer.gd` → `prefill_async` | Slices of `prefill_slice_ms` of wall time with `await process_frame` between them, so the **number of pre-roll frames and physics ticks before replay tick 0 depends on machine speed**. Everything tick-counted inherits this (weather clock, crowd stagger, car idle state) | Golden: `prefill()` plus `_settle_cover()` with no awaits |
| `music_director.gd` → `_audio_now` | `Time.get_ticks_usec()` drives the music grid (1.4 traces music state) | Golden: `return Engine.get_physics_frames() / float(Engine.physics_ticks_per_second)` |
| `adaptive/adaptive_controller.gd` → `from_dict` | reads `Time.get_ticks_usec()` for the `backoff_until_s` clamp | Make it `from_dict(d, now_s: float)`; the caller `adaptive_graphics.gd` → `setup` passes `_now()`; tests pass `0.0` |
| `save_manager.gd` → `save` (`updated_utc`), `cloud_sync.gd:295` stamp | Wall-clock fields in the save | Keep them. Trace writers strip `const WALL_CLOCK_KEYS := ["updated_utc"]` (used when 1.4 dumps the save) |

Wall-clock reads that are present-only or measurement-only can stay. These are all the `PerfLog.track`
brackets, the `load_ms` timers, `hud_dial` blink, the `level_view` shop orbit (`_orbit_t0`), `photo_mode*`,
`cloud_busy`, `auth_service`, `frame_sampler` / `adaptive_graphics._now` (adaptive is off in replays) and
`level_stats`.

### C. Frame-timing dependence (game state in `_process` or idle timers)
| File → function | Fix (all modes, not just golden) |
|---|---|
| `level_weather.gd` → `_process` (`drive_time += dt`, `_wanted`, `_show` → `view.apply_weather`, which sets `cfg.weather`; `drivetrain.gd:802` grip and `crosswind.gd:35` wind read it) | Split it. `_physics_process(dt)` does `drive_time += dt` plus the want/`_show`. `_process(dt)` keeps only `_step(dt)` (the fade is presentation) |
| `level_view.gd` → `_timed_process`: `_check_delivery()` and the `_car.mass = … delivery kg` line | Move both into `_timed_physics_process` |
| `level_spectators.gd` → `_timed_process` (`_collect_placed`, the `_since` / `CHECK_S` timer, `refresh`) | Rename to `_physics_process` / `_timed_physics_process` and keep the `PerfLog` key |
| `level_map.gd` → `_timed_process`: the `_reveal_clock` / `reveal_at_car` branch (discovery is saved state) | Move that branch into a new `_physics_process`. Panning and the painter poll stay in `_process` |
| `spectator_group.gd` → `_timed_physics_process`: `(Engine.get_physics_frames() + _sim_stagger) % interval` (an absolute counter that includes pre-roll) | A per-group `_ticks += 1` counter instead |
| `level_view.gd` → pose-save `Timer` (near line 268, idle callback) | `timer.process_callback = Timer.TIMER_PROCESS_PHYSICS` |
| `level_view.gd` → `_on_gave_up`: `create_timer(wreck_page_delay_s, false)` | `create_timer(…, false, true)` (process in physics) |
| `level_trees.gd` → `update` → `_pump(REPACKS_PER_FRAME)` and `_update_collision` (one hitbox tile per frame) | Golden drains (see D) |

### D. Threads and completion timing
| Use | Under golden |
|---|---|
| `level_streamer` chunk builds (`_dispatch_build` / `_poll_builds`, `is_task_completed`) | `Config.data.threaded_chunk_build = false`, so the main-thread path runs. Drain every frame |
| `ground_cover` tile jobs (`_dispatch_tile` / `_poll_tiles`; the same flag) | Off by the same flag. Drain every frame |
| `level_trees` tile packs (`_repack` wide, `_collect_done`) | `Config.data.threaded_tree_build = false`, plus `settle()` |
| `level_spectators` placement (`_threaded()` is `OS.has_feature` only) | `_threaded()` gets `and not Benchmark.golden`, so it spawns synchronously |
| `spectator_group._steer_wide` (group task, joined at once) | Deterministic. Off by default (`threaded_spectators=false`). See open question 4 |
| `Thread`: `level_map` painter, `engine_audio_feed`, `level_view.load_level` bake thread (only with no bake and not headless) | Present, audio, or never in golden |
| Physics: `project.godot` has `3d/run_on_separate_thread=true` | Golden writes an `override.cfg` with `[physics] 3d/run_on_separate_thread=false` |

Turning threads off in golden also removes `OS.get_processor_count()` from the results (`_max_builds` during
prefill, `cover.max_inflight`).

### E. Everything that runs per frame (for the parity checklist)
- **Present only:** `camera_manager` (cycle input), `car_card_preview`, `display_stretch`, `engine_audio`,
  `hud`, `level_minimap`, `level_stats`, `loading_screen`, `mobile_controls`, `npc_dialogue` (typewriter),
  `perf_log`, `photo_mode*`, `post_process_view`, `route_arrow`, `speed_lines`, `teleport_beacons`,
  `web_fullscreen`. Also `level_trees._step_falls`: the hitbox is already disabled in `knock_down`; only the
  card animates. And the `process_frame` hooks in `level_view` (`_sync_mouse`, `_place_service_prompt`,
  `_place_money`, `_follow_photo_cam`).
- **Game state:** the C rows.
- **World streaming:** the D rows.
- **Ruled out:** cloud. `cloud_manager._ready` returns when headless, and `_can_sync` is false under
  `Benchmark.active`. Adaptive graphics is disabled under `Benchmark.active` unless `force_on`.

## 2. Design

- **`scripts/rng_streams.gd`** (`class_name RngStreams`, static, no autoload, with the Docs/Tests breadcrumb):
  - `static var game_seed: int` comes from `--seed=N` in `OS.get_cmdline_user_args()`, or else a random boot
    seed. That random seed is the one place an unseeded RNG is allowed.
  - `static func make(name: String, id := 0) -> RandomNumberGenerator` returns a fresh generator with
    `seed = fnv1a32("%d/%s/%d" % [game_seed, name, id])`. FNV-1a 32 is masked with `& 0xFFFFFFFF` each step;
    the product stays under 2^56, so it is safe in GDScript ints, and Rust can copy it exactly.
  - `shared(name)` caches one `make(name)` per name for static callers.
  - `reseed(s)` sets `game_seed` and clears the cache.
  - `make` records `_live[key] = weakref(rng)` so the trace can dump `{key: rng.state}`.
  - Normal play stays random per boot, so weather still varies.
- **`Benchmark.golden := false`** goes in `benchmark_mode.gd`. Only the replay's `--golden` sets it. **Perf
  replays don't drain**, so benchmark numbers keep measuring real streaming.
- **`level_replay.gd`:**
  - All non-recording replays: call `RngStreams.reseed(Benchmark.RNG_SEED)` first. This keeps today's "fixed
    misfire seed" behaviour.
  - Before instantiating the level: `Save.profile_path = "user://level_replay_profile.json"`,
    `Save.profile = Save._default_profile()`, `Save.save_disabled = true` (see open question 1).
  - `--golden` sets `Benchmark.golden`, the two `threaded_*` config flags to false, and opens `--trace=<path>`.
  - It exits with code 1 and a clear message if the run is not headless, if `--fixed-fps` is missing from
    `OS.get_cmdline_args()`, if `ProjectSettings.get_setting("physics/3d/run_on_separate_thread")` is true,
    if `--adaptive` is set, or if process frames and physics frames ever stop advancing 1:1.
- **Why `--fixed-fps 60` matters:** with it, `_process` runs exactly once per physics tick with `dt = 1/60`,
  and the loop runs at CPU speed. That alone makes the C rows deterministic for goldens. Moving them onto the
  tick is still required, for normal-play frame-rate independence and for Rust's tick/present split. Do it
  after the harness exists, so the harness guards the move.
- **Golden drain:**
  - `LevelStreamer._process`, when golden: advance `_clock_us`, run the plan, timer and chunk-change check,
    call `_guard_collision()` and `_count_near_miss()`, then `_run_all()` and `_settle_cover()`.
  - `_settle_cover()` loops `cover.stream(xz, now + 60 s, _brush())` until `missing()` is empty and
    `pending() == 0`. Reuse it in `prefill_async`'s second half.
  - `LevelTrees.update`, when golden: make `_update_collision` return whether it built a tile, loop it until
    nothing is built, then `settle()`.
  - Streaming finishes during a frame's `_process`, so it is complete before the next tick.

## 3. The test that proves two replays match

- **Trace:** in `level_replay._physics_process`, golden only, before `_play_tick(i)`, write one JSON line per
  tick with `JSON.stringify(row, "", true, true)` (sorted keys, full precision). Each row holds:
  - `tick`, `Engine.get_physics_frames()`, `Engine.get_process_frames()` (these catch pre-roll drift)
  - car: `global_position`, engine `omega`, `gear`, `boost`, `nitrous_charge`, `_misfire_timer`,
    `misfire_count`, `limiter_cut_count`; damage `hp`, `wheel_toe` (4), `engine_temp`
  - weather: `LevelWeather.drive_time`, `_shown`, `Config.data.weather`; `LevelView.delivery`; money
  - world: `_trees._fallen.keys()` sorted; how many tree tiles have `hit`; `streamer.chunk_counts()`,
    `_tiles.size()`, `cover.tiles.size()`, `cover.pending()`; `level_spectators.live_count()` plus each
    group's ragdoll count and summed member positions
  - every live RngStreams `state`
  - `get_tree().paused`

  Each fix has at least one field that would diverge without it.
- **`./run_level_replay.sh --golden-check [--until=15]`:**
  - Abort if an `override.cfg` already exists. Write it, and remove it with a `trap`.
  - Run twice: `$GODOT --headless --fixed-fps 60 res://benchmark/level_replay.tscn -- --replay=… --golden
    --seed=90210 --trace=$TMP/a.jsonl`.
  - Run B with a CPU hog on every core (`yes >/dev/null &` × `nproc`, killed afterwards), so any leftover
    timing dependence shows up.
  - Compare with `cmp`. On a mismatch, print the first differing line number (that is the tick) and both
    lines, then exit 1.
  - A unit test can't do this: it needs two processes and the real level, which breaks the ~5 minute suite
    budget.
- **CI:** add a `replay-determinism` job to `.github/workflows/test.yml`. Copy the `headless` job's install,
  import and `tools/fetch_bakes.sh` steps, then run `./run_level_replay.sh --golden-check`.
- **Bare GUT tests (cheap):**
  - `tests/headless/test_rng_streams.gd`: same (seed, name, id) gives the same draws; a different name or id
    differs; `reseed` restarts `shared`; `fnv1a32` matches a known vector.
  - `tests/headless/test_no_global_rng.gd`: scans `scripts/**/*.gd`, skipping whole-comment lines and
    `rng_streams.gd`. It fails on `(?<![\w.])(randf|randi|randf_range|randi_range|randfn|randomize|seed)\s*\(`,
    on any `.shuffle(` / `.pick_random(`, and on any `var X := RandomNumberGenerator.new()` whose file has no
    `X.seed =` or `X.state =`.
- **Tests to update:**
  - `test_adaptive_controller.gd`: the `from_dict` signature.
  - `test_level_spectators.gd`: `_NobodyPlaced` is unaffected.
  - `test_level_weather.gd`: drive it through `_physics_process` if it calls `_process`.
  - `test_level_view.gd`: the `map._process` pan test stays valid; the `_check_delivery()` calls still work.
- **Parent's targeted run afterwards:** `test_rng_streams`, `test_no_global_rng`, `test_damage_model`,
  `test_dust_puffs`, `test_wheel_particles`, `test_engine_smoke`, `test_exhaust_flames`, `test_engine`,
  `test_loading_tips`, `test_music_library`, `test_music_director`, `test_cloud_sync`, `test_world_session`,
  `test_level_weather`, `test_weather_library`, `test_level_spectators`, `test_spectator_steering`,
  `test_spectator_damage`, `test_level_view`, `test_level_discovery`, `test_level_streamer`,
  `test_ground_cover`, `test_level_trees`, `test_tree_fall`, `test_adaptive_controller`,
  `test_adaptive_graphics`, `test_benchmark_report`, `test_script_breadcrumbs`, `test_features_docs`,
  `test_smoke`. Then the full suite once, then `--golden-check`.

## 4. Order of work
1. **Harness first:** `Benchmark.golden`, the `level_replay` golden flags, guards, fixture profile and trace,
   plus `--golden-check`. Run it once; expect divergence. That is the baseline.
2. **RngStreams:** convert every A row, add the two GUT tests. This can run in parallel with step 1.
3. **Deterministic pre-roll and drains:** `prefill_async` golden path, the streamer clock and drain,
   `_settle_cover`, the tree drain, spectators `_threaded()`.
4. **Remaining clocks:** `spectator_group` counter, music clock, `AdaptiveController.from_dict`.
   `--golden-check` should now pass, including under CPU load.
5. **C rows onto the tick:** weather split, delivery and mass, spectator refresh, map reveal, the two timers.
   Re-run `--golden-check`.
6. **CI and docs:**
   - The CI job.
   - A "Golden replay" section in `features/benchmark.md`, holding the audit tables from section 1. They are
     the start of the 1.10 parity checklist.
   - `features/testing.md`.
   - Touched area docs: `weather.md`, `spectators.md`, `level-streamer.md`, `trees.md`,
     `adaptive-graphics.md`, `music.md`, `damage.md`, `dust-puffs.md`, `wheel-dust.md`, `engine-smoke.md`,
     `exhaust-flames.md`, `level-editor.md` (deliveries and discovery).
   - Correct `benchmark.md`'s "Benchmark.active seeds the misfire RNG" line.
   - Add the extra sources (title_boot, profile, `_plan_us`, `get_physics_frames`, map reveal, timers, music
     clock, `from_dict`, pre-roll) to spec 1.1, and tick 1.1.
7. **Reviewer break test, by hand:** revert one fix at a time (for example the golden `prefill_async` path, or
   one `randf`) and confirm `--golden-check` fails at a sensible tick.

## 5. Open questions
1. **Fixture profile for every non-recording replay** (web benchmark included), or golden only? I recommend
   all of them: today's behaviour silently uses and writes the real profile. It does change benchmark
   starting conditions.
2. **Physics thread:** use an `override.cfg` per golden run (my default), or turn `run_on_separate_thread` off
   in `project.godot`? Desktop performance hasn't been measured either way.
3. **Golden runs the main-thread streaming paths**, not the threaded paths desktop ships. The compute
   functions are shared, so the results should be the same. The alternative is to keep threads and drain with
   `wait_for_task_completion`.
4. **Spectator steering has two different algorithms:** the threaded `_steer_wide` updates all members from
   the old positions, while the serial loop updates in place. Golden uses serial, the default. Rust should
   port serial; consider deleting the wide path.
5. **The AdaptiveController parity test** on a synthetic sequence would pin tuning values, which conflicts
   with the `CLAUDE.md` rule against testing tuning values. Re-bless under 1.9, or defer it past 1.1?
6. **Exhaust flame seeds:** switch `hash("exhaust_flame_%d")` to `RngStreams.fnv1a32` now, before goldens are
   blessed? The flame frames would look slightly different. I recommend yes.
7. **Game seed in normal play:** random per boot (my default, today's weather variety) or tied to the
   `WorldSession` seed?
8. **Identity is only required on one machine image.** Mac ARM and the x86 CI runner may differ in floating
   point, so goldens get blessed on CI.
9. **Jolt's internal job threads** are assumed deterministic as long as body insertion order is the same. The
   hog run is the empirical check; if it fails on contacts, escalate.

### Chosen defaults (the user was away; chosen by the parent — revisit with the user)
1. Fixture profile (`user://level_replay_profile.json`, `save_disabled`) for ALL non-recording replays.
2. Physics thread: per-run `override.cfg` in `--golden-check` (don't change `project.godot`).
3. Golden uses main-thread streaming paths (`threaded_*` flags off).
4. Golden uses the serial spectator steering; do NOT delete `_steer_wide` yet.
5. AdaptiveController parity test: deferred past 1.1.
6. Exhaust flame seeds: switch `hash()` to `RngStreams.fnv1a32` now.
7. Normal play: random game seed per boot.
8. Goldens blessed on CI (x86 Linux).
9. Jolt: rely on the CPU-hog run as the empirical check.
