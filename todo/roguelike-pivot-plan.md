# Roguelike pivot — implementation plan

The task sequence for `todo/roguelike-pivot.md`. **That spec is authoritative for
every decision and every "why"; this file holds none of its own.** If a task here
seems to contradict a decision there, the spec wins and this file is stale — fix
it in the same change.

Read the spec's **Hazards** section before starting stage 2.

## Ground rules

- **Everything stays on `claude/tappa-roguelike-pivot-qgmfrq` until the pivot is
  finished.** `main` holds the working pre-pivot game and is not touched until
  stage 9's gate passes, then merged once.

  > **This suspends `CLAUDE.md`'s auto-merge rule** ("if you're running in a
  > managed remote execution environment … ALWAYS merge that branch into `main`").
  > That rule normally fires at the start of every remote session — do not follow
  > it for this work. `main` was deliberately reset to `8cfae5f` (pre-pivot) after
  > the spec work had been merged to it by mistake.

- **Stage 2 lands as a single commit.** Decision 20 makes `git revert` the
  rollback mechanism, and that only works if the demolition is one thing to
  revert. It is *worked* in waves with checkpoint commits — that is how the
  parallelism below is possible — and then **squashed into one commit before
  stage 3 begins**. Every other stage commits freely.
- **Tests per `CLAUDE.md`:** implementation first, tests before the stage is
  called done, targeted runs mid-stage, the full suite only at the very end
  (stage 9). Never start a run while another is in progress.
- **Docs in the same change:** every stage that touches a system updates its
  `features/` doc as part of the stage, not in stage 9. Stage 9 is the *audit*,
  not the backlog.
- **A stage is done when its gate passes**, listed per stage below. "It compiles"
  is a gate only where stated.

## Parallel execution

Work the stages in **waves**: a set of agents editing disjoint files at once,
then a parent checkpoint. The constraint that shapes everything below is that all
agents share **one working tree** (`CLAUDE.md`), so the unit of parallelism is a
**file**, not a system.

### Wave rules

1. **Assign file ownership explicitly.** Every agent is told the paths it owns
   and the paths that are off-limits. Two agents never own one file. Where a
   system's deletion touches a shared file (`rally_library.gd`,
   `save_manager.gd`, `world.gd`, `project.godot`), that file belongs to *one*
   agent for the whole wave and the others report what they need changed in it.
2. **Subagents do not run tests. Ever.** `CLAUDE.md` binds them directly. The
   **parent** runs one targeted run per wave, covering the combined blast radius
   of every agent in it. A subagent's own run would measure a half-finished tree
   and violate the no-concurrent-runs rule.
3. **Verify diffs, do not trust reports.** The repo's own eval rounds found
   Haiku-class probes writing *"confident completion reports over empty diffs"*
   (round 045), and one claiming a pre-seeded doc edit as its own work. After
   every wave: `git diff --stat` per claimed file before believing any agent.
4. **A wave ends at a green checkpoint.** Parent runs the targeted tests, fixes
   or reassigns what failed, commits, then launches the next wave. Never overlap
   waves.
5. **Serialise anything that cascades.** If getting task A wrong makes task B's
   output meaningless, they are not in the same wave.

### Model selection

Pick per task, not per stage. This repo has invested 45 rounds in
Haiku-readiness (`evals/small-model/`), so small models are viable here for the
shapes the task bank covers — additive, single-surface, explicit target.

| Model | Use for | Because |
| --- | --- | --- |
| **Haiku** | Mechanical work against an explicit file list: deleting a named system, removing a config block, a `features/` doc whose subject is entirely gone, retiring an eval task, index updates | Cheapest, and the eval bank shows this codebase is legible to it for exactly this shape. Always give the exact file and symbol — the documented failure mode is *vocabulary/surface collision*, picking a similarly-named surface |
| **Sonnet** | Feature implementation with judgement: menu screens, the shop, perks, stats, test rewrites, `features/` docs for systems that partly survive | The bulk of stages 4–8. Bounded, multi-file, but a wrong call is local |
| **Opus** | The `RallySession` extraction seam, the `RunSession` generalisation, the save-schema redesign, the `gameplay.md` rewrite | Where a wrong call cascades through everything after it. These are also the tasks whose cost is dominated by reading, not writing |

**Never give a Haiku agent a task whose success cannot be checked from the
diff.** "Delete these six files and their references" is checkable. "Make the
boost shop feel good" is not.

### Wave map

| Stage | Parallelises? | Shape |
| --- | --- | --- |
| 0 | No | One command, parent only |
| 1 | Barely | `gameplay.md` is one coherent document — one Opus agent. The `challenge-career-reuse-drift` fold is a Haiku task alongside it |
| 2a | **No — serial** | The extraction is one seam through `rally_session.gd`. One Opus agent, alone in the tree |
| 2b | **Yes, 4–5 agents** | Independent deletions, below |
| 2c | **No — serial** | `project.godot`, `Scenes`, the save schema. One Opus agent; a wrong autoload breaks everything |
| 2d | Yes, 3–4 agents | Test triage, partitioned by test-file prefix |
| 3 | **No — serial** | The spine is one coherent design. One Opus agent, or the parent directly |
| 4–8 | Yes, but sequential stages | Each stage is one Sonnet agent; **within** a stage, split UI from logic where the files are disjoint |
| 9 | **Yes, 6–8 agents** | The `features/` audit partitions across 76 docs beautifully; eval re-authoring is one Haiku agent per task |

### Stage 2b — the one wave that needs care

These deletions are independent *in system terms* but converge on three files.
Assign those files to one owner and have the others hand their edits to it:

| Agent | Owns | Model |
| --- | --- | --- |
| A | `rally_library.gd` **and** `save_manager.gd` — the shared files. Applies every other agent's requested edits to them | Sonnet |
| B | Rival field: `rival_pace.gd`, ghost, wrecks, `ai_difficulty.gd` | Haiku |
| C | Leaderboards: `cloud/leaderboard.gd`, `global_standings.gd`, `firestore.rules` | Haiku |
| D | Free roam + `game_config.gd`'s `free_roam_*` block + obsolete `todo/` specs | Haiku |
| E | Parts model: `upgrade_library.gd`, `upgrade_options.gd`, `upgrades_grid.gd` | Sonnet |

The hub demolition (`hq.tscn` and its nine collaborators, `overworld.tscn`,
`WorldPanel`) is **its own wave after this one** — it is the largest single
deletion and touches `hq.gd` at 3563 lines.

### Cost note

The saving is real but comes from task shape, not from agent count: a Haiku agent
deleting a named system costs a fraction of an Opus agent doing the same work,
while an Opus agent is *cheaper* than a Sonnet one that gets the extraction seam
wrong and takes the demolition with it. Spend the expensive model where a mistake
cascades; spend the cheap one where the diff proves the work.

## Stage 0 — verify the tree (before anything)

The multiplayer deletion landed without a compile check or test run (no Godot
binary in the environment it was made in).

1. `./run_tests.sh` — full suite, **on this branch**, not on `main`. `main` is
   the old game and will pass trivially; the multiplayer deletion lives here.
2. Fix anything the lobby removal broke. Suspects, in order: `world.gd` (six edit
   sites), `driving_context.gd`, `hq.gd` / `hq_overlays.gd` (the garage row lost a
   button), `test_stage_manager.gd`, `test_ghost_car.gd`, `test_menu_flow.gd`,
   `test_menu_nav.gd`.

**Gate:** the suite's result matches the recorded baseline below — not
necessarily green. What matters is that a stage-2 failure is *attributable*.

### Baseline, as measured

Run on this branch with Godot 4.6 stable (`GODOT=/tmp/Godot_v4.6-stable_linux.x86_64`):

```
Scripts 214 · Tests 3479 · Passing 3474 · Failing 2 · Time 536s
```

**One failure was mine and is fixed:** `features/hq.md` still listed
`tests/headless/test_hq_multiplayer.gd` in its `**Tests:**` line after the lobby
deletion removed it. A deletion that greps clean in code can still leave a doc
pointing at the corpse — `test_features_docs.gd` catches exactly that.

**Two failures are pre-existing on `main`** — `test_features_docs.gd` →
`test_no_area_doc_grows_into_an_unnavigable_monolith`:

- `features/overworld.md` 1912 lines vs a 1817 baseline
- `features/terrain.md` 1338 vs 1310

Both files were last touched by `8cfae5f`, the commit `main` currently sits at,
and neither was touched by this branch. They are **not** pivot damage. The
`overworld.md` failure resolves itself in stage 2 (the file is deleted with the
overworld hub); `terrain.md` needs a genuine split or shrink and is unrelated
debt — not this pivot's job, but it will stay red until someone does it.

**Runtime note:** 536s here versus the ~5 minute budget in `CLAUDE.md`. This
container is slower than the development Mac, so treat 536s as *this
environment's* baseline rather than evidence of a regression. Compare later runs
against 536s, not against 300s.

## Stage 1 — decide and document (no code)

> **Wave:** 2 agents — Opus on `gameplay.md`, Haiku on the drift-spec fold.

1. Rewrite `gameplay.md` to the roguelike vision. It currently describes the GT
   career and contradicts the spec on nearly every point.
2. Fold `todo/challenge-career-reuse-drift.md` into the pivot spec (its open item
   — retiring `ChallengeSession.abandon()` — is subsumed by the `RunSession`
   extraction) and delete it.
3. Sanity-read the spec's Hazards against the tree once more; anything that has
   drifted since it was written gets corrected now, while it is still cheap.

**Gate:** `gameplay.md` describes the game the spec describes.

## Stage 2 — demolition (worked in waves, squashed to one commit)

> **Waves:** 2a serial (Opus, alone) → 2b five agents → hub demolition wave →
> 2c serial (Opus) → 2d four agents. Parent runs targeted tests between each.

The risky stage. Work in this order — extractions first, deletions second,
project wiring third — so the tree never sits in a state where the next step is
guesswork.

### 2a. Extract what survives

- **`apply_event_config` / `canonical_event_config`** → a new
  `scripts/stage_config.gd` (`StageConfig`), pure statics, no autoload. Update
  the five callers: `driving_context.gd`, `track_cache.gd`, `region_library.gd`,
  `challenge_library.gd`, `benchmark_mode.gd`.
- **`apply_field_repair_to`** → fold into `Save` beside `field_repair`, which it
  already delegates to. It is four lines reading two `GameConfig` fields; it does
  not need a home of its own.
- **`UpgradeLibrary.EFFECTS` / `_cfg_set` / `apply`** → keep in place. The
  catalogue around them goes; the funnel stays and becomes the in-run boost
  applier in stage 5.
- **`build_standings` is NOT extracted — it is deleted.** The spec says extract;
  that is wrong and this file corrects it. With rivals gone its only callers are
  `ChallengeSession.current_event_standings` / `current_standings`, both of which
  feed `standings.tscn` — itself deleted by decision 30. Rewrite those two to
  return plain time lists for the run summary instead.

### 2b. Delete

Execute the spec's *What gets deleted* list. Suggested order, each step leaving
fewer dangling references than the last:

1. Rival field + `rival_pace.gd` + ghost + wrecks + `ai_difficulty.gd`.
2. Star economy (ledger, `stars_for_placement`, `STARS_FOR_*`, `rally_trophy.gd`)
   — and re-point `ChallengeSession.try_grant_completion_reward` at money.
3. Parts model (catalogue, slots, install/buy, `auto_build_plan`,
   `upgrade_options.gd`, `upgrades_grid.gd`).
4. Map + reveal geometry + `map_fog.gd` + `rally_detail.gd`.
5. Prize rallies + `RewardSystem.draw_car`.
6. Global stage leaderboards + `stage_key` + `BOARD_EPOCH` + `global_standings.gd`
   + the `stage_times` Firestore rules.
7. `podium.tscn`, `standings.tscn`.
8. `hq.tscn` + collaborators; `overworld.tscn` + `overworld_picker.gd`;
   `WorldPanel`.
9. Free roam; `restriction`; the `_migrate_step` chain; the three obsolete
   `todo/` specs.
10. The remainder of `RallySession`.

### 2c. Rewire the project

- `project.godot`: `run/main_scene` (temporarily `main.tscn` until stage 3's
  shell exists), autoloads (`RallySession` out).
- `Scenes`: `hub_path()` collapses to one constant; `is_hub_scene` learns the new
  shell so `MusicLibrary.is_hq_scene` still resolves hub music.
- `car.gd`: rear wing visibility stops reading `aero_tuning_unlocked` and becomes
  a per-car property (decision 24). Update `test_aero_visibility.gd` and
  `test_aero_visible_traversal.gd`.
- `TuningLibrary.axis_unlocked` returns true for all axes (decision 24).
- Remove the credits trigger on `all_specials_completed` (decision 37).
- `Save`: bump `SCHEMA_VERSION`, drop the migration ladder, pre-pivot profiles
  reset. New keys: `money`, `regions_cleared`, `boost_levels`, `bought_perks`,
  `equipped_perks`, lifetime stats. `challenge_run` generalises to one run slot
  (decision 27).

### 2d. Triage tests as you go

Per decision 38: delete tests whose subject is deleted; keep physics, car,
drivetrain, terrain, track-gen and fix their incidental `RallyLibrary` couplings
(most are fixture setup, not assertions about rallies).

**Gate:** `godot --headless --quit` loads the project with no script errors, and
the surviving test files compile. **The game does not run — that is expected.**

## Stage 3 — back to playable

> **Wave:** none — serial, Opus or the parent directly. The spine is one design;
> splitting it across agents costs more in seam-fixing than it saves.

The bar is *running*, not *good*. Everything here gets replaced or extended
later; nothing here should be polished.

1. **`RunSession`** — generalise `ChallengeSession`: stage list and fail rule come
   from a strategy; keep `_persist`/`resume`, the car lock, `_pending_repair`,
   the terminal-outcome record. Challenge becomes caller one.
2. **Region stage pool** — flatten a region's rallies into their `events`; seeded
   8-stage draw ordered by the parent rally's `difficulty`.
3. **Fixed timer** — `LapTimeModel.optimum_ms(track, CarPerformance.REFERENCE_CAR,
   event) * target_pace`, with `target_pace` a `GameConfig` tunable taking stage
   index and region index (decisions 11, 22).
4. **Run-over on a missed target**, money paid per stage (completion + fast bonus).
5. **A bare flat shell** — title → car select → run, on `MenuPage` +
   `MenuNav.attach`. Ugly is fine. Register it as the main scene.
6. **Run summary** — stages cleared, per-stage margin, money earned.

**Gate:** a full 8-stage run start to finish, and a run that ends early on a
missed timer. Targeted tests for the draw, the timer derivation and the fail
rule. Nav test for the shell (`CLAUDE.md` requires it for any new menu).

## Stages 4–8 — features

> **Waves:** one Sonnet agent per stage, sequential by stage. Within a stage,
> split UI from logic only where the files are genuinely disjoint.

Conventional work once stage 3 lands; each is independently shippable and each
brings its own tests and `features/` doc.

| Stage | Work | Gate |
| --- | --- | --- |
| 4 | Region select + linear unlock (`order` field on `REGIONS`, `regions_cleared` ledger). **Plus the stage-pool authoring pass** to 16 events: `greece_coast` (3), `home_coast` (12), `taiga` (15). | Every region reachable in order; every region's pool ≥ 16; nav test |
| 5 | In-run boosts + repair pick between stages, through the retained `UpgradeLibrary` effects funnel, wiped on run end | A run's boosts do not survive into the next; repair competes with a boost; nav test |
| 6 | Meta shop — boost levels (with per-level effect ranges, decision 42), car purchasing, engine-swap unlock | Money buys each; boost level changes the magnitude of a drawn pick; nav test |
| 7 | Lifetime stats, then perks (`PerkLibrary`, unlock thresholds, ≤3 equipped) | A perk below threshold is not offered; equip cap holds; nav test |
| 8 | Collectables — prop, off-line placement, pacenote signposting, pickup trigger, HUD counter, audio, banked at stage clear | Coins bank on stage clear and survive a later run failure |

The authoring pass in stage 4 is the one to schedule generously: three regions
need real events written, and they are not playable until they have them.

## Stage 9 — audit and close

> **Wave:** the widest — 6–8 agents. Partition the 76 `features/` docs across
> Haiku agents (one per doc-cluster); one Haiku agent per eval task to re-author.
> Parent runs the single full suite at the end.

1. Flesh out the flat shell beyond stage 3's spine.
2. **Full `features/` audit** — all 76 docs, each fixed or deleted, index rebuilt
   (decision 40).
3. **Re-author the dead small-model eval tasks** against the new systems
   (decision 41) — T001, T005, T008, T009, T014, T015, and reshape T003.
4. One full `./run_tests.sh` against the ~5 minute budget. If it is over, invoke
   `/optimise-test-suite` rather than eyeballing it.
5. **Merge to `main`** — the one time, once the gate below passes.
6. Ask whether `todo/roguelike-pivot.md` and this file should now be deleted
   (`CLAUDE.md`: do not delete a completed spec without checking).

**Gate:** green suite inside budget; no `features/` doc describes a system that
no longer exists.

## Sequencing notes

- Everything depends on stage 2. Stages 4–8 all render on stage 3's shell.
- Stage 7's perks depend on stage 7's stats. Stage 8 depends on stage 3 (it needs
  a generated stage to place props along).
- Nothing depends on a save migration, because there isn't one.
- **The window between stages 2 and 3 is the whole risk of this plan.** Do not
  start stage 2 without a green baseline from stage 0, and do not widen stage 3
  beyond the six items listed — every hour the game does not run is an hour with
  no feedback.
