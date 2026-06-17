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
3. **Steering:** front wheels caster toward the direction of travel
   (`steer_travel_alignment`), blended with player input up to `steer_limit` at
   `steer_speed`. The alignment fraction is scaled linearly with speed — 0 at
   standstill ramping to its full configured value at `steer_assist_min_speed`
   (≈30 km/h) — so it never snaps in suddenly at low speed. A direct yaw torque
   (`steer_assist_torque`) fights understeer,
   faded in linearly from 0 at standstill to full at `steer_assist_min_speed`
   (≈30 km/h) — rather than switched on abruptly at that threshold — so it ramps
   up smoothly without making low-speed handling twitchy.
4. **Aero forces:**
   - *Drag:* `-velocity * |velocity| * drag_coefficient` (quadratic).
   - *Downforce:* `v² * downforce_{front,rear}` applied at the axle midpoints;
     also recorded in `downforce_readouts` for the debug overlay. Either
     coefficient may be negative, which produces lift (an upward force that
     unloads that axle at speed).
5. **Self-righting assist:** when one or more wheels are off the ground, a
   roll+pitch torque (`level_assist_torque`) eases the chassis back toward
   level. The torque axis is `car_up × world_up` — it lies in the horizontal
   plane (so it never yaws) and its magnitude is `sin(tilt)`, so the correction
   grows the further the car is from flat. Inert once all four wheels plant.
6. **Tire/engine step:** `drivetrain.step(delta, throttle, brake, handbrake)`
   computes and applies all wheel contact forces.

## Suspension

Springs configured from `suspension_stiffness` / `suspension_travel`. Damping is
derived in `GameConfig`: compression = √stiffness (critically damped), rebound =
1.5× compression. Per-wheel normal force is computed in
`Drivetrain.wheel_normal_force()`.

`suspension_travel` doubles as the wheel raycast / rest length, so a shorter
travel also lowers ride height. Both values are **per-car**: each `CarLibrary`
entry carries its own `suspension_travel` + `suspension_stiffness`, overlaid onto
the live config by `car.gd`'s `apply_car()` and pushed onto all four wheels
(dampers re-derived). Soft & tall roadster/muscle (MX-5, Mustang) vs stiff & low
supercars (911, LFA, Aventador). The `config/game_config.tres` values are the
baseline/fallback.

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
`level_assist_torque`, `suspension_*`, `brake_torque`, `handbrake_torque`. See
[configuration.md](configuration.md).
