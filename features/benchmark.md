# In-game Benchmark Mode

**Source:** `scripts/benchmark_mode.gd` (the `Benchmark` autoload),
`scripts/benchmark_runner.gd` (`BenchmarkRunner`), `scripts/benchmark_stats.gd`
(`BenchmarkStats`), `scripts/benchmark_results.gd` (`BenchmarkResults`), plus the
Settings page in `scripts/settings_menu.gd` and the run-scene wiring in
`scripts/free_roam/free_roam.gd` (`start_benchmark`).

**Tests:** `tests/headless/test_benchmark_report.gd`, `tests/headless/test_benchmark_mode.gd`, `tests/headless/test_benchmark_ui.gd`

A one-button performance benchmark launched from **Settings → Benchmark**. It boots
**free roam** on a throwaway world (seed `Benchmark.WORLD_SEED`) whose island has just
**one dead-straight road** `Benchmark.ROAD_M` long (`FreeRoamSettings.straight_road_m`,
see [free-roam.md](free-roam.md)), so the auto-driver can't fumble a corner and every
run drives the same scenery. Terrain, foliage, rest stops and biome rings still build
around the road as in play. Free roam's `AutoDriver` drives it at a calm pace
(`BenchmarkRunner.TOP_SPEED_MPS` / `LATERAL_ACCEL` / `BRAKE_DECEL`) in **chase cam**, the
car takes **no damage** (`DamageModel.invulnerable`), and `BenchmarkRunner` samples every
frame for `MAX_RUN_SECONDS` (30 s) after `WARMUP_FRAMES`, then shows the results. The
per-car engine RNG is seeded from `Benchmark.RNG_SEED` while `Benchmark.active`. Not to
be confused with the *standalone* harness (`benchmark/perf_benchmark.gd`,
[debug-tools.md](debug-tools.md)), which runs this same drive from the command line.

## Pre-run toggles

The Settings page lists one ON/OFF row per entry in `Benchmark.TOGGLES` so a
feature's frame cost can be isolated by running with it on and off:

| Toggle | Drives |
|--------|--------|
| Trees & bushes | `cfg.vegetation_enabled` — skips the foliage scatter + fields (and the bush hit volume) entirely in `world._build_foliage` |
| Spectators | `cfg.spectators_enabled` |
| Roadside signs | `cfg.signs_enabled` — skips `world._build_signs` |
| Corner barriers | `cfg.barriers_enabled` — skips `world._build_barriers` (the armco / jersey runs on the sharp corners) |
| Distant terrain | `cfg.distant_terrain_enabled` (the far horizon backdrop) |
| Road markings | `cfg.road_markings_enabled` |
| Tire marks & dust FX | `cfg.tire_marks_enabled` + `cfg.wheel_particles_enabled` + `cfg.engine_smoke_enabled` |
| Full render distance | off = `cfg.tree_render_distance_m` and the phone value `tree_render_distance_web_touch_m` halved (foliage draw distance) |
| Uncap FPS (vsync off) | `cfg.target_fps` = 0 **and** `cfg.target_fps_mobile` = 0 **and** `cfg.target_fps_web` = 0 (all three, so the cap is cleared on every target), `Engine.max_fps` = 0, vsync disabled — exposes real headroom instead of pinning to the refresh rate |

**Roadside signs** and **Distant terrain** do nothing in free roam (it has neither), so
those two rows currently measure nothing. All default ON (the full game as shipped). Toggle states are session-scoped
(not saved). The feature master switches added for this
(`vegetation_enabled`, `signs_enabled`, `barriers_enabled` on `GameConfig`) default
true and are untouched by normal play.

## Lifecycle (the `Benchmark` autoload)

- `start()` = `begin()` + load `free_roam.tscn`. `begin()` unpauses, **snapshots** every
  `GameConfig` field and writes the toggle values (`apply_overrides`), turns the HUD off,
  uncaps the frame rate, sets `active = true`, and seats the throwaway world
  (`seat_world`). The harness calls `begin()` and hosts the scene itself.
- **The player's save is never touched.** `begin()` deep-copies `Save.profile` and turns
  `Save.save_disabled` on; `seat_world()` then makes the benchmark world in memory
  (`WorldSession.new_world`). Cloud sync skips pushes while `Benchmark.active`
  (`cloud_manager.gd`). `end()` puts the copied profile and the save switch back.
  `seat_world()` runs again before every reload (Run again, the two-pass warm pass),
  because free roam writes the car's pose into the world as it drives.
- `finish(stats)` — called by the runner when the run ends; keeps the summary in
  `Benchmark.results`.
- `exit_to_hq()` = `end()` + back to the title. Also the pause menu's quit path while a
  benchmark is active (`pause_menu.gd`).

## The run (`free_roam.gd` + `BenchmarkRunner`)

When `Benchmark.active`, `free_roam.gd` duplicates its `FreeRoamSettings` and sets
`straight_road_m` (`_enter_tree`; the scene's settings resource is shared with normal
play), makes the car invulnerable, and after the shader warm-up calls
`start_benchmark()` instead of the title menu: chase camera, the streaming readout
shown, an `AutoDriver`, and a `BenchmarkRunner` wired to it. The runner sets the
driver's calm pace and puts the car on the route's first point (the route starts at the
nearest junction, which can be behind the spawn pose). The run ends at the time cap or
when the driver reaches the end of the road.

Each rendered frame the runner records: frame interval, draw calls, objects,
primitives, render CPU/GPU time (from the `PostProcess/View` viewport), and the process +
physics-process times.

**Two measurement traps to know about here** (both have already produced one
round of wrong conclusions — see `todo/performance-optimisations.md`):

- The frame interval comes from `BenchmarkRunner._frame_interval_ms()`, a
  `Time.get_ticks_usec()` delta — **not** `_process`'s `delta`. Godot's delta
  smoothing (`application/run/delta_smoothing`, on by default) snaps the reported
  delta to integer divisors of the estimated refresh rate to hide judder from
  gameplay code, which flattens exactly the hitches a profiler exists to find.
  Never profile off `delta`.
- `Performance.TIME_PROCESS` / `TIME_PHYSICS_PROCESS` (the `process_ms` /
  `physics_ms` streams, and the `[perf]` line `scripts/perf_log.gd` prints) are
  **not per-frame values**. The engine publishes them once per second and each is
  the *maximum* over that second, so they repeat unchanged for ~100+ consecutive
  frames. They are a useful "worst frame in the last second" indicator; reading
  one as "this frame's cost" — or correlating it per-frame against anything — is
  meaningless. For real per-frame attribution use `PerfLog`'s per-script counters
  or a `Time.get_ticks_usec()` bracket.

It also tracks **audio overruns** — the fielded car's engine
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

The boot hook is `title_boot.gd` → `Benchmark.autostart_requested()` /
`fetch_sweep_config()` / `apply_sweep()`. The reload poller is injected into the served
`index.html` by `serve_web.sh` (never into a shipped build).

For hands-off iteration on a real phone, load the web build with **`?bench=1`** in
the URL. On boot the title scene launches straight into a benchmark run instead of
the world, and the run POSTs its result back (below). Two pieces make it a loop with no taps:

- **Reload listener.** The page polls
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

- **Resolution sweep.** The same `/bench-config` file also takes
  `{"render_height": 720}`: while the benchmark is active, `DisplayStretch`
  lays the frame out at that logical height instead of `DESIGN_HEIGHT`
  (`scripts/display_stretch.gd` → `logical_size`'s `design_height` parameter;
  the knob lives on the autoload as `Benchmark.render_height`, set by
  `Benchmark.apply_sweep`). Sweeping several heights up to the
  device's native landscape height measures how frame cost scales with render
  resolution. The run label gains an `h<height>` part
  (`BenchmarkReport.make_label`) so the results files are distinguishable;
  each report's `device.render_size` records the resolution actually used.
  0 / absent = authored default.

- **Tree cutout sweep.** `{"tree_mode": 0|1|2}` sets `GameConfig.tree_cutout_mode` for the run
  (`Benchmark.tree_mode`; absent keeps the game's setting, which is 2 since 2026-10-27): 0 the game's opaque traced silhouette (`billboard_opaque.gdshader`),
  1 a plain card cut out per pixel at half alpha (`billboard_alpha.gdshader`, the old way),
  2 a plain card blended by its alpha (`billboard_blend.gdshader`; it writes depth, since the
  Compatibility renderer has no depth prepass and the trees otherwise drew in spawn order). The
  three share `billboard_tree.gdshaderinc`; the run label gains `_trees<mode>`. Run alternately,
  back to back, so the phone heating up affects every mode alike. Measured 2026-10-27 on an
  Android phone, three rounds each: opaque 44.4 fps, half-alpha cutout 41.1 (slowest every
  round), blend 46.0 (a tie with opaque within the ±3 fps spread). The phone is CPU-bound, so tree
  fill moves it only a few percent; the game switched to blend for its soft edges.

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


## The rating cannot price a surface-specialised tyre

`_simulate` laps the benchmark at a frozen `BENCHMARK_SURFACE_GRIP` via `mu_override`,
which bypasses `LapTimeModel._surface_grip`. That is deliberate — it is what makes a
rating comparable across regions and immune to a gravel/tarmac retune — but it means the
surface-dependent tyre terms (`tire_snow_grip_mult` / `tire_tarmac_grip_mult`) are
invisible here, and no amount of retuning will make them visible.

That gap is closed elsewhere, by **matching rather than pricing**: the rival field runs
the player's tyre, so the term cancels instead of needing a number. See
[region-stage-library.md](region-stage-library.md) → "Tyre mirroring".

`CarPerformance.merged_meta` does carry those two keys, but only so the RIVAL/ghost path
can read them — they leave the rating byte-identical.
