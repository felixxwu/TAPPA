# Coins and shops (free roam)

**Source:** `scripts/free_roam/loot_rules.gd` (`LootRules`: pure tables, prices, fitting, names),
`scripts/free_roam/loot_director.gd` (`LootDirector`: coins, money, the wreck, the shop stock), the
Shop / Garage pages of `scripts/free_roam/rest_stop_page.gd`, and the coins in
`TerrainStreamer` (`_coin_marker`, `shaders/coin.gdshader`).

**Tests:** `tests/headless/test_loot.gd`

Coins on the road are money; money buys parts at checkpoints; cars are found, parked at the ends
of side roads (see "Found cars" below); a wreck
drops all of it at the wreck, Souls-style: drive back for it, or wreck again first and it's gone.
This replaced the found-loot loop of decisions 10–18 (crystals, carry / bank / drop, rumours) on
2026-10-25 — see D89 in `todo/2026-10-19-free-roam-pivot.md`.

## Items

| Kind | Shape | Becomes |
|---|---|---|
| Part | `{"kind": "part", "id": <BoostLibrary id>, "level": n}` | a fittable part (the former boost, at level n) |
| Drivetrain kit | `{"kind": "part", "id": "drivetrain:<mode>"}` | a fittable layout conversion |
| Tires | `{"kind": "part", "id": "tire:<TIRES key>"}` | a fittable set of tires |

## What each ring sells (the pacing split, decision 3)

Each boost part (`BoostLibrary.CATALOGUE`) names its own biome `ring` and `price` in its entry
(a car names only its `ring`, where it is found); drivetrain kits have
no entry, so theirs live in `LootRules.KITS`, and tires in `LootRules.TIRES` (gravel from the start, road at The Dunes, snow in The Alps; grip strengths in `GameConfig`'s `shop_tire_*`). `ring_tables(ring_count)` collects them (a boost part
at level = its ring; a ring past `ring_count` folds into the last), and `LootRules.price(item)`
reads the price back. Ring 0's cars are the starter cars (`starter_cars`): the cold open falls back on the first.

- **On sale once lit.** A ring's stock goes on sale at every checkpoint once one of its checkpoints
  is lit (`RestStops.lit` → `LootDirector.site_lit` → `unlock`, wired in `free_roam.gd`, kept in the world's `revealed`
  list; ring 0 from the start; on load `free_roam.gd` re-runs `site_lit` for every lit stop so `revealed` follows `lit`). A ring the road network gave no rest stop would never unlock, so its
  stock is sold by the nearest ring that has one (`LootRules.pool_rings` over rest-stop counts,
  `LootDirector.ring_stock`).
- **One of each, per car.** `for_sale()` is the unlocked stock minus what the player has
  (`owned_keys(owned)`: the parts of the car being driven).
- **A part is unlocked for one car, then switched on or off.** Each owned car's `parts` are the
  parts unlocked for it, each with an `on` flag (`LootRules.is_on`; only switched-on parts reach the
  car through `LootRules.fielded`). Another car has to unlock its own. Drivetrain kits
  share a slot: `LootRules.toggled` switches the other one off when one goes on, and switching a kit
  off returns the car to its stock layout, so a kit for the car's own layout is never sold. Tires
  share a slot the same way (none on means the car runs its stock tires), and so do the parts naming the same `slot` in `BoostLibrary.CATALOGUE` (the small and big turbo).
  `WorldSession.adopt_old_stash` unlocks an older save's shared `stash` for the car being driven
  (switched off), once.
- **Buying** (`buy`) checks it's on sale, affordable and usable on the car being
  driven (`LootRules.can_fit`), takes the money, and hands the part back for the
  Shop page to unlock and switch on. A part the car can't use shows greyed out with the reason.
- `test_loot.gd` → `test_shipped_cars_name_a_ring_on_the_island_and_parts_a_ring_and_a_price`
  guards that every shipped car has a ring on the island, and every part a ring and a price.

## Found cars

**Source:** `scripts/free_roam/parked_cars.gd` (`ParkedCars`), the side roads in `RoadNetwork`
(`add_side_roads`, see [free-roam.md](free-roam.md)), `RoadSites.Kind.CAR`, `free_roam.gd` →
`_drive_found_car`. **Tests:** `tests/headless/test_found_cars.gd`.

- **Where:** every car but the one a new world starts with (`LootRules.cars_to_find`, which leaves
  out `ColdOpen.car_id`) is parked at the end of its own short side road in its `ring`.
- **The model:** `ParkedCars` builds a frozen `CarProp` of each car still waiting, on its pad facing
  back up the road, once at boot behind the loading screen, and keeps it there (a prop is too dear to
  build while driving). The boot's warm-up shows them all to the camera for a few frames
  (`warm_up` / `clear_warm_up`), so meeting one doesn't stall on its shaders. It is solid but never
  moves: a frozen body that stays in the physics world with its own car-shaped hull
  (`DISABLE_MODE_KEEP_ACTIVE`). Headless builds none (`show_props`); finding a car works without them.
- **Finding:** driving onto the pad from off it (`RoadSites.reached`, swept like coins) grants the
  car (`Save.grant_car`) and emits `found`. Its model stays on the pad, and coming back onto the pad
  offers it again, until the world next loads, when only cars still to be found are parked: free roam shows the checkpoint band,
  "Car found" with the car's name under it (`CheckpointBanner.show_found`), and the car drives on,
  nothing paused. While it stays on that pad, the rest stop's prompt line under the minimap reads
  "Enter / A: drive it" (`ParkedCars.offer`, `MiniMap.update_prompt_label`); menu_select or a tap
  on it (`switch_here` → `switch_requested` → `free_roam.gd._drive_found_car`) makes it the active
  car (`WorldSession.set_active_car`, so it starts undamaged) and reloads the world ("Changing
  cars") with it standing where it was parked, facing the same way (`ParkedCars.pad_pose`, held in
  `free_roam.gd._next_pose` so the exit's `save_world` doesn't overwrite it). Leaving the pad withdraws the offer; the car
  waits in the Garage. Enter marks the input handled before switching, because the reload takes the
  node out of the tree. Nothing is found while the cold open is due (`ColdOpen.due`). A car is
  waiting while no owned car has its model (`ParkedCars.model_owned`), so a car bought in an older
  save is already found.
- **On the maps:** a gold car key (`MiniMap.draw_key`, `Marker.CAR_KEY`) once the side road has
  been seen (coming within `minimap_seen_radius_m` of where it starts or of the car), until the
  car is owned. See [minimap.md](minimap.md).

## Coins

- **Where:** every loot slot (`FreeRoamSettings.loot_slot_spacing_m` of road apart) and dead end
  holds one coin (`LootDirector.loot_at` → `{"kind": "coin", "value": n}`); rest stops don't.
  A coin is worth `LootRules.coin_value`: `FreeRoamSettings.coin_value` plus `coin_value_per_ring`
  per ring out.
- **Collect:** driving past — at any speed, anywhere on the road around it (`RoadSites.reached`,
  swept over the step's travel; a jump of 100 m or more in one step, a teleport, doesn't count).
  The spot joins `collected`, the money is added, its coin is removed (`TerrainStreamer.refresh_loot_marker`, that one site only) and
  "+$n" shows on the line under the minimap (`said` → `MiniMap.toast`, see minimap.md).
- **The wreck:** when the car gives up (`DamageModel.gave_up` → `LootDirector.wreck`), all the money
  is left at the wreck (`WorldSession.dropped`: `{pos, money}`; `lost` keeps the amount for the
  wreck page, "You dropped $n here"), replacing — and losing — any earlier drop, and `collected` is
  cleared, so every coin comes back. A gold crystal bobs over the drop (`_sync_dropped_node`,
  `shaders/crystal.gdshader`, the old loot crystal); driving within `FreeRoamSettings.dropped_reach_m` of it
  recovers the money (`recover_dropped`). The full map marks the drop with a gold diamond (`WorldPages.dropped_xz`, [world-session.md](world-session.md)). The boot's shader warm-up draws one too (`LootDirector.warm_up` /
  `clear_warm_up`), so the first wreck doesn't hitch compiling it. A wrecked car picks nothing up until it respawns or rolls into a rest stop (`respawned` / `wreck_recovered`).
- **Travelling from the road** drops the money the same way (`drop_money`, after a confirm on the map —
  see world-session.md), so the map's free travel can't carry money to safety; checkpoint to checkpoint keeps it.
- **Paying:** `LootDirector._pay` adds it, beeps and says "+$n".
- **The counter:** `LootDirector.money_label`, "$n" in the top-left corner while driving, parented to the HUD layer so it hides under paused pages like the gauges.
- **On the ground:** a gold disc stood on its edge, spinning and bobbing in `coin.gdshader` (no
  per-coin scripts), lit by the fake headlight cone at night (`headlight_cone.gdshaderinc`, added to its glow), planted with the mid chunk (`TerrainStreamer._queue_site_markers` → `_coin_marker`, node `Loot<site>`).

## Stunt money

Risky driving pays into the same money (and so is dropped on a wreck like coins), said on the
same line as coins ("Drift +$n", "Speed +$n", "Jump +$n", "Near miss +$n"). `LootDirector.stunt_step` takes
plain readings each physics tick (`Car.chassis_slip_angle`, speed, `Car.wheels_in_contact`, the
trees near the car) so tests drive it without physics. Knobs: `FreeRoamSettings` → "Stunts".

- **Drift / Speed / Jump** are streaks: a drift past `drift_min_angle_deg` with the wheels down, a
  stretch at `fast_speed_mps`, or time with at least one wheel off the ground. Each pays seconds held ×
  its rate once it ends (out of it for `stunt_grace_s`, so a drift swinging sides is one drift);
  one shorter than `stunt_min_s` / `jump_min_s` pays nothing.
- **Near miss:** a tree within `near_miss_radius_m` of the car's side (the query sphere adds `Car.half_width()`, so wide cars get the same gap) at `near_miss_min_speed_mps` pays
  once it's left behind, from `near_miss_money` at the edge of the radius up to `near_miss_max_money` for a tree
  that brushes the car, by the closest it came (`_trees_near`: a sphere query returning id -> gap, trees told apart by
  collision shape index since a `BillboardField` shares one body, gap measured from `instance_positions[shape]`). Rocks and barriers don't count.
- **A hit voids it:** `DamageModel.damaged` drops every streak under way and every pending near
  miss — except a jump, since every landing jolts the car hard enough to register as a hit. Teleports and respawns reset it, and a jump only counts once the car has been on its wheels since
  (so dropping in at a spawn isn't one); a wrecked car earns nothing.

All of it lives in the world block (`WorldSession`: money, collected, revealed; parts live on each owned car); see
[world-session.md](world-session.md).

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

## Rest-stop pages

All card lists ([card-carousel.md](card-carousel.md)); item cards use `LootRules.card_text`
(a short name, then a one-line note on what it does, the card's `desc`; a boost's note is its `blurb` in `BoostLibrary.CATALOGUE`) and
`LootRules.icon`. Names and notes must each fit on one line of the card.
Rebuilding the page you're on (a part fitted, a car picked, something bought) keeps the cursor
where it was (`RestStopPage._keep_at`). There's no separate shop: things on sale show at the end of the page they belong on, their price
as the third line, green when the player can afford it and red when not (`RestStopPage.price_variant`). The MAIN page is Continue /
Shop / Garage / Map / Tune car (travel is on the map); its header says the money held.
The Shop pages' header line is the car, its weight, power, driven wheels and max health with the parts switched on (`LootRules.shop_header` over `fitted_stats`, which runs the parts through a throwaway `GameConfig` via `UpgradeLibrary.apply`; power is at full boost, without nitrous), rebuilt whenever a part changes. Garage cards show power · weight · drive (`CardUI.stats_line`): fitted values.
**Shop:** four cards opening **Upgrades** (`LootRules.is_upgrade`: the boost parts), **Tires**, **Drivetrain** (`_build_part_page`, each card with an "N applied, M available" line, where M counts the parts of that kind on sale this car can fit, affordable or not) and **Engine swaps**, which trades engines between owned cars ([engine-swap.md](engine-swap.md)). Each page has a card per part of that kind unlocked for this car, labelled "On" or "Off" (pick to switch it,
`_toggle_part`; other cars keep theirs), then one per part on sale (its price, or the
`fit_block_reason` label, disabled; picking one buys it and switches it on, `_buy_part`). Tires starts with a **Stock tires** card, which isn't a part: it's on when no bought tire is, and picking it switches them off (`LootRules.on_stock_tires`). Back steps part page → Shop → main page. **Garage:** a card per
owned car (pick to drive one; the cursor starts on the car being driven), each with an
"x / y upgrades" line under its power line (`LootRules.upgrades_text`: parts unlocked for that car, on or off, out of
`LootRules.parts_for(owned)` — the whole part catalogue less the drivetrain kit for its own stock
layout and, for a car that came with it, ABS). No cars are sold: after the owned cars comes a greyed-out card for each car still parked on
the island, "<region> region" / "Not found yet" under its name (`RestStopPage.unfound_cards`, the
region of the ring its side road is in). There is no journal (a read-only list of what
each unlocked biome sells): it was deleted on 2026-10-25 at the user's ask. A change
of parts or car re-fields the car when the page closes: `car_changed` makes free roam save and
reload the scene at the rest stop, because a live body is never re-staged. The loading screen says why
(`RestStopPage.reload_title`: "Changing cars" after a Garage pick, otherwise "Applying parts to your car").
