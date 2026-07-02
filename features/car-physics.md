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
tall roadster/muscle (MX-5, Mustang) vs stiff & low supercars (911, LFA,
Aventador). The `config/game_config.tres` values are the baseline/fallback.

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
vs tail-heavy mid-engine (Acty, Aventador) vs 50/50 (MX-5).

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
  and the handbrake forced, so the car holds still during the countdown while the rest
  of the sim (suspension, drag, camera) keeps running.
- **Scripted** (`ai_controlled`) — the car ignores `Input` and drives from
  `ai_throttle` / `ai_steer` / `ai_handbrake` (same axes/sign as the player inputs).
  Used for the [start-line](start-line.md) queue cars, which run full physics (real
  suspension load) under script while axis-locked to a straight line. Discrete actions
  (shift / mode / reset) are ignored when locked or scripted.

Regardless of source, a car that is holding the handbrake **and** below
`HANDBRAKE_LOCK_SPEED` (0.5 m/s) is **position-locked** — `_apply_handbrake_lock`
freezes the body so it can't be shoved or creep, and unfreezes the instant the
handbrake is released. This is what keeps a settling [start-line](start-line.md) queue
car from drifting into the back of the car ahead, and holds the player put during the
countdown (`controls_locked` forces the handbrake).

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
