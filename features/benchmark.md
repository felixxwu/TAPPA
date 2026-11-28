# Benchmark (the Hafren level replay)

**Source:** `benchmark/level_replay.gd` + `benchmark/level_replay.tscn` (`LevelReplay`), run with
`./run_level_replay.sh` or `?replay=1` in a browser; `scripts/benchmark_mode.gd` (the `Benchmark`
autoload: the `active` and `golden` flags, `RNG_SEED` and `render_height`); `scripts/benchmark_stats.gd`
(`BenchmarkStats`); `scripts/benchmark_report.gd` (`BenchmarkReport`); the capture window in
`scripts/perf_log.gd`; the collector `tools/bench_collector.py` (wired into `start_web.sh`).

**Tests:** `tests/headless/test_benchmark_report.gd` (report payload, stats summariser, PerfLog capture
window); `tests/headless/test_display_stretch.gd` (landscape frame and `render_height` while `active`).

The game's one benchmark replays a recorded drive through the Hafren level and measures every frame.
The in-game island benchmark (Settings → Benchmark, `BenchmarkRunner`, `AutoDriver`,
`run_benchmark.sh`) was deleted on 2026-11-27 with the island.

## Level replay

`benchmark/level_replay.gd` (`./run_level_replay.sh`) benchmarks the level view (`GameConfig.level_path`,
Hafren Forest; [level-editor.md](level-editor.md)) on a drive a person recorded. `--record [path] [--car=<id>]` opens the level
for you to drive (with that car, else the save's) and, when you quit (pause → quit, or close the window), saves every physics tick's car pose,
velocities and inputs (default `benchmark/runs/hafren.rec`: since 2026-11-27 a 42 s fast drive in The Beast from the Cwmbiga point, recorded with `--car=beast`; `--at=<teleport>` picks another start). A recording starts where a new player does — the `level_spawn_teleport` point (`LevelView.spawn_pose`; `Benchmark.active` is off while recording) — not the level view's saved spot; a replay starts wherever its first recorded pose is, and `level_spawn` is only the fallback. With no flag it replays that file: the inputs go
through `Car.ai_controlled` and the pose is written to the physics server each tick, so the path, dust, marks and
felled trees repeat exactly; frame rate is uncapped with vsync off, frames are sampled after `WARMUP_FRAMES`, and
`BenchmarkStats.print_summary` prints the stats before it quits. Replays use the recorded
car and the chase camera, not your save: every non-recording replay (web included) swaps in a blank fixture profile
(`_use_fixture_profile`: `Save.profile_path = user://level_replay_profile.json`, a default profile, `save_disabled`), so it
starts from the same money, cars and discovery on every machine and never writes the player's profile. A replay stops after `DEFAULT_UNTIL_S` (15 s); `--full` plays the whole
drive, `--until=<s>` any length, and `--off=DustPuffs,BushInteraction*,GroundCover` hides and stops the scene nodes with those names (wildcards) or script classes first (hidden ground cover also builds no tiles), to isolate a feature's
cost. Every frame over `BenchmarkStats.SPIKE_MS` is printed with its time and the car's position.

While replaying, the replay sets `Benchmark.active`, which the rest of the game reads to hold still for it:
every seeded RNG restarts from `Benchmark.RNG_SEED` (`RngStreams.reseed`, called before the level loads), nothing syncs to the cloud
(`CloudSync._can_sync`), adaptive graphics stays at its authored settings, the web fullscreen prompt is
kept hidden (`web_fullscreen.gd`, which rechecks when the flag flips), and the frame is laid out landscape (below).

## Golden replay (determinism check)

`./run_level_replay.sh --golden-check [path] [--until=15]` replays the drive twice with
`--headless --fixed-fps 60 … -- --golden --seed=90210 --trace=<file>`, the second time with a `yes` CPU hog on every
core, and `cmp`s the two traces; on a mismatch it prints the first differing tick and both lines and exits 1. It
writes an `override.cfg` turning `physics/3d/run_on_separate_thread` off for the two runs (removed by a `trap`) and
refuses to start if one already exists.

`--golden` sets `Benchmark.golden` and turns `threaded_chunk_build` / `threaded_tree_build` off. `_golden_ready` quits
with code 1 unless the run is headless, has the physics thread off and has no `--adaptive`;
`_trace_tick` also quits if process and physics frames ever stop stepping 1:1. `_trace_tick` writes one sorted-key
JSON line per tick before the tick's inputs are applied: frame counters, pause, the car's position and engine state,
damage, weather, delivery, money, felled trees, streamer/cover counts, crowd groups and every live
`RngStreams.live_states()`. Perf replays never set `golden`, so their numbers still measure real streaming.
Under `golden` the world streams by frame count, not time: `LevelStreamer.prefill_async` fills in one go (its
`prefill_slice_ms` slices were what made the frames before the pause menu arms vary), the streamer, cover and
`LevelTrees` drain everything due each frame, and `LevelSpectators` places crowds inline. The plan
for making the check pass is `todo/2026-11-28-phase-1-1-determinism-plan.md`.

## The report

`_report` builds the JSON with `BenchmarkReport.build`: the `BenchmarkStats.summarise` block plus `distance_m` (`_driven_m`: the recorded path over the ticks played) (avg fps,
**1% low** (inverse p99 frame), frame avg/p95/p99/max, spikes, per-stream avg/max of draws / objects /
prims / render cpu+gpu / process / physics), a per-script CPU breakdown (`scripts`, from
`PerfLog.begin_capture()` / `end_capture(frame_count)`, a capture window that works in release builds
too), the `device` probe (`BenchmarkReport.probe_device`), `load_ms` (`LevelView.load_ms`: `parse`,
`bake_load`, `decode`, `tree_setup`, `buildings_read`, `built`, `prefill`, `warm_up` in ms,
`engine_to_ready` and `ready_at`), and a `label`: `level-replay-<recording>` plus `-off-<nodes>`,
`-flatsky`, `-notimers` or `-adaptive`.

It also carries:
- `frames`: every sampled stream frame by frame, plus the replay time, the car's position, the streamer's
  in-flight chunk builds, queued chunk jobs and in-flight cover tiles, the full-detail terrain's state
  (`speed_mps`, `near_misses`, `near_build_ms`, `near_overdue`, `due_near`, `due_collision`;
  [adaptive-graphics.md](adaptive-graphics.md)), and `scripts_ms` (each `PerfLog.track` key over 0.5 ms
  since the previous frame; the level's per-frame scripts `level_view`, `level_trees`, `terrain_streamer`,
  `ground_cover`, `level_spectators`, `level_minimap`, `level_map`, `route_arrow` are tracked), so a spike
  can be lined up with what was loading at the time.
- `draw_breakdown`: the on-screen meshes per owning node at the draw-call peak.
- `adaptive`, with `--adaptive` (`&adaptive=1`): adaptive graphics runs during the replay (it is
  otherwise off) and its setting changes are listed.

A browser holds the frame to the screen's refresh, so `frame_ms` hides headroom; the replay also samples
`busy_ms`, the main-thread time from a frame's first physics or process step to
`RenderingServer.frame_post_draw` (scripts, physics and draw submission, not GPU time), which
`BenchmarkStats.summarise` reports as `busy_avg_ms` / `_p95` / `_p99` / `_max`.

A native replay writes the whole report to `user://level_replay_report.json` (`LevelReplay.REPORT_PATH`).
A web replay POSTs it to `/bench` on the page's own origin (the collector, below).

**Two measurement traps** (both have produced wrong conclusions before):

- The frame interval is a `Time.get_ticks_usec()` delta, **not** `_process`'s `delta`. Godot's delta
  smoothing (`application/run/delta_smoothing`, on by default) snaps the reported delta to divisors of the
  refresh rate, which flattens exactly the hitches a profiler exists to find. Never profile off `delta`.
- `Performance.TIME_PROCESS` / `TIME_PHYSICS_PROCESS` (the `process_ms` / `physics_ms` streams, and the
  `[perf]` line `scripts/perf_log.gd` prints) are **not per-frame values**: the engine publishes each once
  per second as the maximum over that second. For per-frame attribution use `PerfLog`'s per-script
  counters or a `Time.get_ticks_usec()` bracket.

## Representative render resolution

The web build's render resolution follows the browser canvas: a phone held in portrait renders at ~1/4
the pixels of landscape ([mobile-controls.md](mobile-controls.md) → "Web fullscreen"), which would make the
replay under-measure GPU/fill cost. So while `Benchmark.active`, `DisplayStretch`
(`scripts/display_stretch.gd`, `benchmark_window_size`) lays the frame out against a **landscape** window
size; it is squished on screen, but the replay has no viewer. `Benchmark.render_height`, when above 0,
overrides the layout height too (`DisplayStretch.design_height_for`); nothing sets it today, it stays at 0.

## On the phone (`start_web.sh`)

```
edit code → ./start_web.sh → open https://<mac-LAN-IP>:8080/?replay=1 on the phone (accept the
one-time self-signed-cert warning) → the report POSTs back → build/bench-results/*.json → analyse → repeat
```

`?replay=1` boots straight into the replay (`title_boot.gd`) and takes the same flags from the URL
(`&until=30`, `&full=1`, `&off=...`, `&adaptive=1`). A web build includes the level and `benchmark/runs/`.

- **The collector.** `tools/bench_collector.py` serves `build/web` **and** accepts `POST /bench`, writing
  each report to `build/bench-results/<utc>-<label>.json` (git-ignored) and printing a one-line headline.
- **Reload listener.** `start_web.sh` injects a poller into the served `index.html` (never a shipped
  build) that polls `GET /reload-token` each second and reloads when it changes. The token embeds the
  collector's start time, so restarting `start_web.sh` flips it; `POST /reload` bumps it by hand.
- **Rebuild on save.** While serving, `start_web.sh` watches the game's source (`watch_and_rebuild`: a
  fingerprint of scripts, shaders, scenes, models, icons, levels and project settings, checked every 2 s)
  and re-exports `build/web` when it changes. It does NOT change the reload token, so open pages keep
  running until refreshed. `--no-watch` turns it off. The poller also checks `GET /build-id` (the contents
  of `build/web-build-id`, rewritten only after a rebuild is exported AND re-injected) and prefixes the tab
  title with "⟳ New build, refresh" once it changes.

Web autoplay policy suspends audio until a user gesture, so a replay that boots straight from the URL
never starts audio.

## Level draw calls

`tools/level_draw_calls.tscn` counts the level view's draw calls: it parks the car at a few road spots (`DRAW_SPOTS`, fractions of the
road samples), prints the frame's draw calls / objects / primitives, then how many each part adds by hiding it (trees, ground cover,
terrain chunks, buildings, log piles, spectators, car); `DRAW_OUT=<dir>` also saves a screenshot per spot for before/after comparisons.
Needs a window: `xvfb-run -a godot --path . --rendering-driver opengl3 res://tools/level_draw_calls.tscn` (and the level's bake, see
[level-editor.md](level-editor.md)). Hafren, 2026-11-22, mean of 4 spots: 288 calls before merging tree species and buildings, 250 after
(terrain chunks ~154, ground cover ~64, trees ~15, buildings 1, log piles ~2, sky/car/UI the rest). The horizon terrain level then
added ~46 (296); doubling the level's chunks to 96 m (`LevelStreamer.Settings`) took it to 180 (terrain: near 17, mid 8,
far 39, horizon 17). The probe prints that per-level split as `ground_near` / `_mid` / `_far` / `_horizon`.
