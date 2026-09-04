# Perks

**Source:** `scripts/perk_library.gd` (`PerkLibrary` — the authored catalogue), `scripts/save_manager.gd` (`Save.buy_perk` / `equip_perk` / `unequip_perk` / `owns_perk` — the purchase/equip mutators), `scripts/hub_shell.gd` (`HubShell._build_perks` — the shop/equip page), `scripts/game_config.gd` (`perk_max_equipped`, `@export_group("Roguelike Perks")`).

**Tests:** `tests/headless/test_perk_library.gd`, `tests/headless/test_save_manager.gd` (perk purchase byte-identical-on-refusal), `tests/headless/test_hub_shell.gd` (the PERKS page + its nav)

A straight lift from RR (`todo/roguelike-pivot.md` "Perks — a straight lift from
RR", stage 7 of `todo/roguelike-pivot-plan.md`): permanent, money-bought upgrades
gated behind lifetime-stat thresholds (`features/lifetime-stats.md`), equippable up
to a cap. Additive to TAPPA — there is no earlier equivalent.

## Three states, kept apart deliberately

1. **Locked** — `unlock.stat`'s lifetime counter hasn't crossed `unlock.threshold`
   yet. `PerkLibrary.is_unlocked(id, profile)` is false. Shown on the menu, named,
   saying what opens it — never hidden — but its row is unfocusable (same idiom as a
   locked region on `HubShell`'s REGION page).
2. **Purchasable** — the threshold IS crossed, but the perk is not yet bought.
   `PerkLibrary.is_purchasable(id, profile)` is true (implies `is_unlocked`). The
   menu offers a Buy row, priced at `PerkLibrary.price_of(id)`, disabled +
   `menu_nav_skip` when unaffordable — same idiom as the CAR page's Buy rows.
3. **Owned** — bought via `Save.buy_perk(id)`, recorded in
   `Save.profile[Save.KEY_BOUGHT_PERKS]`. `Save.owns_perk(id)` is true.

**Equipping is a fourth, SEPARATE axis from owning** —
`Save.profile[Save.KEY_EQUIPPED_PERKS]`, toggled by `Save.equip_perk` /
`Save.unequip_perk`, capped at `GameConfig.perk_max_equipped`
(`@export_group("Roguelike Perks")`; RR's own constant is `PERK_MAX_EQUIPPED = 3`).
An owned perk need not be equipped; the cap is enforced once, in `Save.equip_perk`,
never re-checked by a caller.

Every `buy_perk`/`equip_perk`/`unequip_perk` refusal leaves the profile
byte-identical — the same rule `buy_car`/`buy_boost_level`/`buy_engine_swap_unlock`
already follow (`save_manager.gd`'s "The meta shop" section): every precondition
(ownership, the unlock gate, the equip cap) is checked BEFORE `spend_money`, so a
caller never half-spends into a purchase that was going to be rejected anyway.

## The catalogue

`PerkLibrary.PERKS` — a flat `Array[Dictionary]`, each entry `{id, label,
description, price, unlock: {stat, threshold}}`, looked up through the shared
`Registry` helper (`scripts/registry.gd`) exactly like `CarLibrary`/`RallyLibrary`/
`RegionLibrary`. `unlock.stat` names a `LifetimeStats` id — the vocabulary a perk's
gate may use is exactly that table's keys
(`test_perk_library.gd -> test_every_unlock_stat_is_a_real_lifetime_stat` enforces
this against a typo).

A `Registry.Seam` (`PerkLibrary.override_for_test` / `reset`) lets a test swap in a
synthetic roster — per CLAUDE.md, a perk's price/threshold/existence is authored
data, so no test may pin the shipped table; `test_perk_library.gd` builds its own
fixture perks for every state-machine assertion and only reads the real `PERKS` for
the vocabulary contract above (iterating the whole table as opaque input is fine).

## No gameplay effects yet, and that is deliberate for this stage

RR's own perks each carry real in-run behaviour — a coin-magnet radius, a heal
rate, a damage-reduction fraction. **This stage builds the gate/purchase/equip state
machine only.** Every perk here is inert once equipped: a plain id sitting in
`Save.profile[Save.KEY_EQUIPPED_PERKS]` that nothing currently reads for gameplay.

When a real effect is wired, it should go through the SAME funnel `BoostLibrary`
already uses rather than a second mechanism —
`UpgradeLibrary.EFFECTS`/`UpgradeLibrary.apply` plus a car's `"boosts"` seam (see
`features/region-runs.md` → "In-run boosts"). A perk effect is permanent rather than
run-scoped, so it would need its own read path onto that seam (e.g. folding equipped
perks into `active_effects` alongside a car's picked boosts) rather than reusing
`RunSession`'s per-run boost list verbatim.

## The menu

`HubShell.View.PERKS`, reached from `View.MAIN`'s "Perks" row. One row per
`PerkLibrary.all()` entry: a locked row (unfocusable, names its gate via
`PerkLibrary.unlock_label`), a Buy row, or an Equip/Unequip row depending on state.
Keyboard + gamepad navigable via `MenuNav.attach`, per CLAUDE.md.
