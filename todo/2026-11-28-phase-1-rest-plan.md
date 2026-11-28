# Phase 1.2–1.10 — The rest of the yardsticks: implementation plan

**Depends on:** Phase 1.1 (`todo/2026-11-28-phase-1-1-determinism-plan.md`): `RngStreams`
(`scripts/rng_streams.gd`), `Benchmark.golden`, the fixture profile and `_trace_tick` in
`benchmark/level_replay.gd`, and `./run_level_replay.sh --golden-check`. Every golden below runs under
`--golden` (headless, `--fixed-fps 60`, physics thread off through `override.cfg`, threaded builds off), so
two Godot runs on one machine produce identical output and a blessed file can be compared byte for byte.
This file plans steps 1.2–1.10 of `todo/2026-11-27-rust-native-migration.md`; tick them there as they land.

The user is away. Each step is split into **Build now** (agents) and **Needs the user** (deferred). The
work packages (WP) are ordered so each wave's packages touch disjoint files and can go to parallel Sonnet
agents. Subagents don't run tests (CLAUDE.md); the parent runs the targeted set listed at the end.

## 0. Corrections to the spec found while planning

- **Log piles aren't rigid bodies.** `level_view.gd` → `_log_pile` builds a `StaticBody3D`; the only rigid
  bodies the car moves are the spectator ragdolls (`spectator_group.gd` → `_build_ragdoll`). Log piles have
  no per-tick state, so they belong in scene counts (1.6), not in the car snapshot (1.2).
- **Rally starts/results and loot drops don't exist in today's game.** `LevelRallies` only shows the active
  rally's start lines (`static var active`); there's no timing. Loot was deleted with the island. The 1.4
  event list is what the game actually has: money, deliveries, shop purchases, weather, discovery, the
  active rally, damage and temperature, and sounds.
- **Nothing in game code calls `Audio.play_beep` today.** Sound events in the trace are the engine's
  one-shot flags (`EngineSim.bov_event`, `nitrous_event`, `nitrous_emptied`, `misfire_count`,
  `limiter_cut_count`), plus music state and bus levels, and a hook on `Audio.play_beep` for later callers.
- **`features/` has 64 files** (including `README.md`), not 73.
- **The car reads some inputs straight from `Input`, even under `ai_controlled`:** `car.gd` →
  `_timed_physics_process` reads `nitrous`, `shift_up` and `shift_down` only when `_driver_input_live()`,
  which is false for an AI car. A free-running replay therefore can't go through the `ai_*` fields; it
  must drive `Input` itself (see WP2).
- **What `VehicleWheel3D` exposes to scripts:** `is_in_contact`, `get_contact_point`,
  `get_contact_normal`, `get_contact_body`, `get_skidinfo`, `get_rpm`, `steering`, and the wheel node's
  `position` (the body rewrites it with the suspension travel each step). With `wheel_friction_slip = 0`
  (`car.gd` → `_ready`), all tyre force is the script's (`Drivetrain.step`), and the suspension is
  recomputed from the ray each step (`Drivetrain.wheel_normal_force` mirrors it). So the hidden state is
  Jolt's contact cache and sleep state (`PhysicsServer3D.body_get_state(..., BODY_STATE_SLEEPING)` can
  be read), not the wheels. The project runs Jolt (`project.godot`: `3d/physics_engine="Jolt Physics"`).

## 1. Shared design

- **Goldens live outside GUT.** They are change detectors and pin every tuned value, which the CLAUDE.md
  testing rules forbid in `tests/headless/`. They go in `goldens/` (one file per golden, gzipped JSON
  lines), are checked by `run_level_replay.sh` modes and a `goldens` CI job, and are only written by
  `./bless.sh <name>`. GUT gets ordinary tests of the logic each golden relies on (snapshot completeness,
  input packing, the 1 cm matcher, the save normaliser).
- **One writer of `benchmark/level_replay.gd` per wave.** It's 572 lines and every golden hooks into it.
  Wave A puts each golden's logic in its own new file with a static entry point; one agent wires them
  into the replay in Wave B.
- **Golden format:** JSON lines, `JSON.stringify(row, "", true, true)` (sorted keys, full precision), as
  `_trace_tick` does. Line 1 is a header: `{format, level_path, car, seed, godot_version, platform,
  recording}` (the parity contract asks for the platform in each golden). gzip for storage.

## 2. Work packages

### Wave A (parallel; disjoint files)

#### WP1 — Car snapshot (1.2, build now)
- **Goal:** one call returns every piece of per-tick car state, so Rust can restore it.
- **Files:** `scripts/engine.gd`, `scripts/drivetrain.gd`, `scripts/damage_model.gd`, `scripts/car.gd`;
  new `tests/headless/test_car_snapshot.gd`; `features/car-physics.md`, `drivetrain-and-tires.md`,
  `engine-and-transmission.md`, `damage.md` (a "Snapshot" line each).
- **Approach:**
  - `EngineSim.snapshot() -> Dictionary`: `omega, gear, auto, shift_timer, throttle, _torque_ramp,
    limiting, fuel_cut, killed, omega_turbo, boost, bov_event, antilag_active, sc_boost, nitrous_charge,
    nitrous_active, nitrous_delivering, nitrous_event, nitrous_emptied, _prev_nitrous, _prev_throttle,
    _prev_shifting, misfire_level, _misfire_timer, rev_limit_scale, misfire_count, limiter_cut_count`,
    plus `rng_state: _rng.state`.
  - `Drivetrain.snapshot()`: `rear_omega`, `front_omega` and `spin_angle` keyed by wheel **name**
    (`WheelFL`…, never a node), each pooled `WheelContact.abs_active`, and the weather-μ memo
    (`_weather_mu`, `_weather_mu_id`), plus `engine: engine.snapshot()`.
  - `DamageModel.snapshot()`: `max_hp, hp, wheel_toe, thermal, invulnerable, cooling_broken, engine_temp,
    _gave_up`, `rng_state`.
  - `car.gd` → `snapshot()`: pose (basis + origin), `linear_velocity`, `angular_velocity`, sleeping,
    `steering`, `_hold_anchor`, `_hold_anchor_set`, `_hold_anchor_yaw`, `_suppress_impact_frames`,
    `_pending_reset`, `_wind_odometer`, `_wind_gust`, `_wind_id`, `controls_locked`, `handbrake_locked`,
    `mass` (deliveries change it), per wheel `{in_contact, contact_point, contact_normal, steering,
    position}`, and `last_contacts`. Then `drivetrain` and `damage`.
  - `last_contacts`: `_integrate_forces` fills a reused array of `{collider_id, local_pos, normal,
    impulse}` from `state.get_contact_*` only while `record_contacts` is true (set by the replay), so
    normal play allocates nothing.
  - Keys are plain types (floats, ints, arrays), never Objects, so the snapshot serialises as JSON as-is.
  - Ragdolls and felled trees are world state, so they go in the WP9 row, not here.
- **Tests (`test_car_snapshot.gd`, bare logic plus `SceneTestHelpers.add_level_world()` for the car):**
  - Completeness guard: step a synthetic `EngineSim` (with a `GameConfig.new()` and turbo/nitrous turned
    on through the config) and a `DamageModel` for a few hundred ticks with varied inputs. Diff every
    script property (`get_property_list()` with `PROPERTY_USAGE_SCRIPT_VARIABLE`) before and after; any
    property that changed must appear in `snapshot()` or in a short, commented `NOT_STATE` list (config
    refs, caches rebuilt from config). This fails when someone adds a new state variable and forgets it.
  - The car snapshot survives `JSON.stringify` → `JSON.parse_string` with the same keys.
  - Two snapshots taken back to back, with no tick between them, are equal.
  - No tuned values are asserted.
- **Break test:** add `var _new_state := 0.0` to `EngineSim` and change it in `step()`; the completeness
  test fails, naming it.

#### WP2 — Full input recording and a free-running replay (1.2, build now)
- **Goal:** record every in-game action per tick (`TickInput`), and replay a recording by driving
  `Input` (no pose writes), so the car simulates freely.
- **Files:** new `benchmark/tick_input.gd` (`class_name TickInput`); `benchmark/level_replay.gd` (the
  record/load/play paths only); new `tests/headless/test_tick_input.gd`; `features/benchmark.md`.
- **Approach:**
  - `TickInput.ACTIONS`: the gameplay actions from `project.godot` `[input]` that change the sim:
    `accelerate, brake_reverse, steer_left, steer_right, handbrake, shift_up, shift_down, nitrous,
    reset_to_road, pause`. Menu actions stay out; they belong to 1.5.
  - `sample() -> PackedFloat32Array` reads `Input.get_action_raw_strength` per action, plus
    just-pressed bits for the edge actions.
  - `apply(row)` calls `Input.action_press(a, s)` / `action_release(a)`. It is the same path
    `mobile_controls.gd` uses (`Input.action_press`), so the car's own reads (`_axis_input`,
    `is_action_just_pressed("shift_up")`) see it as play. Releases are explicit, so a tap shorter than a
    tick still lands on exactly one tick.
  - Recording format v2 (`file.store_var`):
    - Header: `{format: 2, level, car, hz, seed, at, auto_gearbox}`.
    - Body: `ticks` (the v1 pose stride, kept so pose-fed replays still work) plus `inputs` (one
      `TickInput` row per tick).
    - `_load` still reads v1 (`hafren.rec`).
  - Recording now also uses `_use_fixture_profile()` and `RngStreams.reseed(Benchmark.RNG_SEED)`, so a
    recording and its free run start from the same profile, car and seed. `--car=` is required for v2.
  - `--free`: `_play_tick` skips the `PhysicsServer3D.body_set_state` writes and calls
    `TickInput.apply` instead. `_car.ai_controlled` stays false. The replay already runs at
    `process_physics_priority = -100`, before the car reads its input.
  - Synthetic recordings for testing before the user's drive: `--script=<json>` builds a v2 recording
    from `[{from_s, to_s, action, strength}]`, for example "full throttle and slight left steer for
    8 s from the spawn teleport", saved under `benchmark/runs/synthetic_*.rec`.
- **Tests (`test_tick_input.gd`):**
  - `pack`/`unpack` round-trips.
  - `apply` then `sample` gives the same row.
  - An `apply` from a priority −100 `_physics_process` is seen by `is_action_just_pressed` in the same
    tick and not the next (this checks the `Input.action_press` assumption).
  - On `add_level_world()`, a recorded "accelerate for 60 ticks" run drives the car forward, with no pose
    writes.
- **Break test:** drop `shift_up` from `ACTIONS`; a manual-gearbox synthetic recording that shifts never
  leaves gear 1 in the WP9 golden, so `--car-golden --check` fails at the first shift tick.

#### WP3 — Game-state event log (1.4, build now)
- **Goal:** a per-tick list of game events, compared exactly between runs.
- **Files:** new `benchmark/game_trace.gd` (`class_name GameTrace`); `scripts/audio.gd` (one
  `static var on_beep: Callable` called from `play_beep` before the headless early-out, so headless CI
  logs it); `scripts/music_director.gd` (a read-only `trace_state() -> Dictionary`: track, section,
  crossfade position, on the tick clock 1.1 gave it); new `tests/headless/test_game_trace.gd`;
  `features/benchmark.md`.
- **Approach:**
  - `GameTrace.diff(prev: Dictionary, now: Dictionary, tick) -> Array` compares two cheap state reads and
    emits events like `{tick, kind, ...}`. The kinds:
    - `money` (`LevelView.money()`)
    - `delivery_started` / `picked_up` / `delivered` (`LevelView.delivery` keys, `done_deliveries()`)
    - `bought_car` / `bought_part` (`Save` settings `CARS_KEY`, `PARTS_KEY`)
    - `weather` (`LevelWeather._shown`, `Config.data.weather`)
    - `discovered` (`LevelDiscovery` count of newly stamped cells, plus a hash of the grid)
    - `rally` (`LevelRallies.active`)
    - `hp` / `engine_temp` (as values, so the Rust side can apply its tolerance)
    - `wrecked` (`DamageModel.gave_up`)
    - `beep` (the `Audio.on_beep` hook)
    - `engine_sfx` (the `EngineSim` one-shot flags and counters above)
  - `GameTrace.read(view, car) -> Dictionary` builds `now`. Every tick it also stores `music`
    (`trace_state`) and `buses` (`AudioServer.get_bus_volume_db` per `AudioBuses` bus) as rows, as the
    spec asks.
  - `GameTrace.final_save()` returns `Save.profile` with `updated_utc` and `created_utc` stripped (the
    `WALL_CLOCK_KEYS` idea from 1.1).
  - **Scripted actions** (`benchmark/runs/game_script.json`, `[{tick, do, args}]`) call the same
    functions the menu buttons reach. `do` is one of:
    - `"start_delivery"` → `LevelView._start_delivery_here(t, m)`
    - `"buy_part"` → `_got_part(id, at)`
    - `"buy_car"` → `_got_car(id, at)`
    - `"set_rally"` → `LevelRallies.active = name; show_active()`
    - `"money"` → `Save.set_setting(MONEY_KEY, n)`, to afford the purchase
    - `"wreck"` → `damage.apply_loss(hp)`
    It names shop items by their index in the level file's shop list, not by catalogue id, so the
    catalogue can change underneath it.
- **Tests (`test_game_trace.gd`, bare logic):**
  - `diff` of equal states is empty.
  - Each kind fires once on its change and carries the tick.
  - The event order is stable.
  - `final_save` drops the wall-clock keys and keeps everything else.
  - `on_beep` fires even when `Audio` isn't available (headless).
- **Break test:** make `_complete_delivery` pay `pay + 1` (a code change, not a retune); the events
  check fails at the `money` event of the delivery tick.

#### WP4 — Save round-trip (1.7, build now; fully a GUT test)
- **Goal:** fixture saves covering every field load, save and compare equal as parsed values.
- **Files:**
  - new `tests/fixtures/saves/full.json`: every `_default_profile()` key; two owned cars with parts and
    tuning; a world block with `car_state`; and every settings key, including `input_bindings` with a key
    event, a joypad button and a joypad axis in Godot's numbering (`input_remap.gd` →
    `_event_to_dict`).
  - new `tests/fixtures/saves/minimal.json` and `odd_numbers.json` (ints stored as floats, `1e-7`,
    large ids).
  - new `tests/headless/test_save_round_trip.gd`; `features/save-persistence.md`.
- **Approach:** sandbox `Save.profile_path` the way `save_test_helpers.gd` does, then `load_or_new()`,
  `save_now()`, and read the file back. Compare against the fixture with `normalise(v)`: dictionaries
  compared recursively, every number turned to float, and `updated_utc` dropped. Not a text compare.
- **Tests:**
  - Each fixture round-trips.
  - **Coverage guard:** scan `scripts/**/*.gd` for `set_setting(` call sites and `const *KEY := "…"`
    passed to them, and fail if a written settings key is missing from `full.json`. A new setting then
    can't escape the fixture.
  - `full.json` has every `_default_profile()` key.
  - The fixtures hold no tuned values; prices or stats in them are opaque data.
- **Break test:** make `_sanitise` drop `tuning`; the full fixture round-trip fails on that key.

#### WP5 — Scene counts (1.6, build now)
- **Goal:** at pinned spots, once streaming has finished and before anything moves, list every tree,
  building, fence, spectator and log pile within a radius, and match two lists within 1 cm.
- **Files:** new `benchmark/scene_counts.gd` + `.tscn` (`class_name SceneCounts`); new
  `tests/headless/test_scene_counts.gd`; `features/benchmark.md` (and the `trees.md` / `spectators.md`
  Source lines).
- **Approach:**
  - Boot `Scenes.WORLD` with `Benchmark.golden`, the fixture profile and `RngStreams.reseed`. For each
    fraction in `SPOTS := [0.1, 0.35, 0.6, 0.85]`, pick the road sample from `LevelBake.sx/sz` and place
    the car the way `tools/level_draw_calls.gd` does (`car.reset_to(level.road_pose(...))`).
  - Then `_streamer.prefill()` (the golden path from 1.1), `_trees.settle()`, and the spectators' inline
    placement. Collect before any physics tick runs, with the scene paused (`get_tree().paused`) so
    crowds haven't steered.
  - Items as `[type, x, y, z]`:
    - trees: `LevelBake.tree_xf` origins in the tiles within `RADIUS_M`, minus `LevelTrees._fallen`,
      with `tree_kind` as the subtype
    - buildings: `LevelBuildings.boxes` centres
    - fences: `LevelFences._chunks[*].shapes` centres
    - log piles: the level data's `logPiles`
    - spectators: each live group's `_pos` and `_home`
  - Write JSON. `--check=<golden>` runs `SceneCounts.match(a, b, 0.01)`: every item needs a partner of
    the same type within 1 cm, greedily, using a grid on the 1 cm cell plus neighbours. It reports the
    unmatched items of each side.
- **Tests (bare):**
  - `match` accepts equal lists, accepts a 0.9 cm shift, rejects a 1.1 cm shift, rejects a type swap,
    and rejects an extra item.
  - Matching is independent of order.
  - Two items near a centimetre boundary still match (the reason the spec gives for not rounding).
- **Break test:** change `LevelSpectators.place`'s separation use (a code change), or change
  `RngStreams.make` for `"spectators"`; `--check` lists the moved members.

#### WP6 — Menu-flow replays, keyboard and gamepad (1.5 part, build now)
- **Goal:** scripted presses through every page; after each, log the page id, the focused item's label,
  the state the press changed, and every visible widget's box.
- **Files:** new `benchmark/menu_flow.gd` + `.tscn`, `benchmark/flows/menus.json`; new
  `tests/headless/test_menu_flow_log.gd`; `features/menu-navigation.md`.
- **Approach:**
  - Boot title → world under `Benchmark.golden` and the fixture profile, with a fixed window/content size
    (1280×720 logical).
  - Each flow step is an action (`ui_down`, `ui_accept`, `menu_back`, `pause`, `toggle_map`, …) sent as
    a matching `InputEventKey` or `InputEventJoypadButton` taken from `InputMap.action_get_events`, so
    both the keyboard and the gamepad bindings are exercised. Send it with `Input.parse_input_event`,
    then wait two process frames.
  - The log line has these fields:
    - `page`: the visible `MenuNav` root's title text plus its script's global name; no node paths.
    - `focus`: the focus owner's `text`, or the `CardCarousel` selected card's title.
    - `changed`: a diff of `Save.profile.settings` and the `LevelView` statics.
    - `boxes`: `[label or class, rect]` for every visible Control under the page root, in logical
      pixels, rounded to whole pixels as the layout is.
  - Pages to cover: title, pause, settings (each sub-page), map, shop and parts pages, deliveries,
    service, wreck, account.
  - **Text input:** on the account page, type the email as `InputEventKey` unicode events. For the code,
    the paste goes through `DisplayServer.clipboard_set` then Ctrl+V; if the headless clipboard is a
    no-op, fall back to setting the `LineEdit` text and emitting `text_changed`, and say so in the log.
    Never contact the network: `Cloud` is off under `Benchmark.active`.
- **Tests (bare):** the log-line builder for a hand-built Control tree (page id, focus label, a box
  rounded to whole pixels, no node paths in the output).
- **Break test:** remove one `focus_neighbor` or reorder two settings rows; the check fails at that
  press's `focus` or `boxes`.

#### WP7 — Touch and tilt replay (1.5 part, build now)
- **Files:** new `benchmark/touch_flow.gd` + `.tscn`, `benchmark/flows/touch.json`; new
  `tests/headless/test_touch_flow.gd`; `features/mobile-controls.md`.
- **Approach:**
  - For each scheme in `MobileControls.SCHEMES`, force `_active` and feed recorded
    `InputEventScreenTouch` / `InputEventScreenDrag` points at the scheme's `_rects`.
  - For tilt, feed `TiltInput.adopt(seq, data)` with recorded gravity vectors (the same entry the web
    bridge uses).
  - Each tick, log every `TickInput.ACTIONS` strength (WP2's `sample()`).
- **Tests:** a touch inside a button's rect presses its action and a release lets it go; a tilt-scheme
  gravity roll gives a steer of the right sign. Behaviour only, no strength values.
- **Break test:** swap the throttle and brake rects of one scheme; the log fails on the first press.
- **Depends on:** WP2's `tick_input.gd` (read only). Start it after WP2 has landed that one file, or
  stub the sample.

#### WP8 — Parity checklist (1.10) and re-bless tooling (1.9), build now
- **Files:**
  - new `todo/2026-11-28-parity-checklist.md`: one row per `features/*.md` with columns feature | parity
    check | status | allowed difference. Seed it from 1.1's audit tables in `features/benchmark.md`
    ("present only", "game state", "world streaming").
  - new `tests/headless/test_parity_checklist.gd`
  - new `bless.sh`, new `goldens/README.md`
- **Approach:**
  - The test fails when a `features/*.md` has no row, or a row names a missing file.
  - `./bless.sh <car-step|events|scene-counts|menus|touch>` runs the matching mode with `--bless`, and is
    the only thing that writes `goldens/`.
- **Needs the user:** the CLAUDE.md rule "an agent may not bless unless the user asked for the behaviour
  change", and the `Bless:` commit-line rule. Draft text for both is in §4, to add once the user agrees.

#### WP-D — Device targets tooling (1.8, build now)
- **Files:** new `tools/device_targets.py` (stdlib only); a "Device targets" table in
  `features/benchmark.md`.
- **Approach:** read the reports `tools/bench_collector.py` stores and the native `REPORT_PATH`, and
  print `busy_ms` p95/p99, `draw_phase_ms`, and the `-off-<nodes>` variant per device class into the
  table.
- **Tests:** none in GUT (Python tooling). A `--self-test` with a synthetic report is enough.

### Wave B (after Wave A; mostly serial, because of `level_replay.gd`)

#### WP9 — Car step golden writer (1.2, build now; wires WP1 and WP2)
- **Files:** `benchmark/level_replay.gd`, `run_level_replay.sh`; `features/benchmark.md`.
- **Approach:**
  - `--free --golden --car-trace=<file>`: each tick, at priority −100 before `TickInput.apply`, write
    `{tick, input, snap: _car.snapshot(), world}`. `world` holds the felled tree ids
    (`LevelTrees._fallen`) and each ragdoll's pose and velocities (`SpectatorGroup._ragdolls`).
  - The result of tick i is the snapshot of row i+1, so there's no separate post-state. The one thing
    only known mid-step is the contact impulses, which ride in i+1's `last_contacts`.
  - **On-road check:** count ticks where `LevelView.is_off_road(car xz)` holds, and fail the run if any
    single stretch is longer than `RoadRecovery`'s off-road reset, or if `RoadRecovery` resets the car.
    That proves the free run stays on the road (spec 1.2).
  - `run_level_replay.sh --car-golden [rec] [--check|--bless]` (`--check` compares against
    `goldens/car_step.jsonl.gz` with `cmp` after gunzip and prints the first differing tick and key).
  - Until the user's drive exists, run it on WP2's synthetic recordings.
- **Tests:** none new in GUT; the WP1 and WP2 tests cover the parts. The parent runs `--car-golden` twice
  and expects identical output.
- **Break test:**
  - Retune `GameConfig.drag_coefficient` by 1% (allowed here, because it's a golden, not a GUT test):
    `--check` fails within the first second at the car `linear_velocity`.
  - Revert 1.1's `damage` stream: it fails at `snap.damage.rng_state` or `wheel_toe` on the first hit.

#### WP10 — Wire the event log and scripted actions (1.4, after WP9 in the same file)
- **Files:** `benchmark/level_replay.gd`, `run_level_replay.sh`.
- **Approach:**
  - `--events=<file> --game-script=<json>` runs on the **pose-fed** replay (as the parity contract
    says), writes `GameTrace` events and per-tick audio rows, and writes `final_save` at the end.
  - `--golden-check` also `cmp`s the two event files.
  - `--events-golden --check|--bless` compares against `goldens/events.jsonl.gz` and reports the first
    differing event.
- **Break test:** as WP3.

#### WP11 — Drift report (1.3, build now)
- **Files:** new `tools/drift_report.py` (stdlib only; matplotlib isn't installed, so it writes a hand-made
  SVG plot of the path).
- **Approach:**
  - Input: two car traces (the golden and a candidate).
  - Segments: every `SEGMENT_S` from snapshot ticks.
  - Output, per segment: path deviation over time against a tolerance that widens with time, segment
    time, top speed, and end position. Plus an overlaid path plot. A report, not a gate.
  - The Godot side needs nothing more: the reference is WP9's blessed free run, from which a Rust run can
    restore any tick's snapshot.
- **Check:** golden against itself gives zero drift. Golden against a 1% `drag_coefficient` run gives
  drift that grows over the segment. That is the break test.

#### WP12 — CI, bless guard and docs (1.9 and the exit)
- **Files:** `.github/workflows/test.yml`, `features/testing.md` ("Goldens" section), `goldens/README.md`.
- **Approach:**
  - A `goldens` job copies the `replay-determinism` job's install, import and `fetch_bakes` steps, then
    runs `--car-golden --check`, `--events-golden --check`, `scene_counts --check`, and the menu and touch
    flow `--check`. It uploads the diffs as artifacts on failure.
  - A `bless-guard` job: `git log` over the push range; fail if `goldens/` changed in a commit whose
    message has no `Bless:` line.
  - Spec 1.9's rule: an intended Godot change in Phases 1–3 re-blesses through `./bless.sh` in one
    commit, with a `Bless:` line saying what changed and why.
- **Break test:** push a commit that edits `goldens/events.jsonl.gz` with no `Bless:` line; the guard
  fails.

### Order at a glance
| Wave | Packages (parallel) | Files owned |
|---|---|---|
| A | WP1 | `engine.gd`, `drivetrain.gd`, `damage_model.gd`, `car.gd`, `test_car_snapshot.gd`, car docs |
| A | WP2 | `benchmark/tick_input.gd`, `benchmark/level_replay.gd`, `test_tick_input.gd`, `benchmark.md` (record section) |
| A | WP3 | `benchmark/game_trace.gd`, `audio.gd`, `music_director.gd`, `test_game_trace.gd` |
| A | WP4 | `tests/fixtures/saves/*`, `test_save_round_trip.gd`, `save-persistence.md` |
| A | WP5 | `benchmark/scene_counts.*`, `test_scene_counts.gd` |
| A | WP6 | `benchmark/menu_flow.*`, `benchmark/flows/menus.json`, `test_menu_flow_log.gd`, `menu-navigation.md` |
| A | WP8 | `todo/…parity-checklist.md`, `test_parity_checklist.gd`, `bless.sh`, `goldens/README.md` |
| A | WP-D | `tools/device_targets.py` |
| A′ | WP7 (after WP2's `tick_input.gd` lands) | `benchmark/touch_flow.*`, `test_touch_flow.gd`, `mobile-controls.md` |
| B | WP9 → WP10 (serial, one agent) | `level_replay.gd`, `run_level_replay.sh` |
| B | WP11 (parallel with WP9) | `tools/drift_report.py` |
| C | WP12 | `.github/workflows/test.yml`, `features/testing.md` |

`features/benchmark.md` is touched by several packages. Each adds its own section, and WP2 and WP9/WP10
(the same section) are sequential. Tell the agents which heading is theirs.

## 3. Needs the user (deferred)
1. **1.2 — the hand drive.** Run `./run_level_replay.sh --record benchmark/runs/hafren_free.rec
   --car=<id>` (v2, fixture profile). Aim for 2–3 minutes covering gravel, tarmac, a few shifts (manual
   box), nitrous, the handbrake, one tree hit and one hard landing. Then CI runs `--car-golden --bless`
   on it; check that it stays on the road (WP9's check).
2. **1.3** — look over the drift report's layout once there is a real run.
3. **1.8** — run the replay on a phone (web), Android and iPhone (iPhone needs Phase 0.6, still open)
   and set the frame-time targets. Agents can only fill the desktop row.
4. **1.9** — agree the CLAUDE.md bless rule (§4) and the `Bless:` convention.
5. **Exit** — review the first blessed golden of each kind, and the 1.1 "Chosen defaults".

## 4. Draft rule text for CLAUDE.md (add only with the user's go-ahead)
> **Goldens (`goldens/`) are change detectors.** Only `./bless.sh` writes them, and an agent may run it
> only when the user asked for the behaviour change it records. The commit that changes `goldens/` says
> why on a `Bless:` line (CI's `bless-guard` enforces it). Never re-bless to make a Rust port pass.

## 5. Open questions (recommended default in bold)
1. Free-run inputs: drive `Input.action_press`, or add `ai_nitrous`/`ai_shift` fields to `car.gd`?
   **`Input.action_press`.** It's the path touch controls use and needs no car change; WP2's test checks
   the same-tick edge.
2. Golden storage: commit gzipped JSONL to git, or publish it like the bakes (`gh release` + a fetch
   script)? **Git if under 5 MB per file, else a release asset.** A 2–3 minute car trace is about 1 MB
   gzipped.
3. Car-step check, Godot against Godot: exact `cmp`, or a tolerance? **Exact on the CI image** (1.1 made
   it deterministic). Tolerances only apply to Rust against Godot, in Phase 4.
4. Scene counts: include ground cover and bushes (`ground_cover.gd` tiles, `bush_field.gd`)? **Bushes
   yes, since they react to the car (BushInteraction); grass tufts no.** Tufts are cosmetic, checked by
   the visual review, and there are tens of thousands of them.
5. Menu page id: derive it (title text + script class), or add a `page_id` meta to every menu? **Derive
   it** to keep WP6 off every menu file; add metas only where two pages collide.
6. Headless clipboard for the paste flow: **try `DisplayServer.clipboard_*`, fall back to setting the
   `LineEdit`'s text and log which path ran.**
7. Scripted 1.4 actions: through menu presses or direct calls? **Direct calls to the button handlers.**
   Menu presses are 1.5's job, and mixing them makes one failure break both goldens.
8. Should the events golden run on the pose-fed or the free-run replay? **Pose-fed**, as the parity
   contract says, so position-tied events land on the same tick in Rust.
9. Keep `hafren.rec` (v1, pose-only) as the perf benchmark? **Yes.** Perf replays keep using it; the new
   v2 drive is for goldens.
10. Gearbox for the user's drive: **manual**, so `shift_up`/`shift_down` are exercised (it's
    `GameConfig.auto_gearbox`, stored in the v2 header).

## 6. Parent's targeted run after Wave A and B
`test_car_snapshot`, `test_tick_input`, `test_game_trace`, `test_save_round_trip`, `test_save_manager`,
`test_input_remap`, `test_scene_counts`, `test_menu_flow_log`, `test_touch_flow`, `test_mobile_controls`,
`test_parity_checklist`, `test_audio`, `test_music_director`, `test_engine`, `test_damage_model`,
`test_level_view`, `test_benchmark_report`, `test_script_breadcrumbs`, `test_features_docs`, `test_smoke`.
Then `./run_level_replay.sh --golden-check`, `--car-golden` twice (on a synthetic recording), and the
break tests above. Run the full suite once, at the end.
