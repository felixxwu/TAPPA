# Wheel Spin State & Full Drivetrain — Design

Date: 2026-06-12
Status: approved (pending spec review)

## Goal

Give the car a real wheel spin state: wheels that spin up under power, lock
under braking, and lose lateral grip when slipping — enabling launch
wheelspin, brake lockups, handbrake turns, and progressive breakaway. Make
the spin visible with spoked wheel meshes driven by the simulated spin.

## Decisions (from brainstorming)

- **Depth**: full drivetrain (spin state feeds back into forces; engine
  modeled via the existing force/power caps).
- **Transmission**: single fixed ratio — engine is characterized entirely by
  the existing `engine_force` / `engine_power` sliders, now evaluated against
  wheel surface speed instead of car speed.
- **Differential**: locked rear axle — one shared spin state for both rear
  wheels; torque splits by grip automatically.
- **Brakes**: brake (S) and a new handbrake (Space) apply torque to the spin
  states and can lock wheels. `brake_force` is replaced by `brake_torque`
  and `handbrake_torque` (N·m).
- **Combined slip**: yes — longitudinal slip consumes lateral grip. We take
  over ALL contact-patch friction from Godot's solver
  (`wheel_friction_slip = 0`); Godot keeps suspension + wheel raycasts only.
- **Visuals**: spoked low-poly wheels (dark tire + light spokes + hub),
  rotation driven from the simulated spin state.

## Architecture

```
car.gd (input, steering castering/assist, aero drag, reset)
  └─ drivetrain.gd  (NEW — owned by car, runs in car._physics_process)
       ├─ spin states: rear_omega (locked axle), front_omega[2]
       ├─ torque integration per tick
       ├─ tire model: combined-slip force per contact wheel
       ├─ applies forces via apply_force(contact point)
       ├─ stores per-wheel slip/force readouts for the debug overlay
       └─ writes wheel mesh orientation (spin visual)
wheel_force_debug.gd (draws drivetrain readouts; no longer estimates)
```

`drivetrain.gd` is a plain object (RefCounted) created by `car.gd` in
`_ready()` and stepped explicitly with `step(delta, inputs)` — deterministic
ordering, no node lifecycle.

## Spin dynamics

Per spin state, semi-implicit Euler each physics tick:

```
omega += (T_drive - T_brake - T_reaction - T_engine_braking) / I * delta
```

- `T_drive` (rear axle only):
  `throttle * min(engine_force, engine_power / max(omega * r, 1.0)) * r`.
  The power cap on wheel surface speed self-limits free wheelspin.
- `T_brake`: `brake_input * brake_torque`, opposing omega, both axles.
  `T_handbrake`: `handbrake_torque` on the rear axle only.
  Braking torque is clamped per tick so it can stop the wheel but never
  reverse it (no sign flip-flop at lockup).
- `T_reaction`: `F_long * r` from the tire model (couples wheel to ground).
- `T_engine_braking`: small constant drag at zero throttle (config).
- `I`: `axle_inertia` config for the rear axle; half of it per front wheel.
- Parking brake: existing rule (no throttle, near standstill) now applies
  `brake_torque` — locked wheels at rest produce static-style longitudinal
  friction and hold the car on slopes.

## Tire model (per wheel in contact)

Slip velocity of the contact patch vs the ground, in the contact plane:

- `s_long = omega * r - v_long` (wheel surface speed vs ground speed)
- `s_lat  = -v_lat`
- Combined magnitude with the existing ellipse weighting:
  `s = sqrt((s_long * traction_ellipse_ratio)^2 + s_lat^2)`

Grip curve mapping slip to a fraction of `mu * N`:

- Linear from 0 to `tire_slip_peak` (m/s) → 1.0 (full grip).
- Falls off past the peak to `sliding_grip_ratio` (full slide).

Force = `mu * N * curve(s)`, directed along the (weighted) slip vector,
opposing slip. Consequences by construction: a locked/spinning wheel points
its whole budget longitudinally and lateral grip collapses (handbrake
turns); breakaway is progressive, not binary.

- `mu`: existing `wheel_friction_slip_front` / `_rear` sliders (same
  meaning, now consumed by our model).
- `N`: existing spring+damper reconstruction (`wheel_normal_force`).
- Low-speed stability: force is additionally capped by the impulse that
  would zero the slip this tick (prevents standstill jitter).
- The longitudinal component reacts back on the spin state (`T_reaction`).

## What is removed / unchanged

Removed: `car._apply_drive`, the lateral demand clamp,
`VehicleBody3D.engine_force` / `.brake` usage, `brake_force` config.
Unchanged: steering castering + `steer_travel_alignment`, `steer_limit`,
`steer_speed`, `steer_assist_torque`, aero drag, reset, all suspension
config and behavior, `wheel_roll_influence` (note: with friction zeroed it
becomes inert — our lateral force applies at the contact point; revisit if
roll feel regresses).

## Debug overlay

The drivetrain stores per-wheel readouts (slip vector, demand force, applied
force, normal force). `wheel_force_debug.gd` draws them directly: green =
suspension (unchanged), yellow = pre-curve demand, red = applied tire force.
The arrows become exact, not estimates.

## Visuals

- Spoked wheel: dark `CylinderMesh` tire + 4 light `BoxMesh` spokes + small
  hub cylinder, replacing each wheel's flat cylinder in `main.tscn`.
  Colors: existing `wheel_color` (tire) + new `wheel_spoke_color`.
- Rotation: drivetrain accumulates a spin angle per wheel from its omega and
  writes the mesh orientation each frame (car basis × steering × spin),
  overriding Godot's ground-speed cosmetic rotation.

## Config additions

`axle_inertia` (kg·m², ~1.5), `tire_slip_peak` (m/s, ~1.5),
`sliding_grip_ratio` (0–1, ~0.7), `brake_torque` (N·m), `handbrake_torque`
(N·m), `engine_braking` (N·m), `wheel_spoke_color`. Removed: `brake_force`.

## Controls

New input action `handbrake` = Space (physical keycode 32).

## Tests

New (in `tests/headless/`):
- Launch wheelspin: full throttle from rest → `rear_omega * r` far exceeds
  car speed initially.
- Brake lockup: braking hard at speed → omegas reach ~0 while the car still
  moves.
- Handbrake slide: driving in a curve, pulling handbrake → yaw rate rises /
  rear slip becomes dominantly lateral.
- Slope holding: parked on the spawn slope → longitudinal creep ~0.
Existing suite continues to guard: forward drive, power-capped top speed,
castering, alignment blend at 0, powerslide drive, reset, settle, border,
config application. Visual golden regenerated for the spoked wheels.

## Risks

- Handling feel changes even at zero slip (lateral force now ours end to
  end) — expect a tuning pass on `tire_slip_peak` and the μ sliders.
- Low-speed slip oscillation — mitigated by the demand cap; settle tests
  guard it.
- Wheel mesh orientation fighting `VehicleWheel3D`'s auto-rotation — solved
  by writing mesh global orientation after physics each frame.
