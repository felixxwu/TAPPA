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
- `step(h, throttle_in, driveline_omega, declutch := false)` — integrate
  flywheel; return clutch torque delivered to the wheels. `declutch` (the
  drivetrain passes `handbrake`) forces the clutch fully open, like neutral, so
  the engine revs freely against the throttle while the handbrake locks the
  driven axle — and delivers no wheel torque.
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

A turbo (stock, or fitted via the `turbo_small`/`turbo_large` upgrade) further
multiplies the throttle torque term by `(1 + boost × turbo_boost_gain)`,
reshaping the delivered curve without altering `_torque_fraction` or the
published `peak_torque` figure itself — see
[forced-induction.md](forced-induction.md) for the inertia-based boost model.

`global_torque_scale` (shipped at **0.5**) is a **hidden** global de-rate on the
drive torque every car makes. It scales acceleration for the whole field at once
without changing the published `peak_torque`, so the stats panel and
`power_to_weight` still report the full, pre-scaling figure — it's a balance knob
for overall pace, not a per-car spec. `1.0` disables it. The frozen test fixture
(`tests/fixtures/test_config.tres`) pins it to `1.0` on purpose, so the
drive-mode launch tests stay calibrated to full torque and don't drift when the
shipped de-rate is retuned.

Off throttle (and during fuel-cut/shifts) the gross term is zero, so `crank`
is just `−friction` — that is the **engine braking**, and because friction
rises with revs the braking is stronger at high RPM (and bounces the revs off
the limiter). The no-stall idle clamp still holds the bottom. Defaults
(`engine_friction_base = 10`, `engine_friction_slope = 4`) give ≈28 N·m of
drag at the 4500-rpm peak and ≈42 N·m at 8000 rpm.

`peak_torque`, `peak_torque_rpm`, `redline_rpm`, `cylinders`, and
`firing_angles` all come from the fielded car's referenced **engine** in
`EngineLibrary` (`scripts/engine_library.gd`, `const ENGINES`) — see
[configuration.md](configuration.md). Each `CarLibrary` entry carries an
`"engine": "<engine_id>"` key; `car.gd`'s `apply_car()` resolves it
(`EngineLibrary.by_id`) and writes the whole profile onto `GameConfig` via
`EngineLibrary.apply()`. Each `EngineLibrary` entry also carries a **`mass`**
(kg), used by [engine-swap.md](engine-swap.md) to treat the engine as an
independent point mass when a player exchanges engines between cars. Which
engine a car is actually running is resolved via
`EngineSwap.current_engine_id(owned, stock_id)` — the car's `swapped_engine`
if a swap is in effect, else its `CarLibrary` stock `engine` id; `car.gd`'s
`_apply_engine_swap()` re-applies `EngineLibrary.apply()` for the swapped-in
engine on top of the stock baseline when the two differ. `peak_torque_rpm` is per-engine (not a fixed 4500 for
every car) — e.g. the Charger's `mopar_440_v8` peaks at 3000 rpm while its real
~5500 redline still sits comfortably above that. Layout (`i3`/`i4`/`i5`/`i6`/
`v6`/`v8`/`v10`/`v12`) fixes both the cylinder count and the firing table
(`EngineLibrary.FIRING`) together.

## Transmission

- Forward gears (`gear_ratios`), one reverse (`reverse_ratio`), and a
  `final_drive` multiplier. `EngineSim` handles ANY number of forward gears, so
  the gear COUNT can vary. **The transmission lives on the ENGINE**
  (`EngineLibrary`: `gear_ratios` / `final_drive` / `shift_time`), not the car —
  `EngineLibrary.apply` writes all three onto the config. Because of this, an
  **engine swap carries its gearbox** to the new car
  ([engine-swap.md](engine-swap.md)); a car's stock gearbox is just its stock
  engine's.
- Clutch limited to `clutch_max_torque`; auto-clutch opens when coasting below
  `clutch_engage_speed`.
- Manual shifting: Q (down) / E (up). Auto mode toggled with T or HUD button.
- `shift_time` (clutch-open throttle cut per gear change) is **per-engine**: the
  manual MX-5's i4 shifts slowly (0.30 s) while dual-clutch / automated boxes
  (the 2.5T i5's 7-speed S tronic) snap through gears (~0.08 s). The `GameConfig`
  default (0.25 s) is just the baseline before a car is selected.
- **`engine_inertia` (crank + flywheel rotating inertia, kg·m²) is per-car**
  (`CarLibrary`, applied by `Car.apply_car()`). Small = fast revving, large =
  a heavy, lazy flywheel. Anchored to the MX-5's light 2.0 i4 (`0.15`) and
  scaled by each car's real rotating character: the tiny Acty i3 sits lowest
  (`0.09`, near-instant revs), while the big pushrod V10 Viper (`0.35`), the
  heavy V8 Charger (`0.56`) and the vast Merlin V12 (`1.5`) carry the most
  spinning mass and rev slowest. Cars that omit it keep the `GameConfig`
  fallback.
- **`gear_ratios` + `final_drive` are also per-car** (`CarLibrary`, applied by
  `Car.apply_car()` after the engine is resolved), and **each car now carries its
  own real published transmission** — e.g. the Charger runs a 3-speed TorqueFlite
  A727 (`2.45 / 1.45 / 1.00`), the 911 Turbo its classic 4-speed, the Focus ST a Getrag M66
  6-speed, the Acty its real HA4 5-speed. Only `final_drive` remains a
  game-tuned value, kept deliberately HIGH (mostly ~6–7, but tuned per car
  across a wider band — e.g. 4 on the torquey Charger up to 12 on the Focus ST)
  so the
  cars pull against Jolt's built-in rolling resistance rather than stalling
  against a tall real final drive; the internal gear ratios themselves are real.
  See [drivetrain-and-tires.md](drivetrain-and-tires.md) for why the baseline
  rolling resistance forces `final_drive` this high. The `GameConfig`
  `gear_ratios`/`final_drive` are only the baseline before a car is selected.

## Tests

`tests/headless/test_engine.gd` (idle, redline, limiter bounce, shift, stall
resistance), `tests/headless/test_engine_library.gd` (every catalog entry
loads and `apply()` writes the expected fields), `tests/headless/test_engine_logic.gd`.

## Related config

`idle_rpm`, `rev_limiter_band`, `engine_friction_base`,
`engine_friction_slope`, `gear_ratios`, `reverse_ratio`, `final_drive`,
`clutch_max_torque`, `clutch_engage_speed`, `auto_gearbox`,
`upshift_redline_fraction`. Engine catalog: `scripts/engine_library.gd`
(`EngineLibrary`).
