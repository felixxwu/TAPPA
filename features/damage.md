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

## Impact → HP loss

`car.gd` enables `contact_monitor` (+ `max_contacts_reported`) and, in
`_integrate_forces`, reads the body's travel speed and the per-tick contacts. Only
contacts against bodies in the `DamageModel.OBSTACLE_GROUP` (`"obstacle"`) group
count — **trees** tag their collision body with it in `tree_mesh_field.gd`, so the
ground/road never chip HP. (Bushes and spectators are *soft contacts*, handled
separately below — they are pass-through, not solid obstacles.) Each qualifying contact
calls `register_impact(speed, …)` with the **speed the car was travelling at**:

```
# v = impact speed in km/h (car speed × 3.6); 0 below impact_min_speed_kmh.
hp_loss = impact_ref_hp_loss * (v² - impact_min_speed_kmh²)
                             / (impact_ref_speed_kmh² - impact_min_speed_kmh²)
```

A **square law** (kinetic energy): a hit at the reference speed
(`impact_ref_speed_kmh`, ~60 km/h) costs `impact_ref_hp_loss` (320 HP in
`game_config.tres`, up from the 200 default — objects hit harder), so with
per-car max HP of 800-1100 most cars survive **~3 moderate hits**; the square
then makes a 20 km/h hit cost only a small fraction of that, so the car **barely
takes damage at low speed**. `hp_loss_for_speed()` is a pure static so the
conversion is unit-testable.

**Approach speed, not the arrested one.** The impact speed fed to
`register_impact` is `car.gd._approach_speed` — the chassis speed cached at the
top of `_physics_process`, *before* the physics solver runs — **not** the
`state.linear_velocity` available inside `_integrate_forces`. Godot only surfaces
a contact in `_integrate_forces` *after* the constraint solver has already
resolved (and, in a head-on hit, arrested) it, so the post-solve velocity is
near zero on exactly the hardest crashes. Reading it directly made head-on
collisions deal **no** damage (the square law floored to 0 below
`impact_min_speed_kmh`) while glancing hits — which keep their speed — still
chipped HP. Keying off the cached pre-solve speed gives the true approach speed.

Two guards stop a single crash from instantly wrecking the car (cars should survive
2-3 big hits):
- **Per-hit cap** — the loss is clamped to `impact_max_loss_frac` of max HP, so no
  one impact can take more than ~1/3 of the bar.
- **Post-hit cooldown** — after a damaging hit, impacts are ignored for
  `impact_cooldown_s`. The chassis contacts an obstacle *every physics tick* while
  it's pinned/tumbling, so without this one crash would register dozens of hits;
  the cooldown groups a whole crash into a single hit. `car.gd._physics_process`
  decays it via `damage.tick_cooldown(delta)`. The window **re-arms on each
  continuing contact**, so the timer only starts counting down once the car breaks
  free — a *sustained* crash (grinding along a tree line, or jammed against one for
  several seconds) stays **one** hit instead of re-chipping every `impact_cooldown_s`.

A hit that costs HP emits `damaged(hp_loss, contact_point)` for the HUD/audio cue,
and **bends the wheels** (`nudge_wheels`, below).

## Wheel misalignment (`nudge_wheels`, `car.gd._apply_wheel_toe`)

A damaged car no longer pulls via a synthetic steer offset. Instead each solid
impact **permanently bends every wheel** by a random amount and direction, and the
car's pull/crab then comes from the **physics alone** — the bent wheels are rotated
on the `VehicleWheel3D` nodes themselves.

- **The nudge** (`DamageModel.nudge_wheels`, called from `register_impact` on a
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

## Soft contacts — bushes & spectators (`register_soft_hit`)

Bushes and spectators are **not** solid obstacles: a `StaticBody` would arrest the
car, the opposite of brushing through undergrowth or a crowd. They deal a **flat**
HP loss (not the speed square-law) via `DamageModel.register_soft_hit(hp_loss,
contact_point, cooldown_s)`, which drains HP, can wreck at 0, and emits the same
`damaged` signal so the HUD flashes exactly as for a tree impact. A **separate**
soft-hit cooldown (`soft_hit_cooldown_s`, tracked apart from the impact cooldown so
a bush graze and a tree crash don't mask each other) groups a continuous
contact — sitting in a bush, mowing a tight crowd — into one hit.

- **Bushes** (`scripts/bush_field.gd`, `BushField`). Bushes are pure visual scatter
  (a `TreeMeshField` built `with_collision=false`), so a dedicated node does a
  per-tick **proximity query**: bush XZ positions binned into a grid (cell = hit
  radius) so only the ~handful in the car's 3×3 neighbourhood are tested. Entering a
  bush (one-shot — tracked in an "inside" set, re-arms on leave) costs `bush_hp_loss`
  and applies a **side-based yaw drag torque** via `apply_torque_impulse`: the pure
  `drag_torque(forward, to_bush, mag)` returns a torque whose sign swings the nose
  *toward* the bush (a snagged corner dragging back) and whose magnitude is
  `bush_drag_torque × speed × sin(angle)` (zero head-on, peaks side-on). The
  interaction radius is `bush_hit_radius_frac` (<1) of the bush's visual `xz_radius`,
  so clipping the visible edge is forgiven. Gated by `bush_min_speed_kmh` — a parked
  car in a bush isn't tugged.
- **Spectators** (`scripts/spectator_group.gd`). When a member is knocked over
  (`_knock_over`), the car takes a `spectator_hp_loss` soft hit — a bit **more** than
  a bush. No torque. Ploughing a dense line is one hit (shared soft-hit cooldown),
  not one per member.

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

`impact_min_speed_kmh`, `impact_ref_speed_kmh`, `impact_ref_hp_loss`,
`impact_max_loss_frac`, `impact_cooldown_s`, `damage_misfire_health_threshold`, `damage_misfire_rate_max`,
`damage_misfire_load_bias`, `damage_misfire_duration_min`, `damage_misfire_duration_max`,
`damage_wheel_toe_gain`, `damage_wheel_toe_max`, soft contacts (`bush_hp_loss`, `bush_drag_torque`,
`bush_min_speed_kmh`, `bush_hit_radius_frac`, `soft_hit_cooldown_s`,
`spectator_hp_loss`), `hud_hp_enabled`, `hud_low_hp_warn_frac`,
`wreck_settle_max_seconds` (cap on the wreck-menu settle wait; the orbit reuses the
`start_orbit_*` knobs). Per-car `max_hp` is CarLibrary metadata, **not** a
`GameConfig` field. A Repair Kit fully restores health, so there is no partial-heal
knob. Tuning numbers are placeholders pending playtest (the mechanism is fixed, the
values are not).

## Tests

`tests/headless/test_damage_model.gd` (speed→HP + the 60/20 km/h calibration, the per-hit cap + post-hit
cooldown grouping a crash into one hit / needing several hits to wreck, **soft
hits** — flat loss, own cooldown independent of impacts, wreck at 0 — the
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
scaling, enter/leave one-shot, min-speed gate), `test_spectator_damage.gd` (a
knockdown costs the car `spectator_hp_loss`, more than a bush), `test_car.gd` (contact monitor
wiring, plus a **head-on collision costs HP** regression that drives the car into
an obstacle to guard the approach-speed keying above), `test_hud.gd` (health gauge), `test_wreck_screen.gd` (crash → orbit/menu →
`return_requested`).
