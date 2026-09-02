# Roguelike pivot — replacing the career loop

**Status: AGREED IN OUTLINE, demolition not started.** This is the spec for a
*complete* pivot of TAPPA's gameplay loop, from the Gran-Turismo-shaped career it
ships today to a run-based roguelike modelled on `felixxwu/roguelike-rally`
(referred to below as **RR**). Decisions 1–20 are settled. **Read the Blockers
section before starting stage 2** — it lists errors in the plan that would break
the demolition if followed as written.

Landed so far: the multiplayer lobby is deleted (decision 16). Nothing else in
this document has been implemented.

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
10. **`greece_coast` gets more authored rallies** rather than being folded or
    topped up procedurally — every region must carry a real 8-stage pool.
11. **The stage target time is FIXED, not car-relative** — computed from a
    reference car, so a faster car is straightforwardly better.
12. **A cleared region stays repeatable at full payout.** This is the economy's
    grind valve.
13. **Stages carry collectables** (RR's coins) as a second star source.
14. **A failed run keeps 100% of stars** and never costs you the car.
15. **The Daily/Weekly/Monthly challenge survives** the pivot.
16. **Multiplayer is deleted.** ~~Left dormant~~ — revised, and **already done**:
    dormant code cannot survive a destructive pivot with no flag to hide it
    behind. `scripts/multiplayer/`, `hq_multiplayer.gd`, `cloud/lobby_board.gd`,
    the `LobbySession` autoload, 9 test files, `features/multiplayer-lobby.md`
    and the `lobby_rounds` / `lobby_state` Firestore rules are gone.
17. **Engine swap is re-gated as a meta shop purchase** rather than retired.
18. **Cars are shown as a 3D turntable** in the flat UI, not as flat art.
19. **A run ends on a run-summary screen**, replacing `podium.tscn`.
20. **Everything is deleted destructively, up front. No flags, no dual code
    paths, no migration.** `hq.tscn` goes in the demolition stage rather than
    behind a hub flag; the save schema is reset rather than migrated. Maintaining
    two code paths everywhere costs more complexity than the safety is worth, and
    **git is the rollback mechanism** — the old career is one `git revert` away,
    which is cheaper and more reliable than a flag threaded through every
    transition site.

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

- an authored **`order` field** on `REGIONS`, since linear unlock needs a
  sequence. Not the array order — see Blockers: `REGIONS` explicitly forbids an
  ordering dependency, and `override_for_test()` lets tests pass arbitrary
  arrays;
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

**Not every rally has 3 events** — `shakedown`, `hm_timber_trophy` and
`hm_forest_gt` carry one apiece, so the pool must be counted, not multiplied.
Actual authored event counts (108 total):

| region | authored events |
| --- | --- |
| `home` | 36 |
| `greece` | 24 |
| `snow` | 18 |
| `taiga` | 15 |
| `home_coast` | 12 |
| `greece_coast` | **3** |

**`greece_coast` cannot fill an 8-stage run** — it has one rally, so its pool is
3 events against a requirement of 8. Per decision 10 this is fixed by
**authoring more `greece_coast` rallies**, not by folding it into `greece` or
topping up procedurally. Two consequences:

- This is authoring work that gates the region being playable at all, so it
  belongs in the stage that introduces region runs, not in a later polish pass.
- **Every region needs the same check.** A pool of exactly 8 means every run in
  that region draws the identical 8 stages, so the practical floor is
  comfortably above 8. Every region except `greece_coast` clears 8 today, but
  `home_coast` at 12 offers little variety between runs. Worth deciding a
  minimum pool size as a rule and authoring every region up to it, rather than
  treating `greece_coast` as a one-off.

**`RegionLibrary` explicitly forbids the ordering decision 2 requires.** The
header comment on `REGIONS` reads: *"ORDER CARRIES NO MEANING — regions do not
unlock in sequence … so do NOT re-introduce any ordering dependency. Regions gate
nothing."* Making array order load-bearing therefore collides with an authored
invariant, and with `override_for_test()`, which lets tests substitute arbitrary
region arrays. **An explicit `order` field is the only safe option**, and that
comment plus `features/regions.md` must be rewritten in the same change.

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
car.

Per decision 11 the target is **fixed, not car-relative**: pass
**`CarPerformance.REFERENCE_CAR`** (`scripts/car_performance.gd` — the same
reference the rating system normalises against) as the `car_meta`, so a stage's
target is a property of the *stage*, identical for every player and every car.
Target time is then `optimum_ms(track, REFERENCE_CAR, event) * target_pace`, with
`target_pace` a `GameConfig` tunable that tightens with stage index.

This is what makes the car shop matter — a faster car genuinely beats the clock
more easily, rather than having the bar raised to match it. Three things follow:

- **The starter car sets the difficulty floor.** Stage 1's target must be
  clearable in the worst car a player can own, or the run is unwinnable from a
  bad purchase. Tune `target_pace` against the starter, not against a mid-tier
  car.
- **A late-tier car will trivialise early stages, by design.** That is the
  reward for buying it. If it ever feels *too* flat, the lever is region-gated
  car tiers, not a car-relative target — reintroducing that would undo this
  decision.
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

The **engine swap** (`EngineSwap`, free and unlimited once
`RallyLibrary.ENGINE_SWAP_UNLOCK_RALLY` is won) survives, re-gated as a **meta
shop purchase** per decision 17 — its old gate was a rally that will no longer
exist. `UpgradeLibrary.drivetrain_swap_unlocked` and
`RallyLibrary.engine_swaps_unlocked` both currently read a rally-completion flag
off the profile; both re-point at a purchased-unlock flag instead. Note this is
the one piece of the persistent per-car modification model that outlives the
pivot, so `Save.swap_engines` and the engine-swap car-select flow stay alive
even as `install_upgrade` / `buy_part` go.

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

Following RR, as decided and re-confirmed: `CarLibrary.CARS` gains a star `cost`
per car, the car select screen offers a Buy action for unowned cars, and
ownership persists in the existing `profile["cars"]` structure. This retires
prize rallies and `RewardSystem.draw_car` along with the rallies that advertised
them.

Worth keeping in view as a design loss: prize rallies were a more interesting
acquisition hook than a price list, and with car acquisition now purely
transactional, **clearing a region rewards only the next region's unlock**. If
region clears end up feeling unrewarding in play, the cheapest fix is a one-off
star bounty for a first clear rather than reintroducing reveal-gating.

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
| Run summary | new (pivot), replaces `podium.tscn` — decision 19 |
| Settings | `SettingsMenu` — already host-neutral, also backs the pause menu |

**The run summary** (decision 19) is one screen for both outcomes — cleared all 8
stages, or ended on a missed timer — showing stages cleared, time margin per
stage, stars earned and boosts taken. One screen rather than a podium-plus-defeat
pair, because a run that ends by missing a clock has no placement to celebrate
and the same information is worth showing either way. `podium.tscn` and
`scripts/podium.gd` retire with it.

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

**How cars are shown without a 3D car park.** Per decision 18, a **turntable
`SubViewport`**: the real car model on a slow rotation against a plain
background, no environment, no lot, no lighting rig beyond a key light. This
keeps the models — which are the game's main authored art — visible in a UI that
has otherwise gone flat, at a tiny fraction of the current HQ's build cost
(`Scenes.car_scene()` already exists as the one cached load of `car.tscn`, used
by the HQ lineup, the podium and the dev tools, so the spawn path is in place).

Two practical notes: a `SubViewport` renders every frame it's visible, so it
should be paused when the car list isn't on screen, and mobile/web
(`todo/mobile-web-performance.md`) is where that cost will show first. The baked
`CarSilhouettes` outlines (`scripts/car_silhouettes.gd`, generated by
`tools/bake_car_silhouettes.gd`) remain available as a cheap fallback for dense
list rows or a low-spec path, since they're already generated and cost nothing to
draw.

**Two incidental wins.** `hq.gd::_ready` currently has to show a `LoadingScreen`
cover because building the HQ (ground mesh, buildings, tree ring, bush ring,
spectator crowds, garage, lift, map table, parked lineup) is synchronous and
takes a visible beat. A flat UI deletes that build entirely — a straight startup
improvement, and relevant to `todo/mobile-web-performance.md`. It also removes
the single biggest script in the codebase from the maintenance surface.

**What is genuinely lost:** the diegetic hub is a lot of the game's character,
and this trades it for speed and simplicity. The 3D environment, the map table
model, the present-box reveal and the tuning lift are substantial authored work
being deleted, not mothballed.

Per decision 20 this is done **destructively and up front** — no hub flag, no
period of carrying both. The `overworld_enabled` precedent proves the codebase
*can* hold two hubs, and that is exactly the argument against doing it again:
`Scenes.hub_path()` exists only to stop two hubs drifting apart, and its own
header comment records the seven transition sites that had to be corralled to
make it safe. Adding a third destination means every one of those sites, every
menu test, and every doc carries the branch for as long as the flag lives.

So `hq.tscn`, `overworld.tscn` and `WorldPanel` all go in the demolition stage,
and the flat shell is built on the empty space. **Git is the rollback**: the old
hub is one revert away, which is both cheaper and more trustworthy than a flag
nobody exercises.

### Economy

Stars survive as the single persistent currency, and the ledger already works the
way this pivot needs: `stars_earned` / `stars_spent` on the profile, spendable
figure via `Save.stars_available()`, never reset. RR likewise keeps `money` across
death and has no run-scoped second currency.

A failed run keeps **100% of stars** and never costs the player a car
(decisions 14 and 15's RR-faithful reading): the run's stage progress and its
temporary boosts are the only casualties. Combined with decision 12 — a cleared
region stays **repeatable at full payout** — the player can always grind a
region they've beaten to afford the next car, so the economy has no dead end.

What changes is the **source**. Today stars come from rally placement
(`RallyLibrary.stars_for_placement` — 3/2/1 by podium position), which dies with
the rival field. Replacing it, per RR:

1. **Per-stage payout** that grows with stages completed
   (`LEVEL_WINNINGS_BASE * LEVEL_WINNINGS_MULTIPLIER^tracksCompleted`), so
   surviving deep into a run is where the money is.
2. **Fast-completion bonus** proportional to time saved against the target.
3. **Collectables** picked up mid-stage (decision 13).

**Collectables are genuinely new work** — there is no pickup or trigger-volume
system in the codebase today. It needs a prop mesh, placement along the generated
track, a pickup trigger, a HUD counter, audio, and a rule for what happens to
uncollected ones on a failed stage. The nearest existing patterns to model
placement on are the scatter fields (`bush_field.gd`, `billboard_field.gd`,
`TreeMeshField`) and the trackside props in `rally_flag.gd`. Because they compete
with the clock for the player's attention, collectables also interact with
decision 4 — detouring for one can cost the run — which is a *good* tension, but
placement needs to be authored with that in mind rather than scattered blindly.

Sinks, all star-priced: cars, boost levels, perks, and the engine-swap unlock
(decision 17). Four sinks against three sources is a far healthier economy than
TAPPA has today, where stars only buy repairs and parts.

### Save schema

Needs a `SCHEMA_VERSION` bump (currently `6`, `scripts/save_manager.gd`), and per
decision 20 **no migration is written**. Existing profiles carry cars, parts,
placements and stars earned under rules that will no longer exist; converting
them means writing (and testing) a transform between two economies that never
coexist. Instead, a profile older than the pivot version is treated as "start
fresh".

That also lets the old `_migrate_step` chain and its `_MIGRATABLE_FROM :=
[1, 2, 3, 4, 5]` ladder go, along with the legacy backfill keys
(`KEY_LEGACY_PART_UNLOCKS`, `KEY_LEGACY_ENGINE_SWAP`, `MOVED_PART_UNLOCKS`,
`OLD_ENGINE_SWAP_UNLOCK_RALLY`) — a meaningful simplification of a file that
currently carries five versions of history.

**The cloud path needs the same treatment, and is the sharper edge.** `CloudSync`
refuses a remote document whose `schema_version` exceeds `Save.SCHEMA_VERSION`,
so a player who opens the pivot on one device and the old build on another will
have the old build reject the new save. Under a destructive policy the answer is
to accept that: the pivot is a clean break, old cloud documents are not
migrated, and a stale device is expected to be updated rather than
interoperated with.

New keys:
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
- **The podium** — `podium.tscn`, `scripts/podium.gd`, replaced by the run
  summary (decision 19).

**Explicitly NOT deleted**, despite sitting next to all of the above:

- **The Daily/Weekly/Monthly challenge** (decision 15) — kept, and is the base
  the new run session is generalised from.
- **Multiplayer** (decision 16) — `hq_multiplayer.gd`, `LobbySession`,
  `features/multiplayer-lobby.md` stay in the tree, unreachable from the new
  shell. **But "dormant" is in tension with decision 20**: demolition deletes
  `RallySession`, so if the lobby references it, dormant code will not compile
  and there is no flag to hide behind. The destructive-policy answer is to delete
  multiplayer in stage 2 rather than carry a broken mode — but that is a whole
  feature, so stage 2 must check the coupling and get a call on it rather than
  discovering it mid-demolition.
- **Engine swap** (decision 17) — survives, re-gated as a shop purchase.

Corresponding `features/` docs must be deleted or rewritten in the same change,
per `CLAUDE.md` — at minimum `map-exploration.md`, `regions.md`,
`prize-rallies.md`, `star-economy.md`, `rally-session.md`, `upgrade-catalogue.md`,
`damage.md`, `rally-roster.md`, `menus.md`, `hq.md`, `menu-navigation.md` (loses
a whole regime), `world-panel.md`, `overworld.md`, `overworld-frame-loop.md`,
`rival-ghost.md`, `opponent-wrecks.md`, and `features/README.md`'s index.

## Suggested staging

**Demolish first, then rebuild on clean ground** (decision 20). The earlier draft
of this plan deleted last, so the game stayed playable throughout; that ordering
is abandoned deliberately. Deleting first means every later stage writes new code
against a small codebase instead of threading around a career that is on its way
out, and it removes the temptation to keep a compatibility shim "just for now".

**The cost, stated plainly: the game does not run between stages 2 and 3.** That
window is the whole risk of this approach, so stage 3 is deliberately scoped to
the minimum that gets back to playable — not the minimum that is fun. The
Daily/Weekly/Monthly challenge (decision 15) also breaks during demolition and
returns with `RunSession` in stage 3, since it shares the pieces being torn out.

1. **Decide and document.** Settle the remaining questions, rewrite `gameplay.md`
   to the roguelike vision, and fold `todo/challenge-career-reuse-drift.md` into
   this plan. No code.
2. **Demolition.** One destructive change, on its own commit so the revert is
   clean. **Extract before deleting**: `RallySession.apply_event_config` /
   `canonical_event_config` / `apply_field_repair_to` and `RallyLibrary`'s
   empty-field `build_standings` have live non-career callers (see Blockers), so
   they move to their new home first. `UpgradeLibrary.EFFECTS` / `_cfg_set` /
   `apply` are likewise **retained**, not deleted. Then delete: the rival field
   and everything serving it, the map and its reveal geometry, the parts
   catalogue and install/buy paths, prize rallies, the rest of `RallySession`,
   `podium.tscn`, `standings.tscn`, `hq.tscn` and its collaborators,
   `overworld.tscn`, `WorldPanel`, adaptive difficulty, `map_fog.gd` and
   `rally_trophy.gd`. Update `project.godot` (main scene, autoloads) and
   `Scenes.is_hub_scene` so music still resolves. Reset the save schema with **no
   migration**. Resolve the coupled systems the reviews found — tuning's unlock
   gate and the aero wing meshes it drives, the start-line menu, `stage_key`,
   wheel customisation, the starter picker. The tree compiles at the end of this
   stage; the game does not run.
3. **Back to playable — the minimum spine.** `RunSession` generalised from
   `ChallengeSession`, a bare flat shell (title → car select → run), the region
   stage draw, the fixed reference-car timer, run-over on a missed target, and a
   plain run-summary screen. Ugly is fine; running is the bar. The challenge mode
   comes back here too, as the second caller of `RunSession`.
4. **Region select + linear unlock**, replacing the map table. Includes
   **authoring the extra `greece_coast` rallies** (decision 10) and whatever else
   a minimum pool size demands — the region is not playable without them.
5. **In-run boosts + repair pick** between stages, wiped on run end.
6. **Meta shop**: boost levels, then car purchasing, then the engine-swap unlock.
7. **Lifetime stats, then perks** (perks depend on stats).
8. **Collectables** (decision 13) — prop, placement, pickup trigger, HUD counter,
   audio. Deliberately last of the features: it is the only wholly new runtime
   system in the pivot, and the economy can be tuned without it.
9. **Polish and docs.** Flesh out the flat shell beyond stage 3's spine,
   `features/` rewritten, one full `./run_tests.sh`.

Dependencies, per `CLAUDE.md`'s todo rules: everything depends on 2; 4–8 all
render on the shell from 3; 7's perks depend on 7's stats; 8 depends on 3 (it
needs a generated stage to place props along). Nothing depends on a save
migration, because there isn't one.

## Blockers found in a second review

These are errors in the plan above, not open questions. Verified against the code.

### `RallySession` cannot be deleted wholesale — the challenge depends on it

The spec calls `RallySession` "over half rival plumbing" and deletes it in stage
2, with the challenge (decision 15) returning in stage 3. But `ChallengeSession`
calls into it **right now**, for the exact mechanisms this pivot plans to keep:

| Call site | What it needs |
| --- | --- |
| `challenge_session.gd` → `RallySession.apply_field_repair_to()` | the `_pending_repair` between-stage repair the boost-pick screen reuses |
| `challenge_session.gd` → `RallySession.clear_free_roam_handoff()` | the free-roam supersede rule |
| `challenge_session.gd` → `RallyLibrary.build_standings()` (twice) | its own standings, with an empty rival array |
| `challenge_session.gd` → `RallyLibrary.stars_for_placement()` | its completion reward |

`RallySession` is also a **`project.godot` autoload**, and its statics
`apply_event_config()` / `canonical_event_config()` are the shared stage-config
spine — consumed by `driving_context.gd`, `track_cache.gd`, `region_library.gd`,
`challenge_library.gd` and `benchmark_mode.gd`. Roughly 34 scripts reference it.

So stage 2's claim that "the tree compiles at the end of this stage" is **not
achievable as written**. The fix: stage 2 must *extract* the surviving statics
(event config, field repair, the empty-field standings builder) into their new
home before deleting the rest, and the spec must name that home. This is real
work the plan currently hides inside the word "delete".

### Deleting `hq.tscn` leaves the project unbootable

`project.godot` line 15: `run/main_scene="res://hq.tscn"`. Nothing in the 9
stages edits `project.godot`, yet stage 2 deletes that scene and the autoload
block needs changing too (`RallySession` out, any `RunSession` in). Separately,
`MusicLibrary.is_hq_scene` → `Scenes.is_hub_scene` picks hub-vs-rally music off
the hub scene path, so the flat shell must be registered there or every hub
screen plays a rally song.

### Deleting the parts model silently changes every car's bodywork

`car.gd` calls `_set_aero_visible(_active_body(),
UpgradeLibrary.aero_tuning_unlocked(owned))` — the **visible rear wing** is
gated on a fitted aero part. The earlier gap entry caught that deleting parts
breaks *tuning's* unlock; it missed that it also un-decides every car's
silhouette, with `tests/headless/test_aero_visibility.gd` and
`test_aero_visible_traversal.gd` pinning the behaviour.

### `UpgradeLibrary.EFFECTS` must be explicitly retained, not deleted

Stage 5's in-run boosts route through `UpgradeLibrary.EFFECTS` / `_cfg_set` /
`apply()` — the reuse section says so — while the deletion list says "most of
`UpgradeLibrary` (1182 lines)" goes in stage 2. Those directly contradict. The
effects funnel is the part that survives; the catalogue, slots and install/buy
paths are what go.

### The testing blast radius is understated about fivefold

The spec says 7 test files touch `RallyLibrary` and 10 touch `UpgradeLibrary`.
Actual counts, of 226 test files: **49** touch `RallyLibrary`, **23**
`UpgradeLibrary`, **21** `RallySession`. That moves "no testing strategy" from a
process gap to **the dominant cost of stage 2**, and it undercuts the claim that
deletions will comfortably pull the suite under its ~5 minute budget — stage 3's
new `RunSession` and flat shell need new scene tests, and nothing in the plan
reserves a budget check or points at `features/testing.md`'s cheap patterns.

### More systems still unaccounted for

- **Wheel customisation** (`features/wheel-customization.md`, `wheel_style.gd`,
  `CarparkMode.WHEELS` and its own camera framing) — the spec collapses
  `CarparkMode` "to a flat car list" and never mentions it.
- **The starter picker lives in `overworld_picker.gd`** (`starter_cars`,
  `_starter_ids`, writes `profile["starter_picked"]`) — a file deleted with the
  overworld. So the starter-car loose end does not merely lack a decision, it
  loses its implementation.
- **`map_fog.gd`** reads `RallyLibrary.lit_sources(profile)` — reveal geometry
  being deleted, but the file is not in the deletion list.
- **`rally_trophy.gd`** is built on `MAX_STARS_PER_RALLY` / `STARS_FOR_WIN` /
  `STARS_FOR_PODIUM` / `STARS_FOR_FINISH`, all placement-derived.
- **`upgrade_options.gd`** (`SLOT_ENGINE` / `SLOT_TUNE` pseudo-slots,
  `grid_slots()`) is the shared data source for the garage grid *and* the
  start-line Upgrades page — and is the only UI seam the surviving engine swap
  (decision 17) is rendered through.
- **`registry.gd`, `crosswind.gd`, `weather_library.gd`, `stage_manager.gd`,
  `settings_menu.gd`, `global_standings.gd`** all reference `RallyLibrary` or
  `RallySession` and are in-stage runtime, not hub code.
- **`TrackCache`**: the spec bumps `BOARD_EPOCH` but not `CACHE_VERSION`.
  `data/track_cache.json` is a committed lockfile keyed to authored events, so
  scaling `turn_count` on later stages makes every drawn stage miss the cache and
  fall back to live DFS search — an uncosted per-stage load-time hit.

## Gaps found in review

A pass back over the codebase turned up systems this spec does not account for.
They are recorded here rather than silently decided.

### Systems the spec forgot entirely

- **Free roam / "Test Drive".** Reached from the car park
  (`CarparkMode.FREEROAM`), generated by `hq.gd._prepare_free_roam` from its own
  `GameConfig` block (`free_roam_straightness`, `free_roam_forestiness`,
  `free_roam_tarmac_fraction`, `free_roam_water_level_min_m/max_m`,
  `free_roam_relief_min`), with handoff state on `RallySession`
  (`free_roam_instance_id`, `free_roam_model_id`, `free_roam_region_id`,
  `clear_free_roam_handoff`) that `ChallengeSession` explicitly clears in two
  places and `benchmark_mode.gd` resets. Its entry point is being flattened away
  and nothing in this spec says whether it survives. It also has **no
  `features/` doc**, which per `CLAUDE.md` is its own gap to close.
- **Tuning.** `TuningLibrary` (`AXES := ["grip_balance", "brake_bias",
  "aero_balance"]`, `apply`, `axis_unlocked`) and `scripts/tuning_panel.gd` are
  free, reversible per-car config nudges, reachable from the start-line menu.
  The spec deletes the 3D tuning *lift* but never decides the fate of tuning
  itself. There is a **hard coupling**: `axis_unlocked` /
  `UpgradeLibrary.aero_tuning_unlocked` gate an axis on a *fitted aero part*, so
  deleting the parts model breaks tuning's unlock gate. Retire tuning, make all
  axes free, or re-gate on boost levels — but it cannot be left as-is.
- **The start line.** `scripts/start_line.gd` (`features/start-line.md`) runs
  MENU → FLY_IN → REVEAL → FADE before every stage. REVEAL exists to show the
  top-three rivals and dies with them. The good news is that a rival-free path
  **already exists and ships**: a challenge stage runs the identical MENU and
  skips straight to the fade via the empty-leaders branch, so the pivot inherits
  a working start line. The problem is that the MENU hosts **Upgrades and Tune
  Car** — both systems this pivot replaces — so its contents need redesigning
  even though its structure survives.
- **`standings.tscn`.** Every event currently pauses on it, and `world.gd`
  instantiates it as a panel. Its page 2 is `GlobalStandings`, the world
  leaderboard view. The spec introduces a between-stage pick screen but never
  says standings retires, nor what happens to its leaderboard page.
- **Global leaderboards.** `features/global-leaderboards.md`,
  `scripts/cloud/leaderboard.gd`, and a world-readable
  `stage_times/{stage}/times/{uid}` collection in `firestore.rules`, keyed by
  **`RallyLibrary.stage_key(rally, event_index)`**. Flattening rallies into a
  stage pool changes what a "stage" *is*, so the key derivation needs a decision.
  The boards can survive — each drawn authored event still has a stable identity
  — but `TrackCache.BOARD_EPOCH` must be bumped, since the pivot changes stage
  identity and stale entries would otherwise compete with new ones.
- **Cloud save.** `CloudSync` compares `Save.SCHEMA_VERSION` against the remote
  document and refuses one newer than it knows. A schema bump plus a wholesale
  profile rewrite is a cross-device event — the old career on one device, the
  pivot on another. The spec discusses local migration and never mentions the
  cloud path.

### Contradictions inside the spec

- **The run-state slot collides with the surviving challenge.** The Save schema
  section says run state "can reuse the `challenge_run` shape", while decision 15
  keeps the challenge itself. But `Save.is_challenge_locked` reads a *single*
  `profile["challenge_run"]`, and `set_challenge_run` replaces "whatever was
  there". A paused challenge run plus an active region run means two persisted
  runs and two locked cars. This needs two slots or a discriminated union — the
  casual "reuse the shape" hides a real decision.
- **Pool size is an economy dependency, not an authoring nicety.** Decision 12
  makes regions infinitely repeatable and repeatability is now the *primary*
  grind valve, while decision 10 keeps pools finite and authored. Open question 1
  frames minimum pool size as variety; it is actually load-bearing for the
  economy, because grinding a region is how a player affords the next car.
- **A fixed target plus a strictly-better car plus repeatable regions has a
  solved optimum.** Once a player owns a fast car, an early region becomes
  trivial and farmable. RR's escalating per-stage payout rewards depth, but
  nothing here stops the efficient strategy being "farm region 1 forever". The
  spec should decide whether payout scales with region difficulty, or whether
  early regions taper.
- **"Damage fails indirectly" is stronger than it sounds under a fixed target.**
  `DamageModel` floors HP at 0 and keeps the car drivable, so with a *fixed*
  target a heavily damaged car can become mathematically unable to hit the time
  — turning "indirect failure" into a known-doomed run the player must still
  drive out. The repair-vs-boost pick is the intended tension, but the spec
  should say whether a run can become unwinnable and, if so, whether the player
  is told and allowed to retire.

### Loose ends

- **`restriction` vs. region gating.** The spec deletes the `restriction` field
  (drive_mode / country / doors / cylinders), yet decision 11's note proposes
  "region-gated car tiers" as the balance lever if fast cars flatten early
  stages. That is approximately the restriction mechanism, unspecified. Either
  keep `restriction` re-pointed at regions, or drop the note.
- **The starter car.** `profile["starter_picked"]` / `starter_model_id` and the
  three-car starter picker exist today. RR instead grants `INITIAL_MONEY` and
  sends you to the shop. The spec never says which the pivot uses, and it is the
  first thirty seconds of the game.
- **`Save.record_podium_rally`** is the placement-shaped star-crediting entry
  point. Placement dies, but this function is not named among the deletions or
  rewrites.

### Process gaps

- **No testing strategy.** This pivot deletes or rewrites a large share of the
  suite — 7 test files touch `RallyLibrary`, 10 touch `UpgradeLibrary`, plus
  `test_hq_map_table`, `test_hq_tuning_lift`, `test_hq_present_reveal`,
  `test_menu_flow`, `test_menu_nav`, `test_overworld_garage`,
  `test_cloud_leaderboard` and more. **See the Blockers section for the real
  counts** — 49 / 23 / 21 files of 226, not the 7 / 10 claimed earlier. Stage 9
  says "one full run" but nothing about which tests are deleted versus
  rewritten.
- ~~**No rollback position for the gameplay pivot.**~~ **Resolved by decision
  20, in the opposite direction to what this gap proposed:** there is
  deliberately no in-code rollback. Maintaining two paths everywhere costs more
  than the safety buys, and git is the rollback. The consequence is accepted
  rather than mitigated — if the roguelike loop disappoints, the recovery is
  reverting the demolition commit, which is why stage 2 is kept as a single
  clean commit.
- **`features/` is bigger than the rewrite list.** There are 76 docs; the spec
  names ~16. Many more reference rallies, rivals, or the HQ in passing.

## Open questions

The 13 questions this spec opened have all been answered — they are decisions
3–20 above. What follows are the questions those answers *created*, none of which
block starting stage 1.

1. **What is the minimum stage-pool size per region?** Decision 10 says author
   `greece_coast` up rather than fold it, but a pool of exactly 8 makes every run
   in that region identical. A rule (say 16+, two runs' worth with no repeats)
   sets the authoring target for `greece_coast` and probably `home_coast` too.
2. **Do collectables persist within a run?** If you collect 20 on stage 3 and
   then fail stage 4, are those stars banked or lost with the run? Banking them
   fits decision 14 (a failed run keeps its stars); losing them makes late-run
   collecting tenser.
3. **Does a first region clear pay a bounty?** With acquisition purely
   transactional, clearing a region currently rewards only the next unlock — see
   the note under Car acquisition.
4. **What does the boost-level shop scale when a run hasn't started?** RR's
   `boostLevels` scale the magnitude of in-run picks, so their value is invisible
   until you're mid-run. Worth deciding how the shop communicates that.
5. **Does multiplayer still compile once `RallySession` is deleted?** Decision 16
   leaves it dormant, but under decision 20 there is no flag to hide broken code
   behind. If it references the career session it must be deleted in stage 2 or
   ported then — the one question stage 2 cannot defer.
6. **Is the old `_migrate_step` chain deleted outright?** Decision 20 writes no
   new migration, but the existing ladder from schema 1–5 could either go
   entirely (simplest) or stay for players mid-upgrade. Simplest is consistent
   with the rest of the policy.
