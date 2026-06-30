# Upgrade Catalogue — implementation spec  ✅ DONE

> Status: **DONE (core).** `UpgradeLibrary` (`scripts/upgrade_library.gd`)
> holds the authored `UPGRADES` catalogue (engine/aero/suspension/brakes kits +
> the repair kit), the pure `apply(owned_car, cfg)` effect pipeline (step 2), and
> the aero / brake-bias tuning gates. `Save` now enforces one-upgrade-per-slot in
> `install_upgrade` (replaces + returns the incumbent; rejects consumables/unknown
> ids) and adds `use_repair_kit(instance_id, heal_amount)` (heal clamped to
> max_hp). Tests: `tests/headless/test_upgrade_library.gd` + slot/repair/wreck
> coverage in `test_save_manager.gd`. Doc: `features/upgrade-catalogue.md`.
> **Still open / deferred:** the full part list per slot/tier and exact `effect`
> numbers (balance pass), the `repair_kit_hp` GameConfig tunable (caller passes
> the heal amount today), and the reward-draw policy (owned by
> `todo/reward-system.md` — this spec only provides the tier-keyed pool).
>
> Implementation brief for the upgrade
> **items** in `gameplay.md` › *Tuning & upgrades* and *Progression & rewards* —
> the inventory parts (and the repair kit) won as rewards and fitted to cars.
> Follow the config-first convention (`CLAUDE.md`): every upgrade effect resolves
> into `GameConfig` / `CarLibrary` values, never hardcoded in flow logic. Update
> the relevant `features/*.md` doc and add tests in the same piece of work.
>
> **Distinguish from tuning.** *Tuning* (in `todo/menus.md` › tuning lift) is
> free, reversible config nudges per car. *Upgrades* are consumable inventory
> items that change a car's baseline and are only recovered when the car is
> wrecked. This spec is the upgrades half.

## Goal

Define **what upgrade items exist**, the data that describes each one's effect,
and how installing one modifies a car — slotting cleanly between the CarLibrary
baseline, per-car tuning, and the damage multipliers so the order of application
is unambiguous.

## Current state (measured from the code)

- **Items are pure save data; the catalogue is authored content.** The save spec
  already models the player side: `inventory: { item_id -> count }`,
  `OwnedCar.installed_upgrades: Array[String]`, and the mutators
  `Save.add_item / consume_item / install_upgrade / uninstall`
  (`todo/save-persistence.md`). **This spec defines the `item_id` space and each
  item's effect** — nothing about *what an upgrade does* exists yet.
- **The config knobs upgrades target already exist** in `GameConfig`
  (`scripts/game_config.gd`): power via `peak_torque` (set per-car by
  `apply_car`, `car.gd:267`); aero via `downforce_front` (`:76`) /
  `downforce_rear` (`:80`); brakes via `brake_torque` (`:66`); suspension via
  `suspension_stiffness` (`:115`) / `suspension_travel` (`:112`). Upgrades nudge
  these the same way `apply_car` already writes `Config.data` at runtime.
- **No catalogue, no install logic, no effect application** exists today.

## The effect-application pipeline (the key design point)

A fielded car's live `Config.data` is built in a **fixed order** so effects
compose predictably:

```
1. CarLibrary baseline   apply_car(index) copies the model's spec → Config.data   (car.gd:253,267)
2. Installed upgrades    each installed item applies its effect on top            (this spec)
3. Per-car tuning        the player's tuning deltas (grip/brake bias/aero)        (todo/menus.md)
4. Damage multipliers    power/steer degraded by current HP fraction              (features/damage.md)
```

Steps 2–4 are runtime modifications layered on the step-1 baseline; none mutates
the authored `.tres` (mirrors `apply_car`'s existing `Config.data` mutation).
An **aero upgrade gates step 3's aero tuning** — `downforce_*` sliders are only
live when the aero kit is installed (`todo/menus.md` › tuning-lift knobs).

## Catalogue data model (proposed)

**Mirror `CarLibrary` / `RallyLibrary`: an `UpgradeLibrary`
(`scripts/upgrade_library.gd`, `class_name UpgradeLibrary`) holding
`const UPGRADES: Array[Dictionary]`** *(decided — follows the same in-code
choice settled for the rally roster)*.

```
UpgradeDef
  id: String          # stable item_id (save inventory + installed_upgrades key on this)
  name: String        # display name (reward reveal + inventory overlay)
  slot: String        # "engine" | "aero" | "chassis" | "brakes"  (consumable items below have no slot)
  tier: int           # reward-tier gating; higher = rarer/better
  effect: Dictionary  # config-field -> delta/multiplier (see below)
  consumable: bool     # true for repair kit: spent on use, not slotted

# effect entries map to GameConfig fields, e.g.
#   engine     -> { "peak_torque_mult": 1.15 }
#   aero kit   -> { "unlocks_aero_tuning": true, "downforce_front": +0.2, "downforce_rear": +0.2 }
#   chassis    -> { "mass_mult": 0.9 }   # weight reduction
#   brakes     -> { "brake_torque_mult": 1.2, "unlocks_brake_bias": true }
```

`UpgradeLibrary.apply(owned_car, cfg)` walks `installed_upgrades` and applies each
item's `effect` to `cfg` (step 2 above). Pure and testable.

## Slot model (decided)

**One upgrade per slot, tier-based** *(decided)*: a car holds at most one
`engine` / `aero` / `suspension` / `brakes` upgrade. Installing into an occupied
slot **replaces** the incumbent, returning the old item to inventory. Rationale:
keeps effects bounded (no stacking ten engine kits) and the stats panel readable.
The alternative — free stacking — is noted in *Open questions*.

Install/consume semantics (per `gameplay.md`):
- **Installing consumes** the item from inventory (`Save.consume_item` +
  `Save.install_upgrade`).
- There is **no free uninstall** — installed parts come back **only when the car
  is wrecked** (`Save.wreck_car` returns `installed_upgrades` to inventory).
  *(If we want a manual uninstall later, it's a `Save.uninstall` call; left out
  by default to preserve the "commitment" feel.)*

## The repair kit (the one consumable)

- `consumable: true`, **no slot**. Using it restores HP to the selected car —
  the **only** way HP goes back up (`gameplay.md` › *Damage*).
- Applied from the inventory overlay (`todo/menus.md` overlay 9) at the tuning
  lift: `Save.consume_item("repair_kit")` then heal `OwnedCar.hp` (clamped to
  `max_hp`). How much it heals is a `GameConfig` tunable (`repair_kit_hp` — full
  vs partial restore is a balance call, deferred).
- Bridges to `features/damage.md`, which owns HP; this spec just defines the
  item.

## Reward integration

- Upgrades are the **per-event** reward; cars are the **per-rally** reward
  (`gameplay.md`). The reward draw picks an `UpgradeDef` by `tier`, **clamped by
  progress** (rallies-completed ceiling) so early wins can't yield top-tier parts.
- The reward tier function is **reward-system logic** (`todo/reward-system.md`); this
  spec only provides the `tier`-keyed catalogue to draw from and `add_item` to
  grant into inventory.
- The **reward reveal** rig (`todo/menus.md` rig 5) shows the granted item.

## Dependencies

- **Save / persistence** (`todo/save-persistence.md`) — owns inventory,
  `installed_upgrades`, and the install/consume/uninstall mutators. This spec
  defines the `item_id`s they key on (the save spec flags "upgrade items need
  stable `item_id`s").
- **Damage model** (`features/damage.md`) — the repair kit heals its HP; wreck
  returns installed upgrades here. Tightly paired.
- **Tuning** (`features/tuning.md`) — the aero/brake "unlock tuning" flags this
  catalogue sets gate `features/tuning.md`'s aero/brake-bias sliders; that spec owns
  the new brake-split knob. Pipeline step 2 (here) runs before step 3 (tuning).
- **CarLibrary metadata prerequisite** — stable `id`s for install/inventory keys.
- **Consumed by** `todo/menus.md` — the inventory overlay (browse/install/use),
  the tuning lift (install point + aero/brake gating), and the reward reveal.

## Testing

Headless GUT tests (`tests/headless/`, mirroring `test_car_library.gd`):
- **Catalogue validity:** all `id`s unique; every non-consumable has a known
  `slot`; the repair kit is `consumable` with no slot.
- **Effect application:** `UpgradeLibrary.apply` produces the expected `cfg`
  deltas/multipliers on top of a CarLibrary baseline; order is baseline → upgrade
  (step 1 → 2).
- **Slot replacement:** installing a second `engine` upgrade replaces the first
  and returns it to inventory; counts are conserved.
- **Aero gating:** `downforce_*` tuning is locked until an aero kit is installed.
- **Repair kit:** consuming it raises `OwnedCar.hp`, clamped to `max_hp`, and
  decrements the inventory count.
- **Wreck round-trip:** with the damage/save tests, a wrecked car's installed
  upgrades reappear in inventory.

## Out of scope / open questions

- **Slot model** — **decided: one-per-slot, tiered** (installing replaces +
  returns the incumbent). See *Slot model*.
- **Full upgrade list** — the concrete set of parts per slot and per tier, and
  each one's exact `effect` numbers (balance pass, deferred).
- **Manual uninstall** — left out by default (parts return only on wreck); add a
  `Save.uninstall` path if playtesting wants reversibility.
- **Repair-kit strength** — full vs partial HP restore (`repair_kit_hp`).
- **Multiple effect fields per upgrade** — whether one part can touch several
  knobs (e.g. a "race kit" doing power + brakes); the `effect` dict already
  supports it, but keep early parts single-purpose for legibility.
- **Tuning spec** — the free/reversible tuning half (grip balance, brake bias,
  aero balance) now has its own spec, **`features/tuning.md`** (resolved — it grew).
  That spec owns the **new front/rear brake-split knob** the brakes upgrade's
  `unlocks_brake_bias` flag gates; this catalogue just sets the flag. Pipeline
  step 3 (tuning) runs after step 2 (upgrades).
