# Perks

**Source:** `scripts/perk_library.gd` (`PerkLibrary` — the authored catalogue + `equipped_effects`), `scripts/save_manager.gd` (`Save.buy_perk` / `equip_perk` / `unequip_perk` / `owns_perk` — the purchase/equip mutators; `Save.heal_car`), `scripts/hub_shell.gd` (`HubShell._build_perks` — the shop/equip page), `scripts/game_config.gd` (`perk_max_equipped`, `@export_group("Roguelike Perks")`), `scripts/upgrade_library.gd` (the `EFFECTS` perk rows + `_reseed_globals`), `scripts/world.gd` (`_field_car` — where an equipped perk reaches the car).

**Tests:** `tests/headless/test_perk_library.gd`, `tests/headless/test_save_manager.gd` (perk purchase byte-identical-on-refusal), `tests/headless/test_hub_shell.gd` (the PERKS page + its nav), `tests/headless/test_card_carousel.gd` (the carousel widget itself)

A straight lift from RR (`todo/roguelike-pivot.md` "Perks — a straight lift from
RR", stage 7 of `todo/roguelike-pivot-plan.md`): permanent, money-bought upgrades
gated behind lifetime-stat thresholds (`features/lifetime-stats.md`), equippable up
to a cap. Additive to TAPPA — there is no earlier equivalent.

## Three states, kept apart deliberately

1. **Locked** — `unlock.stat`'s lifetime counter hasn't crossed `unlock.threshold`
   yet. `PerkLibrary.is_unlocked(id, profile)` is false. Shown on the menu, named,
   saying what opens it — never hidden — but its card is disabled/unconfirmable (same
   idiom as a locked region on `HubShell`'s REGION page — see
   [card-carousel.md](card-carousel.md) for how a disabled `CardCarousel` card differs
   from the old `disabled` + `menu_nav_skip` `Button`).
2. **Purchasable** — the threshold IS crossed, but the perk is not yet bought.
   `PerkLibrary.is_purchasable(id, profile)` is true (implies `is_unlocked`). The
   menu offers a Buy card, priced at `PerkLibrary.price_of(id)`, disabled when
   unaffordable — same idiom as the CAR page's Buy cards.
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
description, price, unlock: {stat, threshold}, effect_fields}`, looked up through the shared
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

## What each perk actually does

Wired in one pass after collectables landed, per `todo/roguelike-pivot.md` decision
51 — a perk whose authored description promises an effect it doesn't have is a
visible defect, and `coin_magnet` could not be written before there were coins.

**There is exactly one mechanism, and it is the one `BoostLibrary` already uses.**
Each catalogue entry carries `effect_fields` — `{EFFECTS key: GameConfig field}`,
the same shape as a boost's — and `PerkLibrary.effect_for(id)` reads those fields
live off `Config.data`, so a designer's retune lands on the next stage boot with no
code change. `PerkLibrary.equipped_effects(profile)` returns them in
`UpgradeLibrary.active_effects`' own `{"id", "effect"}` shape, and
`world.gd::_field_car` appends them to the fielded car's `"boosts"` list next to the
run's picked boosts. Decision 51 requires exactly this ("do not build a parallel
modifier path"), so a new perk adds an `EFFECTS` row and a `GameConfig` field —
never a bespoke read at some call site.

| Perk | `EFFECTS` key → config field | Who reads the field |
| --- | --- | --- |
| Coin Magnet | `coin_pickup_radius_mult` → `coin_pickup_radius_m` | `CoinField._timed_physics_process`, live every tick |
| Self Healing | `damage_regen_set` → `damage_regen_hp_per_s` | `DamageModel.regen`, on the damage tick |
| Rubber Body | `impact_damage_mult` → `impact_ref_hp_loss` | `DamageModel.hp_loss_for_speed` |
| Trail Blazer | `fast_bonus_money_mult` → `run_fast_bonus_money` | `RegionRunMode.stage_money` |
| Lucky Coins | `coin_count_mult` → `coins_per_stage` | `CoinLayout.plan`, via `coin_layout_params` |
| Iron Will | `target_pace_add` → `run_target_pace_base` | `RegionRunMode.target_pace` |
| Road Scholar | `stage_money_base_add` → `run_stage_money_base` | `RegionRunMode.stage_money` |

Two descriptions were REWORDED with the wiring rather than bent into the code.
`iron_will` used to promise "a head start on the clock" — there is no run-wide clock
to start ahead of, since the timer is a per-stage target (decision 11) — and
`road_scholar` used to promise money on "the opening stage", which would have needed
a call-site branch, i.e. the parallel path decision 51 rules out. Both now say what
the field they move actually does.

### Why every perk row carries `reseed`

Perks differ from boosts in WHAT they target. Every pre-existing `EFFECTS` row moves
a per-car stat (mass, grip, shift time, brakes, drag), and pipeline step 1 —
`car.gd::apply_car` — re-seeds those from the `CarLibrary` baseline before
`UpgradeLibrary.apply` runs, which is what makes a `mult` row safe to apply on every
stage boot. **Perk rows target global tunables that have no such re-seed.** Nothing
calls `Config.reset()` between stages, so without help a coin radius multiplied on
stage 1 would be multiplied again on stage 2, and un-equipping the perk would never
give the authored number back at all.

`UpgradeLibrary._reseed_globals` closes that: before any effect is applied, every
row flagged `reseed` has its config fields restored from the PRISTINE authored
baseline (`Config.authored_value`, backed by `Config._authored` — the loaded `.tres`
that nothing mutates). It runs unconditionally, because "nothing equipped" is
precisely the case that has to put the authored number back.

### The self-heal's two seams

`damage_regen_hp_per_s` is a LIVE field — `0.0` on the authored baseline, written
only by the funnel — so `DamageModel.regen` knows nothing about perks; it reads a
config knob like every other damage rule. It heals HP only: `wheel_toe` stays bent,
so a self-healing car still has a reason to take the between-stage repair.

Persisting it needed one more change. `world.gd` used to clamp the stage's HP delta
at zero before reporting it, which would have thrown away any stage that ended with
MORE HP than it started. The delta is now signed, and
`RunSession.report_event_result` routes a negative one to `Save.heal_car` (capped at
the car's authored `max_hp`). No lifetime stat is written for a heal —
`DAMAGE_TAKEN` gates a perk unlock, so letting it run backwards could un-unlock a
perk the player had already earned.

## The menu

`HubShell.View.PERKS`, reached from `View.MAIN`'s "Perks" card. One `CardCarousel` card
per `PerkLibrary.all()` entry ([card-carousel.md](card-carousel.md)) — a locked card
(disabled, names its gate via `PerkLibrary.unlock_label`), a Buy card, or an
Equip/Unequip card depending on state. Keyboard + gamepad navigable via `MenuNav.attach`
(the carousel is one focusable unit that owns its own left/right — see
[menu-navigation.md](menu-navigation.md) → *A widget that owns its own left/right*), per
CLAUDE.md.
