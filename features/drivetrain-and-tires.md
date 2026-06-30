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
- Peak grip scaled by `wheel_friction_slip_front` / `_rear` (μ), then by a
  **per-wheel surface multiplier** (`surface_grip`).

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

Switch live with **Y** or the HUD drive button. The roster now ships a stock **FWD**
car — the **Ford Focus RS** (`CarLibrary` `id: "focus"`, the home entrant of the
Front Runners rally, see `features/rally-roster.md`) — so the FWD path is exercised by
a real car, not just the live toggle. The MX-5 is RWD; the RS3/Aventador are AWD.

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

Gearing (`gear_ratios` + `final_drive`) is a **per-car** field in `CarLibrary`,
applied by `Car.apply_car()` (see
[engine-and-transmission.md](engine-and-transmission.md)), but **every car
currently shares the MX-5's box** — its real ND 6-speed ratios (`5.087 / 2.991 /
2.035 / 1.594 / 1.286 / 1.000`) with the game-tuned `3.5` final drive. We briefly
gave each car its own *real published* transmission, but only the MX-5's (already
game-tuned to drive well, below) actually made sense in-sim; the real ratios on
the other cars felt wrong, so the whole roster is modelled on the MX-5's gearing
again. The field stays per-car so a car can be given its own box later. (This had
itself replaced a single shared gearbox, `[6, 4, 2.9, 2.4, 2.0] × 3.0`, that was
far too short — tractive force = `peak_torque × gear × final_drive ÷ wheel_radius`,
so its short ratios over-multiplied the light cars' torque into violent low/mid-gear
acceleration; the MX-5 box spaces the gears out and calms that.)

**Important physics caveat:** Jolt's `VehicleBody3D` applies a built-in rolling
resistance of roughly **0.2 g, proportional to mass**, that our model does *not*
control (it persists even coasting in neutral with the wheels rolling freely, and
is independent of `drag_coefficient`). This — not aero drag — is what actually
caps the cars' top speeds, and it is why the gearing has to stay fairly short
(huge wheel torque is needed to overcome it). The powerful cars have the torque
to push through it on the MX-5's box and reach high gears the MX-5 can't; the
**MX-5 itself** — with only ~150 hp — can't pull its *real* tall final drive
(2.866) against the resistance and stalls/crawls. So the MX-5's `final_drive` is
game-tuned to **3.5**: the shortest drive that still pulls cleanly. Its real ratios
are kept; gears 5–6 sit above its ~95 km/h power-limited top and go unused (the
more powerful cars do use them). This is the box the whole roster now shares.
Fully neutralising the Jolt resistance (to make real drag + real gearing yield
realistic top speeds game-wide) was considered and deferred as a larger, riskier
change.

Because this baseline resistance already lands the cars near their real top speeds
on its own, the per-car `drag` coefficients are **sized to top it up to the
realistic total, not to be the whole aero force** — so they are deliberately small
(slippery cars like the LFA/Aventador sit near zero; only draggy bodies like the
Mustang carry a real coefficient). They were tuned by measuring top speed in the
sim; with them the cars top out within a couple of percent of real, except the
LFA and Aventador, which the baseline friction caps a little under their real tops
(≈306 vs 325, ≈319 vs 350) even at near-zero drag. Setting `drag` to a from-scratch
aerodynamic value here would double-count the resistance and leave every car
10–25 % slow.

## Tests

`tests/headless/test_drivetrain.gd` (wheelspin, brake lockup, handbrake,
parking brake), `tests/headless/test_drive_mode.gd` (per-mode torque). Per-car
gearing is covered by `tests/headless/test_car_library.gd` (descending positive
ratios; every car shares the MX-5's box; overlaid onto the live config by
`apply_car`).

## Related config

`wheel_friction_slip_front/rear`, `grass_grip`, `gravel_grip`, `tarmac_grip`,
`wheel_roll_influence`, `drive_mode`, `suspension_*`, `brake_torque`,
`handbrake_torque`, `gear_ratios`, `final_drive`, `drag_coefficient`.
