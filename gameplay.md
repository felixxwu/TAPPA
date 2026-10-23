# Gameplay Design — "One island, no clock"

> **This is a design / vision document, not an implementation spec.** It captures the intended
> game and *why* it is shaped this way. Where it names real systems it's to show feasibility, not
> to prescribe code.
>
> The settled decision record is **`todo/2026-10-19-free-roam-pivot.md`**: decisions 1–32 agreed
> with the user, and D33 onward made during the autonomous build and logged for review. **If this
> file and that record ever disagree, the record wins.** It superseded the roguelike's record,
> `todo/roguelike-pivot.md`, which is kept for history.

## Tagline & fantasy

**A free-roam rally game on a procedural island: explore outward, find cars and parts, and
nurse a dying car to the next rest stop.**

You start a world, pick one of a few modest cars, and drive out from the spawn rest stop. The
roads fork as you go and the island streams in around you, with no loading screens after boot.
There is no timer and no run to lose. The island is laid out in **biome rings**, Valheim-style:
each ring has its own look, surfaces, weather and loot, and the rarer, better things sit further
out. You play to see what's over the next ridge and to find the car and parts that get you there.

The tension comes from the car, not the clock. **Roads are hard and damage is unforgiving.** Hit
something hard enough and the cooling system fails; from then on the engine only heats up, and
you are racing the temperature gauge to a rest stop.

## The loop

```
title (Continue · New World · Settings)
  └─ new world: choose a starter car (the cheapest few in the catalogue)
       └─ drive out from the spawn rest stop
            ├─ drive near loot → it's CARRIED (not yours yet)
            ├─ drive through a rest stop → it's LIT (your respawn point)
            ├─ crash → HP down; below half health the cooling FAILS
            │     └─ engine only heats up → over the limit it drains HP → 0 HP: the car gives up
            │           └─ respawn at the last lit rest stop; carried loot is left at the wreck
            └─ stop at a rest stop → BANK loot · free REPAIR · fit PARTS · TUNE · swap CAR
                                       · TRAVEL to any lit rest stop · MAP · JOURNAL
```

## The world

- **One persistent world per save.** A single seed makes the island; progress never resets. The
  only setback is a respawn.
- **A bounded island.** The coast is the edge (about 5 km radius today; the loot pacing pass is
  what sizes it).
- **A road network, laid out whole at world creation.** Roads grow out from spawn, fork, and
  join where they meet. Terrain is built *around* the roads, so they sit in valleys and the
  mountains rise away from them. Some roads end at the coast or in the hills; every dead end has
  something at the end of it.
- **Biome rings** by distance from spawn, with noisy borders. Each ring wears a region (its sky,
  ground, trees, rocks, handling) and has a weighted weather pool that drifts every few
  minutes. The sky and fog cross-fade as you cross a border.

## Damage, temperature and rest stops

- **Impacts cost HP** on the same square law as always.
- **At half health the cooling system breaks** and stays broken until you rest. The engine
  temperature then only rises, faster under load and at high revs. Easing off buys time;
  nothing stops it.
- **Over the limit, the engine loses HP continuously**, misfires and won't rev out.
- **At 0 HP the car gives up.** You respawn at the last lit rest stop, repaired. What you were
  carrying stays at the wreck; drive back to get it, but give up again first and it's gone.
- **Rest stops are bonfires.** Driving past one — no need to stop — lights it and fully heals the
  car. Pulling in and pressing Enter / A opens the rest-stop page: carried loot is banked, and you can fit parts, tune,
  swap cars, read the journal, and travel to any rest stop you've lit. A crowd gathers at each.
- **Rest-stop spacing is the main balance lever**, because it decides how survivable a cooling
  failure is. It is set per ring.

## Loot

- **Everything is found; nothing is bought.** There is no money.
- **Car titles** join your garage once banked. **Parts** are the old boosts (turbo, supercharger,
  nitrous, sticky tyres, quick-shift gearbox, aero, brakes, lightweight parts) found at a
  level that rises with the ring. **Engines** and **drivetrain kits** are parts too. Parts go into
  a shared stash and move freely between cars at rest stops.
- **Every car and part exists once.** Pull-ins along the roads show what's still to be found in
  their biome; the moment you have something it's gone from all of them, and once a biome's things
  are all found its pull-ins stand empty. Tall beams of light mark rest stops from far off, and
  coloured crystals on the road mark loot. **Rumours** reveal the next biome's full loot
  list in the journal, so you always know what's just out of reach.
- **The pacing goal:** the cars and parts run out at about the same time as the biomes, so the late
  game is fresh in both.

## Front end

- **The title screen** leads straight into the world: Continue, New World, Settings.
- **The pause menu** offers the map (driven roads, lit rest stops, ring borders crossed) and
  lifetime stats (distance driven, rest stops lit, times the car gave up). At a rest stop the map
  doubles as the travel picker.
- Every menu is keyboard- and gamepad-navigable (`CLAUDE.md`).

## What this replaced, and why

The game was a rally career, then a run-based roguelike ("eight stages, one clock"). The
roguelike's loop was a timer you failed. Free roam swaps the timer for the car: the pressure
comes from damage and distance to safety, and progress is exploration and finds rather than a
ratchet of purchases. The systems that carried over are the ones that were always the point:
driving, damage, cars, tuning, terrain and weather.

## Open, and deferred

- **Harder roads per biome** (tighter bends, hairpins further out) are deferred until a playtest
  says the roads are too easy (decision 28).
- **Island and ring sizes** follow the loot pacing pass; the current numbers are a first pass.
- **Rest-stop spacing, temperature rates and impact damage** all need a playtest; see the decision
  log's REVIEW items.
