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
  the debug overlays: `normal`, `demand`, `applied`, and `grip` — how far up its grip
  curve the tire is, slip over `slip_peak` via the pure static `grip_fraction`, which
  the HUD's 2x2 grip grid reads; see [debug-tools.md](debug-tools.md)).
- Exposes `front_axle_state()` — the steering axle's slip state as ONE load-weighted set of
  numbers (`slip_angle`, `slip_lat`, `slip_long`, `slip_peak`, `v_long`, `in_contact`),
  weighted by each front wheel's normal force so the loaded outer tire dominates. This is what
  the grip-servo steering closes its loop on ([car-physics.md](car-physics.md) → Steering).
  Deliberately NOT sourced from `readouts`, which is gated on `publish_readouts` (the debug
  overlay's visibility) — steering needs these numbers every tick in every build. Both read
  the same `WheelContact` fields, so the debug grid and the servo cannot disagree.
- `front_axle_driven()` — whether the steered axle is also driven (FWD/AWD, not RWD), i.e.
  whether throttle and steering compete for the same tires' grip. Used by the
  longitudinal-demand arbitration.
- **Live per-wheel tire state** — `wheel_force_n(wheel)`, `wheel_grip_usage(wheel)`,
  `wheel_long_grip_usage(wheel)` (see below).

## Live per-wheel tire state

What each tire is doing *right now*, for the surface effects — tire-mark opacity
([tire-marks.md](tire-marks.md)) and the debris gate ([wheel-dust.md](wheel-dust.md)):

| Accessor | Reads | Used for |
|---|---|---|
| `wheel_force_n` | magnitude of the combined long+lat force applied this tick, in **N** (`WheelContact.force_n`) | gravel rut opacity — shear work, not proximity to the limit |
| `wheel_grip_usage` | `slip_use`, how far up the grip curve (1.0 = on the limit) | tarmac skid opacity — the tire giving up |
| `wheel_long_grip_usage` | `grip_fraction(abs(slip_long_norm), slip_peak)` — the slip ratio over the peak ratio, **unsigned** and NOT ellipse-weighted | the debris gate: has this tire broken traction fore/aft (spinning up, or locked)? |
| `drive_wheelspin_excess` | the **max** of `wheel_long_grip_usage - 1` over the **driven** wheels, floored at 0 | the camera-shake wheelspin term ([camera.md](camera.md)). Max, not load-weighted: one wheel lighting up is felt as a judder, and weighting would hide an unloaded inside wheel spinning freely. Gated on `is_wheel_driven`, so a locked undriven wheel under braking is not mistaken for wheelspin — braking reaches the camera through the g-force term instead |

Same contract as `front_axle_state`, and for the same reason: these read the pooled
`WheelContact` directly, **not** the `readouts` dict, which only exists while
`publish_readouts` (the debug overlay's visibility) is on — the effects need these
numbers in every build. Both sides read the same fields, so the HUD grip grid and what
the marks/particles do cannot disagree; `force_n` is literally the magnitude of the
vector the overlay publishes as `applied`.

The contact pool is persistent (one `WheelContact` per wheel for the drivetrain's life),
so `step()` clears `live`/`force_n` on every pooled contact **before** any early-out.
Without that a wheel that goes airborne would keep serving the last tick it was loaded,
and a jumping car would go on laying marks and throwing dirt in mid-air. All three
accessors return `0.0` for a wheel with no live contact — the value that reads as "no
effect" at every call site.

## Main entry: `step(delta, throttle, brake, handbrake)`

1. Build a contact context for each in-contact wheel: normal force, contact
   velocity, slip.
2. Integrate spin over **8 substeps** (`SPIN_SUBSTEPS`) for stability:
   - Compute tire force from slip + grip curve (`_tire_force`).
   - Accumulate force impulse; react on wheel spin states.
   - `engine.step()` supplies drive/brake torque. A damaged engine cuts this
     torque in stumbling bursts via the **misfire** (`engine.misfire_level`, set
     each tick by `car.gd` from the damage fraction; see [damage.md](damage.md)).
   - Couple wheels per `drive_mode`.
3. Apply the time-averaged tire force to the chassis.

## Tire force model

- `_tire_force(contact, surface_vel, h)` — combined-slip force from the grip
  curve, capped for stability. Longitudinal slip velocity = (wheel surface speed
  − ground speed) along rolling dir; lateral slip velocity = transverse contact
  velocity. Long slip is weighted to approximate a traction ellipse.
- **Slip is normalized before the curve.** Both slip velocities are divided by
  the patch's planar ground speed `v_ref = max(√(v_long² + s_lat²), tire_norm_floor)`,
  turning them into dimensionless slip: lateral → `sin(slip angle)`, longitudinal
  → slip ratio `Δv/v`. So grip peaks at a constant slip **angle**/ **ratio**,
  not a constant slip **speed** — a real tyre peaks at ~a fixed angle regardless
  of speed. The `tire_norm_floor` floor avoids dividing by ~0 at creep (a
  stationary tyre has no defined slip angle); the stability caps still key off
  the RAW velocities, so the standstill guarantee is unchanged.
- `_grip_curve(slip_peak, slide_ratio, s)` (s is the combined normalized slip):
  - `s ≤ slip_peak`: grip rises linearly 0 → 1.
  - `s > slip_peak`: grip rolls off 1.0 → `slide_ratio` over ~3× peak.
- **The curve shape is surface-dependent.** `slip_peak` (optimum-slip location)
  and `slide_ratio` (post-peak plateau) are resolved *per contact* from the
  terrain by `surface_tire_params(cp)` — one `surface_at` query, blended across
  the same feathered grass↔road / gravel↔tarmac bands as μ, and stashed in the
  contact. Rubber on hard **tarmac** peaks at a low slip angle then drops off
  sharply (`tarmac_slip_peak ≈ 0.14 ≈ sin(8°)`, `tarmac_slide_ratio ≈ 0.6`);
  loose **gravel/grass** shear a wedge of material and peak at a much larger
  angle with a broad, forgiving plateau (`gravel_slip_peak ≈ 0.31 ≈ sin(18°)`,
  `gravel_slide_ratio ≈ 0.85`) — which is why rally is driven sideways. Off
  terrain (flat fixtures) the shape falls back to the global `tire_slip_peak` /
  `sliding_grip_ratio`. `surface_grip(cp)` is now a thin wrapper returning the
  same query's μ multiplier.
- Peak grip scaled by `wheel_friction_slip_front` / `_rear` (μ), then by a
  **per-wheel surface multiplier** (`surface_grip`), then by a **per-wheel
  load-sensitivity factor** (`GameConfig.tire_load_factor`, see below).

### Compound, width and load sensitivity

A car authors **one `tire_compound`** (the rubber's intrinsic μ, ~0.85 hard economy
→ ~1.30 track) plus **`wheel_width_front` / `wheel_width_rear`** (real section widths).
`car.gd:apply_car` seeds BOTH `wheel_friction_slip_front/rear` from the single compound
(the `grip_balance` tuning slider then trims them apart) and copies the widths onto the
config.

**The compound is upgradeable.** The `tires` upgrade slot holds two parts — **Snow Tires**
(`snow_tires`, the early rung, won at the Alps gateway pin) and **Race Tires**
(`race_tires`, the top rung, won deep in the Alps) — whose `tire_grip_mult` effect
multiplies **both** axle μ figures in pipeline step 2 — i.e. *after* `apply_car` seeds them and *before* the `grip_balance`
slider shifts them apart, so a player's front/rear balance is scaled, never overwritten.
It gets its own slot rather than sharing `aero` because rubber grip and downforce are not
alternatives: a car wants both, and one-enabled-part-per-slot would have made them
mutually exclusive. See [upgrade-catalogue.md](upgrade-catalogue.md).

Effective μ is **not** the textbook load-independent `μN`. A real tyre's μ falls as the
load pressed through its contact patch rises, and a wider tyre spreads that load over
more rubber. `tire_load_factor(normal_force, width)` models this as
`(tire_ref_pressure / (normal_force/width))^tire_load_sensitivity` — >1 when a tyre is
lightly loaded or wide, <1 when heavily loaded or narrow, 1.0 at the reference pressure.
The exponent (~0.12) keeps it gentle, matching real tyres (a few percent, not a cliff);
set it to 0 to disable the effect.

Because the physics feeds it the **live** suspension `n_force`, weight transfer emerges
for free (braking loads the fronts → their μ dips), and front/rear grip **balance** now
comes from the widths + `weight_front` rather than a per-axle grip knob. Consequences:
**adding mass on the same tyres lowers grip; widening the tyres recovers it** — so both
the lateral-G and the power-to-weight stats are genuinely driven by weight.

The car-select panel shows this as a **lateral-G** figure (`CarLibrary.max_lateral_g`):
each axle's static per-wheel load (`mass·g·weight_split/2`) run through the SAME
`tire_load_factor`, times the compound, averaged over the two axles — so the panel can't
disagree with what the car actually does.

`max_lateral_g(entry, cfg, speed_kmh := 0.0)` takes an optional **speed** so a figure can
be rated **with aero**. At the default `0.0` it returns exactly the static-load number
above, unchanged. Above 0 it adds each axle's downforce (`v² · downforce_front/rear / 2`
per wheel, `v` in m/s) to that axle's load **before** the load-sensitivity factor, and,
since the axles then no longer carry equal shares, returns the **load-weighted**
`Σ(μ·load)/(mass·g)` rather than a plain mean of the two μ. Downforce fields — and the
**race tyres**' multiplier on `tire_compound` — reach the meta via
`UpgradeLibrary.grip_meta` (see [upgrade-catalogue.md](upgrade-catalogue.md)), **not**
`effective_meta`: grip must never move a car's power-to-weight, and therefore never its
rally eligibility. A quoted
speed-rated figure must **always show its speed** — the effect grows with v², so a
speed-dependent grip number without its speed reads as a promise; the Simple upgrades
page's Grip row does exactly that (`GameConfig.grip_reference_kmh`). Note `wheel_width_*` is dual-purpose: it sizes
the wheel meshes AND drives grip, so staggered cars both look and handle staggered.

## Per-wheel surface grip

Each wheel's μ is scaled by the surface under ITS OWN contact point, so the car
can run e.g. two wheels on grass and two on gravel and feel the split. `car.gd`
hands the drivetrain the `Floor` (`drivetrain.terrain`, found as the sibling
exposing `surface_at`; null on the flat test fixtures → multiplier 1.0).
`surface_grip(cfg, cp)` asks `TerrainManager.surface_at(x, z)` for the
`(road_weight, tarmac_weight)` there and blends the configured scales:
`lerp(grass_grip, lerp(gravel_grip, tarmac_grip, tarmac_weight), road_weight)`.
So **gravel = `gravel_grip` (1.0, the baseline)**, **grass = `grass_grip` (0.7)**,
**tarmac = `tarmac_grip` (1.3)**, cross-faded across the same feathered bands the
road colour uses (grass↔road and gravel↔tarmac — see [terrain.md](terrain.md) /
[track.md](track.md)).

**Weather.** `surface_tire_params` multiplies the resolved `mu_mult` by
`WeatherLibrary.grip_mult(cfg, cfg.weather)` — **unconditionally**, because dry
resolves to exactly 1.0, so there is no per-condition `if` in this file at all. A
single global penalty applied on top of whatever surface grip was already blended,
in BOTH branches (terrain-backed and the no-terrain flat-fixture fallback), so a wet
stage is wet everywhere including in test fixtures. The multiplier is memoised
(`_weather_mu`, keyed on the condition string + the config resource) so the
allocation-free per-contact hot path never does a table lookup — it re-resolves only
on a stage transition. `slip_peak` and `slide_ratio` are untouched by weather — this version
ships one global grip multiplier rather than per-surface wet curves (see
[weather.md](weather.md) for the design rationale and the per-surface
alternative it defers).

## Helper functions

- `wheel_normal_force(wheel)` — suspension force: spring×compression −
  damper×velocity.
- `wheel_forward(wheel)` / `wheel_side(wheel)` — rolling and lateral axes in the
  contact plane (includes caster + steering).
- `velocity_at(point)` — linear + angular×offset.
- `driveline_omega()` — effective driven-wheel speed (rear for RWD/AWD, front for
  FWD), fed to the engine.
- `_update_visuals()` — rotates wheel meshes from simulated spin (not Godot's
  ground estimate).

## Drive modes

| Mode | Driven | Free-rolling | Feel |
|------|--------|--------------|------|
| **RWD** (default) | rear spool | fronts (open) | wheelspin-prone, oversteer |
| **FWD** | front spool | rear | understeer bias |
| **AWD** | front+rear locked (no center diff) | — | most grip, least drama |

Drivetrain is no longer switched live. Each car ships with an authored stock
`drive_mode`; a car-bound **Drivetrain Swap** upgrade (a rally reward, `drivetrain`
slot, carrying an `unlocks_drivetrain_swap` flag) unlocks a **FWD / RWD / AWD selector
on that slot's row in the garage upgrades menu** — `UpgradeLibrary.drivetrain_swap_unlocked`
gates it. The chosen mode is stored per car as `OwnedCar.drivetrain_override`
(`-1` = stock) and resolved by `UpgradeLibrary.resolve_drive_override`, which
`car.gd.apply_owned` threads through the drivetrain rebuild (member `_owned_drive_override`,
honoured by `_rebuild_drivetrain`) and `UpgradeLibrary.effective_meta` reports for the
stats panel + rally eligibility. A car with the kit counts as eligible for a
`drive_mode`-restricted rally if it can switch to comply (and it can stack with an
engine detune — see the lineup logic in `hq_carpark.gd`: `_switch_target_for` /
`_qualifying_drivetrain_for` / `_build_eligible_lineup`); entering auto-applies the
switch and `RallySession` reverts it afterward (`register_drivetrain_revert`), mirroring
the engine-detune round-trip. The roster ships two stock **FWD** cars — the **Focus**
(`id: "focus"`) and the **Renault Twingo** (`id: "twingo"`), both home entrants of the
Front Runners rally (see `features/rally-roster.md`); the MX-5/Viper/XJS are RWD; the
Acty is AWD.

**AWD handbrake exception:** AWD is normally one rigid locked driveline, so a
foot-brake lockup takes all four wheels together. The handbrake is the one
exception — while it's held it opens the centre diff, splitting the axles into
two undriven braked spools (engine torque cut for that tick). The rear takes the
handbrake torque and **locks**, while the **front spool free-rolls** and stays
steerable — enabling handbrake rotation in AWD. Releasing the handbrake restores
the rigid locked driveline. (RWD/FWD already brake the rear only.)

**Handbrake opens the clutch:** whenever the handbrake is held (any drive mode),
`step` passes it to `EngineSim.step` as `declutch`, which forces the clutch fully
open like neutral. The engine revs freely against the throttle (handbrake-rev /
flat-shift launch feel) and delivers **no** drive torque to the wheels while the
handbrake locks the driven axle.

## Gearing, top speed & the engine's hidden rolling resistance

Gearing (`gear_ratios` + `final_drive` + `shift_time`) lives on the **engine**
(`EngineLibrary`), written by `EngineLibrary.apply()` (see
[engine-and-transmission.md](engine-and-transmission.md)), so an **engine swap
carries its gearbox** ([engine-swap.md](engine-swap.md)). Each engine
carries its car's real published transmission — e.g. the MX-5's real ND 6-speed
ratios (`5.087 / 2.991 / 2.035 / 1.594 / 1.286 / 1.000`), the Charger's 3-speed
TorqueFlite (`2.45 / 1.45 / 1.00`), the 911 Turbo's classic 4-speed, the Focus's MTX-75
5-speed. Only `final_drive` is a game-tuned value (see below); the internal
ratios are real and differ per car, so gearing character now varies across the
roster instead of every car sharing one box. (An earlier iteration had every
car share the MX-5's box outright, and before that a single fictional shared
gearbox, `[6, 4, 2.9, 2.4, 2.0] × 3.0`, that was far too short — tractive force
= `peak_torque × gear × final_drive ÷ wheel_radius`, so its short ratios
over-multiplied the light cars' torque into violent low/mid-gear acceleration.)

**Important physics caveat:** Jolt's `VehicleBody3D` applies a built-in rolling
resistance of roughly **0.2 g, proportional to mass**, that our model does *not*
control (it persists even coasting in neutral with the wheels rolling freely, and
is independent of `drag_coefficient`). This — not aero drag — is what actually
caps the cars' top speeds, and it is why every car's `final_drive` is kept deliberately HIGH (tuned per car,
mostly ~6–7 but ranging from 4 on the torquey Charger to 12 on the Audi TFSI i5, not
the real ~3–4) — a car needs enough wheel torque multiplication to overcome it.
The **MX-5**, with only ~150 hp, can't pull its *real* tall final drive (2.866)
against the resistance and stalls/crawls, so its `final_drive` is game-tuned to
**7**: short enough to pull cleanly. Its real gear ratios are kept as-is; gears
5–6 sit above its ~95 km/h power-limited top and go unused. Every other car
follows the same pattern — real internal gear ratios, but a final drive raised
above the real value to keep it pulling against the baseline resistance.
Fully neutralising the Jolt resistance (to make real drag + real gearing yield
realistic top speeds game-wide) was considered and deferred as a larger, riskier
change.

Because this baseline resistance already lands the cars near their real top speeds
on its own, the per-car `drag` coefficients are **sized to top it up to the
realistic total, not to be the whole aero force** — so they are deliberately small
(slippery cars like the Viper/XJS sit near zero; only draggy bodies like the
Charger carry a real coefficient). They were tuned by measuring top speed in the
sim; with them the cars top out within a couple of percent of real, except for a
few whose baseline friction caps them a little under their real tops even at
near-zero drag. Setting `drag` to a from-scratch
aerodynamic value here would double-count the resistance and leave every car
10–25 % slow.

## Tests

`tests/headless/test_drivetrain.gd` (wheelspin, brake lockup, handbrake,
parking brake, and the live per-wheel state above: published without the debug
overlay, agreeing with the overlay's `applied`/`grip` when it IS up, and zeroed for
an airborne wheel), `tests/headless/test_drive_mode.gd` (per-mode torque). Gearing
is covered by `tests/headless/test_engine_library.gd` (each engine's transmission:
descending positive ratios, positive final_drive/shift_time) and
`tests/headless/test_car_library.gd` (the engine's ratios overlaid onto the live
config by `apply_car`).

## Related config

`wheel_friction_slip_front/rear`, `grass_grip`, `gravel_grip`, `tarmac_grip`,
`wheel_roll_influence`, `drive_mode`, `suspension_*`, `brake_torque`,
`handbrake_torque`, `gear_ratios`, `final_drive`, `drag_coefficient`.


## Region grip overrides and ice

Two ways the per-surface μ scales can be replaced for a stage, both introduced with the
Alps (see [snow-region.md](snow-region.md)):

- **Per-surface overrides.** A region may override `grass_grip` / `gravel_grip` /
  `tarmac_grip` for every stage tagged to it. `RallySession.apply_event_config` seats the
  values, so `surface_tire_params` needs no change at all — it reads the same live config
  fields it always did, and so does `LapTimeModel`, which is why the rival field scales
  automatically.
- **Ice.** On a stage whose region freezes its water, a contact over a submerged cell
  **overrides** the surface blend with `cfg.frozen_water_grip` rather than scaling it —
  what is under the ice is irrelevant to a tyre resting on top of it. Gated on
  `frozen_water_grip > 0.0`, which is `0.0` everywhere else, so the added cost off a
  frozen stage is one float compare.
