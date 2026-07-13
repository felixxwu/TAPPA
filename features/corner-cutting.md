# Corner-Cutting Penalty

A time penalty for cutting across the inside of a corner, layered on top of
[`TrackProgress`](progress.md) without changing how progress itself accrues —
progress is never nullified, so a cut can't strand the run; it just costs
seconds at the finish.

## The signature — a sudden jump in progress

Each tick `TrackProgress._physics_process` finds the car's nearest point on the
road centerline as a baked arc-length offset. `_accrue_cut(offset)` (in
`scripts/track_progress.gd`) watches how far that offset moves in a single tick:

```
jump = offset - _prev_offset   # progress advanced this one tick
```

The car's nearest point can only advance about as far as the car physically
moved that tick — even flat out that's ~1–2 m per 60 Hz tick (plus ~1 m of
sampling quantisation from the centerline search). Normal driving, on a straight
or through a smooth corner, never comes close to a large single-tick jump, **at
any speed**. Cutting across the neck of a corner is different: the centerline
doubles back the long way around the bend, and the instant the car reaches the
far leg the nearest point *flips* to it — the offset leaps tens of metres in one
tick. A tick counts as a cut when

```
jump > Config.data.cut_jump_threshold_m
```

which sits in the wide dead zone between the fastest honest tick and a flip. The
**excess** past the threshold (`jump - cut_jump_threshold_m`) is the stolen
progress, billed into `_cut_excess_m`. This deliberately ignores gradual
apex-clipping (which advances the nearest point smoothly, never jumping) — the
penalty targets outright shortcuts, not tidy racing lines.

Detection needs no reference to the car's speed or distance driven: it is purely
the discontinuity in the centerline projection, so it can't false-positive on a
slow car the way a per-tick arc-vs-distance ratio does. `_best_offset` (the
monotonic progress counter) still advances normally alongside; nothing about
progress tracking or the off-track reset changes. `_prev_offset` is re-seeded
wherever progress is teleported (`setup`, `mark_start`, `jump_to_finish`, and the
off-track snap-back) so those jumps are never mistaken for cuts.

## Excess → time

The billed metres convert to seconds at a fixed reference speed, not the car's
live speed, so braking mid-cut can't shrink the penalty:

```
cut_penalty_s() = cut_excess_m() / Config.data.cut_reference_speed_mps
```

`cut_penalty_s()` returns `0.0` when `cut_penalty_enabled` is off or the
reference speed is non-positive. Both accumulators (`_cut_excess_m` and the
per-incident tally below) reset in `setup()`, alongside the rest of progress
state.

## Incident coalescing

A single cut is usually several consecutive ticks, not one. `TrackProgress`
tracks a running `_incident_excess_m` for the current unbroken run of cut
ticks and closes it — via `_close_cut_incident()` — the moment a tick isn't a
cut (the jump falls back under the threshold, or the car goes off-track and gets
reset). Closing emits:

```gdscript
signal cut_billed(incident_s: float, total_s: float)
```

once per incident: `incident_s` is that incident's own seconds, `total_s` is
the running `cut_penalty_s()` for the whole event so far.

## Wiring: snapshot at the finish, not live accumulation

[`StageManager`](stage.md) connects `cut_billed` in `setup()` and relays it to
the HUD as a live flash (`_on_cut_billed`), but only while `Phase.RUNNING` — a
cut ticking in during the post-finish coast or a pre-GO state can't pop a
flash the player can no longer act on.

The penalty itself is **snapshot once**, at the finish crossing
(`StageManager._complete()`), not accumulated live into the run timer:

```gdscript
if _progress != null and _progress.has_method("cut_penalty_s"):
    _penalty_s = _progress.cut_penalty_s()
_reported_seconds = _elapsed + _penalty_s
```

`_elapsed` (the on-screen run timer) stays clean throughout the run; only the
`stage_completed(_reported_seconds)` signal — fired later by
`proceed_to_results()` on the NEXT button — carries the penalty. Nothing
downstream (`RallySession`'s rally-total accumulation, standings, etc.) needs
to know a penalty exists; it just sees a slightly larger event time.

## HUD

Two surfaces, both in `scripts/hud.gd` ([hud.md](hud.md)):

- **Live flash** — `show_cut_flash(incident_s, total_s)`, pulsed on every
  `cut_billed` while running. Shows the running event total (`CUT +total_s`),
  not the incident delta, so back-to-back incidents read as one growing tag
  instead of flickering resets. Fades the same way the pace-popup does
  (`stage_delta_show_seconds`, ticked in `_process`). No-ops when
  `cut_penalty_enabled` is off.
- **Finish-panel breakdown** — `show_stage_complete(seconds, penalty_s)`.
  When `penalty_s > 0.0` the panel reads `FINISH / <time> / +X.Xs cut / =
  <total>`; otherwise it's the plain `FINISH / <time>` it always was.

## Config (`GameConfig` › Track)

| Field | Default | Purpose |
|---|---|---|
| `cut_penalty_enabled` | `true` | Master switch. Off ⇒ cuts are never billed and `cut_penalty_s()` is always `0`. |
| `cut_jump_threshold_m` | `5.0` | Single-tick progress jump (m) above which a tick counts as a cut. Sits in the dead zone between the fastest honest tick (~1–2 m) and a neck-flip (tens of m). Metres beyond it are billed. |
| `cut_reference_speed_mps` | `25.0` | Fixed speed (not the car's live speed) that converts stolen metres to seconds. |

## Out of scope

No progress nullification, no conversion at the car's current speed, no
penalty tiers/allowance/DNF, no apex/geometry detection — this is purely the
sudden-jump-in-progress signature on top of the existing progress counter.

## Tests

`tests/headless/test_track_progress.gd` covers the logic against synthetic
centerlines/cars: realistic small per-tick steps along a straight bill nothing,
a single-tick neck flip bills the excess, and the penalty is `0` when
`cut_penalty_enabled` is off. Driving backwards makes the jump negative, so it
never bills.
`tests/headless/test_stage_manager.gd` covers the wiring against stub
progress/HUD nodes: the reported time is `elapsed + penalty`, the finish panel
receives the clean time and penalty separately, and the `cut_billed` flash is
relayed to the HUD only while `Phase.RUNNING`.

See [progress.md](progress.md), [stage.md](stage.md), [hud.md](hud.md).
