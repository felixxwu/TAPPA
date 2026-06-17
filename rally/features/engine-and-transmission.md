# Engine & Transmission

**Source:** `scripts/engine.gd` (`class_name EngineSim extends RefCounted`).
Owned by `Drivetrain`; stepped each physics substep.

Models a flywheel + gearbox + clutch: a torque curve over RPM, sequential gear
selection, automatic upshift/downshift, and a bouncing rev limiter.

## State

| Property | Meaning |
|----------|---------|
| `omega` | flywheel speed (rad/s) |
| `gear` | -1 = reverse, 0 = neutral, 1..N = forward |
| `auto` | automatic gearbox mode |
| `shift_timer` | seconds of clutch-open throttle cut during a shift |
| `throttle` | last drive request (0..1), used by audio synth |
| `limiting` | rev-limiter fuel-cut latch |
| `shift_up_speeds` | precomputed upshift airspeed per gear |

## Key functions

- `_init()` — omega = idle, `auto` from config, compute shift speeds.
- `idle_omega()` / `redline_omega()` / `rpm()` — unit conversions.
- `ratio()` — total engine→axle ratio (gear × final drive); 0 in neutral.
- `request_shift(direction)` — sequential ±1 shift if not already shifting.
- `update_auto(throttle_in, airspeed)` — auto up/downshift driven by **ground
  speed**, not revs, so wheelspin doesn't trigger false upshifts. Downshift uses
  a hysteresis dead band to avoid hunting.
- `select_reverse / select_forward` — engage R / 1st from neutral below ~1 m/s.
- `reset()` — back to idle + 1st gear.
- `step(h, throttle_in, driveline_omega)` — integrate flywheel; return clutch
  torque delivered to the wheels.
- `_update_limiter(cfg)` — latch fuel cut ON at redline, OFF below
  redline − `rev_limiter_band` (the "bounce").
- `_torque_fraction(at_rpm)` — torque curve (below).
- `_compute_shift_speeds()` — upshift airspeed per gear =
  redline × `upshift_redline_fraction`.

## Torque curve

```
rpm ≤ peak_torque_rpm        : 70%  → 100%  (linear)
peak_torque_rpm < rpm < redline : 100% → 70%  (linear)
rpm ≥ redline                : 0%   (fuel cut)
```
This curve is the **gross (indicated)** output. An always-on engine-friction
torque is subtracted on every substep, modelled affine in RPM the way FMEP is
fit on real engines (a constant breakaway term plus a slope that grows with
revs):

```
friction = engine_friction_base + engine_friction_slope × rpm / 1000
crank    = throttle × peak_torque × _torque_fraction(rpm) − friction
```

Off throttle (and during fuel-cut/shifts) the gross term is zero, so `crank`
is just `−friction` — that is the **engine braking**, and because friction
rises with revs the braking is stronger at high RPM (and bounces the revs off
the limiter). The no-stall idle clamp still holds the bottom. Defaults
(`engine_friction_base = 10`, `engine_friction_slope = 4`) give ≈28 N·m of
drag at the 4500-rpm peak and ≈42 N·m at 8000 rpm.

`peak_torque`, `peak_torque_rpm`, `redline_rpm`, `cylinders`, and
`firing_angles` all come from the selected **engine preset** (`engine_type`) —
see [configuration.md](configuration.md). Presets: i4, i5, i6, v6, v8, v10, v12.

## Transmission

- 5 forward gears (`gear_ratios`), one reverse (`reverse_ratio`), common
  `final_drive` multiplier.
- Clutch limited to `clutch_max_torque`; auto-clutch opens when coasting below
  `clutch_engage_speed`.
- Manual shifting: Q (down) / E (up). Auto mode toggled with T or HUD button.
- `shift_time` (clutch-open throttle cut per gear change) is **per-car**: each
  `CarLibrary` entry carries its own value, applied by `Car.apply_car()`, so the
  manual MX-5 shifts slowly (0.30 s) while dual-clutch / automated supercars
  (911, RS3, Aventador) snap through gears (0.05–0.08 s). The `GameConfig`
  default (0.25 s) is just the baseline before a car is selected.

## Tests

`tests/headless/test_engine.gd` (idle, redline, limiter bounce, shift, stall
resistance), `tests/headless/test_engine_type.gd` (all 7 presets load).

## Related config

`engine_type`, `idle_rpm`, `rev_limiter_band`, `engine_friction_base`,
`engine_friction_slope`, `gear_ratios`, `reverse_ratio`, `final_drive`,
`clutch_max_torque`, `clutch_engage_speed`, `auto_gearbox`,
`upshift_redline_fraction`.
