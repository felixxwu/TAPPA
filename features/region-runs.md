# Region runs — the roguelike run spine

The game's main loop after the pivot (`todo/roguelike-pivot.md`): pick a region,
pick a car, and drive **8 stages back to back against a fixed clock**. Miss a
stage's target time and the run is over on the spot — that is the only hard fail
state in the game. Money is banked at every stage clear and never taken back.

**Tests:** `tests/headless/test_region_run.gd`, `tests/headless/test_region_stage_pool.gd`, `tests/headless/test_boost_library.gd`, `tests/headless/test_challenge_session.gd`

This doc owns the **run spine** — the session, its strategy seam, the stage draw,
the timer, the money and the between-stage pick. The Daily/Weekly/Monthly
challenge, which is the spine's *other* caller, is documented in
[rally-challenge.md](rally-challenge.md).

**Stage 3 shipped the spine; stage 4 (region select + linear unlock) and stage 5
(in-run boosts, this section) are landed.** The meta shop (boost LEVELS, car
purchasing, engine-swap unlock) is stage 6; lifetime stats + perks are stage 7;
coins are stage 8. Nothing here builds those — see "The meta seam" below for
exactly where stage 6 hooks in.

## The pieces

| Piece | File | What it owns |
| --- | --- | --- |
| `RunSession` | `scripts/run_session.gd` (autoload) | The stage cursor, banked stage times, the persisted run slot, the between-stage field repair, the car lock, the terminal result |
| `RunMode` | `scripts/run_mode.gd` | The **strategy seam** — the base class every kind of run implements |
| `RegionRunMode` | `scripts/region_run_mode.gd` | The region run: the stage draw, the fixed timer, the fail rule, the money |
| `ChallengeRunMode` | `scripts/challenge_run_mode.gd` | The challenge: rolled stages, no clock, one placement payout |
| `RegionStagePool` | `scripts/region_stage_pool.gd` | A region's authored event pool, and the seeded draw taken out of it |
| `BoostLibrary` | `scripts/boost_library.gd` | The in-run boost catalogue and its seeded draw |
| `RunPickPanel` | `scripts/run_pick_panel.gd` | The between-stage MenuPage modal (repair vs. boost, or a plain Continue) |

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
| What does a finished run record? | `record_outcome(result, t)` | the period's one-attempt outcome | the `regions_cleared` ledger (stage 4) |
| Does clearing a stage offer a boost pick? | `offers_boost_pick()` / `boost_choices(i)` | never — repair stays automatic | always (unless it was the run's own final/failed stage) |

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

## Between-stage pick: repair or boost

`report_event_result` used to apply the field repair **automatically** on every
non-final stage clear. Per `todo/roguelike-pivot.md` → "Upgrades — RR's two-tier
model" that is wrong on purpose: repair is meant to **compete** with a boost, so
taking it costs the boost you didn't take. `RunMode.offers_boost_pick()` is the
switch — `RegionRunMode` opts in, `ChallengeRunMode` does not, so a challenge
stage still repairs automatically exactly as before (`test_challenge_session.gd`
pins that unchanged behaviour).

When the mode opts in and the stage was **not** the run's last (and did not miss
the clock — `over` in `report_event_result`), the automatic repair is replaced
with a drawn pick:

```gdscript
_pending_pick = _mode.boost_choices(_stage_index)   # BoostLibrary entries
_pick_awaiting = true                               # continue_to_next_stage() now refuses
```

`RunSession.choose_repair()` / `.choose_boost(id)` resolve it — repair goes
through the same `Save.apply_field_repair_to` every other transition uses (so
`take_pending_repair()` / world.gd's between-stage repair popup are unchanged for
the repair case), and a boost is appended to the run's own list:

```gdscript
func boosts() -> Array   # this run's picks so far, {"id","effect"} — UpgradeLibrary's shape
```

`continue_to_next_stage()` is a no-op while `_pick_awaiting` is true — the player
must resolve the pick before the run advances (todo/roguelike-pivot.md: "the
player picks exactly one"). On the run's **final or failed** stage no pick is
drawn at all (there is no next stage to carry a boost into) and the repair applies
silently, exactly as before.

### Where boosts live, and what wipes them

**Never `Save`'s persisted car.** `RunSession._boosts` is RUN state, merged onto a
**duplicated** owned-car dict only at fielding time — `world.gd._field_car`:

```gdscript
if RunSession.is_active():
    owned = owned.duplicate(true)
    owned["boosts"] = RunSession.boosts()
$Car.apply_owned(owned)
```

so `UpgradeLibrary.active_effects` sees them (via `_field_car` → `apply_owned` →
`UpgradeLibrary.apply`) without a single byte reaching `profile["cars"]`. They
persist across a **pause/resume** of the same run (`_persist()`/`resume()` carry
`boosts` and `pick_awaiting` in the run record — a resumed run mid-pick
re-derives the *same* offer via `_mode.boost_choices(_stage_index)`, since the
draw is a pure function of `(run_seed, stage_index)`) and are wiped **the moment
the run ends, win or lose**: `_finish_locally()` clears `_boosts` in memory and
`_clear_persisted()` deletes the whole run record — including `boosts` — from
`Save`, so nothing survives into the next run (`todo/roguelike-pivot.md`, "Soft
permadeath").

### The catalogue and its draw

`BoostLibrary.CATALOGUE` (`scripts/boost_library.gd`) — six entries, each an
`effect` dict keyed by an **existing** `UpgradeLibrary.EFFECTS` row (no second
effects system): `mass_mult`, `tire_grip_mult`, `shift_time_set`,
`downforce_front`/`_rear`, and two new rows added alongside this stage —
`brake_force_mult` (`GameConfig.brake_torque`) and `drag_mult`
(`GameConfig.drag_coefficient`). RR's `engineForce` category is deliberately not
reproduced: its natural GameConfig target, `global_torque_scale`, is a hidden
global de-rate (engine.gd's own comment), not a per-car effect field, so hooking
a boost onto it would fight that knob's real job.

Every magnitude is a `GameConfig` field under `@export_group("Roguelike Run
Boosts")` (`run_boost_mass_mult`, `_grip_mult`, `_shift_time_s`, `_downforce_n`,
`_brake_mult`, `_drag_mult`, plus `run_boost_choices` for how many are drawn) —
`BoostLibrary.effect_for` re-reads them live, never bakes a value in, and no test
may pin the shipped numbers (CLAUDE.md).

`BoostLibrary.draw(seed_value, count)` picks `count` **distinct** entries with no
replacement, seeded by `RegionRunMode._boost_seed(stage_index) = run_seed +
stage_index * 104729` — the same "big prime stride" convention
`features/rally-challenge.md` documents for bumping a challenge stage's retry
seed. No sort step (unlike `RegionStagePool.draw`), so there is no sort-stability
tie-break to reason about.

### The pick screen

`RunPickPanel.open(host, pick, on_choice)` (`scripts/run_pick_panel.gd`) builds
the modal — a repair button plus one per drawn boost, or a bare "Continue" when
`pick` is empty — as a `MenuPage` wired through `MenuNav.attach`
(`tests/headless/test_run_pick_panel.gd` is the nav test CLAUDE.md requires).
It is deliberately decoupled from `world.gd`/`$Car`/the replay machinery so it
can be tested without booting a world scene at all. `world.gd._present_standings_overlay`
hosts it over the just-finished stage's cinematic replay — the same beat that
used to load the now-deleted `standings.tscn` (decision 30: no more per-stage
leaderboards) — and `_on_interstitial_choice` applies the pick, tears the modal
down, then either continues the run (`RunSession.continue_to_next_stage()`) or,
if the run just ended, emits `run_interstitial_dismissed` so `_on_run_finished`
(mode-agnostic — challenge and region both wait on it before returning to the
hub) knows the player has seen the result.

### The meta seam (stage 6 — not built here)

`BoostLibrary.effect_for` is the one place a magnitude is resolved from
`Config.data`. A purchased "boost level" (decision 42: the shop shows the effect
range per level) belongs there — nothing here reads a level; every pick rolls at
the single authored magnitude.

## Known placeholder — resolved

`RegionRunMode.region_index()` used to read the region's raw array index in
`RegionLibrary.REGIONS`; stage 4 landed the authored `order` field this section
used to call for, and `region_index()` now reads `RegionLibrary.order_of(region_id)`.
Nothing left calling for changes here.
