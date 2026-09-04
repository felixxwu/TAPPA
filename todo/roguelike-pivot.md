# Roguelike pivot — replacing the career loop

**Status: AGREED, demolition not started.** A *complete* pivot of TAPPA's
gameplay loop, from the Gran-Turismo-shaped career it ships today to a run-based
roguelike modelled on `felixxwu/roguelike-rally` (**RR** below). All decisions
are settled and there are no open questions; what remains is execution.
Decisions 46-49 were settled during stage 3, from holes the implementation found.

**On the numbering:** the list runs 1–36 then 38–45 — **44 decisions, and there is
no decision 37.** The gap is an artefact of a renumbering during review. It is
kept rather than closed because these numbers are cited from
`todo/roguelike-pivot-plan.md`, from `gameplay.md`, and from within this file;
renumbering would silently invalidate every one of them. Do not "fix" it.

**How to read this:** *Decisions* is the settled record — the why. *System-by-
system* is the design. *What gets deleted* and *Staging* are the work. **Read
*Hazards* before starting stage 2** — it lists things that will break the
demolition or silently change behaviour if not handled.

The executable task sequence lives in **`todo/roguelike-pivot-plan.md`**. This
file owns the decisions; that one owns the order of work and holds no decisions
of its own.

Landed so far: the multiplayer lobby is deleted (decision 16), unverified by any
test run (see Hazards → Unverified). Nothing else here is implemented.

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
    topped up procedurally — every region carries a real pool of its own.
    (Pool size later fixed at 16 by decision 32.)
11. **The stage target time is FIXED, not car-relative** — computed from a
    reference car, so a faster car is straightforwardly better.
12. **A cleared region stays repeatable at full payout.** This is the economy's
    grind valve.
13. **Stages carry collectables** (RR's coins), boosting the money a stage pays.
14. **A failed run keeps 100% of the money earned** and never costs you the car.
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
21. **Stars are replaced wholesale by RR-style money.** Not retained and
    re-sourced as earlier drafts assumed — the star ledger, placement tiers and
    everything built on them are deleted. Money is earned from stage completion
    (scaling with stages cleared), a fast-completion bonus proportional to time
    saved against the target, and coins picked up mid-stage.
22. **Region difficulty comes from `target_pace` scaled by region index**, not
    from re-authored per-region difficulty bands. One tunable, no roster
    re-authoring — the same stage simply demands a faster time later in the
    order.
23. **The run ships thin — one decision type, revisited after playing.** No route
    choice or stage modifiers until the loop is playable and the need is felt.
24. **Tuning survives, ungated.** All three axes free on every car; the aero-part
    gate goes with the parts model, and the rear-wing mesh becomes a plain
    per-car property rather than a parts-derived one.
25. **Wheel customisation survives; free roam does not.** The hub keeps cosmetic
    wheel swapping as its one non-shopping activity; Test Drive is retired with
    the rest of the car park's modes.
26. **Perk pacing is left as authored and tuned after playing.**
27. **One run at a time, one slot.** `profile["challenge_run"]` generalises to a
    single run record of either kind; starting a region run discards a paused
    challenge run and vice versa, behind a confirm. Keeps the existing car-lock
    query working with no discriminator.
28. **A new player starts with money and buys from the shop.** The three-car
    starter picker is not rebuilt — it dies with `overworld_picker.gd`, and the
    car shop becomes the first screen carrying a decision.
29. **The start line offers Tune Car only.** Upgrades has nothing to show once
    parts are gone and boosts are picked between stages; tuning survives
    (decision 24) and is per-stage useful.
30. **Global stage leaderboards are dropped.** The between-stage screen is the
    boost pick alone. See the Economy/leaderboards note for what that deletes.
31. **Money payout scales with region index.** The same region index that
    tightens `target_pace` (decision 22) also raises the reward, so grinding an
    early region is strictly worse per unit time than progressing. This is what
    stops "farm region 1 forever" without taking the grind valve away.
32. **Minimum stage pool: 16 events per region** — two runs with no repeats.
    `home` (36), `greece` (24) and `snow` (18) already pass; `taiga` (15) is one
    event short; `home_coast` (12) and `greece_coast` (3) need real authoring.
    So this is a content pass across three regions, not a `greece_coast` one-off.
    Supersedes decision 10's "8-stage pool" wording.
33. **A doomed run is driven out.** No retire option and no unwinnable-run
    warning: missing the timer ends the run anyway, so the worst case is one
    stage of known-lost driving.
34. **The old `_migrate_step` chain (schemas 1–5) is deleted** along with the
    legacy backfill keys. No migration is written for the pivot, so a pre-pivot
    profile resets whatever its version.
35. **Coins are placed OFF the racing line**, as a real gamble against the clock
    rather than a reward for a good line. They must be **signposted far enough
    ahead to commit or decline** — an unseen coin on a procedurally-drawn stage
    is a memory test, not a decision. The existing pacenote strip
    (`hud_pacenotes_enabled`, `features/hud.md`) is the natural place to flag one.
36. **Coin money banks at stage clear**, not at run end. This follows from
    decision 14 (a failed run keeps its money) rather than being a separate
    choice: with off-line placement the detour already risks the run, and losing
    the coins too would punish the same gamble twice.
38. **Test triage: delete dead, fix incidental.** Tests whose subject is deleted
    (rally, rival, parts, map, HQ) go. The physics, car, drivetrain, terrain and
    track-gen tests stay — most touch `RallyLibrary` only incidentally through
    fixtures — and those couplings are fixed rather than deleted. Stages 3–8
    bring their own tests per `CLAUDE.md`.
39. **`restriction` is deleted.** Decision 22 answers region difficulty with
    `target_pace`, so nothing needs the categorical car filter. Recoverable from
    git if the car shop ever needs to be about more than speed.
40. **`features/` gets a full audit in stage 9** — all 76 docs walked, each fixed
    or deleted, per `CLAUDE.md`'s self-correcting index rule. Not just the ~16
    the pivot obviously invalidates.
41. **The dead small-model eval tasks are re-authored in stage 9** against the
    new systems, so the suite keeps measuring a real codebase and
    `/small-model-readiness` and `/small-model-readiness-drill` keep working.
42. **The boost shop shows the effect range per level** — "engine boosts now roll
    +8–15%" rather than a bare level number — so the purchase is legible without
    a live car to compute against.
43. **No first-clear bounty.** Decision 31's region payout scaling already makes
    progressing pay better; a second progression reward is one more number to
    balance for no new information.
44. **The three obsolete `todo/` specs are deleted outright** in stage 2:
    `star-economy.md`, `menus.md`, `star-gated-special-events.md`.
45. **No endgame, for now.** Clearing the last region leaves every region
    unlocked and repeatable; there is no credits roll, ascension mode or
    difficulty ladder. Accepted deliberately — one demolition consequence, in
    Hazards: the credits trigger dies with specials and must be removed, not left
    dangling on a predicate that can never be true.

46. **`greece_coast` gets more authored events** rather than a repeat-refilled bag.
    It has 3; a single 8-stage run needs 8, and the spec's no-repeat-across-two-runs
    floor wants 16. The `RegionStagePool` refill that currently covers a short pool
    is a STOPGAP and must never fire once stage 4's authoring lands. Do not "solve"
    a short pool by shortening the run — 8 stages is the run's identity.
47. **`test_menu_flow.gd` is salvaged, not deleted.** 5884 lines, 146 parse errors,
    all from driving the deleted `HqController` — but it holds the only coverage of
    start-line preflight, wheel swap and cloud boot gating. Read it, re-point the
    assertions whose subject survives at the flat shell once that exists, delete the
    rest. Its own stage, after the shell.
48. **Discarding a paused challenge run BURNS the attempt, behind a hard confirm.**
    Decision 27's one-slot rule otherwise hands out a free retry: discarding writes
    no `challenge_results` outcome, so the player can restart the same period from
    stage 1 and reroll until they like their start. The confirm must say plainly
    that quitting costs the attempt — the rule is fine, a silent surprise is not.
49. **`CLAUDE.md`'s stale game description is corrected** (it called `gameplay.md`
    "Gran Turismo, but with rally stages" and cited a "final showdown"). Every agent
    reads that file. `README.md` is deliberately NOT changed yet, and `main` stays
    parked until the loop is playable end to end.

## The new loop, end to end

```
title
  └─ hub / main menu (Run, Cars, Shop, Perks, Stats, Settings) — the screen every
  │    run starts and ends at; a NEW player is sent to the car shop first, since
  │    that is the first screen carrying a decision (decision 28)
  └─ Run ─ region select (linear unlock; locked regions greyed, with their gate)
       └─ car select (owned cars; buy new ones with money — RR-style shop)
            └─ RUN START (stage 1 of 8)
                 ├─ stage: drive a drawn event against a target time
                 │    ├─ beat the timer → stage cleared, money paid out
                 │    └─ miss the timer → RUN OVER
                 ├─ between-stage pick: repair, or 1 of N random boosts
                 └─ …repeat to stage 8
                      └─ region cleared → next region unlocked
  └─ (on run end, win or lose) back to the hub:
       money, owned cars, perks, boost levels and lifetime stats all persist
```

**Soft permadeath, exactly as RR.** A failed run destroys the run: stage
progress, every temporary boost picked during it, and the car's accrued damage.
It does **not** touch money, owned cars, purchased perks, purchased boost levels,
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
stage-loop/persist/repair logic. This approach absorbs the prior challenge/career
reuse drift spec; its remaining work is folded into this plan below.

### Absorbed: challenge/career reuse drift

The prior `/refactor-after-bugfix` spec (2026-07-31, all 13 sections implemented)
tracked drift between `ChallengeSession` and `RallySession`. `features/rally-challenge.md`
and `features/cloud-save.md` are the living docs. Two items remain.

**1. Retire the `ChallengeSession.abandon()` alias** — a deprecated alias for
`pause_run()`, kept only so five test teardowns compile. With the DNF path
removed and pause as the only non-completion exit, the alias is a pure duplicate
with no distinct behaviour. This item **is subsumed** by the `RunSession`
extraction above: renaming `ChallengeSession` to `RunSession` and generalising it
to cover both challenge and region runs is where the alias dies. Migrate these
five test files from `abandon()` to `pause_run()` as part of the extraction:
`tests/headless/test_start_line.gd`, `tests/headless/test_menu_flow.gd` (also
has a comment referring to `abandon()`), `tests/headless/test_challenge_run_end.gd`,
`tests/headless/test_rally_session.gd`, `tests/headless/test_upgrade_reveal.gd`.

**Note:** `RallySession.abandon()` is a different method — career only, called
from the Pause overlay to end a rally incomplete — and is unaffected by this
extraction. It dies with `RallySession` itself, not with the alias.

**2. A synthetic period-key seam for tests,** so a challenge period can be forced
rather than depending on the real clock. This item **is NOT mooted** by the pivot:
the Daily/Weekly/Monthly challenge is explicitly retained (decision 15), so this
stays live work and must survive the fold as a real outstanding item.

**3. Seventeen code comments cite this now-deleted spec by item number** (e.g.
`todo/challenge-career-reuse-drift.md item 9`) across `world.gd`,
`challenge_session.gd`, `cloud/cloud_busy.gd`, `cloud/conflict_prompt.gd`,
`confirm_popup.gd`, `rally_session.gd`, `global_standings.gd`, `standings.gd`
and six `tests/headless/` files. Four of those files are themselves deleted by
this pivot (`rally_session.gd`, `global_standings.gd`, `standings.gd`, and the
challenge-session comment moves with the `RunSession` rewrite), so do NOT sweep
them now — stage 2 churns most of them anyway. The survivors get repointed at
this section during the stage 9 `features/` audit, which is already a
pointer-fixing wave. Tracked here so the reference rot is not discovered by
accident later.

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
  sequence. **Not** the array order: `REGIONS`'s own header says "ORDER CARRIES
  NO MEANING … do NOT re-introduce any ordering dependency", and
  `override_for_test()` lets tests pass arbitrary arrays. That comment and
  `features/regions.md` are rewritten in the same change;
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
- **The floor is 16 events per region** (decision 32) — two runs with no
  repeats. Against that bar: `home` (36), `greece` (24) and `snow` (18) pass;
  `taiga` (15) is one event short; `home_coast` (12) and `greece_coast` (3) need
  real authoring. So this is a content pass across three regions, not a
  `greece_coast` one-off, and it gates those regions being playable at all.

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
directly. Deliberately NOT adopted for the pivot — noted only as a known lever
if impacts read as too forgiving in play, since it converts
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
perk *purchasable*; buying it is a separate money cost; at most
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
cleared, total runs started/failed, total damage taken, total money earned/spent,
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

The paid garage repair (`Save.repair_car`, `Save.repair_price`) is **retired**:
between runs the car resets anyway, so it has no place left. Listed in *What gets
deleted*. (Stated as a decision rather than a recommendation so the "no open
questions" claim above stays honest.)

### Car acquisition — RR's shop

Today TAPPA has **no car shop at all**: cars are won outright at prize rallies
(`RallyLibrary.prize_car_id`, `features/prize-rallies.md`,
`RewardSystem.draw_car`), and the old star currency only bought repairs and parts. RR is the
opposite — a flat currency shop (`CAR_LIST`, each `CarDefinition` with a fixed
`cost`, purchase recorded in persisted `boughtCars`).

Following RR, as decided and re-confirmed: `CarLibrary.CARS` gains a money `cost`
per car, the car select screen offers a Buy action for unowned cars, and
ownership persists in the existing `profile["cars"]` structure. This retires
prize rallies and `RewardSystem.draw_car` along with the rallies that advertised
them.

Worth keeping in view as a design loss: prize rallies were a more interesting
acquisition hook than a price list, and with car acquisition now purely
transactional, **clearing a region rewards only the next region's unlock**. Decision 43 rejects a first-clear bounty, so this ships without one. Recorded
here only as the contingency lever: **if** region clears prove unrewarding in
play, revisiting 43 for a one-off money bounty is cheaper than reintroducing
reveal-gating. That is a post-playtest question, not an open design question.

### Salvaged from `hq_challenge.gd` — what the flat rebuild MUST reproduce

The Rally Challenge screen died with the hub (its file is deleted; this section is
the only record). Decision 15 RETAINS the challenge, so stage 4 rebuilds this flat.
Most business logic already lives in the surviving `challenge_session.gd` /
`challenge_library.gd` autoloads — `has_stale_run`, `discard_stale_run`,
`resumable_run`, `classify_cars`, `start`, `resume`, `period_outcome`,
`displayed_ceiling`, `CHALLENGE_TOP_FRACTION`. But the deleted screen held real
orchestration with no other home:

- **A generation-guarded async board fetch.** Both the completed-run placing and
  the win-condition cut-line come from `Cloud.challenge_leaderboard`
  asynchronously, and a generation counter discarded stale in-flight answers when
  the screen rebuilt mid-fetch. This is correctness logic, not decoration — a flat
  rebuild that just awaits the fetch will show one period's placing on another
  period's tab.
- **Per-visit-only caching**, cleared on close: cheap kind-tab switching within one
  visit, never stale across visits.
- **Signed-out short-circuit** before firing either board query.
- **Entry/start sequencing.** Pressing Start spends nothing; the attempt is spent
  at the later `_begin_challenge_start` point. The original cites a regression test
  for this ordering — preserve it.
- **The car picker.** Challenge car selection rode the 3D car park
  (`CarparkMode.CHALLENGE` on `hq_carpark.gd`). This is the ONE place challenge
  logic depended on hub-only code, and the flat rebuild needs its own
  challenge-eligible picker.

From `hq_tuning_lift.gd` (tuning survives, decision 24), one behavioural rule worth
keeping: the car cycle order sorted by ascending `instance_id` — acquisition order —
because `Save.set_selected_car` promotes the selected car to the front of the array.
Everything else there was 3D lift positioning and correctly died.

Also noted: "Test Drive" called `hq.gd`'s `_launch_free_roam`, which is gone. Free
roam is deleted by decision 25 anyway, so this entry point does not come back.

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
stage, money earned and boosts taken. One screen rather than a podium-plus-defeat
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

**Stars are deleted outright and replaced by money** (decision 21). Earlier drafts
of this spec kept the star ledger and merely re-sourced it; that is no longer the
plan. The whole star surface goes: `stars_earned` / `stars_spent`,
`Save.stars_available()` / `award_stars` / `spend_stars` / `record_podium_rally`,
`RallyLibrary.stars_for_placement` and the `STARS_FOR_WIN` / `STARS_FOR_PODIUM` /
`STARS_FOR_FINISH` / `MAX_STARS_PER_RALLY` tiers, `rally_trophy.gd`,
`features/star-economy.md`, `todo/star-economy.md` and
`todo/star-gated-special-events.md`.

This is a **simplification of the demolition**, not extra work: the ledger was
one of the few career structures the plan tried to carry across, and carrying it
meant keeping a placement-shaped crediting path alive with no placements left to
credit. Deleting it removes that seam entirely.

**Money**, per RR, is a single persistent currency, never reset by a failed run
(decision 14), with no run-scoped second currency. Three sources:

1. **Per-stage payout** growing with stages cleared (RR's
   `LEVEL_WINNINGS_BASE * LEVEL_WINNINGS_MULTIPLIER^tracksCompleted`), so
   surviving deep into a run is where the money is.
2. **Fast-completion bonus** proportional to time saved against the target — the
   reason to drive well rather than merely clear the timer.
3. **Coins** picked up mid-stage, boosting what the stage pays.

Sinks: cars, boost levels, perks, the engine-swap unlock (decision 17) and
cosmetic wheels (decision 25). Five sinks against three sources, versus today's
one source and two sinks.

**One knock-on to re-point:** `ChallengeSession.try_grant_completion_reward`
currently pays out through `RallyLibrary.stars_for_placement`. The challenge
survives (decision 15), so its reward must be re-pointed at money in the same
change that deletes the star tiers.

**Dropping the global stage leaderboards** (decision 30) deletes
`scripts/cloud/leaderboard.gd`, `scripts/global_standings.gd`, the world-readable
`stage_times/{stage}/times/{uid}` rules in `firestore.rules`, and
`tests/headless/test_cloud_leaderboard.gd`. It also makes
**`RallyLibrary.stage_key` and `TrackCache.BOARD_EPOCH` dead** — `stage_key` has
no other consumer — which retires an earlier Blocker outright: there is no longer
a question about how to derive a stage key once rallies are flattened, and no
epoch to bump.

Two things survive it. `scripts/cloud/firestore_board.gd` stays, because it is
the shared base for the **challenge** leaderboard
(`challenge_leaderboard.gd`, `challenge_runs/{period_key}/entries`), which comes
along with the challenge itself (decision 15) — decision 30 is read as dropping
the *stage* boards, not the challenge's. And `username_popup.gd` still owns
`profile["username"]`, which the challenge board needs.

**Collectables are genuinely new work** — there is no pickup or trigger-volume
system in the codebase today. It needs a prop mesh, placement along the generated
track, a pickup trigger, a HUD counter and audio. The nearest existing patterns
to model placement on are the scatter fields (`bush_field.gd`,
`billboard_field.gd`, `TreeMeshField`) and the trackside props in
`rally_flag.gd`.

**Coins sit off the racing line** (decision 35), so taking one is a real gamble:
money comes mostly from finishing fast, and a detour that costs the run costs
every remaining stage's payout. Two things follow that the implementation has to
respect:

- **Signposting is not optional.** Stages are drawn from a pool the player may
  never have driven, so a coin they cannot see coming is not a decision. Flag it
  on the pacenote strip, place it in clear sight, or both.
- **Late stages will price coins out, by design.** `target_pace` tightens with
  both stage index and region index (decisions 11 and 22), so a detour that is
  affordable on stage 2 of region 1 may be untakeable on stage 8 of region 5.
  That is a reasonable emergent curve — the gamble gets steeper as the run gets
  deeper — but it does mean late-run coins are close to decorative unless
  placement gets easier as the clock gets harder.

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

The demolition list. Stage 2 executes this; it is kept here rather than inline so
the stage stays readable.

**Retained first — extract before deleting** (see Hazards):
`RallySession.apply_event_config` / `canonical_event_config` /
`apply_field_repair_to`, `RallyLibrary.build_standings` (empty-field form), and
`UpgradeLibrary.EFFECTS` / `_cfg_set` / `apply`. These have live non-career
callers and must move to their new home before the surrounding code goes.

**Deleted:**

- **The rival field and everything serving it** — `RallyLibrary.generate_opponent_field`,
  `_eligible_combos`, `_draw_distinct_combos`, `_residual_pace_trim`, `swap_weight`,
  `rating_match_weight`, `placement`, `is_top3`, `event_wreck`, `RIVAL_NAMES`, the
  `PACE_*` consts, `scripts/rival_pace.gd`, the rival ghost, opponent wrecks, and
  adaptive difficulty (`scripts/ai_difficulty.gd`).
- **The star economy** (decision 21) — `stars_earned` / `stars_spent`,
  `Save.stars_available` / `award_stars` / `spend_stars` / `record_podium_rally`,
  `stars_for_placement` and the `STARS_FOR_*` tiers, `rally_trophy.gd`.
- **The overworld map** — `hq_map_table.gd`, `hq_table.gd`, `rally_detail.gd`, the
  reveal geometry (`rally_revealed`, `lit_sources`, `reveal_link_pairs`,
  `suggest_map_pos`, …), `map_fog.gd`, `textures/map_world.jpg`.
- **The diegetic 3D hub** (decision 9) — `hq.tscn`, the bulk of `hq.gd` (3563
  lines), `hq_environment.gd`, `hq_tuning_lift.gd`, `hq_present_reveal.gd`,
  `scripts/map_table.gd`, every `GameConfig.hq_*` camera pose, the `LoadingScreen`
  cover in `_ready`.
- **`WorldPanel`** — `world_panel.gd`, `world_panel_host.gd`, the
  `world_space_menus` flag.
- **The overworld hub** — `overworld.tscn`, `overworld_region.gd`,
  `overworld_picker.gd`, `GameConfig.overworld_enabled`, `Scenes.hub_path()`'s
  branch.
- **The persistent parts model** — the `UpgradeLibrary` catalogue, `SLOTS`,
  install/buy paths, `Save.install_upgrade` / `set_upgrade_enabled` / `buy_part`,
  `auto_build_plan`, `upgrade_options.gd`, `upgrades_grid.gd`.
- **Prize rallies and reward draws** — `RewardSystem.draw_car`, `prize_car_id`,
  `prize_part_id`, `prize_capability_id`, `has_prize`.
- **`RallySession`**, once its retained statics have moved.
- **Global stage leaderboards** (decision 30) — `cloud/leaderboard.gd`,
  `global_standings.gd`, the `stage_times` Firestore rules, `RallyLibrary.stage_key`,
  `TrackCache.BOARD_EPOCH`.
- **Free roam** (decision 25) — `_prepare_free_roam`, the `free_roam_*` GameConfig
  block, `RallySession`'s handoff state.
- **The paid garage repair** — `Save.repair_car`, `Save.repair_price` and their
  callers. Between-run resets leave it nothing to do; the between-stage repair
  pick replaces it.
- **The `RALLIES` table's non-event fields** — `restriction` (decision 39),
  `map_pos`, `special`, `prize_*`, `unlocked_by_rally`. The `events` arrays survive
  and become the stage pool.
- **`podium.tscn`** and `scripts/podium.gd` (decision 19), **`standings.tscn`**
  (decision 30).
- **The migration chain** (decision 34) — `_migrate_step`, `_MIGRATABLE_FROM`,
  `KEY_LEGACY_PART_UNLOCKS`, `KEY_LEGACY_ENGINE_SWAP`, `MOVED_PART_UNLOCKS`.
- **Three obsolete `todo/` specs** (decision 44) — `star-economy.md`, `menus.md`,
  `star-gated-special-events.md`.
- **Already done:** the multiplayer lobby (decision 16).

**Explicitly retained:** the Daily/Weekly/Monthly challenge (15), engine swap
re-gated as a purchase (17), tuning ungated (24), wheel customisation (25), the
challenge's own cloud leaderboard and `firestore_board.gd`, and the start line
(29 — its MENU survives, its rival REVEAL phase does not).

## Staging

**Demolish first, then rebuild on clean ground** (decision 20). Deleting first
means every later stage writes against a small codebase instead of threading
around a career on its way out.

**The cost, stated plainly: the game does not run between stages 2 and 3.** That
window is the whole risk, so stage 3 is scoped to the minimum that gets back to
playable — not the minimum that is fun. The challenge mode also breaks during
demolition and returns with `RunSession` in stage 3.

1. **Decide and document.** Rewrite `gameplay.md` to the roguelike vision.
   Absorb the challenge/career reuse drift spec into this plan (done: see
   "Absorbed: challenge/career reuse drift" above). No code.
2. **Demolition.** One commit, so the revert is clean. Execute *What gets
   deleted* above — extractions first. Update `project.godot` (main scene,
   autoloads) and `Scenes.is_hub_scene`. Reset the save schema, no migration.
   Resolve the coupled systems named in *Hazards*. Triage tests per decision 38.
   **The tree compiles; the game does not run.**
3. **Back to playable — the minimum spine.** `RunSession` generalised from
   `ChallengeSession`; a bare flat shell (title → car select → run); the region
   stage draw; the fixed reference-car timer; run-over on a missed target; a plain
   run-summary screen. The challenge returns as `RunSession`'s second caller.
4. **Region select + linear unlock**, replacing the map table. Includes the
   **stage-pool authoring pass** to decision 32's 16-event floor — `greece_coast`
   (3), `home_coast` (12) and `taiga` (15) need events written before those
   regions are playable.
5. **In-run boosts + repair pick** between stages, wiped on run end.
6. **Meta shop** — boost levels, car purchasing, the engine-swap unlock.
7. **Lifetime stats, then perks** (perks depend on stats).
8. **Collectables** (13, 35, 36) — prop, off-line placement, pacenote
   signposting, pickup trigger, HUD counter, audio, banking at stage clear. Last
   of the features: the only wholly new runtime system in the pivot.
9. **Polish and docs.** Flesh out the shell beyond stage 3's spine; a **full audit
   of all 76 `features/` docs** (40); the dead small-model eval tasks
   **re-authored** (41); one full `./run_tests.sh` against the ~5 minute budget.

Dependencies: everything depends on 2; 4–8 render on the shell from 3; 7's perks
depend on 7's stats; 8 depends on 3. Nothing depends on a save migration, because
there isn't one.

## Hazards

Verified against the code. These are things that will break the demolition or
silently change behaviour if not handled — not open questions.

### `RallySession` cannot be deleted wholesale

`ChallengeSession` — which survives — calls into it right now:

| Call site | What it needs |
| --- | --- |
| `RallySession.apply_field_repair_to()` | the `_pending_repair` between-stage repair the boost-pick screen reuses |
| `RallySession.clear_free_roam_handoff()` | the free-roam supersede rule (moot once free roam goes, but the call must be removed) |
| `RallyLibrary.build_standings()` ×2 | its own standings, empty rival array — **delete rather than extract**: its consumers feed `standings.tscn`, which decision 30 deletes. Rewrite the two callers to return plain time lists for the run summary |
| `RallyLibrary.stars_for_placement()` | its completion reward — re-point at money (decision 21) |

`RallySession` is also a **`project.godot` autoload**, and its statics
`apply_event_config` / `canonical_event_config` are the shared stage-config spine
used by `driving_context.gd`, `track_cache.gd`, `region_library.gd`,
`challenge_library.gd` and `benchmark_mode.gd`. ~34 scripts reference it. Extract
the survivors *before* deleting — `todo/roguelike-pivot-plan.md` §2a names their
homes (`scripts/stage_config.gd` for the event-config statics, `Save` for the
field repair).

### Deleting `hq.tscn` leaves the project unbootable

`project.godot` line 15 is `run/main_scene="res://hq.tscn"`. The autoload block
also changes (`RallySession` out, `RunSession` in). And `MusicLibrary.is_hq_scene`
→ `Scenes.is_hub_scene` picks hub-vs-rally music off the hub scene path, so the
flat shell must register there or every hub screen plays a rally song.

### Deleting the parts model changes every car's bodywork

`car.gd` calls `_set_aero_visible(_active_body(),
UpgradeLibrary.aero_tuning_unlocked(owned))` — the **visible rear wing** is gated
on a fitted aero part. Decision 24 makes tuning ungated, so the wing must become a
plain per-car property. `tests/headless/test_aero_visibility.gd` and
`test_aero_visible_traversal.gd` pin the current behaviour.

### The test blast radius is the dominant cost of stage 2

Of 226 test files: **49** touch `RallyLibrary`, **23** `UpgradeLibrary`, **21**
`RallySession`. Decision 38 sets the policy (delete dead, fix incidental), but the
volume is real. Stage 3's new `RunSession` and shell need new scene tests —
reach for `SceneTestHelpers.minimal_world()` and the cheap patterns in
`features/testing.md` rather than full world generation.

### Systems that will be found mid-demolition if not planned for

- **`upgrade_options.gd`** (`SLOT_ENGINE` / `SLOT_TUNE` pseudo-slots,
  `grid_slots()`) is the shared data source for the garage grid *and* the
  start-line page — and the only UI seam the surviving engine swap renders
  through. Deleting it needs a replacement seam for engine swap.
- **The start line** (`start_line.gd`, `features/start-line.md`) runs
  MENU → FLY_IN → REVEAL → FADE. REVEAL exists to show the top-three rivals and
  dies with them — but a rival-free path **already ships**: a challenge stage runs
  the identical MENU and skips to the fade via the empty-leaders branch. The
  structure survives; only the menu contents change (decision 29).
- **The credits trigger** fires from `RallyLibrary.all_specials_completed`, which
  dies with specials. Remove it rather than leaving it on a predicate that can
  never be true (decision 45's closing clause).
- **`registry.gd`, `crosswind.gd`, `weather_library.gd`, `stage_manager.gd`,
  `settings_menu.gd`** all reference `RallyLibrary` or `RallySession` and are
  in-stage runtime, not hub code.
- **`TrackCache`**: `data/track_cache.json` is a committed lockfile keyed to
  authored events. If the stage draw scales `turn_count`, every drawn stage misses
  the cache and falls back to live DFS search — bump `CACHE_VERSION` and re-bake,
  or keep `turn_count` as authored.
- **`GhostCar.pose_at_offset`** is already dead production code (its only caller
  was the deleted lobby) and goes with the rival ghost.

### Unverified

The multiplayer deletion and its follow-up cleanup were made in an environment
with **no Godot binary** — no compile check, no test run. Verify locally with
`./run_tests.sh` before starting stage 1.

## Open questions

**None.** Every question raised across three review passes is settled in
decisions 1–45. If something new surfaces during implementation, add it here
rather than deciding it silently.
