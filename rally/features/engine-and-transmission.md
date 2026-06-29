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
crank    = throttle × peak_torque × global_torque_scale × _torque_fraction(rpm) − friction
```

`global_torque_scale` (shipped at **0.5**) is a **hidden** global de-rate on the
drive torque every car makes. It scales acceleration for the whole field at once
without changing the published `peak_torque`, so the stats panel and
`power_to_weight` still report the full, pre-scaling figure — it's a balance knob
for overall pace, not a per-car spec. `1.0` disables it.

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

- Forward gears (`gear_ratios`), one reverse (`reverse_ratio`), and a
  `final_drive` multiplier. `EngineSim` handles ANY number of forward gears, so
  the gear COUNT can vary per car (the field is per-car, see below).
- Clutch limited to `clutch_max_torque`; auto-clutch opens when coasting below
  `clutch_engage_speed`.
- Manual shifting: Q (down) / E (up). Auto mode toggled with T or HUD button.
- `shift_time` (clutch-open throttle cut per gear change) is **per-car**: each
  `CarLibrary` entry carries its own value, applied by `Car.apply_car()`, so the
  manual MX-5 shifts slowly (0.30 s) while dual-clutch / automated supercars
  (911, RS3, Aventador) snap through gears (0.05–0.08 s). The `GameConfig`
  default (0.25 s) is just the baseline before a car is selected.
- **`gear_ratios` + `final_drive` are also per-car** (`CarLibrary`, applied by
  `Car.apply_car()` after the engine preset), but **every car currently shares the
  MX-5's box** — its real ND 6-speed ratios with the game-tuned `3.5` final drive.
  Each car briefly ran its own *real* transmission (MX-5 manual, Mustang MT82, LFA
  ASG, RS3 DSG, Aventador ISR, 911 PDK), but only the MX-5's made sense in-sim, so
  the roster is modelled on the MX-5's gearing again; the field stays per-car so a
  car can diverge later. See [drivetrain-and-tires.md](drivetrain-and-tires.md) for
  why this box drives well and why the MX-5's `final_drive` is game-tuned (not its
  real 2.866) — its ~150 hp can't pull the tall real ratio against the physics
  engine's built-in rolling resistance. The `GameConfig` `gear_ratios`/`final_drive`
  are only the baseline before a car is selected.

## Tests

`tests/headless/test_engine.gd` (idle, redline, limiter bounce, shift, stall
resistance), `tests/headless/test_engine_type.gd` (all 7 presets load).

## Related config

`engine_type`, `idle_rpm`, `rev_limiter_band`, `engine_friction_base`,
`engine_friction_slope`, `gear_ratios`, `reverse_ratio`, `final_drive`,
`clutch_max_torque`, `clutch_engage_speed`, `auto_gearbox`,
`upshift_redline_fraction`.
