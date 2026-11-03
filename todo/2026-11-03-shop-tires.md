# Shop: upgrades / tires / engine swaps tabs, and fitted tires

Status: unlock points, stock-tire behaviour and sub-menu shape settled; numbers and card text still open. Dependencies: none (the "Shop" rename + "N applied, M unlocked" subtext already landed in `rest_stop_page.gd` → `_build_main` / `_shop_text`).

## Goal

The checkout Shop page (`rest_stop_page.gd` → `_build_parts`, `View.PARTS`) gets three sub-menus:

1. **Upgrades**: today's boost parts (`BoostLibrary.CATALOGUE` items). Exists.
2. **Tires**: new.
3. **Engine swaps**: today's `engine_swap:<id>` parts (`LootRules.is_engine`). Exists.

Today `_build_parts` lists every part kind in one flat card list, so this is mostly a split by kind, plus the new tire kind.

## New: tires

Four compounds: **stock** (what the car ships with), **road**, **gravel**, **snow**.

- Unlock points (decided): **gravel** from the start, **road** at The Dunes (`RegionLibrary` id `greece`, order 1), **snow** in The Alps (id `snow`, order 4).
- Bought like upgrades: they go into `LootRules.ring_tables` (the per-ring sale tables, like engine swaps and drivetrain kits) and are priced in `LootRules.price`.
- Only one tire fitted at a time, like engine swaps: extend the "switching one on switches the other off" rule in `LootRules.toggled` (currently `is_engine` / `is_drivetrain` pairs) with an `is_tire` kind.
- Fitting writes through `LootRules.fielded` onto the owned-car dict (as `swapped_engine` / `drivetrain_override` do), and `Car.apply_owned` applies it.
- **Stock**: owned from the start for every car, and is "no override". It is a real card the player can re-select to go back to stock (decided).

## What exists to build on

- The tire physics is already surface-aware: `Drivetrain.surface_tire_params` resolves μ per contact, blending `GameConfig.TIRE_SURFACE_AXES` (`tire_snow_grip_mult` on the snow channel, `tire_tarmac_grip_mult` on the tarmac channel) with the flat `tire_grip_mult` via `GameConfig.tire_surface_mult_for`. See `features/drivetrain-and-tires.md` ("Surface-specialised compounds").
- Road / gravel / snow compounds can probably be expressed as authored rows of those same effect keys (`UpgradeLibrary.EFFECTS`: `tire_grip_mult`, `tire_snow_grip_mult`, `tire_tarmac_grip_mult`). Check that gravel needs no new axis: the flat term is documented as the gravel (neutral) value.
- Caveat: that doc and `UpgradeLibrary` describe the roguelike-era `tires` upgrade slot (Snow Tires / Race Tires). Verify what of it still runs in free roam (`BoostLibrary` has no tire entries) before reusing it. A new axis would be four edits (see the warning above `TIRE_SURFACE_AXES` in `game_config.gd`).

## Open questions (to settle with the user)

- Prices and grip numbers go in `config/game_config.tres` / the authored tables, not scripts. No tests may pin them.
- Tire card icon, and a dedicated tire name/description in `LootRules.card_text`.
- Decided: the Shop is a sub-menu of three cards (Upgrades / Tires / Engine swaps), each opening its own card page. Keyboard and gamepad nav is mandatory (`MenuNav.attach`, plus a nav test).
- Save format: owned tires live in the car's `parts` array like the other parts, so probably no schema change. Confirm against `Save.set_car_parts`.

## Docs / tests to touch when implemented

- `features/loot.md`, `features/drivetrain-and-tires.md`, `features/menu-navigation.md`.
- `tests/headless/test_loot.gd`: only one tire on at once, a bought tire shows in `fielded`, the sale tables only offer tires that fit. Use synthetic input, not catalogue entries.
- A nav test for the new sub-menus.
