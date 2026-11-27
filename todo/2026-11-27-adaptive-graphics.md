# Adaptive graphics — the game tunes its own settings to hold the frame rate

**Status:** design, agreed in conversation 2026-11-27. Not started.
**Depends on:** nothing. Replaces `GraphicsSettings` and the Settings → Graphics page.

## Why

Players shouldn't have to know which setting their device struggles with. The game should
notice it's running out of frame time and quietly cut whatever is costing the most (ground
cover distance, trees, terrain loading, smoke puffs…) *before* the frame rate drops — and it
must keep probing back up, so a wrong measurement or a device that stopped throttling never
leaves it stuck on low settings.

## Goals

- Hold the target frame rate on every device without the player touching anything.
- Cut the setting that is actually expensive on *this* device, not a fixed order.
- Keep climbing: constantly try a little more quality whenever there's room, and recover after
  throttling or a bad estimate.
- Show what it's thinking on the P overlay (`LevelStats`): every setting's level, its learned
  cost, and the controller's last decision and why.

## Non-goals

- Exact per-feature GPU milliseconds (Godot can't report them; costs are learned instead).
- The legacy free-roam island (`free_roam.gd` has its own `_track_spare_time` loop; leave it).
- New graphical features. Only existing costs become adjustable.

## Anti-goals (a failure even if it "works")

- Visible flicker or pulsing: settings bouncing up and down every few seconds, pop-in waves.
- Stuck low: a device that could run more sitting on minimum for the rest of the session.
- A noisier frame time than with no controller (the controller's own changes causing spikes,
  e.g. a reach raise that queues 40 tile builds in one frame).
- Breaking benchmark reproducibility.

## Approaches considered

1. **One global quality dial, AIMD.** Every setting tied to one 0–10 level; drop fast when over
   budget, creep up slowly. Simple and never stuck, but cuts everything together even when only
   one thing is expensive.
2. **Per-setting dials with learned cost per step (chosen).** Each setting has its own level and
   a running estimate of "ms saved/spent per step", learned from the before/after frame cost of
   every change the controller makes. Drop the best ms-saved-per-visual-loss, raise the best
   visual-gain-per-ms that fits the headroom. Estimates decay so nothing is "too expensive"
   forever.
3. **Deliberate A/B flicks** (briefly toggle a setting to time it). Most precise, but visible.
   Rejected.

The user picked 2.

## What the user decided

- Option 2 (learned per-setting cost, constant probing up and down).
- **Remove the Settings → Graphics page entirely.** The controller owns every setting; no player
  ceilings, no manual override.
- A readout of the controller's estimates and reasoning on the **P** overlay.
- **Target frame rate:** the player's FPS cap if one is set, otherwise **60 fps** — never the raw
  refresh rate. Uncapped / 144 Hz does not mean "chase 144"; quality wins over extra fps. Once
  every knob is at max with room to spare, the controller does nothing more.
- **At the floor:** render resolution is a required knob, the last one cut and the first raised.
  If even that is at minimum, accept it and show "at floor" on the P overlay. The controller never
  touches `Engine.max_fps` / the player's FPS cap.
- **Web probing:** with no GPU timer, headroom on web counts only from frames that arrived on time
  (frame interval within budget), not from idle main-thread time. Each failed raise of the same
  knob lengthens that knob's wait (≈30 s → 1 min → 2 min → then every 5 min); it never stops
  retrying, but rarely enough not to read as pulsing. Waits shrink back over time.
- **Ceiling:** each knob's max is the authored `GameConfig` value; nothing goes above it (trees
  can't anyway — the baked visibility caps them). The old page's above-default choices are gone.

## Design

### Measurement (every frame, level view only)

The controller needs one "frame cost" number per frame plus, where available, per-system script
time.

- **Frame budget** = `1000 / target` where target is the player's cap from `FpsSetting.resolve()` (not `Engine.max_fps`, which loading / benchmark overwrite) if set, else 60 (see
  "What the user decided"; not `free_roam.gd` → `_frame_budget_ms`'s refresh-rate fallback). Aim for `budget × 0.85` so there is margin before a frame is missed.
- **Frame cost** = the larger of main-thread busy time and the viewport's measured GPU time:
  - busy time: first physics/process step of the frame to `RenderingServer.frame_post_draw`, as
    `benchmark/level_replay.gd` (`_mark_frame_start` / `_on_frame_drawn`) does. Move that into the
    controller (or a small shared sampler) so the replay and the controller use one copy.
  - GPU time: `RenderingServer.viewport_get_measured_render_time_gpu` after
    `viewport_set_measure_render_time(..., true)`. On web this is usually 0 / unavailable — then
    busy time alone, plus "frame interval clearly longer than budget" (a missed vsync) as a hard
    over-budget signal.
  - Frame interval from `Time.get_ticks_usec()` deltas, never `_process` delta (see
    `features/benchmark.md`, "measurement traps").
- **Per-system script time:** `PerfLog.track` already brackets `terrain_streamer`, `ground_cover`,
  `level_trees`, `dust_puffs`, `engine_smoke`, `wheel_particles`, `tire_marks`, `exhaust_flames`…
  Today it only accumulates in debug builds and per second. Add an always-on per-frame total per
  key (cheap: a dict add) that the controller reads and clears each frame. Settings whose cost is
  mostly script time get a direct measurement instead of an inferred one.
- Smooth with a rolling window (≈1–2 s) and use a high percentile (p90), not the mean, so the
  controller reacts to stutter, not just averages.
- Ignore frames during loading, teleports, scene reloads, pause/menus and photo-mode renders
  (they aren't representative and photo mode already overrides distances).

### Settings ("knobs")

Each knob is a small entry: id, display name, number of levels, current level, a visual-value
weight per step (how much it hurts to lose that step; authored, the one hand-tuned thing), and an
`apply(level)` that changes the game **live**. Level max = today's `GameConfig` value (the
authored look is the ceiling); lower levels are fractions of it. Changing a value never reloads
the scene.

Initial knobs and how each becomes live (from the 2026-11-27 code survey):

| Knob | Live today? | Work needed |
|------|-------------|-------------|
| Tree distance (`level_tree_draw_m`) | Yes — `LevelTrees.set_draw_override` pushes `draw_end_m` and `visibility_range_end` | Use it. Note the baked visibility (`tools/bake_level.gd`) caps how far trees can ever show, so the top level = authored value. Photo mode also uses the override — it must win while active and hand back after. |
| Far ground cover (`ground_cover_far_reach` + `far_fade`) | Read live via `far_reach()`, but that is `maxf(config, _reach_override)` — the override can only raise | Controller writes `Config.data.ground_cover_far_reach` / far fade and re-pushes uniforms + far MMI ranges; the override stays photo mode's. |
| Near ground cover (`ground_cover_reach`, `_fade_start/_end`) | No — `visibility_range_end` is set per MMI in `_add_layer` at tile build | Add a setter that updates the `fade` uniform on `material` and loops built tiles' near MMIs. |
| Terrain detail rings (`mid_radius`, `far_radius`, `horizon_radius_m` on the live `_streamer.settings` — `LevelStreamer.level_settings()` is a static that returns a fresh copy) | Read at each `_plan`, but `_plan` only frees chunks past `far_r + 2` (`_drop_chunk`) and mids past `mid_radius + 1.5` (`_drop_mid`) | On a drop, explicitly free chunks / mid meshes beyond the new radius, then `_plan_timer = 0`. `far_radius` is an int: integer steps. Strides / `chunk_m` / `near_tile_m` are NOT live. |
| Dust puffs, engine smoke, wheel spray, tyre marks (`*_enabled`) | Read every tick, but Off freezes live particles/marks in place | Off must clear the MultiMesh (or let existing ones finish) — exhaust flames' `_set_lit(false)` is the model. Prefer partial levels (spawn rate / max count) over pure on/off where the script has a count, so it can step instead of pop. |
| Exhaust flames | Yes, clean | Use it. |
| Spectators (`spectators_enabled`) | Stops new groups; existing stay until despawn | Acceptable; optionally lower spawn distance as intermediate levels. |
| Weather particles (`*_particle_count`) | Read only in `LevelView.apply_weather` | Drive `LevelView._particles.amount_ratio` (no emitter restart). |
| Render resolution | No lever exists | Required last-resort knob: cut only once every other knob is at min, raised first. Set `scaling_3d_scale` (bilinear) on `PostProcess/View` — the root viewport has `disable_3d` (`post_process_view.gd` → `_enter_tree`). Frame is already 400 px logical, so savings may be small: a cut that saves nothing measurable counts as a backfire (undo, show "at floor"). |

There are no realtime shadows, MSAA or SSAO in the level, so no knobs for them.

Knobs that can't be measured apart can be grouped into one knob (e.g. "surface effects" =
dust + spray + tyre marks) — builder's call per knob, based on what turns out separable.

Each distance step should be small (≈10–15 % of the max) so a change is not a visible pop;
fades already dither.

### Loading work (spikes, not steady cost)

Chunk and cover-tile building cost shows up as single slow frames, not a steady load. It is
not a knob; it gets a **per-frame time budget fed by measured headroom**:

- `TerrainStreamer.budget_us` already mixes a floor with `spare_us × budget_fraction`, but in
  the level view nothing sets `spare_us`, so the budget is fixed. The controller sets
  `LevelStreamer.spare_us` each frame from its headroom (as `free_roam.gd` →
  `_track_spare_time` does), so loading uses spare time and shrinks when the frame is tight.
- `chunk_build_tasks_web/desktop` (thread count) can stay as is.
- A raise of a distance knob must not cause a build burst: tiles queue through the existing
  nearest-first budgeted `stream()` path, so this should hold — verify.

### The controller

A pure, testable class (no scene access) that is fed `(frame_cost_ms, budget_ms,
per_key_script_ms, now)` each frame and returns decisions; a thin node in the level view feeds
it and calls knobs' `apply`.

- **Over budget** (smoothed p90 above target for ≈0.5 s, or several missed vsyncs): pick the
  knob not at min with the highest *estimated ms saved ÷ visual weight of the step*. Drop one
  step. Short cooldown (≈1 s) before the next drop so the effect can be seen.
- **Headroom** (p90 under target minus a margin for ≈5 s): pick the knob not at max with the
  highest *visual weight ÷ estimated ms cost* whose estimate fits the headroom, and whose own
  backoff has expired. Raise one step.
- **Learning:** every change is an experiment. Compare the frame cost in a window just before the
  change with a window just after (≈2 s each, settling time in between); the difference ÷ steps
  is a sample of that knob's cost per step. Fold it into a running estimate with a confidence
  (sample count). Where the knob owns a `PerfLog` key, the script-time delta is also used
  directly. Samples during big scene changes (teleport, entering a dense area — detectable by
  an unusual jump in draw calls / tris from `RenderingServer.get_rendering_info` that the knob
  change can't explain) are discarded.
- **Backfire:** a raise that pushes over budget is undone at once; that knob's estimate rises and
  its raise backoff lengthens per the schedule in "What the user decided". An over-budget event within a few seconds of a raise reverts that raise rather than picking a fresh drop (no raise-A / drop-B churn).
- **Never stuck:** backoffs shrink back over time, and estimates decay toward their prior over a
  few minutes, so every knob is eventually retried. That is what recovers from throttling.
- **Priors:** each knob starts with a rough guessed cost per step (authored alongside the
  visual weight), replaced as samples come in.
- **Start point:** the levels and estimates this device ended its last session with. First ever
  run: a middle level on everything, not minimum.

### Persistence

Learned levels + estimates are per device, so they must NOT go in the cloud-synced profile
(`Save` / `CloudSync`). Store them in a local file under `user://` (web: the same IndexedDB-backed
`user://`). Builder picks the format; corrupt or missing → first-run defaults.

### Benchmark and tests

- Controller **off while `Benchmark.active`** (replays and the benchmark must be reproducible),
  with every knob at its max (the authored look), as today with Graphics settings skipped.
- A replay flag (e.g. `--adaptive` / `&adaptive=1`) turns it on, so the controller itself can be
  checked on a real drive; the report should include the knob levels over time.
- Headless tests drive the pure controller with synthetic knobs and a fake cost function (e.g.
  "knob A costs 2 ms/step, budget 16 ms") and check behaviour that holds for any reasonable
  tuning: it drops when over budget, it drops the expensive knob before the cheap one, it raises
  again when headroom returns, a backfiring raise is undone and backed off, it never stays at
  minimum once the cost goes away, it does nothing while disabled. No assertions on tuning
  numbers (`CLAUDE.md` → Testing).
- A scene test that each knob's `apply` really changes the live thing (e.g. tree
  `visibility_range_end`, cover `fade` uniform) without a reload.

### P overlay

`LevelStats` (one `Label`, refreshed every 0.25 s) grows a section:

```
budget 16.7 ms (60 fps)  cost p90 13.9  headroom +2.8   [adaptive on]
last: dropped Grass near → 6/10  (over by 3.1 ms, best 1.4 ms per loss)  4 s ago
knob              lvl    ms/step  conf  next raise
Trees             8/10    0.9     12    in 22 s
Grass near        6/10    1.4      7    backoff 40 s
Grass far        10/10    0.3      3    —
Terrain rings     9/10    1.1      5    now
Surface FX        10/10   0.2*     9    —      (* measured from script time)
...
```

Jersey 10 at `UITheme.FONT_SIZE` only (`CLAUDE.md` → UI text); widen the panel rather than shrink
text. The overlay is a readout, not a menu (no navigation needed).

### Removals

- `scripts/graphics_settings.gd` and its call in `LevelView._ready`.
- The Graphics page in `scripts/settings_menu.gd` (`_build_graphics_page`, `cycle_graphics`,
  `reset_graphics`, `_refresh_graphics_rows`, `graphics_rows`, `_graphics_dirty`,
  `_apply_graphics_if_changed`) and `LevelView.reload_for_graphics` if nothing else uses it.
- `tests/headless/test_graphics_settings.gd`; menu-nav tests that walk the Settings page list.
- The saved `"graphics"` setting is simply ignored (no migration needed).
- Docs: `features/settings.md` "Graphics page" section; `features/weather.md` mention of
  graphics reloads. New `features/adaptive-graphics.md`, indexed in `features/README.md`.

## Corrections from the second review (2026-11-27) — these win over earlier text

1. **Frame cost excludes loading work.** cost = busy time − this frame's `terrain_streamer` +
   `ground_cover` time (`LevelStreamer._process` brackets both; `free_roam.gd` →
   `_track_spare_time` subtracts `stat_used_us` the same way). Otherwise handing headroom to
   `spare_us` makes every raise look like a backfire. Those two PerfLog keys are never a knob's
   "direct" cost. A raise's "after" window only closes once `_streamer.queued() == 0` and the
   cover has no pending tiles.
2. **GPU timing on both viewports** (root + `PostProcess/View`), as `free_roam.gd` →
   `_measured_viewports`; only where it returns non-zero.
3. **Ownership split with photo mode.** The controller writes `Config.data` fields and re-pushes
   them to built tiles/materials; photo mode keeps sole use of `set_draw_override` /
   `set_reach_override` (its `_render_off` resets them to 0, which then falls back to the
   controller's value). Ceilings come from `Config.authored_value(field, …)`, never `Config.data`.
4. **Benchmark:** under `Benchmark.active`, `LevelView._ready` writes authored values into every
   knob field (`Benchmark.apply_overrides` snapshots whatever `Config.data` holds).
5. **Disturbances.** `LevelView` calls `controller.disturbed()` on teleport, respawn, weather swap
   (`LevelWeather._show` → `apply_weather`), photo mode open (frozen the whole time it is open,
   not just renders), menus/pause, and reload. It aborts in-flight experiments and holds until
   settled and streaming queues are empty. A sample is discarded if another knob changed inside
   its windows; experiments never overlap (next change waits for the current one).
6. **Learning signal.** Trigger on p90; learn from means/medians. Primary cost model: a per-device
   fit of ms-per-draw-call and ms-per-k-primitives over all frames (`RenderingServer.get_rendering_info`),
   so a step's cost ≈ the draw/primitive change it causes on the next frames × that fit. Natural
   scene variation feeds the fit instead of drowning the experiment. Before/after timing is the
   cross-check (and the only signal for knobs that don't change draws, e.g. resolution).
7. **Survives reloads.** Car/part changes reload the scene (`_reload` → `Scenes.change_to`);
   controller state lives in statics (as `LevelWeather` does), and the local file is written
   periodically (≈30 s), since web tabs die without a clean exit.
8. **Cover near/far coupling.** The far shader uses the near `fade` too (`GroundCover.make_material`):
   a near change updates `fade` on both materials. Near reach ≤ far reach always. Each knob scales
   its reach and fade start/end together, as `GraphicsSettings` did.
9. **Web frame timing.** An interval over ≈250 ms (hidden tab, GC) is a pause, not a miss. A
   "missed frame" means ≥ ≈1.5× budget, repeated — a 60 cap on a 120 Hz screen jitters by a
   refresh.
10. **Fog makes far detail free.** A step whose distance lies beyond the current fog end
    (`LevelWeather` → `fog_depth_end`) has zero visual weight; re-evaluated when the fog lifts.
11. **Outlines** (Display → Outlines, `OutlineSetting`, `spike_id_pass.gd`, roughly doubles draw
    calls): stays player-owned, not a knob. The P overlay shows it as a fixed cost.
12. **P overlay pages.** The frame is 400 px tall (`DisplayStretch.DESIGN_HEIGHT`): P cycles
    off → perf (today's `LevelStats` text) → adaptive. `LevelStats.tally` walks every MultiMesh
    every 0.25 s — make it cheap or skip it on the adaptive page, since it adds to what's measured.
13. **Fast first climb.** When headroom is several times a step's estimated cost, raise without the
    full 5 s wait (still one experiment at a time).
14. Small: `PerfLog.track` also accumulates in release while a capture is open; weather
    `amount_ratio` is re-applied after every `apply_weather` (new `WeatherField`); knob `apply`
    tolerates nodes freed by the replay's `--off=`.

## Full detail under the car at speed (added 2026-11-27)

Separate from the controller: on a slow device a fast car drives onto tiles that aren't full detail
yet. The user wants the highest-quality ground **always** under the car, sacrificing the
surrounding chunks if needed. Causes found in `scripts/free_roam/terrain_streamer.gd`:

- `_plan` queues near tiles only around the car (`near_tiles_of(here)`, `NEAR_REACH_M` 70 m); mid/far
  chunks already look 1.5 s ahead (`ahead = here + vel * 1.5`). At 40 m/s that's < 2 s of warning.
- Near jobs get `dist - 200`; mid collision jobs `d - 1000`; nothing ranks the tile under the car
  above everything but its own collision.
- Threaded builds are capped (`_max_builds`: `chunk_build_tasks_web` 2) with no reservation:
  in-flight far builds hold both slots while the next near tile waits.

Changes:

1. **Corridor ahead.** Near tiles are also queued along the velocity for
   `adaptive_near_lead_s` (≈2.5 s) of travel, a corridor about one tile wide each side.
2. **Rank by time-to-arrival.** Near job priority = seconds until the car reaches the tile (its
   nearest point along the path) scaled into a band above every non-collision job; the tile under
   the car and the next ones on its path come first, only the collision under the car beats them.
3. **Reserve and starve.** One build slot is kept for near tiles (others may still be used). The
   streamer measures its near-tile build time on this device (running mean); when some queued
   near tile's time-to-arrival is less than its expected build time, mid/far/plant/horizon work is
   not dispatched or stepped that frame — the surroundings stay coarse (or briefly missing at the
   far edge) until near work catches up.
4. **Count misses.** `TerrainStreamer.stat_near_misses` increments each time the car's tile is
   without a near mesh. Shown on the P overlay and in the replay report. The controller treats a
   miss as a hard over-budget signal against the `terrain` knob only (smaller rings free build
   time); it never drops other knobs for it.

Tests (behaviour, synthetic): a moving focus queues tiles ahead before they are within
`NEAR_REACH_M`; a near job ahead outranks any far job; under starvation no far job is stepped while
an overdue near job waits; misses count up when the car's tile has no near mesh.

## Left to the builder

- Exact window lengths, margins, cooldowns, priors, visual weights (all `GameConfig` tunables).
- Which effects become multi-level vs on/off, and which knobs are grouped.
- Where the shared frame-budget / busy-time sampler lives.
- File format for the local persistence.
