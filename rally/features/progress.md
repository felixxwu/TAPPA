# Track Progress & Off-Track Reset

`TrackProgress` (`scripts/track_progress.gd`, `class_name TrackProgress extends
Node`) tracks how far along the generated road the car has driven and snaps it
back onto the road if it strays too far. Both behaviours run off the road
**centerline** — the `Curve2D` (XZ plane) from `TrackGenerator`, which `world.gd`
now retains by handing it to this manager instead of discarding it after
`Floor.set_track`.

## How it works

`world.gd._generate_track()` creates a `TrackProgress`, adds it as a child, and
calls `setup(centerline, car, terrain)`. On a car swap (`cycle_car`) it
`retarget()`s the fresh car (progress resets to the spawn offset, since the new
car respawns at the start).

Each `_physics_process` tick:
- Find the car's nearest offset on the curve via `_local_closest_offset` — a
  **windowed** search of the baked centerline around the current progress
  (`_best_offset − SEARCH_BACK_M .. + SEARCH_FWD_M`, sampled every
  `SEARCH_STEP_M`) — and the lateral distance to the centerline there.
- **Within** `Config.data.track_progress_max_dist_m`: if the offset beats the
  best ever reached, advance `_best_offset` (the monotonic progress counter) and
  recompute the recovery pose. Driving backwards lowers the live offset but never
  `_best_offset`.
- **Beyond** it: if `off_track_reset_enabled`, call `car.reset_to(_best_reset)` —
  snapping the car back onto the road at the furthest recorded point.

The single threshold does double duty: inside it progress accrues, crossing
outside triggers the reset. It's deliberately **generous** (default 25 m — run
wide onto the verge / cut rough ground before being snapped back). Because the
nearest-point search is local (windowed around current progress) rather than a
global `get_closest_offset`, a wide threshold can't snap onto a spatially-near but
along-track-far section of a winding track — so it's independent of
`track_clearance` (the old below-`track_clearance` assert is gone). The spawn seed
in `setup` still uses a global query (unambiguous at the start line).

## The recovery pose

`_reset_xform_at(offset)` converts a baked curve offset into a 3D pose: position
= centerline point (XZ) lifted to ground height + `spawn_clearance` (the same
lift the spawn uses); orientation = `Basis.looking_at(forward, UP)` so the car's
-Z faces along the road's forward tangent (sampled a little further along the
curve). Ground height comes from the terrain's `height_at` (0 on flat fixtures).

## The car reset path

`Car._reset()` was split into `_reset()` (restores the authored `_start_transform`
— the manual `R` action) and `reset_to(xform)` (resets to an arbitrary pose with
velocities, wheel spin and engine state zeroed). The manual reset and the
off-track recovery now share one code path.

## Config (`GameConfig` › Track)

| Field | Default | Purpose |
|---|---|---|
| `track_progress_max_dist_m` | `25.0` | Lateral distance from the centerline within which progress counts; beyond it triggers the reset. Generous (run wide before snapping back); independent of `track_clearance` thanks to the windowed search. |
| `off_track_reset_enabled` | `true` | Master switch for the auto-reset (progress tracking runs regardless). |

## Readouts

`progress_offset()`, `baked_length()`, and `progress_percent()` (0..1) are
exposed for the HUD and the stage-completion gate ([stage.md](stage.md), which
fires at 100% — coinciding with the finish arch at the centerline end).
`progress_percent()` is measured **from the start line, not the curve origin**:
the progress centerline has a straight lead-in *behind* the start (so the queue
car sits on road), which would otherwise read several % before the off. It is
anchored at `_origin_offset` — seeded at the spawn in `setup()` and re-anchored to
the car's on-the-line position by `mark_start()`, which `StageManager` calls at the
off — so the start reads exactly **0%**. The windowed search also samples its **far
edge exactly**, so the very end of the curve is reachable and `progress_percent()`
can hit 1.0 (a 1 m step would otherwise cap it ~1 m short). A **temporary** percentage readout is wired into the
HUD (`HUD/ProgressLabel`, fed by `world.gd` setting `HUD.track_progress`); it's a
placeholder until the real stage UI lands.

## Tests

`tests/headless/test_track_progress.gd` (Curve2D + stub car, no full scene):
progress advances on-road and is monotonic (backward travel doesn't reduce it);
an off-road position doesn't advance progress; straying triggers exactly one
reset whose XZ matches the recorded progress, lifted by `spawn_clearance` and
facing along the road; the reset can be disabled; `progress_percent` tracks the
fraction driven, reads 0% at the start line despite the lead-in, and `mark_start()`
re-zeros it at the car's position.
