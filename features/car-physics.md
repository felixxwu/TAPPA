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

### Hitbox shape (chamfered octagon)

The chassis collision hull is **not a plain box** — it's a box with its four
**vertical** corners chamfered, so from the top it's an elongated octagon
(`_chassis_hull_points` in `car.gd`). `_apply_body_meshes` swaps the scene's default
`BoxShape3D` for a per-car `ConvexPolygonShape3D` whose 16 points (8 top-view corners ×
top/bottom) are rebuilt from the body dims each `apply_car`. The corner cut is an
**equal absolute inset on both width (X) and length (Z)** — `body.x ×
GameConfig.hitbox_chamfer_fraction` (default **1/3**) — so the cut is 45° and the
nose/tail read as a regular octagon (a third-of-width chamfer leaves a flat front edge
one-third the car's width). The inset is clamped so every face keeps a positive flat
edge. The hull's **bounding extents are unchanged** (the mid-edge points still reach
`body.x`, `body.y − 0.3`, `body.z`), so weight/CoM/ride-height are unaffected — only the
corners are pulled in.

Why: the hull is only ever hit by *obstacles* (trees, signs, spectators, other cars) and
feeds the damage model's contact impulses — the wheels are independent raycasts, so this
shape has **zero effect on grip, top speed, or cornering**. Chamfering makes a glancing
corner clip **deflect along** the obstacle instead of catching the square corner and
snapping the car, and (being a glancing rather than square contact) costs marginally less
HP on side-swipes. The [debug overlay](debug-tools.md) draws the octagon prism, rebuilt
from the same hull points. Geometry is covered by `test_chassis_hull_*` in
`tests/headless/test_car_types.gd`.

### Per-instance resource isolation

`car.tscn` authors the chassis/cabin boxes, the wheel tyre/spoke meshes, and the
chassis **collision shape** as `[sub_resource]`s. Godot shares one copy of a
sub-resource across **every instance** of the scene, and `apply_car()` reshapes these
in place per car (`_apply_body_meshes` / `_relocate_wheels`). So without isolation, a
second live car — the [start-line](start-line.md) queue leader/trailer, spawned and
`apply_car`'d **after** the player is already sized — reshapes the shared resource and
the change bleeds back onto the player: wrong wheel visuals, or (the subtler one) the
player's **hitbox** taking the last-applied car's body size while the meshes still look
right. `car.gd._ready()` defends against this by giving each instance its own copies up
front (`.duplicate()` of the Chassis/Cabin meshes, each wheel's tyre/spoke mesh, and
the collision shape) before any `apply_car` can run. The hitbox is doubly safe now that
`_apply_body_meshes` assigns a **fresh** `ConvexPolygonShape3D` per instance (the scene
`BoxShape3D` is only the un-applied fallback), but the duplicate still covers a car that
never gets `apply_car`'d. Any *new* shared sub-resource that `apply_car` mutates must be
added to that list, or it will silently leak across instances — this class of bug has
bitten wheels and the hitbox already (`tests/headless/test_car_types.gd` has a regression
for each).

## Per-step loop (`_physics_process`)

1. **Mode inputs:** `engine.auto` is mirrored from the Gearbox setting
   (`SettingsMenu.gearbox_auto()`, see [controls.md](controls.md));
   `shift_up`/`shift_down` (E/Q) request manual shifts.
2. **Throttle/brake resolution:**
   - *Auto:* `engine.select_forward/select_reverse` pick a gear at low speed;
	 `engine.update_auto` handles upshifts based on ground speed.
   - *Manual:* W accelerates (or reverses in R gear); S brakes / reverses.
   - Near-zero speed engages a parking brake.
3. **Steering — a grip servo, not an angle:** steering input is the **share of the front
   tires' available cornering grip** the driver is asking for; `Car._update_steering` works
   the wheel angle until the tires deliver it. It runs **after** `drivetrain.step()` so it
   closes its loop on this tick's own tire measurements. See
   [todo/grip-servo-steering.md](../todo/grip-servo-steering.md) for the full derivation and
   the three things driving corrected.
   - **The zero point.** There is one wheel angle at which the front tires do no sideways
     work: pointing them along the direction they are already travelling. `null = steering +
     slip_angle`, from each front wheel's OWN measured slip angle
     (`Drivetrain.front_axle_state()`, load-weighted by normal force — the loaded outer tire
     dominates, since it does most of the work). Every command is measured out from there,
     which is why countersteer needs no rule: releasing the wheel targets the null and the
     slide catches. It also makes the controller **stateless** — the current offset from the
     null is just `|slip_angle|`, re-measured every tick, so there is nothing to wind up.
   - **The setpoint is the LATERAL budget**, not total usage: `steer_demand * lat_available`,
     where `lat_available = sqrt(1 - long_used²)` from the *measured* longitudinal slip. The
     wheel angle only moves the lateral component, so charging the driver for longitudinal
     spend would mean a pinned pedal drives the wheels straight.
   - **The step is `error * slip_peak`** (`Car.grip_servo_step`) — the usage error converted
     into radians, a Newton step of gain 1. Requiring that a tick never move further than the
     remaining angular error collapses any gain term to exactly this, so **there is no gain
     knob**; it self-scales with the surface and the frame rate. Its small-angle approximation
     errs toward under-correcting, which is the safe direction.
   - **At rest the null is undefined** — `atan2(0, 0)` is 0, so `null == steering` and released
     wheels would stay cocked. Below `tire_norm_floor` the null fades toward straight ahead
     (the same floor at which the tire model stops treating slip as meaningful), so parked
     wheels centre themselves. Confined to the zero-input branch: pinning the null while a
     demand is held would stop it walking out to full lock at a standstill.
   - **`steer_limit`** is the mechanical stop and the only hard bound; **`steer_speed`** is the
     rate limit and the ONLY rate in the system — the model of how fast a hand can turn the
     wheel, and also the input smoothing (there is no separate easing stage). Because the servo
     only has to cover the tire's slip angle (~8.6° on tarmac) rather than most of full lock,
     it is the dominant feel parameter and is tuned well below a lock-to-lock rate.
   - **Damage toe rides inside the loop.** `_apply_wheel_toe` bends each wheel on top of the
     servo's angle and the drivetrain measures in that toed frame, so the servo corrects the
     symmetric front component exactly as a real driver holds a correction on a car with bent
     alignment — it tracks straight with the wheels visibly off-centre. Rear toe is beyond its
     authority and a front pair bent opposite ways nets out of the load-weighted average, so a
     damaged car still crabs and scrubs. See [damage.md](damage.md).
   - **Longitudinal and lateral demand share one circle.** Every input is 0% or 100% on a
     keyboard or touch screen, so `Car.longitudinal_demand_scale` scales the longitudinal side
     to fit: a pedal alone is untouched, a pedal pinned with full steering scales to 0.71 (the
     friction-circle optimum). The **brake** always counts; the **throttle** counts only when
     the steered axle is also driven (`Drivetrain.front_axle_driven()` — FWD/AWD, not RWD), so
     RWD power-oversteer is untouched. Only the longitudinal side is scaled, because
     `lat_available` already limits the lateral side and scaling both would double-count.
     Trail braking and power-out emerge from this rather than being scripted. It is demand
     arbitration, **not** ABS or traction control: pedal torque is untouched when the player
     isn't steering, so lockup and wheelspin remain.
   - **Spin protection** (`spin_assist_torque`) is now the ONLY steering aid, and solves what
     the servo cannot: a player who holds steering *into* a slide until the car rotates past
     recovery. Once the car has rotated further than `spin_assist_angle` from its travel
     direction, a corrective yaw torque pulls the nose back, ramping in linearly from 0 at the
     threshold to full at twice it, with a yaw-rate damping term (`SPIN_ASSIST_DAMPING`) so the
     slide settles instead of oscillating. Suppressed while the handbrake is held (so
     deliberate drifts work), and gated by `Car._chassis_slip_angle`'s own 2 m/s
     forward-motion floor, which keeps it out of low-speed manoeuvring — it prevents reaching a
     spin rather than unwinding a completed one.

   **Deleted with this redesign** (do not look for them): the `_steer` input-smoothing stage,
   `steer_travel_alignment`, `Car.optimum_steer_limit`, `steer_lock_blend_end_speed`,
   `Car.steer_authority`, `Car.optimum_slip_angle`, `Drivetrain.steering_axle_slip_peak`,
   `steer_assist_min_speed`, and the understeer aid `_apply_steer_assist` /
   `steer_assist_torque` (which was already `0` on every shipped car).
4. **Aero forces:**
   - *Drag:* `-velocity * |velocity| * drag_coefficient` (quadratic). `linear_damp`
	 is forced to 0 so this is the only speed-dependent linear loss. The body's
	 `angular_damp` is likewise forced to 0 in `_ready` (Godot's implicit default is
	 0.1) so a launched car keeps its spin mid-air instead of being passively slowed;
	 grounded rotation is governed by the tire model + the steer/spin/level assists.
   - *Downforce:* `v² * downforce_{front,rear}` applied at the axle midpoints;
	 also recorded in `downforce_readouts` for the debug overlay. Either
	 coefficient may be negative, which produces lift (an upward force that
	 unloads that axle at speed). The coefficients are **per-car**: `apply_car`
	 *sets* `cfg.downforce_{front,rear}` from the CarLibrary spec (so a car with 0
	 has none — no hidden global), and the aero_kit upgrade adds on top. Every car
	 carries a small `downforce_rear` to keep the tail planted under power; front
	 is 0 unless a spec sets it.
   - *Crosswind:* on a windy condition only — see "Crosswind" below.
5. **Self-righting assist:** a roll+pitch torque (`level_assist_torque`) eases the
   chassis back toward level (`car.gd` → `_apply_level_assist`). The torque axis is
   `car_up × reference_up`, perpendicular to the car's own up (so it never yaws),
   with magnitude `sin(tilt)`, so the correction grows the further the car is from
   flat; a damping term (`LEVEL_ASSIST_DAMPING`) opposing the roll+pitch rate keeps
   it from overshooting. It runs in **two regimes off one strength knob**:
   - **Airborne** (any wheel off the ground) — full strength, referenced to **world
     up**. A landing / anti-flip aid: world-flat is the attitude that lands on four
     wheels.
   - **Grounded** (all four planted) — `level_assist_torque × level_assist_grounded`,
     referenced to the **average wheel contact normal** (`_ground_normal()`). Here it
     acts as a cheap **anti-roll bar**: it resists cornering roll and braking dive and
     stands the car back up on its springs. Referencing the *surface* rather than world
     up is what stops it fighting a cambered corner or off-camber verge, where
     levelling to the world would mean a permanent torque trying to peel the car off
     the slope. At realistic body-roll angles the `sin(tilt)` term is small, so the
     **damping term dominates** the feel. Note this damps the chassis *attitude* only —
     unlike a real anti-roll bar it does not shift left/right suspension load, so it
     cannot be used to trim understeer/oversteer balance (that would need a load-
     transfer term in `Drivetrain.wheel_normal_force()`). It also resists **pitch** as
     well as roll, so a high setting flattens dive/squat too; splitting the roll and
     pitch weights would need separate knobs. `level_assist_grounded = 0` (the script
     default) makes the aid airborne-only, as it originally was.
6. **Tire/engine step:** `drivetrain.step(delta, throttle, brake, handbrake)`
   computes and applies all wheel contact forces.

## Crosswind (storm)

**Source:** `scripts/crosswind.gd` (the pure profile), `car.gd` → `_apply_crosswind`
(applied inside `_apply_aero`, alongside drag and downforce, so it composes with the
existing physics instead of fighting it).

A lateral **body force in a fixed world direction**, so on a windy stage the car is
blown off line and has to be steered against — not a drag term that turns with the car.
Because the heading is world-fixed, a broadside car catches more of it than a nose-on
one (`crosswind_nose_on_fraction` sets how much still acts head-on). That exposure
factor is deliberately a constant: there is **no shelter/occlusion model** (open ground
vs. tree cover). Possible future work, but it needs a cheap way to know cover — do not
build a new occlusion system for it.

### Determinism — the load-bearing property

The force is a **pure function of distance along the stage and the event seed**
(`Crosswind.force_at` / `magnitude_at`): never `randf()`, never the clock or a frame
count, and no `RandomNumberGenerator` state carried between ticks (phases come from an
integer hash of `(seed, octave)`, so evaluation order cannot matter). Two runs of the
same stage therefore meet the identical gust at the identical point on the road.

Why it matters: every stage has a **global leaderboard** keyed by
`RallyLibrary.stage_key` ([global-leaderboards.md](global-leaderboards.md)). A wind
that differed run to run would silently stop every storm board comparing like with
like. Keying on *distance* rather than time also makes gusts **learnable** — the same
gust waits in the same place every attempt — which is fairer play as well as fairer
scoring. Distance comes from the existing `TrackProgress.progress_offset()` odometer,
not a private one, so wind is keyed to the same along-track metric the HUD and the
stage gate use.

The gust profile is `strength + gust × (normalised sum of `OCTAVES` layered sines)`,
so it is smooth (a gust builds and eases rather than snapping) and provably bounded to
`strength ± gust`.

### Opting in, and the zero-cost default

Nothing here ever tests a weather id by name. A condition opts in by carrying a
**`"wind"` block** in its `WeatherLibrary` entry, naming the GameConfig fields that
supply strength / gust / direction (per the project rule the table names fields, never
numbers). `Crosswind.wind_params(cfg)` returns `{}` for any condition without one —
dry, rain, fog, everything non-storm — and the car then applies nothing.

`car.gd` memoises that resolution the same way `Drivetrain` memoises `_weather_mu`:
re-read only when `cfg.weather` or the config object changes. **On a non-storm stage
the per-tick cost is two comparisons and a bool test** — no dictionary lookup, no
allocation, no force. Wind never reaches `TrackGenParams` or the track cache; it is not
a shape determinant.

Tests: `tests/headless/test_crosswind.gd` (determinism incl. order-independence,
distance variation, monotonicity in strength, the `strength ± gust` bound, and "no wind
block ⇒ no wind").

## Suspension

Springs configured from `suspension_stiffness` / `suspension_travel`. Damping is
derived in `GameConfig`: compression = √rate (critically damped), rebound =
1.5× compression. Per-wheel normal force is computed in
`Drivetrain.wheel_normal_force()`.

**Per-axle spring rates.** The authored `suspension_stiffness` is the car's
*overall* rate; the front/rear rates are not authored but **split from it by the
weight distribution** — `GameConfig.axle_stiffness(front)` returns
`suspension_stiffness × 2 × axle_weight_fraction` (the ×2 keeps the two-axle mean
at the base rate, so a 50/50 car gets the base rate on both). Because static
compression is `load / rate` and both scale with the axle's weight fraction, the
compression works out **equal front and rear** (`≈ g/(4·rate)`, independent of
distribution) — so a nose-heavy car sits **level** instead of drooping onto its
heavy end. Dampers are re-derived per axle from the resolved rate. This is the
partner to the per-car centre of mass (see "Weight distribution"): `weight_front`
drives both.

`suspension_travel` doubles as the wheel raycast / rest length, so a shorter
travel also lowers ride height. Optional `suspension_travel_front` /
`suspension_travel_rear` overrides (0 = inherit `suspension_travel`) let a body run
a longer front or rear stroke for rake / wheel-well fit; `axle_travel(front)`
resolves them per wheel. These values are all **per-car**: each `CarLibrary` entry
carries its own `suspension_travel` + `suspension_stiffness` (+ optional per-axle
travel), overlaid onto the live config by `car.gd`'s `apply_car()` and pushed onto
each wheel per axle via `_apply_suspension()` (dampers re-derived; the standalone
`_sync_suspension_to_wheels()` re-pushes after an upgrade mutates the rate). Soft &
tall roadster/muscle (MX-5, Charger) vs stiff & low supercars (911, Viper,
XJS). The `config/game_config.tres` values are the baseline/fallback.

### Static rest pose (`settled_ride_height`)

Display / prop cars — the roadside opponent wreck (`world.gd`), the podium finishers
(`podium.gd`), and the HQ parked lineup (`hq.gd`) — are placed **analytically at rest
and frozen at once**, instead of being dropped as live physics bodies and frozen a beat
later. That old drop-and-settle was a recurring bug source: it depended on a ground
collider being present under the car (the wreck sank through the streamed-in-only-near-
the-player terrain), on the car not rolling on a slope, and on not re-wrecking on the
landing impact — plus the freeze timing.

Placing a prop takes **two** offsets — the body and the wheels move independently:

```
settled_ride_height = wheel_radius + axle_travel − mount_y            # wheel fully drooped
                    − SUSPENSION_COMPRESSION_COEFF · g / suspension_stiffness   # sag under weight
wheel Visual droop  = wheel_rest_length − WHEEL_DROOP_COEFF · g / suspension_stiffness  # per wheel
```

`car.settled_ride_height()` returns how far the body origin sits above flat ground at
rest — the height a **live** car settles to. That height assumes the wheels have drooped
down below their authored mount (as Godot's solver renders them while driving). But a
frozen prop's solver never runs, and `drivetrain._update_visuals` only re-orients the
wheel Visual (never translates it), so left alone the Visual stays at its authored mount
— ~`axle_travel` too high, so the car reads as sitting on **over-compressed** suspension
and floats. So after seating the body, a caller also calls **`car.settle_wheel_visuals()`**,
which drops each wheel Visual by the droop above to where Godot's live solver would render
it. This must run on frozen props **only** — a live car lets Godot move the wheel node and
keeps its Visual at the local origin.

Both compression terms come from Godot's built-in `VehicleWheel3D` solver (**not** the
game's own tire model — they disagree by ~0.1 m) and are **mass-independent** (Godot
normalises the spring by chassis mass). `SUSPENSION_COMPRESSION_COEFF` and
`WHEEL_DROOP_COEFF` are both calibrated against a real settle and pinned by
`test_rest_pose.gd`, which re-derives them from an actual `VehicleWheel3D` settle across a
range of configs (and checks the drooped prop Visual lands at the live wheel height),
failing loudly if a Godot upgrade shifts the solver — so the constants can't silently
drift. A caller seats the car on its ground plane, lifts the body by
`settled_ride_height()`, droops the wheels, then freezes `FREEZE_MODE_STATIC`.

**Ground-conforming wheels (uneven ground / the lift).** Props that sit on real,
possibly-uneven ground (HQ car-park lineup, HQ tuning lift, roadside wrecks) use
**`car.settle_wheels_to_ground(ground_at)`** instead of the flat `settle_wheel_visuals()`.
It droops each wheel Visual so the **tyre bottom sits on `ground_at(wheel_world_pos)`**
(geometric contact), clamped to `[0, wheel_rest_length]` — so a wheel over lower ground
extends further and one over higher ground tucks up, and a wheel with no ground in reach
dangles at full droop. If `ground_at` returns a **non-finite** value (e.g. a raycast miss),
that wheel keeps the analytic `settle_wheel_visuals` droop rather than dangling. HQ contexts
pass **`car.ground_raycast()`** (a downward ray against the lot floor, self excluded); this
is what makes the tuning-lift wheels rest on the floor when down and **extend as the lift
raises** (re-settled each frame from the raise tween). Roadside wrecks pass
`terrain.height_at`. The **podium keeps the flat `settle_wheel_visuals()`** (staged platform,
no ground collider). **`Car.compression_budget(cfg)`** (static) returns how far a wheel can
droop below the rest plane — used by the wreck site gate.

## Weight distribution (centre of mass)

Each `CarLibrary` entry carries a real `weight_front` — the car's published static
front-axle weight fraction (0.50 = 50/50, >0.5 nose-heavy, <0.5 tail-heavy).
`apply_car()` switches the body to `CENTER_OF_MASS_MODE_CUSTOM` and places the CoM
along the wheelbase: for static balance the CoM sits behind the front axle by
`wheelbase × rear_fraction`, so from the wheelbase-centred body origin (front axle at
−Z, rear at +Z) the offset is `center_of_mass.z = wheelbase × (rear_frac − 0.5)`
(+Z = rearward). Only the front/rear split is authored; the CoM height stays at the
body origin (`y = 0`) — published CoG-height data is scarce and the low
`wheel_roll_influence` (0.1) damps its effect anyway.

This is **not cosmetic**: `Drivetrain.wheel_normal_force()` derives each wheel's grip
from its actual suspension compression, and the suspension settles around wherever the
CoM sits — so a rearward CoM compresses the rear springs more, loads the rear tyres
more, and shifts the car toward oversteer (and vice-versa). The transient effects (dive
/ squat / roll load-transfer) are deliberately muted by the low `wheel_roll_influence`;
the static front/rear balance comes through regardless. Nose-heavy FWD (Focus, Twingo)
and nose-heavy front-engine GT (XJS) vs tail-heavy mid-engine (Acty) vs
near-50/50 (MX-5, Viper).

**Recompute on engine swap.** [engine-swap.md](engine-swap.md) lets a player move an
engine from one owned car to another. `car.gd`'s `_apply_engine_swap` treats the
engine as an independent point mass at the car's `engine_pos` (a `CarLibrary` field —
the ENGINE's own front-weight fraction, distinct from the car's overall `weight_front`)
and re-derives both `mass` and `weight_front` from the authored baseline via
`EngineSwap.recompute_mass` / `EngineSwap.recompute_weight_front`, then re-applies the
same `center_of_mass.z = wheelbase × (0.5 − weight_front)` formula above with the new
`weight_front`. This runs before the upgrade/tuning steps and before the suspension
re-sync, so a swapped-in heavy V8 (or a lightweight rear-engined flat-6) shifts the
car's static balance — and hence its suspension load split and handling bias — exactly
like a different authored `weight_front` would.

## Damage effects

`car.gd` owns a `DamageModel` (see [damage.md](damage.md)) that degrades the car
as its HP falls. Two effects fold into the per-step loop above: physically **bent
wheels** (per-wheel toe on `VehicleWheel3D.steering`, step 3) and an **engine
misfire** — `car.gd` feeds the damage fraction to `engine.misfire_level` (step 6)
and `EngineSim` cuts fuel in stumbling bursts. Both are 0 at full HP. `car.gd` also
enables contact monitoring and reads obstacle-contact impulses in
`_integrate_forces` to drain HP.

## Control source (player / locked / scripted)

`_physics_process` reads its throttle / steer / handbrake from one of three sources:
- **Player** (default) — global `Input` actions.
- **Locked** (`controls_locked`, set by [`StageManager`](stage.md)) — input neutralised
  and the handbrake forced, so the car holds fully still (staged at the line, or after
  the finish) while the rest of the sim (suspension, drag, camera) keeps running.
- **Scripted** (`ai_controlled`) — the car ignores `Input` and drives from
  `ai_throttle` / `ai_steer` / `ai_handbrake` (same axes/sign as the player inputs).
  Used for the [start-line](start-line.md) queue cars, which run full physics (real
  suspension load) under script while axis-locked to a straight line. Discrete actions
  (shift / mode / reset) are ignored when locked or scripted.

A lighter **handbrake-only hold** (`handbrake_locked`, also set by `StageManager`)
forces the handbrake while leaving driver input fully live — used during the
**countdown** so the player can rev the engine (a held handbrake opens the clutch in
[`Engine.step`](engine-and-transmission.md), so the revs climb freely) and steer, then launch the
instant the brake releases on GO.

The **finish stop** (`finish_stop`, set by `StageManager` on crossing the line
alongside `controls_locked`) brakes the car to a halt cleanly: while it's still
rolling (> `FINISH_STOP_SPEED`, 0.8 m/s) it forces the **full foot brake** on top of
the forced handbrake, then releases the foot brake once stopped (the handbrake /
parking hold still holds it put). Crucially the engine **clutch stays engaged**
through the stop — `_physics_process` computes `declutch` as the handbrake by default
but overrides it to `false` here, and passes it to `Drivetrain.step` separately from
the handbrake's brake torque — so the engine **winds down with the braking wheels**
(the speed-gated auto-clutch opens at standstill and it settles to idle) instead of
free-revving on the handbrake's open clutch.

Regardless of source, a car that is fully braked (handbrake **or** the low-speed
parking brake) and below `HANDBRAKE_LOCK_SPEED` (0.5 m/s) gets a **static-friction
hold** — `_apply_parking_hold` anchors it to the spot it stopped on and ties it there
with a **damped spring** (`parking_hold_stiffness` / `parking_hold_damping`, both in
acceleration terms so they are mass-independent), clamped to `parking_hold_grip · m · g`.
The anchor is taken on the first engaged tick and dropped the moment the hold
disengages; when the clamp is reached (a very steep grade, or a shove) the car slides
and the anchor follows `parking_hold_slack` behind it, so no unbounded slack builds up.
The hold anchors **heading as well as position** (`_apply_heading_hold`): the yaw the
car was facing on the first engaged tick, sprung back with a **critically damped**
term whose damping is derived as `2·√k` from `parking_hold_stiffness` rather than
authored, so the heading half can never be tuned into a wobble. Without it the
positional anchor left rotation completely free, and anything that turned a held car
— a kerb, a steering input during the countdown, an uneven surface — left it turned:
measured at **16.6° of drift in two seconds** from one nudge, which is how a car could
be pointing the wrong way by the time the 3·2·1 reached GO. Guarded by
`tests/headless/test_countdown_hold.gd`, which asserts the behaviour (no ringing, no
drift, still releases) rather than any tuned value.

**A body with no yaw freedom is skipped, and this is load-bearing.** The heading term
needs the yaw inertia, which it gets by inverting `get_inverse_inertia_tensor()` — and
that tensor is SINGULAR whenever the body cannot yaw: `axis_lock_angular_y` zeroes that
axis, and a frozen body zeroes all three. Inverting it trips Godot's
`Condition "det == 0" is true` in `Basis::invert`, which returns a garbage basis that
then goes straight into `apply_torque` and corrupts the physics state. So
`_apply_heading_hold` bails when the tensor's determinant is EXACTLY zero — mirroring
the engine's own condition, so it fires precisely when inverting would fail. Which is
also the correct behaviour, since a car that cannot yaw has no heading to hold.
(`is_zero_approx` is wrong here: its 1e-6 epsilon swallows the legitimately tiny
determinant of a real car's inverse inertia tensor — entries ~1e-3 for a ~1000 kg car,
so det ~1e-9 — which disables the hold for every car.)

That was not hypothetical. `start_line.gd::_stage_player` sets `axis_lock_angular_y`
while the grid rolls up, so **every career start** hit it on every physics frame. The
corrupted transform left the car pinned at the world origin for the entire stage, and
the chase camera — which follows the car — sat below the terrain rendering a flat grey
screen; the symptom reported from an Android build was "the cars on the start line are
all inside each other and pressing play shows pure grey". Regression:
`test_car.gd::test_heading_hold_survives_a_locked_yaw_axis`, which asserts the car's
transform and velocities stay FINITE with yaw locked (a garbage basis shows up as
NaN/INF) — it fails without the guard.

This is needed because the tire model's longitudinal force fades to zero as slip does
(`_tire_force` caps it at `|slip|·m/h`), so at creep speed gravity's slope component
would otherwise win and the car would dribble downhill. The hold behaves like real
stiction: it pins the car on any sane grade (a centimetre or so of slack) but a
wall-steep slope still slides, and — unlike the old `freeze` hack — the car stays a
**live rigid body** (no snap on release, still collidable). This keeps a settling
[start-line](start-line.md) queue car from creeping into the car ahead and holds the
player put during the countdown (`handbrake_locked` forces the handbrake).

> **Why a spring and not a velocity cancel** (the countdown-vibration fix — don't
> regress it). The hold used to be `F = -m·v_h/dt` sized off the **previous** tick's
> velocity: "erase whatever velocity the car had". That has no position feedback and
> always runs a tick behind the disturbance, so every tick it wiped last tick's velocity
> while the grade/drivetrain added a fresh `a·dt` — a held car therefore lurched along at
> a steady `v ≈ a·dt` **forever** (measured: ~3 cm/s under an ~12° grade's worth of pull),
> which is exactly the countdown "vibration + sideways creep". It also double-counted the
> pinned tires' own friction (both cancel the same velocity in the same step), so the body
> could overshoot through zero and ring, and the `μ·m·g` clip rectified that ringing into
> yet more drift. The anchored spring fixes both: it corrects **displacement**, so the
> resting offset is bounded (`≈ a / parking_hold_stiffness`), and its per-tick authority is
> `k·offset·dt² ≪ offset`, so it converges instead of oscillating. It also leaves the
> chassis's own roll/pitch sway alone — a velocity cancel stiffened the body and killed
> body roll dead. Regression test: `test_held_car_stays_put_under_steady_disturbance`
> in `tests/headless/test_car.gd` (it fails on the old velocity-cancel hold).

## Braking summary

| Input | Torque | Target |
|-------|--------|--------|
| S (foot brake) | `brake_torque` (300) per axle | all 4 wheels |
| Space (handbrake) | `handbrake_torque` (400) | rear axle only (drift) |
| Auto parking | `brake_torque` | all 4 below ~2 m/s |

## Tests

`tests/headless/test_car.gd` (launch, speed, steering, reset),
`tests/headless/test_car_terrain.gd` (behavior on slopes),
`tests/headless/test_crosswind.gd` (the storm wind profile + its determinism).

## Related config

`mass`, `drag_coefficient`, `downforce_front/rear`, `steer_*`,
`spin_assist_torque`, `spin_assist_angle`, `level_assist_torque`,
`level_assist_grounded`,
`crosswind_gust_wavelength_m`, `crosswind_nose_on_fraction`,
`suspension_*`, `brake_torque`, `handbrake_torque`. See
[configuration.md](configuration.md).
