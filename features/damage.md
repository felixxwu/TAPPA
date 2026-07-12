# Damage Model

**Source:** `scripts/damage_model.gd` (`DamageModel`, a `RefCounted` helper owned
by `car.gd` like `Drivetrain`). Design intent in `gameplay.md` › *Damage model*.

Each fielded car has a depleting **HP pool**. Impacts drain it during a run, the
car's handling and power degrade as HP falls, and at 0 HP the car is **wrecked**
(run DNF; a fielded car is destroyed along with its installed upgrades — parts are
fully consumed when fitted, so they are NOT returned). HP only ever goes down
in-run — a repair kit (Save) is the only way it climbs back.

## State (`DamageModel`)

| Field | Meaning |
|-------|---------|
| `max_hp` | the car's HP pool — CarLibrary metadata (`max_hp`, mass-keyed), set per car |
| `hp` | working HP for the current run (starts at the OwnedCar's stored HP) |
| `instance_id` | OwnedCar binding; **-1 = unbound** (free-roam / dev — never touches `Save`) |
| `wheel_toe` | permanent per-wheel toe misalignment (rad), keyed by `WHEEL_NAMES` — see *Wheel misalignment* below |

`field(max_hp, hp, instance_id, wheel_toe)` configures all of the above for a run.
`car.gd` calls it (unbound, full HP, straight wheels) from `apply_car`; the
rally/Start-line layer ([rally-session.md](rally-session.md)) re-fields it from the
OwnedCar (stored HP + instance id + persisted `wheel_toe`) via `apply_owned` when a
car is taken to the line.

## Damage → HP loss (unified deceleration model)

Damage is **generalised**: HP loss is keyed to how much velocity the car sheds in a
**single physics tick** — whatever caused it. A tree, a sign, a cliff wall, a
nose-first drop into a pit, a brushed bush, a mowed crowd: they all decelerate the
body, and that deceleration *is* the damage signal. Nothing on the track "knows" it
deals damage; the car's own physics does.

`car.gd._integrate_forces` runs every physics tick. It computes:

```gdscript
dv = (_approach_velocity - state.linear_velocity).length()   # m/s shed this tick
```

`_approach_velocity` is the **pre-solve** velocity cached at the top of
`_physics_process`; `state.linear_velocity` is **post-solve**. Godot resolves
collisions (and, on a head-on hit, arrests the body) *before* `_integrate_forces`
sees the state, so a collision's full velocity loss shows up in `dv` — with **no
contact inspection**. Gravity/engine/drag each move the velocity only ~0.1–0.3 m/s
per tick, far under threshold, so only real collisions and the soft-drag impulses
(below) produce a damaging `dv`. Using the full **vector** (not scalar speed change)
captures glancing redirects and vertical face-plants alike.

`DamageModel.register_deceleration(dv, dt, point, cfg)` turns it into HP loss:

```
# floor = impact_threshold_g · g · dt   (per-tick velocity below which nothing counts)
# above the floor, a pure square law in km/h (v = the shed velocity):
hp_loss = impact_ref_hp_loss · v² / impact_ref_speed_kmh²
```

- **Braking-proof threshold** (`impact_threshold_g`, ~2 g). Tyres/brakes cap real
  deceleration at ~1–1.5 g and suspension cushions a clean wheel-landing over several
  ticks, so those stay under the floor and cost nothing; a solid crash arrests the
  body in one tick (tens of g) and clears it easily. The small soft-drag impulses
  tip just over it for a light chip. (Trade-off: a hard flat landing or sharp kerb
  can briefly exceed 2 g and chip *minor wear* — accepted; raise `impact_threshold_g`
  if it feels twitchy.)
- **Continuity.** For a full solid arrest `dv ≈ approach speed`, so a 60 km/h head-on
  lands exactly where the old speed-keyed model did — `impact_ref_hp_loss` (320 HP in
  `game_config.tres`) and the whole square-law tuning carry over. `hp_loss_for_speed()`
  is still the pure, unit-tested static.

Two things shape survivability:
- **Per-hit cap** — each tick's loss is clamped to `impact_max_loss_frac` of max HP
  (~1/3), so no one spike wrecks the car.
- **No cooldown.** A pinned/stopped car sheds ~0 velocity/tick, so grinding against a
  wall self-limits with no timer; a genuine multi-bounce **tumble** down a tall drop
  is several real `dv` spikes and racks up several capped hits — so a long fall can
  wreck you. This is intentional: drops are dangerous.

A **reset/teleport** zeroes the velocity discontinuously, which would read as a huge
false `dv`; `car.gd.reset_to` sets `_suppress_impact_frames` so the next couple of
ticks skip the damage check.

A hit that costs HP emits `damaged(hp_loss, contact_point)` for the HUD/audio cue,
and **bends the wheels** (`nudge_wheels`, below).

**Object reactions stay contact-driven.** The `_integrate_forces` contact loop is
kept, but *only* to trigger reactions — trees fall (`TreeFall.should_fell`), etc. —
on their own approach-speed thresholds (they still need to know *which* object was
hit). It no longer touches HP. `OBSTACLE_GROUP` (`"obstacle"`) still tags those
collision bodies so the loop can find them.

## Wheel misalignment (`nudge_wheels`, `car.gd._apply_wheel_toe`)

A damaged car no longer pulls via a synthetic steer offset. Instead each solid
impact **permanently bends every wheel** by a random amount and direction, and the
car's pull/crab then comes from the **physics alone** — the bent wheels are rotated
on the `VehicleWheel3D` nodes themselves.

- **The nudge** (`DamageModel.nudge_wheels`, called from `register_deceleration` on a
  landed hit). For each of the four wheels: `toe += random_sign * (hp_loss/max_hp) *
  damage_wheel_toe_gain * randf(0.5,1)`, clamped to `±damage_wheel_toe_max`. The
  magnitude scales with the hit's strength (bigger crash → bigger knock); the sign
  is rolled **per wheel**, so the wheels don't all bend the same way and repeated
  hits can partly cancel — a wheel can end up near-straight again after two hits.
  `wheel_toe` is a dictionary keyed by `WHEEL_NAMES` (`WheelFL/FR/RL/RR`, the
  car.tscn node names and the stable order used to persist it).
- **Applying it physically** (`car.gd._apply_wheel_toe`). Each wheel carries its own
  `VehicleWheel3D.steering` — a physical steer angle the custom drivetrain tire model
  reads for the force direction (`drivetrain.gd`). So the toe is applied straight to
  that: **front** (steering) wheels get `steering` (the live base steer the body just
  set) **plus** their toe; **rear** wheels — which the body never steers — get only
  their toe. This runs every physics frame right after the base steer is computed, so
  it re-asserts over the body's per-frame overwrite of the front wheels. No node
  rotation and no re-parenting. Because the wheel *visual* is also rebuilt off
  `wheel.steering` (`drivetrain._update_visuals`), the bend is **visible** for free.
- **Persistence.** `wheel_toe` lives on the **OwnedCar** (a 4-float array ordered
  like `WHEEL_NAMES`), persisted at each event boundary alongside HP
  (`world.gd._on_session_event_completed` → `Save.set_wheel_toe`), so a car carries
  its bent wheels **between events**. A **Repair Kit** straightens the wheels along
  with restoring HP (`Save.use_repair_kit` zeroes it; `DamageModel.reset_wheel_toe`
  is the in-model equivalent). Older saves with no `wheel_toe` key are backfilled
  straight (`Save._sanitise`).

## Soft contacts — bushes & spectators (`apply_soft_drag`)

Bushes and spectators are **not** solid obstacles: a `StaticBody` would arrest the
car, the opposite of brushing through undergrowth or a crowd. So they stay
**pass-through**, but instead of a separate flat-HP path they apply a small
**speed-scaled drag impulse** to the car via `car.apply_soft_drag(strength)` —
`apply_central_impulse(-v_horiz · strength · mass)`, shedding a `strength` fraction of
horizontal speed. The resulting deceleration then feeds the **unified damage rule**
above for a light chip. Grouping is natural: a car slowed toward a stop sheds ~0 more
per tick, so ploughing a dense line doesn't wildly over-count — no soft-hit cooldown
needed.

- **Bushes** (`scripts/bush_field.gd`, `BushField`). Bushes are pure visual scatter
  (a `TreeMeshField` built `with_collision=false`), so a dedicated node does a
  per-tick **proximity query**: bush XZ positions binned into a grid (cell = hit
  radius) so only the ~handful in the car's 3×3 neighbourhood are tested. Entering a
  bush (one-shot — tracked in an "inside" set, re-arms on leave) calls
  `apply_soft_drag(bush_drag_strength)` and applies a **side-based yaw drag torque**
  via `apply_torque_impulse`: the pure `drag_torque(forward, to_bush, mag)` returns a
  torque whose sign swings the nose *toward* the bush (a snagged corner dragging back)
  and whose magnitude is `bush_drag_torque × speed × sin(angle)` (zero head-on, peaks
  side-on). The interaction radius is `bush_hit_radius_frac` (<1) of the bush's visual
  `xz_radius`, so clipping the visible edge is forgiven. Gated by `bush_min_speed_kmh`
  — a parked car in a bush isn't tugged.
- **Spectators** (`scripts/spectator_group.gd`). When a member is knocked over
  (`_knock_over`), the car takes `apply_soft_drag(spectator_drag_strength)` — a bit
  **more** than a bush. No torque.

## Effects

- **Engine misfire** (read each physics tick in `car.gd`) — instead of a smooth
  power derate, a damaged engine **intermittently cuts fuel**. The engine stays
  **fully healthy** while health (`hp/max_hp`) is at/above
  `damage_misfire_health_threshold`; below it, `damage.misfire_level(cfg)` ramps
  linearly from 0 at the threshold to 1 at 0 HP. `car.gd` feeds that as
  `engine.misfire_level = m`; inside `EngineSim.step()` a stochastic cut fires with
  probability `rate·h` per substep, where
  `rate = damage_misfire_rate_max · m · (damage_misfire_load_bias + (1-bias)·load)`
  and `load` blends throttle and rpm — so the stumble worsens with damage and under
  load, and a healthy engine (`d = 0`) never cuts. Each cut lasts a rolled
  `damage_misfire_duration_min..max`. While cut, crank torque drops to friction only
  (real power loss, fully simulated) and the same `fuel_cut` state the rev limiter
  uses ducks the synth's firing voice — so the engine audibly sputters. Unlike the
  limiter it does **not** fire the exhaust crackle (that pop is limiter-only;
  `engine_audio.gd` passes `engine.fuel_cut` to duck but only `engine.limiting` as
  the crackle trigger). The pure
  `EngineSim.misfire_rate()` is unit-testable, and a seeded per-engine RNG makes the
  cuts reproducible). This **replaces** the old `power_scale` / `damage_power_loss_max`.
  Each cut also puffs a burst of bonnet smoke — see [engine-smoke.md](engine-smoke.md).
- **Wheel misalignment** — the car's pull/crab is NOT a damage-fraction effect: it
  comes from the accumulated per-wheel `wheel_toe` applied to the physical wheels
  (see *Wheel misalignment* above). It persists between events and is fixed only by
  a Repair Kit, independent of HP.

## Wreck at 0 HP

`apply_loss()` clamps HP at 0 and calls `_wreck()`:
- A **fielded** car (`instance_id >= 0`) calls `Save.wreck_car(instance_id)` —
  which leaves the car **owned at 0 HP** (NOT destroyed): it stays in the garage,
  its installed upgrades stay fitted (parts are consumed on fit, so they're never
  returned), and it's **too damaged to enter a rally** until a **Repair Kit**
  restores it (`Save.use_repair_kit` → full health). `Save.car_is_wrecked(car)` is
  the "0 HP" predicate the menus gate on.
- `wrecked` is emitted either way; `car.gd` re-emits it as the car-level `wrecked`
  signal for the rally/menu layer (sibling to `StageManager.stage_completed`).
- In **free-roam** (unbound) there is no DNF flow, so `car.gd` heals the car
  to full and respawns it at the start so play continues.

Every car — including the starter — is a normal, wreckable car (no invulnerable
car exists). The anti-soft-lock floor is instead `Save.ensure_repair_safety_net`
(see [save-persistence.md](save-persistence.md)): if the player owns ≥1 car, every
owned car is wrecked, and no repair kits are held, it grants one free Repair Kit so
a wrecked car can always be revived.

### Mid-event wreck menu (`scripts/wreck_screen.gd`)

In a real session run, the car's `wrecked` signal does NOT cut straight to the
podium. `world.gd` builds a **`WreckScreen`**: the crash is allowed to play out
(controls locked so the car can't be driven away), then — once it settles, or
`wreck_settle_max_seconds` elapses — an **orbit camera** circles the wreck (reusing
the start-line `start_orbit_*` knobs) under a flat **"CAR WRECKED"** menu with a
**Return to HQ** button. Pressing it emits `return_requested`, which `world.gd`
routes to `RallySession.report_wreck()` (the DNF → podium → HQ). Headless runs skip
the cinematic and report immediately. See [menus.md](menus.md) for the loop.

## In-run HUD (see [hud.md](hud.md))

`hud.gd` reads `car.damage` each frame: a colour-graded **health bar** (`HPBar`,
green → amber → red) under a **`Health NN%`** label (`HPLabel` — a percentage, not a
raw HP number, since "HP" reads as horsepower), a low-health **warning pulse** below
`hud_low_hp_warn_frac`, and a red **impact flash** (`ImpactFlash`) sized to each
HP-losing hit. The gauge is hidden when `hud_hp_enabled` is off.

## Config knobs (`GameConfig`, *Damage* group)

`impact_threshold_g` (the braking-proof deceleration gate — the single sensitivity
knob), `impact_ref_speed_kmh`, `impact_ref_hp_loss`,
`impact_max_loss_frac`, `damage_misfire_health_threshold`, `damage_misfire_rate_max`,
`damage_misfire_load_bias`, `damage_misfire_duration_min`, `damage_misfire_duration_max`,
`damage_wheel_toe_gain`, `damage_wheel_toe_max`, soft contacts (`bush_drag_strength`,
`bush_drag_torque`, `bush_min_speed_kmh`, `bush_hit_radius_frac`,
`spectator_drag_strength`), `hud_hp_enabled`, `hud_low_hp_warn_frac`,
`wreck_settle_max_seconds` (cap on the wreck-menu settle wait; the orbit reuses the
`start_orbit_*` knobs). Per-car `max_hp` is CarLibrary metadata, **not** a
`GameConfig` field. A Repair Kit fully restores health, so there is no partial-heal
knob. Tuning numbers are placeholders pending playtest (the mechanism is fixed, the
values are not).

## Tests

`tests/headless/test_damage_model.gd` (the square-law `hp_loss_for_speed`, **unified
deceleration damage** — below-threshold braking costs nothing, above-threshold costs
HP & emits, a full arrest matches the capped square law, the per-hit cap can't wreck,
a stopped car self-limits without a cooldown, repeated spikes accumulate & wreck, a
soft-drag-magnitude deceleration deals a small chip — the
**damage fraction** tracking HP, **wheel toe** (a hit bends every wheel within the
clamp, a zero-strength hit is a no-op, toe stays clamped over many hits, `field`
loads persisted toe, repair straightens), bound/unbound wreck **keeping the car at 0
HP with its upgrades**, persistence round-trip, **misfire level** — 0 above the
health threshold, ramping to 1 at 0 HP), `test_engine_logic.gd` (**misfire**:
the pure `misfire_rate` is 0 when healthy / positive & load-rising under damage, a
healthy engine never cuts over many steps, a wrecked one cuts intermittently, and a
forced cut kills crank torque), `test_save_manager.gd` (`wheel_toe`
round-trips through save/reload, a Repair Kit straightens the wheels, old saves
backfill straight), `test_car.gd` (bent front wheels **veer the car through the
physics alone**, `engine.misfire_level` tracks the damage fraction), `test_bush_field.gd` (side-based `drag_torque` sign +
scaling, enter/leave one-shot **soft drag**, min-speed gate), `test_spectator_damage.gd` (a
knockdown applies **soft drag** to the car), `test_car.gd` (contact monitor
wiring, plus a **head-on collision costs HP** regression that drives the car into
an obstacle to guard the approach-speed keying above), `test_hud.gd` (health gauge), `test_wreck_screen.gd` (crash → orbit/menu →
`return_requested`).
