# The effects funnel (`UpgradeLibrary`)

**Source:** `scripts/upgrade_library.gd` (`class_name UpgradeLibrary`)

**Tests:** `tests/headless/test_upgrade_library.gd`

`UpgradeLibrary` **is not a catalogue.** It is the MECHANISM that turns a car's fitted parts
into config. The parts themselves are `BoostLibrary.CATALOGUE` entries found as free-roam loot
at a level ([loot.md](loot.md)); `LootRules.fielded(owned)` writes a car's parts into its
`boosts` list (plus `swapped_engine` / `drivetrain_override` for engines and drivetrain kits)
on the duplicate that fields it.

What it owns:

| Piece | What it owns |
| --- | --- |
| `EFFECTS` | The descriptor table saying what each effect key DOES |
| `_reseed_globals` | Restores every `reseed` row's fields from the authored baseline, first thing |
| `_cfg_set` | The one loud writer onto a live `GameConfig` |
| `apply` | Walks the active effects and writes them (pipeline step 2) |
| `stock_drive_mode` / `resolve_drive_override` | The drive-mode resolver, which never depended on the catalogue |

**Distinguish from TUNING.** Tuning ([tuning.md](tuning.md)) is free, reversible per-car
config nudges, and is UNGATED on every axis now (decision 24) — the aero gate that used to
live here went with the aero part.

## The active-effect seam

```gdscript
static func active_effects(owned_car: Dictionary) -> Array:
	return owned_car.get("boosts", [])
```

Entries are `{"id": String, "effect": Dictionary}` — the same `effect` sub-dict shape the
authored parts used, which is why every consumer below was unchanged by the swap.

**One writer fills it:** `LootRules.fielded(owned)`, from the car's fitted `parts`, onto a
DUPLICATED owned-car dict so it never reaches the saved profile. The seam is
`UpgradeLibrary.EFFECTS` + a car's `boosts` list; do not build a parallel modifier path.

**Why a plain key on the car dict** rather than a query into another object: it keeps the
funnel pure and testable with no session standing up, it is where `tuning` and
`swapped_engine` already live, and it means a new source of effects WRITES the key rather
than re-plumbing five call sites.

## The `EFFECTS` table

The single source of truth for what each effect key does, so adding an effect means adding one row. Each row carries:

| Field | Meaning |
| --- | --- |
| `field` | The CAR-META spelling of the quantity (a key on the car dict) |
| `cfg_fields` | The LIVE-CONFIG spelling(s), when the two vocabularies diverge |
| `op` | `mult` / `add` / `set` / `mult_floor` / `install_induction` / `write_fields` |
| `reseed` | Whether the row's config fields are restored from the authored baseline first |
| `enable` | Induction-only: the config flag to switch on |
| `floor_field` | `mult_floor`-only: the GameConfig field the clamp floor is read from (`UpgradeLibrary._floor_value`) |

**A `mult`/`add` row may target more than one config field, under a different name.**
`field` is the meta spelling; `cfg_fields` overrides for a row whose two vocabularies
diverge — a car's rubber is one `tire_compound` on its meta but a per-axle
`wheel_friction_slip_front` / `_rear` pair on the config. Keeping that mapping as table
DATA is what stops `apply` growing a branch per effect. `_cfg_fields(desc)` falls back to
`[field]` when the two coincide.

**Every name in a row must EXIST, and nothing enforces that at runtime.** An effect naming
something nobody declares applies silently and does nothing — the effect reads as active,
no gameplay test fails. Two guards catch it instead:

- `test_upgrade_library.gd::test_every_effect_target_names_a_real_config_property` — every
  `cfg_fields` / `enable` / `clears` name is a real `GameConfig` property.
- `apply` itself `push_error`s on an effect key with **no `EFFECTS` row** — the other half
  of the same failure, and the one `_cfg_set` cannot catch because the value never reaches
  it. Found by the small-model-readiness loop (round 041), where a wet-weather tyre shipped
  with the `@export`, the registry row and the blend arm all correct and no rain grip at
  all. `test_boost_library.gd` asserts its catalogue against the table for the same reason.

## Effect-application pipeline

A fielded car's live `Config.data` is built in a fixed order so effects compose
predictably:

0. **Global reseed** — `_reseed_globals(cfg)`, the first thing `apply` does. See below.
1. **CarLibrary baseline** — `car.gd::apply_car` copies the model's spec into
   `Config.data`, and `_apply_physics_spec` re-seeds the per-car fields effects multiply.
2. **Active effects** — `apply(owned_car, cfg)` walks `active_effects` and applies each
   `effect` on top.
3. **Per-car tuning** — the player's tuning deltas ([tuning.md](tuning.md)).
4. **Damage** — power and steering degraded by HP fraction ([damage.md](damage.md)).

`apply` is pure: it mutates only the passed-in live `cfg`, never the authored `.tres`.
`mult` keys multiply the baseline, `add` keys add, `set` keys **replace** it outright with
an absolute figure, `install_turbo` / `install_supercharger` switch their induction flag on
(they stack — [forced-induction.md](forced-induction.md)), and `install_nitrous` (`write_fields`) straight-splats
its fields with no enable flag — `has_nitrous()` reads the values themselves, so a zero
gain/tank already reads as "not fitted" ([nitrous.md](nitrous.md)).

> **Mass re-sync:** `apply_car` copies the baseline `mass` onto the RigidBody, but effects
> run *after* it (step 2), so `apply_owned` re-assigns `mass = Config.data.mass` after
> `apply` — otherwise a weight effect would lighten the config and leave the physics body
> at its baseline weight.

### The reseed pre-pass, and why only some rows carry it

Every row today targets a **per-car** field, and step 1 re-seeds those from the CarLibrary
baseline before `apply` runs, so a `mult` always lands on a fresh baseline. A row that
writes a GLOBAL tunable on the long-lived `Config.data` gets no such re-seed: it must carry
`reseed: true`, and `_reseed_globals` restores its field from the authored baseline
(`Config.authored_value` — see [configuration.md](configuration.md)) before anything is
applied. No row needs it today.

## Drivetrain conversion

The one piece of the old slot model that survives whole, because it never depended on the
catalogue.

- `stock_drive_mode(owned_car)` — the layout the car was built with, always free to return
  to.
- `resolve_drive_override(owned_car)` — the player's chosen layout (0/1/2), or `-1` for
  "use stock". A bare range check against `Drivetrain.DriveMode.values()`, no purchase
  gate. The single resolver used by physics (`car.gd`).

**In free roam a conversion is a found drivetrain kit.** `LootRules.fielded` writes the kit's
layout as `drivetrain_override` on the duplicate a car is fielded with, never on the persisted
car; removing the kit returns the car to `stock_drive_mode`.

## What is gone, so you stop looking for it

`UPGRADES`, `SLOTS`, `options_for`, `auto_build_plan`, `max_potential_meta`, the rally /
prerequisite gates, the `Save` buy/install paths, the upgrades grid and reveal, and the
`flag` op (`apply`'s `_:` arm still absorbs an unknown op). `OwnedCar.installed_upgrades` /
`disabled_upgrades` are gone from the profile too — see
[save-persistence.md](save-persistence.md).

## Tests

`tests/headless/test_upgrade_library.gd` covers the table's contract (every target name is
a real `GameConfig` property; every fixture-authored effect key has a row), each `op` arm
against a synthetic effect set, and the drive-mode resolver.

Per CLAUDE.md, none of them pin a magnitude: the fixtures author their own effect values
(`tests/headless/upgrade_fixtures.gd`), and the shipped `GameConfig` numbers the real
parts read are tunables no test may assert.
