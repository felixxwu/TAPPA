# Region runs — the roguelike run spine

The game's main loop after the pivot (`todo/roguelike-pivot.md`): pick a region,
pick a car, and drive **8 stages back to back against a fixed clock**. Miss a
stage's target time and the run is over on the spot — that is the only hard fail
state in the game. Money is banked at every stage clear and never taken back.

**Tests:** `tests/headless/test_region_run.gd`, `tests/headless/test_region_stage_pool.gd`, `tests/headless/test_challenge_session.gd`

This doc owns the **run spine** — the session, its strategy seam, the stage draw,
the timer and the money. The Daily/Weekly/Monthly challenge, which is the spine's
*other* caller, is documented in [rally-challenge.md](rally-challenge.md).

**Stage 3 of the pivot ships the spine only.** Region SELECT and the linear unlock
ledger (`Save.KEY_REGIONS_CLEARED`) are stage 4; in-run boosts are stage 5; the meta
shop is stage 6; coins are stage 8. Nothing here builds those — it builds the thing
they hang off.

## The pieces

| Piece | File | What it owns |
| --- | --- | --- |
| `RunSession` | `scripts/run_session.gd` (autoload) | The stage cursor, banked stage times, the persisted run slot, the between-stage field repair, the car lock, the terminal result |
| `RunMode` | `scripts/run_mode.gd` | The **strategy seam** — the base class every kind of run implements |
| `RegionRunMode` | `scripts/region_run_mode.gd` | The region run: the stage draw, the fixed timer, the fail rule, the money |
| `ChallengeRunMode` | `scripts/challenge_run_mode.gd` | The challenge: rolled stages, no clock, one placement payout |
| `RegionStagePool` | `scripts/region_stage_pool.gd` | A region's authored event pool, and the seeded draw taken out of it |

## The strategy seam

`RunSession` is the generalisation of the old `ChallengeSession` — same stage loop,
same persistence, same repair, but the **stage list and the fail rule now come from
a `RunMode`**. A caller supplies a mode; the session never branches on which kind of
run is live.

```gdscript
# Caller one — the retained Daily/Weekly/Monthly challenge:
RunSession.start(ChallengeLibrary.DAILY, owned_car, unix_time)

# Caller two — a region run (run_seed 0 rolls one; pass a seed to reproduce a run):
RunSession.start_region("home", owned_car, run_seed)

# Either, given a mode you built yourself — the generic entry point:
RunSession.begin(RegionRunMode.for_region("home"), owned_car)
```

`RunMode` is six questions, and adding a third kind of run means answering them in a
new subclass plus one arm in `RunSession._mode_from_record` — never another branch
inside the session:

| Question | Method | Challenge | Region run |
| --- | --- | --- | --- |
| Which stages? | `stages()` / `stage_count()` | rolled from the period key | drawn from the region's authored pool |
| What must this stage be beaten in? | `stage_target_ms(i, track_result)` | `0` — no clock | reference-car optimum × `target_pace` |
| Does this time end the run? | `stage_failed(i, elapsed, target)` | never | `elapsed > target` |
| What does clearing it pay? | `stage_money(i, elapsed, target)` | `0` (paid once, at the end) | completion + fast bonus |
| What is persisted? | `to_record()` / `is_resumable(t)` | `{period_key, kind}`, stale once the period rolls | `{region_id, run_seed, stage_count}`, never stale |
| What does a finished run record? | `record_outcome(result, t)` | the period's one-attempt outcome | nothing (stage 4's `regions_cleared` ledger) |

## One run slot

`profile[Save.KEY_RUN]` (`"run"`) holds an in-progress run **of either kind** —
decision 27. Starting a region run discards a paused challenge run and vice versa;
the confirm that guards that belongs to the screen offering the start, not to the
session. The record is always

```
{mode, car_instance_id, stage_index, stage_times_ms, dnf, money_earned}
```

plus the mode's own half merged on top. `Save.is_challenge_locked(instance_id)` —
read through `DrivingContext.is_car_locked` — is the car lock over that one slot, so
it covers both kinds with no discriminator.

The key was `challenge_run` before the generalisation. Renaming it cost nothing:
`SCHEMA_VERSION` is already at 7 and every pre-pivot profile is refused rather than
migrated (decision 34).

## The stage draw

`RegionStagePool.draw(region_id, stage_count, run_seed)`.

The pool is `RallyLibrary.RALLIES` **flattened**: every rally tagged with the region
contributes its `events` array. The 3-event rally wrapper is exactly what the pivot
deletes, so a stage is one event and the pool is **counted, never multiplied by 3**
(`shakedown`, `hm_timber_trophy` and `hm_forest_gt` carry one event apiece).

Each pooled stage is a **copy** of the authored event plus three annotations:

- `region` — load-bearing, not decoration: `StageConfig.apply_event_config` resolves
  the waterline and the per-region grip / deep-snow / frozen-water overrides off it,
  so a stage that lost it would generate as the wrong corner of the world;
- `rally_id` — provenance, for debugging a drawn run;
- `difficulty` — the parent rally's authored tier, which is what the draw orders by.

Rules:

- **Seeded.** Deterministic in `(region_id, stage_count, run_seed)`, and the seed is
  persisted — so a resumed run re-derives byte-identical stages and a bug report
  carrying the seed is reproducible.
- **No repeats while the pool lasts.**
- **Easiest first,** by the parent rally's `difficulty`, with the authored seed as a
  tie-break (`Array.sort_custom` is not stable, and an unstable order would break the
  resume guarantee above). So the run escalates and stage 8 is the hardest drawn.
- **The events are never mutated.** Every authored `(seed, turn_count)` pair is
  hand-verified to route and is baked into `data/track_cache.json`; nudging
  `turn_count` or re-rolling `water_level` / `terrain_layer1_amplitude` would miss the
  lockfile and hand the player a combination no shipped content has exercised. (This
  is the same trap `ChallengeLibrary.stages_for` documents when it rolls water level
  and terrain amplitude *together*.) Escalation comes from the ordering and from the
  clock tightening — never from editing content.

### Pool sizes, and the one that cannot fill a run

Decision 32 sets the floor at **16 authored events per region** — two 8-stage runs
with no repeats. Against that bar today: `home` 36, `greece` 24, `snow` 18 pass;
`taiga` 15, `home_coast` 12 and `greece_coast` 3 do not. **Stage 4 owns that
authoring pass**, and those regions are not really playable until it lands.

Until then the draw **refills the bag** rather than returning a short run: a repeated
stage is a thin region, an 8-stage run that is only 3 stages long is a broken one.
`taiga` at 15 still fills a run without repeats — the 16 floor is about two runs, not
one — so `greece_coast` is the only region the refill actually fires for.

## The timer — the one fail state

```
target_ms = LapTimeModel.optimum_ms(track, CarPerformance.REFERENCE_CAR, event)
            * target_pace(stage_index, region_index)
```

**Fixed, not car-relative** (decision 11). The solve uses
`CarPerformance.REFERENCE_CAR` — the same reference the rating system normalises
against — so a stage's clock is a property of the *stage*, identical for every player
and every car. That is what makes the car shop matter: a faster car beats the clock
more easily instead of having the bar raised to match it.

Two consequences the design accepts on purpose: **the starter car sets the difficulty
floor** (stage 1 must be clearable in the worst car a player can own — tune against
that car), and **a late-tier car trivialises early stages**, which is the reward for
buying it.

`target_pace` is the one difficulty dial (decision 22): it tightens with the stage's
index within the run *and* with the region's index in the unlock order, so a later
region simply demands a faster time on the same kind of stage. All four knobs are
`GameConfig` (`run_target_pace_base` / `_stage_step` / `_region_step` / `_min`,
authored in `config/game_config.tres`).

> **Tune these against real driving, not against the model.** `LapTimeModel`'s
> optimum is a point-mass centreline *reference*, not a physical bound —
> `RallyLibrary.GHOST_SOLVABLE_PACE` says as much: a real driver beats it by
> straightening corners. Paces at or below 1.0 are viable but must be *felt*. The
> shipped base of `1.6` is a deliberately generous placeholder chosen so the loop is
> obviously completable while the rest of the pivot lands; it is the designer's number
> to move.

### Where the target is seated

The clock is solved over the track that was **actually generated**, and that dict
exists in exactly one place, so `world.gd` pushes it in right after generation (and
after the gradient sampler is attached, so the clock is set on the same hilly road
the player drives):

```gdscript
RunSession.set_stage_track(result)   # -> RunSession.stage_target_ms()
```

`_arch_event_info` then frames it on the start arch. A challenge stage — and a track
that failed to solve — get `0` back, which `FinishArch` renders as no time row, and
which the fail rule treats as "cannot be failed".

## Money

Banked **at stage clear** (decision 36), not at run end, so a run that dies on stage 6
keeps everything stages 1–5 paid. Soft permadeath destroys the run — stage progress,
in-run boosts, the car's accrued damage — and never the wallet (decision 14). There is
no `Save.lose_money`.

```
stage_money = (base * growth^stages_cleared + fast_bonus * fraction_of_target_saved)
              * (1 + region_step * region_index)
```

- **completion**, growing with stages cleared, so surviving deep into a run is where
  the money is;
- **fast bonus**, proportional to the time saved against the target — the reason to
  drive well rather than merely clear the clock;
- **the region scale** (decision 31), so grinding an early region pays worse per unit
  time than progressing. That is what stops "farm region 1 forever" without taking the
  repeatable-region grind valve away (decision 12).

Coins (decision 13/35) are the third source and arrive in stage 8; they bank through
this same stage-clear moment.

`Save.money()` / `add_money()` / `spend_money()` are the whole currency surface.
`RunSession.money_earned()` is the run's own running tally, for the run summary.

## Known placeholder

`RegionRunMode.region_index()` reads the region's **array index** in
`RegionLibrary.REGIONS`. That table's own header says array order carries no meaning,
and `override_for_test` lets a test substitute an arbitrary array — so this is a
stand-in that **must not outlive stage 4**, which adds the authored `order` field
decision 2 needs and re-points both the pace ramp and the money scale at it.
