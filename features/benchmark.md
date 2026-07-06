# In-game Benchmark Mode

**Source:** `scripts/benchmark_mode.gd` (the `Benchmark` autoload),
`scripts/benchmark_runner.gd` (`BenchmarkRunner`), `scripts/benchmark_stats.gd`
(`BenchmarkStats`), `scripts/benchmark_results.gd` (`BenchmarkResults`), plus the
Settings page in `scripts/settings_menu.gd` and the run-scene wiring in
`scripts/world.gd`.

A one-button performance benchmark launched from **Settings → Benchmark**
(reachable from both the HQ title screen and the in-run pause menu, since both
host the shared `SettingsMenu`). It generates a fixed **long stage** (seed
`Benchmark.TRACK_SEED`, `TRACK_TURN_COUNT` = 30 turns — roughly double a normal
event), auto-drives the car down the whole track at a steady moderate pace
(`BenchmarkRunner.TARGET_SPEED_KMH` = 50 km/h), records per-frame stats the
entire way with the frame-profiler overlay forced on, and shows a results
breakdown at the finish. Not to be confused with the *standalone* CPU/chunk
benchmark (`benchmark/perf_benchmark.gd`, [debug-tools.md](debug-tools.md)) —
this one measures the real, shipped game loop on the player's machine.

## Pre-run toggles

The Settings page lists one ON/OFF row per entry in `Benchmark.TOGGLES` so a
feature's frame cost can be isolated by running with it on and off:

| Toggle | Drives |
|--------|--------|
| Trees & bushes | `cfg.vegetation_enabled` — skips the foliage scatter + fields (and the bush hit volume) entirely in `world._build_foliage` |
| Spectators | `cfg.spectators_enabled` |
| Roadside signs | `cfg.signs_enabled` — skips `world._build_signs` |
| Distant terrain | `cfg.distant_terrain_enabled` (the far horizon backdrop) |
| Road markings | `cfg.road_markings_enabled` |
| Tire marks & dust FX | `cfg.tire_marks_enabled` + `cfg.wheel_particles_enabled` + `cfg.engine_smoke_enabled` |
| Full render distance | off = `cfg.tree_render_distance_m` halved (foliage draw distance) |
| Uncap FPS (vsync off) | `cfg.target_fps` = 0, `Engine.max_fps` = 0, vsync disabled — exposes real headroom instead of pinning to the refresh rate |

All default ON (the full game as shipped). Toggle states are session-scoped
(not saved). The two feature master switches added for this
(`vegetation_enabled`, `signs_enabled` on `GameConfig`) default true and are
untouched by normal play.

## Lifecycle (the `Benchmark` autoload)

- `start()` — unpauses (the pause menu can host Settings), abandons any active
  rally, **snapshots** every `GameConfig` field it touches
  (`_OVERRIDDEN_FIELDS`), writes the benchmark stage + toggle values
  (`apply_overrides`), turns the HUD off (`cfg.hud_enabled` — the perf overlay
  is the benchmark's UI), uncaps the frame rate, sets `active = true` and loads
  `main.tscn`.
- `finish(stats)` — called by the runner at the finish line; keeps the summary
  in `Benchmark.results`.
- `exit_to_hq()` — restores the config snapshot + frame cap/vsync and returns to
  HQ. Also the pause menu's *Quit to HQ* path while a benchmark is active
  (`pause_menu.gd`), so bailing out mid-run can't leak a disabled feature or the
  fixed seed into normal play.

Like `RallySession` the autoload survives scene changes, which is what makes the
results screen's **Run again** a plain `reload_current_scene()` — the overrides
are still in place, so the identical stage regenerates and re-runs.

## The run (`world.gd` + `BenchmarkRunner`)

When `Benchmark.active`, `world.gd`:

- leaves the `StageManager` **un-armed** — no countdown, no control lock, no
  finish panel;
- hides the touch controls and (via config) the HUD;
- forces the `PerfOverlay` on (`activate()`) and points its render-time
  measurement at the `PostProcess/View` SubViewport (where the 3D pass actually
  runs);
- spawns a `BenchmarkRunner` wired to the car, the `TrackProgress` manager and
  the road centerline.

The runner drives the car through its real AI inputs (`Car.ai_controlled` —
the same hook the start-line presence cars use), **not** by teleporting it, so
the run exercises the genuine per-frame workload: vehicle physics, the tire
model, wheel dust, tire marks, engine audio. Steering is a simple pure-pursuit
follow of the centerline (`steer_toward`, look-ahead `LOOKAHEAD_M`) and speed is
held proportionally (`throttle_for`). The off-track reset (TrackProgress) is the
safety net if a corner is fumbled: the car snaps back onto the road and carries
on. The first `WARMUP_FRAMES` (car settle + first-visible shader compiles) are
left unsampled.

Each rendered frame it records: frame interval, draw calls, objects, primitives,
render CPU/GPU time (from the `PostProcess/View` viewport), and the process +
physics-process times.

## Results

At 100% track progress the runner parks the car, summarises the streams via
`BenchmarkStats.summarise` (pure/static — avg fps, **1% low** (inverse p99
frame), frame avg/p95/p99/max, spike count over 28 ms, per-stream avg/max,
distance, and which toggles were disabled), hands the summary to
`Benchmark.finish`, and shows `BenchmarkResults`: a keyboard/gamepad-navigable
panel (MenuNav-attached; Esc/B = Exit) with **Run again** and **Exit benchmark**.

## Tests

`tests/headless/test_benchmark_mode.gd` — toggle registry, the
override/snapshot/restore lifecycle, the stats summariser, the runner's pure
driving math, and a scene-integration boot (1-turn track) checking the world
gates + that the runner actually drives. `tests/headless/test_benchmark_ui.gd`
— the Settings page rows (per-toggle, focusable, flip + repaint) and the results
panel (lines carry the breakdown; nav contract per features/menus.md).
