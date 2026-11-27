# Adaptive Graphics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The level view tunes its own graphics settings live, learning what each costs on this device, to hold the frame rate without the player touching anything.

**Architecture:** A pure `AdaptiveController` (no scene access) is fed one sample per frame and decides which `AdaptiveKnob` to step up or down. A `FrameSampler` produces those samples (busy time minus loading work, GPU time, interval, draws, primitives). An `AdaptiveGraphics` node in `LevelView` owns both, builds the knobs from `GameConfig` authored values, and calls each knob's live `apply`. Each system (trees, cover, terrain, effects, weather, resolution) gets a live setter.

**Tech Stack:** Godot 4 GDScript, GUT headless tests (`tests/headless/`), `./run_tests.sh --fast <name>`.

**Spec:** `todo/2026-11-27-adaptive-graphics.md`. Read it first; its "What the user decided" and "Corrections from the second review" sections win over everything else, including this plan.

## Global Constraints

- Level view only (`Scenes.WORLD` / `LevelView`). Don't touch legacy `free_roam.gd`'s own loop.
- Never reload the scene to apply a knob. Never go above `Config.authored_value(field, …)`.
- The controller never writes `Engine.max_fps`. Target fps = `FpsSetting.resolve()` if > 0, else 60.
- Every tunable is a plain `var` in `scripts/game_config.gd` under an `# --- Adaptive graphics ---` header, prefixed `adaptive_`.
- Controller off and every knob at its authored value while `Benchmark.active`, unless the replay's `adaptive` flag is set.
- Learned state is per device: a local `user://adaptive_graphics.json`, never `Save` / the cloud-synced profile.
- Overlay text: Jersey 10 at `UITheme.FONT_SIZE` only.
- Code style (user's CLAUDE.md): almost no comments; one role line atop each new file / exported function.
- Tests: implementation first, tests at the end of each task; never assert tuning values; synthetic knobs only. **Subagents never run tests**; the parent runs them.
- No commits unless the user asks. Other agents may share the checkout: touch only the files a task lists.

## Review Focus

1. **Photo mode round-trip:** open photo mode, render, close → tree and cover distances end at the controller's current level, not the authored value and not stuck at the render's long distance. (Test in Task 5.)
2. **Car change / parts reload mid-session:** the controller's levels and estimates survive `LevelView._reload` (statics) and the new scene applies them on its first frame. (Test in Task 5.)
3. **Corrupt or old `user://adaptive_graphics.json`** (bad JSON, missing knob ids, a knob id that no longer exists, a level above the knob's max) → loads what it can, clamps, never errors. (Test in Task 5.)
4. **Hidden tab / long hitch:** a 2 s frame interval is ignored as a pause, not treated as a miss that drops three knobs. (Test in Task 2.)
5. **Benchmark started after adaptive play lowered values:** benchmark scene runs with authored values in every knob field. (Test in Task 5.)

---

### Task 1: Remove the Settings → Graphics page

**Files:**
- Delete: `scripts/graphics_settings.gd` (+ `.uid`), `tests/headless/test_graphics_settings.gd` (+ `.uid`)
- Modify: `scripts/settings_menu.gd` (`_build_graphics_page`, `cycle_graphics`, `reset_graphics`, `_refresh_graphics_rows`, `_apply_graphics_if_changed`, `graphics_rows`, `_graphics_dirty`, the page's entry in the Settings list, the `_notification` / line-~462 callers)
- Modify: `scripts/level_view.gd` (`_ready`'s `GraphicsSettings.apply` call; `reload_for_graphics`)
- Modify: `features/settings.md` (drop the "Graphics page" section and test line), `features/weather.md` (graphics-reload mention)

**Interfaces:** Produces nothing. After this task nothing references `GraphicsSettings` or `reload_for_graphics`.

- [ ] **Step 1:** Delete the files and references above. `grep -rn "GraphicsSettings\|reload_for_graphics\|graphics_rows\|cycle_graphics" scripts tests features` returns nothing.
- [ ] **Step 2:** Make sure the Settings page's MenuNav still walks its remaining rows (`features/menu-navigation.md`); adjust any nav test that counted the Graphics row.
- [ ] **Step 3 (parent):** `godot --headless --quit` loads cleanly; run `./run_tests.sh --fast settings menu_nav level_view`. Expected: PASS.

### Task 2: `AdaptiveKnob` + `AdaptiveController` (pure logic)

**Files:**
- Create: `scripts/adaptive/adaptive_knob.gd`, `scripts/adaptive/adaptive_controller.gd`
- Modify: `scripts/game_config.gd` (add the `adaptive_*` tunables listed below)
- Test: `tests/headless/test_adaptive_controller.gd`

**Interfaces:**
- Produces `class_name AdaptiveKnob extends RefCounted`:
  - `id: StringName`, `name: String`, `levels: int` (max level index = `levels - 1`), `level: int`
  - `weight: Callable` → `func(step_level: int) -> float`: visual loss of going from `step_level` to `step_level - 1`. Returns 0 for steps beyond the fog (Task 5 supplies that).
  - `prior_ms: float` (guessed cost of one step), `cost_ms: float`, `samples: int`
  - `last_resort: bool` (render resolution: cut only when every other knob is at 0, raised first)
  - `apply: Callable` → `func(level: int) -> void`
  - `backoff_until_s: float`, `fails: int`
- Produces `class_name AdaptiveController extends RefCounted`:
  - `var knobs: Array[AdaptiveKnob]`, `var enabled := true`, `var at_floor := false`
  - `var last_decision: String` (human text for the overlay, e.g. `"dropped Grass near → 6/10 (over by 3.1 ms)"`), `var last_decision_s: float`
  - `func feed(s: Dictionary) -> void`, where `s = {now_s: float, cost_ms: float, budget_ms: float, interval_ms: float, gpu_ms: float, draws: int, prims: int, quiet: bool}`. `quiet` = the streaming queues are empty. Calls knobs' `apply` itself when it decides.
  - `func disturbed(now_s: float) -> void`: abort the in-flight experiment and hold for `adaptive_settle_s`.
  - `func headroom_ms() -> float`, `func p90_ms() -> float`
  - `func to_dict() -> Dictionary` / `func from_dict(d: Dictionary) -> void` (levels, cost_ms, samples, fails, backoff; tolerant: unknown ids ignored, levels clamped)
  - `func ms_per_draw() -> float`, `func ms_per_kprim() -> float` (the per-device fit)
- GameConfig tunables (defaults are the builder's call; names fixed): `adaptive_enabled`, `adaptive_margin` (0.85), `adaptive_window_s`, `adaptive_over_hold_s` (0.5), `adaptive_raise_hold_s` (5.0), `adaptive_drop_cooldown_s` (1.0), `adaptive_settle_s`, `adaptive_experiment_s` (2.0), `adaptive_revert_window_s`, `adaptive_backoff_s` (`[30, 60, 120, 300]`), `adaptive_backoff_shrink_s`, `adaptive_estimate_decay_s`, `adaptive_pause_ms` (250), `adaptive_miss_factor` (1.5), `adaptive_fast_climb_factor`.

Behaviour to implement (spec → "The controller" + corrections 5, 6, 9, 13):

- Rolling window of samples. Over budget = p90 of `cost_ms` (or GPU, whichever is larger) above `budget_ms × adaptive_margin` for `adaptive_over_hold_s`, or repeated `interval_ms ≥ budget × adaptive_miss_factor`. A sample with `interval_ms > adaptive_pause_ms` is dropped entirely.
- Drop: if a raise happened within `adaptive_revert_window_s`, revert it and mark it a failure. Otherwise pick the non-`last_resort` knob with `level > 0` that maximises `est_cost / max(weight(level), ε)`. When all non-last-resort knobs are at 0, drop the last-resort knob. Respect `adaptive_drop_cooldown_s`.
- Raise: headroom held for `adaptive_raise_hold_s` (skip the wait when `headroom > est_cost × adaptive_fast_climb_factor`), and only while `quiet`. Last-resort knob first if it is below max. Otherwise pick the knob maximising `weight(level+1) / est_cost` with `est_cost ≤ headroom` and `now ≥ backoff_until_s`.
- One experiment at a time. Before window = `adaptive_experiment_s` of means before the change; after window = the same length, starting after `adaptive_settle_s` and only once `quiet`. Sample = mean difference ÷ steps. Discard it if `disturbed` was called inside the windows.
- `est_cost` = blend of the draws/prims fit (difference in draws/prims between the windows × `ms_per_draw` / `ms_per_kprim`) and the timed `cost_ms` running estimate, weighted by `samples`. A knob with no samples uses `prior_ms`.
- Fit: least squares of `cost_ms` against `(draws, prims/1000)` over a long decaying window (2-variable normal equations; no library).
- Failure: `fails += 1`, `backoff_until_s = now + adaptive_backoff_s[min(fails-1, 3)]`. `fails` shrinks by one every `adaptive_backoff_shrink_s` without a failure. `cost_ms` decays toward `prior_ms` over `adaptive_estimate_decay_s`.
- A last-resort drop that saves less than ≈ the noise floor counts as a failure, is reverted, and sets `at_floor = true`. `at_floor` clears when headroom returns.
- `enabled = false` → `feed` does nothing.

- [ ] **Step 1:** Implement both files and the GameConfig fields.
- [ ] **Step 2:** Write `tests/headless/test_adaptive_controller.gd`. Use a fake world: a dict of synthetic knobs whose `apply` sets a level, and `cost_ms = base + Σ level × per_step_cost[id]`, fed at 60 samples/s with a controllable `now_s`. Tests (assert behaviour only, no tuning values):
  - `test_drops_when_over_budget`: base above budget → some knob's level decreases within a few simulated seconds.
  - `test_drops_expensive_knob_first`: knob A costs 4 ms/step, B 0.2 ms/step, equal weights, after priors are learned → A is dropped before B.
  - `test_raises_when_headroom_returns`: start all at 0 with a cheap world → every knob reaches max eventually.
  - `test_backfiring_raise_is_reverted_and_backed_off`: a knob whose step costs more than the headroom → it's raised, reverted, and not raised again before `backoff_until_s`.
  - `test_never_stuck_low`: an expensive phase drives knobs down, then the cost drops → all knobs climb back to max within bounded simulated time.
  - `test_last_resort_cut_only_at_floor`: the resolution knob stays at max until every other knob is 0.
  - `test_long_interval_is_a_pause`: one sample with `interval_ms = 2000` → no drop (Review Focus 4).
  - `test_disturbed_discards_experiment`: `disturbed()` mid-experiment → `samples` unchanged.
  - `test_disabled_does_nothing`.
  - `test_roundtrip_and_tolerant_load`: `from_dict(to_dict())` keeps levels; bad ids are ignored and levels clamped.
- [ ] **Step 3 (parent):** `./run_tests.sh --fast adaptive_controller`. Expected: PASS.

### Task 3: `FrameSampler` + per-frame `PerfLog`

**Files:**
- Create: `scripts/adaptive/frame_sampler.gd`
- Modify: `scripts/perf_log.gd`, `benchmark/level_replay.gd` (use the sampler for `busy_ms` instead of its own `_mark_frame_start` / `_on_frame_drawn`)
- Test: `tests/headless/test_frame_sampler.gd`, extend `tests/headless/test_perf_log.gd` if it exists (else add to the sampler test)

**Interfaces:**
- `PerfLog.track` also adds to an always-on `_frame_us: Dictionary`. New: `func frame_us(key: StringName) -> int`, `func clear_frame() -> void`.
- Produces `class_name FrameSampler extends Node`:
  - `var viewports: Array[RID]`; `func watch(vps: Array[RID]) -> void` turns on `viewport_set_measure_render_time` for each.
  - `signal sampled(s: Dictionary)`, emitted once per drawn frame with the `feed` dict from Task 2. `quiet` and `now_s` are filled in by the caller; the sampler fills `cost_ms`, `gpu_ms`, `interval_ms`, `draws`, `prims`, `busy_ms`, `load_ms`.
  - `cost_ms = busy_ms − load_ms`, where `load_ms = PerfLog.frame_us(&"terrain_streamer") + frame_us(&"ground_cover")` in ms. `gpu_ms` = sum over watched viewports; 0 when unsupported.
  - `static func budget_ms() -> float`: `1000 / (FpsSetting.resolve() if > 0 else 60)`.
  - Busy time: first `physics_frame` / `process_frame` of a frame to `RenderingServer.frame_post_draw`, moved from `level_replay.gd`. Interval from `Time.get_ticks_usec()` deltas.
- [ ] **Step 1:** Implement. Keep `level_replay`'s report fields identical (`busy_ms`, `render_gpu_ms`, …) and keep its `_no_timers` behaviour.
- [ ] **Step 2:** Tests: `test_budget_uses_fps_setting_or_60` (the logic, not values: a cap gives `1000/cap`, uncapped gives the 60 rule); `test_cost_excludes_loading_work` (track fake `terrain_streamer` usec in a frame → `cost_ms` is lower than `busy_ms` by that amount); `test_frame_us_clears`.
- [ ] **Step 3 (parent):** `./run_tests.sh --fast frame_sampler perf_log benchmark_report`. Expected: PASS.

### Task 4: Live setters in each system

**Files:**
- Modify: `scripts/ground_cover.gd`, `scripts/level_trees.gd`, `scripts/free_roam/terrain_streamer.gd`, `scripts/dust_puffs.gd`, `scripts/engine_smoke.gd`, `scripts/wheel_particles.gd`, `scripts/tire_marks.gd`, `scripts/level_view.gd` (weather `amount_ratio`)
- Test: extend `tests/headless/test_level_trees.gd`, `tests/headless/test_level_streamer.gd`; add `tests/headless/test_live_graphics_setters.gd` for cover / effects / weather

**Interfaces (produced; Task 5 calls them):**
- `GroundCover.refresh_near() -> void`: re-reads `Config.data.ground_cover_reach/_fade_start/_fade_end`, sets `fade` on **both** `material` and `far_material`, and sets `visibility_range_end` on every built tile's near MMIs (`material_override == material`), like `_add_layer`.
- `GroundCover.refresh_far() -> void`: re-reads the far fields, sets `far_fade` and the far MMIs' ranges via `far_reach()` (so photo mode's override still wins), and frees tiles beyond the new reach.
- `LevelTrees.refresh_draw() -> void`: the body of `set_draw_override` without changing `_draw_override`.
- `TerrainStreamer.apply_rings(mid_radius: float, far_radius: int, horizon_radius_m: float) -> void`: writes `settings`, immediately `_drop_chunk` / `_drop_mid` everything beyond the new radii (no `+2` / `+1.5` hysteresis on this path), sets `_plan_timer = 0`.
- Effects (`DustPuffs`, `EngineSmoke`, `WheelParticles`, `TireMarks`): `func set_quality(f: float) -> void` with f in [0, 1]. It scales spawn rate / max live count; `0` clears the MultiMesh (`visible_instance_count = 0`) instead of freezing it. The builder picks what each script scales; the `*_enabled` bools stay as master switches.
- `LevelView.set_weather_ratio(f: float) -> void`: stores f and sets `_particles.amount_ratio`. `apply_weather` re-applies the stored f to the new `WeatherField`.
- Render resolution: `LevelView.set_render_scale(f: float) -> void` sets `scaling_3d_scale` (bilinear) on `PostProcess/View` if present.
- [ ] **Step 1:** Implement all setters. Each tolerates its target being freed or missing (replay `--off=`).
- [ ] **Step 2:** Tests:
  - trees: lower `level_tree_draw_m` + `refresh_draw()` → every built MMI's `visibility_range_end` drops, with no rebuild.
  - cover: `refresh_near()` changes the `fade` uniform on both materials and the near MMI ranges; `refresh_far()` with a smaller reach frees outer tiles.
  - streamer: `apply_rings` with a smaller `far_radius` → `chunk_counts()` drops right away, without moving the focus.
  - effects: `set_quality(0)` → `visible_instance_count == 0`.
  - weather: `set_weather_ratio(0.5)` then `apply_weather(<any id>)` → the new field's `amount_ratio == 0.5`.
- [ ] **Step 3 (parent):** `./run_tests.sh --fast level_trees level_streamer live_graphics_setters ground_cover dust_puffs engine_smoke tire_marks photo_mode`. Expected: PASS.

### Task 4b: Full detail under the car at speed

**Files:** Modify `scripts/free_roam/terrain_streamer.gd` (`_plan`, `_run_queue`, `_dispatch_build`, `_poll_builds`), `scripts/game_config.gd` (`adaptive_near_lead_s`). Test: extend `tests/headless/test_level_streamer.gd` (or `test_terrain_streamer*.gd` if that is where streamer tests live).

**Interfaces (produced):** `var stat_near_misses := 0`; `func near_overdue() -> bool` (some queued near tile would be reached before its expected build time); `var near_build_ms: float` (running mean). Spec → "Full detail under the car at speed" lists the four behaviours.

- [ ] **Step 1:** Implement the corridor, the time-to-arrival priority, the reserved slot plus starvation, and the miss count. Starvation only skips non-near, non-collision work; the collision rush (`_guard_collision`) is untouched.
- [ ] **Step 2:** Tests from the spec's list.
- [ ] **Step 3 (parent):** `./run_tests.sh --fast level_streamer terrain_streamer level_view`. Expected: PASS.

### Task 5: `AdaptiveGraphics` in the level view (knobs, wiring, persistence, benchmark)

**Files:**
- Create: `scripts/adaptive/adaptive_graphics.gd` (Node), `scripts/adaptive/level_knobs.gd` (static builder of the knob list)
- Modify: `scripts/level_view.gd`, `benchmark/level_replay.gd`, `scripts/title_boot.gd` (URL flag)
- Test: `tests/headless/test_adaptive_graphics.gd`

**Interfaces:**
- Consumes Tasks 2–4.
- `LevelKnobs.build(view: LevelView) -> Array[AdaptiveKnob]`. Knob ids are fixed: `&"trees"`, `&"cover_near"`, `&"cover_far"`, `&"terrain"`, `&"surface_fx"` (dust + spray + tyre marks), `&"smoke"`, `&"flames"` (on/off, 2 levels), `&"spectators"` (on/off), `&"weather"`, `&"resolution"` (`last_resort = true`). For distance knobs, max level = the authored value via `Config.authored_value`, with ~10 % steps. `terrain` steps `far_radius` by integers (mid/horizon scaled with it). Weights are `adaptive_weight_<id>` and priors `adaptive_prior_<id>` in GameConfig. A distance knob's `weight` returns 0 for a step whose distance is beyond the current `fog_depth_end`. The cover_near level is clamped so near reach ≤ far reach.
- `class_name AdaptiveGraphics extends Node`:
  - `static var state: Dictionary` (the controller's `to_dict()`, survives reloads), `const SAVE_PATH := "user://adaptive_graphics.json"`, written every 30 s and on `_exit_tree`.
  - `var controller: AdaptiveController`, `var sampler: FrameSampler`
  - `func disturbed() -> void` (forwards with the current time)
  - `func setup(view: LevelView) -> void`: builds the knobs, restores `state`, else the file, else middle levels, and applies every knob once. Calls `sampler.watch([root viewport RID, PostProcess/View RID])`.
  - Each sample: fills `quiet = _streamer.queued() == 0 and cover.pending() == 0` and `now_s`, feeds the controller, then sets `_streamer.spare_us` from the headroom (lerp 0.1, as `free_roam.gd` → `_track_spare_time`).
- `LevelView` wiring:
  - `var adaptive: AdaptiveGraphics`, created in `_ready` after the streamer and effects exist.
  - Call `adaptive.disturbed()` from `respawn`, the teleport path(s), `apply_weather`, `_on_photo_opened`, pause/menu open, and `_reload`.
  - The controller is frozen (`enabled = false`) from `_on_photo_opened` to `_on_photo_closed`.
  - Under `Benchmark.active` without the adaptive flag: write `Config.authored_value` into every knob field and apply max levels; the controller stays disabled.
- Replay flag: `--adaptive` / `&adaptive=1` enables it during a replay; the report gains `adaptive: [{t, id, level}]` change events.
- [ ] **Step 1:** Implement.
- [ ] **Step 2:** Tests (`SceneTestHelpers.minimal_world()` or the cheapest level-view fixture that exists; see `features/testing.md`):
  - `test_knob_max_is_authored_value`: logic, not values: for each distance knob, applying max level writes `Config.authored_value(field)`.
  - `test_photo_mode_roundtrip_keeps_controller_level` (Review Focus 1).
  - `test_state_survives_reload` (Review Focus 2): set levels → `state` → a new `AdaptiveGraphics` restores them.
  - `test_corrupt_file_loads_defaults` (Review Focus 3): garbage JSON / unknown ids / out-of-range levels.
  - `test_benchmark_forces_authored_values` (Review Focus 5): lower a field, set `Benchmark.active`, set up → the field is back at authored and the controller is disabled.
- [ ] **Step 3 (parent):** `./run_tests.sh --fast adaptive level_view photo_mode benchmark level_replay`. Expected: PASS.

### Task 6: P overlay page + docs

**Files:**
- Modify: `scripts/level_stats.gd`, `scripts/level_view.gd` (P handler)
- Create: `features/adaptive-graphics.md`; Modify: `features/README.md`, `features/benchmark.md` (sampler, `adaptive` flag, report field), `features/settings.md` (pointer to the new doc), `features/ground-cover…`/`trees.md`/`terrain-streaming.md` (one line each on the live setter)
- Test: extend `tests/headless/test_level_stats.gd`

**Interfaces:**
- `LevelStats.cycle() -> void` replaces `toggle()`: off → perf → adaptive → off. `var page: int`.
- `static func adaptive_text(c: AdaptiveController, budget_ms: float, outlines_on: bool) -> String` renders the layout in the spec's "P overlay" section. The header carries budget / p90 / headroom / on-off / "at floor". The next line is `last_decision` with its age. Then one row per knob: name, `level/levels-1`, ms/step (`*` when it comes from the draw fit), samples, next raise. Last comes a fixed-cost line for Outlines when they're on (`OutlineSetting`).
- `tally` doesn't run while the adaptive page shows.
- [ ] **Step 1:** Implement the overlay and write the docs. `features/adaptive-graphics.md` covers the role, knob table, controller rules, where the tunables live, and the overlay.
- [ ] **Step 2:** Tests: `test_cycle_pages`; `test_adaptive_text_lists_every_knob` (synthetic controller: each knob name appears; "at floor" appears when `at_floor`).
- [ ] **Step 3 (parent):** `./run_tests.sh --fast level_stats`; then, as the final pre-handoff check, the full `./run_tests.sh` (once). Expected: TESTS PASSED, under ~5 min.
- [ ] **Step 4 (parent, manual):** `./start_web.sh`, `?replay=1&full=1&adaptive=1`, read the report's `adaptive` events and frame stats. Then drive with P on the adaptive page and confirm the rows move sensibly.

## Order and dependencies

Task 1 is independent. Tasks 2, 3 and 4 are independent of each other (parallel-safe: disjoint files, except `game_config.gd`, which only Task 2 edits; Task 5 adds its `adaptive_weight_*` / `adaptive_prior_*` fields after Task 2 lands). Task 4b is independent. Task 5 needs 2–4b (it feeds `stat_near_misses` to the controller as a terrain-only drop signal). Task 6 needs 5.
