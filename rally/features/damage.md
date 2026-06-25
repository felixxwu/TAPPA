# Damage Model

**Source:** `scripts/damage_model.gd` (`DamageModel`, a `RefCounted` helper owned
by `car.gd` like `Drivetrain`). See the implementation brief in
[../todo/damage-model.md](../todo/damage-model.md) and the design intent in
`gameplay.md` › *Damage model*.

Each fielded car has a depleting **HP pool**. Impacts drain it during a run, the
car's handling and power degrade as HP falls, and at 0 HP the car is **wrecked**
(run DNF; a fielded car is destroyed and its upgrades returned to inventory). HP
only ever goes down in-run — a repair kit (Save) is the only way it climbs back.

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
layer ([../todo/rally-event-flow.md](../todo/rally-event-flow.md)) re-fields it
from the OwnedCar (stored HP + instance id) when a car is taken to the line.

## Impact → HP loss

`car.gd` enables `contact_monitor` (+ `max_contacts_reported`) and reads
per-contact impulses in `_integrate_forces`. Only contacts against bodies in the
`DamageModel.OBSTACLE_GROUP` (`"obstacle"`) group count — trees/bushes (and the
planned signs) tag their collision body with it in `billboard_field.gd`, so the
ground/road never chip HP. Each qualifying contact calls `register_impact()`:

```
hp_loss = max(0, impulse - impact_min_impulse) * hp_per_impulse
```

`hp_loss_for_impulse()` is a pure static so the conversion is unit-testable.
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
  returns its installed upgrades to inventory, then removes the instance.
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

`impact_min_impulse`, `hp_per_impulse`, `damage_power_loss_max`,
`damage_steer_bias_max`, `hud_hp_enabled`, `hud_low_hp_warn_frac`. Per-car
`max_hp` is CarLibrary metadata, **not** a `GameConfig` field. Tuning numbers are
placeholders pending playtest (the mechanism is fixed, the values are not).

## Tests

`tests/headless/test_damage_model.gd` (impulse→HP, effect scaling, bound/unbound
wreck, upgrade return, immortal, persistence round-trip),
`test_car.gd` (contact monitor + power-scale wiring), `test_hud.gd` (HP gauge).
