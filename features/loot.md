# Parts and the level's shop pages

**Source:** `scripts/free_roam/loot_rules.gd` (`LootRules`: the parts catalogue, fitting,
names), `scripts/free_roam/rest_stop_page.gd` (`RestStopPage`: the Parts, Engine swaps and Tune
pages the level opens), and the level's shops and money in `scripts/level_view.gd` (see
[level-editor.md](level-editor.md)).

**Tests:** `tests/headless/test_loot.gd`, `tests/headless/test_level_shop_specialties.gd`, `tests/headless/test_level_view.gd`

The island's coins, rings, found cars, stunt money and rest stops were deleted with the island
(Phase 4 of `todo/2026-11-27-hafren-only-cleanup.md`). The level keeps its own money
(`LevelView.MONEY_KEY`) and sells parts at its shops.

## Items

| Kind | Shape | Becomes |
|---|---|---|
| Part | `{"kind": "part", "id": <BoostLibrary id>, "level": n}` | a fittable part (the former boost, at level n) |
| Drivetrain kit | `{"kind": "part", "id": "drivetrain:<mode>"}` | a fittable layout conversion |
| Tires | `{"kind": "part", "id": "tire:<TIRES key>"}` | a fittable set of tires |

`LootRules.catalogue()` lists every part once: each boost part (`BoostLibrary.CATALOGUE`, at level
0), each drivetrain kit (`LootRules.KITS`) and each tire (`LootRules.TIRES`; grip strengths in
`GameConfig`'s `shop_tire_*`). The level's shops price what they sell in the level file (each
shop item's `price`); the catalogue itself carries no prices.

- **A part is unlocked for one car, then switched on or off.** Each owned car's `parts` are the
  parts unlocked for it, each with an `on` flag (`LootRules.is_on`; only switched-on parts reach the
  car through `LootRules.fielded`). Drivetrain kits share a slot: `LootRules.toggled` switches the
  other one off when one goes on, and switching a kit off returns the car to its stock layout (on
  Hafren, tires and kits are bought per car at shops listing `tire:<key>` / `drivetrain:<mode>`,
  level-editor.md), so a kit for the car's own layout is never sold. Tires share a slot the same
  way (none on means the car runs its stock tires), and so do the parts naming the same `slot` in
  `BoostLibrary.CATALOGUE` (the small and big turbo).

## Parts on cars (the effects funnel, decision 51)

A car's fitted parts are saved on its owned-car record (`parts`, `Save.set_car_parts`). At fielding,
`LootRules.fielded(owned)` writes them onto the funnel's own keys: `boosts` (`{id, effect}` from
`BoostLibrary.magnitude_for(id, level)`, or `LootRules._tire_effect` for tires, which don't scale with level), `swapped_engine` and `drivetrain_override`.
Each switched-on part also adds weight (`mass_kg` in `BoostLibrary.CATALOGUE`, `TIRES` and `KITS`; a kit adds the difference from the car's stock layout, and an engine's own mass goes through `EngineSwap`). `fielded` totals it into one `mass_add` effect at the front of `boosts`, so the Lightweight multiplier scales it whatever order the parts were bought in.
`Car.apply_owned` and `UpgradeLibrary.apply` do the rest. There's no other modifier path.

Fitting rules (`can_fit`, `toggled`): one of each part id per car; a kit for the car's own layout
never fits (switching its other kit off changes it back). Each part is switched on or off, and
switching on a kit, tire or turbo switches off whichever other one of its kind was on (`LootRules._slot`).
`fit_block_reason` gives the shop card's label when a part can't go on ("Already RWD",
"Already has ABS", "Already unlocked"); `can_fit` is just "no reason".

## The level's part pages (`RestStopPage`)

All card lists ([card-carousel.md](card-carousel.md)); item cards use `LootRules.card_text`
(a short name, then a one-line note on what it does, the card's `desc`; a boost's note is its `blurb`
in `BoostLibrary.CATALOGUE`) and `LootRules.icon`. Names and notes must each fit on one line of the card.
Rebuilding the page you're on (a part switched) keeps the cursor where it was (`RestStopPage._keep_at`).
`LevelView._rest_page` makes one and sets `owned`, `car` and `engine_cars`; it opens on one of:

- **Shop** (`open_shop`, the service menu's Parts): four cards opening **Upgrades**
  (`LootRules.is_upgrade`), **Tires**, **Drivetrain** (each "N applied") and **Engine swaps** (only
  when `engine_cars` isn't empty). Each part page has a card per part of that kind unlocked for this
  car, labelled "On" or "Off" (pick to switch it, `_toggle_part`). Tires starts with a **Stock
  tires** card, which isn't a part: it's on when no bought tire is, and picking it switches them off
  (`LootRules.on_stock_tires`).
- **Engine swaps** (`open_engines`, a shop's Engine swap): a card per owned car; picking one fits
  its engine to the car being driven (`engine_from`, free; [engine-swap.md](engine-swap.md)).
- **Tune car** (`open_tune`): the shared `TuningPanel`.

The header line is the car, its weight, power, driven wheels and max health with the parts switched
on (`LootRules.shop_header` over `fitted_stats`, which runs the parts through a throwaway
`GameConfig` via `UpgradeLibrary.apply`; power is at full boost, a stock turbo included, without
nitrous). Back steps a sub-page → the shop → closed. A change of parts or engine emits `car_changed`
when the page closes, and the level reloads the car ("Applying parts to your car"), because a live
body is never re-staged. `LootRules.parts_for(owned)` is the catalogue less the kit for the car's own
layout and, for a car that came with it, ABS.
