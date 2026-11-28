# Benchmark (the Hafren level replay)

**Source:** `benchmark/level_replay.gd` + `benchmark/level_replay.tscn` (`LevelReplay`), run with
`./run_level_replay.sh` or `?replay=1` in a browser; `scripts/benchmark_mode.gd` (the `Benchmark`
autoload: the `active` and `golden` flags, `RNG_SEED` and `render_height`); `scripts/benchmark_stats.gd`
(`BenchmarkStats`); `scripts/benchmark_report.gd` (`BenchmarkReport`); the capture window in
`scripts/perf_log.gd`; the collector `tools/bench_collector.py` (wired into `start_web.sh`); `tools/device_targets.py` (the device targets table).

**Tests:** `tests/headless/test_benchmark_report.gd` (report payload, stats summariser, PerfLog capture
window); `tests/headless/test_display_stretch.gd` (landscape frame and `render_height` while `active`).

The game's one benchmark replays a recorded drive through the Hafren level and measures every frame.
The in-game island benchmark (Settings → Benchmark, `BenchmarkRunner`, `AutoDriver`,
`run_benchmark.sh`) was deleted on 2026-11-27 with the island.

## Level replay

`benchmark/level_replay.gd` (`./run_level_replay.sh`) benchmarks the level view (`GameConfig.level_path`,
Hafren Forest; [level-editor.md](level-editor.md)) on a drive a person recorded. `--record [path] --car=<id>` opens the level
for you to drive (with that car; see "Input recording and free replay") and, when you quit (pause → quit, or close the window), saves every physics tick's car pose,
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
core, and `cmp`s the two traces; on a mismatch it prints the first differing tick, the first differing key and both
values, and exits 1. Both runs also write the event log with `benchmark/runs/game_script.json` (see "Game-state event
log"), and the two event files are `cmp`ed too. It
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

## Scene counts (golden)

`benchmark/scene_counts.gd` (`SceneCounts`), run with
`godot --headless --fixed-fps 60 res://benchmark/scene_counts.tscn -- [--golden] [--seed=90210] [--out=<file>] [--check[=<golden>]] [--bless]`
(`./bless.sh scene_counts` passes `--golden --seed=90210 --bless`, which also writes `goldens/scene_counts.jsonl.gz`), lists what
stands near four pinned road spots (`SPOTS`, fractions of the road samples, picked as `tools/level_draw_calls.gd`
picks them) once streaming has finished and before anything moves. It boots `Scenes.WORLD` on the blank fixture
profile with `Benchmark.golden` and `RngStreams.reseed`, pauses the tree once the level has loaded, then per spot
puts the car there (`reset_to(road_pose(...))`), runs `prefill_async` and `LevelTrees.settle`, drops the crowds placed
while loading and places them again inline (`LevelSpectators.refresh`). `collect` lists every item within `RADIUS_M`
as `[type, x, y, z]`: trees (`tree:<species>`, from the bake, minus felled ones), bushes (each cover tile's
`BushField._points`; grass tufts are left out), buildings (`LevelBuildings.boxes` centres), fences (the collision
boxes in `LevelFences.bodies`), log piles (the `LogPile*` bodies, where `_log_pile` really put them) and spectators
(each live group's `_pos` and `_home`). Flat items have y = 0. The output is JSON lines: a header
(`format`, `level_path`, `seed`, `godot_version`, `platform`, `radius_m`, `spots`), then one line per spot
(default `user://scene_counts.jsonl`). `--check` pairs each spot's items with the golden's through
`SceneCounts.match_items` (bare `--check` reads `goldens/scene_counts.jsonl.gz`; a `.gz` path is gzipped; same type within `TOLERANCE_M`, 1 cm, nearest first, on a 1 cm grid; positions aren't
rounded, so values either side of a rounding boundary still match), prints every unmatched item and exits 1 on any.
Tests: `tests/headless/test_scene_counts.gd` (the matcher).

## Game-state event log

`benchmark/game_trace.gd` (`GameTrace`) logs what the game does during a replay so two runs (or Godot and Rust) can be
compared event for event. Each tick `GameTrace.read(view, car)` takes a cheap snapshot (money, the delivery in progress,
finished deliveries, owned cars and bought parts from `Save`, the shown and live weather, the discovery grid's lit-cell
count and MD5, `LevelRallies.active`, the car's `damage.hp` / `engine_temp` / gave-up, the engine's one-shot sound flags
and counters, and the beeps since the last read), and `GameTrace.diff(prev, now, tick)` turns two snapshots into events
`{tick, kind, ...}` in a fixed kind order: `money`, `delivery_started`, `picked_up`, `delivered`, `delivery_dropped`,
`bought_car`, `bought_part`, `weather`, `discovered`, `rally`, `hp`, `engine_temp`, `wrecked`, `beep`, `engine_sfx`.
`hp` and `engine_temp` carry the value so the Rust side can apply its own tolerance.
- Beeps come from `AudioManager.on_beep` (`scripts/audio.gd`), a static hook `play_beep` calls before its headless
  early-out, so headless CI logs them; `GameTrace.listen()` / `stop()` install and remove it.
- `GameTrace.audio_row(tick)` is the per-tick audio row: `MusicDirector.trace_state()` (song, requested song, segment,
  next handoff on the music clock, which is the tick clock under `--golden`) and every `AudioBuses` bus's volume.
- `GameTrace.final_save()` is `Save.profile` without `WALL_CLOCK_KEYS` (`created_utc`, `updated_utc`).
- `GameTrace.act(view, car, {tick, do, args})` runs a scripted step through the function the menu button calls:
  `start_delivery {teleport, delivery}` → `_start_delivery_here`, `buy_part` / `buy_car {shop, item}` → `_got_part` /
  `_got_car`, `set_rally {name}`, `money {amount}`, `wreck {hp}` → `damage.apply_loss`. Shops, stock and deliveries
  are named by index in the level file, so catalogue changes don't break a script.

In the replay, `--golden --events=<file> --game-script=<json>` (`level_replay.gd` → `_events_tick`) writes, after a
golden header line, the events seen at the start of each tick: an event tagged tick `i` was caused by ticks before
`i` (the first read is the baseline, so tick 0 has none). Then come the tick's audio row (`kind: "audio"`, only when it
changed since the last one) and that tick's scripted steps. The last line is `{kind: "final_save", save}`.
`GameTrace.act` opens the page each handler expects: the jobs page for `start_delivery` (with no `_menu_point`, so the
car isn't moved) and the map's remote shop for the buys (left open, since closing it after a car purchase reloads
the level). A buy goes straight to `_got_*`, so no money is taken.
**Events golden:** `./run_level_replay.sh --events-golden [rec] [--check | --bless]` runs this on the pose-fed
`hafren.rec`, `--full`, with `benchmark/runs/game_script.json`. `--check` compares against `goldens/events.jsonl.gz`
and prints the first differing line and key; `--bless` (from `./bless.sh events`) rewrites it; neither runs it twice and
compares the runs.
Tests: `tests/headless/test_game_trace.gd`.

## Input recording and free replay

`benchmark/tick_input.gd` (`TickInput`) is one physics tick of the driver's gameplay input: a
`PackedFloat32Array` of the strength of each `ACTIONS` entry (`accelerate`, `brake_reverse`, steer, `handbrake`,
`shift_up/down`, `nitrous`, `reset_to_road`, `pause`; menu actions are left out) plus a bitmask of the actions that
went down this tick, so a tap shorter than a tick still lands once. `sample()` reads it from `Input`; `apply(row)`
replays it through `Input.action_press` / `action_release` (the path `mobile_controls.gd` uses), so the car's own
reads, `is_action_just_pressed("shift_up")` included, see it as play. `reset_to_road` and `pause` are read from input
events, not polled, so `apply` sends them as `InputEventAction`s and flushes them at once.

A recording is format 2 (`level_replay.gd` → `FORMAT`): `file.store_var` of a header `{format, level, car, hz, seed, at,
auto_gearbox}` plus `ticks` (the format 1 pose stride, so pose-fed replays still work) and `inputs` (one `TickInput`
row per tick). `_load` still reads format 1 (`hafren.rec`, which stays the perf benchmark). Recording now needs
`--car=<id>` and, like a replay, starts from the blank fixture profile and `RngStreams.reseed(Benchmark.RNG_SEED)`, so a
recording and its free replay start from the same profile, car, seed, gearbox setting and teleport.
`--free` replays a format 2 file with no pose writes: the car stays player-driven (`ai_controlled` off), is placed at
the recorded teleport, and `level_replay.gd` → `_start_free_inputs` presses each tick's row at the END of the tick
before it (a late `_Tail` node; row 0 before ticks start). A press made during a physics tick only reads as
just-pressed on the next tick in Godot, so this is the only timing where held strength and just-pressed land on
the same tick, as a real key press does. `--script=<json> --car=<id> [--at=<teleport>]` writes a synthetic format 2 recording
(no poses) from `[{from_s, to_s, action, strength}]` (or `{auto_gearbox, steps}`) to
`benchmark/runs/synthetic_<name>.rec` and quits, for testing before a hand drive exists:
`godot --headless res://benchmark/level_replay.tscn -- --script=<json> --car=<id>` (a `car` key in the JSON
can stand in for `--car`).
A free replay must stay on the road: `_check_on_road` tracks the longest stretch where `LevelView.is_off_road`
holds, and the run exits 1 if that reaches `off_road_reset_timeout_s` or `RoadRecovery` resets the car. Its
`distance_m` comes from the car's own positions, since there are no recorded poses.
Tests: `tests/headless/test_tick_input.gd`.

### Car-step golden
`--free --golden --car-trace=<file>` writes a golden header line, then per tick, before the tick runs,
`{tick, input, snap, world}`: the `TickInput` row being played, `Car.snapshot()` (with `record_contacts` on, so
`last_contacts` holds the previous step's contact impulses) and `world` (`fallen_trees`, sorted `LevelTrees._fallen`
ids, and every live ragdoll's pose, velocities and sleep state). Tick `i`'s result is row `i+1`'s `snap`.
`tools/drift_report.py` reads this shape. `./run_level_replay.sh --car-golden [rec] [--check | --bless]` runs it over the
whole recording: `rec` defaults to `benchmark/runs/hafren_free.rec` (the hand drive) or, until that exists, a
synthetic one built fresh from `benchmark/runs/car_golden_script.json` (manual gearbox, shifts, nitrous, brake,
handbrake). `--check` compares with `goldens/car_step.jsonl.gz`, `--bless` (`./bless.sh car-step`) rewrites it, and
neither runs it twice and compares.

## Car drift report

`python3 tools/drift_report.py <golden> <candidate> [--svg out.svg] [--segment 10] [--hz 60]` compares two car
traces (the `--car-trace` JSON lines from the free replay, gzipped or not; rows without a `snap` such as the header
are skipped). It matches the runs on their shared ticks, so a run restored from a mid-run snapshot is compared from
that tick, and cuts them into `SEGMENT_S` segments. Per segment it prints the max and end distance between the two
`snap.origin`s against a tolerance of `TOL_BASE_M + TOL_GROWTH_M_PER_S × seconds into the segment`, the first tick
over it, the time each run takes to cover the golden's segment distance, top speeds and end positions; the SVG
overlays the two paths from above and plots deviation against tolerance. It is a report for review, not a gate:
it exits 0 whatever the drift. Stdlib only. `--self-test` checks it on synthetic circles (self-compare is zero
drift, a 1% slower run drifts more as each segment goes on).

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
  [adaptive-graphics.md](adaptive-graphics.md)), and `scripts_ms` (each `PerfLog.track` key over 0.5 ms; the streaming spike is split into `stream_mesh`, `stream_node`, `stream_shape`, `cover_mesh`, see [level-streamer.md](level-streamer.md)
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

## Device targets

`python3 tools/device_targets.py [report.json | dir ...]` prints this table from the reports the collector stores
(`build/bench-results/*.json`) and the native replay's `REPORT_PATH` file: the newest report per device class (`device.os/model`,
`(web)` for a browser run) and variant (the label's `-off-<nodes>` part, else `full`), with `busy_ms` and `draw_phase_ms`
p95/p99. A `-` means the report has no such samples (a headless run, or one from before the stream existed).
`--self-test` checks it on synthetic reports. Re-run it and paste the output here after measuring on a new device.

| Device class | Variant | busy p95 ms | busy p99 ms | draw_phase p95 ms | draw_phase p99 ms | Report |
|---|---|---|---|---|---|---|
| Web/GenericDevice (web) | full | 11.6 | 19.1 | 3.9 | 4.5 | 2026-11-27T17:22:55 |
| Web/GenericDevice (web) | off-BushInteraction | 15.7 | 17.9 | - | - | 2026-11-19T13:02:50 |
| Web/GenericDevice (web) | off-Collision | 15.7 | 18.3 | - | - | 2026-11-19T13:04:53 |
| Web/GenericDevice (web) | off-GroundCover | 15.9 | 18.8 | - | - | 2026-11-19T13:06:55 |
| Web/GenericDevice (web) | off-PostProcess | 15.2 | 18.0 | 8.2 | 9.3 | 2026-11-19T13:39:03 |
| Web/GenericDevice (web) | off-Trees_ | 16.3 | 18.1 | - | - | 2026-11-19T13:08:57 |
| Web/GenericDevice (web) | off-WheelParticles+DustPuffs+EngineSmoke+TireMarks | 14.1 | 15.7 | - | - | 2026-11-19T13:00:45 |
| Web/GenericDevice (web) | off-WheelParticles+DustPuffs+EngineSmoke+TireMarks+ExhaustFlames+CarLamps+BushInteraction+Collision+GroundCover+Trees_ | 11.9 | 13.5 | 6.6 | 8.0 | 2026-11-19T13:26:54 |
| Web/GenericDevice (web) | off-WheelParticles+DustPuffs+EngineSmoke+TireMarks+ExhaustFlames+CarLamps+BushInteraction+Collision+GroundCover+Trees_+HUD+MobileControls+SpeedLines | 11.1 | 12.8 | 5.7 | 7.1 | 2026-11-19T13:36:59 |
| Web/GenericDevice (web) | off-WheelParticles+DustPuffs+EngineSmoke+TireMarks+ExhaustFlames+CarLamps+BushInteraction+Collision+GroundCover+Trees_+HUD+MobileControls+SpeedLines+PostProcess | 10.4 | 11.6 | 5.3 | 6.5 | 2026-11-19T13:33:57 |
| Web/GenericDevice (web) | off-WheelParticles+DustPuffs+EngineSmoke+TireMarks+ExhaustFlames+CarLamps+BushInteraction+Collision+GroundCover+Trees_+HUD+MobileControls+SpeedLines+PostProcess-flatsky | 10.6 | 12.4 | 5.3 | 6.9 | 2026-11-19T13:35:57 |
| Web/GenericDevice (web) | off-WheelParticles+DustPuffs+EngineSmoke+TireMarks+ExhaustFlames+CarLamps+BushInteraction+Collision+GroundCover+Trees_+HUD+MobileControls+SpeedLines-flatsky | 11.4 | 12.9 | 6.0 | 7.3 | 2026-11-19T13:34:57 |
| macOS/Mac17,9 | full | - | - | - | - | 2026-11-28T05:41:49 |

## Level draw calls

`tools/level_draw_calls.tscn` counts the level view's draw calls: it parks the car at a few road spots (`DRAW_SPOTS`, fractions of the
road samples), prints the frame's draw calls / objects / primitives, then how many each part adds by hiding it (trees, ground cover,
terrain chunks, buildings, log piles, spectators, car); `DRAW_OUT=<dir>` also saves a screenshot per spot for before/after comparisons.
Needs a window: `xvfb-run -a godot --path . --rendering-driver opengl3 res://tools/level_draw_calls.tscn` (and the level's bake, see
[level-editor.md](level-editor.md)). Hafren, 2026-11-22, mean of 4 spots: 288 calls before merging tree species and buildings, 250 after
(terrain chunks ~154, ground cover ~64, trees ~15, buildings 1, log piles ~2, sky/car/UI the rest). The horizon terrain level then
added ~46 (296); doubling the level's chunks to 96 m (`LevelStreamer.Settings`) took it to 180 (terrain: near 17, mid 8,
far 39, horizon 17). The probe prints that per-level split as `ground_near` / `_mid` / `_far` / `_horizon`.
