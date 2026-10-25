# What changed: two pivots

**Read this before working in this repo.** TAPPA has pivoted twice:

1. **September 2026 — rally career → run-based roguelike.** Recorded below as history (*The
   roguelike pivot*); much of what it added has since been deleted again.
2. **October 2026 — roguelike → free roam.** The current game. It's the section right after this.

| If you want… | Read |
| --- | --- |
| The gist (you are here) | this file |
| Why any given thing is the way it is | `todo/2026-10-19-free-roam-pivot.md`: decisions 1–32 agreed with the user, D33 onward logged during the autonomous build for review |
| The design north star | `gameplay.md` |
| How any one system works today | `features/` (indexed in `features/README.md`); start with `free-roam.md`, `world-session.md`, `loot.md` |

---

# The free-roam pivot (October 2026)

## The shape of the game, before and after

| | Roguelike (before) | Free roam (now) |
| --- | --- | --- |
| World | 8 finite stages per run, a scene reload each | **One persistent procedural island per save**, streamed in during play (`TerrainStreamer`) |
| Roads | One DFS centreline per stage, carved into terrain | **A whole road network laid out at boot** (`RoadNetwork`); terrain built *around* the roads (`RoadTerrain`) |
| Fail state | The stage clock | **None.** At 0 HP the car gives up and you respawn at the last lit rest stop |
| Damage | Never wrecks | **Cooling fails at half health; the engine overheats and drains HP** (`DamageModel.thermal`) |
| Progress | Money, shop, skills, boost levels | **Coins → bought at checkpoints** (D89): cars, parts (the old boosts, by level), engines, drivetrain kits; a wreck drops all the money, Souls-style |
| Between stages | Repair or a boost | **Rest stops**: free repair, parts and garage (buying in both), map (travel), tune |
| Regions | Picked per run | **Biome rings** by distance from spawn, with drifting weather (`BiomeDirector`) |
| Front end | `HubShell` (11 pages) | **Title screen** (`title.tscn`): Continue / New World / Settings |
| Save | Run slot + economy keys, schema 7 | **`world` block** (`WorldSession`), schema 8; v7 profiles are refused |

## Added

| File | Role |
| --- | --- |
| `free_roam.tscn`, `scripts/free_roam/free_roam.gd` | The game scene and its glue to the world session |
| `scripts/free_roam/road_network.gd`, `road_terrain.gd`, `lab_noise.gd` | The road layout and the road-first terrain (bit-exact with `tools/road_network_lab.html` until something diverges — decision 32) |
| `scripts/free_roam/terrain_streamer.gd` | Chunk streaming under a strict 1 ms/frame budget, with foliage, sites, barriers, loot markers and per-ring materials |
| `scripts/free_roam/road_sites.gd`, `road_barriers.gd` | Rest stops, loot slots and dead ends; barriers on sharp bends |
| `scripts/free_roam/biome_director.gd` | Ring → region look, handling and weather, following the car |
| `scripts/free_roam/rest_stops.gd`, `rest_stop_page.gd`, `world_pages.gd` | Bonfires, the rest-stop page, the map and stats pages |
| `scripts/free_roam/loot_rules.gd`, `loot_director.gd` | Shop stock and prices, coins, money, the wreck |
| `scripts/free_roam/road_recovery.gd`, `auto_driver.gd` | Reset to road; the self-driving streaming test |
| `scripts/world_session.gd` (**autoload**) | The persistent world in the profile |
| `scripts/title_screen.gd`, `title.tscn` | The front door (the main scene) |
| `tools/compile_check.tscn` | Loads every script and scene with the autoloads present; the CI gate |

## Deleted

Do not go looking for these: `RunSession` / `RunMode` / `RegionRunMode` / `ChallengeRunMode` /
`ChallengeLibrary` / `RegionStagePool` / `RunPickPanel` / `FreePlay` / `DrivingContext`, the
challenge cloud board, `HubShell` and `MenuShowcase`, `StartLine`, `RivalGhost`, pacenotes, signs,
arches, the stage coins (`CoinLayout` / `CoinField` — free roam has its own coins since D89), `SkillLibrary`, the roguelike money and boost-level economy, the track lockfile
(`TrackCache`, `data/track_cache.json`, the cache scripts and the pre-commit hook), and the
hub-only widgets (car cards, stat bars, the car list).

## Kept, and why

- **`main.tscn` / `world.gd` — the stage scene — survives as a dev stage and the physics test
  harness.** About 40 test files (car physics, damage, collisions, the benchmark) build their
  world on it. Porting them onto free-roam terrain is its own project; until then the stage
  pipeline (`TrackGenerator`, `TerrainManager`'s corridor bake, `StageManager`, `TrackProgress`)
  stays, and nothing in the game reaches it. `RegionStageLibrary` / `StageFields` / `StageConfig`
  stay with it (the benchmark and seed lab read them).
- **`BoostLibrary`** is the parts catalogue now (`features/loot.md`).
- **`UpgradeLibrary.EFFECTS`** is still the only way anything modifies a car (seam 1 below).

## The seams you must not work around

1. **The effects funnel** (unchanged): `UpgradeLibrary.EFFECTS` + a car's `boosts` list. A car's
   fitted parts reach it only through `LootRules.fielded(owned)`, which writes `boosts`,
   `swapped_engine` and `drivetrain_override`.
2. **The reseed pre-pass** (unchanged): global config fields an effect writes carry `reseed`.
   The same hazard applies to `BiomeDirector.apply_handling`, which re-seeds grip from the
   authored values on every ring change.
3. **The frame budget.** Terrain work in `TerrainStreamer` must stay inside units its scheduler
   can measure and stop between. A stage that runs out of frame returns `false` from `_step`.
4. **`WorldSession` is the only writer of the world block.** JSON hands numbers back as floats;
   readers normalise.
5. **Every menu is a flat `MenuPage` + `MenuNav.attach`** (unchanged), with a nav test.

---

# The roguelike pivot (September 2026) — history

Most of what this section describes has been deleted again by the free-roam pivot above. It's
kept because decision numbers from `todo/roguelike-pivot.md` are still cited in older comments.

TAPPA was a Gran-Turismo-style rally *career*; it is now a **run-based roguelike**. The
pivot touched 439 files (+21.7k / −73.7k lines) across 40 commits, `bb959a1..bff6d4d`,
all on `main` now. Roughly half the old codebase is gone.

This file is a **map, not a decision record.** It exists so an agent can get the gist in
two minutes instead of reading 1,661 lines of spec.

| If you want… | Read |
| --- | --- |
| The gist (you are here) | this file |
| Why any given thing is the way it is | `todo/roguelike-pivot.md` — **54 numbered decisions, authoritative** |
| The task sequence that built it | `todo/roguelike-pivot-plan.md` (deleted — every stage landed) |
| The design north star | `gameplay.md` |
| How any one system works today | `features/` (indexed in `features/README.md`) |

Decisions are cited by number from ~30 `features/` docs and dozens of code comments
("decision 51", "decision 30"). Those numbers resolve to `todo/roguelike-pivot.md`.

---

## The shape of the game, before and after

| | Before | After |
| --- | --- | --- |
| Loop | Pick a rally from a world map, drive it, place, repeat | Pick a **region**, drive **8 stages back to back** on one car (`RegionRunMode.STAGE_COUNT` — deliberately *not* a `GameConfig` tunable) |
| Fail state | None — you could always retry | **The per-stage target time.** Miss it and the run is over |
| Currency | Stars (placement) + money | **Money only** (decision 21) |
| Opponents | Rival field, AI pace, global leaderboards | **Deleted.** You race the clock, not cars |
| Upgrades | Persistent bought parts slotted per car | **Two tiers**: in-run **boosts** (die with the run) and permanent **perks** |
| Between stages | Free automatic repair | **Repair *or* a boost** — taking one costs the other |
| Front end | Diegetic 3D HQ you walked around | **Flat menu pages** (`hub.tscn`) |
| Persistence | Career progress + save migrations | Soft permadeath; run state in one resumable save slot; **no migration chain** |

---

## Deleted outright

Do not go looking for these — they are gone, not moved:

- **The diegetic 3D HQ** — `hq.tscn`, `scripts/hq*.gd` (9 files), `world-panel`-hosted
  menus, the map table, the tuning lift, the present reveal.
- **The overworld** — `overworld.tscn` and 15 `scripts/overworld_*.gd`.
- **The rival field and everything downstream** — `rally_session.gd`, `ai_difficulty.gd`,
  `ghost_car.gd`, `rival_pace.gd`, `standings.gd`/`standings.tscn`, `live_standings.gd`,
  `global_standings.gd`, `podium.gd`/`podium.tscn`, `rally_trophy.gd`.
- **The global stage leaderboards** — `scripts/cloud/leaderboard.gd` and the
  `stage_times` Firestore rules. The Rally Challenge board (`challenge_runs`) survives.
- **The star economy** — prize rallies, `reward_system.gd`, star tiers, free roam.
- **The persistent parts model** — `upgrades_grid.gd`, `upgrade_options.gd`,
  `upgrade_reveal.gd`, `upgrade_icons.gd`, and the `installed_upgrades` /
  `disabled_upgrades` save keys. **`UpgradeLibrary` itself survives** — see the effects
  funnel below. It is no longer a catalogue.
- **The multiplayer lobby** (deleted just before the pivot, and it left two landmines:
  a broken `firestore.rules` and a red test — both since fixed).

## Added

| File | Role |
| --- | --- |
| `scripts/run_session.gd` (**autoload**) | The run. Stage cursor, banked times, the persisted+resumable run slot, the between-stage pick, the terminal result |
| `scripts/run_mode.gd` | **Strategy seam** — what differs between kinds of run |
| `scripts/region_run_mode.gd` | The region run: stage draw, the clock, the fail rule, the payout |
| `scripts/challenge_run_mode.gd` | The retained Daily/Weekly/Monthly challenge: rolled stages, no clock, one placement payout |
| `scripts/region_stage_pool.gd` | A region's authored event pool + the seeded draw |
| `scripts/boost_library.gd` | In-run boosts (die with the run) |
| `scripts/perk_library.gd` | Permanent perks — locked → purchasable → owned → equipped |
| `scripts/lifetime_stats.gd` | Persistent counters that survive run failure; the ledger perk unlocks read |
| `scripts/coin_layout.gd` / `coin_field.gd` | Stage coins — seeded off-racing-line placement, pickup query |
| `scripts/hub_shell.gd` + `hub.tscn` | The flat front end. `enum View` has 11 pages |
| `scripts/run_pick_panel.gd` | The between-stage repair-or-boost pick |
| `scripts/stage_config.gd` | Extracted from `RallySession` — the **canonical** writer that turns a stage dict into a `GameConfig` |

---

## The five seams you must not work around

1. **The effects funnel.** `UpgradeLibrary.EFFECTS` + a car's `boosts` list is the *only*
   way anything modifies a car or the config. **Two writers** merge in
   `world.gd::_field_car` onto a *duplicated* owned-car dict: in-run boosts
   (`RunSession.boosts()`) and equipped perks (`PerkLibrary.equipped_effects()`). They
   differ in lifetime, not mechanism. Decision 51 forbids a parallel modifier path — a
   new effect adds an `EFFECTS` row and a `GameConfig` field, never a bespoke read at a
   call site.

2. **The reseed pre-pass.** `Config.data` is a long-lived singleton, so a *global* config
   field an effect writes would compound every time `apply` ran. `EFFECTS` rows that
   touch a global field carry `reseed: true`, and `UpgradeLibrary._reseed_globals`
   restores them from the pristine authored `.tres` via `Config.authored_value()` before
   applying. Add a global-field effect ⇒ set `reseed`.

3. **`RunMode`, not `if kind == …`.** Anything that differs between a region run and a
   challenge goes behind a `RunMode` method (`stages()`, `stage_target_ms()`,
   `stage_money()`, `offers_boost_pick()`, `to_record()`, `record_outcome()`). Anything
   shared lives in `RunSession`.

4. **`StageConfig` is the one writer.** `apply_event_config` (mutates the live config) or
   `canonical_event_config` (fresh, for cache keys). Do not hand-write a subset — the
   config is a persistent working copy and a subset silently inherits the last stage.

5. **Every menu is a flat `MenuPage` + `MenuNav.attach`.** Keyboard *and* gamepad
   navigation is a CLAUDE.md rule with a required nav test. The old `hq.gd`
   `_unhandled_input` spatial pattern is deleted. Note `MenuNav.attach` runs *after* page
   build and re-enables focus on every `BaseButton`; `menu_nav_skip` meta is the only
   working opt-out. Watch `_back()` (Esc / gamepad B) as well as the Back button — they
   are separate code paths and have already diverged once.

## Money

**Three sources:** the per-stage payout (grows with stages cleared), the fast-completion
bonus (proportional to time saved), and coins picked up mid-stage.

**Four implemented sinks**, all thin wrappers over `Save.spend_money` sharing one refusal
rule — *an invalid or unaffordable purchase leaves the profile byte-identical*:
`buy_car`, `buy_boost_level`, `buy_engine_swap_unlock`, `buy_perk`. Drivetrain
conversion (decision 52) was briefly a fifth sink, `buy_drive_mode`; decision 55
supersedes it — a conversion is now a free, run-scoped mid-run upgrade offered in the
between-stage pick, not a purchase (`region-runs.md (deleted)` → *Drivetrain
conversion*). The spec's sixth sink, cosmetic wheels
(decision 25), is still free and has no host screen.

## Save schema

New keys on the profile: `money`, `run` (the resumable slot), `regions_cleared`,
`boost_levels`, `bought_perks`, `equipped_perks`, `lifetime`. Gone: stars, the parts
keys, and the `_migrate_step` ladder — a profile whose `schema_version` does not match
exactly (older *or* newer) is **refused, not migrated** (decisions 20 / 34). `_migrate()`
survives only to backfill a key missing from a correctly-versioned profile.

---

## Known gaps — deliberate, documented, not bugs

- The challenge's entry screen is minimal: no cloud board, standing or reward explainer
  (decision 53, `rally-challenge.md (deleted)`).
- **The cloud boot-pull gate has no consumer.** `HubShell` does not await the initial
  sync, so a returning player can act on a profile that is about to be replaced
  (`features/cloud-save.md` leads with this).
- Three finished systems have no host: `WorldPanel`, the garage model, the wheel-fitting
  view. Each file says what a rebuild owes.
- `engine_detune` is stored, read and applied with no slider anywhere
  (`features/tuning.md`).

## A second, smaller pivot: region stage slots (2026-09)

After the roguelike pivot shipped, the authored-rally-pool model it introduced
(decision 7) was itself replaced: `todo/region-stage-slots-redesign.md` swaps the
flat per-region pool + difficulty-sort draw for a fixed 8-slot × 3-candidate grid
per region. The `RallyLibrary.RALLIES` wrapper (named rallies, `restriction`,
`special`, `map_pos` — all pre-pivot residue `features/rally-roster.md` had been
tracking as dead since stage 2b) is deleted along with it. See
`features/region-stage-library.md` for how it works today, and decisions 3/7/32 in
`todo/roguelike-pivot.md` for what it superseded.

## Test suite

~2,553 tests, **~350 s** — over the ~5 min budget in CLAUDE.md and knowingly so. ~140 s
is full-library live track generation (the seed-3002 regression guard); the remaining
~210 s of ordinary test cost sits under 300 s. The user declined both ways out (a slow
lane, or re-basing the budget). Cost model and levers: `features/testing.md`.

Two traps worth knowing before you write a test here: **`SceneTestHelpers.minimal_world()`**
cuts a `main.tscn` build from ~15 s to <1 s, but does *not* help a challenge stage
(`TrackGenParams.for_event` overrides the turn count); and JUnit XML timings cover test
bodies only, so `before_all` builds are invisible in the per-test numbers.
