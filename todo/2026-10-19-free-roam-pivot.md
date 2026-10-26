# Free-roam pivot — island road network, biome rings, rest stops (2026-10-19)

**Status: IMPLEMENTED (autonomous build, 2026-10-20) — stages 0–8 landed; see *Decision log*
for the calls made without the user, REVIEW items first.** Prototype ACCEPTED (2026-10-20). The user declared the prototype a
success. **The road and terrain method is settled:** the whole network is laid out at boot
by radial growth (`RoadNetwork`), the terrain is built from the roads (`RoadTerrain`), and it
streams under the strict per-frame budget (`TerrainStreamer`). Do not revisit corridor
carving, streaming the network ahead of the car, or the `TerrainManager` seam. Design questions were
resolved with the user on 2026-10-19 (see *Decisions*). A free-roam prototype now exists
and the game boots into it (`features/free-roam.md`). It covers stage 0 and parts of
stages 1, 3 and 4 (see *Progress* and *Staging*). The prototype took a different technical
route from the one first sketched below: the whole road network is built at boot, a new
`TerrainStreamer` replaces the `TerrainManager` streaming seam, and terrain is built around
the roads instead of being carved into them. Sections that route makes stale are marked
**(superseded)** where they stand. This file is the decision record for the pivot. It
supersedes `todo/roguelike-pivot.md` wherever they disagree, and `gameplay.md` gets
rewritten to match.

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
4. **Forks from day one.** The road is a branching network, not a single road.
   **Resolved 2026-10-20:** the network is laid out whole at boot rather than streamed
   ahead of the car, and dead ends are allowed, each with a payoff (*Road network
   decisions*, 27–32).
5. **Hard roads.** They should take real skill to drive fast. Difficulty rises per
   biome. **Amended 2026-10-20:** the first version uses the **same road settings
   everywhere**. Rising difficulty per biome is deferred until after playtesting (see
   *Road network decisions*).
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

## Road network decisions (resolved with the user, 2026-10-20)

These replace the planned `todo/road-network-generation.md`, which won't be written.
Building the whole layout at boot (`RoadNetwork._grow` / `_densify`) removed the questions
that spec was for: overlap checks without a whole-network view, generating ahead of the
load radius, and determinism per branch.

27. **The method is the prototype's.** The whole network is laid out at boot by radial
    growth, terrain is built from the roads, and it streams under the per-frame budget
    (see *Status*).
28. **Same road settings everywhere, for now.** The wiggled roads (`road_twist`,
    `bend_length_m`) and every growth setting stay global on `FreeRoamSettings`. Harder
    roads per biome (tighter wiggle, `CornerLibrary` hairpins) are **deferred** until a
    playtest says the roads are too easy. Don't build per-biome road knobs speculatively.
29. **No stage road features come back.** No camber, jump crests, sheer cliff drops or
    separate road edge mesh. Roads stay level across and roll with the bumps, and the
    road reads from the ground texture or tint by distance to the road, as in the
    prototype.
30. **Dead ends are allowed, and every one has a payoff.** A dead end is a node with
    only one road (other than spawn). `_grow` already makes them when a branch hits water
    or road it doesn't join. Each one gets something worth the drive: a loot site, a
    rumour or a lookout. Stage 7 decides which.
31. **Rest stops are placed by distance along the road, with spacing set per biome.**
    They're planned at boot from the whole graph, every N metres of road, and spawned
    when their chunk builds. N is a **per-biome setting that starts at the same value in
    every ring** (300 m, from the lab), so tuning it later is a data change. **Loot sites**
    sit on short pull-ins along roads, plus the dead-end payoffs. Their density per biome
    comes from the stage 7 pacing pass.
32. **The game diverges from the lab from now on.** The game is the reference. Rest stops,
    loot sites and payoffs are built in GDScript only, and `tools/road_network_lab.html`
    becomes a stale sketch tool. The bit-exact lab test
    (`test_the_random_stream_and_hash_match_the_lab_javascript`) may go once a change
    breaks parity. Keep same-seed determinism tests.

Still to check, not to decide: whether the boot build stays cheap if the stage 7 pacing
makes the island bigger than its current 5 km radius.

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
- `set_region_source(source)` with `region_rank_at(x, z)` feeds the per-chunk region look blend (the original `_apply_region_blend` was removed).
- `set_bounds` / `taper_height` make the coast (decision 3).

The plan is to **write the producers this seam was built for**, not to make
`TrackGenerator` incremental inside the stage pipeline.

**(superseded 2026-10-20.)** The prototype doesn't use this seam. Instead it adds
`TerrainStreamer` (`scripts/free_roam/terrain_streamer.gd`), which has its own chunk size
(64 m vs `CHUNK_M` 50 m), two detail levels, a strict per-frame time budget and per-chunk
foliage (see *Streaming method* below). It still holds that `TrackGenerator` isn't made
incremental. Once the prototype is the game, the `TerrainManager` streaming mode
(`stream_on_miss`, `set_road_source`, …) and the overworld budget field have no user. Audit
them for deletion in stage 8, along with the corridor pipeline.

## Architecture

### A. `RoadNetwork`, the streaming road producer

> **(largely superseded 2026-10-20.)** `RoadNetwork` exists, but it builds the whole
> network at boot, so "grows ahead of the car", "committed road is never rewritten" and
> "generate-ahead distance" no longer apply. It doesn't reuse corner pieces, and that's deferred
> (decision 28). The carve isn't ported either: `RoadTerrain` makes height a
> pure function of distance to the nearest road, so roads are level across, junctions come
> for free and there's no corridor bake. Cliffs, camber and jump crests from the stages
> don't come back (decision 29). Water
> avoidance (`_seg_hits_water` against the base field) and seed determinism are done. The
> text below is the original sketch.

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
  the boundary. The region look blend cross-fades looks across boundary chunks (the original `_apply_region_blend` was removed).
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

> **(superseded 2026-10-20)** by the strict 1 ms per-frame budget with a cooperative
> scheduler (*Streaming method* below). It's built, and it's the baseline everywhere because
> web exports have no threads. Threads become a later optimisation for desktop and
> Android, using the same job design.

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

- **What they are.** Roadside pull-ins placed by `RoadNetwork` by distance along the road (decision 31), drawn with a
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

## Progress (2026-10-20)

Landed in `aa7ee9d` ("Add free-roam prototype"). Source is `scripts/free_roam/` and
`free_roam.tscn`; tests are `tests/headless/test_free_roam.gd` (20 tests); docs are
`features/free-roam.md`.

- `project.godot` boots `free_roam.tscn`. **The hub and the region run can't be reached in
  the shipped game** until something links back to them.
- **Layout:** `RoadNetwork` builds the island's whole network at boot, matching the lab
  preset exactly (5 km radius, 3 rings). It answers allocation-free `nearest` and
  per-chunk `candidates_for` queries.
- **Terrain:** `RoadTerrain` builds road-first height (base field, lakes, mountains away
  from roads, ribbon banks, coast, Perlin bumps), all pure functions of position.
- **Streaming:** `TerrainStreamer` streams under a strict 1 ms budget with measured
  atomic units, two detail levels, collision near the car, skirts, priority by predicted
  position and a boot `prefill`.
- **Foliage:** trees, bushes and rocks are planted per near chunk through `Foliage`, with
  per-ring `tree_mix` and rock density, and freed along with the chunk.
- **Rings:** `RoadTerrain.ring_index` / `ring_tint`. Ring i wears region i's look, but
  only as a vertex tint and foliage mix.
- **Driving:** the car spawns on the road, `surface_at` reads road / off-road per wheel,
  and **R** puts the car back on the nearest road. A debug label shows streaming stats.
- **Measured** (headless, car parked): 15.6 µs per sample, 843 ms prefill, worst frame
  1.04 ms. It hasn't been measured with the car driving at speed.
- **Not in the prototype:** the game HUD (speed, health), mobile touch controls, a pause
  or settings page, audio checks, stuck or flipped recovery, barriers, rest stops,
  pickups, damage consequences, and saving. Settings live on `FreeRoamSettings`, not
  `GameConfig`.

## Staging (each stage depends on the ones before it)

Reviewed 2026-10-20 against the prototype. Each stage notes what's done and what changed.

0. **Streaming spike — DONE (auto driver landed 2026-10-20).** It went further than planned: it runs on the real
   lab network rather than a stand-in road, with a new streamer instead of the
   `TerrainManager` seam. **Remaining:** the auto driver. It drives a fixed route across
   the island at top speed, reports budget overruns and any chunk reached without
   collision, and backs a cheap headless regression test. The original exit criterion,
   "5+ km with no hitch", has only been checked while parked.
1. **The road network — DONE 2026-10-20** (`RoadSites`, `features/free-roam.md` → *Sites*). Layout and terrain DONE.
   Remaining:
   - rest stop positions, every N m of road with N per biome (decision 31);
   - a list of dead-end nodes, for the payoffs (decision 30);
   - loot site pull-in slots along roads, so stage 7 has somewhere to put things.
   Road character, camber, crests and edges are settled as "no change" (decisions 28–29).
2. **Background chunk building — REPLACED by the budget scheduler. Headless hardening DONE
   2026-10-20** (spin bug, peak-based stops, spawn estimates, shader warm-up). **Still owed: a
   real phone and a web export.** It is now **performance hardening**: measure on a real mid-range Android phone and on a web export
   (`todo/mobile-web-performance.md`), warm up shaders at boot, and move the height
   maths to GDExtension or threads only if those measurements say so. It can run
   alongside stages 3–4 rather than strictly between them.
3. **Per-chunk props — DONE 2026-10-20** (barriers, bush brushing; trees already fell). Foliage and rocks DONE. Remaining: barriers. `BarrierLayout`
   plans from a single centreline, so it needs to work per road and per chunk, and it
   needs a rule at junctions. Also remaining: bush brushing (`BushField` hit-and-drag)
   and knocking trees over.
4. **Biome rings — DONE 2026-10-20** (`BiomeDirector`, `features/free-roam.md` → *Biomes*). Ring index, tint and foliage DONE. Remaining:
   - position-based sky, fog and weather that cross-fade at borders (the `GameConfig`
     global-write audit in §B);
   - per-ring `surface_grip` and surfaces, since `surface_at` is only road / off-road
     today;
   - per-ring water level;
   - noise on the ring borders.
   Per-biome road difficulty is deferred (decision 28).
   §B still says "region state has to become position-based" — that holds.
4½. **NEW — a playable shell, before the playtest gate. DONE 2026-10-20** (`features/free-roam.md` → *The shell*). Stages 0–4 are meant to be
   playtested as a pure drive, and mobile is a target, so the prototype needs:
   - the game HUD (speed, Health gauge, later the temperature gauge);
   - mobile touch controls;
   - a pause page (`MenuPage` + `MenuNav.attach` + nav test) with Settings and a way to
     reset the car;
   - stuck or flipped auto-recovery made network-aware. `TrackProgress` assumes one
     centreline, so recovery should reuse `free_roam.gd._road_pose`.
   The hub stays unreachable until stage 6 rewires title → world. Moving
   `FreeRoamSettings` onto `GameConfig` / `game_config.tres` (CLAUDE.md: tunables live
   there) can happen here or in stage 6, once the knobs have settled.
5. **Damage chain and rest stops — DONE 2026-10-20** (`features/free-roam.md` → *Damage and rest stops*). Temperature, cooling failure,
   overheat drain, 0-HP respawn, lighting, free repair, travel, spectators at rest stops.
   The rest-stop page at this stage: repair, tune, travel. Needs rest stop positions from
   stage 1. Rest stops can also seed `prefill` for the fade on travel.
6. **The world session and save — DONE 2026-10-20** (`features/world-session.md`). `WorldSession`, schema bump (profile wipe),
   title → world (replacing the direct `run/main_scene` boot), the map page. The map is
   cheap now because the whole network is known at boot: draw it and mask it to driven
   roads.
7. **Loot — DONE 2026-10-20** (`features/loot.md`). Pickups, carried / stash / garage, the dropped stash, part
   fitting, car titles, starter choice, rumours and the journal, and **biome loot tables
   with the catalogue-to-biome pacing pass**. That pass then fixes the island and ring
   sizes. A bigger island loops back to stage 1 (build cost) and to the floating-origin
   check: today's 5 km radius is already about 10 km across, right at the threshold in
   *The core technical problem*.
8. **Demolition and docs — DONE 2026-10-20** (`PIVOT-CHANGES.md` → *The free-roam pivot*), with
   the stage scene kept as a dev stage and test harness (D68). Originally: the `TerrainManager` streaming mode, the
   corridor pipeline (`bake_track`, `TrackGenerator`, `TrackCache`), and possibly
   `MenuShowcase` and most of `HubShell`. Rewrite `gameplay.md`, `PIVOT-CHANGES.md` and the
   affected `features/` docs. Then a full test run.

Stages 0–4½ can be played as a pure drive, and should be playtested before 5–7.

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
- **What each dead-end payoff is** (loot site, rumour or lookout): stage 7.
- **Harder roads per biome:** deferred until after a playtest (decision 28).

## Road-network lab — the liked preset (2026-10-20, revised)

`tools/road_network_lab.html` is a throwaway browser spike for comparing network layouts and
road-first terrain. The user's current favourite settings are below. They are the lab's
defaults, and also the `FreeRoamSettings` defaults the game boots with. They are a starting
point for the road-network spec, not tuned game values. The revision replaced an earlier
12 km preset with a much smaller, denser island.

- **Layout: radial growth, seed 1.** Island radius 5000 m, 3 biome rings, node min spacing
  75 m, rest stop every 300 m of road. Growth: segment 175 m, fork chance 0.37, fork angle 150°,
  heading jitter 120°, outward pull 0.44, join-on-collide 1.0, 3 roads leaving spawn. Road
  wiggle on, road twistiness 1.0, bend length 200 m.
- **Base field and lakes:** base height scale 500 m, base height variation 15 m, water level
  −5 m, lake depth factor 1.6, shore band 1 m.
- **Road-first terrain:** mountain height 300 m, flat band beside road 2 m, distance to full
  mountain 400 m, ribbon bank/drop 47 m, ribbon width 320 m. Bumps (Perlin):
  height 5 m, size 50 m.
- **View only:** contour interval 135 m, 3D area 8000 m, 3D resolution 800, exaggeration 1.0.
- **Fork angle and heading jitter** sat at the slider maximum, and segment length and
  rest-stop spacing at the minimum. Those ranges have been widened.
- **The game's network won't match the lab exactly** for the same seed: the GDScript port
  uses Godot's random number generator and `FastNoiseLite` rather than the lab's own noise.

## Streaming method — a strict per-frame terrain budget (agreed 2026-10-20)

**The rule:** terrain work gets at most **2 ms per frame** (raised from 1 ms on 2026-10-23) (now a share of the spare frame time: `TerrainStreamer.budget_us()`, 2026-10-25), and
nothing that would overrun it may start. The car drives while the world fills in around it.
The old streaming seam budgeted by count (`overworld_chunk_build_budget = 2` chunks per frame),
which is how it produced 13–34 ms spikes (`features/terrain-streaming.md`).

- **The arithmetic:** at 60 fps, 1 ms per frame is 60 ms of compute per second of driving. At
  about 55 m/s with a 350 m load radius either side, that is about 38,500 m² of new ground per
  second, which leaves roughly 1.5 µs per 1 m² sample, all-in. So:
  - full detail only near the car, with far chunks sampled every 4–8 m;
  - generation ahead along the known road network rather than in a ring around the car;
  - unlimited prefill at boot, and later at rest stops;
  - native code (GDExtension) for the per-sample maths if GDScript can't keep up.
- **A cooperative, measured scheduler.** Each chunk is a resumable job, with plain state and
  no coroutines. Every atomic unit kind keeps a moving average of its cost on the running
  device. A unit never starts if its estimate exceeds what is left of the frame; the first
  unit of a frame always runs, so it can't starve. Overruns are counted and shown on screen.
- **Atomic units:** gather road candidates → heights one sample at a time → pack mesh arrays →
  upload the mesh → attach → collision. Engine calls that can't be split (mesh upload, heightmap
  collision, MultiMesh upload) must have inputs sized to fit a unit, which makes **chunk size,
  sub-mesh size and foliage bin size budget-driven settings**.
- **Priority by time to arrival.** Collision under and ahead of the car first, then a coarse
  mesh ahead (never a hole), then full detail near the car, then foliage, far detail and
  eviction. Falling behind degrades detail, never the budget.
- **What the timer won't see:** physics work that adding a shape pushes into the next physics
  step, shader compilation (warm it up at boot), and allocation churn. Total frame time is the
  real measure.
- **Threads later, same design.** Web exports have `thread_support=false`, so main-thread
  time-slicing is the baseline. On desktop and Android the pure-data stages can move to
  `WorkerThreadPool` later, leaving only the engine calls on the main thread.

**Prototype status (2026-10-20):** implemented in `scripts/free_roam/`, and the game boots into
it (`features/free-roam.md`). First headless measurement on desktop: 15.6 µs per height sample
in GDScript, 843 ms boot prefill, and 5 of 600 frames slightly over 1 ms (worst 1.04 ms) with
the car parked, before tightening the per-sample stop. Next: an auto driver that drives a
fixed route at top speed and reports overruns and "reached a chunk without collision".


## Decision log (autonomous run, 2026-10-20 onward)

While the user was away, the remaining stages were implemented autonomously. Each call made
without the user is logged here for review. **REVIEW** marks the ones most worth a look.
Numbering continues from decision 32.

- **D33. The auto driver's route avoids dead ends and stops at one.** Pure pursuit can't
  turn round at a dead end, so a route ends there instead. Cheap to change (`plan_route`).
- **D34. Budget overruns are reported, not asserted.** The headless test asserts only "no
  holes" and real progress. Overrun counts depend on the machine and its load, so a
  threshold would make the test flaky. Overruns are followed up in stage 2.
- **D35. The streaming readout shows in debug builds only, toggled with H**, the same key as
  the other dev overlays. Release builds never show it.
- **D36. Free roam's pause menu has no Photo Mode, and "Quit to HQ" goes to the old hub**
  until stage 6 rewires title → world. Photo mode needs `world.gd`'s free-fly camera host; it can
  be ported later if wanted.
- **D37. Fixed a `PauseMenu` bug that also affected the stage.** The settings panel started
  visible, so the very first open put the cursor on Settings instead of Resume. It now starts
  hidden. Also fixed an existing ternary type warning in `spike_id_pass.gd`, which GUT reports
  as an error once a test loads the post-process scene.
- **D38. REVIEW — rest stops are dense at the decided 300 m.** On the default island that's
  147 rest stops on 48 km, one every 20 s or so at speed. A cooling failure is then barely a
  threat. I kept 300 m because it's what we agreed (decision 31); it's one number per ring in
  `FreeRoamSettings.rest_stop_spacing_m`. My guess is 800–1500 m once the damage chain is in.
  **2026-10-22:** raised to 600 m per ring at the user's request.
- **D39. Loot slots every 400 m of road**, kept 40 m clear of rest-stop pads, which gives 78 on the
  default island. They're slots: stage 7 decides which hold loot.
- **D40. Sites are flat pads that read as road** (gravel texture, road grip, no foliage). The
  spawn rest stop is centred on the spawn junction. Each site sits at least 45 m from a junction
  along the road.
- **D41. Placeholder coloured posts mark sites** until real rest-stop and loot models exist
  (`site_markers`).
- **D42. Barriers are planned at boot and built per chunk**, rather than planned per chunk. The
  whole graph is known, so a bend's run never splits across a planning boundary. A sharp bend
  is a vertex turning more than 28°. Falling land is judged once per three modules, which cut
  planning from 0.65 s to 0.3 s. **REVIEW:** with roads in valleys, the stage's "land falls
  away" rule leaves very few barriers (about 190 modules on 48 km). Lowering
  `barrier_drop_min_m` or the turn threshold adds more.
- **D43. REVIEW — four rings: home, greece, taiga, snow** (`FreeRoamSettings.ring_regions`).
  `home_coast` is left out because its only identity is a raised stage waterline, which free
  roam doesn't have (D44). Snow is in, because it's the region with its own handling. The
  island's ring layout changes from the lab's 3 rings to 4.
- **D44. REVIEW — one water level for the whole island.** The plan asked for water level per
  biome, but lakes, the coast and road water-avoidance all come from one sea level in
  `RoadTerrain`. A per-ring level would need ring-aware lake maths and a water mesh per ring. I
  judged it not worth it for v1.
- **D45. Weather drifts in 3-minute slots** of driving time. Each (ring, slot) is a seeded
  weighted draw from the ring's pool (`ring_weather`). Driving back and forth across a border
  can flip the weather, but the cross-fade softens it.
- **D46. Biome borders switch per chunk** (64 m) for ground textures. The sky, fog and colour
  cross-fade over 4 s, and the panorama swaps at the midpoint behind a fog swell. The prototype's
  strong debug ring tints are gone: each ring's tint is now its region's `terrain_tint` (white
  default), as on the stage.
- **D47. Not ported:** storm lightning; night's terrain re-bake (night darkens the ground with
  the albedo tint only); re-lighting foliage that was already spawned when the weather changes.
- **D48. The stage 4 "Opus planning pass" was done inline.** This session already runs on Opus,
  so a planning subagent would have been the same model re-reading the same context.
- **D49. Found and fixed a streaming bug:** a stage that ran out of frame told the queue to
  carry on, so the queue spun until the deadline. Fixing it, plus peak-based stop rules and
  per-size spawn estimates, took over-budget frames on the 3 km auto drive from 36% to 2.2%.
  The rest are mostly a single sample's worth of overshoot.
- **D50. REVIEW — no device measurements.** I couldn't run on a phone or a web export here.
  Headless desktop numbers: about 29 µs per height sample and a 1.1 s boot prefill. GDExtension
  or threads stay unneeded until a device says otherwise (`todo/mobile-web-performance.md`).
  Boot shader warm-up covers the ring ground materials only, not foliage or weather particles.
- **D51. The thermal chain is opt-in per car (`DamageModel.thermal`)**, on in free roam and off on
  the stage, so the stage keeps "damage never wrecks" until stage 8 deletes it. **REVIEW the
  starting rates:** flat out, a broken cooling system reaches the overheat threshold in about
  27 s; with a light foot, up to about 2 minutes. HP then drains at 25 HP/s, so a car that's just
  below half health has about 20 s more after that. All of it is in `GameConfig`.
- **D52. REVIEW — impacts were not retuned.** Decision 8 says "retuned to hurt more", but a
  60 km/h hit already costs 560 HP (capped at 640) on a pool of about 1000. I left it for the
  playtest rather than guess.
- **D53. Arriving at a rest stop repairs for free, the moment the page opens**, and the game is
  frozen while the page is up. Travel also repairs (you arrive at a rest stop). Travel is only
  offered from the rest-stop page, not the pause menu. Stage 6's map page will become the travel
  picker (decision 21).
- **D54. REVIEW — a respawn or travel is an instant teleport behind a synchronous prefill**
  (about 1 s headless). There's no fade overlay yet, so the screen holds on the last frame
  for that long.
- **D55. Rest stops look like a beacon post** (grey, orange once lit) plus a static crowd of 14
  onlookers. There's no building model; that's an art task.
- **D56. REVIEW — every new world gets a random seed** (1 to 999,999). The lab's liked preset was
  seed 1, and seeds vary in quality, so a bad one is possible. There's no seed curation or
  "reroll". Easy to change in `TitleScreen._start`.
  **Superseded:** every world now uses the fixed `FreeRoamSettings.world_seed` (commit 486c78d8).
- **D57. A new world also wipes the owned cars.** A world is the whole save (decision 2), and cars
  are found in the world (decision 16).
- **D58. The starter choice is the 3 cheapest cars by `cost`.** It's a rule, not a list, so it
  survives roster changes. **REVIEW** whether those three are the right starters.
- **D59. A new title scene (`title.tscn`) is the main scene**, rather than cutting `HubShell` down.
  The hub is now unreachable, and stage 8 deletes it. The world saves pose and condition every
  5 s, map cells every 0.25 s (through `Save`'s 1 s debounce), and on quitting.
- **D60. The map** draws ring borders as their average circles, and roads by 40 m driven cells.
  At a rest stop it is the travel picker. The rest-stop page keeps its Travel list too (cheaper
  to use with a gamepad), plus a Map button.
- **D61. Stats in free roam:** distance driven, rest stops lit and times the car gave up. Two new
  `LifetimeStats` ids; the run-era ones go in stage 8.
- **D62. Parts are the former boosts, found at level = ring**, plus the four swap-tier engines and
  the three drivetrain kits. A car takes one of each part id, one engine and one kit (a new one
  swaps with the fitted one), and a kit for its own layout only in place of another kit (changing it back, Felix 2026-10-23). Parts reach the car only through
  the funnel keys (`LootRules.fielded`).
- **D63. A rumour is read on pickup**, not carried and banked, because knowledge can't be dropped
  at a wreck. Ring 0's loot is known from the start.
- **D64. Changing parts or car reloads the scene at the rest stop** (about 1–2 s), so the car is
  fielded through the full `apply_owned` path rather than re-staged live, which `car.gd` warns
  against.
- **D65. ~~A car title for a model you already own still grants a second car.~~** Superseded by
  D77: a car you own is no longer in the pool, so its title never shows.
- **D66. REVIEW — the pacing pass.** The island stays at 5 km radius with 4 rings. That gives 12–14
  finds per ring; ring 0's 12 sites are exactly full, and the outer rings have about twice as many
  sites as items, so many slots are empty. Levers: `loot_slot_spacing_m`, or more items (e.g. two
  levels of each part per ring).
- **D67. Loot looks like a coloured crate under a light beam, by kind.** A dead end with no item
  left is a "lookout" with nothing on it (decision 30's third option). The HUD toasts each find.
- **D68. REVIEW — the stage scene (`main.tscn` / `world.gd`) survives as a dev stage and the
  physics test harness**, not deleted. About 40 test files (car physics, damage, collisions, the
  benchmark, seed lab) build their world on it, and re-homing them onto free-roam terrain is its
  own project. So `TrackGenerator`, `TerrainManager`'s corridor bake and streaming mode,
  `StageManager` (countdown, clock, corner-cut penalty), `TrackProgress`, `RegionStageLibrary`,
  `StageFields` and `StageConfig` stay. Nothing in the game reaches them. `world.gd` went from
  2,816 to about 1,750 lines. Suggested follow-up spec: "port the physics tests to a free-roam
  or flat harness, then delete the corridor pipeline".
- **D69. `BoostLibrary` is kept as the parts catalogue.** Decision 13 said "BoostLibrary
  deleted", but parts *are* the boosts, so its catalogue and level scaling stay. The run draw,
  categories, purchased levels and shop helpers are gone.
- **D70. The settings Dev page** lost Add money / Unlock all skills / Complete stage and gained
  "Reveal all biomes" (fills the journal). F (skip to finish) still works on the dev stage.
- **D71. CI:** the `verify-caches` gate (track lockfile) is replaced by a `compile-check` gate
  (`tools/compile_check.tscn`: every script and scene loads with the autoloads present).
- **D72. REVIEW — dead `GameConfig` fields were left in place** (signs, coins, arches,
  pacenotes, start line, rival pace, run economy, skills). Removing them means editing
  `game_config.tres` and the config tests in one sweep; worth a `/housekeeping` pass.
- **D73. `todo/` specs for deleted systems were NOT deleted** (`region-stage-slots-redesign.md`,
  `mid-run-upgrade-menu.md`, parts of `backlog.md` and `roguelike-pivot.md`). `CLAUDE.md` says to
  ask before removing todo items. Please decide.
- **D74. Two dev tools that were already broken were deleted** (`map_pin_capture`,
  `start_line_capture`), along with the sign tools and the menu-showcase cache generator.
- **D75. Final full test run (2026-10-20): 2,264 of 2,266 pass, in 254 s** (under the ~5 min
  budget again; the deleted seed-3002 full-library guard was about 140 s of it). **REVIEW — the 2
  failures were already failing before this work:** `test_nitrous.gd` →
  `test_holding_nitrous_makes_more_torque` and `test_a_bigger_gain_makes_more_torque` fail with
  identical numbers on `aa7ee9d`, the commit this session started from. The likely cause is the
  earlier "Ramp crank torque down over 100ms on cut" change: a stronger engine reaches the limiter
  sooner within the test's 150-tick climb and spends time in the cut. I didn't change engine
  physics or loosen the tests; the call is yours.

### After the build (2026-10-20, user feedback)

- **D76. Menus are card lists again** (user ask: "reuse the card list"). `CardCarousel` / `CardUI`
  are back from before the demolition; every menu that is a list of choices is a card list
  (features/card-carousel.md). Settings, Tune car and the map stay plain pages because they are not
  lists. The hub's spinning 3D car previews are back too (user ask) on the starter choice and the
  Garage; the Journal keeps icons, because building a dozen car props at once is a visible hitch.
- **D77. The pool replaces fixed placement (supersedes decision 17's "placed once" and D65).**
  User ask: every car and part fully unique, plenty of places it can spawn, gone from all of them
  once owned or picked up, and a biome's pull-ins empty once its things are found
  (features/loot.md → "The pool"). Calls I made: **(a)** with more sites than items an item shows at
  several sites at once (every one empties when it's taken) rather than leaving sites blank;
  **(b)** a site you pick something up from is spent for good (user ask, 2026-10-20); a ring with
  more items than free sites moves its lesser items to the nearest ring with sites to spare; **(c)** a lost drop's items go back into the pool rather than vanishing; **(d)**
  loot pull-ins every 150 m of road (was 400). **REVIEW (a).**
- **D78. REVIEW — the road network's size varies a lot by world seed.** The default island reaches
  all four rings, but e.g. seed 7 grows only 22 nodes / 5 km of road and never leaves rings 0–1.
  A ring with no loot sites folds its loot into the nearest ring that has some (D77), so nothing is
  unreachable, but such a world has only two biomes. New worlds take a random seed. Worth a
  minimum-size rule in `RoadNetwork._grow` (re-seed or keep growing until the network reaches the
  outer ring) — not done, it changes world generation.
- **D79. Beacons.** Every rest stop and piece of loot has a tall beam visible from far away
  (`SiteBeacons`, `GameConfig.beacon_*`), fainter the further off it is. Loot's floating name ("New car", …) was removed on 2026-10-23:
  the pickup toast already says what was taken. The rest-stop beams went too on 2026-10-23
  (Felix): rest stops now have log cabins, and `SiteBeacons` and `GameConfig.beacon_*` are deleted.
- **D80. No menu paints an opaque backdrop.** `UITheme.MODAL_DIM` is 0.7 alpha (was 0.96), and the
  plain pages (Tune car, Settings, Map) have see-through body boxes. **REVIEW — the title screen
  still has a solid background:** there is no world behind it yet. Options: render the island
  behind the title, or a static backdrop.
- **D81. Mobile pedals:** the GAS / BRAKE column is `GameConfig.mobile_pedal_band_frac` (0.36) of
  the screen height, up from a fixed 0.20. Steer buttons are unchanged.
- **D82. The minimap** (features/minimap.md): heading-up, tilted like a nav app, top-centre; driven
  roads plus faint undriven road just ahead; rest stops and loot once seen (`WorldSession` "seen",
  within 150 m). Tap it, or press M / gamepad Back (the existing `toggle_map` action), for the full
  map; closing that goes straight back to driving. **REVIEW:** its size is capped so it stays above
  the simple touch scheme's steering zones (top 20% of the screen) — a bigger minimap means moving
  those; loot shows as a blue diamond; the full map still shows the whole island, so a short drive
  is small on it.
- **D83. No stopping needed** (user ask): driving past loot or a rest stop, at any speed and on
  either lane, picks the loot up / lights the stop and fully heals the car (swept check,
  `RoadSites.reached`). Stopping at a rest stop is only for its page. Beams fade out towards their
  tops; the minimap has no rim or edge line.
- **D84. Quick travel from the map, anywhere** (user ask), and the map frames what's been explored.
  **REVIEW:** travelling repairs the car (as at a rest stop), so a player whose cooling has failed
  can open the map and travel to safety instead of racing the gauge — it weakens the damage chain's
  tension. Options: no travel while the cooling is broken, or travel without the repair.
- **D85. Post-pivot code review (three reviewers) — all findings fixed.** Streaming: old chunks
  shed detail/collision after a teleport; planting heights are exact, not the neighbour's loaded
  LOD; no duplicate loot crates; far-mesh gaps interleave with planting (`far_lead_chunks`);
  vegetation off keeps barriers and site dressing. Gameplay: travel after a parts change lands at
  the target; the pose is cached each tick so every exit path saves it; no own-layout kit swap;
  teleports and resets reset the drive-past sweep; overflow keeps the best items. UI: a scene
  change always unpauses (the Wipe soft-lock); the HUD hides under paused pages; the preview cache
  re-parents stale previews and drops a previous world's cars; a Stats page nav test. The
  auto-driver test allows ≤ 3 safety-net rushes (it varies 0–2 with machine load).
- **D86. Tuning asks (user):** health gauge is a heart; `GameConfig.global_grip_mult` = 0.8
  scales all grip; roads narrower (`road_half_width_m` 2.75, was 3.5); forest cover 0.8 (was 0.6).
- **D87. Missing stage effects restored in free roam (user ask):** wheel debris (grass blades
  off-road, gravel clods on the road, the region's own look per ring), the stage's baked terrain
  light (one formula, `TerrainManager.light_for_normal`, shared by both), engine smoke on misfires
  and exhaust flames. Tyre marks are still stage-only (they need a single centreline). Also: game
  scripts are warning-free again, with `tools/warning_check.tscn` to keep them so.
- **D88. Rumours reveal one item each (user ask, supersedes decision 18's "full loot list"):**
  ring r holds one rumour per item of ring r + 1, and each reveals just that item in the journal.
  Spare sites show each rumour `loot_rumour_weight` (2) times as often as a part while any are left;
  rumours rank last for dead ends so they don't crowd out the real loot.
- **D89. Coins and shops replace found loot (user ask, 2026-10-25; supersedes decisions 10, 11,
  15–18 and D88).** Every loot slot and dead end holds a coin; coins are money, worth more per ring
  out (`FreeRoamSettings.coin_value` / `coin_value_per_ring`). Cars and parts are bought at any
  checkpoint, each at a `price` authored on its catalogue entry, once a checkpoint in their ring is
  lit (ring 0 from the start). Giving up loses **all** the money and puts every coin back, so the
  player is pushed to spend at each checkpoint. Gone: loot crystals, carried / banked / dropped
  loot, rumours and the journal's "?" cards. The stash, fitting (decision 14) and the journal stay;
  a small "$n" counter sits top-left while driving.
  **Same day, follow-ups (user):** no separate shop page — parts on sale show on the Parts page
  (buying fits it) and cars on sale on the Garage page (buying switches to it). A part owned fits
  every car at once (nothing moves between cars). The rest-stop menu is Continue / Parts / Garage /
  Map / Tune car: Travel (the map does it) and Journal (still in the pause menu) are gone from it.
  **2026-10-25 (user):** Journal is out of the pause menu too (back to Resume / Reset to road / …);
  the journal itself (its pages and `LootDirector.journal`) is deleted.
  **Later (user):** the money isn't simply lost on a wreck: it's dropped at the wreck under the old
  loot crystal and recovered by driving back; giving up again first loses it for good. Coins still
  all come back on a wreck. The minimap is off (`GameConfig.minimap_enabled = false`); the full map
  is enough.
