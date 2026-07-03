# Upgrade Catalogue

`UpgradeLibrary` (`scripts/upgrade_library.gd`, `class_name UpgradeLibrary`) is
the catalogue of upgrade **items** — authored content (like `CarLibrary` /
`RallyLibrary`), not player state. The save profile holds the player side
(inventory counts + each `OwnedCar.installed_upgrades`, keyed by the stable `id`
here); this library defines what those ids mean and what each does to a fielded
car.

**Upgrades vs tuning:** upgrades are items that change a car's baseline. Applying
one consumes it from the unlocked pool and fits it to that car **for good** — it
never returns to the pool (not on swap, and not when the car is wrecked) — but a
fitted part can be **toggled on/off** in the upgrades menu
(`OwnedCar.disabled_upgrades`); only **enabled** parts contribute effects, and a
car keeps at most one enabled part per slot. Tuning (`features/tuning.md`, the
lift) is free, reversible per-car config nudges. This is the upgrades half.

## Catalogue

`const UPGRADES: Array[Dictionary]`, each an UpgradeDef: `id`, `name`, `slot`
(`engine` / `aero` / `chassis` / `brakes`, or `""` for consumables), `tier`
(reward-tier gating), `consumable`, and `effect` (config-field → delta/multiplier).
Current set: two engine kits (stage 1/2), an aero kit, a **weight-reduction** kit
(chassis slot, `mass_mult` 0.90), a big brake kit, and the **repair kit** (the one
consumable). The concrete part list and exact numbers are a balance pass
(deferred); these are single-purpose defaults.

## Effect-application pipeline

A fielded car's live `Config.data` is built in a fixed order so effects compose
predictably:

1. **CarLibrary baseline** — `apply_car` copies the model's spec into `Config.data`.
2. **Enabled upgrades** — `UpgradeLibrary.apply(owned_car, cfg)` walks
   `enabled_upgrades(owned_car)` (installed minus the menu-disabled ones) and
   applies each `effect` on top; a disabled part stays fitted but is inert.
3. **Per-car tuning** — the player's tuning deltas (`features/tuning.md`).
4. **Damage multipliers** — power/steer degraded by HP fraction (`features/damage.md`).

`apply` is pure: it mutates only the passed-in live `cfg`, never the authored
`.tres`. `*_mult` keys multiply the baseline (`peak_torque`, `brake_torque`,
`mass`); additive keys add (`downforce_front` / `downforce_rear`).
`unlocks_*` keys are **flags**, skipped by `apply` — they gate tuning sliders, not
config. `aero_tuning_unlocked(car)` / `brake_bias_unlocked(car)` read those flags
so the tuning lift only exposes aero / brake-bias sliders when the matching kit
is fitted.

> **Mass re-sync:** `car.gd.apply_car` copies the baseline `mass` onto the
> RigidBody, but upgrades run *after* it (step 2), so `apply_owned` re-assigns
> `mass = Config.data.mass` after `apply` — otherwise a weight-reduction kit would
> lighten the config but leave the physics body at its baseline weight.

## Effective stats (display + eligibility)

`effective_meta(owned_car, meta)` returns a copy of a car's CarLibrary entry with
the power-to-weight inputs (`peak_torque`, `mass`) adjusted by its installed
upgrades. It's pure (never touches the authored `CARS` entry) and is what makes a
fitted engine kit or weight reduction **change the displayed HP/kg AND a car's
rally eligibility**: the HQ stats panel calls
`CarLibrary.power_to_weight(UpgradeLibrary.effective_meta(owned, entry))`, and the
two player-car eligibility checks (`hq._has_eligible_car`,
`hq._build_eligible_lineup`) pass `effective_meta` into `RallyLibrary.is_eligible`,
so an upgrade can push a car into — or out of — a rally's `pw_min` / `pw_max` band.
The rival pool and reward-grant queries keep using the raw `CARS` entries (those
are unmodified roster cars, not the player's upgraded ones).

## Install / repair (in `Save`)

The slot policy and HP healing live in `Save` (it owns inventory + HP):

- **`Save.install_upgrade(instance_id, item_id)`** — applying consumes the part
  from the **unlocked pool** (inventory) for good and fits it to that car
  permanently. Applied parts **accumulate** on the car; at most one is **enabled**
  per slot, so a freshly-applied part arrives enabled and switches off any
  same-slot incumbent (which stays fitted, just disabled). Applying a part the car
  already carries is rejected (the pool copy is kept). Consumables and unknown ids
  can't be slotted (rejected). There is **no uninstall** — a fitted part can only
  be toggled off, never moved to another car, and a **wrecked car keeps its parts
  fitted** (the car isn't destroyed — see
  [save-persistence.md](save-persistence.md)). The HQ upgrades menu confirms via a
  dialog before applying, since the commitment is irreversible; the podium's
  reward reveal offers the same fit via its Apply/Keep choice
  (`features/reward-system.md`).
- **`Save.set_upgrade_enabled(instance_id, item_id, enabled)`** — the upgrades-menu
  toggle for an applied part. Free, instant and reversible; enabling a part
  disables its same-slot siblings (`OwnedCar.disabled_upgrades` holds the
  toggled-off ids). `UpgradeLibrary.enabled_upgrades(car)` /
  `is_enabled(car, id)` are the read side every effect/gate consumer uses.
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
baseline incl. `mass_mult`; empty list is a no-op), `effective_meta`
(lightens/empowers a meta copy without mutating the source), and the aero /
brake-bias tuning gates. `test_rally_library.gd` covers an installed upgrade
qualifying / disqualifying a car for a rally's pw band; `test_car_library.gd`
covers `apply_owned` re-syncing the RigidBody mass after a weight-reduction kit.
Disabled parts being inert everywhere (config, effective stats, tuning gates) is
covered there too. Same-slot exclusivity (applying/enabling a part disables the
incumbent instead of scrapping it), duplicate-apply rejection, the
`set_upgrade_enabled` toggle, consumable/unknown rejection, repair-kit heal+clamp,
and wreck consumption (parts not returned) are in `test_save_manager.gd` (they
need the Save profile). The HQ apply-confirmation flow and the upgrades-menu
toggle are in `test_menu_flow.gd`; the podium's Apply/Keep reward choice is in its
podium-sequence test there.
