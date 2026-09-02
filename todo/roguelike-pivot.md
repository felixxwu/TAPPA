# Roguelike pivot — replacing the career loop

**Status: DESIGN DRAFT, not agreed.** This is the spec for a *complete* pivot of
TAPPA's gameplay loop, from the Gran-Turismo-shaped career it ships today to a
run-based roguelike modelled on `felixxwu/roguelike-rally` (referred to below as
**RR**). It is written to be argued with — the "Open questions" section at the
bottom is the part that still needs the user, and nothing here should be
implemented before those are settled.

Sibling design docs: `gameplay.md` is the CURRENT north star and **contradicts
this document on almost every point** — if this pivot is agreed, rewriting
`gameplay.md` is part of stage 1, not a follow-up.

## Decisions already taken

Settled with the user during the brainstorm that produced this file:

1. **The world map does not survive.** Regions are picked from a menu; a run
   happens entirely inside one region.
2. **Regions unlock linearly.** Only the home region is available at the start;
   finishing a region's 8th stage unlocks the next region.
3. **A run is 8 stages** (RR's `TOTAL_STAGES = 8`), and a "stage" is ONE
   procedurally-generated point-to-point event — not a 3-event rally.
4. **Missing the timer ends the run.** That is the only hard fail state.
5. **Rivals are dropped entirely.** You race the clock, not a field.
6. **Damage cannot end a run directly** — it degrades the car so you miss the
   timer. TAPPA's existing "HP floors at 0, car stays drivable" rule survives.
7. **Stages are drawn from the authored rally pool**, per region, rather than
   generated from scratch.
8. **Upgrades and car acquisition follow RR** — see those sections below.
9. **The diegetic 3D HQ is dropped for a simple flat UI.** The hub stops being a
   3D space the camera flies through and becomes ordinary menu screens.

## The new loop, end to end

```
title
  └─ region select (linear unlock; locked regions shown greyed with their gate)
       └─ car select (owned cars; buy new ones with stars — RR-style shop)
            └─ RUN START (stage 1 of 8)
                 ├─ stage: drive a drawn event against a target time
                 │    ├─ beat the timer → stage cleared, stars paid out
                 │    └─ miss the timer → RUN OVER
                 ├─ between-stage pick: repair, or 1 of N random boosts
                 └─ …repeat to stage 8
                      └─ region cleared → next region unlocked
  └─ (on run end, win or lose) back to the hub:
       stars, owned cars, perks, boost levels and lifetime stats all persist
```

**Soft permadeath, exactly as RR.** A failed run destroys the run: stage
progress, every temporary boost picked during it, and the car's accrued damage.
It does **not** touch stars, owned cars, purchased perks, purchased boost levels,
or lifetime stat counters.

## The big reuse win: `ChallengeSession`, not `RallySession`

The most important structural finding of the research. TAPPA already ships a
second session type that is *most of a roguelike run*:
`scripts/challenge_session.gd` (`ChallengeSession` autoload) +
`scripts/challenge_library.gd` (`ChallengeLibrary`), documented in
`features/rally-challenge.md`.

What it already does, that the run mode needs:

| Need | `ChallengeSession` today |
| --- | --- |
| N sequential stages, no rally wrapper | `_stage_index`, `_stage_times_ms`, `stage_count()`, `continue_to_next_stage()` |
| No opponent field | already rival-free — `current_standings()` is a leaderboard, not a grid |
| Procedural per-stage params | `ChallengeLibrary.stages_for(period_key, stage_count)` |
| Mid-run state persisted + resumable | `_persist()` / `resume()` / `Save.set_challenge_run` (`profile["challenge_run"]`) |
| Between-stage pit repair | `take_pending_repair()` / `_pending_repair` |
| A car locked to the run | `Save.is_challenge_locked(instance_id)` |
| Terminal outcome recorded per run | `_record_outcome()` / `profile["challenge_results"]` |
| Completion reward | `try_grant_completion_reward()` |

`RallySession` (`scripts/rally_session.gd`, 1276 lines) is the WRONG base: over
half of it — `generate_opponent_field`, `current_event_p1`, `_p1_skill_seed`,
`refield_opponents`, `current_standings`, `_award_podium_rewards`, the whole
PRESENCE/STANDINGS/PODIUM phase machine — exists to serve a rival field that this
pivot deletes.

**Recommended approach: generalise `ChallengeSession` into a `RunSession`** that
takes its stage list and its fail rule from a strategy, with the daily/weekly/
monthly challenge becoming one caller and the region run the other. That keeps
the challenge mode working for free and avoids a third copy of the
stage-loop/persist/repair logic. Note `todo/challenge-career-reuse-drift.md`
already tracks drift between these two session types — this pivot should absorb
and close that spec rather than adding a third divergent path.

## System-by-system design

### Region select and linear unlock

Replaces `hq_map_table.gd` / `hq_table.gd` / `rally_detail.gd` pin-picking and the
whole geometric reveal system (`RallyLibrary.rally_revealed`, `lit_sources`,
`position_lit_by`, `reveal_link_pairs`, `distance_beyond_frontier`,
`suggest_map_pos`, `map_pos_is_free`, `MIN_PIN_SEPARATION`, `HQ_MAP_POS`,
`reveal_depths`, `nearest_locked_special_id`).

`RegionLibrary.REGIONS` (`scripts/region_library.gd`) already holds the six
regions with stable ids — `home`, `home_coast`, `taiga`, `greece`,
`greece_coast`, `snow` — plus their look and `water_level`. Today a region is
explicitly **not** a gate (`features/regions.md` says so in as many words); this
pivot makes it the *only* gate. Two things to add:

- an authored **order** on `REGIONS` (a new `order` field, or just the array
  order made load-bearing), since linear unlock needs a sequence;
- `profile["regions_cleared"]` — an array of region ids — as the unlock ledger.
  A region is playable if it is first in order, or its predecessor is in that
  array.

Menu navigation is mandatory here: per `CLAUDE.md`, the region-select screen
needs keyboard + gamepad nav and a nav test in the same change
(`features/menu-navigation.md`, the `MenuNav.attach` framework).

### Stage draw

Per the decision, stages come from the authored pool, not fresh procgen. Each
`RallyLibrary.RALLIES` entry carries `region` and exactly 3 `events`, where an
event is a `{seed, turn_count, surface_mix, weather, …}` `TrackGenerator` spec.
Flattening rallies-in-region into their events gives the per-region stage pool:

| region | rallies | authored events |
| --- | --- | --- |
| `home` | 14 | 42 |
| `greece` | 8 | 24 |
| `snow` | 6 | 18 |
| `taiga` | 5 | 15 |
| `home_coast` | 4 | 12 |
| `greece_coast` | 1 | **3** |

**`greece_coast` cannot fill an 8-stage run** — it has one rally. Options: fold
it into `greece`'s pool, author more rallies for it, or let a thin pool top up
procedurally. This needs a decision (see Open questions).

The draw itself should be seeded per run so a run is reproducible for debugging,
and should escalate: RR grows its tracks with
`NUM_TURNS + tracksCompleted * TURNS_ADDED_PER_TRACK_COMPLETED`. The equivalent
here is to order the drawn 8 by an authored difficulty proxy (the parent rally's
`difficulty`, or `turn_count`) so stage 8 is the hardest of the drawn set — and
optionally scale `turn_count` up on later stages. All escalation constants are
`GameConfig` tunables in `config/game_config.tres`, never script literals.

### The timer — the one fail state

With rivals gone, `RallySession.current_event_target_ms()` loses its source (it
reads the P1 rival's time via `current_event_p1()`). The replacement already
exists: **`LapTimeModel.optimum_ms(track_result, car_meta, event)`**
(`scripts/lap_time_model.gd`) computes a physics optimum for a given track and
car. Target time becomes `optimum_ms * target_pace`, where `target_pace` is a
`GameConfig` tunable that tightens with stage index.

Two consequences worth being explicit about:

- The target is now **car-relative**, so a faster car gets a proportionally
  faster target and cannot trivially cruise the early stages. This is a real
  design choice, not an implementation detail — the alternative (a fixed
  per-stage time, so a better car is straightforwardly better) is arguably more
  roguelike. Flagged in Open questions.
- `LapTimeModel`'s optimum is a point-mass centreline *reference*, not a hard
  physical bound — `RallyLibrary.GHOST_SOLVABLE_PACE`'s comment is explicit that
  a real driver can beat it by straightening corners. So `target_pace` values
  near or below 1.0 are viable but must be tuned against real driving, not
  reasoned about from the model.

RR also has `SPECTATOR_HIT_TIME_PENALTY_SECONDS` — hitting things costs time
directly. Worth considering as a second damage channel here, since it converts
crashes into timer pressure, which is exactly the indirect-failure model
decision 6 asks for.

### Upgrades — RR's two-tier model

RR splits upgrades in a way TAPPA currently does not:

- **In-run, temporary.** After each stage, pick one of ~3 randomly drawn boosts
  from `BOOST_DEFINITIONS` (engineForce, frictionMax, brakeForce, mass,
  shiftTime, downforce, dragCoefficient), plus an always-offered repair. These
  mutate the live car and are **wiped on run end** — RR's `resetGameState()`
  re-reads the car from its definition.
- **Meta, permanent.** Stars buy *boost levels* in a shop. A level does not make
  the car faster directly; it scales the magnitude of future in-run picks
  (`getBoostedUpgradeValue`), with per-level exponential pricing and a
  `maxLevel` cap.

Mapping onto TAPPA: the natural in-run boost fields are `GameConfig` physics
fields, and the machinery to write them already exists —
`UpgradeLibrary.EFFECTS` + `UpgradeLibrary.apply(owned_car, cfg)` already patch a
`GameConfig` from a list of fitted parts, via `_cfg_set`. A run-scoped boost list
can go through the same funnel without inventing a second effects system.

What this retires: the entire car-bound persistent parts model — the 7 slots
(`UpgradeLibrary.SLOTS`: turbo, gearbox, aero, tires, weight, drivetrain,
nitrous), `Save.install_upgrade` / `set_upgrade_enabled` / `buy_part`,
`OwnedCar.installed_upgrades` / `disabled_upgrades`,
`UpgradeLibrary.rally_gate_met` and `unlocked_by_rally` (there are no rallies to
gate on), and `auto_build_plan`. That is a large deletion and the single
riskiest part of this pivot — `grep -rn 'UpgradeLibrary' tests/headless/` reports
10 test files touching it.

Open sub-question: does the **engine swap** (`EngineSwap`, free and unlimited
once `RallyLibrary.ENGINE_SWAP_UNLOCK_RALLY` is won) survive? Its unlock gate is
a rally that will no longer exist. Simplest answer: retire it with the rest, or
re-gate it as a meta shop purchase.

### Perks — a straight lift from RR

TAPPA has no equivalent today, so this is additive rather than a replacement.
RR's `PERK_DEFINITIONS` gives 9 perks (coinMagnet, selfHealing, treeHugger,
driftBonus, nitrous, rubberBody, trailBlazer, luckyCoins, crowdPleaser), each
with a `price`, a `description`, and an `unlock: {stat, threshold}` gate keyed to
a lifetime counter in `GLOBAL_STAT_DEFINITIONS`. Crossing a threshold makes a
perk *purchasable*; buying it is a separate star cost; at most
`PERK_MAX_EQUIPPED = 3` are equipped at once.

For TAPPA this needs three new pieces: a `PerkLibrary` (authored content module,
static, mirroring `UpgradeLibrary`/`RallyLibrary` — not an autoload), lifetime
stat counters on the profile, and a perks menu (keyboard + gamepad navigable,
with a nav test).

Per `CLAUDE.md`'s testing rules, perk *definitions* are authored data: test that
"an unlocked perk is purchasable", "at most `PERK_MAX_EQUIPPED` can be equipped",
"a perk below its threshold is not offered" — never that a specific perk exists,
costs a specific amount, or unlocks at a specific threshold.

### Lifetime global stats

New, and load-bearing for perks. RR tracks counters like `totalCoinsCollected`,
`totalDamageTaken`, `totalMoneySpent`. TAPPA's natural equivalents: total stages
cleared, total runs started/failed, total damage taken, total stars earned/spent,
total distance, best region depth. These live on the profile, only ever grow, and
survive run failure. Follow RR's single-registry pattern (its `CLAUDE.md` calls
this out explicitly: one registry with `satisfies`, type derived via
`keyof typeof`) — in GDScript, one authored `const STATS` dictionary that the
menu, the perk gates, and the save backfill all read, rather than parallel lists.

### Repair

TAPPA already has both halves and needs only rewiring. `DamageModel`
(`scripts/damage_model.gd`) keeps its "HP floors at 0, never wrecked" rule per
decision 6. `Save.field_repair(instance_id, hp_fraction, toe_fraction)` already
implements a partial between-stage repair, and `ChallengeSession` already routes
it through `_pending_repair` / `take_pending_repair()`.

The change is that repair stops being automatic and becomes **a choice that
competes with a boost** — RR's `repairCarUpgrade` is always among the offered
picks, so taking it costs you a boost. RR also scales the repair *down* as the
run progresses (`REPAIR_AMOUNT` is a curve keyed by `tracksCompleted`), which
makes late-run damage genuinely threatening. That curve is a `GameConfig`
tunable here.

The paid garage repair (`Save.repair_car`, `Save.repair_price`) has no obvious
place left — between runs the car resets anyway. Recommend retiring it.

### Car acquisition — RR's shop

Today TAPPA has **no car shop at all**: cars are won outright at prize rallies
(`RallyLibrary.prize_car_id`, `features/prize-rallies.md`,
`RewardSystem.draw_car`), and stars only buy repairs and parts. RR is the
opposite — a flat currency shop (`CAR_LIST`, each `CarDefinition` with a fixed
`cost`, purchase recorded in persisted `boughtCars`).

Following RR, as decided: `CarLibrary.CARS` gains a star `cost` per car, the car
select screen offers a Buy action for unowned cars, and ownership persists in the
existing `profile["cars"]` structure. This retires prize rallies and
`RewardSystem.draw_car` along with the rallies that advertised them.

Worth noting as a design loss: prize rallies are a more interesting acquisition
hook than a flat shop, and a plain price list makes the run's own rewards feel
thin. A middle option — a car is *revealed* by clearing a region, then bought
with stars — keeps a discovery beat inside the RR model. Flagged in Open
questions since the decision was "follow RR".

### The UI — dropping the diegetic HQ

Per decision 9. Today the hub is `hq.tscn` + `scripts/hq.gd` (`HqController`,
**3563 lines** — the largest script in the project), documented in
`features/hq.md` and `features/menus.md`. It is *one continuous 3D space*: an
`enum View { EXTERIOR, GARAGE, TABLE, LIFT, CARPARK, SETTINGS }` names camera
**stations** and `go_to(view)` tweens a single `Camera3D` between authored poses
(`GameConfig.hq_*_cam_eye` / `hq_*_cam_look`, eased over `menu_camera_move_time`).
Props are clickable `Area3D`s with `input_ray_pickable`. Around it sit nine
collaborator scripts: `hq_environment.gd` (buildings, trees, garage shell, lift),
`hq_carpark.gd` (with its own `enum CarparkMode { RALLY, FREEROAM, SWAP, STARTER,
WHEELS, CHALLENGE, PRESENT }`), `hq_tuning_lift.gd`, `hq_table.gd`,
`hq_map_table.gd`, `hq_present_reveal.gd`, `hq_challenge.gd`,
`hq_multiplayer.gd`, and `hq_overlays.gd`.

**The good news: most of the 2D already exists.** `HqOverlays` already builds
flat overlay content for every station — `build_title_overlay`,
`build_garage_overlay`, `build_table_overlay`, `build_lift_overlay`,
`build_car_overlay`, `build_settings_overlay`, `build_challenge_overlay`,
`build_multiplayer_overlay`. And `MenuPage` (`scripts/menu_page.gd`) is already
"the house page shape" — a body box that hugs its contents with an action row
gapped below it. So this is mostly **re-hosting existing overlay builders on a
plain `CanvasLayer` and deleting the 3D side**, not designing a UI from nothing.

The screen list, each a `MenuPage` wired with `MenuNav.attach`:

| Screen | Source today |
| --- | --- |
| Title | `build_title_overlay` |
| Hub / main menu (Run, Cars, Shop, Perks, Stats, Settings) | new, replaces the garage station |
| Region select | new (pivot) |
| Car select + buy | `build_car_overlay` + `hq_carpark.gd`'s bay paging |
| Boost-level shop | new (pivot) |
| Perks | new (pivot) |
| Between-stage pick | new (pivot) |
| Run summary / run over | new (pivot), replaces `podium.tscn` |
| Settings | `SettingsMenu` — already host-neutral, also backs the pause menu |

**One navigation regime instead of two.** `features/menu-navigation.md`
currently documents two: flat menus driven by `MenuNav.attach`, and the spatial
`hq.gd::_unhandled_input` per-station branches. Dropping the diegetic hub
deletes the second regime outright, which is a real simplification of that doc
and of every screen that had to work in both.

**`WorldPanel` goes too.** `scripts/world_panel.gd` / `world_panel_host.gd`
(`features/world-panel.md`) welds menus into 3D world space off an anchor, and
`config/game_config.tres` ships `world_space_menus` **ON**, so it is the path
players actually get. Its consumers are `hq_overlays.gd`, `hq_challenge.gd`,
`rally_detail.gd` and `upgrade_slot_popup.gd` — every one of them hub-side and
either deleted or re-hosted by this pivot. With no 3D hub there is nothing left
to weld a panel to, so retire the whole mechanism and its config flag.

**The overworld hub goes too.** `overworld.tscn` / `scripts/overworld_region.gd`
(`features/overworld.md`, `features/overworld-frame-loop.md`,
`todo/overworld-hq.md`) is a *second*, even more diegetic hub — a drivable open
world — selected by `GameConfig.overworld_enabled` via `Scenes.hub_path()`. It is
the opposite direction from decision 9, so it retires with the rest, and
`Scenes.hub_path()` collapses from a branch to a single constant (the seam's own
header comment explains it exists solely to keep the two hubs in sync).

**How cars are shown without a 3D car park.** The car park stages real 3D car
models in bays. A flat car list still wants to show the car, and the asset for it
already exists: `scripts/car_silhouettes.gd` (`CarSilhouettes`) holds baked
side-profile vector outlines per `CarLibrary` model id, generated by
`tools/bake_car_silhouettes.gd` and designed to be rasterised by `PolygonIcon`.
That is the cheap answer. The richer alternative is a small `SubViewport` with
just the car on a turntable and no environment — far lighter than the current HQ
without losing the 3D model. Flagged in Open questions.

**Two incidental wins.** `hq.gd::_ready` currently has to show a `LoadingScreen`
cover because building the HQ (ground mesh, buildings, tree ring, bush ring,
spectator crowds, garage, lift, map table, parked lineup) is synchronous and
takes a visible beat. A flat UI deletes that build entirely — a straight startup
improvement, and relevant to `todo/mobile-web-performance.md`. It also removes
the single biggest script in the codebase from the maintenance surface.

**What is genuinely lost:** the diegetic hub is a lot of the game's character,
and this trades it for speed and simplicity. Worth being clear-eyed that it is a
one-way door — the 3D environment, the map table model, the present-box reveal
and the tuning lift are all substantial authored work being deleted, not
mothballed. If there is any doubt, the flat UI can be built alongside the HQ
behind a flag first (the `overworld_enabled` precedent shows the codebase can
carry two hubs) and the HQ deleted only once the flat one is clearly better.

### Economy

Stars survive as the single persistent currency, and the ledger already works the
way this pivot needs: `stars_earned` / `stars_spent` on the profile, spendable
figure via `Save.stars_available()`, never reset. RR likewise keeps `money` across
death and has no run-scoped second currency.

What changes is the **source**. Today stars come from rally placement
(`RallyLibrary.stars_for_placement` — 3/2/1 by podium position), which dies with
the rival field. RR's model: a per-stage payout that grows with stages completed
(`LEVEL_WINNINGS_BASE * LEVEL_WINNINGS_MULTIPLIER^tracksCompleted`), plus a
fast-completion bonus proportional to time saved against the target, plus
collectables picked up mid-stage. The first two map cleanly onto the new stage
loop; the third (RR's coins) would be a new prop system and is optional.

Sinks, all star-priced: cars, boost levels, perks. That is three sinks against
one source, which is a healthier economy than TAPPA has today.

### Save schema

Needs a `SCHEMA_VERSION` bump (currently `6`, `scripts/save_manager.gd`) and a
migration step in `_migrate_step`. Existing profiles carry cars, parts and stars
earned under rules that will no longer exist, so the migration has to decide
whether to convert (e.g. refund fitted parts as stars) or reset. New keys:
`regions_cleared`, the run state (which can reuse the `challenge_run` shape),
lifetime stats, `bought_perks` / `equipped_perks`, `boost_levels`. Retired keys:
`KEY_RALLIES` (per-rally best placements), `reward_history`, the adaptive
difficulty counters (`AiDifficulty.KEY_STEPS` / `KEY_WIN_STREAK` /
`KEY_LOSS_STREAK`), `KEY_LEGACY_PART_UNLOCKS`, `KEY_LEGACY_ENGINE_SWAP`.

## What gets deleted

Sized honestly, because this is the bulk of the work and most of the risk:

- **Rival field and everything serving it** — `RallyLibrary.generate_opponent_field`,
  `_eligible_combos`, `_draw_distinct_combos`, `_residual_pace_trim`, `swap_weight`,
  `rating_match_weight`, `placement`, `is_top3`, `build_standings`, `event_wreck`,
  `RIVAL_NAMES`, the `PACE_*` band consts, `scripts/rival_pace.gd`, the rival ghost
  (`features/rival-ghost.md`), opponent wrecks (`features/opponent-wrecks.md`), and
  adaptive difficulty (`scripts/ai_difficulty.gd`).
- **The overworld map** — `hq_map_table.gd`, `hq_table.gd`, `rally_detail.gd`, the
  reveal geometry listed above, `textures/map_world.jpg`, and the map-pin half of
  `hq.gd` (`_refresh_map_pins`, `_make_pin`).
- **The diegetic 3D hub** (decision 9) — `hq.tscn`, the bulk of `hq.gd` (3563
  lines: the `View` station enum, `go_to`, the `Area3D` picking, `_unhandled_input`'s
  spatial branches), `hq_environment.gd`, `hq_tuning_lift.gd`,
  `hq_present_reveal.gd`, `scripts/map_table.gd`, the parked-car lineup and lift
  car props, the `LoadingScreen` cover in `_ready`, and every `GameConfig.hq_*`
  camera pose. `hq_carpark.gd`'s `CarparkMode` collapses to a flat car list.
- **`WorldPanel`** — `scripts/world_panel.gd`, `scripts/world_panel_host.gd`,
  `features/world-panel.md`, and the `world_space_menus` config flag.
- **The overworld hub** — `overworld.tscn`, `scripts/overworld_region.gd`,
  `GameConfig.overworld_enabled`, `Scenes.hub_path()`'s branch,
  `features/overworld.md`, `features/overworld-frame-loop.md`, and
  `todo/overworld-hq.md`.
- **The persistent parts model** — most of `UpgradeLibrary` (1182 lines) and the
  `Save` methods listed under Upgrades.
- **Prize rallies and reward draws** — `RewardSystem.draw_car`, `prize_car_id`,
  `prize_part_id`, `prize_capability_id`, `has_prize`.
- **`RallySession`** as a whole, once its stage-loop responsibilities move to the
  generalised run session.
- **The authored `RALLIES` table's non-event fields** — `restriction`, `map_pos`,
  `special`, `difficulty` (unless reused as the draw's ordering proxy),
  `prize_*`, `unlocked_by_rally`. The `events` arrays are the part that survives.

Corresponding `features/` docs must be deleted or rewritten in the same change,
per `CLAUDE.md` — at minimum `map-exploration.md`, `regions.md`,
`prize-rallies.md`, `star-economy.md`, `rally-session.md`, `upgrade-catalogue.md`,
`damage.md`, `rally-roster.md`, `menus.md`, `hq.md`, `menu-navigation.md` (loses
a whole regime), `world-panel.md`, `overworld.md`, `overworld-frame-loop.md`,
`rival-ghost.md`, `opponent-wrecks.md`, and `features/README.md`'s index.

## Suggested staging

Each stage should land working and testable on its own; this is too large for one
change.

1. **Decide and document.** Settle the Open questions, rewrite `gameplay.md` to
   the roguelike vision, and fold `todo/challenge-career-reuse-drift.md` into
   this plan.
2. **Generalise the session.** Extract `RunSession` from `ChallengeSession` with
   a pluggable stage source and fail rule; keep the challenge mode green on top
   of it. No player-visible change yet.
3. **Region run mode, behind the existing menus.** Region stage pool, seeded
   8-stage draw, `LapTimeModel`-derived timer, run-over on a missed target.
   Playable end to end while the old career still exists.
4. **The flat UI shell** (decision 9) — title, hub, settings, car select, all as
   `MenuPage` + `MenuNav.attach` on a plain `CanvasLayer`, re-hosting the
   existing `HqOverlays` builders. Recommend landing this *behind a hub flag*
   alongside the HQ rather than deleting the HQ in the same change, so the flat
   shell can be judged before the 3D one is gone. Nav tests included.
5. **Region select + linear unlock**, replacing the map table, on the new shell.
6. **In-run boosts + repair pick** between stages, wiped on run end.
7. **Meta shop**: boost levels, then car purchasing.
8. **Lifetime stats, then perks** (perks depend on stats).
9. **Delete the old career and the 3D hubs** — rivals, map, parts, prize
   rallies, `hq.tscn`, `overworld.tscn`, `WorldPanel` — and the save migration.
   Last, so the game is never non-functional mid-pivot.
10. **Docs and full suite.** `features/` rewritten, one full `./run_tests.sh`.

Dependencies worth stating explicitly, per `CLAUDE.md`'s todo rules: 5–8 all
render on the shell from 4, so 4 comes first among the UI work; 6 depends on 3;
8's perks depend on 8's stats; 9 depends on everything; the save migration in 9
cannot be written until 5–8 have settled what the profile holds.

## Open questions

1. **`greece_coast` has 3 authored events and a run needs 8.** Fold it into
   `greece`, author more rallies, or allow procedural top-up?
2. **Is the target time car-relative or fixed per stage?** Car-relative
   (`optimum_ms * pace`) neutralises car choice; fixed makes a better car
   straightforwardly better, which is more RR-like and makes the car shop matter.
3. **Do stars persist through a failed run in full?** RR keeps 100% of money.
   Confirm no partial loss on failure.
4. **Does the car itself survive a failed run?** RR keeps `boughtCars` — a run
   loss costs progress, not the car. Confirm no permadeath of the vehicle.
5. **Is one run per region, repeatable?** Can a cleared region be re-run for
   stars, or does it lock once cleared? Repeatable is the obvious grind valve.
6. **Does the daily/weekly/monthly challenge survive the pivot?** It is a
   substantial shipped feature (`features/rally-challenge.md`, cloud
   leaderboards) that fits the new model better than the old one — recommend
   keeping it, which is why stage 2 preserves it.
7. **Engine swap:** retire, or re-gate as a meta purchase?
8. **Car acquisition:** flat price list as decided, or the reveal-then-buy middle
   option noted above?
9. **Do collectables (RR's coins) come along** as an in-stage star source, or is
   the payout purely time-based?
10. **How are cars shown in the flat UI** — baked `CarSilhouettes` outlines
    (cheap, already generated), or a small turntable `SubViewport` keeping the
    real 3D model?
11. **Is the HQ deleted outright, or does the flat shell ship behind a flag
    first?** Staging above assumes the latter; deleting outright is faster but
    unrecoverable if the flat UI disappoints.
12. **What happens to the podium?** `podium.tscn` is a flat scene already, but a
    run that ends by missing a timer has no placement to celebrate. Replace with
    a run-summary screen, or keep it for a cleared region?
13. **Multiplayer** (`hq_multiplayer.gd`, `LobbySession`,
    `features/multiplayer-lobby.md`) is reached from the HQ and assumes the
    rally/rival model. Keep it on the new shell, or retire it with the career?
