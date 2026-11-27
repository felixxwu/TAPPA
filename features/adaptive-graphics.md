# Adaptive graphics

**Source:** `scripts/adaptive/adaptive_graphics.gd` (`AdaptiveGraphics`), `scripts/adaptive/adaptive_controller.gd`
(`AdaptiveController`), `scripts/adaptive/adaptive_knob.gd` (`AdaptiveKnob`), `scripts/adaptive/level_knobs.gd`
(`LevelKnobs`), `scripts/adaptive/frame_sampler.gd` (`FrameSampler`), the near-tile lead in
`scripts/free_roam/terrain_streamer.gd`, the adaptive page of `scripts/level_stats.gd`.

**Tests:** `tests/headless/test_adaptive_controller.gd`, `tests/headless/test_adaptive_graphics.gd`,
`tests/headless/test_live_graphics_setters.gd`, `tests/headless/test_level_streamer.gd`, `tests/headless/test_level_stats.gd`

The level view tunes its own graphics while you drive, so it holds its frame rate on any device and
nobody has to pick settings. There is no Graphics page. Design record: `todo/2026-11-27-adaptive-graphics.md`.

## How it works

- **Budget.** `FrameSampler.budget_ms()`: the player's FPS cap (`FpsSetting.resolve()`), else 60 fps,
  never the screen's refresh rate. The controller aims for `budget × adaptive_margin`.
- **Measuring.** `FrameSampler` times each drawn frame from its first physics/process step to
  `RenderingServer.frame_post_draw`, minus that frame's terrain, ground-cover and tree loading
  (`PerfLog.frame_us` of `terrain_streamer`, `ground_cover` and `trees_pump`; loading spends spare time on purpose, so
  it must not count as cost). GPU time comes from the root and `PostProcess/View` viewports where the
  platform reports it (mostly not on web). Gaps over `adaptive_pause_ms` are pauses, not slow frames.
- **Settings (`LevelKnobs.build`).** Each `AdaptiveKnob` has levels, an `apply(level)` that changes the
  running game, a look weight (`adaptive_weights`) and a first cost guess (`adaptive_priors_ms`). The
  top level is always the authored `GameConfig` value (`Config.authored_value`); nothing goes above it.

  | id | changes | live via |
  |----|---------|----------|
  | `trees` | `level_tree_draw_m` | `LevelTrees.refresh_draw` |
  | `cover_near` / `cover_far` | `ground_cover_*` reach and fades (near never past far) | `GroundCover.refresh_reach` |
  | `terrain` | far ring 3…authored, mid ring scaled with it; also cut when the car outruns full detail | `TerrainStreamer.apply_rings` |
  | `surface_fx` | dust + wheel spray pool share, tyre marks on/off | `CpuParticlePool.set_quality`, `TireMarks.set_shown` |
  | `smoke` | engine smoke pool share | `CpuParticlePool.set_quality` |
  | `flames`, `spectators` | on/off | their `*_enabled` field |
  | `weather` | share of rain/snow particles | `LevelView.set_weather_ratio` (`amount_ratio`) |
  | `resolution` | 3D render scale of `PostProcess/View` (last resort) | `LevelView.set_render_scale` |

- **Deciding (`AdaptiveController.feed`).** Over budget (p90 of the window, or repeated missed frames)
  for `adaptive_over_hold_s` → cut the setting with the most estimated ms per unit of look lost; a raise
  less than `adaptive_revert_window_s` old is undone instead. Room to spare for `adaptive_raise_hold_s`
  (sooner when the room is many times the step's cost) → raise the step with the most
  look per ms that fits. The resolution knob is cut only once everything else is at its lowest, and
  raised first. A distance step that only adds what lies beyond the fog (`LevelView.fog_end_m`) is
  worth nothing, so it is cut first and not raised.
- **Learning.** Every change is measured unless a tile on the car's path is overdue (`AdaptiveGraphics._quiet`; loading and tree repacks are already out of the cost, and at speed something is always queued): the mean cost over `adaptive_experiment_s` before against
  the same after `adaptive_settle_s`, blended with a per-device fit of ms per draw call and per thousand
  primitives. Frame time is only judged on frames from `adaptive_settle_s` after the last change, so one slow spell doesn't cut twice. A failed raise (or a resolution cut that saved nothing) backs that setting off per `adaptive_backoff_s`; failures and estimates
  fade back over time (`adaptive_backoff_shrink_s`, `adaptive_estimate_decay_s`) so nothing stays low
  for good (a device that stopped throttling climbs back).
- **Pauses.** It stops measuring while the HUD is hidden (pause, map, shop menus, photo mode) and on a
  frame gap over `adaptive_pause_ms`, a scene reload, a
  teleport (the car jumping more than `AdaptiveGraphics.JUMP_M`) or weather swap, and starts fresh after.
- **Memory.** Levels and estimates are kept in statics across the level's reloads and written to
  `user://adaptive_graphics.json` every 30 s — per device, never in the cloud-synced save. A first run
  starts every setting in the middle.
- **Benchmark.** While `Benchmark.active` every setting sits at its authored top and nothing adapts,
  unless the level replay is run with `--adaptive` / `&adaptive=1`; its report then carries
  `adaptive: [{t, id, level}]` and its label ends `-adaptive`.

## Full detail under the car

`TerrainStreamer.wanted_near_tiles` queues near (full-detail) tiles in a corridor along the car's path
for `adaptive_near_lead_s` of travel as well as round it. Tiles on the path rank by seconds until the
car reaches them (`NEAR_AHEAD_PRIORITY`), above everything but collision. When one would be reached
before it can be built at this device's pace (`near_build_s`, `near_overdue`), the queue runs nothing
else (for at most `MAX_STARVED_FRAMES` frames in a row); while one is waiting a build thread is kept for them. A tile stays built for `NEAR_WANT_HOLD_US` after the path last wanted it, so steering doesn't churn it, and its build time is only sampled from dispatch for tiles on the path. The strip narrows from a tile each side of the path to half a tile by `NARROW_AT_MPS`. Path tiles and
collision go to `WorkerThreadPool` at **high priority** (`_dispatch_build`): Godot runs low-priority
tasks on under a third of its threads, so on web's two threads every terrain, grass, tree and crowd
build shared one thread and the path waited behind grass (2026-11-27 web replay at 180 km/h: tile
builds 219 → 39 ms, misses 4 → 0). `stat_near_misses` counts the times the car still rolled
onto a tile without full detail (driving only, not photo mode's camera); a miss cuts `terrain` and holds it off raising for `adaptive_backoff_s[0]`.

## The P overlay

P cycles off → perf page → adaptive page (`LevelStats.adaptive_text`): budget, p90 and spare time,
the last decision and why, how often the terrain fell behind, the draw-call fit, then one row per
setting: level, ms per step (`*` when the draw fit fed it), measurements, and any wait before its next
raise. Outlines (Display settings) are the player's choice and show as a fixed cost.
