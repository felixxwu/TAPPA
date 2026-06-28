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
| `immortal` | the starter car's anti-soft-lock floor: no depletion, no effects, never wrecked |
| `instance_id` | OwnedCar binding; **-1 = unbound** (free-roam / dev — never touches `Save`) |
| `align_bias_sign` | ±1 steer-pull direction, re-rolled each run via `reroll_bias()` |

`field(max_hp, hp, immortal, instance_id)` configures all of the above for a run.
`car.gd` calls it (unbound, full HP) from `apply_car`; the future rally/Start-line
layer ([rally-session.md](rally-session.md)) re-fields it
from the OwnedCar (stored HP + instance id) when a car is taken to the line.

## Impact → HP loss

`car.gd` enables `contact_monitor` (+ `max_contacts_reported`) and, in
`_integrate_forces`, reads the body's travel speed and the per-tick contacts. Only
contacts against bodies in the `DamageModel.OBSTACLE_GROUP` (`"obstacle"`) group
count — trees/bushes (and the planned signs) tag their collision body with it in
`billboard_field.gd`, so the ground/road never chip HP. Each qualifying contact
calls `register_impact(speed, …)` with the **speed the car was travelling at**:

```
# v = impact speed in km/h (car speed × 3.6); 0 below impact_min_speed_kmh.
hp_loss = impact_ref_hp_loss * (v² - impact_min_speed_kmh²)
                             / (impact_ref_speed_kmh² - impact_min_speed_kmh²)
```

A **square law** (kinetic energy): a hit at the reference speed
(`impact_ref_speed_kmh`, ~60 km/h) costs `impact_ref_hp_loss` (~200 HP), so with
per-car max HP of 800-1100 most cars survive **4-5 moderate hits**; the square
then makes a 20 km/h hit cost only a small fraction of that, so the car **barely
takes damage at low speed**. The post-hit cooldown (below) means a crash registers
on its FIRST contact, so this is the approach speed, not a decelerated one.
`hp_loss_for_speed()` is a pure static so the conversion is unit-testable.

Two guards stop a single crash from instantly wrecking the car (cars should survive
2-3 big hits):
- **Per-hit cap** — the loss is clamped to `impact_max_loss_frac` of max HP, so no
  one impact can take more than ~1/3 of the bar.
- **Post-hit cooldown** — after a damaging hit, impacts are ignored for
  `impact_cooldown_s`. The chassis contacts an obstacle *every physics tick* while
  it's pinned/tumbling, so without this one crash would register dozens of hits;
  the cooldown groups a whole crash into a single hit. `car.gd._physics_process`
  decays it via `damage.tick_cooldown(delta)`.

A hit that costs HP emits `damaged(hp_loss, contact_point)` for the HUD/audio cue.

## Effects (scale with the damage fraction `d = 1 - hp/max_hp`)

Read each physics tick in `car.gd`; both are 0 at full HP and for the immortal car:

- **Power loss** — `drivetrain.power_scale = damage.power_multiplier(cfg)` fades
  the driven torque to `1 - d * damage_power_loss_max` (applied at the engine
  torque in `drivetrain.gd`).
- **Wheel-alignment pull** — `steer_target += damage.steer_bias(cfg)` adds a
  constant bias of `align_bias_sign * d * damage_steer_bias_max` (radians), so a
  damaged car drifts to one side. The direction is re-rolled per run.

## Wreck at 0 HP

`apply_loss()` clamps HP at 0 and, on a non-immortal car, calls `_wreck()`:
- A **fielded** car (`instance_id >= 0`) calls `Save.wreck_car(instance_id)` —
  removes the instance; its installed upgrades are gone with it (parts are fully
  consumed on apply, so nothing is returned to inventory).
- `wrecked` is emitted either way; `car.gd` re-emits it as the car-level `wrecked`
  signal for the rally/menu layer (sibling to `StageManager.stage_completed`).
- In **free-roam** (unbound) there is no DNF flow yet, so `car.gd` heals the car
  to full and respawns it at the start so play continues.

The immortal starter floors at 1 HP and is never wrecked.

## In-run HUD (see [hud.md](hud.md))

`hud.gd` reads `car.damage` each frame: a colour-graded **HP bar** (`HPBar`,
green → amber → red), a low-HP **warning pulse** below `hud_low_hp_warn_frac`, and
a red **impact flash** (`ImpactFlash`) sized to each HP-losing hit. The gauge is
hidden when `hud_hp_enabled` is off or for the immortal starter.

## Config knobs (`GameConfig`, *Damage* group)

`impact_min_speed_kmh`, `impact_ref_speed_kmh`, `impact_ref_hp_loss`,
`impact_max_loss_frac`, `impact_cooldown_s`, `damage_power_loss_max`,
`damage_steer_bias_max`, `hud_hp_enabled`, `hud_low_hp_warn_frac`. Per-car
`max_hp` is CarLibrary metadata, **not** a `GameConfig` field. Tuning numbers are
placeholders pending playtest (the mechanism is fixed, the values are not).

## Tests

`tests/headless/test_damage_model.gd` (speed→HP + the 60/20 km/h calibration, the per-hit cap + post-hit
cooldown grouping a crash into one hit / needing several hits to wreck, effect
scaling, bound/unbound wreck, upgrade return, immortal, persistence round-trip),
`test_car.gd` (contact monitor + power-scale wiring), `test_hud.gd` (HP gauge).
