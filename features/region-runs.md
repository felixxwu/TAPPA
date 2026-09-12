# Region runs — the roguelike run spine

The game's main loop after the pivot (`todo/roguelike-pivot.md`): pick a region,
pick a car, and drive **8 stages back to back against a fixed clock**. Miss a
stage's target time and the run is over on the spot — that is the only hard fail
state in the game. Money is banked at every stage clear and never taken back.

**Tests:** `tests/headless/test_region_run.gd`, `tests/headless/test_region_stage_pool.gd`, `tests/headless/test_boost_library.gd`, `tests/headless/test_challenge_session.gd`, `tests/headless/test_save_manager.gd` (the meta shop: `buy_car`/`buy_boost_level`), `tests/headless/test_hub_shell.gd` (the SHOP screen + nav)

This doc owns the **run spine** — the session, its strategy seam, the stage draw,
the timer, the money and the between-stage pick. The Daily/Weekly/Monthly
challenge, which is the spine's *other* caller, is documented in
[rally-challenge.md](rally-challenge.md).

**Stages 3-6 are landed:** the spine, region select + linear unlock, in-run boosts,
and now the meta shop (boost LEVELS, car purchasing) — see
"The meta tier" below. Lifetime stats + skills (stage 7) and coins (stage 8,
[collectables.md](collectables.md)) are landed too, as is the pass that wired the skills
to real effects (decision 51) — every stage of the pivot plan is now built.

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
| What does clearing it pay? | `stage_money(i, elapsed, target, coins)` | `0` (paid once, at the end) | completion + fast bonus + coin money |
| What is persisted? | `to_record()` / `is_resumable(t)` | `{period_key, kind}`, stale once the period rolls | `{region_id, run_seed, stage_count}`, never stale |
| What does a finished run record? | `record_outcome(result, t)` | the period's one-attempt outcome | the `regions_cleared` ledger (stage 4) |
| Does clearing a stage offer a boost pick? | `offers_boost_pick()` / `boost_pool_ids(i, extras)` | never — repair stays automatic | always (unless it was the run's own final/failed stage) |

**A new run always starts the car at 100% health.** `RunSession.begin()` calls
`Save.restore_car_to_full(_car_instance_id)` alongside its other `_pending_*` resets —
a damaged car from a previous run (or from browsing the garage) never carries that
damage into a fresh one. This is the ONLY OTHER place besides `Save.grant_car` (a
brand-new car) that sets `hp` to `max_hp`; every other HP change in the game is either
`apply_damage` (impact), `heal_car` (the self-healing trickle) or a field repair —
i.e. repairs happen only via a repair pick, or a fresh run, never silently mid-run.

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

`RegionStagePool.draw(region_id, stage_count, run_seed)`. Full design record:
`todo/region-stage-slots-redesign.md` (supersedes decisions 3, 7 and 32 of
`todo/roguelike-pivot.md`). See also `features/region-stage-library.md` for the
authoring shape.

Each region authors a **fixed 8×3 grid** in `RegionStageLibrary.STAGES`: 8 stage
SLOTS (one per position in an 8-stage run, gentlest at slot 0 and hardest at slot 7),
each with exactly 3 authored CANDIDATE stages. `draw` picks **one candidate per
slot, uniformly at random, in slot order** — there is no pool, no difficulty sort,
and no "thinner than the run" case, because every slot always has exactly 3
candidates:

```gdscript
static func draw(region_id: String, stage_count: int, run_seed: int) -> Array:
    var slots := RegionStageLibrary.slots_in(region_id)   # 8 slots x 3 candidates
    var rng := RandomNumberGenerator.new()
    rng.seed = run_seed
    var out: Array = []
    for slot_index in range(mini(stage_count, slots.size())):
        var candidates: Array = slots[slot_index]
        var candidate_index := rng.randi_range(0, candidates.size() - 1)
        out.append(_stamp(candidates[candidate_index], region_id, slot_index, candidate_index))
    return out
```

Each drawn stage is a **copy** of the chosen candidate plus three stamped fields:

- `region` — load-bearing, not decoration: `StageConfig.apply_event_config` resolves
  the waterline and the per-region grip / deep-snow / frozen-water overrides off it,
  so a stage that lost it would generate as the wrong corner of the world;
- `slot` — the stage's fixed position (0-7); this IS the difficulty signal now;
- `candidate` — which of the slot's 3 seeds was drawn, for provenance/debugging (in
  place of the old `rally_id`).

Rules:

- **Seeded.** Deterministic in `(region_id, run_seed)` (a fixed `stage_count` of 8
  picks one candidate per slot), and the seed is persisted — so a resumed run
  re-derives byte-identical stages and a bug report carrying the seed is
  reproducible.
- **Escalation is authored, not computed.** Each slot's 3 candidates are hand-tuned
  for that slot's difficulty (straightness, terrain amplitude, turn count) — there is
  no runtime interpolation any more (`StageConfig.stage_scale` and the
  `stage_hilliness_scale_*`/`stage_curviness_scale_*` `GameConfig` fields are
  deleted). The clock still separately tightens by stage index
  (`RegionRunMode.target_pace`'s `run_target_pace_stage_step`) — two escalation
  signals, deliberately reinforcing rather than one computed from the other.
- **The candidates are never mutated.** Every authored `(seed, turn_count)` pair is
  hand-verified to route and is baked into `data/track_cache.json`; nudging
  `turn_count` or re-rolling `water_level` / `terrain_layer1_amplitude` would miss the
  lockfile and hand the player a combination no shipped content has exercised. (This
  is the same trap `ChallengeLibrary.stages_for` documents when it rolls water level
  and terrain amplitude *together*.)
- **The cache key no longer depends on WHERE in the run a candidate lands** — only on
  its own authored shape (seed, turn_count, straightness, terrain fingerprint, …),
  since there is no more stage-index-dependent scaling. `TrackCache.all_event_keys()`
  and `tools/generate_track_cache.gd` both walk `RegionStageLibrary.all_stages()`
  (120 stamped candidates across 5 regions, +2 flat `for_config` entries) exactly
  once each — no per-stage-position multiplier. A change to either enumeration must
  keep the other in lockstep or the lockfile's `source_hash` freshness check
  (`tools/verify_track_cache.gd`) silently passes while runs still miss the cache.

### Pool sizes — retired

The old "16 authored events per region" floor (decision 32) and the "refill the bag
when the pool is thinner than the run" stopgap no longer apply: every region
structurally has exactly 8 slots × 3 candidates = 24 stages, so there is no pool to
run thin. Adding content now means authoring a 4th candidate onto an existing slot
(or retuning an existing one), not adding rows to a flat pool.

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

**The clock is no longer just a number** ([rival-ghost.md](rival-ghost.md)):
`RegionRunMode.stage_target_profile(stage_index, track_result)` scales
`LapTimeModel.optimum_profile`'s whole distance/time curve by the SAME
`target_pace` factor `stage_target_ms` applies to the total (`stage_target_ms`
is now built ON this — its last scaled sample, in ms — so the two can never
disagree). `RunSession.set_stage_track` seats both in the same call
(`RunSession.stage_target_profile()`), and `world.gd` hands the profile to a
`RivalGhost` — a single posed `Car` driving it — for a start-line reveal and a
live "player vs rival pace" HUD delta through the run. This is NOT the deleted
rival field back (decision 5 still holds: no opponent to race position
against) — it's the same fixed clock as always, made visible instead of
silent.

## Money

Banked **at stage clear** (decision 36), not at run end, so a run that dies on stage 6
keeps everything stages 1–5 paid. Soft permadeath destroys the run — stage progress,
in-run boosts, the car's accrued damage — and never the wallet (decision 14). There is
no `Save.lose_money`.

```
stage_money = (base * growth^stages_cleared + fast_bonus * fraction_of_target_saved)
              * region_multiplier^region_index
              + coins_collected * GameConfig.coin_money
```

- **completion**, growing with stages cleared, so surviving deep into a run is where
  the money is;
- **fast bonus**, proportional to the time saved against the target — the reason to
  drive well rather than merely clear the clock;
  Two skills move the terms above rather than adding a term of their own: "Trail Blazer"
  multiplies `run_fast_bonus_money` and "Road Scholar" adds to `run_stage_money_base`,
  both through the effects funnel before this function reads them ([skills.md](skills.md));
- **the region scale** (decision 31) — `run_money_region_multiplier` (2.0) COMPOUNDED
  per region index, so each region in the unlock order pays flat-out DOUBLE the one
  before it (1x, 2x, 4x, 8x, ...). Clearing a region pays no money of its own — the
  only reward `record_outcome` grants is the next region unlocking — and that next
  region is what actually pays more, per stage, immediately. That is what stops "farm
  region 1 forever" without taking the repeatable-region grind valve away (decision 12).
  `RegionRunMode.base_stage_reward(region_id)` is the region picker's read of this same
  scale (stage 0, no bonus, no coins) — the "$X/stage" figure shown against every
  region, locked or not;
- **coins** (decisions 13/35/36, stage 8 — see [collectables.md](collectables.md)),
  added AFTER the region scale rather than inside it: a coin is worth a flat amount
  everywhere, and the region scale's job is specifically to make progressing beat
  grinding on the stage-clear reward, not on the collectable gamble sitting on top of
  it. `RegionRunMode.stage_money(stage_index, elapsed_ms, target_ms, coins_collected)`
  is where all four terms meet; `RunSession.report_event_result`'s third argument is
  what carries `coins_collected` in from `CoinField.collected_count`, and only reaches
  `stage_money` when the stage is NOT missed — a run that dies keeps its coin money
  exactly like the rest of the stage's payout (decision 36).

`Save.money()` / `add_money()` / `spend_money()` are the whole currency surface.
`RunSession.money_earned()` is the run's own running tally, for the run summary.

**A fresh profile starts with money, not zero** (decision 28) —
`GameConfig.run_starting_money` seeds `Save.KEY_MONEY` in `_default_profile()`, sized
to afford the cheapest tier of `CarLibrary.CARS` so the shop is reachable (and has
something in it) from the very first boot. See [save-persistence.md](save-persistence.md)
and *The meta tier* below for where that money goes.

## Between-stage pick: repair, or a direction and a roll

`report_event_result` used to apply the field repair **automatically** on every
non-final stage clear. Per `todo/roguelike-pivot.md` → "Upgrades — RR's two-tier
model" that is wrong on purpose: repair is meant to **compete** with an upgrade, so
taking it costs the upgrade you didn't take. `RunMode.offers_boost_pick()` is the
switch — `RegionRunMode` opts in, `ChallengeRunMode` does not, so a challenge
stage still repairs automatically exactly as before (`test_challenge_session.gd`
pins that unchanged behaviour).

**Redesigned per `todo/mid-run-upgrade-menu.md`.** The player no longer picks
straight off a small randomly-drawn list — they choose a DIRECTION (Better Handling
or More Power) and then ONE entry from that direction is rolled for them at random,
slot-machine style. Concretely: when the mode opts in and the stage was **not** the
run's last (and did not miss the clock — `over` in `report_event_result`), the
automatic repair is replaced with the WHOLE pool, not a draw:

```gdscript
var healthy := Save.car_health_fraction(_car_instance_id) >= Config.data.run_boost_healthy_threshold
_pick_offers_repair = not healthy
_pending_pick = _resolve_pick_pool()   # every catalogue id + available extras, resolved
_pick_awaiting = true                  # continue_to_next_stage() now refuses
```

`_resolve_pick_pool()` maps `_mode.boost_pool_ids(_stage_index, extra_ids)` — EVERY
`BoostLibrary.CATALOGUE` id plus whatever drivetrain/engine-swap pseudo-ids are
currently available, no draw, no seed (see *The catalogue and its pool* below) —
through `BoostLibrary.resolve_id` and stamps the engine-swap hp/hp_delta display
fields, same as before. `RunSession.pending_pick()` is still the flat list of
resolved entries; what changed is that it is now the WHOLE pool rather than a
random `run_boost_choices`-sized subset (that field is retired — there is no draw
left for it to size).

**The undamaged-arrival reward.** If the run's own car is at or above
`GameConfig.run_boost_healthy_threshold` (a fraction of `max_hp`; resolved via
`Save.car_health_fraction`, which reads `hp`/`max_hp` the same way
`heal_car`/`apply_field_repair_to` do) at the moment the pick is drawn, the repair
option disappears from the top-level choice entirely — arriving undamaged means every
roll lands on a real upgrade instead of the usual repair-or-upgrade choice. Below the
threshold, repair is offered as the first of two top-level cards, same as always.

The answer is resolved **once**, at draw time, and persisted verbatim
(`RunSession._pick_offers_repair`, written into `_persist()`'s `pick_offers_repair`
key) rather than re-derived on resume — the car's HP can move between the draw and a
resume (self-healing, damage), and the pick must keep offering the same choice it
originally offered. `RunSession.offer_repair()` is the read: world.gd uses it to
decide whether to open `RunPickPanel.open_repair_or_upgrade` first or skip straight
to `RunPickPanel.open_category_choice` (see *The pick screens* below).

`RunSession.choose_repair()` / `.choose_boost(id)` resolve it — repair goes
through `Save.apply_full_field_repair_to`, a FULL repair (100% of lost HP, every
wheel fully straightened) rather than the fractional `apply_field_repair_to` every
other (automatic) transition uses, since the player gave up a boost specifically to
fix the car (`take_pending_repair()` / world.gd's between-stage repair popup are
otherwise unchanged for the repair case), and a boost is appended to the run's own
list. `choose_repair()` **refuses** (a no-op, same style as its existing "no pick
outstanding" guard) when `_pick_offers_repair` is false — repair must not be
reachable on the reward pick even if something bypasses the UI's hidden button.

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
    owned["boosts"] = RunSession.boosts() + SkillLibrary.equipped_effects(Save.profile)
    owned["drivetrain_override"] = RunSession.drivetrain_override()
$Car.apply_owned(owned)
```

**The drivetrain conversion rides the same duplicated dict** (see *Drivetrain
conversion* below) — same lifetime as a boost, written onto the same throwaway copy so
neither ever reaches `profile["cars"]`.

**Equipped skills ride the same list** (decision 51 — "do not build a parallel modifier
path"; see [skills.md](skills.md)). The two differ in LIFETIME, not mechanism: a boost is
run-scoped and wiped when the run ends, while a skill is a permanent profile purchase, so
skills are re-derived from the profile on every stage boot rather than carried on the run
object. Both land on the same duplicated dict, which is what keeps either of them out of
the saved profile.

so `UpgradeLibrary.active_effects` sees them (via `_field_car` → `apply_owned` →
`UpgradeLibrary.apply`) without a single byte reaching `profile["cars"]`. They
persist across a **pause/resume** of the same run (`_persist()`/`resume()` carry
`boosts`, `pick_awaiting` and `pick_offers_repair` in the run record — a resumed run
mid-pick re-derives the *same* offer via `_resolve_pick_pool()`, which is a pure
function of `(the drivetrain pool, the engine-swap pool)` and nothing else — no seed to
carry, since it's the whole catalogue every time — and both extra-id pools re-derive
identically because they depend only on the car's own current drivetrain/engine state,
unchanged by a pause) and are wiped **the moment
the run ends, win or lose**: `_finish_locally()` clears `_boosts` in memory and
`_clear_persisted()` deletes the whole run record — including `boosts` — from
`Save`, so nothing survives into the next run (`todo/roguelike-pivot.md`, "Soft
permadeath").

**The category-and-roll step itself is NOT persisted.** Once the pool is drawn,
nothing is committed until the player presses Next on the roll screen
(`RunSession.choose_boost`/`choose_drivetrain`/`choose_engine_swap` haven't run yet) —
so an app restart mid-roll (category chosen, item revealed, Next not yet pressed)
simply re-opens the pick from the top against the same re-derived pool, exactly like
a cancelled `_confirm_pick` already did before this redesign. See
`todo/mid-run-upgrade-menu.md` for the full reasoning.

### The catalogue and its pool

`BoostLibrary.CATALOGUE` (`scripts/boost_library.gd`) — eight entries, each an
`effect` dict keyed by an **existing** `UpgradeLibrary.EFFECTS` row (no second
effects system): `mass_mult`, `tire_grip_mult`, `shift_time_set`,
`downforce_front`/`_rear`, `brake_force_mult` (`GameConfig.brake_torque`),
`drag_mult` (`GameConfig.drag_coefficient`), and the two forced-induction entries
`install_turbo`/`install_supercharger` (the SAME permanent-part EFFECTS rows
[forced-induction.md](forced-induction.md) documents, now also reachable as an
in-run boost — see *Turbo and supercharger as boosts* below). The catalogue's other
POWER pick — the Engine Swap — is **not** in this table; see *The engine swap* below
and [engine-swap.md](engine-swap.md) for why it's a genuine `EngineLibrary` swap, not
an EFFECTS multiplier.

**Each entry carries a `category`** — `"power"` or `"handling"` — read by
`BoostLibrary.category_of(id)`, which also classifies the two pseudo-id families
(`"drivetrain:"` → handling, `"engine_swap:"` → power). Power: `gearbox`, `turbo`,
`supercharger`, the engine swap. Handling: `lightweight`, `grip`, `aero`, `brakes`,
`streamline`, the AWD conversion. This is what the category-choice screen (below)
offers as "Better Handling" / "More Power".

Every magnitude is a `GameConfig` field under `@export_group("Roguelike Run
Boosts")` (`run_boost_mass_mult`, `_grip_mult`, `_shift_time_s`, `_downforce_n`,
`_brake_mult`, `_drag_mult`, `_turbo_boost_gain`/`_omega_ref`/`_inertia`/
`_parasitic_friction`, `_supercharger_boost_gain`/`_rpm_ref`/`_parasitic_coef`, plus
`run_boost_healthy_threshold` for the undamaged-arrival reward's health cutoff, see
above) — `BoostLibrary.effect_for` re-reads them live, never bakes a value in, and no
test may pin the shipped numbers (CLAUDE.md).

**A non-stacking id already picked this run is excluded from later pools.**
`RunSession._resolve_pick_pool()` drops any id already in `_boosts` for which
`BoostLibrary.stacks(id)` is false — an entry whose EFFECTS row `op` is `"set"` or
`"install_induction"` overwrites the exact same value every time it's applied, so a
repeat is a dead roll, not a stronger one (`"gearbox"`, `"turbo"`, `"supercharger"`).
A `"mult"`/`"add"` entry (`"grip"`, `"lightweight"`, `"aero"`, `"brakes"`,
`"streamline"`) genuinely compounds — `apply()` walks the whole `boosts` list onto the
same freshly-reseeded baseline every stage — so those stay in the pool and can be
picked repeatedly. Drivetrain/engine-swap pseudo-ids need no such filtering: their own
availability check already drops them once a repeat would be redundant (already AWD;
already running the next engine up).

**There is no draw or seed any more.** `RunMode.boost_pool_ids(stage_index, extra_ids)`
returns the WHOLE pool — `BoostLibrary.CATALOGUE.keys() + extra_ids` (the AWD
conversion pseudo-id and/or the engine-swap pseudo-id) — with nothing narrowed and
nothing randomised: the player picks a direction themselves, so every entry has to be
offered up front rather than pre-narrowed to a small drawn sample that could leave a
whole category empty (`todo/mid-run-upgrade-menu.md`). `BoostLibrary.resolve_id(id)`
is the single place a pool id resolves to its display/apply shape: `{"id","effect"}`
for a catalogue id, `{"id","drivetrain_mode"}` for `"drivetrain:<mode>"`,
`{"id","engine_id"}` for `"engine_swap:<id>"`. `BoostLibrary.draw`/`draw_from_ids` (a
seeded, distinct, no-replacement draw over an arbitrary id list) still exist as
tested primitives but no production code calls them any more — the meta shop's
boost-LEVEL scaling (below) is the only thing that still varies per-boost.

### Turbo and supercharger as boosts

`"turbo"`/`"supercharger"` are the first `BoostLibrary` entries whose
`effect_fields` value is a DICTIONARY rather than a plain cfg-field string — because
their EFFECTS row (`install_induction`) writes SEVERAL engine fields at once (spool
inertia, saturation point, parasitic drag, boost gain), not one scalar. Each entry
names which of its sub-fields the purchased level actually SCALES
(`scaled_subfields`, just the boost-gain field — the part's real strength) versus
which are FIXED characteristics of the part that never scale (spool inertia,
omega_ref/rpm_ref, parasitic friction/drag — the part's "personality").
`BoostLibrary.magnitude_for` resolves a dict-shaped entry to a sub-dict (scaled
fields multiplied by `level_scale`, fixed fields passed through as-is) — exactly the
shape `UpgradeLibrary.apply()`'s `install_induction` arm already expects, so no
change was needed on that side of the funnel. `current_effect_text` shows these as a
signed percentage of the boost-gain field plus the entry's `display_suffix` (e.g.
"+45% torque at full boost") — its own third shape, alongside the existing
mult-as-percentage and add/set-as-absolute-figure branches.

**Turbo and supercharger STACK with each other — rolling both across a run genuinely
combines them (a twincharger), on purpose.** They used to be mutually exclusive under
the old permanent-part shop (fitting one cleared the other), but that exclusivity was a
purchase-slot rule, never a physics one — `EngineSim.step()` already multiplied the two
factors together unconditionally. `UpgradeLibrary.EFFECTS`'s `install_turbo`/
`install_supercharger` rows no longer clear anything, and `effective_meta` tracks each
axis's gain independently and combines them multiplicatively — see
[forced-induction.md](forced-induction.md) → "Turbo and supercharger STACK". This is
exactly what `BoostLibrary.stacks()` (above) means by "stacks": a repeat roll of the
SAME part is still a dead pick (its own `op` is `install_induction`, which overwrites
rather than compounds), but rolling the *other* forced-induction part is never
punished — the player who already has a turbo keeps it if a later roll lands on
supercharger instead.

### The pick screens

Four steps now, each a card list (`scripts/run_pick_panel.gd`), chained by
`world.gd`'s `_open_pick_panel` → `_on_repair_or_upgrade` → `_open_category_panel` →
`_open_roll_panel`:

1. **`RunPickPanel.open_continue(host, on_choice)`** — no pick to offer at all (a
   challenge stage, or this run's own final/failed stage): a single "Continue" card.
2. **`RunPickPanel.open_repair_or_upgrade(host, on_choice)`** — "Repair the car" /
   "Upgrade car", only shown when `RunSession.offer_repair()` is true; the
   undamaged-arrival reward skips straight to step 3.
3. **`RunPickPanel.open_category_choice(host, pick, on_choice)`** — "Better
   Handling" / "More Power", each disabled when that category has nothing to roll in
   `pick` (`BoostLibrary.category_of`) — same "locked rows stay visible, disabled"
   convention as everywhere else.
4. **`RunPickPanel.open_roll(host, pick, category, on_done)`** — the slot-machine
   reveal: a `CardCarousel` of every `pick` entry in the chosen category (a boost
   card showing its purchased level 1-based as `"Lv %d" % (Save.boost_level(id) +
   1)` — the same convention `hub_shell.gd`'s shop cards use — a `"drivetrain:"` "Convert
   to X" card, or an `"engine_swap:"` card titled `"<hp>HP <layout>"` with subtitle
   `"+<hp_delta> HP"`), a winner drawn with plain unseeded `randi()` (see *the
   category-and-roll step is NOT persisted*, above), and a scripted spin
   (`Config.data.upgrade_roll_spin_ticks` ticks over
   `upgrade_roll_spin_duration_s`, `@export_group("Roguelike Upgrade Roll")`) that
   lands on it. The carousel is DECORATIVE ONLY (`focus_mode`/`mouse_filter` turned
   off) — the only interactive control is a **Next** button, disabled until the spin
   lands, which reports the winner's id. No `on_back`: once a category is chosen the
   roll cannot be cancelled — "the user has no choice"
   (`todo/mid-run-upgrade-menu.md`).

Every step is wired through `MenuNav.attach` (`tests/headless/test_run_pick_panel.gd`
is the nav test CLAUDE.md requires). Each is deliberately decoupled from
`world.gd`/`$Car`/the replay machinery so it can be tested without booting a world
scene at all. `world.gd._present_standings_overlay` hosts the chain over the
just-finished stage's cinematic replay — the same beat that used to load the
now-deleted `standings.tscn` (decision 30: no more per-stage leaderboards). Every
page's backdrop is deliberately transparent (`"alpha": 0.0` in the `open_modal`
opts) so the 3D world shows through the gaps between cards — each card keeps its own
opaque background (`card_carousel.gd`'s `_card_stylebox`), so legibility is
unaffected.

### Seven screens now, not one

Picking a card no longer applies it immediately. `world.gd`'s interstitial sequence
now opens with `_show_stage_reward` (`"Earned: $%d"` off
`RunSession.last_stage_money()`, `"Total money: $%d"` off `Save.money()`, a single
**Continue** — shown for EVERY stage result, including a missed one, which pays $0
but should still tell the player plainly rather than jumping straight to a bare
Continue) → the four pick screens above (repair-or-upgrade → category → roll) →
`_confirm_pick` (what the ROLLED choice does to the car — a `CarStatsPanel`
before/after built off `CarStats.preview`, read-only, a single **Next**) →
`_show_skill_progress` (`SkillProgressPanel` — how far the stage moved every skill
gate, Continue) → `_apply_pick` (applies the pick for real and advances the run). See
[car-stats.md](car-stats.md) for what the stats/preview step actually builds and why
`preview` never mutates the profile.

`RunSession.last_stage_money()` is deliberately transient (unlike `money_earned()`,
the run's running tally, which IS persisted) — it exists only to answer "what did
that stage just pay", is set once per `report_event_result` call (0 for a missed
stage) and read exactly once, immediately after, by `_show_stage_reward`. Nothing
reconstructs it across a pause/resume because nothing needs to: a resumed run has
already shown its last stage's reward screen.

Each step REPLACES the interstitial page rather than stacking pages. **There is no
Cancel any more** — the roll already committed the choice
(`todo/mid-run-upgrade-menu.md`: "the user has no choice"), so `_confirm_pick`'s
stats step is read-only and `MenuNav.attach`s with no `on_back`. **Repair and the
bare "Continue" (an empty pick) skip the stats step entirely** — a repair has no
car-stat sheet worth comparing (it restores `wheel_toe`, not a `CarStats` row) and an
empty pick has nothing to preview — going straight to `_show_skill_progress`.

`_on_interstitial_choice` is the seam that applies whichever pick the roll landed on
(routing a `"drivetrain:<mode>"` choice to `RunSession.choose_drivetrain`, an
`"engine_swap:<id>"` choice to `RunSession.choose_engine_swap`, same as `"repair"`
and a boost id go to `choose_repair`/`choose_boost`), tears the modal down, then
either continues the run (`RunSession.continue_to_next_stage()`) or, if the run just
ended, emits `run_interstitial_dismissed` so `_on_run_finished` (mode-agnostic —
challenge and region both wait on it before returning to the hub) knows the player
has seen the result. Not tested at the `world.gd` layer — instantiating `main.tscn`
costs ~15s per test (`features/testing.md`), so this relay is covered by
compile-time checking plus the already-tested panel builders (`car-stats.md`'s test
files, `test_run_pick_panel.gd`) it calls in sequence.

### Drivetrain conversion — an AWD option competing in the SAME pool as boosts

**Decision 52 is superseded.** It originally sold a drivetrain conversion as a
permanent, per-car money sink (`Save.buy_drive_mode`) — that purchase surface is
deleted outright. A conversion is now a **run-scoped mid-run upgrade**, offered in the
same between-stage pick as repair and the drawn boosts: free, chosen exactly once per
pick, and gone the moment the run ends, win or lose — the same lifetime as a boost.

Only **AWD** is offered, and only when the car isn't already AWD — not every
`Drivetrain.DriveMode` the car could switch to. `RunSession._pool_drivetrain_ids()`
returns `["drivetrain:%d" % Drivetrain.DriveMode.AWD]` when AWD is available, `[]`
otherwise, and that's what `report_event_result`/`resume()` pass as `boost_pool_ids`'s
`extra_ids` (alongside `_pool_engine_swap_ids()`) — folded into the SAME pool as the
boost catalogue (see *The catalogue and its pool* above), so an AWD conversion is just
another entry a player can land on when they choose "Better Handling", not a guaranteed
extra card. This is deliberately narrower than `RunSession.drivetrain_choices()` (unchanged, still every
non-current `DriveMode`) — that function now exists purely to answer "what conversions
exist at all" for other callers (its own tests, `RunSession.choose_drivetrain`'s
contract), not to enumerate what the between-stage pick offers.

`RunSession._drivetrain_override` (-1 = "the fielded car's own stock/current layout")
mirrors `_boosts` exactly: reset in `begin()`, restored from the run record in
`resume()`, persisted in `_persist()`, wiped in `_finish_locally()`.
`RunSession.choose_drivetrain(mode)` resolves the pick, same "the player picks exactly
one" rule `choose_repair`/`choose_boost` follow — unlike boosts, a second conversion
picked later in the run **replaces** the first rather than stacking (a car has one
driveline at a time).

`UpgradeLibrary.resolve_drive_override` no longer gates on a purchase — it is a bare
range check against `Drivetrain.DriveMode.values()`, since `world.gd::_field_car` is now
the only legitimate writer of `drivetrain_override` (onto the duplicated fielding dict,
never `Save`'s persisted car — see *Where boosts live* above). `HubShell`'s old
`DRIVETRAIN` / `DRIVETRAIN_CAR` shop pages are deleted along with the purchase path.

### The engine swap — a genuine EngineLibrary swap, deterministic

A power-category option alongside repair, the boost catalogue and the AWD conversion: a
REAL engine dropped into the run's car via the already-built `EngineSwap` module +
`car.gd::_apply_engine_swap` pipeline (see [engine-swap.md](engine-swap.md) for that
pipeline in full). It is deliberately NOT random — `RunSession._pool_engine_swap_ids()`
offers exactly **the next most powerful `EngineLibrary` engine relative to the car's
current one** (`RunSession._current_engine_id()`, which prefers this run's own swap over
the persisted car's `swapped_engine`/stock engine, exactly like `EngineSwap.
current_engine_id`), ranked by `CarLibrary.peak_power_kw({"peak_torque", "redline"})` —
among every engine strictly more powerful than the current one, the smallest such power,
i.e. the immediate next rung up. `[]` once the car is already running the catalogue's
most powerful engine, the same "drop the option once it has nothing left to offer" shape
`_pool_drivetrain_ids()` uses for AWD. Folded into the SAME pool as the boosts and the
drivetrain conversion (`RunSession._pool_drivetrain_ids() + _pool_engine_swap_ids()` as
`extra_ids`), so it's just another entry in the "More Power" category rather than a
guaranteed extra card.

`RunSession._with_engine_swap_display(pick)` — called at BOTH pick-building call sites
(`report_event_result`, `resume`, via `_resolve_pick_pool`) so a live pool and a resumed
pool can't disagree — stamps `hp` and `hp_delta` onto any `engine_swap:` entry, via
`CarLibrary.horsepower({"peak_torque", "redline"})` (the same derivation the car stats
panel uses) against the car's current engine. `RunPickPanel` reads those fields straight
off the entry to build its card (see *The pick screens* above).

`RunSession._engine_swap_id` (`""` = "the car's own stock/previously-swapped engine")
mirrors `_boosts`/`_drivetrain_override` exactly: reset in `begin()`, restored from the
run record in `resume()` (`"engine_swap_id"` key), persisted in `_persist()`, wiped in
`_finish_locally()`. `RunSession.choose_engine_swap(id)` resolves the pick, same "the
player picks exactly one" rule the other `choose_*` methods follow — unlike a boost, a
second swap picked later **replaces** the first rather than stacking (a car has one
engine at a time), same as a drivetrain conversion.

`world.gd::_owned_with_run_effects` (called from `_field_car`, the same seam that merges
`boosts` and `drivetrain_override` onto the duplicated fielding dict) sets `owned
["swapped_engine"] = RunSession.engine_swap_id()` whenever that id is non-empty — that
single write is the WHOLE integration: `car.gd::apply_owned` already reads `swapped_engine`
and runs `_apply_engine_swap`, bringing the swapped engine's real torque curve, redline,
mass, weight distribution and gearbox/gearing along with it. Never touches `Save`'s
persisted car, and dies with the run like every other boost — see *Where boosts live*
above.

### The meta tier — boost levels, car purchasing

Stage 6 built all three. They are thin wrappers over
`Save.spend_money` sharing one refusal
rule: an invalid or unaffordable purchase leaves the profile **byte-identical** — no
half-spend, no partial mutation. `HubShell`'s `SHOP` view
(`features/hub-shell.md`) are the only sellers.

**Boost levels.** `Save.KEY_BOOST_LEVELS` (id -> level, never wiped by a failed run —
it's meta, not run state) is what a level does NOT do — touch the live car — vs. what
it DOES: scale the magnitude a FUTURE in-run pick rolls. `BoostLibrary.magnitude_for(id,
level)` is the one place that scaling happens (`effect_for(id)` is the live wrapper that
reads `Save.boost_level(id)`), via three new `GameConfig` fields under
`@export_group("Roguelike Meta Shop")`:

- `boost_level_max` — the level cap, shared by every catalogue entry (RR gives every
  `BOOST_DEFINITIONS` row the same `maxLevel` too — one cap, not one per entry).
- `boost_level_price_base` / `boost_level_price_growth` — `Save.boost_level_price(id)`
  is `base * growth ^ level_owned` (RR's `basePrice * priceMultiplierPerLevel **
  currentLevel`), so each level costs more than the last.
- `boost_level_magnitude_step` — how far ONE level pushes a magnitude away from its
  unleveled (level 0) baseline, as a fraction. Each `BoostLibrary.CATALOGUE` entry
  carries its own `level_direction` (+1 or -1) saying which way "more boost" moves that
  field (e.g. `grip`'s `tire_grip_mult` goes UP, `lightweight`'s `mass_mult` goes DOWN)
  — `BoostLibrary.level_scale(level, direction)` is `1.0 + direction * level * step`,
  floored well above zero so no combination of step/level can flip a magnitude's sign.
  **Level 0 is always an exact no-op**, which is what keeps every stage-5 boost-pick
  assertion valid without knowing about levels at all.

Decision 42's requirement — "the shop shows the effect range per level ... legible
without a live car to compute against" — is `BoostLibrary.effect_range_text(id)`: the
percent swing the WHOLE ladder covers (level 1's push through the cap's), not a bare
level number or the raw `GameConfig` magnitude (which means nothing without knowing the
car's own baseline stat, and reads the same way regardless of the effect's mult/add/set
op).

**Car purchasing.** `CarLibrary.CARS` gained a `cost` field per entry — authored
catalogue data exactly like `reward_tier`, not a `GameConfig` value, so CLAUDE.md's
no-pinning rule applies the same way (`test_car_stats.gd` only asserts every car HAS a
positive cost). `Save.buy_car(model_id)` refuses (no mutation) if the model is unknown,
already owned, or unaffordable; otherwise it spends `cost` and calls the existing
`grant_car`. `HubShell`'s `CAR` page is BOTH the run's car-select screen and the shop —
decision 28's own wording ("the car select screen offers a Buy action for unowned
cars") — so owned cars start a run and unowned ones show `Buy <name> — <cost>`,
disabled + `menu_nav_skip` (the same opt-out pattern the REGION page's locked rows use)
when unaffordable. This is what retires the old dead end: a fresh profile owns nothing,
but decision 28's starting purse means the very page that used to say "no cars yet" now
lists something it can afford.

**The Engine Swap is a mid-run boost now** — one of the seven `BoostLibrary`
entries above (`"engine_swap"`), picked between stages and sold up levels in
the shop like every other boost. The decision-17 one-time meta unlock is
deleted with its `Save.buy_engine_swap_unlock` mutator; see
[engine-swap.md](engine-swap.md) for the full history.

## Known placeholder — resolved

`RegionRunMode.region_index()` used to read the region's raw array index in
`RegionLibrary.REGIONS`; stage 4 landed the authored `order` field this section
used to call for, and `region_index()` now reads `RegionLibrary.order_of(region_id)`.
Nothing left calling for changes here.
