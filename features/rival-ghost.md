# Rival ghost (P1 on track while you drive)

**Sources:** `scripts/rival_pace.gd` (`RivalPace`), `scripts/ghost_car.gd` (`GhostCar`),
`scripts/lap_time_model.gd` (`optimum_profile`'s `grip_mult` / `power_mult`),
`scripts/car.gd` (`kinematic_pose`), `scripts/track_progress.gd` (`origin_offset` /
`sample_at`), `scripts/rally_session.gd` (`current_event_p1`), `scripts/world.gd`
(`_setup_stage_splits` / `_solve_rival_pace` / `_wire_stage_splits` /
`_setup_rival_ghost`). Design:
`docs/superpowers/specs/2026-08-06-rival-ghost-design.md`.

While the player drives a stage, the rally leader (P1) is shown on track as a
translucent ghost car, crossing the finish **exactly when the standings say they did**.

## Why it isn't an AI driver

Rival times are drawn as *their own car's physics optimum × a pace factor*
([rally-roster.md](rally-roster.md)) — a number, not a driven lap. Three problems ruled
out a scripted-physics rival:

1. **It can't hit its number.** A physics AI arrives when it arrives. A ghost that
   visibly beats you while the standings say you won is a bug, not a nuance.
2. **The existing AI isn't fast enough.** `benchmark_runner.gd`'s pure-pursuit driver
   holds a fixed target speed, nowhere near rival pace.
3. **Terrain collision is streamed around the player only.** A simulated car that gaps
   out has no ground under it and free-falls out of the world — the same problem
   [opponent-wrecks.md](opponent-wrecks.md) solves by placing wrecks analytically.

So the ghost is **kinematic**, posed from the very model that produced the rival's time:
`LapTimeModel.optimum_profile`, which treats the car as a point mass following the
centerline exactly. Inverting its cumulative-time array gives position at any elapsed
time.

The ghost therefore climbs the same hills the player does, but ONLY because `world.gd`
seats `road_height` on the live track result before the pace solve (see
[rally-roster.md](rally-roster.md) -> the QSS model). That sampler has to be attached in
both producers — `RallySession._generate_event_tracks` for the drawn times and `world.gd`
for the solve — or the ghost re-solves a flat road chasing a time that was set on a hilly
one, and visibly drifts against its own split table.

## `RivalPace` — the pace model

Pure `RefCounted`; no nodes, no scene, no knowledge of the rendered world.

`solve(track_result, car_meta, event, target_ms, cached_k := -1.0)` bisects a **driver
skill factor `k`** until the profile's total lands on the rival's drawn time. `k` drives
**two** multipliers, applied at different sites inside `optimum_profile`:

| Term | Where it applies | Governs |
|---|---|---|
| `grip_mult = pow(k, rival_ghost_grip_exponent)` | folds into `_surface_grip`'s `mu` | how much is lost in CORNERS |
| `power_mult = pow(k, rival_ghost_power_exponent)` | scales `p_peak_w` | how much is lost on STRAIGHTS |

`grip_mult` is the *driver's* share of μ, and it is not the last word on it: after either
branch resolves μ, `optimum_profile` multiplies in `LapTimeModel._load_factor` — the tyre
load-sensitivity term, the car's mass and tyre widths through the same
`GameConfig.tire_load_factor` the live physics uses (see
[car-performance.md](car-performance.md)). That is a property of the CAR, so it sits
outside the skill arm entirely and bisection is unaffected: it shifts the whole
time-vs-`k` curve rather than changing its shape, and time is still strictly decreasing
in `k`. Practically it means a light or wide-tyred rival now has a genuinely lower
optimum, so `k` lands *higher* (less deficit to hand out) for the same drawn target —
another reason to keep the bracket wide.

The same "property of the CAR, outside the skill arm" reasoning applies to the
**geared top-speed cap** (`LapTimeModel._geared_top_speed_sq`, described in
[car-performance.md](car-performance.md)): `optimum_profile` folds the rival
car's top-gear speed ceiling into `cap2`, so a short-geared rival can no longer
be solved into a straight-line speed its gearbox forbids. `power_mult` scales
`p_peak_w` and therefore how *fast the rival gets there*; it does not raise the
ceiling. Bisection is still well-behaved — time remains monotonically decreasing
in `k` — but on a stage with a long straight the curve **flattens** once the
rival is pinned at `v_max`, because extra power buys nothing more there. If a
drawn target ever sits below what the ceiling allows, `k` will run to the top of
the bracket rather than converge; that is the model correctly refusing to invent
speed, not a bisection bug. Note the cap is skipped entirely for a meta that does
not describe a gearbox (no engine id, no wheel radius) — synthetic rival metas in
tests solve exactly as they did before.

Two arms are required because the forward pass takes `min(grip_long, a_engine)`: grip does
not bind at all on a power-limited straight, and power barely binds mid-corner. Either
alone leaves a class of stage it cannot slow down.

They are **exponents rather than direct multipliers** so each arm can be switched off
independently — `pow(k, 0) == 1`. That is what makes the shipped default possible:

**Default: `grip_exponent = 0`, so corners cost nothing.** The ghost corners at the car's
true limit and loses time only on the straights. That makes it a *usable reference line* —
it brakes where the player should brake and carries the correct apex speed, so copying it
through a corner teaches the right thing, and it only pulls away down the straight. Set
`grip_exponent = 1` for coupled behaviour (a slower rival is slower everywhere).

### The cost of corners being free: `skill_min` must be low

With grip neutral, straight-line pace is the only lever, and corner-dominated stages have
little of it to give away. `pow(0.45, 1) = 0.45` — a 55% power cut — moves a real rally
stage by only ~4-30%, while P1 needs 6-35%.

Measured, not guessed, with **`tools/audit_ghost_pace.tscn`**
([debug-tools.md](debug-tools.md)): across all 96 career stages the worst case needs a
skill factor of **0.151**, and at the old `skill_min = 0.45` **73 of 96 P1 solves
clamped**. At `skill_min = 0.05` it is **0 of 96**, for P1 and the slowest rival alike.

A wide bracket costs nothing — the bisection still lands on whichever `k` matches the
target, so a low floor only extends what is REACHABLE and never makes a normal ghost
slower. Re-run that audit after changing either exponent.

Both multipliers default to exactly `1.0` and are pure no-ops there, which is what keeps
every existing caller, and every rival time, unchanged.

### The one thing that must never ask for more

Adaptive difficulty ([adaptive-difficulty.md](adaptive-difficulty.md)) can make rivals
quicker in two ways, and only one of them touches this solver. Better MACHINERY is free:
a faster car has a genuinely lower optimum, so the target stays a sane multiple of that
car's own optimum and `k` never leaves its bracket. The residual PACE trim is the one that
could overrun it, so it is clamped at `RallyLibrary.GHOST_SOLVABLE_PACE` — 0.976× the
rival's optimum, measured as where the shipped exponents put `k_max`. **That bound exists
for this file's sake, not for physics'**: the optimum is a point-mass centreline
reference, and a real driver beats it routinely. Whenever either ghost exponent is
retuned, re-measure and move that constant with it.

Note also that a rival carries a BUILD (`upgrades`, see
[rally-roster.md](rally-roster.md)) as well as an engine, and its time was drawn off a
meta that includes those parts. `RallySession._effective_meta_for` rebuilds that same meta
via `CarPerformance.merged_meta`; dropping the parts would hand this solver a slower car
than the one that set the time and push every solve to the clamp.

### Bracket, clamps and exactness

- Bracket is `[rival_ghost_skill_min, rival_ghost_skill_max]`, and `skill_max` is
  deliberately **above 1.0**: a safety valve for cached-vs-live track divergence, where
  the target can land beyond the car's ungraded optimum. Without the headroom those
  solves would fall onto the uniform-scale fallback this design exists to avoid.
- Time is strictly decreasing in `k`, so bisection is well-posed.
- Out-of-bracket at **either** end clamps, `push_warning`s, and micro-scales anyway —
  the ghost's *time* still matches the standings, which is the invariant that matters.
- After bisection a final uniform **micro-scale** puts the total on the target. Exact to
  **±1 ms** (`total_ms` is an int round), not exactly.
- If the bisection leaves a residual beyond `rival_ghost_max_time_residual_ms`, the
  micro-scale is doing the shape's job — i.e. a disguised uniform slowdown — so it warns
  rather than shipping silently.

Read-outs `solved_k()`, `residual_ms()`, `used_fallback()` exist so which path the solve
took is observable (and testable) rather than inferred.

### The timed-span curve

`RivalPace.timed_span_track(source, from, to)` resamples the road centerline between two
arc offsets into a fresh `Curve2D`. The ghost must be solved over the span the **player
is timed on**, not the raw generated centerline: `optimum_profile` puts `t = 0` at a
standing start wherever its curve begins, and the raw curve begins tens of metres past
where the player actually launches — so solving over it parks the ghost short of the
finish.

Resample step is `SUB_CURVE_STEP_M = 0.5`, deliberately much finer than the model's
`SAMPLE_STEP_M = 2.0`: curvature is derived from chord heading changes over one sample
step, so resampling *at* the sample step would concentrate each vertex's whole turn onto
one sample and produce a kappa spike/zero comb, biasing the (nonlinear) cornering cap
downward and making every ghost systematically slow.

What a finer step **cannot** do is add fidelity — `Curve2D.sample_baked` lerps between
points baked at `bake_interval`, so any resample reproduces those chords. That is fine
and in fact wanted: the goal is **parity** with the profile the authored rival times came
from, not a better one.

## `GhostCar` — the presentation

A `Node3D` owning one display car built through **`CarProp.spawn`** (see
[garage.md](garage.md) for that recipe): `use_isolated_config()` so its `apply_car`
can't stomp the player's live tuning in the shared `Config.data`, and `dup_meshes` so it
can't resize `car.tscn`'s *shared* body/wheel subresources.

The wreck preset is the wrong default and every override matters — `spawn()` freezes by
default (a frozen body renders at its freeze pose, defeating the pose write), and
`_spawn_wreck_car` adds `disable_process` plus an hp-zeroing configure, so reused as-is
the ghost would be a frozen, process-disabled car smoking like a wreck. The ghost passes
`index` (**required** alongside `engine_id`, or `spawn()` silently builds catalogue car
0), `freeze: false`, `stop_physics: true`, and a configure that zeroes
`collision_layer` / `collision_mask` and sets `kinematic_pose`.

Per frame (`pose_at`, split out from `_process` so the whole chain is testable without a
running stage):

- `rendered = progress.origin_offset() + pace.offset_at(elapsed)`, clamped to
  `progress.finish_offset()` — so the ghost **parks** at the line rather than sailing
  into the runoff or looping the way the post-event replay ghost does.
- position from `progress.sample_at(rendered)`; `y` from `terrain.height_at` plus the
  car's analytic `settled_ride_height`, wheels drooped by `settle_wheels_to_ground`
  (pure node math — no collider, so it works far from the player where no terrain
  collision is streamed).
- **Laid onto the road surface, not stood level on it.** The basis' up vector is the terrain
  normal from `_surface_normal` (finite differences along and across the road over
  `NORMAL_PROBE_M`), with the travel direction projected onto that plane so the two stay
  perpendicular. With world up instead, the ghost stands level on every slope and visibly
  floats at the nose / digs in at the tail on a climb. Slip yaw is applied about the surface
  normal too, so a cambered corner keeps its wheels on the road.
- **Fades out as the player closes in**: full `rival_ghost_opacity` at
  `rival_ghost_fade_near_m`, ramping to fully transparent at zero separation, driven per
  frame over the retained ghost materials. A solid car you are overlapping fills the screen
  and hides the road you are trying to drive.
- **Heading by centred difference** over `HEADING_PROBE_M`, falling back to backward-only
  at the finish clamp (where a forward sample would cross into the post-finish runoff).
  Backward-only everywhere was the original form and it made the ghost point where the road
  *was* — see *Two rotation bugs* below.
- Wheel spin by filling `drivetrain.replay_omega` from `speed_at / wheel_radius`.

### Transparency

Fading is done with a per-mesh `StandardMaterial3D` override, not
`GeometryInstance3D.transparency`: that property only multiplies alpha for a material
already in the transparent pass, and the car's `ps1_models_lit.gdshader` is
`render_mode unshaded` and never writes `ALPHA`, so it renders opaque and the instance fade
is a no-op. Adding an alpha write to that shader was rejected — it would move EVERY car
into the transparent queue, and that file's comments document how deliberately its cost is
kept off mobile.

The override **writes depth** (`DEPTH_DRAW_ALWAYS`). Without it every panel blends against
every other, so you see through the ghost's near side to its own far side — an x-ray look
that never reads as solid however high `rival_ghost_opacity` goes. The trade-off, taken
deliberately: at low opacity only the nearest surface shows, and separate meshes can sort
inconsistently against each other, since a blended pass has no per-pixel ordering
guarantee.

**Known limitation:** flattening onto a `StandardMaterial3D` drops the car shader's
per-vertex fake lighting (`v_light`) and its vertex-colour multiply, so the ghost is
slightly flatter than the player's car. Fixing that means giving the ghost a
`ShaderMaterial` variant of `ps1_models_lit`, which then has to be kept in sync with it —
or factoring the shared body into a `.gdshaderinc`, which means editing the perf-sensitive
shader the player's car uses. Dithered/alpha-hash transparency is the textbook third
option and is deliberately NOT used: `tree_canopy.gdshader` records that this project
removed dithered fades because any `discard` disables early-Z/HSR for the whole draw on
tile-based mobile GPUs.

### Cosmetics — body only, never the clock

`offset_at(t)` is the invariant. These change the pose, not the pace:

- **Lateral line offset** toward the inside, scaled by local curvature.
- **Cornering slip angle, derived from the tyre model and the friction circle** rather
  than authored per surface — see *Slip angle comes from the tyre model* below.
- Both share **one** road-width budget (`|lateral| + tail_swing ≤ half_width − margin`),
  because two independent clamps are jointly unsatisfiable: a body centre allowed to sit
  at the half-width puts its tail off the road the moment it yaws.

## Slip angle comes from the tyre model

A tyre generating peak lateral force **is** at its peak-slip angle, so the ghost's slip
should be that angle whenever cornering is using all the grip — and proportionally less
when it isn't. That is what it computes now, instead of an invented per-surface number.

- **The angle**: `*_slip_peak` is a NORMALISED slip (the sine of the slip angle laterally),
  so the peak angle is `asin(slip_peak)` — about **11.5 deg** on tarmac at 0.20 and
  **20.5 deg** on gravel at 0.35, blended by `event_tarmac_fraction`. The
  gravel-slides-more-than-tarmac difference therefore falls out of the shared physics for
  free: retune `gravel_slip_peak` / `tarmac_slip_peak` and the player's car moves with it.
  There is no second set of ghost-only angles to keep in sync.
- **The fraction**: how much of the friction circle cornering is actually using.
  `a_lat = v^2 * kappa` against the lateral grip still available once longitudinal demand
  has taken its share, `sqrt((mu*g)^2 - a_long^2)`, with `a_long` differenced off the pace
  profile's own speeds. Neither braking nor accelerating and at the cornering limit gives
  1 — full optimum slip. Braking in or powering out spends part of the circle
  longitudinally, and slip drops accordingly.
- **`mu` mirrors `LapTimeModel._surface_grip`**, including `pow(solved_k, grip_exponent)`,
  so the cosmetic agrees with the profile it is drawn from rather than assuming full grip.
  It does **not** fold in the tyre load-sensitivity factor the profile applies on top of
  that μ, and that is a knowing approximation rather than an oversight: this μ only sets
  what *fraction* of the friction circle cornering is using, the factor is a gentle few
  percent, and it moves the numerator and the circle together. If it is ever retuned hard
  enough to matter, this is the site to revisit — the pace itself is already correct.
- **Weather is deliberately absent from the ANGLE.** Rain lowers `mu`, and the pace profile
  already answers that by cornering slower. The angle at which a tyre peaks is a property
  of the rubber and surface, not of how much grip is on offer. An earlier version divided
  by the weather multiplier to make wet "slide more" — invented, not derived, now gone.
- `rival_ghost_slip_scale` (1.0 = physical) remains for exaggerating the drift, and
  `rival_ghost_max_slip_deg` is still a hard cap.

## `car.gd` → `kinematic_pose`

A mode distinct from `replay_playback`, for two reasons the ghost can't work around:
`replay_playback` needs a `ReplayRecorder` (`_step_replay` early-returns without one, so
nothing would feed the wheel spin), and it is read outside `car.gd` by
`track_progress.gd`, where a second car asserting it risks corrupting player progress.

The flag's setter owns the `process_priority` swap so no caller can forget it. It gates
five sites:

| Site | Without it |
|---|---|
| `_driver_input_live()` | the ghost runs the full drive sim **on the player's live input** — it is neither `controls_locked` nor `ai_controlled` |
| `_physics_process` early return | drivetrain / engine / stuck-and-water watchdogs run on a teleported body |
| `_integrate_forces` early return | per-frame repositioning reads as huge deceleration, draining HP and wrecking the ghost |
| `drivetrain.replay_spin` | the ghost slides down the road on four dead wheels |
| `process_priority` | observers read a stale pose |

## Wiring (`world.gd`) — two phases

The solve depends on `TrackProgress.origin_offset()`, and that is **re-anchored after
generation**: `StageManager.setup(staged)` doesn't call `_mark_progress_start`; instead
`start_line.gd` `reset_to`s the player into their grid slot and only then
`begin_countdown()` → `mark_start()`. So:

| Phase | When | What |
|---|---|---|
| 1 — construct | generate path (`_setup_stage_splits`) | snapshot P1, capture the raw turn boundaries, build the `GhostCar` (hidden, clockless) |
| 2 — solve | `StageManager.stage_started` (`_solve_rival_pace`) | build the timed-span curve from the now-anchored origin, solve, feed the ghost and the popup, start the clock |

**Not gated on `_headless`.** `world.gd`'s `_headless` is `Platform.is_headless()`, which
is always true under the test runner — gating construction there would make the whole
feature untestable. Only *visibility* is headless-gated, inside `GhostCar`.

The ghost node is `_replace_named_child`'d, not `_ensure_child`'d: reuse would carry the
previous event's pace and car build into the next stage.

## Rebuilt when the field is re-drawn

Phase 1 snapshots P1 when the stage BUILDS — which is before the start-line overlay
appears. The player can change upgrades on that overlay, and because the rival grid is
matched to the player's `CarPerformance` rating
([car-performance.md](car-performance.md)), that re-matches the whole field. The leader
they are about to chase is then not the one the ghost was built from.

So `RallySession.refield_opponents` emits **`opponent_field_changed`**, and
`world.gd::_on_opponent_field_changed` re-runs `_setup_stage_splits` against the stored
`_splits_track_result` — re-reading P1 and rebuilding the ghost node. The track is not
regenerated; this is a pure re-read.

Two guards, both load-bearing:

- **Nothing happens once the stage has started.** `_rival_pace` is set at GO, so a
  non-null pace means the refresh is skipped — swapping the ghost out mid-lap would move
  the player's target while they are chasing it.
- **A refused or no-op refield emits nothing.** `refield_opponents` returns `false` (and
  stays silent) when the rating is unchanged or when a stage has already been raced, so
  opening the upgrades page and closing it unchanged does not churn the ghost.

## One pace model, two consumers

The in-stage "vs P1" delta popup ([stage.md](stage.md)) now takes its **times** from the
same `RivalPace`, so the number on the HUD and the car in the windscreen cannot disagree
about the same rival.

`RallyLibrary.derive_turn_splits` is still the source of the per-turn **boundaries** — it
is the only thing that knows where each placed piece ends — but those offsets are measured
on the **raw** curve, while the profile starts at the timing origin. `_wire_stage_splits`
therefore shifts them by `start_lead_in_ahead_m` on a staged run before calling
`time_at_offset`; without that every turn reads one lead-in early and the final boundary
stops landing on the total, breaking the popup's `cum/total → 1.0` tail.

`RivalPace` is built for **every** session run, independent of `rival_ghost_enabled` —
the popup depends on it, so gating it on the ghost's display flag would kill the popup
whenever the ghost was switched off.

## Leaderboard fidelity

`RallySession.current_event_p1()` returns **one snapshot** — `time_ms`, `car_id`,
`engine_id` and the effective `meta` — from a single `current_event_leaders(1)` read.
`current_event_target_ms()` and `current_event_p1_car()` now delegate to it, so the three
P1 consumers share one lookup structurally rather than agreeing by luck.

The meta goes through `UpgradeLibrary.effective_meta` with the rival's **fitted** engine:
a bare catalogue entry derives a profile for a car that wasn't racing, while the time it
is compared against came from the swapped build in `generate_opponent_field`.

Because `current_event_leaders` filters `t >= 0`, the ghost is always the fastest
**classified** rival — DNFs and wrecked rivals are excluded, so the ghost can never be a
rival whose car is simultaneously staged as a roadside wreck.

## Config (`GameConfig`, *Rival Ghost* group)

`rival_ghost_enabled`, `rival_ghost_visible_m`, `rival_ghost_opacity`,
`rival_ghost_line_offset_m`, `rival_ghost_gravel_slip_deg`,
`rival_ghost_tarmac_slip_deg`, `rival_ghost_max_slip_deg`, `rival_ghost_slip_lag_s`,
`rival_ghost_fade_near_m`, `rival_ghost_grip_exponent`, `rival_ghost_power_exponent`,
`rival_ghost_skill_min`, `rival_ghost_skill_max`, `rival_ghost_skill_iterations`,
`rival_ghost_max_time_residual_ms`. No test pins any of them — the tests that are about a
deficit split set the exponents themselves, precisely so retuning the ghost's look cannot
break unrelated assertions.

## Pace seeds (`skill_k`) — the seam, now always unseeded

The expensive part of the solve is the **search**, not the sweep, so `RivalPace.solve`
takes an optional precomputed `cached_k` seed to skip it.

**Nothing fills it today.** The seeds used to be baked into `data/opponent_cache.json`
by `tools/generate_opponent_cache.gd`, one float per event for each event's P1. That
lockfile is gone — the rival field is drawn matched to the player's car rating, so it is
generated live and cannot be precomputed per rally (see
[rally-session.md](rally-session.md)). `RallyLibrary.generate_opponent_field` therefore
emits `"skill_k": []`, `current_event_p1()` surfaces no seed, and every ghost solves
from scratch with the full bisection.

- **The seam is kept deliberately.** A seed is VALIDATED, not trusted: `RivalPace.solve`
  runs **one** sweep with it, accepts it if the residual is inside
  `rival_ghost_max_time_residual_ms`, and otherwise warns and falls through to the full
  14-sweep solve. Any future precompute can hand a seed back in without re-deriving that
  safety check.
- **Never bake the profile arrays instead.** Storing P1's `s`/`v`/`t` per event would be
  ~1.3 MB and would store the wrong thing: a speed profile is track-shaped, so a
  stale-vs-live mismatch would apply old corner speeds to corners that no longer exist.
  A seed keeps the profile generated from the live curve.

- `RallySession.current_event_p1()` surfaces the current event's seed as `skill_k`
  (empty today). `_p1_skill_seed` takes the target time as an **argument** rather than
  calling `current_event_target_ms()` — that delegates back to `current_event_p1()`,
  i.e. infinite recursion.

## Ghost dust

The ghost owns a **second `WheelParticles` instance** (`_add_dust`), because that node
tracks one car and `world.gd` wires its only instance to the player's. An earlier draft of
this document claimed dust came "for free" from `drivetrain.replay_omega` — that override
is necessary but not sufficient, since no particle system was looking at the ghost's
drivetrain at all. Everything else (spin, driven axle, the terrain that classifies gravel
vs grass) it reads live off the car, so `setup(car)` is the whole wiring. Toggle:
`rival_ghost_dust_enabled` — it is a real per-wheel cost, not a free ride.

## Smoothness: why the ghost slid and snapped

The road curve `TrackProgress` measures on stores baked points every `bake_interval`
(**5 m**) and lerps between them, and its 1 m point table is a resample of those chords, so
it adds no fidelity. The geometry the ghost can see is a ~5 m chord polyline with all the
turning concentrated at vertices.

A probe SHORTER than a chord therefore reads inside one straight segment and returns a
piecewise-constant answer that jumps a whole chord angle at each vertex. The first version
used a 1.5 m heading probe and a 6 m curvature probe, and the ghost visibly snapped its
rotation and slid side to side — the slide because the curvature **sign** flipped between
frames and the lateral line offset follows that sign.

Measured on a real 485 m generated stage with `tools/probe_jitter.tscn`:

| probe span | max heading change per frame | curvature sign flips per stage |
|---|---|---|
| 1.5 m | 6.51 deg | 174 |
| 6.0 m | 3.13 deg | 26 |
| **10.0 m** (heading, now) | 2.65 deg | 6 |
| **20.0 m** (curvature, now) | 2.37 deg | 4 |

So the probes span several chords, and a filter handles the residual. **Two independent
constants**, because they want opposite treatment:

- `rival_ghost_position_smoothing_s` (0.45) — the LATERAL offset. Wants a heavy hand.
- `rival_ghost_rotation_smoothing_s` — the basis slerp. Wants a light one: heavy rotational
  filtering makes the car turn lazily and lag its own direction of travel, which itself
  reads as sliding.

**Along-track position is never smoothed.** It is the ghost's clock; filtering it would make
the ghost miss the time the standings report. Only lateral offset and orientation are
filtered, and a test asserts the arc offset is bit-identical with smoothing on and off.

### Two rotation bugs that felt like smoothing

Both were reported as "the slip angle is the wrong way, or at least it lags", and both were
real — they compounded, which is why one description covered two defects.

**The slip sign was inverted.** Curvature is measured in the 2D curve space, which is
`Vector2(world_x, world_z)`, so its angles are `atan2(z, x)`. But `Basis(Vector3.UP, +a)`
rotates +Z toward +X, which **decreases** that 2D angle. The two conventions run opposite,
so feeding the 2D curvature sign straight into the yaw pointed the nose OUT of every
corner. A rally car slides nose-inside. `_basis_from` now negates, and
`test_the_ghost_yaws_INTO_the_corner_not_out_of_it` pins the nose's side against the road's
own turn sign rather than against a hardcoded direction, so the convention cannot silently
flip back.

**The heading lagged the road.** `_heading_at` used a purely BACKWARD difference (chosen so
that at the finish clamp a forward sample could not cross into the post-finish runoff,
which bends away from the stage). That makes the facing the chord from a full probe-span
behind, i.e. the ghost points where the road *was* — a systematic turn-in-late look. At a
curvature transition the lag exceeded the slip angle and put the nose on the wrong side
outright. It is now a **centred** difference, with the backward-only form kept solely for
the clamp.

Worth noting for anyone touching this: the lateral offset has the *same* handedness trap
and gets away with it by accident — its "right" vector is also computed in 2D and is
actually the left direction, which cancels against the negated `turn_sign`. Two sign errors
that happen to agree. Do not "tidy" one of them alone.

### There are TWO rotational filters

`rival_ghost_rotation_smoothing_s` is not the only one. `rival_ghost_slip_lag_s` lags the
slip angle, and slip is a yaw folded into the same basis — so zeroing the rotation constant
alone still leaves rotation filtered in corners. **Both must be zero** for genuinely
unfiltered rotation. The naming hid this; both fields now cross-reference each other, and a
test pins it.

### Every knob is read live

The per-frame tunables are read from `Config.data` inside `pose_at`, not cached at
`setup()`. Caching meant a value change did nothing until the next stage spawned a fresh
ghost, which makes the tune-by-eye loop these knobs exist for useless. Only structural or
expensive things (materials, the dust instance, the nametag) are resolved once.

## Nametag

P1's name floats above the ghost as a billboarded `Label3D`, parented to the CAR so it
inherits the pose (slip yaw and road tilt included) with no per-frame update of its own,
and fades with the proximity fade — left opaque it would hang in the air over an invisible
car. Styled after `finish_arch.gd`'s banners so the game keeps one 3D-text look. Depth
testing stays on: a name showing through a hillside reads as UI, not as part of the world.
Config: `rival_ghost_nametag_enabled`, `_height_m`, `_size_m`.

## Not built yet

- **Ghost engine audio.** A silent ghost is not a bug; a wrong-sounding one is.
- **Own-PB and downloaded leaderboard ghosts.** Same pair with a different pace source;
  `ReplayRecorder` frames are never serialized today.
- **Seeds for rivals other than P1**, which a multi-rival field would need.

## Tests

`tests/headless/test_rival_pace.gd` — the solve (target fidelity across a pace sweep,
both clamps, monotonic and clamped queries, the corner-vs-straight shape, resample
fidelity against a **handled** Bezier curve, and the cached-seed paths).
`tests/headless/test_ghost_car.gd` — the coordinate mapping (origin-relative offset,
parking at the finish, monotonicity), the cosmetics' direction and bounds, and the
display car's intangibility. `tests/headless/test_kinematic_pose.gd` — the five gates,
including that the ghost is dead to live player input and takes no damage.
`tests/headless/test_ghost_car_display.gd` — the scene-backed half: the display car's
intangibility, the road-incline tilt, the proximity fade, and the dust instance.
**`tests/headless/test_ghost_wiring.gd`** — `world.gd`'s two phases end to end against a
real booted world and a synthetic field. This file exists because every runtime bug this
feature shipped lived in the plumbing rather than the pieces (a wrong-arity callback that
only fired at countdown zero, a solve scheduled before the timing origin was anchored, a
180-degree facing error): the parts were tested, the ORDER was not. It builds the world once
in `before_all` — per-test instantiation cost 28 s for the file.
`tests/headless/test_lap_time_model.gd` — the multiplier seam, and that its defaults are
byte-identical no-ops. `tests/headless/test_track_progress.gd` — the two new accessors.
Synthetic curves come from `tests/headless/track_fixtures.gd` (`TrackFixtures`).
