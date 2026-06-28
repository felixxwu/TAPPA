# Upgrade Catalogue

`UpgradeLibrary` (`scripts/upgrade_library.gd`, `class_name UpgradeLibrary`) is
the catalogue of upgrade **items** — authored content (like `CarLibrary` /
`RallyLibrary`), not player state. The save profile holds the player side
(inventory counts + each `OwnedCar.installed_upgrades`, keyed by the stable `id`
here); this library defines what those ids mean and what each does to a fielded
car.

**Upgrades vs tuning:** upgrades are consumable items that change a car's
baseline and are **fully consumed when applied** — fitting a part uses it up for
good; it never returns to inventory (not on swap, and not when the car is wrecked).
Tuning (`features/tuning.md`, the lift) is free, reversible per-car config nudges.
This is the upgrades half.

## Catalogue

`const UPGRADES: Array[Dictionary]`, each an UpgradeDef: `id`, `name`, `slot`
(`engine` / `aero` / `suspension` / `brakes`, or `""` for consumables), `tier`
(reward-tier gating), `consumable`, and `effect` (config-field → delta/multiplier).
Current set: two engine kits (stage 1/2), an aero kit, a sport suspension kit, a
big brake kit, and the **repair kit** (the one consumable). The concrete part
list and exact numbers are a balance pass (deferred); these are single-purpose
defaults.

## Effect-application pipeline

A fielded car's live `Config.data` is built in a fixed order so effects compose
predictably:

1. **CarLibrary baseline** — `apply_car` copies the model's spec into `Config.data`.
2. **Installed upgrades** — `UpgradeLibrary.apply(owned_car, cfg)` walks
   `installed_upgrades` and applies each `effect` on top.
3. **Per-car tuning** — the player's tuning deltas (`features/tuning.md`).
4. **Damage multipliers** — power/steer degraded by HP fraction (`features/damage.md`).

`apply` is pure: it mutates only the passed-in live `cfg`, never the authored
`.tres`. `*_mult` keys multiply the baseline (`peak_torque`, `brake_torque`,
`suspension_stiffness`); additive keys add (`downforce_front` / `downforce_rear`).
`unlocks_*` keys are **flags**, skipped by `apply` — they gate tuning sliders, not
config. `aero_tuning_unlocked(car)` / `brake_bias_unlocked(car)` read those flags
so the tuning lift only exposes aero / brake-bias sliders when the matching kit
is fitted.

## Install / repair (in `Save`)

The slot policy and HP healing live in `Save` (it owns inventory + HP):

- **`Save.install_upgrade(instance_id, item_id)`** — fitting **fully consumes** the
  part: it leaves inventory for good and never comes back. Enforces **one upgrade
  per slot**: installing into an occupied slot replaces the incumbent, which is
  **scrapped, not refunded** (it was already consumed when it was applied).
  Consumables and unknown ids can't be slotted (rejected). There is **no uninstall**
  — a fitted part can only be replaced by fitting another into the same slot, and a
  **wrecked car keeps its parts fitted** (the car isn't destroyed — see
  [save-persistence.md](save-persistence.md)). The HQ upgrades menu confirms via a
  dialog before fitting, since the commitment is irreversible.
- **`Save.use_repair_kit(instance_id)`** — spends one repair kit to **fully
  restore** the car to its CarLibrary `max_hp`. The only way HP goes back up, and
  what revives a wrecked (0 HP) car. Offered at the tuning lift and at the
  car-select screen when a chosen car is too damaged to enter.

## Reward integration

Upgrades are the per-event reward (cars are per-rally). The reward draw picks an
`UpgradeDef` by `tier`, clamped by progress — that policy is reward-system logic
(`todo/reward-system.md`); this library just provides the tier-keyed pool and
`Save.add_item` grants it into inventory.

## Tests

`tests/headless/test_upgrade_library.gd` — catalogue validity (unique ids, known
slots, one consumable), lookups, effect application (multiplies/adds on a
baseline; empty list is a no-op), and the aero / brake-bias tuning gates.
Slot-replacement (incumbent scrapped, not refunded), consumable/unknown rejection,
repair-kit heal+clamp, and wreck consumption (parts not returned) are in
`test_save_manager.gd` (they need the Save profile). The HQ fit-confirmation flow is
in `test_menu_flow.gd`.
