# Free-roam pivot — island road network, biome rings, rest stops (2026-10-19)

**Status: AGREED DESIGN, nothing implemented.** Design questions were resolved with the
user on 2026-10-19 (see *Decisions*). One piece is deliberately left open: the **road
network generation algorithm** is its own spec, still to be written and discussed with
the user (see *Dependencies*). Once staging starts, this file is the decision record
for the pivot. It supersedes `todo/roguelike-pivot.md` wherever they disagree, and
`gameplay.md` gets rewritten to match.

## The pitch

You start a world, pick one of a few starter cars, and drive outward from the spawn
rest stop across a procedural island. The roads stream in ahead of you and fork as you
go, with no loading screens after boot. There is no timer. You play to **explore, find
cars and find parts**. The island is laid out in Valheim-style **biome rings**: each
ring has its own look, surfaces, weather and loot, and the rarer rings sit further out.

Roads are hard, and damage is unforgiving. Once the car is damaged enough the cooling
system fails, the engine starts overheating, and you are racing the temperature gauge
to the next **rest stop**. Rest stops are Dark Souls bonfires: you get a free full
repair, you fit the loot you've been carrying, you tune and swap cars, and you can
travel to any other rest stop you've lit. Die on the road and you respawn at the last
one, with your unbanked loot left at the wreck for you to go back for.

## Decisions (resolved with the user, 2026-10-19)

### World and roads

1. **No timer as the objective.** The stage clock (`RegionRunMode.stage_target_ms` /
   `stage_failed`) is deleted. The goals are exploration, finding cars and finding
   parts.
2. **One persistent world per save.** There is one world seed per save and progress
   never resets. The only setback is a respawn. There are no runs and no soft
   permadeath.
3. **A bounded island with a coastline edge.** The existing `TerrainManager.set_bounds` /
   `taper_height` coast is the border.
   - **The size is undecided on purpose.** It is set by content pacing: each biome
     should arrive soon enough to keep things changing, and the player should find
     something new often enough to stay hooked. **The cars and parts should run out at
     about the same time as the regions**, so the late game is fresh in both. The ring
     sizes come out of how the car and part catalogue is split across biomes; that
     split is a design task in itself (stage 7).
4. **Forks from day one.** The road is a branching network streamed ahead of the car,
   not a single road. **How it is generated, including what a branch does at the coast
   or when it runs out of room, is a separate spec to be discussed with the user**
   (see *Dependencies*).
5. **Hard roads.** They should take real skill to drive fast. Difficulty rises per
   biome.
6. **Biome rings, chosen by distance from spawn.** Each region keeps its look and
   surfaces (as `RegionLibrary` does today) and gains a **loot table** of cars and
   parts. Rarer regions sit further out.
7. **Per-biome weather that drifts over time.** Each biome has a weather pool.
   Conditions change slowly while you drive and cross-fade at biome borders. Night
   reuses the existing headlight cone.

### Damage, temperature and rest stops

8. **Unforgiving damage, with a fixed chain** (this reverses decision 6, "damage never
   wrecks"):
   - Impacts take HP as they do today, retuned to hurt more.
   - **At `cooling_failure_hp_fraction` (about 50%) the cooling system breaks** and stays
     broken until you rest. While it is broken, **engine temperature only goes up**.
     Load and revs make it rise faster, and easing off slows it, but it never stops
     rising.
   - **Above `overheat_temp_threshold` the engine loses HP continuously.**
   - **At 0 HP the car gives up and you respawn** at the last lit rest stop, whether
     the 0 came from a crash or from overheating.
   - So once you are below about 50%, you have a limited, stretchable amount of time
     to reach a rest stop. A temperature gauge shows it.
9. **Rest stops are Dark Souls bonfires.**
   - **Driving through one lights it** and makes it your respawn point.
   - **Stopping in one opens the rest-stop page**, where you:
     - bank carried loot;
     - get a **free full repair** (HP, cooling, temperature, wheel alignment);
     - fit parts and tune;
     - swap cars;
     - read rumours;
     - **travel to any lit rest stop.**
   - **Spectators gather at every rest stop**, a repurposed `Spectators`.
10. **Loot is collected by driving near it, and is only usable once banked at a rest
    stop.** Carried loot is not yours yet.
11. **Dying drops your carried loot at the wreck**, Dark Souls-style. Drive back to pick
    it up. If you die again before reaching it, it is gone for good.
12. **No field repairs.** There are no coolant or sealant pickups. A broken cooling
    system means racing to a rest stop.

### Loot, cars and the economy

13. **Found parts replace boosts and skills.** `BoostLibrary`, `SkillLibrary` and the
    between-stage pick (`run_pick_panel.gd`) are deleted. **Engine swaps and drivetrain
    conversions become found parts** too.
14. **Parts go into a shared stash** and can be fitted to any eligible car at a rest
    stop, and moved between cars freely.
15. **No money at all.** `Save.money` / `add_money` / `spend_money` and every sink
    (`buy_car`, `buy_boost_level`, `buy_skill`, …) are deleted, along with coins
    (`CoinLayout` / `CoinField`), payouts and the shop. Everything is found.
16. **Found cars arrive as a "title" pickup.** It is carried like any other loot, joins
    the garage once banked, and you switch to it at a rest stop.
17. **Loot is fixed per world and one-time.** Placement is seeded and each pickup exists
    once.
18. **Rumours are biome teasers.** A rumour pickup reveals **the full loot list of the
    next unrevealed biome outward**, so you always learn what is just out of reach.
    Rumours are generated from the real loot tables, so they are always true.
19. **New world: choose one of a few starter cars** at the spawn rest stop.

### Front end, HUD and what goes

20. **The title screen leads straight into the world.** The hub shrinks to Continue /
    New World / Settings. The garage, map, journal and stats live in the rest-stop and
    pause pages.
21. **The map shows driven roads, lit rest stops and the ring borders you've crossed.**
    It doubles as the fast-travel picker.
22. **Lifetime stats stay, as a stats page only** (distance driven, crashes, rest stops
    lit, …). Nothing is gated on them any more.
23. **Set dressing:** start/finish arches (`FinishArch`) and roadside signs
    (`SignLayout` / `SignField`) are dropped. Barriers (`BarrierLayout`) are kept, and
    hurt more under the new damage. Spectators are kept, but only at rest stops.
24. **The pacenote strip is dropped** (`Pacenotes` and the HUD strip). You read the road
    yourself.
25. **The Rally Challenge is deleted** (daily/weekly/monthly, `ChallengeRunMode`,
    `ChallengeLibrary`, the `challenge_runs` board). This frees the whole finite-stage
    pipeline for deletion.
26. **Save profiles are wiped.** The schema version is bumped and old profiles are
    refused under the existing no-migration rule (decisions 20/34).

## Dependencies

- **`todo/road-network-generation.md` (NOT YET WRITTEN — must be brainstormed with the
  user first).** It covers the forking, streamed-ahead road algorithm on a bounded
  island:
  - how branches are spawned and spaced;
  - what a branch does at the coast or when it runs out of room;
  - overlap checks without a whole-network view;
  - the per-biome difficulty knobs;
  - how rest stops and loot sites hang off the network;
  - determinism from (world seed, branch, segment).
  Stage 0 below can run on a stand-in single road. Stage 1 onward depends on this spec.

## The core technical problem: today's world is a finite stage, rebuilt every stage

Verified 2026-10-19:

- **The road is one finished DFS.** `TrackGenerator.generate` (`scripts/track_generator.gd`)
  searches the whole point-to-point centreline up front: corner, then straight, then
  corner, with backtracking, `MAX_RESTARTS` and a 0.5 m cell overlap test against the
  full track. `TrackCache` / `data/track_cache.json` exists only because this is slow.
- **Terrain is precomputed along that finished corridor.** `bake_track` carves the road,
  cliffs, camber and jumps; then `corridor_coords` → `cache_chunk` builds every
  reachable chunk before the car moves (`features/loading.md`). The live ring is
  `RADIUS` 3 (7×7 chunks of `CHUNK_M` 50 m). Only `collision_ring` 1 has collision.
- **Props are planned from the whole centreline:** `world.gd._build_foliage` →
  `TreeScatter`, barriers, coins (`CoinLayout.plan(centerline, …)`), lakes and spectators.
- **Everything runs on one thread.** `terrain_manager.gd` says so outright: there is no
  `WorkerThreadPool` or `Thread`.
- **Each stage reloads the whole scene.** `RunSession.continue_to_next_stage` →
  `Scenes.change_to(MAIN)`, about 15 s per build headless.
- **Positions are single precision, with no floating origin.** The island is bounded
  (decision 3), so the floating origin is **only needed if the island ends up more than
  about 10 km across**. Decide that once its size is known.

**The streaming seam already exists, with nothing using it.**
`features/terrain-streaming.md` documents a bounded, streamed world mode on
`TerrainManager`, left from the deleted overworld. It is tested and live, but nothing
feeds it:

- `stream_on_miss` builds a chunk on a cache miss.
- `cache_cap_mb` + `evict_to_cap()` give an LRU memory cap.
- `set_road_source(source)` takes a duck-typed road network that drives the per-chunk
  carve and `surface_at`.
- `set_region_source(source)` with `region_rank_at(x, z)` feeds `_apply_region_blend`.
- `set_bounds` / `taper_height` make the coast (decision 3).

The plan is to **write the producers this seam was built for**, not to make
`TrackGenerator` incremental inside the stage pipeline.

## Architecture

### A. `RoadNetwork`, the streaming road producer

It implements `road_source` and grows the network ahead of the car. The algorithm is
the separate spec. The constraints that spec must meet:

- **Reuse the existing corner pieces.** `CornerLibrary` shapes and `TrackGenerator`'s
  candidate weighting (`_candidates`, `CORNER_WEIGHTS`, `STRAIGHTNESS_BIAS`) and
  `rasterize_cells` are the building blocks.
- **Committed road is never rewritten.** Backtracking happens only inside the segment
  being built.
- **Deterministic from the world seed**, so saves store only the seed plus the player's
  state.
- **The road must be committed before any chunk it touches is built.** This is the
  constraint `set_road_source` already documents. So the generate-ahead distance must
  exceed the chunk load radius plus a margin, **on every branch near the car**.
- **Water avoidance per segment.** The segment generator must check against terrain
  that may not be built yet, using `_noise_height_at` (the pure-noise height)
  (`features/lakes.md`).
- **Per-biome difficulty.** Today's per-stage knobs in `RegionStageLibrary`
  (`turn_count`, `straightness`, `terrain_layer1_amplitude`, `cliffiness`, `width`,
  `surface_mix`) become per-biome parameters in `GameConfig` or a biome table.
- **The carve moves from per corridor to per chunk.** `bake_track`'s distance field,
  cliffs, camber and `TrackProfile` jump crests are currently corridor bakes, and this
  is the riskiest port. Junction meshing, where two roads meet at a fork, is new.

### B. `BiomeRings`, regions chosen by distance

- `region_rank_at(x, z)` returns a ring index from the distance to spawn, with noise on
  the boundary. `_apply_region_blend` cross-fades looks across boundary chunks.
- `RegionLibrary.REGIONS` keeps its look and `surface_grip` entries. Its authored
  `order` becomes the ring order. It gains new `ring_min_m`, a loot table and a weather
  pool. `gate_for` / `is_unlocked` / `regions_cleared` are deleted, because distance is
  the gate.
- **Region state has to become position-based.** Today sky, fog, weather and
  `water_level` are applied once per stage (`world.gd._apply_region_look`,
  `StageConfig.apply_event_config`). They must cross-fade while you drive, and water
  level must vary per biome. **Every global `GameConfig` field a region writes needs
  auditing**, the same hazard as the reseed pre-pass (`PIVOT-CHANGES.md`, seam 2).

### C. Props per chunk

Foliage, rocks, barriers, rest stops and loot are planned when a chunk is built, from
that chunk's road segments, seeded by the chunk coordinate. `TreeScatter` and
`BarrierLayout` are already pure planners. MultiMesh bins (`billboard_field.gd`) are
built and freed along with chunks.

### D. Background threading

Chunk building now happens during play, so the plan is `WorkerThreadPool` for the
pure-data half (heights, carve, region blend), with only node and mesh creation on the
main thread. **This is the first threading in the project.** Web export needs
cross-origin isolation headers for threads; if web can't thread, the fallback is a
per-frame build budget (`overworld_chunk_build_budget` already exists).

### E. Damage, temperature and respawn (`DamageModel`)

- **What exists:** `register_deceleration` → `apply_loss`, a square-law impact curve,
  and the degradation outputs `misfire_level`, `rev_limit_fraction`, `nudge_wheels` and
  `regen`. There is no temperature code anywhere today.
- **New state:** `cooling_broken: bool` and `engine_temp: float`.
  - The cooling breaks the first time HP falls to or below `cooling_failure_hp_fraction`.
  - While it is broken, temperature rises at a rate that grows with load and revs
    (`EngineSim` throttle and rpm), above a floor rate that is never zero.
  - While it is healthy, temperature settles at its normal operating value.
  - Above `overheat_temp_threshold`, HP drains at `overheat_hp_drain_per_s`.
  - Overheating also pushes `misfire_level` and `rev_limit_fraction` up, so the car
    sounds sick.
  - The `regen` self-heal (a skill effect) is deleted with skills.
- **At 0 HP the car gives up.** This reintroduces a 0-HP event, partly restoring what
  `features/damage.md` records as deleted (the `wrecked` signal), but the consequence is
  a respawn, not a DNF. Respawning:
  - drops the carried loot as a recoverable stash at the wreck position, replacing any
    earlier dropped stash;
  - moves the car to the last lit rest stop's saved pose;
  - gives a full repair.
- **What stays free:** the ordinary stuck or flipped auto-recovery
  (`TrackProgress.recovery_pose`). It stays local, with no respawn, and puts you back
  on the road where you were.
- **HUD:** a temperature gauge plus a "cooling failed" warning, next to the Health gauge
  (`features/hud.md`). Optionally, steam from the bonnet, reusing `EngineSmoke`.
- **All rates and thresholds are `GameConfig` fields.** The tests cover the chain's
  logic, never its values (CLAUDE.md):
  - crossing the fraction breaks the cooling;
  - broken cooling raises temperature at any throttle;
  - over the threshold, HP drains;
  - 0 HP respawns and drops the stash;
  - resting clears everything.
- **Rest-stop spacing is a per-biome tunable and the main balance lever**, because it
  sets how survivable a cooling failure is.

### F. Rest stops

- **What they are.** Roadside pull-ins placed by `RoadNetwork` (spec), drawn with a
  spectator crowd.
- **Driving through lights one** and saves it as the respawn point. **Stopping inside**
  (speed under a threshold) opens the rest-stop page.
- **The rest-stop page** is a flat `MenuPage` with `MenuNav.attach` and a nav test
  (CLAUDE.md rule). It has:
  - Bank (automatic on entry);
  - Repair (automatic and free);
  - Fit parts (stash → car slots, `UpgradeLibrary` eligibility);
  - Tune (`TuningPanel` / `TuningLibrary`, moved from `StartLine`);
  - Garage / swap car;
  - Journal (rumours, found and missing items per revealed biome);
  - Map / travel;
  - Stats.
- **Travel** teleports to a lit rest stop's pose. Terrain streams in behind a short fade,
  the one acceptable "load".

### G. Loot and rumours

- **The pickup system** is a generalisation of `CoinField` / `CoinLayout`. It keeps the
  `find_pickups` drive-near proximity query and is placed per chunk.
- **Three kinds of pickup:**
  - **part:** an `UpgradeLibrary` item, an engine, or a drivetrain kit;
  - **car title;**
  - **rumour.**
- **Pickup state:** world-seeded placement plus a saved set of collected ids. Collecting
  one moves it into `carried`, and banking moves it into the stash or garage.
- **Parts must keep the effects funnel.** `UpgradeLibrary.EFFECTS` stays the only
  modifier path (decision 51 / seam 1). The car's fitted parts become **the single
  writer** merged in `world.gd._field_car`, replacing the boost and skill writers.
- **Loot tables live per biome** (cars plus parts). The catalogue split across biomes is
  the pacing tool (decision 3). Tests use synthetic tables, never real catalogue entries
  (CLAUDE.md).
- **A rumour** reveals the next unrevealed biome's loot table in the journal.

### H. The world session (replaces `RunSession` / `RunMode`)

- A persistent `WorldSession` autoload, saved continuously. It holds:
  - world seed;
  - car pose;
  - lit rest stops;
  - last rest stop;
  - carried loot;
  - dropped stash (position + items);
  - collected pickup ids;
  - stash;
  - garage (with fitted parts and tuning);
  - revealed biomes;
  - driven-road record for the map;
  - lifetime stats.
- `world.gd`'s `_ready` sequence (`_generate_track` → `_wire_session_and_stage`) is
  replaced by: boot → stream around the saved pose → drive. There are no
  `Scenes.change_to(MAIN)` reloads in play.

## What gets deleted

| Area | Goes |
|---|---|
| Stage loop | `RunSession` / `RunMode` / `RegionRunMode` / `ChallengeRunMode`, `StageManager`'s countdown and clock, `StartLine`, `RivalGhost`, `LapTimeModel`, `stage_config.gd`'s per-stage writer (audit what the biome look still needs from it) |
| Finite tracks | `RegionStageLibrary` / `RegionStagePool` / `StageFields`, `TrackCache` + `data/track_cache.json` + `cache_*.sh` + the pre-commit regen hook, the seed-3002 full-library generation guard (about 140 s of the suite) |
| Economy | money, coins, the shop, `buy_*` sinks, payouts, `BoostLibrary`, `SkillLibrary` (lifetime stats stay as a stats page) |
| Challenge | `ChallengeLibrary`, the entry screen, the `challenge_runs` Firestore board and its rules |
| Dressing | `FinishArch`, `SignLayout` / `SignField`, `Pacenotes` + the HUD strip, corner-cut penalty (`TrackProgress._accrue_cut`) |
| Front end | most `HubShell` views. What remains: title, Continue / New World / Settings, and new-world starter car choice |
| Misc | `FreePlay` (absorbed), the REGION page, region unlock gating |

Check each before deleting, using the `PIVOT-CHANGES.md` approach: read the callers,
not just the file. `MenuShowcase` (the hub's 3D background) probably goes with the hub.

## Staging (each stage depends on the ones before it)

0. **Spike: streaming on a stand-in single road, in a dev scene. No gameplay.** A
   minimal road source + `stream_on_miss` + `set_bounds`, driving across a 5+ km island
   with no hitch. This proves the streaming before the road spec lands. **Opus
   planning pass first** (CLAUDE.md model posture).
1. **The road network (blocked on the road spec)**, plus per-chunk carve with cliffs,
   camber, jumps and junctions.
2. **Background chunk building** (threading spike, web check, budget fallback).
3. **Per-chunk props:** foliage, rocks, barriers.
4. **Biome rings:** `BiomeRings`, position-based sky, fog and water, drifting weather,
   per-biome difficulty.
5. **Damage chain and rest stops:** temperature, cooling failure, overheat drain,
   0-HP respawn, lighting, free repair, travel, spectators at rest stops. The
   rest-stop page at this stage: repair, tune, travel.
6. **The world session and save:** `WorldSession`, schema bump (profile wipe), title →
   world, the map page.
7. **Loot:** pickups, carried / stash / garage, the dropped stash, part fitting,
   car titles, starter choice, rumours + the journal, **biome loot tables and the
   catalogue-to-biome pacing pass** (which then fixes island and ring sizes).
8. **Demolition and docs:** delete the stage loop, economy and challenge. Rewrite
   `gameplay.md`, `PIVOT-CHANGES.md` and the affected `features/` docs. Then a full
   test run.

Stages 0–4 can be played as a pure drive, and should be playtested before 5–7.

## Hazards

- **Test suite.** Deleting the full-library generation guard removes about 140 s. Its
  replacement (stream N km of network, assert no dead end, hole or hitch) must stay
  cheap.
- **Whole-track assumptions.** `bake_track`'s distance field, `TrackProfile` crests
  keyed on arc distance, and `TrackProgress`'s single-centreline offset all assume one
  finished curve. On a network, "nearest road" and recovery have to work per branch.
- **Mobile and web performance** (`todo/mobile-web-performance.md`). Streaming in play
  inverts today's "pay everything behind the loading screen".
- **Global config writes.** Position-based region looks will expose every place a
  per-stage global was assumed constant for the whole scene.

## Still open

- **Island and ring sizes:** they follow from the catalogue-to-biome pacing pass in
  stage 7.
- **Everything in `todo/road-network-generation.md`:** to be brainstormed with the user.

## Road-network lab — the liked preset (2026-10-20)

`tools/road_network_lab.html` is a throwaway browser spike for comparing network layouts and
road-first terrain. The user liked the terrain these values produce; they are now the lab's
defaults. They are a starting point for the road-network spec, not tuned game values.

- **Layout: radial growth.** Island radius 12000 m, 5 biome rings, node min spacing 150 m,
  rest stop every 1500 m of road. Growth sliders: segment 250 m, fork chance 0.18, fork angle
  90°, heading jitter 60°, outward pull 0.35, join-on-collide 1.0, 3 roads leaving spawn.
  Road wiggle preview on.
- **Base field and lakes:** base height scale 1100 m, base height variation 150 m, water level
  −70 m, lake depth factor 1.5, shore band 15 m.
- **Road-first terrain:** mountain height 1000 m, flat band beside road 6 m, distance to full
  mountain 1950 m, ribbon bank/drop 100 m, ribbon width 400 m.
- **View only (no effect on the terrain):** contour interval 100 m, 3D area 8000 m, 3D
  resolution 240, exaggeration 1.5.
- **Several of these sat at the slider maximum** (radius, fork angle, jitter, join chance,
  mountain height, bank, ribbon width). The ranges have since been widened, so the preference
  may lie beyond them.
