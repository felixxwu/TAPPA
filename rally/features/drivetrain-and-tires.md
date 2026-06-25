# Drivetrain & Tire Model

**Source:** `scripts/drivetrain.gd` (`class_name Drivetrain extends RefCounted`).

Godot's built-in `VehicleWheel3D` friction is **disabled** (friction slip set to
0). All contact forces and wheel-spin integration are computed here, giving a
custom combined-slip tire model and explicit RWD/AWD/FWD behavior.

## Responsibilities

- Owns the `EngineSim` (see [engine-and-transmission.md](engine-and-transmission.md)).
- Classifies wheels into `front_wheels` / `rear_wheels` by `use_as_traction`.
- Tracks per-wheel spin (`front_omega`, `rear_omega`), spin angle, and `Visual`
  nodes for mesh rotation.
- Holds `drive_mode` (RWD / AWD / FWD) and `readouts` (per-wheel force data for
  the debug overlay).

## Main entry: `step(delta, throttle, brake, handbrake)`

1. Build a contact context for each in-contact wheel: normal force, contact
   velocity, slip.
2. Integrate spin over **8 substeps** (`SPIN_SUBSTEPS`) for stability:
   - Compute tire force from slip + grip curve (`_tire_force`).
   - Accumulate force impulse; react on wheel spin states.
   - `engine.step()` supplies drive/brake torque, scaled by `power_scale`
     (set each tick by `car.gd` from the damage model — 1.0 healthy, lower as HP
     falls; see [damage.md](damage.md)).
   - Couple wheels per `drive_mode`.
3. Apply the time-averaged tire force to the chassis.

## Tire force model

- `_tire_force(contact, surface_vel, h)` — combined-slip force from the grip
  curve, capped for stability. Longitudinal slip = (wheel surface speed − ground
  speed) along rolling dir; lateral slip = transverse contact velocity. Long
  slip is weighted to approximate a traction ellipse.
- `_grip_curve(s)`:
  - `s ≤ tire_slip_peak`: grip rises linearly 0 → 1.
  - `s > tire_slip_peak`: grip rolls off 1.0 → `sliding_grip_ratio` over ~3× peak.
- Peak grip scaled by `wheel_friction_slip_front` / `_rear` (μ).

## Helper functions

- `wheel_normal_force(wheel)` — suspension force: spring×compression −
  damper×velocity.
- `wheel_forward(wheel)` / `wheel_side(wheel)` — rolling and lateral axes in the
  contact plane (includes caster + steering).
- `velocity_at(point)` — linear + angular×offset.
- `driveline_omega()` — effective driven-wheel speed (rear for RWD/AWD, front for
  FWD), fed to the engine.
- `cycle_drive_mode()` — RWD → AWD → FWD.
- `_update_visuals()` — rotates wheel meshes from simulated spin (not Godot's
  ground estimate).

## Drive modes

| Mode | Driven | Free-rolling | Feel |
|------|--------|--------------|------|
| **RWD** (default) | rear spool | fronts (open) | wheelspin-prone, oversteer |
| **FWD** | front spool | rear | understeer bias |
| **AWD** | front+rear locked (no center diff) | — | most grip, least drama |

Switch live with **Y** or the HUD drive button.

**AWD handbrake exception:** AWD is normally one rigid locked driveline, so a
foot-brake lockup takes all four wheels together. The handbrake is the one
exception — while it's held it opens the centre diff, splitting the axles into
two undriven braked spools (engine torque cut for that tick). The rear takes the
handbrake torque and **locks**, while the **front spool free-rolls** and stays
steerable — enabling handbrake rotation in AWD. Releasing the handbrake restores
the rigid locked driveline. (RWD/FWD already brake the rear only.)

## Tests

`tests/headless/test_drivetrain.gd` (wheelspin, brake lockup, handbrake,
parking brake), `tests/headless/test_drive_mode.gd` (per-mode torque).

## Related config

`wheel_friction_slip_front/rear`, `wheel_roll_influence`, `drive_mode`,
`suspension_*`, `brake_torque`, `handbrake_torque`.
