# Car Physics & Control

**Source:** `scripts/car.gd` (extends `VehicleBody3D`), scene `car.tscn`.

The car is a Godot `VehicleBody3D`, but its tire friction is custom — see
[drivetrain-and-tires.md](drivetrain-and-tires.md). `car.gd` owns input
handling, chassis-level forces (drag, downforce, steering, yaw assist), and the
reset feature, and delegates wheel/engine simulation to `Drivetrain`.

## Lifecycle

- `_ready()` — caches wheels, builds the `Drivetrain` (which owns the
  `EngineSim`), sets up the debug overlay, records `_start_transform`, and
  computes `_front_axle` / `_rear_axle` local midpoints (downforce application
  points).
- `_physics_process(delta)` — the per-step control loop (below).
- `_reset()` — restores `_start_transform`, zeroes linear/angular velocity, and
  resets the drivetrain/engine. Bound to **R**.

### Hitbox shape (chamfered octagon)

The chassis collision hull is **not a plain box** — it's a box with its four
**vertical** corners chamfered, so from the top it's an elongated octagon
(`_chassis_hull_points` in `car.gd`). `_apply_body_meshes` swaps the scene's default
`BoxShape3D` for a per-car `ConvexPolygonShape3D` whose 16 points (8 top-view corners ×
top/bottom) are rebuilt from the body dims each `apply_car`. The corner cut is an
**equal absolute inset on both width (X) and length (Z)** — `body.x ×
GameConfig.hitbox_chamfer_fraction` (default **1/3**) — so the cut is 45° and the
nose/tail read as a regular octagon (a third-of-width chamfer leaves a flat front edge
one-third the car's width). The inset is clamped so every face keeps a positive flat
edge. The hull's **bounding extents are unchanged** (the mid-edge points still reach
`body.x`, `body.y − 0.3`, `body.z`), so weight/CoM/ride-height are unaffected — only the
corners are pulled in.

Why: the hull is only ever hit by *obstacles* (trees, signs, spectators, other cars) and
feeds the damage model's contact impulses — the wheels are independent raycasts, so this
shape has **zero effect on grip, top speed, or cornering**. Chamfering makes a glancing
corner clip **deflect along** the obstacle instead of catching the square corner and
snapping the car, and (being a glancing rather than square contact) costs marginally less
HP on side-swipes. The [debug overlay](debug-tools.md) draws the octagon prism, rebuilt
from the same hull points. Geometry is covered by `test_chassis_hull_*` in
`tests/headless/test_car_types.gd`.

### Per-instance resource isolation

`car.tscn` authors the chassis/cabin boxes, the wheel tyre/spoke meshes, and the
chassis **collision shape** as `[sub_resource]`s. Godot shares one copy of a
sub-resource across **every instance** of the scene, and `apply_car()` reshapes these
in place per car (`_apply_body_meshes` / `_relocate_wheels`). So without isolation, a
second live car — the [start-line](start-line.md) queue leader/trailer, spawned and
`apply_car`'d **after** the player is already sized — reshapes the shared resource and
the change bleeds back onto the player: wrong wheel visuals, or (the subtler one) the
player's **hitbox** taking the last-applied car's body size while the meshes still look
right. `car.gd._ready()` defends against this by giving each instance its own copies up
front (`.duplicate()` of the Chassis/Cabin meshes, each wheel's tyre/spoke mesh, and
the collision shape) before any `apply_car` can run. The hitbox is doubly safe now that
`_apply_body_meshes` assigns a **fresh** `ConvexPolygonShape3D` per instance (the scene
`BoxShape3D` is only the un-applied fallback), but the duplicate still covers a car that
never gets `apply_car`'d. Any *new* shared sub-resource that `apply_car` mutates must be
added to that list, or it will silently leak across instances — this class of bug has
bitten wheels and the hitbox already (`tests/headless/test_car_types.gd` has a regression
for each).

## Per-step loop (`_physics_process`)

1. **Mode inputs:** `toggle_gearbox` (T) flips `engine.auto`; `cycle_drive_mode`
   (Y) cycles RWD→AWD→FWD; `shift_up`/`shift_down` (E/Q) request manual shifts.
2. **Throttle/brake resolution:**
   - *Auto:* `engine.select_forward/select_reverse` pick a gear at low speed;
	 `engine.update_auto` handles upshifts based on ground speed.
   - *Manual:* W accelerates (or reverses in R gear); S brakes / reverses.
   - Near-zero speed engages a parking brake.
3. **Steering:** the raw input is first smoothed once into a single `_steer`
   value (eased toward the input at the same angular rate the wheels turn,
   `steer_speed / steer_limit`), so a keyboard's instant 0→1 doesn't jerk; both
   the wheel-angle target and the yaw assist torque read this same value, keeping
   them 1:1. Front wheels caster toward the direction of travel
   (`steer_travel_alignment`), blended with the smoothed input up to `steer_limit`
   at `steer_speed`. The input steering offset is **physically bounded** by the
   front tire's optimum slip angle (`Car.optimum_steer_limit`), not a tuned speed
   ramp: the normalized slip a steering offset θ induces is `sin(θ)·speed/v_ref`
   (`v_ref` floored at `tire_norm_floor`), so the largest offset that keeps the
   tire on its grip peak is `sin(θ) = slip_peak·v_ref/speed`, which pins to
   `asin(slip_peak)` — the surface's optimum slip angle (≈8° tarmac, ≈18° gravel),
   speed-independent — because capping at the optimum is also the tightest
   achievable turn. `slip_peak` is the surface under the steering axle
   (`Drivetrain.steering_axle_slip_peak`). Below `STEER_LOCK_BLEND_END_SPEED`
   (50 km/h) the effective cap blends **linearly** from the full mechanical
   `steer_limit` at standstill down to that slip-based cap, so parking-speed turning
   keeps full bite; above 50 km/h it is purely slip-based.
   The steer-assist yaw torque is scaled by the same reduction
   (`Car.steer_authority` = cap ÷ `steer_limit`) so the smaller wheel angle is
   actually felt — in this arcade model the assist provides most of the turning
   authority and would otherwise mask it. The travel-alignment countersteer and
   spin protection are deliberately NOT scaled, so slides still catch. The
   alignment fraction is scaled linearly with speed — 0 at
   standstill ramping to its full configured value at `steer_assist_min_speed`
   (≈30 km/h) — so it never snaps in suddenly at low speed. A direct yaw torque
   (`steer_assist_torque`, authored **per car** in `CarLibrary` and overlaid onto
   the config by `apply_car()`; the global `GameConfig` value is a 0 fallback, so
   only cars that author a value get the aid) fights understeer,
   faded in linearly from 0 at standstill to full at `steer_assist_min_speed`
   (≈30 km/h) — rather than switched on abruptly at that threshold — so it ramps
   up smoothly without making low-speed handling twitchy. It also tapers with the
   car's slip angle: full when the car points along its travel direction, fading
   linearly to zero once it has rotated the surface's optimum slip angle
   (`asin(slip_peak)`, ≈8–18°) into the turn — the aid rotates the car in until the
   tires reach peak grip, then stops adding, so it won't keep over-rotating it into a
   spin. **Spin protection** (`spin_assist_torque`) is the recovery counterpart:
   once the car has rotated further than `spin_assist_angle` (≈35°) away from its
   travel direction, a corrective yaw torque pulls the nose back toward the travel
   direction, ramping in linearly from 0 at the threshold to full at twice it and
   sharing the steer assist's speed fade-in. A yaw-rate damping term
   (`SPIN_ASSIST_DAMPING`) settles the slide instead of oscillating. Suppressed
   while the handbrake is held (so deliberate drifts work), and only active while
   travelling nose-forward — it prevents reaching a spin rather than unwinding a
   completed one.
4. **Aero forces:**
   - *Drag:* `-velocity * |velocity| * drag_coefficient` (quadratic). `linear_damp`
	 is forced to 0 so this is the only speed-dependent linear loss. The body's
	 `angular_damp` is likewise forced to 0 in `_ready` (Godot's implicit default is
	 0.1) so a launched car keeps its spin mid-air instead of being passively slowed;
	 grounded rotation is governed by the tire model + the steer/spin/level assists.
   - *Downforce:* `v² * downforce_{front,rear}` applied at the axle midpoints;
	 also recorded in `downforce_readouts` for the debug overlay. Either
	 coefficient may be negative, which produces lift (an upward force that
	 unloads that axle at speed). The coefficients are **per-car**: `apply_car`
	 *sets* `cfg.downforce_{front,rear}` from the CarLibrary spec (so a car with 0
	 has none — no hidden global), and the aero_kit upgrade adds on top. Every car
	 carries a small `downforce_rear` to keep the tail planted under power; front
	 is 0 unless a spec sets it.
5. **Self-righting assist:** when one or more wheels are off the ground, a
   roll+pitch torque (`level_assist_torque`) eases the chassis back toward
   level. The torque axis is `car_up × world_up` — it lies in the horizontal
   plane (so it never yaws) and its magnitude is `sin(tilt)`, so the correction
   grows the further the car is from flat. Inert once all four wheels plant.
6. **Tire/engine step:** `drivetrain.step(delta, throttle, brake, handbrake)`
   computes and applies all wheel contact forces.

## Suspension

Springs configured from `suspension_stiffness` / `suspension_travel`. Damping is
derived in `GameConfig`: compression = √rate (critically damped), rebound =
1.5× compression. Per-wheel normal force is computed in
`Drivetrain.wheel_normal_force()`.

**Per-axle spring rates.** The authored `suspension_stiffness` is the car's
*overall* rate; the front/rear rates are not authored but **split from it by the
weight distribution** — `GameConfig.axle_stiffness(front)` returns
`suspension_stiffness × 2 × axle_weight_fraction` (the ×2 keeps the two-axle mean
at the base rate, so a 50/50 car gets the base rate on both). Because static
compression is `load / rate` and both scale with the axle's weight fraction, the
compression works out **equal front and rear** (`≈ g/(4·rate)`, independent of
distribution) — so a nose-heavy car sits **level** instead of drooping onto its
heavy end. Dampers are re-derived per axle from the resolved rate. This is the
partner to the per-car centre of mass (see "Weight distribution"): `weight_front`
drives both.

`suspension_travel` doubles as the wheel raycast / rest length, so a shorter
travel also lowers ride height. Optional `suspension_travel_front` /
`suspension_travel_rear` overrides (0 = inherit `suspension_travel`) let a body run
a longer front or rear stroke for rake / wheel-well fit; `axle_travel(front)`
resolves them per wheel. These values are all **per-car**: each `CarLibrary` entry
carries its own `suspension_travel` + `suspension_stiffness` (+ optional per-axle
travel), overlaid onto the live config by `car.gd`'s `apply_car()` and pushed onto
each wheel per axle via `_apply_suspension()` (dampers re-derived; the standalone
`_sync_suspension_to_wheels()` re-pushes after an upgrade mutates the rate). Soft &
tall roadster/muscle (MX-5, Charger) vs stiff & low supercars (911, Viper,
XJS). The `config/game_config.tres` values are the baseline/fallback.

### Static rest pose (`settled_ride_height`)

Display / prop cars — the roadside opponent wreck (`world.gd`), the podium finishers
(`podium.gd`), and the HQ parked lineup (`hq.gd`) — are placed **analytically at rest
and frozen at once**, instead of being dropped as live physics bodies and frozen a beat
later. That old drop-and-settle was a recurring bug source: it depended on a ground
collider being present under the car (the wreck sank through the streamed-in-only-near-
the-player terrain), on the car not rolling on a slope, and on not re-wrecking on the
landing impact — plus the freeze timing.

Placing a prop takes **two** offsets — the body and the wheels move independently:

```
settled_ride_height = wheel_radius + axle_travel − mount_y            # wheel fully drooped
                    − SUSPENSION_COMPRESSION_COEFF · g / suspension_stiffness   # sag under weight
wheel Visual droop  = wheel_rest_length − WHEEL_DROOP_COEFF · g / suspension_stiffness  # per wheel
```

`car.settled_ride_height()` returns how far the body origin sits above flat ground at
rest — the height a **live** car settles to. That height assumes the wheels have drooped
down below their authored mount (as Godot's solver renders them while driving). But a
frozen prop's solver never runs, and `drivetrain._update_visuals` only re-orients the
wheel Visual (never translates it), so left alone the Visual stays at its authored mount
— ~`axle_travel` too high, so the car reads as sitting on **over-compressed** suspension
and floats. So after seating the body, a caller also calls **`car.settle_wheel_visuals()`**,
which drops each wheel Visual by the droop above to where Godot's live solver would render
it. This must run on frozen props **only** — a live car lets Godot move the wheel node and
keeps its Visual at the local origin.

Both compression terms come from Godot's built-in `VehicleWheel3D` solver (**not** the
game's own tire model — they disagree by ~0.1 m) and are **mass-independent** (Godot
normalises the spring by chassis mass). `SUSPENSION_COMPRESSION_COEFF` and
`WHEEL_DROOP_COEFF` are both calibrated against a real settle and pinned by
`test_rest_pose.gd`, which re-derives them from an actual `VehicleWheel3D` settle across a
range of configs (and checks the drooped prop Visual lands at the live wheel height),
failing loudly if a Godot upgrade shifts the solver — so the constants can't silently
drift. A caller seats the car on its ground plane, lifts the body by
`settled_ride_height()`, droops the wheels, then freezes `FREEZE_MODE_STATIC`.

## Weight distribution (centre of mass)

Each `CarLibrary` entry carries a real `weight_front` — the car's published static
front-axle weight fraction (0.50 = 50/50, >0.5 nose-heavy, <0.5 tail-heavy).
`apply_car()` switches the body to `CENTER_OF_MASS_MODE_CUSTOM` and places the CoM
along the wheelbase: for static balance the CoM sits behind the front axle by
`wheelbase × rear_fraction`, so from the wheelbase-centred body origin (front axle at
−Z, rear at +Z) the offset is `center_of_mass.z = wheelbase × (rear_frac − 0.5)`
(+Z = rearward). Only the front/rear split is authored; the CoM height stays at the
body origin (`y = 0`) — published CoG-height data is scarce and the low
`wheel_roll_influence` (0.1) damps its effect anyway.

This is **not cosmetic**: `Drivetrain.wheel_normal_force()` derives each wheel's grip
from its actual suspension compression, and the suspension settles around wherever the
CoM sits — so a rearward CoM compresses the rear springs more, loads the rear tyres
more, and shifts the car toward oversteer (and vice-versa). The transient effects (dive
/ squat / roll load-transfer) are deliberately muted by the low `wheel_roll_influence`;
the static front/rear balance comes through regardless. Nose-heavy FWD (Focus, Twingo)
and nose-heavy front-engine GT (XJS) vs tail-heavy mid-engine (Acty) vs
near-50/50 (MX-5, Viper).

**Recompute on engine swap.** [engine-swap.md](engine-swap.md) lets a player move an
engine from one owned car to another. `car.gd`'s `_apply_engine_swap` treats the
engine as an independent point mass at the car's `engine_pos` (a `CarLibrary` field —
the ENGINE's own front-weight fraction, distinct from the car's overall `weight_front`)
and re-derives both `mass` and `weight_front` from the authored baseline via
`EngineSwap.recompute_mass` / `EngineSwap.recompute_weight_front`, then re-applies the
same `center_of_mass.z = wheelbase × (0.5 − weight_front)` formula above with the new
`weight_front`. This runs before the upgrade/tuning steps and before the suspension
re-sync, so a swapped-in heavy V8 (or a lightweight rear-engined flat-6) shifts the
car's static balance — and hence its suspension load split and handling bias — exactly
like a different authored `weight_front` would.

## Damage effects

`car.gd` owns a `DamageModel` (see [damage.md](damage.md)) that degrades the car
as its HP falls. Two effects fold into the per-step loop above: physically **bent
wheels** (per-wheel toe on `VehicleWheel3D.steering`, step 3) and an **engine
misfire** — `car.gd` feeds the damage fraction to `engine.misfire_level` (step 6)
and `EngineSim` cuts fuel in stumbling bursts. Both are 0 at full HP. `car.gd` also
enables contact monitoring and reads obstacle-contact impulses in
`_integrate_forces` to drain HP.

## Control source (player / locked / scripted)

`_physics_process` reads its throttle / steer / handbrake from one of three sources:
- **Player** (default) — global `Input` actions.
- **Locked** (`controls_locked`, set by [`StageManager`](stage.md)) — input neutralised
  and the handbrake forced, so the car holds fully still (staged at the line, or after
  the finish) while the rest of the sim (suspension, drag, camera) keeps running.
- **Scripted** (`ai_controlled`) — the car ignores `Input` and drives from
  `ai_throttle` / `ai_steer` / `ai_handbrake` (same axes/sign as the player inputs).
  Used for the [start-line](start-line.md) queue cars, which run full physics (real
  suspension load) under script while axis-locked to a straight line. Discrete actions
  (shift / mode / reset) are ignored when locked or scripted.

A lighter **handbrake-only hold** (`handbrake_locked`, also set by `StageManager`)
forces the handbrake while leaving driver input fully live — used during the
**countdown** so the player can rev the engine (a held handbrake opens the clutch in
[`Engine.step`](engine-and-transmission.md), so the revs climb freely) and steer, then launch the
instant the brake releases on GO.

The **finish stop** (`finish_stop`, set by `StageManager` on crossing the line
alongside `controls_locked`) brakes the car to a halt cleanly: while it's still
rolling (> `FINISH_STOP_SPEED`, 0.8 m/s) it forces the **full foot brake** on top of
the forced handbrake, then releases the foot brake once stopped (the handbrake /
parking hold still holds it put). Crucially the engine **clutch stays engaged**
through the stop — `_physics_process` computes `declutch` as the handbrake by default
but overrides it to `false` here, and passes it to `Drivetrain.step` separately from
the handbrake's brake torque — so the engine **winds down with the braking wheels**
(the speed-gated auto-clutch opens at standstill and it settles to idle) instead of
free-revving on the handbrake's open clutch.

Regardless of source, a car that is fully braked (handbrake **or** the low-speed
parking brake) and below `HANDBRAKE_LOCK_SPEED` (0.5 m/s) gets a **static-friction
hold** — `_apply_parking_hold` cancels its residual in-plane velocity each frame with
a counter-force, clamped to `parking_hold_grip · m · g`. This is needed because the
tire model's longitudinal force fades to zero as slip does (`_tire_force` caps it at
`|slip|·m/h`), so at creep speed gravity's slope component would otherwise win and the
car would dribble downhill. The hold behaves like real stiction: it pins the car on any
sane grade but a wall-steep slope still slides, and — unlike the old `freeze` hack — the
car stays a **live rigid body** (no snap on release, still collidable). This keeps a
settling [start-line](start-line.md) queue car from creeping into the car ahead and
holds the player put during the countdown (`handbrake_locked` forces the handbrake).

## Braking summary

| Input | Torque | Target |
|-------|--------|--------|
| S (foot brake) | `brake_torque` (300) per axle | all 4 wheels |
| Space (handbrake) | `handbrake_torque` (400) | rear axle only (drift) |
| Auto parking | `brake_torque` | all 4 below ~2 m/s |

## Tests

`tests/headless/test_car.gd` (launch, speed, steering, reset),
`tests/headless/test_car_terrain.gd` (behavior on slopes).

## Related config

`mass`, `drag_coefficient`, `downforce_front/rear`, `steer_*`,
`spin_assist_torque`, `spin_assist_angle`, `level_assist_torque`,
`suspension_*`, `brake_torque`, `handbrake_torque`. See
[configuration.md](configuration.md).
