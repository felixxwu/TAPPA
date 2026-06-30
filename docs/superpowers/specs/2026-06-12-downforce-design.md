# Front/Rear Downforce — Design

Date: 2026-06-12
Status: approved pending user review

## Goal

Add aerodynamic downforce to the car, with independent front and rear
strength, each tunable via an Inspector slider on `config/game_config.tres`.
No in-game UI.

## Physics model

Speed-squared aero force, matching the existing `drag_coefficient` style:

- `force = v² * coefficient`, where `v` is the car's speed (m/s) and the
  coefficient is in N per (m/s)².
- Applied along the car body's `-basis.y` (pushes the chassis down), at two
  application points: the front axle midpoint and the rear axle midpoint.
- The force compresses the suspension; wheel normal force and therefore tire
  grip rise through the existing `Drivetrain.wheel_normal_force` path. No
  tire-model changes. The car visibly squats at speed — accepted/desired.

## Components

### `scripts/game_config.gd` (+ `config/game_config.tres`)

Two new properties in the `Car` export group, next to `drag_coefficient`:

```gdscript
@export_range(0.0, 2.0) var downforce_front := 0.0  # N per (m/s)² at the front axle
@export_range(0.0, 2.0) var downforce_rear := 0.0   # N per (m/s)² at the rear axle
```

Defaults are 0.0 so existing behavior, tuning, and tests are unchanged out of
the box. For scale: 0.2 adds ≈125 N (~half the 120 kg car's weight) at
25 m/s. Both values are added to `config/game_config.tres`.

### `scripts/car.gd`

- In `_ready`: compute and store the front and rear axle midpoints in car-local
  space by averaging the rest positions of the wheels in each group. Wheels are
  classified the same way the drivetrain does: `use_as_traction` → rear,
  otherwise front.
- In `_physics_process`, next to the existing quadratic drag: compute
  `v² = linear_velocity.length_squared()` once, then

```gdscript
apply_force(-global_transform.basis.y * v2 * cfg.downforce_front,
        global_transform.basis * _front_axle_midpoint)
apply_force(-global_transform.basis.y * v2 * cfg.downforce_rear,
        global_transform.basis * _rear_axle_midpoint)
```

(Force offsets are relative to the car's global position, per
`RigidBody3D.apply_force` semantics — the basis-rotated local midpoint is
exactly that offset.)

## Testing

All in `tests/headless/`:

- **Config applied** (`test_config_applied.gd`): the two new fields exist on
  `GameConfig` and load from `game_config.tres`.
- **Gameplay** (`test_car.gd`):
  - With `downforce_rear` set and the car moving at speed, rear wheel normal
    forces exceed the zero-downforce baseline; fronts are (approximately)
    unaffected. Mirror check for `downforce_front`.
  - Regression: with both coefficients 0, stationary wheel normal forces match
    current behavior.

Run `./run_tests.sh` (full suite, including visual) before declaring done. No
golden regeneration expected: defaults are 0, so the rendered look is
unchanged.

## Debug arrows (added 2026-06-12, user request)

The `WheelForceDebug` overlay (toggled with H) also draws the two applied
downforce vectors in blue, one per axle. `car.gd` publishes the global
application point and force vector each tick (`downforce_readouts`), mirroring
how the drivetrain publishes `readouts`; the overlay just draws them. Zero
force at standstill means no visible arrow (arrows under 1 cm are skipped).
Tested in `tests/headless/test_debug_arrows.gd`: arrow vertex count grows when
downforce is active at speed versus at rest.

## Out of scope

- In-game/runtime slider UI.
- Drag changes, ride-height-dependent aero, or any tire-model changes.
