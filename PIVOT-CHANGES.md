# What changed: the roguelike pivot

**Read this before working in this repo if your mental model predates September 2026.**
TAPPA was a Gran-Turismo-style rally *career*; it is now a **run-based roguelike**. The
pivot touched 439 files (+21.7k / −73.7k lines) across 40 commits, `bb959a1..bff6d4d`,
all on `main` now. Roughly half the old codebase is gone.

This file is a **map, not a decision record.** It exists so an agent can get the gist in
two minutes instead of reading 1,661 lines of spec.

| If you want… | Read |
| --- | --- |
| The gist (you are here) | this file |
| Why any given thing is the way it is | `todo/roguelike-pivot.md` — **54 numbered decisions, authoritative** |
| The task sequence that built it | `todo/roguelike-pivot-plan.md` |
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

**Five implemented sinks**, all thin wrappers over `Save.spend_money` sharing one refusal
rule — *an invalid or unaffordable purchase leaves the profile byte-identical*:
`buy_car`, `buy_boost_level`, `buy_engine_swap_unlock`, `buy_perk`, `buy_drive_mode`
(per-car drivetrain conversion, decision 52). The spec's sixth sink, cosmetic wheels
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
  (decision 53, `features/rally-challenge.md`).
- **The cloud boot-pull gate has no consumer.** `HubShell` does not await the initial
  sync, so a returning player can act on a profile that is about to be replaced
  (`features/cloud-save.md` leads with this).
- Three finished systems have no host: `WorldPanel`, the garage model, the wheel-fitting
  view. Each file says what a rebuild owes.
- `engine_detune` is stored, read and applied with no slider anywhere
  (`features/tuning.md`).

## Test suite

~2,553 tests, **~350 s** — over the ~5 min budget in CLAUDE.md and knowingly so. ~140 s
is full-library live track generation (the seed-3002 regression guard); the remaining
~210 s of ordinary test cost sits under 300 s. The user declined both ways out (a slow
lane, or re-basing the budget). Cost model and levers: `features/testing.md`.

Two traps worth knowing before you write a test here: **`SceneTestHelpers.minimal_world()`**
cuts a `main.tscn` build from ~15 s to <1 s, but does *not* help a challenge stage
(`TrackGenParams.for_event` overrides the turn count); and JUnit XML timings cover test
bodies only, so `before_all` builds are invisible in the per-test numbers.
