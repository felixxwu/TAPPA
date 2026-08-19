# Engine & Transmission

**Source:** `scripts/engine.gd` (`class_name EngineSim extends RefCounted`).
Owned by `Drivetrain`; stepped each physics substep.

**Tests:** `tests/headless/test_engine.gd`, `tests/headless/test_engine_logic.gd`

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
| `rev_limit_scale` | fraction of the config redline this engine may rev to (damage rev cap; 1.0 = healthy) |
| `shift_up_speeds` | precomputed upshift airspeed per gear |

## Key functions

- `_init()` — omega = idle, `auto` from config, compute shift speeds.
- `idle_omega()` / `rpm()` — unit conversions.
- `redline_omega()` — **the** redline every consumer reads (see *Damage rev cap*
  below): `config.redline_rpm × rev_limit_scale`, floored at
  `idle_omega() × MIN_REDLINE_IDLE_RATIO`.
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
- `_update_limiter(cfg)` — latch fuel cut ON at `redline_omega()`, OFF below
  it − `rev_limiter_band` (the "bounce").
- `_torque_fraction(at_rpm)` — torque curve (below).
- `_compute_shift_speeds()` — upshift airspeed per gear =
  `redline_omega()` × `upshift_redline_fraction`.

## Damage rev cap

A damaged engine is **rev-capped as well as misfiring** — that is the lasting
cost of a crash (see [damage.md](damage.md)): each gear runs out early and the
car is slower everywhere, for the rest of the rally.

- `rev_limit_scale` (0.05..1.0) is written **every physics tick by `car.gd`**
  from `DamageModel.rev_limit_fraction(cfg)`. It is a setter, not a plain field:
  on an actual change it calls `_compute_shift_speeds()`, so the automatic
  gearbox's upshift airspeeds follow the redline **down**. Without that the box
  would hold a gear the engine can no longer pull to and just sit bouncing off
  the lowered limiter.
- `redline_omega()` is the single scaled redline, and **every** consumer reads it
  rather than `config.redline_rpm`: the rev limiter (`_update_limiter`), the
  clutch-engagement gate (`absf(input_omega) < redline_omega() * 1.05`), the
  crank clamp (`omega = clampf(omega, idle_omega(), redline_omega() * 1.02)`),
  and `_compute_shift_speeds()`. Lower the cap and they all move together.
- `MIN_REDLINE_IDLE_RATIO` (1.5) floors the capped redline at that multiple of
  idle, so even a maximally damaged engine keeps a usable rev range instead of
  sitting on its idle clamp — it can still rev, pull away and change gear.
- The torque **curve** is untouched: `_torque_fraction` still keys off
  `config.redline_rpm`, so the engine's real curve is unchanged — the limiter
  just stops you earlier.

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

Forced induction (stock, or fitted via the `turbo_small` / `turbo_large` /
`supercharger` upgrades, which share one slot) further multiplies the throttle
torque term — by `(1 + boost × turbo_boost_gain)` for a turbo, or
`(1 + sc_boost × supercharger_boost_gain)` for a blower — reshaping the
delivered curve without altering `_torque_fraction` or the published
`peak_torque` figure itself. See [forced-induction.md](forced-induction.md) for
the turbo's inertia-based boost model and the supercharger's stateless,
rpm-linear belt drive.

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
the limiter). The no-stall idle clamp still holds the bottom.

### Coasting vs. fuel cut vs. mid-shift — three states, one drag term

`step()` names three DISTINCT conditions, and confusing them is the classic bug
here (`engine.gd` → `is_lifting_off`, the `lifting_off` / `combusting` locals):

| Question | Where it's answered | Means |
|---|---|---|
| "has the driver lifted off?" | `EngineSim.is_lifting_off(throttle)` / the `lifting_off` local | **throttle position only** — coasting, engine braking, lift-off feel |
| "is combustion suppressed?" | the `fuel_cut` field | rev limiter **or** damage misfire — usually with the throttle still wide open |
| "is the engine making torque?" | the `combusting` local | pedal down **and** not mid-shift **and** not fuel-cut |

`not combusting` is **not** "the driver lifted off": it is also true mid-gearchange
(`shift_timer > 0`) and under a fuel cut. Work on lift-off/coasting feel must gate
on `is_lifting_off`, never on `not combusting`, or it silently retunes gearchanges
and the rev limiter as well.

The `friction` term above has **two customers**: it is both the coasting engine
braking and the only thing that pulls the revs back down through the limiter's
hysteresis band in `_update_limiter` (which cuts fuel at full throttle). Scaling
it, or bolting a lift-off multiplier onto it, changes limiter bounce too — a
lift-off-only change belongs behind `lifting_off`, applied where it cannot reach
the cut path. `test_engine_logic.gd` guards this:
`test_limiter_bounce_depends_on_fuel_cut_friction` (the cut must still release),
`test_coasting_and_fuel_cut_share_one_friction_term` (both decelerate alike), and
`test_is_lifting_off_is_throttle_position_only`.

`engine_friction_base` is **per-engine**, authored in `EngineLibrary` and written
onto the config by `apply()` (see below): it scales vaguely with cylinder count /
displacement, so a big-block V8 or the 27 L Merlin carries far more parasitic drag
than a 0.66 L kei triple. A single global term couldn't serve both ends — enough
friction to give the big engines authority stalled the tiny ones (the kei Acty
couldn't pull away). The GameConfig `engine_friction_base` (**20**) is now only a
**fallback** for the baseline car before an engine is fielded (or a synthetic engine
dict that omits the field). The rpm-dependent `engine_friction_slope` (**1.0**,
the script default — it is not overridden in `config/game_config.tres`) stays
global. As a feel anchor, a 3.0 L flat-6 (`engine_friction_base = 30`) gives ≈34 N·m
of drag at its 4000-rpm peak (30 + 1.0 × 4).

`peak_torque`, `peak_torque_rpm`, `redline_rpm`, `cylinders`, and
`firing_angles` all come from the fielded car's referenced **engine** in
`EngineLibrary` (`scripts/engine_library.gd`, `const ENGINES`) — see
[configuration.md](configuration.md). Each `CarLibrary` entry carries an
`"engine": "<engine_id>"` key; `car.gd`'s `apply_car()` resolves it
(`EngineLibrary.by_id`) and writes the whole profile onto `GameConfig` via
`EngineLibrary.apply()`. Each `EngineLibrary` entry also carries a **`mass`**
(kg), used by [engine-swap.md](engine-swap.md) to treat the engine as an
independent point mass when a player exchanges engines between cars. Displayed
power / power-to-weight are **derived** from the same torque + redline
(`CarLibrary.power_to_weight`: torque × redline speed ×
`CarLibrary.TORQUE_POWER_FALLOFF`, a single global ~0.78 calibration for real
torque falloff before redline) — there is no separately-authored power figure,
so retuning an engine's torque moves its stats and its physics together, and
the derived figures land within ~±8% of the cars' real published power. Which
engine a car is actually running is resolved via
`EngineSwap.current_engine_id(owned, stock_id)` — the car's `swapped_engine`
if a swap is in effect, else its `CarLibrary` stock `engine` id; `car.gd`'s
`_apply_engine_swap()` re-applies `EngineLibrary.apply()` for the swapped-in
engine on top of the stock baseline when the two differ. `peak_torque_rpm` is per-engine (not a fixed 4500 for
every car) — e.g. the Charger's `mopar_440_v8` peaks at 3000 rpm while its real
~5500 redline still sits comfortably above that. Layout (`i3`/`i4`/`i5`/`i6`/
`v6`/`v8`/`v10`/`v12`) fixes both the cylinder count and the firing table
(`EngineLibrary.FIRING`) together.

### Displacement, cylinders and doors (rally-restriction metadata)

Three catalogue fields exist purely so rally restrictions can theme a class by
body/engine shape ([rally-roster.md](rally-roster.md)). Which catalogue owns each
is decided by **what an engine swap must change**:

- **`displacement_l`** (float, litres) lives on the **engine** (`ENGINES`). It is an
  engine property, so a swap carries it — a car dict field would go stale the moment
  the car was re-powered.
- **cylinder count is NOT authored at all.** `EngineLibrary.cylinders(engine)` derives
  it from `FIRING[layout].size()`, the same table that drives the audio, so the two
  can never disagree. Returns `0` for an unknown/absent layout.
- **`doors`** (int) lives on the **car** (`CARS`) — a body property no engine can
  change. It uses the conventional body designation (a hatchback's tailgate counts:
  3-door hatch = 3, coupe/roadster/kei van = 2, 5-door hatch = 5).

`RallyLibrary.ineligibility_reason` reads `doors` flat off the car meta but resolves
the engine-derived pair through `EngineLibrary.by_id(car_meta["engine"])` — and
`UpgradeLibrary.effective_meta` re-points that key at the **fitted** engine, so
**swapping an engine changes which rallies a car can enter**. If a restriction names
an engine-derived field and the engine id doesn't resolve (a synthetic dict in a test
or tool), the car is **rejected** ("Unknown engine for this class") rather than waved
through — the failure mode of the old dead `engine_displacement_l` key, which nothing
ever wrote, so every `engine_min_l` gate rejected everything and every `engine_max_l`
gate accepted everything.

## Transmission

- Forward gears (`gear_ratios`), one reverse (`reverse_ratio`), and a
  `final_drive` multiplier. `EngineSim` handles ANY number of forward gears, so
  the gear COUNT can vary. **The transmission lives on the ENGINE**
  (`EngineLibrary`: `gear_ratios` / `final_drive` / `shift_time`), not the car —
  `EngineLibrary.apply` writes all three onto the config. Because of this, an
  **engine swap carries its gearbox** to the new car
  ([engine-swap.md](engine-swap.md)); a car's stock gearbox is just its stock
  engine's.
- **The ratios now leave the live sim and reach the offline solver too.**
  `LapTimeModel._geared_top_speed_sq` computes a car's geared top speed as
  `omega_redline * wheel_radius / (top_ratio * final_drive)` — the same crank →
  axle chain `Drivetrain` gears through — and `optimum_profile` folds it in as a
  speed ceiling, so gearing now moves PAR times, rival times and the car
  performance rating ([car-performance.md](car-performance.md)). It reads
  `gear_ratios` / `final_drive` off the **ENGINE**, matching the "the transmission
  lives on the engine" rule above, which is what makes an engine swap correctly
  move a car's top speed; `wheel_radius` comes off the car. Top gear is taken as
  the **smallest** ratio rather than the last entry, so a mis-authored list can't
  hand a car a first-gear top speed. Keep the distinction sharp in the other
  direction, though: only the top ratio is modelled. The intermediate ratios and
  `shift_time` are still invisible to the solver — nothing charges a car for the
  time lost to an upshift, so a close-ratio box gets no credit offline even
  though it is a real advantage in the live sim.
- Clutch limited to `clutch_max_torque`; auto-clutch opens when coasting below
  `clutch_engage_speed`.
- Manual shifting: Q (down) / E (up). Auto mode toggled with T or HUD button.
- `shift_time` (clutch-open throttle cut per gear change) is **per-engine**: the
  manual MX-5's i4 shifts slowly (0.30 s) while dual-clutch / automated boxes
  (the 2.5T i5's 7-speed S tronic) snap through gears (~0.08 s). The `GameConfig`
  default (0.25 s) is just the baseline before a car is selected.
  **`shift_time` is upgradeable**: the `gearbox` upgrade slot holds the **Sequential
  Gearbox** (`sequential_gearbox`), whose `shift_time_set` effect **replaces** whatever the
  fitted engine authors with its own absolute figure, in pipeline step 2. Because the
  baseline is per-engine and the kit's figure is not, fitting it makes a car with an
  already-quicker gearbox **slower** — the S tronic (0.08 s) is the only one on the shipped
  roster; the 0.22–0.35 s manuals all gain. That is accepted: fitting is the player's choice
  and nothing auto-fits it. `EngineSim` reads `config.shift_time` live at each shift, so
  fitting or unfitting the kit needs no drivetrain rebuild. See
  [upgrade-catalogue.md](upgrade-catalogue.md).
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
  A727 (`2.45 / 1.45 / 1.00`), the 911 Turbo its classic 4-speed, the Focus an MTX-75
  5-speed, the Acty its real HA4 5-speed. Only `final_drive` remains a
  game-tuned value, kept deliberately HIGH (mostly ~6–7, but tuned per car
  across a wider band — e.g. 4 on the torquey Charger up to 12 on the Audi TFSI i5)
  so the
  cars pull against Jolt's built-in rolling resistance rather than stalling
  against a tall real final drive; the internal gear ratios themselves are real.
  See [drivetrain-and-tires.md](drivetrain-and-tires.md) for why the baseline
  rolling resistance forces `final_drive` this high. The `GameConfig`
  `gear_ratios`/`final_drive` are only the baseline before a car is selected.
- **A LONG final drive is now a real design lever, not just a feel one.** Since the
  lap model caps a car at its geared top speed
  (`LapTimeModel._geared_top_speed_sq`), `final_drive` moves the car's PACE and its
  performance rating, not only how it pulls. The Beast is the case that made this
  visible: a 27-litre V12 redlining at ~3.2k through three widely-spaced ratios on a
  short diff was geared so low it ran out of revs at motorway speed, and the rating
  dutifully pinned it there. Its diff is now deliberately the longest on the roster —
  it has torque to spare from idle, so trading multiplication for reach costs it
  nothing it misses. Read `final_drive` as "how much of this engine's output is
  spent on acceleration versus top end", and expect the rating to follow.

## Tests

`tests/headless/test_engine.gd` (idle, redline, limiter bounce, shift, stall
resistance), `tests/headless/test_engine_library.gd` (every catalog entry
loads and `apply()` writes the expected fields), `tests/headless/test_engine_logic.gd`.

## Related config

`idle_rpm`, `rev_limiter_band`, `engine_friction_base`,
`engine_friction_slope`, `gear_ratios`, `reverse_ratio`, `final_drive`,
`clutch_max_torque`, `clutch_engage_speed`, `auto_gearbox`,
`upshift_redline_fraction`, `damage_rev_limit_min_fraction` (the damage rev cap's
floor). Note `engine_friction_base` / `engine_friction_slope` are **shared** by
coasting engine braking and the rev limiter's pull-down (see "Coasting vs. fuel
cut vs. mid-shift" above) — retuning them moves limiter bounce as well as
off-throttle feel. Engine catalog: `scripts/engine_library.gd`
(`EngineLibrary`).
