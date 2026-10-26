# Coins and shops (free roam)

**Source:** `scripts/free_roam/loot_rules.gd` (`LootRules`: pure tables, prices, fitting, names),
`scripts/free_roam/loot_director.gd` (`LootDirector`: coins, money, the wreck, the shop stock), the
Parts / Garage pages of `scripts/free_roam/rest_stop_page.gd`, and the coins in
`TerrainStreamer` (`_coin_marker`, `shaders/coin.gdshader`).

**Tests:** `tests/headless/test_loot.gd`

Coins on the road are money; money buys cars and parts at checkpoints; a wreck
drops all of it at the wreck, Souls-style: drive back for it, or wreck again first and it's gone.
This replaced the found-loot loop of decisions 10–18 (crystals, carry / bank / drop, rumours) on
2026-10-25 — see D89 in `todo/2026-10-19-free-roam-pivot.md`.

## Items

| Kind | Shape | Becomes |
|---|---|---|
| Car | `{"kind": "car", "id": <CarLibrary id>}` | a new owned car (`Save.grant_car`) |
| Part | `{"kind": "part", "id": <BoostLibrary id>, "level": n}` | a fittable part (the former boost, at level n) |
| Engine | `{"kind": "part", "id": "engine_swap:<engine id>"}` | a fittable engine (the swap-tier engines) |
| Drivetrain kit | `{"kind": "part", "id": "drivetrain:<mode>"}` | a fittable layout conversion |

## What each ring sells (the pacing split, decision 3)

Each car (`CarLibrary.CARS`), swap-tier engine (`EngineLibrary`) and boost part
(`BoostLibrary.CATALOGUE`) names its own biome `ring` and `price` in its entry; drivetrain kits have
no entry, so theirs live in `LootRules.KITS`. `ring_tables(ring_count)` collects them (a boost part
at level = its ring; a ring past `ring_count` folds into the last), and `LootRules.price(item)`
reads the price back. Ring 0's cars are also the starter choice (`starter_cars`).

- **On sale once lit.** A ring's stock goes on sale at every checkpoint once one of its checkpoints
  is lit (`CheckpointBanner._reveal_ring` → `LootDirector.unlock`, kept in the world's `revealed`
  list; ring 0 from the start). A ring the road network gave no rest stop would never unlock, so its
  stock is sold by the nearest ring that has one (`LootRules.pool_rings` over rest-stop counts,
  `LootDirector.ring_stock`).
- **One of each, per car.** `for_sale()` is the unlocked stock minus what the player has
  (`owned_keys(owned)`: every car in the garage, and the parts of the car being driven).
- **A part is unlocked for one car, then switched on or off.** Each owned car's `parts` are the
  parts unlocked for it, each with an `on` flag (`LootRules.is_on`; only switched-on parts reach the
  car through `LootRules.fielded`). Another car has to unlock its own. Engines and drivetrain kits
  share a slot: `LootRules.toggled` switches the other one off when one goes on, and switching a kit
  off returns the car to its stock layout, so a kit for the car's own layout is never sold.
  `WorldSession.adopt_old_stash` unlocks an older save's shared `stash` for the car being driven
  (switched off), once.
- **Buying** (`buy`) checks it's on sale, affordable and — for a part — usable on the car being
  driven (`LootRules.can_fit`), takes the money, and grants the car or hands the part back for the
  Parts page to unlock and switch on. A part the car can't use shows greyed out with the reason.
- `test_loot.gd` → `test_shipped_cars_engines_and_parts_each_name_a_ring_on_the_island_and_a_price`
  guards that every shipped entry has a ring on the island and a price.

## Coins

- **Where:** every loot slot (`FreeRoamSettings.loot_slot_spacing_m` of road apart) and dead end
  holds one coin (`LootDirector.loot_at` → `{"kind": "coin", "value": n}`); rest stops don't.
  A coin is worth `LootRules.coin_value`: `FreeRoamSettings.coin_value` plus `coin_value_per_ring`
  per ring out.
- **Collect:** driving past — at any speed, anywhere on the road around it (`RoadSites.reached`,
  swept over the step's travel; a jump of 100 m or more in one step, a teleport, doesn't count).
  The spot joins `collected`, the money is added, its coin is removed (`refresh_loot_markers`) and
  the HUD toasts "+$n".
- **The wreck:** when the car gives up (`DamageModel.gave_up` → `LootDirector.wreck`), all the money
  is left at the wreck (`WorldSession.dropped`: `{pos, money}`; `lost` keeps the amount for the
  wreck page, "You dropped $n here"), replacing — and losing — any earlier drop, and `collected` is
  cleared, so every coin comes back. A gold crystal bobs over the drop (`_sync_dropped_node`,
  `shaders/crystal.gdshader`, the old loot crystal); driving within `DROPPED_REACH_M` of it
  recovers the money (`recover_dropped`). A wrecked car picks nothing up until it respawns (`RestStops.respawned`).
- **The counter:** `LootDirector.money_label`, "$n" in the top-left corner while driving, parented to the HUD layer so it hides under paused pages like the gauges.
- **On the ground:** a gold disc stood on its edge, spinning and bobbing in `coin.gdshader` (no
  per-coin scripts), built with the near chunk (`TerrainStreamer._coin_marker`, node `Loot<site>`).

All of it lives in the world block (`WorldSession`: money, collected, revealed; parts live on each owned car); see
[world-session.md](world-session.md).

## Parts on cars (the effects funnel, decision 51)

A car's fitted parts are saved on its owned-car record (`parts`, `Save.set_car_parts`). At fielding,
`LootRules.fielded(owned)` writes them onto the funnel's own keys: `boosts` (`{id, effect}` from
`BoostLibrary.magnitude_for(id, level)`), `swapped_engine` and `drivetrain_override`.
`Car.apply_owned` and `UpgradeLibrary.apply` do the rest. There's no other modifier path.

Fitting rules (`can_fit`, `occupant`): one of each part id; one engine and one drivetrain kit (a new
one swaps with the fitted one); a kit for the car's own layout only fits in place of another kit
(changing a converted car back). `fit_block_reason` gives the
Parts card's label when a part can't go on ("Already RWD", "Already fitted"); `can_fit` is just
"no reason".

## Rest-stop pages

All card lists ([card-carousel.md](card-carousel.md)); item cards use `LootRules.card_text`
(a short name, then a one-line note on what it does, the card's `desc`; a boost's note is its `blurb` in `BoostLibrary.CATALOGUE`) and
`LootRules.icon`. Names and notes must each fit on one line of the card.
Rebuilding the page you're on (a part fitted, a car picked, something bought) keeps the cursor
where it was (`RestStopPage._keep_at`). There's no separate shop: things on sale show at the end of the page they belong on, their price
as the third line, dimmed when they cost more than the player has. The MAIN page is Continue /
Parts / Garage / Map / Tune car (travel is on the map); its header says the money held.
**Parts:** a card per fitted part (pick to take off), then one per other part owned (pick to fit; it
says "Fit", "Swap for X", or — disabled — "Can't fit"; other cars keep theirs), then one per part on
sale ("for sale"; picking one buys it and fits it straight away, `_buy_part`). **Garage:** a card per
owned car (pick to drive one; the cursor starts on the car being driven), each with an
"x / y upgrades" line (`LootRules.upgrades_text`: parts unlocked for that car, on or off, out of
`LootRules.parts_for(owned)` — the whole part catalogue less the drivetrain kit for its own stock
layout), then one per car on sale
(picking one buys it and switches to it, `_buy_car`). There is no journal (a read-only list of what
each unlocked biome sells): it was deleted on 2026-10-25 at the user's ask. A change
of parts or car re-fields the car when the page closes: `car_changed` makes free roam save and
reload the scene at the rest stop, because a live body is never re-staged.
