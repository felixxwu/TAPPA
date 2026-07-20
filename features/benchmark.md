# In-game Benchmark Mode

**Source:** `scripts/benchmark_mode.gd` (the `Benchmark` autoload),
`scripts/benchmark_runner.gd` (`BenchmarkRunner`), `scripts/benchmark_stats.gd`
(`BenchmarkStats`), `scripts/benchmark_results.gd` (`BenchmarkResults`), plus the
Settings page in `scripts/settings_menu.gd` and the run-scene wiring in
`scripts/world.gd`.

A one-button performance benchmark launched from **Settings → Benchmark**
(reachable from both the HQ title screen and the in-run pause menu, since both
host the shared `SettingsMenu`). It generates a fixed **long stage** (seed
`Benchmark.TRACK_SEED`, `TRACK_TURN_COUNT` = 10 turns — a short stage, quick to
run), auto-drives the car down the whole track at a steady moderate pace
(`BenchmarkRunner.TARGET_SPEED_KMH` = 50 km/h), records per-frame stats the
entire way with the frame-profiler overlay forced on, and shows a results
breakdown at the finish. The run is fully deterministic: the stage geometry
(track, terrain, foliage, signs) is seeded off `Benchmark.TRACK_SEED`, and while
`Benchmark.active` the per-car engine RNG is seeded from `Benchmark.RNG_SEED`
(instead of `randomize()`) so damage misfires and their smoke FX also repeat
identically run-to-run. Not to be confused with the *standalone* CPU/chunk
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
| Uncap FPS (vsync off) | `cfg.target_fps` = 0 **and** `cfg.target_fps_mobile` = 0 **and** `cfg.target_fps_web` = 0 (all three, so the cap is cleared on every target), `Engine.max_fps` = 0, vsync disabled — exposes real headroom instead of pinning to the refresh rate |

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
physics-process times. It also tracks **audio overruns** — the fielded car's engine
`AudioStreamGenerator` buffer underruns (`EngineAudio.skip_count()` →
`AudioStreamGeneratorPlayback.get_skips()`), a per-frame delta so a skip is
attributed to the (usually slow) frame it happened on; the run total is reported as
`audio_skips` and per-spike as `audio_skips`. (NB: web autoplay policy suspends the
audio context until a user gesture — an auto-started `?bench=1` run measures 0 skips
because audio never starts; launch the benchmark from Settings, which involves a tap,
to measure real audio behaviour.)

## Results

At 100% track progress the runner parks the car, summarises the streams via
`BenchmarkStats.summarise` (pure/static — avg fps, **1% low** (inverse p99
frame), frame avg/p95/p99/max, spike count over 28 ms, per-stream avg/max,
distance, and which toggles were disabled), hands the summary to
`Benchmark.finish`, and shows `BenchmarkResults`: a keyboard/gamepad-navigable
panel (MenuNav-attached; Esc/B = Exit) with **Run again** and **Exit benchmark**.

## Representative render resolution

The web build's render resolution follows the browser canvas: a phone held in
**portrait** renders at ~1/4 the pixels of landscape (the logical width collapses —
see [mobile-controls.md](mobile-controls.md) → "Web fullscreen"), which would make
the benchmark **under-measure GPU/fill cost**. To keep runs representative even when
the auto-profiling loop boots with no gesture to go fullscreen, `DisplayStretch`
(`scripts/display_stretch.gd`, `benchmark_window_size`) lays the frame out against a
**landscape** window size while `Benchmark.active` — a portrait window still renders
the landscape pixel count (visually squished, but the auto-driven run has no
viewer). Normal play is untouched.

## Dev auto-profiling loop (iterate on the phone)

For hands-off iteration on a real phone, load the web build with **`?bench=1`** in
the URL. On boot `hq.gd` (`_should_autostart_benchmark`) then launches straight into
a benchmark run — skipping the HQ it would discard — and the run POSTs its result
back (below). Two pieces make it a loop with no taps:

- **Reload listener.** The export's `head_include` (`export_presets.cfg`) polls
  `GET /reload-token` each second and reloads the page when the token changes. The
  collector's token embeds its start time, so a **rebuild** (which restarts
  `serve_web.sh`) flips it automatically; `POST /reload` bumps it to force a reload
  without a rebuild. So a dev's edit→rebuild cycle re-runs the benchmark on the
  phone unattended.
- **Remote toggle sweep.** On a `?bench=1` boot the game fetches `GET /bench-config`
  (a synchronous XHR) and disables the benchmark toggles it names
  (`{"disabled": ["spectators", ...]}`) before starting — so a dev drives a full
  toggle sweep from the workstation (write `build/bench-config.json` + `POST
  /reload`) with **no shippable config change**. Empty / missing = full baseline.

`?bench=1` gates the whole thing, so it can never ship on by default.

## Feedback loop (report POST-back)

**Source:** `scripts/benchmark_report.gd` (`BenchmarkReport`), the capture window
in `scripts/perf_log.gd`, the POST in `scripts/benchmark_runner.gd`
(`_report`/`_resolve_report_url`), the status line in `scripts/benchmark_results.gd`
(`set_report_status`), and the collector `tools/bench_collector.py` (wired into
`serve_web.sh`).

The point of this loop is to profile per-system cost **on the actual phone** and
get the numbers back to a dev machine (or Claude) to iterate — no push to prod:

```
edit code → ./serve_web.sh → open https://<mac-LAN-IP>:8080 on the phone (accept
the one-time self-signed-cert warning) → run Settings → Benchmark → results POST
back → build/bench-results/*.json → analyse → edit → repeat
```

- **What a run reports.** At the finish, the runner builds a JSON report
  (`BenchmarkReport.build`, pure/testable) carrying: the `BenchmarkStats.summarise`
  block (fps + 1% low, frame p95/p99/max, draws/objects/prims, render cpu/gpu,
  process/physics ms, spikes), a **per-script CPU breakdown** (`scripts`:
  ms/frame per instrumented script — `engine_audio`, `car`, `terrain_manager`, …),
  the `device` context (`RenderingServer.get_video_adapter_name()`, OS/model,
  browser UA on web, cpu count, build version), the `disabled_toggles`, and a run
  `label` (build version + which toggles were off).
- **Per-script capture in RELEASE.** `PerfLog`'s per-second logger is debug-build
  only, but the benchmark needs the per-script numbers from the *representative
  release* web build. `PerfLog.begin_capture()` / `end_capture(frame_count)` open
  a second accumulator that `track()` always feeds (independent of
  `OS.is_debug_build()`); the runner opens it right after warm-up so the window
  lines up with the sampled frames, and closes it at the finish, averaging over
  the frame count it sampled.
- **Where it POSTs.** `_resolve_report_url()`: an explicit
  `GameConfig.bench_report_url` wins (set it on an installed **APK** to reach your
  dev machine, e.g. `http://192.168.1.50:8080/bench`); otherwise on a **web**
  build it POSTs to `/bench` on the page's own origin (`window.location.origin`
  via `JavaScriptBridge`) — so the `serve_web.sh` LAN loop is zero-config.
  Skipped headless / when nothing resolves (desktop dev). The results panel shows
  `reporting…` → `reported ✓` / `report failed …`.
- **The collector.** `tools/bench_collector.py` serves `build/web` **and** accepts
  `POST /bench`, writing each report to `build/bench-results/<utc>-<label>.json`
  (git-ignored) and printing a one-line headline to the terminal. `serve_web.sh`
  runs it, so the game is served and reports are collected on the same origin/port.
- **Isolating a system.** Two attribution paths feed the same collector: a single
  run already separates CPU (per-script + physics ms) from GPU (draws/prims/render
  gpu); a **toggle sweep** (baseline, then one Settings→Benchmark toggle off at a
  time — trees, distant terrain, signs, FX, render distance) posts one labelled
  report each, and the frame-cost deltas pin terrain vs objects vs FX.

## Tests

`tests/headless/test_benchmark_report.gd` — the report payload assembly, the
run-label (baseline vs disabled-toggle naming, filename-safety), and the PerfLog
capture window (averaging over frame count, ignoring out-of-window tracks).
`tests/headless/test_benchmark_mode.gd` — toggle registry, the
override/snapshot/restore lifecycle, the stats summariser, the runner's pure
driving math, and a scene-integration boot (1-turn track) checking the world
gates + that the runner actually drives. `tests/headless/test_benchmark_ui.gd`
— the Settings page rows (per-toggle, focusable, flip + repaint) and the results
panel (lines carry the breakdown; nav contract per features/menus.md).
