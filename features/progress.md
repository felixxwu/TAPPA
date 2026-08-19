# Track Progress & Off-Track Reset

> **"Progress" here means DISTANCE ALONG ONE STAGE, not career progress.** This file owns
> `TrackProgress` — how far the car has driven down the generated road, and the off-track
> auto-reset. It owns **nothing** about the player's career.
> Looking for how many rallies the player has finished or podiumed, stars, unlocks, or
> anything persisted between sessions? That is
> [save-persistence.md](save-persistence.md) (the profile and its API) and
> [star-economy.md](star-economy.md) (the star ledger). There is no career "progress"
> module; the profile IS the career state.

`TrackProgress` (`scripts/track_progress.gd`, `class_name TrackProgress extends
Node`) tracks how far along the generated road the car has driven and snaps it
back onto the road if it stays off it too long. Both behaviours run off the road
**centerline** — the `Curve2D` (XZ plane) from `TrackGenerator`, which `world.gd`
now retains by handing it to this manager instead of discarding it after
`Floor.set_track`.

**Tests:** `tests/headless/test_track_progress.gd`

They use **two different thresholds**, and mixing them up is the easiest mistake
to make here:

| | Threshold | What it does |
|---|---|---|
| Progress leash | `track_progress_max_dist_m` (lateral distance) | How far off-line the car can be and still bank along-track metres. Generous. **Never resets anything.** |
| Off-road clock | `off_road_reset_timeout_s` (seconds past the road edge) | The off-track reset. Fires on TIME, never on distance. |

## How it works

`world.gd._generate_track()` creates a `TrackProgress`, adds it as a child, and
calls `setup(centerline, car, terrain, finish_offset)` — passing the arc length of
the generated track (before the post-finish runoff is appended) as the finish
offset (see Readouts). `retarget()` re-acquires the offset for a car that has
been teleported/respawned elsewhere on the same road, preserving the finish
offset.

Each `_physics_process` tick:
- Find the car's nearest offset on the curve via `_local_closest_offset` — a
  **windowed** search of the baked centerline around the current progress
  (`_best_offset − SEARCH_BACK_M .. + SEARCH_FWD_M`, sampled every
  `SEARCH_STEP_M`) — and the lateral distance to the centerline there.
- **Within** `Config.data.track_progress_max_dist_m`: if the offset beats the
  best ever reached, advance `_best_offset` (the monotonic progress counter) and
  recompute the recovery pose. Driving backwards lowers the live offset but never
  `_best_offset`.
- **Beyond** it: progress simply doesn't accrue, and any corner-cut incident in
  flight is closed (`_close_cut_incident`) so it can't coalesce with the next one
  across the excursion. Nothing is reset.
- Then `_update_off_road` runs the off-road clock (below), and if that fired a
  reset the stuck watchdog is skipped for the tick.

The progress leash is deliberately **generous** — run wide onto the verge / cut
rough ground and you still bank the metres (rally!). Because the nearest-point
search is local (windowed around current progress) rather than a global
`get_closest_offset`, a wide threshold can't snap onto a spatially-near but
along-track-far section of a winding track — so it's independent of
`track_clearance` (the old below-`track_clearance` assert is gone). The spawn seed
in `setup` still uses a global query (unambiguous at the start line).

## The off-track reset is TIMED, not distance-based

`_update_off_road(delta, dist)` is the reset. The road is a **fixed width**, so
"off the road" is clean geometry — `off_road_edge_m()` is
`track_width * 0.5 + off_road_margin_m` — and what's measured is how **long** the
car stays out there, not how far out it gets:

- Beyond the edge: accumulate `_off_road_time`.
- Back inside it: `_off_road_time` snaps to **0**. The clock times one
  *continuous* excursion, so a quick cut across the inside costs nothing and two
  separate trips off the road never add up into a reset.
- Past `off_road_reset_timeout_s`: `car.reset_to(_best_reset)` — the same
  snap-back-onto-the-road-at-the-furthest-recorded-point as every other recovery
  path here. Free (no penalty, no damage).
- `off_track_reset_enabled` gates the whole thing; while it's off the clock
  doesn't even run.

**Why time and not distance.** A distance leash leaves the worst case unhandled:
bogged in a ditch a couple of metres off the verge, the car can neither climb back
onto the road nor get far enough out to trip the leash, so the run just stalls
with no way out. The stuck watchdog below doesn't catch it either — that one
requires the car to be **stationary**, and a car thrashing back and forth in a
ditch isn't. A clock always expires. It also makes the rule legible to the player:
you get N seconds off the road, and how far out you went never enters into it.

`_off_road_time` is zeroed on every path that puts the car back where it belongs:
`setup()`, `mark_start()` (so time spent being staged onto a grid slot isn't the
player's), the water / off-the-world reset, and the off-road reset itself.

### HUD warning

`off_road_time()` and `off_road_seconds_left()` (‑1.0 when nothing is pending) are
the readouts. `StageManager._update_off_road_warning` polls them each frame while
the stage is **RUNNING** and drives `Hud.show_off_road` / `hide_off_road` — a
centre-screen red `OFF TRACK  n.n` counting down to the reset
([hud.md](hud.md)). It's held back by `off_road_warning_after_s` so everyday rally
excursions (running wide, landing a jump on the verge) don't flash a warning every
corner. Polled rather than signal-driven because it mirrors a continuously
changing value, not an event. Only while RUNNING: `TrackProgress` keeps its clock
in every phase — a car that crosses the line off-road is still recovered — but a
warning under the finish panel or during the countdown is noise the player can't
act on, so `_complete()` and `setup()` take it down.

### Consequence: the play area is no longer hard-bounded

The distance leash used to guarantee the car stayed within
`track_progress_max_dist_m` of the centerline, and `TerrainManager` leaned on that
to precompute *every chunk the level could ever request*
([terrain.md](terrain.md) → `corridor_coords`). With a timed reset that guarantee
is gone: a big enough launch can outrun the precomputed band before the clock
expires. `track_progress_max_dist_m` still sizes the corridor (which is why it
stays modest — the corridor's own `RADIUS + 1` chunk dilation already carries it
hundreds of metres off the road, covering any realistic excursion).

Out past that edge the terrain is simply left to **degrade**, which is the whole
point of the timed reset making excursions short-lived: the chunk is a silent hole,
the static `DistantTerrain` backdrop still draws the landscape, and the car is
recovered within a second or two by whichever net reaches it first — the off-road
clock, or `fell_off_world_y` if it drops through in the meantime. Nothing is built
on demand out there; paying a main-thread build hitch for ground the player is about
to be teleported off would be the wrong trade. A missing chunk *inside* the corridor
is still a loud `push_error` — that one really is an invariant break.

## Fallen off the world (water/void)

Before the lateral check, `_timed_physics_process` does a plain Y-coordinate
check, independent of lateral distance from the road (a car can be perfectly
on-line laterally but have dropped straight down through a lake):

- **On a track with water** (`Config.data.water_enabled`): the trigger is the
  **per-track** flood height, `Config.data.track_water_level_m` — set per rally
  event (`event["water_level"]`, see [lakes.md](lakes.md)), not a fixed
  constant, since it varies per track. The car resets once it's
  `water_submersion_reset_depth_m` below that surface (a small margin so
  resting at the shoreline/surface doesn't false-trigger — roads are routed
  above `water_level + water_shore_clearance_m`, so normal driving never
  approaches it).
- **Fallback floor**: `Config.data.fell_off_world_y`, a fixed absolute Y, for
  tracks with no water at all (a sheer drop off the map with nothing to define
  a "water level").

Either condition teleports straight to `_best_reset` (the last recorded
on-road pose) — no stuck-timeout wait, unlike the pit watchdog. Deliberately
just a Y-coordinate gate reusing the same `reset_to(_best_reset)` path as the
lateral/stuck recovery above — no separate respawn/checkpoint system.

## Stuck-car recovery (on the road)

The off-road clock only runs when the car is *off the road*. With big cliffs & drops
([terrain.md](terrain.md)) a car can get trapped **on** it — nose-down in a pit,
flipped on its roof, or pinned against a wall — where the clock never starts. A
**watchdog** (`_update_recovery`, run each tick after the off-road check) handles
that: it accumulates `_stuck_time` while the car is **stationary**
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
The two watchdogs can't double-up: the off-road reset zeroes `_stuck_time` and returns
early (skipping `_update_recovery` for that tick) when it fires. They cover
complementary failures — the stuck watchdog needs the car stationary but works
anywhere; the off-road clock ignores motion entirely but only runs off the road, which
is exactly why it catches the car thrashing about in a ditch. The manual `R` reset
still exists — these are the automatic safety net.

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

| Field | Purpose |
|---|---|
| `track_progress_max_dist_m` | Lateral distance from the centerline within which progress counts. Generous; independent of `track_clearance` thanks to the windowed search. **Not a reset trigger** — it also sizes the precomputed terrain corridor, which is why it stays modest. |
| `off_track_reset_enabled` | Master switch for the off-track auto-reset (progress tracking runs regardless). While off, the off-road clock doesn't run at all. |
| `off_road_margin_m` | Metres past the road EDGE (`track_width * 0.5`) before the car counts as off the road. Keeps a wheel clipping the verge, or a tail-out slide, from starting the clock. |
| `off_road_reset_timeout_s` | Seconds continuously off the road before the reset fires. **This is the off-track reset.** |
| `off_road_warning_after_s` | Seconds off the road before the HUD shows `OFF TRACK` + the countdown. Must be below the timeout or the warning never appears. |

Stuck-recovery knobs live in the **Recovery** group: `recovery_enabled`,
`recovery_timeout_s`, `recovery_speed_mps`, `recovery_depth_m`,
`recovery_upright_dot`.

The fallen-off-the-world triggers:

| Field | Purpose |
|---|---|
| `fell_off_world_y` | Fallback absolute world Y below which the car is snapped back to `_best_reset` — used on tracks with no water at all. |
| `track_water_level_m` | Per-track flood height (Water group; set per rally event via `event["water_level"]`, see [lakes.md](lakes.md)) — the primary "fallen in water" trigger when `water_enabled` is on. |
| `water_submersion_reset_depth_m` | Depth (Water group) below `track_water_level_m` at which the car is considered submerged (not just resting at the surface/shore) and is reset. |

## Baked centerline table (performance)

`TrackProgress` owns a resampled copy of the road centerline and every hot-path
lookup goes through it instead of `Curve2D.sample_baked`.

- `TrackProgress.baked_points(curve)` resamples once at ~1 m (`BAKE_STEP_M`) with
  equal-width cells, cached against the curve instance *and* its baked length, so a
  re-baked or replaced track rebuilds automatically.
- `TrackProgress.point_on(pts, length, offset)` is the drop-in for `sample_baked`. It
  **linearly interpolates** between adjacent samples and clamps at both ends.
  **Do not index the table directly** — truncating to the cell quantises position to
  1 m, which shifts stage progress, split timing and tire-mark placement.
- `TireMarks` consumes the SAME table via `baked_points`, so the two systems resample
  the curve once between them.

Why: the window scan here plus the windowed and per-wheel scans in `TireMarks` were
issuing roughly **26,000 `sample_baked` engine calls per second** at 60 Hz over a curve
that is static for the whole event. The table turns each into a `PackedVector2Array`
index plus a `lerp`.

> **The search WINDOW was deliberately left wide.** Narrowing it to a few metres around
> the previous offset was considered and **rejected**: `_accrue_cut` detects a corner cut
> by seeing the nearest-point offset leap tens of metres in a single tick when the car
> crosses a hairpin's neck. A narrow window cannot see that jump, so corner-cutting
> penalties would silently stop being billed. The same width is what lets the off-track
> leash re-acquire after a big excursion. Optimise the per-probe cost, never the window.

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
an off-road position doesn't advance progress; `progress_percent` tracks the
fraction driven, reads 0% at the start line despite the lead-in, and `mark_start()`
re-zeros it at the car's position.

The **off-road clock**: staying off the road past the timeout triggers exactly one
reset whose XZ matches the recorded progress, lifted by `spawn_clearance` and facing
along the road; it does *not* fire before the timeout elapses; a car bogged just past
the road edge — deliberately asserted to be well INSIDE `track_progress_max_dist_m`,
where a distance-based reset could never fire — still gets recovered; touching the
road zeroes the clock, so two separate near-timeout excursions don't add up; the
countdown readout falls while off the road and reads ‑1 on it; and the whole thing can
be disabled. All of these set a **synthetic** timeout and derive the off-road X from
the live `track_width` + `off_road_margin_m`, so retuning any of those keeps them
valid. `test_stage_manager.gd` covers the HUD relay (grace period, hidden on returning
to the road, cleared at the finish) and `test_hud.gd` the label itself
(`off_road_text` formatting, show/hide, no self-fade).

The **stuck-recovery watchdog**: a stationary car
that's flooring it / flipped / in a pit auto-recovers after the timeout (and not
before), a parked upright car or a moving car never does, recovery can be disabled,
and it teleports to the last on-road pose. Falling below `fell_off_world_y`
(no-water tracks) or below the per-track `track_water_level_m` minus
`water_submersion_reset_depth_m` (water tracks) resets to the last on-road pose
immediately, using synthetic Y/threshold values rather than pinning the
authored defaults.
