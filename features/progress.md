# Track Progress & Off-Track Reset

`TrackProgress` (`scripts/track_progress.gd`, `class_name TrackProgress extends
Node`) tracks how far along the generated road the car has driven and snaps it
back onto the road if it strays too far. Both behaviours run off the road
**centerline** — the `Curve2D` (XZ plane) from `TrackGenerator`, which `world.gd`
now retains by handing it to this manager instead of discarding it after
`Floor.set_track`.

## How it works

`world.gd._generate_track()` creates a `TrackProgress`, adds it as a child, and
calls `setup(centerline, car, terrain, finish_offset)` — passing the arc length of
the generated track (before the post-finish runoff is appended) as the finish
offset (see Readouts). On a car swap (`cycle_car`) it `retarget()`s the fresh car
(progress resets to the spawn offset, since the new car respawns at the start,
preserving the finish offset).

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

## Stuck-car recovery (inside the leash)

The lateral reset only fires when the car strays *sideways* past the threshold. With
big cliffs & drops ([terrain.md](terrain.md)) a car can get trapped **inside** the
leash — nose-down in a pit, flipped on its roof, or pinned against a wall — where it
never triggers. A **watchdog** (`_update_recovery`, run each tick after the lateral
check) handles that: it accumulates `_stuck_time` while the car is **stationary**
(`linear_velocity < recovery_speed_mps`) **and can't recover on its own** — i.e. one
of:

- **throttling** and going nowhere (`car.is_throttling()` — flooring it, pinned),
- **flipped** (`up · UP < recovery_upright_dot`, rolled onto side/roof), or
- **in a pit** (`car.y` more than `recovery_depth_m` below the road surface at its
  progress point — a drop it can't climb out of, caught even with no input).

Once `_stuck_time` passes `recovery_timeout_s` it calls `reset_to(_best_reset)` —
**free** (a plain teleport to the last on-road pose, no penalty; you already lost the
time getting stuck) and damage-free (`reset_to` suppresses impact frames, see
[damage.md](damage.md)). The **stationary gate** keeps everyday play safe: while
driving, falling or jumping the car is moving, so the timer stays at 0, and a
deliberately-parked upright car on the road satisfies no qualifier and is left alone.
The lateral reset zeroes `_stuck_time` when it fires, so the two never double-up. The
manual `R` reset still exists — this is the automatic safety net.

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
| `off_track_reset_enabled` | `true` | Master switch for the lateral auto-reset (progress tracking runs regardless). |

Stuck-recovery knobs live in the **Recovery** group: `recovery_enabled`,
`recovery_timeout_s` (3.0), `recovery_speed_mps` (0.7), `recovery_depth_m` (3.0),
`recovery_upright_dot` (0.3).

## Corner-cutting penalty

`TrackProgress` also detects **corner cutting** off the same per-tick advance:
it watches how far the car's nearest centerline offset jumps in a single tick,
and bills the excess when that jump exceeds `cut_jump_threshold_m` — the
signature of shortcutting a corner's neck, where the nearest point flips to the
far leg and progress leaps tens of metres at once. Exposed via `cut_excess_m()`,
`cut_penalty_s()`, and the
`cut_billed(incident_s, total_s)` signal (fired once per coalesced run of cut
ticks); progress itself is never nullified. Both accumulators reset in
`setup()` alongside the rest of progress state. See
[corner-cutting.md](corner-cutting.md).

## Readouts

`progress_offset()`, `baked_length()`, `finish_offset()`, and `progress_percent()`
(0..1) are exposed for the HUD and the stage-completion gate ([stage.md](stage.md),
which fires at 100% — coinciding with the finish arch). **100% is the finish
offset, not the curve end.** The rendered road now continues past the finish for a
short straight **runoff** ([track.md](track.md)) so the car has room to skid to a
stop, so the centerline is longer than the timed track. `setup(centerline, car,
terrain, finish_offset)` records that finish offset (defaults to the baked length
when omitted / negative); `progress_percent()` measures the span
`_origin_offset → _finish_offset`, and `jump_to_finish()` (the dev F cheat) pins to
the finish offset. Driving into the runoff past the finish stays clamped at 1.0.
`progress_percent()` is measured **from the start line, not the curve origin**:
the progress centerline has a straight lead-in *behind* the start (so the queue
car sits on road), which would otherwise read several % before the off. It is
anchored at `_origin_offset` — seeded at the spawn in `setup()` and re-anchored to
the car's on-the-line position by `mark_start()`, which `StageManager` calls at the
off — so the start reads exactly **0%**. The windowed search also samples its **far
edge exactly**, so the very end of the curve is reachable and `progress_percent()`
can hit 1.0 (a 1 m step would otherwise cap it ~1 m short). The `TrackProgress`
node feeds the `StageManager` (pace deltas, stage completion); there is no
longer an on-screen percentage readout on the HUD.

## Tests

`tests/headless/test_track_progress.gd` (Curve2D + stub car, no full scene):
progress advances on-road and is monotonic (backward travel doesn't reduce it);
an off-road position doesn't advance progress; straying triggers exactly one
reset whose XZ matches the recorded progress, lifted by `spawn_clearance` and
facing along the road; the reset can be disabled; `progress_percent` tracks the
fraction driven, reads 0% at the start line despite the lead-in, and `mark_start()`
re-zeros it at the car's position. The **stuck-recovery watchdog**: a stationary car
that's flooring it / flipped / in a pit auto-recovers after the timeout (and not
before), a parked upright car or a moving car never does, recovery can be disabled,
and it teleports to the last on-road pose.
