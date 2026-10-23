# Loot (free roam)

**Source:** `scripts/free_roam/loot_rules.gd` (`LootRules`: pure tables, the pool, fitting, names
and colours), `scripts/free_roam/loot_director.gd` (`LootDirector`: the loot loop in the world),
`scripts/free_roam/site_beacons.gd` (`SiteBeacons`: the tall beams over rest stops and loot, and the
floating names over loot), the Parts / Garage / Journal pages of
`scripts/free_roam/rest_stop_page.gd`, and the loot crystals in `TerrainStreamer`.

**Tests:** `tests/headless/test_loot.gd`

Everything is found, nothing is bought (decisions 10–18 in `todo/2026-10-19-free-roam-pivot.md`).

## Items

| Kind | Shape | Becomes |
|---|---|---|
| Car title | `{"kind": "car", "id": <CarLibrary id>}` | a new owned car once banked (`Save.grant_car`) |
| Part | `{"kind": "part", "id": <BoostLibrary id>, "level": n}` | a fittable part (the former boost, at level n) |
| Engine | `{"kind": "part", "id": "engine_swap:<engine id>"}` | a fittable engine (the swap-tier engines) |
| Drivetrain kit | `{"kind": "part", "id": "drivetrain:<mode>"}` | a fittable layout conversion |
| Rumour | `{"kind": "rumour", "ring": r, "of": <item_key>}` | reveals that ONE item of ring r in the journal, on the spot |

## Where it is (the pacing split, decision 3)

Each car (`CarLibrary.CARS`), swap-tier engine (`EngineLibrary`) and boost part
(`BoostLibrary.CATALOGUE`) names its own biome `ring` in its entry; drivetrain kits have no entry, so
theirs live in `LootRules.KIT_RINGS`. `ring_tables(ring_count)` collects them. Ring r holds:
- the cars, engines, kits and boost parts that name ring r — a boost part exists once, at level r;
- one rumour for each car / engine / kit / part of ring r + 1, each revealing just that item.

Ring 0's cars are also the starter choice (`starter_cars`). A ring past `ring_count` folds into the
last ring. `test_loot.gd` → `test_shipped_cars_engines_and_parts_each_name_a_ring_on_the_island`
guards that every shipped entry names a ring on the island.

## The pool: every car and part exists once

Nothing is pinned to a site. `LootRules.assign(sites, ring_count, seed, taken, used)` decides what
every loot slot and dead end shows **right now**, and `LootDirector._reassign` re-runs it whenever
what the player holds changes (a pickup, a drop, a lost drop), emitting `pool_changed`:
- **The pool.** A ring's pool is its table minus everything the player has
  (`LootDirector.taken_keys()`, by `item_key`): owned cars, every car's fitted parts, the stash,
  `carried`, the dropped pile, and every rumour with nothing left to tell (its item is already
  revealed or owned, or its whole ring is revealed). The moment the player has
  an item it is gone from **every** site at once; once a ring's things are all found, its sites
  show nothing. Owning a car (the starter included) means its title never shows on the ground.
- **Sites show the pool in order.** Dead ends first, with the best items (cars, engines, kits,
  parts, then rumours — decision 30; rumours rank last because there's one per next-ring item), then loot slots, each group in a seeded order; site k shows pool item
  k mod pool size. So with more sites than items each item shows at more than one site (all of them
  empty out together when it's taken). Past the first round, spare sites skip cars:
  `FreeRoamSettings.loot_item_weight` (3) makes every other item show at about that many times as
  many sites as a car, and `loot_rumour_weight` (2) makes each rumour show at that many times as
  many sites as a part again, while any rumours are left (`LootRules.weighted_cycle`).
- **A site you pick something up from is spent** (`collected`): nothing ever shows there again.
- **A ring with more items than free sites** keeps its best and moves the rest to the nearest ring
  with sites to spare (inward first); the overflow is hosted best-first across rings, so scarce
  spare sites show the best of what overflowed. If no ring has any to spare, those items show nowhere — so
  sites are kept plentiful.
- **A ring with no loot sites** (the road network never reached it) folds its table into the
  nearest ring that has some (`pool_rings`).
- **A lost drop** (giving up again while carrying something, before fetching the first) puts its items back in the pool.

There are plenty of sites: `FreeRoamSettings.loot_slot_spacing_m` is 150 m of road. The road
network varies a lot by world seed; `LootDirector.pacing_report()` prints sites, table size, items
left and sites showing something per ring at boot.

## Seeing it

- **On the ground:** a thin crystal, pointed top and bottom, bobbing over the road (`shaders/loot_crystal.gdshader`), coloured by kind (`LootRules.colour`: gold car, orange engine,
  green kit, cyan part, white rumour), built with the near chunk (`TerrainStreamer._loot_marker`;
  `refresh_loot_markers` rebuilds every loaded one when the pool changes).
- **From far away:** `SiteBeacons` keeps one beam per rest stop for the whole world (grey, orange
  once lit; `GameConfig.beacon_rest_height_m`), within `beacon_range_m`. Loot has no beam: the
  crystal is the marker. Beams ignore fog and are widened with distance
  (`beacon_width_per_m`) so they stay a few pixels wide, fade out as they reach into the sky
  (`shaders/beacon_beam.gdshader`), and fade from `beacon_alpha_near` up close
  to `beacon_alpha_far` at the edge of their range. Only once the car is close
  (`beacon_label_range_m`, 60 m) does a floating name over the loot say what it is
  (`LootRules.ground_label`: "New car", "New upgrade", "New engine", "Drivetrain kit", "Rumour"); it
  faces the camera at a fixed screen size and shows through hills.

## The loop (`LootDirector`)

- **Collect:** driving past a piece of loot — at any speed, anywhere on the road around it
  (`RoadSites.reached`, swept over the step's travel; a jump of 100 m or more in one step, a
  teleport, doesn't count) — takes the item into `carried`, which isn't yours yet (decision 10).
  The site is spent, the pool is re-assigned (it's gone from every site) and the HUD toasts what
  was found.
- **Bank:** reaching a checkpoint (`RestStops.healed` → `bank_at_checkpoint`) banks everything
  carried at once and toasts it; no need to open the page. Parts go to the shared `stash`; car
  titles become owned cars.
- **Drop:** when the car gives up, `carried` is left at the wreck (`dropped`, marked by a red
  beacon). Driving back within `DROPPED_REACH_M` recovers it. Giving up again while carrying
  something replaces the drop (an empty-handed give-up keeps the earlier pile): the old one is lost, and its items go back into the pool to be found again (decision 11).
- **Rumours** are read on pickup: the one item they tell of (`of`) is added to `revealed_items`
  (`reveal_item`). Whole rings in `revealed` are fully known (ring 0 from the start, or every ring
  via the dev action). The journal (`journal()`) lists each ring with anything known, with its
  known items; "found" means the player has it.

All of it lives in the world block (`WorldSession`: carried, stash, dropped, collected, revealed,
revealed_items);
see [world-session.md](world-session.md).

## Parts on cars (the effects funnel, decision 51)

A car's fitted parts are saved on its owned-car record (`parts`, `Save.set_car_parts`). At fielding,
`LootRules.fielded(owned)` writes them onto the funnel's own keys: `boosts` (`{id, effect}` from
`BoostLibrary.magnitude_for(id, level)`), `swapped_engine` and `drivetrain_override`.
`Car.apply_owned` and `UpgradeLibrary.apply` do the rest. There's no other modifier path.

Fitting rules (`can_fit`, `occupant`): one of each part id; one engine and one drivetrain kit (a new
one swaps with the fitted one); no kit for the car's own layout.

## Rest-stop pages

All card lists ([card-carousel.md](card-carousel.md)); item cards use `LootRules.card_text`
(a short name, then what it is — "Level 2", "Engine", "Car") and `LootRules.icon`.
**Parts:** a card per fitted part (pick to take off), then one per stash part (pick to fit; it
says "Fit", "Swap for X", or — disabled — "Can't fit"), then one per part fitted to another owned
car ("on <car>"; "Move here" / "Swap for X" / "Can't fit"). Picking one of those asks first in a
`ConfirmPopup` ("It will be removed from the <car>") and then moves it over (`_take`); a part it
displaces goes to the stash. **Garage:** a card per owned car (pick
to drive one; the cursor starts on the car being driven). **Journal:** a card per revealed region
("n of m found"); picking one opens that region's page (`View.REGION`, `journal_ring`), a read-only
card per item and car there, "Found" or "Not found yet". Back steps region → region list → main. A change of parts or car re-fields the car
when the page closes: `car_changed` makes free roam save and reload the scene at the rest stop,
because a live body is never re-staged.

## In the world

`TerrainStreamer._loot_marker`: a crystal under a tall light beam, coloured by kind (gold car,
orange engine, green kit, cyan part, white rumour), built per near chunk while the item is
still there (`loot_query`), and removed on pickup (`refresh_loot_marker`).
