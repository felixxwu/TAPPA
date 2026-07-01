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
| `align_bias_sign` | ±1 steer-pull direction, re-rolled each run via `reroll_bias()` |

`field(max_hp, hp, instance_id)` configures all of the above for a run.
`car.gd` calls it (unbound, full HP) from `apply_car`; the future rally/Start-line
layer ([rally-session.md](rally-session.md)) re-fields it
from the OwnedCar (stored HP + instance id) when a car is taken to the line.

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

A hit that costs HP emits `damaged(hp_loss, contact_point)` for the HUD/audio cue.

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

## Effects (scale with the damage fraction `d = 1 - hp/max_hp`)

Read each physics tick in `car.gd`; both are 0 at full HP:

- **Power loss** — `drivetrain.power_scale = damage.power_multiplier(cfg)` fades
  the driven torque to `1 - d * damage_power_loss_max` (applied at the engine
  torque in `drivetrain.gd`).
- **Wheel-alignment pull** — `steer_target += damage.steer_bias(cfg)` adds a
  constant bias of `align_bias_sign * d * damage_steer_bias_max` (radians), so a
  damaged car drifts to one side. The direction is re-rolled per run.

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
`impact_max_loss_frac`, `impact_cooldown_s`, `damage_power_loss_max`,
`damage_steer_bias_max`, soft contacts (`bush_hp_loss`, `bush_drag_torque`,
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
hits** — flat loss, own cooldown independent of impacts, wreck at 0 — effect
scaling, bound/unbound wreck **keeping the car at 0 HP with its upgrades**,
persistence round-trip), `test_bush_field.gd` (side-based `drag_torque` sign +
scaling, enter/leave one-shot, min-speed gate), `test_spectator_damage.gd` (a
knockdown costs the car `spectator_hp_loss`, more than a bush), `test_car.gd` (contact monitor + power-scale
wiring, plus a **head-on collision costs HP** regression that drives the car into
an obstacle to guard the approach-speed keying above), `test_hud.gd` (health gauge), `test_wreck_screen.gd` (crash → orbit/menu →
`return_requested`).
