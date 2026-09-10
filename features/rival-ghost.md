# Rival Ghost

**Source:** `scripts/rival_ghost.gd` (`class_name RivalGhost extends Node`),
`scripts/region_run_mode.gd` (`stage_target_profile`), `scripts/run_mode.gd`
(the base no-op), `scripts/run_session.gd` (`stage_target_profile`,
`stage_target_pace`), plus the `kinematic_pose` seam on `scripts/car.gd`
([car-physics.md](car-physics.md), [event-replay.md](event-replay.md)). Wired
by `scripts/world.gd` (`_setup_rival_ghost`, `_build_start_line`),
`scripts/start_line.gd` (the start-line reveal + the rival card) and
`scripts/stage_manager.gd` (`setup_target_profile`, `_update_rival`, the HUD
delta).

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
with no lateral offset of any kind — the ghost drives the same line the player
does, wheel track for wheel track. `origin_offset()` /
`sample_at()` are `TrackProgress` methods that already existed and were already
commented as being *for* this consumer (see [progress.md](progress.md)) — the
ghost is posed in `TrackProgress`'s arc-length space (which already accounts
for the start-line lead-in and re-anchors at `mark_start()`), not the raw
generated centerline's, so the ghost and the player's own progress percentage
agree on where "0%" and "100%" are.

Two posing entry points on the same `Car`, selected by what the caller has:

- **`pose_at(t)`** — a race time: `StageManager` drives this off its own
  `_elapsed` during RUNNING, un-looped (it holds at the finish once the
  profile's duration passes). Also applies the proximity fade/cull below.
- **`pose_at_distance(s)`** — a raw track distance (m from the origin sample):
  the start line's grid slot (ON the line, `s = 0`) and the DEPART drive-off are
  DISTANCES, not times on the profile, so `start_line.gd` poses the
  parked/departing rival with this. Renders the car **SOLID** — the rival is the
  subject of the start-line shot, and a see-through car on the grid reads as
  broken; translucency is the run-time reading aid. Same posing path and guards
  as `pose_at`.

(The ghost's own-clock `advance`/`reset` pair — the looping MENU idle an
earlier start line drove — is gone: the rival parks on the grid instead of
driving laps in the background.)

## The display layer (transparency, slope, slip, wheels, fade)

The pre-pivot `ghost_car.gd`'s whole display stack rides along on every pose:

- **Transparency** — `_make_translucent` builds, for every `MeshInstance3D` under
  the car, a `ShaderMaterial` override running
  `shaders/ps1_models_ghost.gdshader`: the same fake per-vertex sun/ambient maths
  as the car's own `ps1_models_lit.gdshader` (uniform block copied straight off
  the source material, so it inherits whatever weather-dimmed values car.gd last
  pushed), plus a blended `ghost_alpha` and `depth_draw_never` so overlapping
  panels don't punch holes in each other. A material override — not
  `GeometryInstance3D.transparency` — is the only thing that works: the car's own
  shader never writes ALPHA. Carrying the lighting across is not cosmetic detail:
  the earlier plain unshaded `StandardMaterial3D` threw the fake sun away, and the
  rival read as a flat, visibly LIGHTER car than the player's beside it on the
  line. Run after `_apply_rival_car` (which reshapes the meshes) in `setup()`, so
  a stage's fresh body is always re-ghosted. Base alpha is `rival_ghost_opacity`.
- **Full alpha means OPAQUE, not "blended at 1.0"** — `_write_alpha` (the one
  funnel both the start-line park and the proximity fade write through) takes the
  overrides OFF entirely when the effective alpha reaches 1, so the body renders
  with its own materials: opaque, depth-writing, lit by the same shader the
  player's car wears. Below 1 the overrides go back on. Without that, a
  fully-"opaque" ghost still drew in the transparent queue with no depth writes,
  so a single-mesh body whose cab overlaps its own bed (the Acty) rendered the
  truck bed through the cab — reading exactly like inverted normals. The
  attach/detach happens only on the crossing, not per frame.
- **Slope** — `_basis_from` builds the body basis from the road's own surface
  normal (`_surface_normal`, finite-difference height probes `NORMAL_PROBE_M`
  apart) with the travel direction projected onto that plane, so the ghost
  pitches and rolls with the road instead of floating nose-level on climbs.
- **Slip yaw** — `_slip_at` reads the centerline's curvature around `s` and the
  profile's own speed there, and wears the centripetal demand
  (`atan(v²·κ/g)`, scaled by `rival_ghost_slip_scale`, capped by
  `rival_ghost_max_slip_deg`) as a yaw about the SURFACE normal — negated,
  because the 2D curve space's angles run opposite to `Basis` yaw (a rally car
  slides nose-INSIDE the corner; the wrong sign makes it counter-steer out of
  every bend).
- **Wheels** — `settle_wheels_to_ground` droops the wheel Visuals onto the road
  the body was just seated against (a frozen body's solver never runs), and
  `_drive_wheels` fills `drivetrain.replay_omega` from `speed / wheel_radius`
  so car.gd's `kinematic_pose` branch spins them — without it the ghost slides
  down the road on four dead wheels.
- **Proximity fade + cull** — `_apply_visibility` (run by `pose_at`, with the
  player car wired in via `set_player`) hides the ghost past
  `rival_ghost_visible_m` and fades its alpha (and the nametag's) toward zero
  as the player closes inside `rival_ghost_fade_near_m` — a solid-looking car
  you're overlapping fills the screen and hides the road. Deliberately not
  gated on headless so the tests can assert it.
- **Nametag** — a `Label3D` over the car (`rival_ghost_nametag_*` keys)
  naming the driver, fading with the car.

## The start-line send-off and the re-entry gate

The start line doesn't just park the ghost — after the reveal, Start sends it
off (`start_line.gd`'s DEPART phase) driving forward from the line (the parked
grid slot, `s = 0`) at the
profile's own pace (`departure_speed(s)`, the profile's `ds/dt`). When it is
`start_lead_in_ahead_m` past the line, `mark_departed_at(s)` hides it and arms
`_reentry_s`: through the early run, `pose_at` keeps the ghost hidden until
the profile's own distance at `StageManager.elapsed()` passes that point — the
player's clock "catches up" to where the drive-off left the rival — so it
never pops back onto the start line the moment the run starts posing it.

## The rival's car and name

The ghost's body used to be the car scene's neutral baseline — the shape of no
car at all, which read as a placeholder box driving the stage. It now wears a
REAL car from the CarLibrary roster, chosen to make the clock believable:

- **The pick** — `RivalGhost.pick_rival(pace, seed) -> {"car_index", "name"}`
  is a pure static `world.gd._setup_rival_ghost` calls once per stage boot.
  `pace` is `RunSession.stage_target_pace()` — the mode's own
  `target_pace(stage_index)` multiplier (read off the MODE, never
  reverse-engineered from the seated profile, so it cannot disagree with the
  target; 0.0 for a mode with no target concept). A car "as fast as the target"
  is one whose benchmark time sits the same multiplier from the reference's:
  `benchmark_ms(car) / benchmark_ms(REFERENCE_CAR) ≈ pace`. Both sides are
  `CarPerformance.benchmark_ms` solves on the SAME frozen benchmark track
  (cached per car), so the ratio carries over to a real stage closely enough
  for a believable body — catalogue entries are fed through
  `CarPerformance.merged_meta({}, entry)` so the solver sees each car's RESOLVED
  engine, and an entry that fails to solve is never picked. The winner is the
  nearest neighbour of `pace` (argmin of the absolute gap), which is monotonic
  in pace: a slower target never picks a faster car.
- **The costume, not the physics** — the ghost still drives the target PROFILE
  exactly, per the class contract above: the clock is the fail state, the body
  is presentation. A car that "could not actually" run the target time in a
  player's hands still races it here, because the profile — not the car — is
  what the HUD delta is measured against. The pick only has to look right.
- **The application** — `setup()` takes the pick as its `rival` argument and
  reshapes the ghost's Car via the same path the old start-line grid props
  used: `use_isolated_config()` so `apply_car`'s config writes cannot clobber
  the fielded player car, a `Config.data` value snapshot/restore around it as
  the belt-and-braces net, and `rebuild_audio = false` since a kinematic ghost
  never fires its engine. `apply_car` relocating wheels and resetting the pose
  is destructive to a LIVE body but harmless here — the body is frozen,
  zero-collision, and `_pose_car_at_distance` writes its transform every frame.
- **The name** — an authored pool (`RIVAL_NAMES`, twelve parody-adjacent driver
  names), picked by `posmod(seed, pool)` where the seed is the run's own
  `run_seed` offset by the stage index (`world.gd._rival_seed`, the same
  determinism convention as the boost draw's stride): the same stage of the
  same run always names the same rival, while runs and stages differ.
- **On the start line** — `start_line.gd`'s rival card reads the identity back
  off the ghost (`rival_name()` / `rival_car_name()` / `target_ms()`); see
  [start-line.md](start-line.md). With no pick (`{}` — no target, or a roster
  with no solvable car) the ghost keeps the neutral baseline and the card shows
  the time alone, or nothing at all with no ghost.

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
it outlives this node, kept posing through RUNNING — it parks the ghost ON the
line (`pose_at_distance(0.0)`, solid through the OPAQUE path — the pre-pivot
grid's front slot, with the
player staged one `start_queue_gap` behind it) through
MENU/FLY_IN/REVEAL, then drives it off down the lead-in in the DEPART phase at
the profile's own pace, hiding it (with the re-entry gate above) once it is
properly away; `StageManager` poses it per-frame again from the countdown on.
See [start-line.md](start-line.md).

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
- **No RUNNING-phase LOD concern.** The ghost keeps posing at whatever distance
  the pace profile puts it (culled past `rival_ghost_visible_m`) — there's no
  attempt to keep it in shot after the start-line reveal, since the HUD delta
  (not the visual) is the must-have for RUNNING.
