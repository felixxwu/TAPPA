# Star Economy — spendable stars, purchased cars

Turn stars from a monotonic threshold counter into **spendable currency**: a new menu
trades stars for a random car (keeping the existing anti-soft-lock override), cars stop
dropping automatically from every rally win, and the special-event ladder moves from
star-gating to completion-gating.

Status: **IMPLEMENTED** (full suite 2321/2321). Changes 1–5, the podium stars beat, the
present-box map target and the car-park reveal are all in. Two follow-ups remain, listed
under *Still outstanding* at the bottom.

**Post-implementation measurement** (`./sim_career.sh`, 100 careers, price 4):

| | predicted | measured |
|---|---|---|
| stars earned per career | ~80 | **79.8** |
| final cars | 20 | **20.5** |
| distinct models | 9 of 9 | 9 of 9 |
| soft-locked | 0% | **0%** |
| rescues needed | — | **0** |

The prediction for 3b's effect on the star supply (~60 → ~80 once specials pay stars) was
accurate to within 0.2. **It also confirms the over-supply warning:** 20.5 cars bought
against a 9-car catalogue means ~11 duplicates, so the surplus sink below is now a measured
problem rather than a projected one.

> **This reverses a shipped design on two levels.** See
> [`star-gated-special-events.md`](star-gated-special-events.md), which is marked
> SHIPPED and whose central argument is that stars work *because* they are derived
> rather than stored — "a running metric that rewards both breadth and mastery (go back
> and convert a 2nd into a 1st)".
>
> - **Change 3** removes star-gating from specials, changing what stars *do*.
> - **Change 4** replaces derivation with a persisted ledger, changing what stars *are* —
>   and deletes `total_stars()` / `max_total_stars()` outright.
>
> Both are deliberate reversals decided after simulation, not oversights, but they must be
> conscious decisions before implementation starts. Read that spec first. Note the mastery
> incentive it valued **survives**: change 4's delta rule still pays for converting a 2nd
> into a 1st, and still pays nothing for re-winning at the same or worse placement.

## Why — the evidence

`./sim_career.sh` (`tools/sim_career.gd`, see
[`features/rally-roster.md`](../features/rally-roster.md) → *Progression check*) walks
100 whole careers over the real predicates. Two findings drive this work.

**1. Restriction bands stop gating anything early.** The tool prints `revealed` (what
reveal gating has opened) beside `eligible` (what the garage can actually enter). From
rally 5 onward **the two columns are identical** — the per-rally `restriction` dicts
(`drive_mode` / `car_type` / `doors_max` / `cylinders_max` / engine litres /
power-to-weight band) filter out nothing at all. The most interesting, most diegetic
gate in the game ("this is a hatchback cup, bring a hatchback") is inert for ~80% of a
career.

The cause is the guaranteed car supply: `RallySession` draws a car on every ordinary
top-3 finish (`rally_session.gd`, the `elif not is_special` branch calling
`RewardSystem.draw_car`, ~line 591). 24 ordinary rallies means 24 cars plus the starter
— the sim measures exactly 25.00 — and a 25-car garage owns something in every class.

**2. Stars are earned and then do almost nothing.** A career ends with a mean 60.1 of 72
stars. They gate four special-event rungs and are otherwise inert, so placing 1st versus
2nd is very nearly meaningless: both are a win, both grant a car.

Making stars buy cars fixes both at once — cars become scarce (so bands bite) and every
placement matters continuously rather than at four cutoffs.

## Already landed (prerequisite)

- **The simulation tool** — `tools/sim_career.gd` / `.tscn`, `./sim_career.sh`,
  `tests/headless/test_sim_career.gd`. Pure computation, ~210 ms per career.
- **Stretched reveal schedule** — 19 `reveal_after` values in `RallyLibrary.RALLIES`
  respread from 0–8 to 0–20 (one new rally per completion, authored rung order
  preserved). Cut simultaneous choice from a peak of 16.47 enterable rallies to a flat
  ~4.0–4.7 across the whole career, with soft-lock still 0% and 0 rescue draws in 100
  careers. Note this required regenerating `data/opponent_cache.json` via
  `./cache_all.sh` — see *Incidental findings*.

## The coupled changes

They are coupled: shipping any one alone leaves the game in a worse state than today.
Changes 1–4 are the economy; change 5 aligns the Rally Challenge with it.

### 1. Cars are bought, not granted

Remove the automatic car draw from the ordinary-rally reward path in
`rally_session.gd` (the `elif not is_special` branch). Add a menu that spends stars on
`RewardSystem.draw_car(profile, difficulty, rng)`.

`draw_car` must keep being the draw entry point, because it already carries the
anti-soft-lock behaviour this design depends on: `RewardSystem._unlock_candidates`
returns `[]` when any owned car can already enter something (normal tier-clamped draw),
and otherwise returns the set of catalogue cars that can enter the *easiest*
revealed-but-locked rally, so the grant re-opens progression. That path is pure — it
reads only `profile`, `CarLibrary`, `UpgradeLibrary`, `RallyLibrary` — which is why the
sim can exercise it faithfully.

**The price is a `GameConfig` field, not a script constant.** CLAUDE.md: all gameplay and
balance tuning lives in `config/game_config.tres`, and script literals are fallback
defaults only. This is the most-retuned number in the whole design, so it must be
inspector-editable. `game_config.tres` carries no reward/price field today, so this is a
new one. (`STAR_COST_PER_CAR` in `tools/sim_career.gd` is the *simulation's* knob and stays
a constant there — the tool is not the game.)

**Nothing to give = nothing spent.** `draw_car` returns `Variant` and **can be null** (the
podium path guards with `if model != null`). A purchase must resolve the draw BEFORE
debiting stars and abort the whole transaction if it comes back empty — never charge for
nothing. This is exactly the rule `Save.open_mystery_box` already states for boxes
("NOTHING TO GIVE = NOTHING SPENT", box retained rather than burned); follow that
precedent rather than inventing a refund path.

**One purchase at a time.** Even when the balance affords several, a purchase buys exactly
one car and returns the player to the map. The reveal is a moment, not a slot machine.
(Note the sim buys *greedily* in a loop — that is a modelling simplification for measuring
supply, not the intended UX.)

#### The dead-end rescue: price 0 when stranded AND broke

This is how the stranded-and-broke hole is closed — no separate rescue path, just a price of
zero under one condition:

```
price = 0  if  stranded AND available < normal_price
```

Reusing the purchase flow is the point: `draw_car` still runs, so `_unlock_candidates` still
picks a car that actually opens the *easiest* revealed-but-locked rally, rather than a random
one that might not help.

**Both halves of the condition are required.** Free-when-merely-stranded is farmable: take
the free car, complete the rally it unlocks, become stranded again, take another — an entire
career for nothing. Gating on `available < price` closes it, because a player who is
progressing is earning stars and therefore is not broke. It is a rescue, not a discount.
The exploit value is further limited by `_unlock_candidates` granting the *minimum unlocking*
car rather than a desirable one.

**`stranded` must be ONE shared predicate.** The pin's price readout and the purchase itself
must agree, so expose the existing logic rather than reimplementing it —
`RewardSystem._unlock_candidates(profile)` already returns non-empty exactly when nothing is
enterable. Promote it to something like `RewardSystem.is_stranded(profile)` and have both
callers use it.

**Check whether it counts wrecked cars.** `_unlock_candidates` iterates `profile["cars"]` with
no apparent wreck filter, and wrecked cars stay in that array as dead weight. If a wreck can
satisfy "some car can enter something", a player whose only eligible car is wrecked would read
as not-stranded and be denied the rescue. Verify and filter on `Save.car_is_wrecked` if so.

**Display:** the pin shows the price normally (`3/5 ★`); when the condition holds it should
read as free rather than showing a price the player cannot meet.

**Tests:** stranded + broke ⇒ price 0; stranded + affordable ⇒ normal price; not stranded +
broke ⇒ no purchase. Assert against the configured price, never the literal number.

**Out of scope:** the per-event upgrade draws (`RewardSystem.draw_upgrade`, the mystery-box
roll) are untouched by this work. Only the CAR supply changes.

### 2. No rewards on re-wins — NOTHING TO IMPLEMENT

**This is a property of changes 1 and 4, not a task.** Kept as its own section only because
grind resistance is a requirement worth stating explicitly and verifying.

- Change 1 removes the car draw from the rally reward path entirely, so a re-win grants no car.
- Change 4 awards only the delta against a rally's previous best, so a re-win at the same or
  worse placement grants no stars.

Nothing else is needed, and **replays are deliberately NOT banned** — see below. Worth a test
asserting a re-win at equal-or-worse placement changes neither car count nor star balance.

`rally_session.gd`'s own comment describes the current car draw as a *"renewable supply
— it fires on re-wins too"*. That is a live grind exploit today: replay an easy rally,
farm cars forever.

Stars are **already** immune to this. `Save.complete_rally` only ever improves the
record:

```gdscript
if placed > 0 and (int(rec.get("best_placed", 0)) <= 0 or placed < int(rec["best_placed"])):
	rec["best_placed"] = placed
```

Re-winning a rally already taken at 1st writes nothing, so it earns nothing. Only the
car drop needs fixing.

**Do NOT ban replays to solve this.** The problem is a reward problem, not a replay
problem. Banning replays costs the player practice runs and time-chasing, and it breaks
wreck recovery (a wrecked-out player could no longer re-earn). Removing the reward gets
the whole benefit with none of that cost.

### 3. Specials move from star-gated to completion-gated

**Required, not cosmetic:** with spendable stars, star-gating means buying a car can
*revoke* access to a special the player had already qualified for — punishing them for
using the currency.

**The gate.** Each special carries a required number of completed ordinary rallies, and
the readout is *progress toward that requirement* — `0/2 events completed`, then `3/4`,
and so on. The denominator is the special's own requirement, **not** the roster size.
(Recording this explicitly because "1/4" first read as "1 of 4 total events", which would
have implied a per-region or per-special count and a completely different mechanism.)

**Thresholds:** ascending in steps of 2 — the first special at 2 completions, the next at
4, then 6, and so on. With 8 specials that puts the last rung at 16, leaving 8 ordinary
rallies still to play after the ladder is finished.

Note this **front-loads specials considerably** versus today, where the showdowns sit at
25–40 stars (≈10–16 rallies at the measured 2.5 stars/rally, and the ladder currently
finishes near the end of the career). Combined with the stretched reveal schedule this
wants simulating before it is committed to — see *Not yet simulated* below.

**Mechanism:** this is the existing global ordinary-completion count,
`RallyLibrary._completed_count(profile)`, which already excludes specials — so specials
still do not advance each other's gates, and the deliberate global (not per-region)
drip-feed documented in that function's comment is preserved.

**Field:** add `requires_completions` to the special entries rather than reusing
`reveal_after`. `reveal_after` is currently *ignored* for specials, so reusing it would
silently give every existing special whatever value it happens to carry today.

This is a net simplification. `RallyLibrary.rally_revealed` currently branches:

```gdscript
if is_special(rally):
	return special_gate_open(rally, profile)
var need := int(rally.get("reveal_after", 0))
...
return _completed_count(profile) >= need
```

Completion-gating deletes the branch — specials use the same path as everything else —
and `special_gate_open`, `stars_required` and `stars_needed` can go with it.

**Dependency / breakage.** `RallyLibrary.engine_swap_star_requirement()` is
`stars_required(by_id(ENGINE_SWAP_UNLOCK_RALLY))`, and `engine_swaps_unlocked(profile)`
keys the engine-swap capability to completing `sp_woodland_trial`. The capability gate
itself survives (it is completion-based already), but the **star readout** quoted by the
garage swap row and the car-park confirm popup breaks and needs rewording to the
completion count. Note also loose end 3 in
[`star-gated-special-events.md`](star-gated-special-events.md): that gate was recorded
as only half-wired, so confirm its current state before touching it.

### 3b. Specials award stars

A special's placement pays stars like any other rally: it increments the change-4 ledger by
the same delta rule. Today `RallyLibrary.total_stars` explicitly skips specials —

```gdscript
for rally in all():
	if is_special(rally):
		continue
	n += stars_for_placement(...)
```

— but under change 4 that function is deleted outright, so this is not an exclusion to
remove so much as one that stops existing. **What matters is that the award site fires for
specials too**, where today it does not fire at all.

**The "x of N" star readout goes away.** `max_total_stars()` is quoted as a denominator,
which stops meaning anything once stars are spendable (change 4) and renewable (change 5) —
the balance can exceed any career maximum, and "earned" and "available" become different
numbers. **Show the balance on its own, with no denominator**, and delete
`max_total_stars()` along with `total_stars()`.

**This is only safe because of change 3.** While specials are star-gated, specials
awarding stars creates a feedback loop — win a special, gain stars, unlock the next
special — which is exactly the "authored against a stable maximum" property
[`star-gated-special-events.md`](star-gated-special-events.md) called out when it chose
the exclusion. Once specials gate on *completions* the loop is broken, and the exclusion
stops earning its keep. **So 3 and 3b must ship together; 3b alone reintroduces the loop.**

It also gives specials a stake in the economy again. Today a special pays an upgrade
unlock, no car and no stars — under this design it pays an unlock and stars.

**Note `_completed_count` keeps excluding specials.** That is deliberate and consistent:
stars are the *currency*, completions are the *gate*, and a special should not advance the
gate that governs its own ladder.

**Budget consequence — it makes the over-supply worse.** Ceiling rises from 72
(24 ordinary × 3) to **96** (32 × 3); expected earnings at the measured 2.5 stars/rally
rise from ~60 to **~80**. At 4 stars/car that is 20 purchases against a 9-car catalogue,
so ~12 of them are duplicates and roughly 48 stars do nothing once the roster is complete.

This sharpens the pricing question rather than settling it. For reference, **8 stars/car**
against ~80 earned gives 10 purchases — the 9-car roster plus one spare, with little idle
surplus. Worth including in the sweep.

### 4. Stars become a persisted ledger

**Stars stop being derived.** Today `RallyLibrary.total_stars(profile)` recomputes by
summing `stars_for_placement(best_placed)` over completed non-special rallies on every
call — which is exactly why the total can never decrease. That model cannot survive this
design (see *Why derivation has to go*), so stars move to two persisted profile fields:

```
stars_earned  # monotonic accumulator, incremented at award time from EVERY source
stars_spent   # incremented on each purchase
available = stars_earned - stars_spent
```

**Increments are always deltas against the previous best**, never the raw placement:

```
delta = stars_for_placement(new_placed) - stars_for_placement(old_placed)
```

Re-winning at a worse placement yields `delta == 0`, so the no-double-dip guarantee that
`best_placed` gave implicitly is now explicit in the increment. Grind resistance is
preserved, not lost.

#### Why derivation has to go

Three separate holes close at once, which is why this replaces the earlier
`stars_spent`-only plan:

1. **Challenge stars cannot be derived.** `challenge_results[period_key]` stores only
   `{kind, dnf, cumulative_ms}` — **no rank** — and `challenge_session.gd` *prunes* the dict
   to currently-live periods (`Save.profile["challenge_results"] = pruned`). So past periods
   are discarded by design: any derived sum would make a player's stars *fall* overnight as
   periods roll. Change 5 is impossible without an accumulator.
2. **A derived total can shrink.** It reads `RallyLibrary.RALLIES`, so renaming or removing a
   rally reduces earned — potentially below `stars_spent`, producing a negative balance from
   a routine catalogue edit. A ledger makes "spent never exceeds earned" **structurally**
   true instead of data-dependent, and needs no clamp.
3. **The delta does not exist anywhere today.** The podium stars beat needs "stars gained",
   not "stars for this placement" (see *UX — the podium stars beat*). Computing the increment
   is what produces that number.

**`RallyLibrary.total_stars()` becomes dead code.** Its only callers are `special_gate_open`
(deleted by change 3), `engine_swap_star_requirement` via `stars_required` (also deleted by
change 3), and the UI readout (now the ledger). Confirm and delete it with
`max_total_stars()`. `stars_for_placement()` stays — it is what computes each delta.

**What is lost:** self-healing. Derived stars auto-correct if `best_placed` data is ever
repaired; a ledger does not, so a bug that over-credits is permanent. Judged an acceptable
price for a balance that cannot go negative and cannot silently shrink.

**No migration.** Existing profiles start at `stars_earned = 0` rather than being seeded from
their derived total. Accepted deliberately: those profiles already hold ~25 cars granted free
under the old rules, so starting them at zero stars is closer to fair than the windfall of
a full balance *and* the whole roster. Nothing to write, nothing to test, no one-shot
migration to get wrong.

**Do this FIRST.** Changes 1, 3b and 5 all award or debit through this ledger, and the podium
stars beat reports the delta it computes — none of them can ship without it. Needs coverage in
`test_save_manager.gd`.

**Tests must not pin the price.** CLAUDE.md forbids asserting tunable values, and "a car
costs 4 stars" is exactly the assertion to avoid — it breaks the moment a designer retunes
the `GameConfig` field. Assert the *logic* instead: a purchase debits exactly the configured
price, a balance below the price refuses the purchase, the balance never goes negative,
spent never exceeds earned.

### 5. The Rally Challenge pays stars, not cars

**Decided:** the Daily/Weekly/Monthly challenge awards **1/2/3 stars** instead of drawing a
car, consistent with the podium losing its car beat. Remove the `car_tier` branch of
`_COMPLETION_REWARD` in `challenge_session.gd` (the `RewardSystem.draw_car` +
`Save.grant_car` pair); keep the `boxes` grant.

**Mapping:** reuse `RallyLibrary.stars_for_placement(rank)` — 1st → 3, 2nd → 2, 3rd → 1,
else 0. That is exactly the 1/2/3 scale and keeps one definition of what a star is worth.

**Award by incrementing the change-4 ledger.** Challenge stars have nowhere else to live:
`challenge_results[period_key]` stores only `{kind, dnf, cumulative_ms}` (no rank) and is
pruned to live periods, so nothing about a past challenge is recoverable. The increment at
award time IS the record. This makes change 5 **dependent on change 4** — it cannot ship
first.

Because each period is one terminal attempt, the increment fires at most once per period and
needs no delta comparison (unlike rallies, there is no "previous best" to improve on).

**The Challenge gets the stars beat too.** Same three-star reveal as the rally podium, for
consistency — a star earned in a challenge should look identical to one earned in a career
rally. See *UX — the podium stars beat*.

**It is rate-limited, not grindable.** `challenge_session.gd` enforces *"One attempt per
period. A finished run — completed OR DNF'd — is terminal"* until the period rolls, and the
terminal outcome is stored per `period_key`, so a period cannot be re-farmed. This is the
same no-double-dip property `best_placed` gives career rallies.

**But it IS renewable, and becomes the dominant star source long-term.** A player who
podiums everything can draw roughly 30 dailies + 4 weeklies + 1 monthly per month ≈ **105
stars a month**, against a whole-career ceiling of 96 (post-3b). So for an engaged player
the Challenge dwarfs career income and car scarcity effectively disappears over real time.

That is a deliberate trade rather than a bug — it is time-gated, so it cannot be exploited
inside a single sitting, and a first playthrough over a weekend yields only a couple of
dailies (~9 stars). The consequence to accept is that **scarcity is a first-playthrough
property, not a permanent one**. If permanent scarcity matters, cap Challenge stars per
period or decay them.

**Unresolved detail: the "placed" threshold disagrees with the star scale.** Challenge
reward eligibility is *top half* of the field (`rank > ceili(total / 2.0)` → not placed),
whereas stars only pay to the top 3. So a player ranking 5th of 9 currently "places" but
would earn **zero** stars — colliding with the existing comment that *"a player who placed
must never walk away with nothing"*. Either widen the star scale for challenges, or lean on
the `boxes` grant as the consolation and accept that placing can pay no stars. Needs a
decision before implementing.

**This does NOT fix the stranded-and-broke dead end.** A stuck player must wait for a real
-world period to roll before earning anything, which is not an acceptable recovery path. The
guard in *Sequencing* is still required.

## Already covered — no work needed

**Wreck recovery does not touch stars.** A two-stage net already exists:

- `Save.ensure_wreck_safety_net()` — when every car is wrecked *and* no mystery box is
  held, grants a box free.
- `Save.open_mystery_box()` — when every car is wrecked, pays out a whole **car** via
  `RewardSystem.draw_car`, carrying the anti-soft-lock fallback.

Both are free and star-free, so wrecking out cannot drain the star pool and a
wrecked-out player always gets a car that re-opens progression.

Worth knowing: wrecked cars are **not** removed from `profile["cars"]` — they remain as
unusable dead weight (`Save.all_cars_wrecked` iterates them; wrecks can never be
repaired). So any "cars owned" count, including the sim's, overstates *usable* cars.

**KNOWN EXPLOIT, ACCEPTED.** Because the wreck net is free while cars otherwise cost stars,
a player owning exactly ONE car can wreck it deliberately and take the free replacement
instead of paying — and `all_cars_wrecked()` is trivially satisfied with a one-car garage,
which is the entire early game. Damage is one-way (repair kits are gone), so this is easy to
trigger on purpose. **Judged acceptable:** it costs the player their only car and a whole
run, it does not scale (a larger garage means wrecking *everything* first), and closing it
would mean charging stars for the anti-soft-lock rescue — which is the one thing that must
never have a price. Recorded so it reads as a deliberate trade, not a miss.

## Open questions — settle by simulation before implementing

- **Car price — DECIDED at 4, see *Simulated prices*.** The CAREER star pool is capped at 72
  (24 ordinary × 3), rising to 96 with change 3b, and career stars are non-renewable because
  change 4 awards only the *delta* against a rally's previous best. **Change 5 breaks that cap** — the Rally Challenge is
  renewable over real time (~105 stars/month for a player who podiums everything), so the
  cap only bounds a first playthrough, not a long-lived profile. Note `CarLibrary.CARS`
  holds only **9** cars, so roster coverage is not the constraint it would be with a large
  catalogue — at 4 stars every career sees all 9.
- **Stacking with the stretched schedule.** Both changes narrow choice, and rally 1 is
  already down to 2.50 eligible. Simulate them **together**, not separately.
- **The dead end — RESOLVED**, by pricing the car at 0 when stranded and broke (change 1).
  Recorded here because the reasoning matters: without it, a stranded player with no stars has
  no eligible rally → no way to earn → no way to buy the car that would unlock one, which
  cannot happen today. **The accepted wreck exploit does NOT cover this**, though it looks like
  it might: wrecking a car requires entering a rally, and a stranded player cannot enter one.
  Still open is *verifying* the fix in the sim — see *Simulated prices*.
- **The surplus sink.** At 4 stars the economy *over-supplies* (see below): the roster is
  complete around two-thirds in and the remaining stars buy nothing but duplicates. Stars
  becoming inert late is the same problem this design set out to fix, just deferred.
  Either raise the price, or give stars a second sink — upgrades are the obvious
  candidate, and `UpgradeLibrary` / `RewardSystem.draw_upgrade` already exist.

## Simulated prices

`STAR_COST_PER_CAR` in `tools/sim_career.gd`, run with the stretched reveal schedule
active, 100 careers per price. Purchases are greedy (buy as soon as affordable), the most
generous assumption — so coverage is an upper bound and soft-lock a lower bound. Setting
the constant to `0` restores today's free-car-per-win model for comparison.

**DECIDED: price is 4 stars.** 5 + rescue measured slightly better on over-supply (12.71 final
cars vs 15.60), but 4 was chosen anyway — it is safe without depending on the rescue at all
(see *4 stars per car* below), which is one fewer moving part for a first ship. All figures
here were measured **before** changes 3 and 3b, so the star pool is still 72 rather than 96 —
see *Not yet simulated*.

Against today's free-car-per-win model, for orientation:

| | current game | 4 stars |
|---|---|---|
| final cars | 25.00 | **15.60** |
| distinct models | 9 of 9 | 9 of 9 (100%) |
| bands stop filtering at | rally 5 | rally 10 |
| eligible at rally 1 | 2.50 | 1.73 |
| soft-locked | 0% | 0% |

Cars drop by more than a third while roster coverage holds, and the restriction bands stay
live twice as long — which is what this whole design set out to achieve.

**The rescue still ships.** Even though 4 does not currently need it, the price is a
`GameConfig` field (see change 1) precisely so it can be retuned — and the moment anyone bumps
it above 4, the rescue is what stands between that retune and an 11%+ soft-lock rate. It is
cheap insurance, not price-specific work, so it is not conditional on the final price chosen.

### 5 stars per car — VIABLE with the dead-end rescue, not chosen

The rescue is now modelled in `tools/sim_career.gd` (price 0 when stranded and the balance
cannot cover a car, one free car, drawn through `draw_car` so `_unlock_candidates` still picks
an unlocking model). It converts every one of the 11 deaths into a rescue:

| | 5 stars, unrescued | **5 stars + rescue** |
|---|---|---|
| completed all | 89% | **100%** |
| soft-locked | 11% | **0%** |
| stranded + broke | 11 runs | **0** |
| career length | 28.9 (min 2) | **32 (min 32)** |
| distinct models | 8.17 of 9 | **9 of 9 (100%)** |
| final cars | 11.40 | 12.71 |
| free rescues | n/a | 11 cars across 11 runs (1 each) |
| stars unspent | 2.3 | 2.1 |

**Verdict: 5 stars works, and would over-supply less than 4** (12.71 final cars vs 15.60 for
the same 100%-coverage, 32-rally career). **Not chosen** — the price is 4 (see above) — but
kept here as a validated fallback if 4 is ever retuned up, or if the surplus-sink question
below is resolved by raising the price instead of adding a second sink.

**The rescue is load-bearing, not decorative.** Without it this price loses 11% of careers, so
it must ship WITH the purchase logic (change 1) and must not regress. Note the diagnostic
distinction the tool now draws: `rescue draws` counts stranded moments that were resolved,
`stranded+broke` counts those that were not. The second must stay 0.

**Still measured pre-3b**, so the star pool is 72 rather than 96. Change 3b adds income, which
pushes toward *more* over-supply — a reason to consider pricing above 5 at the re-measure, not
below.

### Why the rescue was necessary — the 5-star boundary

Kept as the rationale record. Before the rescue existed, 5 stars lost 11% of careers, and the
reason is a **boundary, not a gradient**. Placement pays 3 stars (1st) or 2 (2nd), so after two
rallies a player holds 6 / 5 / **4** stars with probability 25 / 50 / 25%. At a price of 4 every
outcome affords the first car; at 5 the two-seconds case (25% of players) cannot buy until rally
3, and if their starter cannot enter anything revealed meanwhile the career is over.
`min career length = 2` was that death.

Critically, `RewardSystem._unlock_candidates` could not save them: it runs only *inside* a car
draw, and a broke player never triggers a draw — hence 0 rescues against 11 dead ends. The
anti-soft-lock system was bypassed, not defeated. That is exactly why the fix had to be a price
of **0** rather than a smarter draw.

**The lesson generalises: any price at which two 2nd-place finishes cannot buy the first car
needs the rescue** — which is every price above 4. The rescue makes the cliff irrelevant, but it
is the only thing doing so, and that is why it must not regress.

### 4 stars per car — DECIDED

Measured **before** the rescue was modelled, so its own soft-lock figures stand but its rescue
counts are not comparable with the 5-star run above.

| | 4 stars | 5 stars + rescue |
|---|---|---|
| completed all | 100% | 100% |
| soft-locked | 0% | 0% |
| final cars | 15.60 | 12.71 |
| distinct models | 9 of 9 | 9 of 9 |
| stars unspent | 1.4 | 2.1 |
| eligible at rally 1 | 2.50 | 1.73 |

**4 is safe even unrescued** — this is the deciding factor: it does not depend on the rescue
firing correctly to avoid soft-locking, which is one fewer thing that must work for a first
ship. Its cost is **over-supply**: only 8 purchases complete the 9-car roster (32 of 72
stars), so ~40 stars buy duplicates that add nothing to eligibility — confirmed by
`revealed == eligible` from rally 10 onward. That is accepted as the trade for the simpler
dependency profile; see *The surplus sink* in *Open questions* if it proves too generous in
practice.

Both prices share one early-game problem: **1.73–2.50 eligible rallies at rally 1** against 4.00
revealed, so a new player often has only one or two options and cannot afford a car until two
rallies in. Worth widening the four openers' restriction bands or discounting the first purchase,
independently of the price chosen.

## UX — the present box

**Decisions taken:** the present box is the **single shared reveal device for every random
car grant**; the **podium awards no car at all** (the player earns stars, which they spend
later); and **duplicates are allowed** — the full cinematic plays whether the car is new or
not.

Car grants therefore reduce to two sources, both using the box:

1. **Star purchase** — the new map pin (below).
2. **Wreck rescue** — `Save.open_mystery_box` when wrecked out, which today shows only a
   plain `ConfirmPopup.open(self, "Mystery Box!", …)`. It inherits the cinematic for free.

`Stage.CAR_REVEAL` and `podium.gd:_reveal_showroom_car` are **retired** — the podium's car
beat becomes a stars-earned beat. The turntable/showroom *pattern* is worth copying into
the car park, but it cannot be reused literally: it lives in the podium scene and the
reveal now happens in the car park.

### Map pin

A present-box target on the world map, showing price and affordability. Reuse the
locked-rally-pin readout idiom so an unaffordable box reads `3/5 ★` rather than merely
being disabled.

**It gets a discovery beat.** A brand-new map mechanic must not appear silently. Reuse the
new-rally reveal machinery — `hq_table.gd:_pending_reveals` / `_run_reveal_sequence`, which
already pans the camera to a target and banners it — to introduce the box the first time it
becomes affordable. That path is generation-tokened and headless-short-circuiting already,
so it is the cheapest correct place to hang this.

**The starter pick survives unchanged.** `hq.gd:_enter_starter_pick()` keeps letting the
player *choose* their first car from `STARTER_MODEL_IDS`, and every later car is a random
box. The inconsistency (chosen once, random thereafter) is accepted: the opening choice is
an identity moment worth keeping, and it doubles as the lever for the tight early game
(1.73 eligible rallies at rally 1) if that needs widening later.

**Position: ~(0.52, 0.50), not (0.5, 0.5).** `front_runners` sits at (0.45, 0.45), only
0.071 away, and `hq.gd:_add_pin_hit`'s own comment says hit radii are kept under half the
closest pin spacing — a dead-centre target shrinks that budget and makes
`hq_table.gd:_select_target_under_center()` ambiguous between the two. Check the baked map
texture too (`tools/gen_map_texture.py`): the centre is where the four regional influence
fields converge and may render as water.

**Navigation is free.** The map does not use discrete pin-to-pin nav or `MenuNav.attach`:
`hq.gd:_process` reads held `menu_up/down/left/right` → `hq_table.gd:_pan_table_step`,
which glides the camera and then `_select_target_under_center()` picks the nearest target.
A new target joins keyboard **and** gamepad nav simply by appearing in
`hq_table.gd:_build_table_targets()`. It must carry a `label_panel` meta so
`UITheme.mark_panel_focused` can paint focus in `_focus_table_target`.

**The structural work is the rally-id assumption.** This is the first non-rally target;
`_table_targets()` hardcodes `kind = "pin"` ("pins are the only kind of target"). The
`match` on kind in `hq_table.gd:_activate_table_focus` is the natural seam, but
`_build_table_targets`, `_unlocked_pins`, `_node_with_rally_id`, `_focus_hardest_incomplete`
and `_pending_reveals` all assume a rally id exists and need to tolerate a target without
one.

### The reveal

New `CarparkMode.PRESENT` (joining `RALLY, FREEROAM, SWAP, STARTER, WHEELS, CHALLENGE`).
Transition in via the `hq.gd:_enter_car_screen()` path; `hq_carpark.gd:_make_carpark_modal`
already exists for the prompt.

1. Car park with every bay empty, one oversized present box at
   `hq_environment.carpark_center()`.
2. Prompt to open — **must accept `menu_select` from keyboard and pad**, not pointer only
   (CLAUDE.md: no menu ships pointer-only).
3. Lid tweens up and off screen; four sides rotate down about their bottom edges.
4. Car spawns through the existing `hq_carpark.gd:_spawn_parked_car` /
   `_seat_car_at_marker` at that marker, then a turntable pivot.
5. A closing card naming the car, modelled on `repair_reveal.gd`
   (`MenuNav.attach(self, {first = _continue_button})`, `finished` signal).

**Animation idiom:** `create_tween` / `await create_timer`. There is no `AnimationPlayer`
usage anywhere in this codebase — do not introduce one here.

**Assets:** no box model, mesh, icon or texture exists today (`models/` holds only
vegetation). The lid + four sides are five `MeshInstance3D`s; the bow is the only real
modelling.

**Headless short-circuit is mandatory.** `hq_table.gd:_run_reveal_sequence` already jumps
to `_finish_reveals` when headless and `UpgradeReveal.start_spin` is headless-aware. A
cinematic that awaits real time will add seconds to every test that touches it, and the
suite is already at 578 s.

**Tests:** a nav test alongside the existing map-table ones in `test_menu_flow.gd`
(`test_hq_map_table_pans_camera_and_tracks_centre`,
`test_hq_table_entry_focuses_hardest_incomplete_rally`,
`test_hq_map_table_focus_highlight_survives_a_pin_rebuild`), plus coverage that the box
target survives a pin rebuild and that a purchase is refused when unaffordable.

## UX — the podium stars beat

A new podium stage after the leaderboard: three large stars revealed one at a time, the
stars won filling **gold** and the rest left dim, with the player's star total underneath.
This is what fills the hole change 1 leaves when the podium stops awarding a car.

**It needs no new assets and no new patterns — everything exists.**

**The widget:** `StarRow` (`scripts/star_row.gd`, `class_name StarRow`) is already exactly
this — `setup(earned, total)`, gold `UITheme.GOLD` for earned and dim `UITheme.MUTED` for
not, drawn with `draw_colored_polygon` in `_draw` so it needs no font glyph or texture (Syne
Mono has no ★). `star_radius` (default 11 px) and `gap` are plain vars, so "big stars" is
just a larger radius. Already used by the HQ map pins and the rally detail panel, so the
podium inherits the same visual language for free.

**The one-at-a-time reveal:** call `setup(0, 3)` first so all three stars are visible but
dim, then step `earned` up to the won count. Copy the existing coroutine shape from
`podium.gd:_reveal_standings`, which already reveals leaderboard rows one per `REVEAL_STEP`:

- bump `_reveal_gen` and capture it, so leaving the stage mid-reveal abandons the coroutine
  rather than touching freed nodes
- `await get_tree().create_timer(REVEAL_STEP).timeout` per step, re-checking
  `gen != _reveal_gen or _stage != Stage.STARS` after each await
- gate the Next button with `_reveal_done = false` / `_refresh_next_button()` so the player
  cannot skip past a half-revealed row

**Headless short-circuit is mandatory** and the pattern is right there in
`_show_leaderboard`: `if _headless:` set the final state immediately, `_reveal_done = true`,
`_refresh_next_button()`, return. Without it every podium test pays real seconds.

**Wiring:** add `STARS` to `podium.gd`'s `enum Stage { PODIUM, LEADERBOARD, SPECIAL_UNLOCK,
CAR_REVEAL }`, append it in `_compute_stages()` **immediately after `LEADERBOARD`**, and add
a `_show_stars()` arm to the `match` in `_enter_stage`. A special therefore runs
`LEADERBOARD → STARS → SPECIAL_UNLOCK`; **two reward beats back to back is accepted.**

#### It must report the DELTA, not the placement

The obvious implementation — light `stars_for_placement(placed)` stars gold — is **wrong**,
because `best_placed` only ever improves:

| scenario | placement stars | actually gained |
|---|---|---|
| re-win a 3-starred rally at 2nd | 2 | **0** |
| improve 2nd → 1st | 3 | **+1** |
| first win at 1st | 3 | +3 |

Lighting two gold stars while the total underneath does not move is a straight lie to the
player. So the beat shows both numbers, distinctly:

- **The three stars** show this rally's star rating — the gold count is the player's
  *best* for it, which is the same thing the HQ map pin shows. Consistent across surfaces.
- **The text underneath** carries the change-4 delta explicitly plus the new balance —
  `+1 star · 34 total`. When the delta is 0, say so rather than showing "+0": something like
  "no new stars — your best here is already 3" reads as information instead of a bug.

This is only possible because change 4 computes the delta at award time; the number does not
exist today.

**The total is the SPENDABLE BALANCE** (`stars_earned - stars_spent`), not lifetime earned —
the actionable figure for a player heading to the present box. Bare, no denominator.

**The Rally Challenge gets the same beat**, so a star looks identical wherever it is earned.
The challenge award has no previous best to improve on, so its delta is simply the stars
awarded.

**Depends only on change 4, and should land right after it.** The widget and the reveal
coroutine already exist, so the work is small — but the delta it reports does **not** exist
until the ledger does, so this cannot genuinely ship first. Sequenced as step 3. It coexists
with `CAR_REVEAL` until change 1 retires that stage.

**Also shows on a non-podium finish** (0 stars won): three dim stars is honest feedback
rather than hiding the miss.

## Sequencing

**Change 4 comes first.** It is the foundation, not the finishing touch: 3b awards stars by
incrementing the ledger, change 5 has nowhere to record stars without it, change 1 needs a
balance to debit, and the stars beat needs the delta it computes. An earlier draft of this
spec sequenced it last, which was wrong once stars stopped being derived.

1. **Change 4** — the `stars_earned` / `stars_spent` ledger and the delta-based award site.
   No migration. Everything below depends on it.
2. **Changes 3 + 3b together** (completion-gating + specials award stars). Must ship as a
   pair — see 3b — and 3 is a net simplification that deletes `total_stars()` /
   `max_total_stars()` / `special_gate_open` / `stars_required` / `stars_needed`. Needs a
   `./cache_all.sh` afterwards.
3. **The podium stars beat** — pure UI over the ledger, reusing `StarRow` and the existing
   reveal coroutine. Can land any time after step 1; earlier is better, since it makes stars
   legible before they become spendable.
4. **Re-run the sim** with the real gating, the larger star pool and the ledger modelled, and
   re-price. This is where 5 stars gets a fair hearing (it is only rejected *today*, pre-3b).
5. **Change 1 + change 5** (cars only purchased, including the price-0 dead-end rescue;
   Challenge pays stars and gets the stars beat), plus retiring the podium's car beat. Grouped
   because they are the same edit in three places — every remaining `RewardSystem.draw_car`
   call site outside the purchase menu and the wreck rescue. Change 2 needs no work of its
   own; it falls out of 1 and 4.
6. **The present-box UX**, in two steps: the map target and purchase flow first (the
   rally-id generalisation in `hq_table.gd` is the bulk of it), then the car-park cinematic.
   The cinematic is the only part with no functional dependency on anything else, so it can
   land last without blocking the economy.

**The dead-end rescue ships with step 5, not with the UX.** Pricing the car at 0 when stranded
and broke is a correctness fix, not polish — unrescued, any price above 4 strands ~11% of
players unrecoverably. It is part of the purchase logic itself, so it cannot be deferred to the
present-box work that comes later.

## Not yet simulated: completion-gated specials

Everything under *Simulated prices* above was measured with specials still on their
**authored star gates**. Change 3's completion thresholds (2, 4, 6, …) are **not** reflected
there, and neither is change 5's renewable Challenge income.

There is a structural reason this could not simply be flagged into the sim:
`RallyLibrary.incomplete_rallies_enterable_by` calls `rally_revealed` internally, so the
tool cannot substitute a different reveal rule without either reimplementing the query
(which would fork the logic the tool exists to exercise faithfully) or making change 3 for
real in `rally_library.gd`. Implementing change 3 first, then re-running the sim, is the
right order.

Expect two effects worth checking when that happens:

- Specials arriving much earlier changes the *shape* of the career, not just its pacing —
  the `special share` column currently sawtooths as star rungs open, and step-of-2
  thresholds will make specials a steady drumbeat instead.
- Because specials grant no car and no stars, a denser early run of them means more
  progression-neutral steps up front, which interacts badly with the already-tight early
  game (1.73 eligible rallies at rally 1).

**Cost note:** editing the special entries to add `requires_completions` changes the rally
dicts, which re-keys `OpponentCache.rally_content_fingerprint` and requires another
`./cache_all.sh` run. See *Incidental findings*.

## Simulation caveats to fix before trusting output here

`tools/sim_career.gd` currently models:

- **Stock cars only** — no upgrades, no engine swaps. So it cannot see upgrades raising
  power-to-weight into higher bands, which is a real mechanism for escaping a
  restriction band. Eligible counts are a lower bound, soft-lock rate an upper bound.
- **No damage** — never wrecks, so it cannot speak to the wreck interaction at all.

Add upgrade modelling before using the sim to set a car price, and damage modelling
before trusting it on wreck questions. **Note the meta cache**: `_meta_pair` caches by
model id, sound only because cars are stock. Adding upgrades or swaps requires re-keying
that cache on instance and state or the tool will silently report stale bands.

**The sim still derives stars** (`_stars_available` = `RallyLibrary.total_stars` −
`stars_spent`) rather than modelling change 4's ledger. That is a faithful stand-in only
because the sim's world is closed: it never re-wins a rally (so every delta equals the raw
placement) and has no Rally Challenge income. **Both assumptions break once change 5 lands** —
model the ledger explicitly before using the tool to price against renewable income.

## Incidental findings (not part of this work)

- **`OpponentCache.rally_content_fingerprint` is over-broad.** It is
  `str(rally).sha256_text()` — the whole rally dict — and feeds the lockfile key
  (`"%s|%s|%s" % [id, rally_content_fingerprint(rally), global_fingerprint()]`). So
  editing a pure progression field like `reveal_after`, which cannot possibly change a
  rival's pace, invalidates every cached opponent field for that rally. The stretched
  schedule above needed a full `./cache_all.sh` for this reason. Narrowing the hash to
  the time-affecting fields (`difficulty`, `restriction`, per-event `surface_mix`, as its
  own docstring describes) would stop this recurring. Needs one regeneration to reseat.
- **Full-suite runtime has drifted to 578 s (9.6 min)** against the ~5-minute budget in
  `CLAUDE.md`, across 156 scripts / 2299 tests. Not caused by this work.

## Still outstanding

Everything in *The coupled changes* is implemented. Two items from this spec did NOT land,
plus one measured problem now needing a decision:

1. **The Rally Challenge has no stars beat.** Change 5 awards stars correctly
   (`challenge_session.gd` → `Save.award_stars` on placement), but the challenge results
   screen still does not show the three-star reveal the rally podium does — so a star earned
   in a challenge is paid silently. `podium.gd:_show_stars` / `_reveal_stars` is the pattern
   to copy; the challenge award has no previous best, so its delta is simply the stars won.
2. **`podium.gd Stage.CAR_REVEAL` is not retired.** It is now UNREACHABLE in real play —
   nothing sets `car_reward` any more — but the stage, `_show_car_reveal`,
   `_reveal_showroom_car`, `_start_slot` and the showroom/turntable props are all still
   there, and one test still drives it through a synthetic result. Deleting it is safe and
   wants doing before the wreck-rescue mystery box is routed through the present box.
3. **The surplus sink is now a measured problem, not a projection.** At price 4 with specials
   paying stars, a career earns ~80 and buys ~20 cars from a 9-car catalogue — about 11
   duplicates, and stars go inert once the roster is complete. Options, unchanged: raise
   `GameConfig.star_cost_per_car` (8 lands near 10 purchases; 5 is validated and safe now
   that the rescue exists), or give stars a second sink such as upgrades. **This is a
   one-value change now** — the price is inspector-editable, so it needs a decision, not
   engineering.

Also unresolved from the original design: the Challenge's reward threshold is the top HALF
of the board while stars only pay to the top 3, so a mid-table "placed" finish banks zero
stars and walks away with only the boxes. Deliberate for now (the boxes are the consolation),
but worth revisiting if it reads as a non-reward.
