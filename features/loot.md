# Loot (free roam)

**Source:** `scripts/free_roam/loot_library.gd` (`LootLibrary`: pure tables, placement, fitting),
`scripts/free_roam/loot_director.gd` (`LootDirector`: the loot loop in the world), the Parts / Garage /
Journal pages of `scripts/free_roam/rest_stop_page.gd`, and the loot markers in `TerrainStreamer`.

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

`LootLibrary.place(sites, ring_count, seed)` puts each ring's items on its loot slots and dead ends,
seeded:
- **Dead ends take the best items first** (cars, engines, rumours, kits, parts), so every dead end
  has a payoff while its ring has items (decision 30). A dead end with nothing is a lookout.
- Leftover items spill into the next ring out.
- Each item exists once (decision 17).

On the default island the four rings have 12, 31, 27 and 35 loot sites for 12, 14, 13 and 12 items.
`LootDirector.pacing_report()` prints this at boot.

## The loop (`LootDirector`)

- **Collect:** driving within `PICKUP_REACH_M` of a loot pad takes the item into `carried`, which
  isn't yours yet (decision 10). Its marker goes and the HUD toasts what was found.
- **Bank:** opening the rest-stop page calls `bank()`. Parts go to the shared `stash`; car titles
  become owned cars.
- **Drop:** when the car gives up, `carried` is left at the wreck (`dropped`, marked by a red
  beacon). Driving back within `DROPPED_REACH_M` recovers it. Giving up again first replaces the
  drop, so the old one is lost for good (decision 11).
- **Rumours** are read on pickup: their ring is added to `revealed` (ring 0 starts revealed).
  The journal (`journal()`) lists each revealed ring's items, found or not.

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
