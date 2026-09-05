# Rival Ghost

**Source:** `scripts/rival_ghost.gd` (`class_name RivalGhost extends Node`),
`scripts/region_run_mode.gd` (`stage_target_profile`), `scripts/run_mode.gd`
(the base no-op), `scripts/run_session.gd` (`stage_target_profile`), plus the
`kinematic_pose` seam on `scripts/car.gd` ([car-physics.md](car-physics.md),
[event-replay.md](event-replay.md)). Wired by `scripts/world.gd`
(`_setup_rival_ghost`, `_build_start_line`), `scripts/start_line.gd` (the MENU
idle loop) and `scripts/stage_manager.gd` (`setup_target_profile`,
`_update_rival`, the HUD delta).

**Tests:** `tests/headless/test_rival_ghost.gd`, `tests/headless/test_region_run.gd`,
`tests/headless/test_stage_manager.gd`, `tests/headless/test_start_line.gd`,
`tests/headless/test_hud.gd`, `tests/headless/test_kinematic_pose.gd`

A staged region run's one fail state — `RegionRunMode.stage_target_ms`'s fixed,
reference-car clock (`todo/roguelike-pivot.md` decisions 4/11; see
[region-runs.md](region-runs.md)) — used to be a silent number. This makes it a
visible **rival**: a second, posed-not-simulated `Car` driving the same
pace-scaled profile the clock is derived from, shown at the start line and kept
posing through the run for a live HUD delta.

This is **not** the deleted rival field back (`todo/roguelike-pivot.md` decision
5 still holds). There is exactly ONE ghost car, it is never a race opponent —
it cannot be collided with or overtaken in any way that matters — and there is
still no field position to report. It's the fixed clock, drawn as a line on the
road instead of a number on the arch.

## The pace-scaled profile

`LapTimeModel.optimum_profile(track_result, car_meta, event, ...)`
([car-performance.md](car-performance.md)) already returns a distance-indexed
time curve — `{"s": PackedFloat32Array, "v": ..., "t": PackedFloat32Array,
"total_ms": int}` — solved against `CarPerformance.REFERENCE_CAR`. Before this
feature, `RegionRunMode.stage_target_ms` read only `total_ms` and applied
`target_pace(stage_index)` to that ONE number.

```gdscript
func stage_target_profile(stage_index: int, track_result: Dictionary) -> Dictionary:
    # ... solve optimum_profile, then scale EVERY sample of "t" by target_pace ...
    return {"s": profile["s"], "t": scaled_t}

func stage_target_ms(stage_index: int, track_result: Dictionary) -> int:
    # built ON stage_target_profile — its last (scaled) sample, in ms — so the
    # two can never disagree.
```

`stage_target_profile` scales the WHOLE `t` array by the same `target_pace`
factor, not just the total — a rival that only knew the final time couldn't be
posed anywhere mid-stage. `stage_target_ms` is now built on top of it (its last
sample, in ms), rather than the two being two independent reads of
`optimum_profile`, so they can never quietly drift apart. Both return
empty/`0` for a degenerate (unsolved) track — RunMode's own base
`stage_target_profile` returns `{}`, so a `ChallengeRunMode` (no target concept
at all) never has a profile either.

`RunSession.set_stage_track(track_result)` seats both `_stage_target_ms` and
`_stage_target_profile` in one call (`RunSession.stage_target_profile()` reads
the latter), the same chokepoint `stage_target_ms()` was already seated from.

## `RivalGhost`: the maths, then the Car

`scripts/rival_ghost.gd` is two pure, static inversions of the profile's
parallel `{"s","t"}` arrays — no live `Car`, track or session needed, so they're
tested with a synthetic profile:

- **`distance_at_time(profile, t) -> s`** — how far the rival has covered at
  race time `t`. Poses the ghost.
- **`time_at_distance(profile, s) -> t`** — what time the rival reaches
  distance `s`. Drives the HUD delta: called at the PLAYER's own live distance,
  compared against the player's actual elapsed time.

Both binary-search the monotonic array (`_bracket`) and linearly interpolate
between the bracketing samples, clamping (not extrapolating) past either end —
a race time past the profile's duration holds the ghost at the finish; a
distance before the start holds the lookup at the first sample.

The live instance owns a second `Car` (`Scenes.car_scene()`, same as
`start_line.gd`'s own player car) with `kinematic_pose = true`
([car-physics.md](car-physics.md) / [event-replay.md](event-replay.md) →
"A second consumer: the rival ghost" — the mode this flag exists for).
`kinematic_pose` stops the car's own drivetrain/engine/damage from running and
gates it out of `_driver_input_live()`, but it does **not**, by itself, stop the
physics server from integrating gravity/collisions on the body between
`RivalGhost`'s per-frame transform writes (only `replay_playback` sets
`custom_integrator` for that). `RivalGhost.setup()` handles this itself:
`freeze = true` with `freeze_mode = FREEZE_MODE_KINEMATIC` turns the body into
one the server only ever moves on command, and zeroing `collision_layer` /
`collision_mask` means it can never push or be pushed by the player's real car.

Posing (`_pose_car_at_distance`): sample the position on the SAME centerline
`TrackProgress` tracks progress against —
`_track_progress.sample_at(origin_offset() + s)` — take a second sample a
short distance ahead for the facing tangent, seat the Y on the terrain the same
way `start_line.gd` seats the player (`height_at(x, z) + start_spawn_clearance`),
and nudge it sideways by a small, purely cosmetic lateral offset (so it doesn't
sit exactly on the player at `s = 0`). `origin_offset()` /
`sample_at()` are `TrackProgress` methods that already existed and were already
commented as being *for* this consumer (see [progress.md](progress.md)) — the
ghost is posed in `TrackProgress`'s arc-length space (which already accounts
for the start-line lead-in and re-anchors at `mark_start()`), not the raw
generated centerline's, so the ghost and the player's own progress percentage
agree on where "0%" and "100%" are.

Two drive modes on the same `Car`, selected by which caller drives the clock:

- **`advance(delta)`** — the ghost's OWN clock, optionally looping
  (`reset(looping)`): the start-line MENU idle.
- **`pose_at(t)`** — an EXTERNAL race time, un-looped: `StageManager` drives this
  off its own `_elapsed` during RUNNING.

Wheel spin is NOT filled in (`drivetrain.replay_omega` stays empty) — a static
idle roll on the ghost's wheels was accepted as a v1 trade-off rather than
deriving an approximate omega from `ds/dt`; see the file for where that would
plug in if it's ever worth doing.

## Start-line reveal

`world.gd._setup_rival_ghost` (called from `_build_persistent_managers`,
alongside the other per-stage managers `_ensure_child` reuses across a
same-run stage change) builds/updates the `RivalGhost` for a staged region run
whose track solved a target, and wires it into `StageManager` via
`setup_target_profile`. An unsolvable stage's empty profile frees any ghost
left over from an earlier, solvable one, rather than leaving it posed on
nothing.

`world.gd._build_start_line` hands that same `RivalGhost` into
`StartLine.setup(..., ghost)`. `StartLine` does not own the ghost's lifecycle —
it outlives this node, kept driving through RUNNING — it only calls
`ghost.reset(true)` (looping) at setup and `ghost.advance(delta)` from the MENU
branch of `_timed_process` (the same branch that already drives the orbit
camera idle), so the loop stops naturally the moment the sequence leaves MENU
for the fade. See [start-line.md](start-line.md).

## Live HUD delta

`StageManager.setup_target_profile(profile, ghost)` seats both; every RUNNING
tick, `_update_rival`:

1. Reposes `ghost` (if any) at `_elapsed` — `pose_at`, un-looped, so it holds at
   the finish once the rival's own time is up rather than looping mid-run.
2. Computes the player's live along-track distance:
   `progress_percent() * (finish_offset() - origin_offset())`.
3. Looks up `RivalGhost.time_at_distance(profile, player_s)` — the rival's time
   at that SAME distance.
4. Calls `hud.show_delta(_elapsed - rival_time)` (or `hide_delta()` with no
   profile wired, or `finish_offset() <= origin_offset()`).

`hud.gd`'s `DeltaLabel` (built in code, directly under the run timer — see
[hud.md](hud.md) → "Rival delta") shows it signed (`"+1.23"` / `"-0.40"` via the
pure `Hud.delta_text`), change-gated on the displayed centisecond. **Positive =
behind** the rival's pace at the player's own distance (red); **negative =
ahead** (green) — matching the health gauge / stage-complete label's red/green
sense elsewhere in the HUD.

## What this deliberately does not do

- **No collision, no overtaking, no position.** The ghost is a visual/HUD aid,
  not an opponent — `todo/roguelike-pivot.md` decision 5 stays in force.
- **No wheel-spin fidelity.** Static idle roll, accepted as a v1 trade-off (see
  above).
- **No RUNNING-phase camera/LOD concern.** The ghost keeps posing at whatever
  distance the pace profile puts it, however far that drifts from the player's
  own camera framing — there's no attempt to keep it in shot after the
  start-line reveal, since the HUD delta (not the visual) is the must-have for
  RUNNING.
