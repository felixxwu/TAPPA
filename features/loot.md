# Loot (free roam)

**Source:** `scripts/free_roam/loot_library.gd` (`LootLibrary`: pure tables, the pool, fitting, names
and colours), `scripts/free_roam/loot_director.gd` (`LootDirector`: the loot loop in the world),
`scripts/free_roam/site_beacons.gd` (`SiteBeacons`: the tall beams over rest stops and loot, and the
floating names over loot), the Parts / Garage / Journal pages of
`scripts/free_roam/rest_stop_page.gd`, and the ground crates in `TerrainStreamer`.

**Tests:** `tests/headless/test_loot.gd`

Everything is found, nothing is bought (decisions 10–18 in `todo/2026-10-19-free-roam-pivot.md`).

## Items

| Kind | Shape | Becomes |
|---|---|---|
| Car title | `{"kind": "car", "id": <CarLibrary id>}` | a new owned car once banked (`Save.grant_car`) |
| Part | `{"kind": "part", "id": <BoostLibrary id>, "level": n}` | a fittable part (the former boost, at level n) |
| Engine | `{"kind": "part", "id": "engine_swap:<engine id>"}` | a fittable engine (the swap-tier engines) |
| Drivetrain kit | `{"kind": "part", "id": "drivetrain:<mode>"}` | a fittable layout conversion |
| Rumour | `{"kind": "rumour", "ring": r}` | reveals ring r's loot in the journal, on the spot |

## Where it is (the pacing split, decision 3)

`LootLibrary.ring_tables(ring_count)`. Ring r holds:
- the catalogue's cars sorted by `cost`, cut into even runs, cheapest innermost;
- every boost part at level r, so the same part is better further out;
- the swap-tier engines and the drivetrain kits, spread from ring 1 outward;
- a rumour of ring r + 1.

## The pool: every car and part exists once

Nothing is pinned to a site. `LootLibrary.assign(sites, ring_count, seed, taken, used)` decides what
every loot slot and dead end shows **right now**, and `LootDirector._reassign` re-runs it whenever
what the player holds changes (a pickup, a drop, a lost drop), emitting `pool_changed`:
- **The pool.** A ring's pool is its table minus everything the player has
  (`LootDirector.taken_keys()`, by `item_key`): owned cars, every car's fitted parts, the stash,
  `carried`, the dropped pile, and the rumours of rings already revealed. The moment the player has
  an item it is gone from **every** site at once; once a ring's things are all found, its sites
  show nothing. Owning a car (the starter included) means its title never shows on the ground.
- **Sites show the pool in order.** Dead ends first, with the best items (cars, engines, rumours,
  kits, parts — decision 30), then loot slots, each group in a seeded order; site k shows pool item
  k mod pool size. So with more sites than items each item shows at more than one site (all of them
  empty out together when it's taken).
- **A site you pick something up from is spent** (`collected`): nothing ever shows there again.
- **A ring with more items than free sites** keeps its best and moves the rest to the nearest ring
  with sites to spare (inward first). If no ring has any to spare, those items show nowhere — so
  sites are kept plentiful.
- **A ring with no loot sites** (the road network never reached it) folds its table into the
  nearest ring that has some (`pool_rings`).
- **A lost drop** (giving up again before fetching the first) puts its items back in the pool.

There are plenty of sites: `FreeRoamSettings.loot_slot_spacing_m` is 150 m of road. The road
network varies a lot by world seed; `LootDirector.pacing_report()` prints sites, table size, items
left and sites showing something per ring at boot.

## Seeing it

- **On the ground:** a crate coloured by kind (`LootLibrary.colour`: gold car, orange engine,
  green kit, cyan part, white rumour), built with the near chunk (`TerrainStreamer._loot_marker`;
  `refresh_loot_markers` rebuilds every loaded one when the pool changes).
- **From far away:** `SiteBeacons` keeps one beam per site for the whole world — every rest stop
  (grey, orange once lit; `GameConfig.beacon_rest_height_m`) and every piece of loot (its colour;
  `beacon_loot_height_m`), within `beacon_range_m`. Beams ignore fog and are widened with distance
  (`beacon_width_per_m`) so they stay a few pixels wide, fade out as they reach into the sky
  (`shaders/beacon_beam.gdshader`), and fade from `beacon_alpha_near` up close
  to `beacon_alpha_far` at the edge of their range. Only once the car is close
  (`beacon_label_range_m`, 60 m) does a floating name over the loot say what it is
  (`LootLibrary.ground_label`: "New car", "New upgrade", "New engine", "Drivetrain kit", "Rumour"); it
  faces the camera at a fixed screen size and shows through hills.

## The loop (`LootDirector`)

- **Collect:** driving past a piece of loot — at any speed, anywhere on the road beside its pad
  (`RoadSites.reached`, swept over the step's travel; a jump of 100 m or more in one step, a
  teleport, doesn't count) — takes the item into `carried`, which isn't yours yet (decision 10).
  The site is spent, the pool is re-assigned (it's gone from every site) and the HUD toasts what
  was found.
- **Bank:** opening the rest-stop page calls `bank()`. Parts go to the shared `stash`; car titles
  become owned cars.
- **Drop:** when the car gives up, `carried` is left at the wreck (`dropped`, marked by a red
  beacon). Driving back within `DROPPED_REACH_M` recovers it. Giving up again first replaces the
  drop: the old one is lost, and its items go back into the pool to be found again (decision 11).
- **Rumours** are read on pickup: their ring is added to `revealed` (ring 0 starts revealed).
  The journal (`journal()`) lists each revealed ring's items; "found" means the player has it.

All of it lives in the world block (`WorldSession`: carried, stash, dropped, collected, revealed);
see [world-session.md](world-session.md).

## Parts on cars (the effects funnel, decision 51)

A car's fitted parts are saved on its owned-car record (`parts`, `Save.set_car_parts`). At fielding,
`LootLibrary.fielded(owned)` writes them onto the funnel's own keys: `boosts` (`{id, effect}` from
`BoostLibrary.magnitude_for(id, level)`), `swapped_engine` and `drivetrain_override`.
`Car.apply_owned` and `UpgradeLibrary.apply` do the rest. There's no other modifier path.

Fitting rules (`can_fit`, `occupant`): one of each part id; one engine and one drivetrain kit (a new
one swaps with the fitted one); no kit for the car's own layout.

## Rest-stop pages

All card lists ([card-carousel.md](card-carousel.md)); item cards use `LootLibrary.card_text`
(a short name, then what it is — "Level 2", "Engine", "Car") and `LootLibrary.icon`.
**Parts:** a card per fitted part (pick to take off), then one per stash part (pick to fit; it
says "Fit", "Swap for X", or — disabled — "Can't fit"). **Garage:** a card per owned car (pick
to drive one; the cursor starts on the car being driven). **Journal:** a read-only card per item
in each revealed ring, "Found" or "Not found yet". A change of parts or car re-fields the car
when the page closes: `car_changed` makes free roam save and reload the scene at the rest stop,
because a live body is never re-staged.

## In the world

`TerrainStreamer._loot_marker`: a crate under a tall light beam, coloured by kind (gold car,
orange engine, green kit, cyan part, white rumour), built per near chunk while the item is
still there (`loot_query`), and removed on pickup (`refresh_loot_marker`).
