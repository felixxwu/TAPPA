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
   at `steer_speed`. The alignment fraction is scaled linearly with speed — 0 at
   standstill ramping to its full configured value at `steer_assist_min_speed`
   (≈30 km/h) — so it never snaps in suddenly at low speed. A direct yaw torque
   (`steer_assist_torque`) fights understeer,
   faded in linearly from 0 at standstill to full at `steer_assist_min_speed`
   (≈30 km/h) — rather than switched on abruptly at that threshold — so it ramps
   up smoothly without making low-speed handling twitchy. It also tapers with the
   car's slip angle: full when the car points along its travel direction, fading
   linearly to zero once it has rotated `steer_assist_max_angle` (≈30°) into the
   turn, so the aid helps rotate the car in but won't keep over-rotating it into a
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
   - *Drag:* `-velocity * |velocity| * drag_coefficient` (quadratic).
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
[`Engine.step`](drivetrain.md), so the revs climb freely) and steer, then launch the
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
