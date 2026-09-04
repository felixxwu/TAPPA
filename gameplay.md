# Gameplay Design — "Eight stages, one clock"

> **This is a design / vision document, not an implementation spec.** It captures
> the intended game and *why* it is shaped this way. Where it names real systems
> it's to show feasibility, not to prescribe code.
>
> The settled decision record and the system-by-system design live in
> **`todo/roguelike-pivot.md`**; the order of work lives in
> **`todo/roguelike-pivot-plan.md`**. **If this file and that spec ever disagree,
> the spec wins** — it is authoritative, this file is the north star it ladders
> up to.

## Tagline & fantasy

**A rally roguelike: eight stages, one clock, no second chances.**

Pick a region, pick a car, and drive **eight point-to-point stages** back to back.
Every stage carries a target time. Beat it and you bank money and take a boost;
**miss it and the run ends on the spot**, however many stages you had left. There
is no rival field, no championship table, no placing — there is the clock, the car
you brought, and how much of that car is still working by stage six.

The pull is the roguelike ratchet. A **run** is disposable and always will be. The
**meta** is not: money, owned cars, purchased perks, purchased boost levels and
lifetime stat counters all survive a failed run untouched. You lose runs, and you
get stronger anyway. Every failure ends with a number to spend and a stat that
ticked up, so the next attempt starts from a better place than the last one.

This is a deliberate replacement for the Gran-Turismo-shaped career the game used
to describe: a garage, a world map, a rival field and a star ladder. That loop
asked the player to plan a season; this one asks them to survive an evening. It's
a smaller game with a much tighter feedback loop, and the systems it keeps —
driving, damage, tuning, cars — are the ones that were always the point.

## The run, end to end

```
title
  └─ hub (Run · Cars · Shop · Perks · Stats · Settings)
       └─ region select (linear unlock; locked regions shown, with their gate)
            └─ car select (owned cars; buy new ones with money)
                 └─ RUN START — stage 1 of 8
                      ├─ drive a drawn stage against its target time
                      │    ├─ beat it → stage cleared, money banked
                      │    └─ miss it → RUN OVER
                      ├─ between-stage pick: repair, or 1 of N random boosts
                      └─ …repeat to stage 8
                           └─ region cleared → next region unlocked
  └─ (run over, win or lose) → run summary → back to the hub
```

The run summary is **one screen for both outcomes** — cleared all eight, or
stopped by the clock. A run that ends on a missed timer has no placement to
celebrate, and the same information (stages cleared, margin per stage, money
earned, boosts taken) is worth reading either way.

### Soft permadeath — what a failed run actually costs

A failed run destroys **the run and only the run**: stage progress, every
temporary boost picked up during it, and the damage the car accumulated. It does
**not** touch money, owned cars, perks, boost levels or lifetime stats. You keep
**100% of the money you earned before you died**, and you never lose the car.

That combination is the whole design in one line. The stakes are real *within* an
evening — a stage-7 timer miss throws away the deep-run payouts you were driving
toward — while being zero *across* evenings. Nothing can brick a profile, nothing
needs an anti-soft-lock guarantee, and there is no state a bad run can leave you
in that a fresh run can't climb out of.

## The clock — the one fail state

Each stage's target time is **fixed, not car-relative**: it is computed from the
stage's own geometry against a single reference car, then scaled by a pace
tunable. Everyone's target for a given stage is the same target.

This is the decision that makes the car shop matter. If the target scaled to the
car you brought, buying a faster car would just raise the bar and buy you nothing
— the classic rubber-band trap. With a fixed target, **a faster car is
straightforwardly better**, and money spent on cars converts directly into
survivable stages. Two consequences we accept on purpose:

- **The cheapest car sets the difficulty floor.** Stage 1 has to be clearable in
  the worst car a player can own, or a bad purchase makes the game unwinnable.
  The pace tunable is calibrated against the bottom of the roster, not the middle.
- **A late-tier car will trivialise early stages.** That is the reward for owning
  it, not a bug. If it ever flattens out too far, the lever is gating car tiers by
  region — never reintroducing a car-relative target.

Difficulty escalates two ways off one tunable: the target tightens **within** a
run (stage 8 is harder than stage 1) and **across** regions (region 5 demands a
faster time on the same stage than region 1 does). No per-region difficulty
authoring, one number to tune.

**A doomed run is driven out.** There's no retire button and no "you can't make
this up" warning. Missing the timer ends the run anyway, so the worst case is one
stage of knowingly-lost driving — and dressing that up in a confirmation dialog
would cost more than it saves.

## Regions & the stage draw

Regions replace the world map entirely. **There is no map** — no pins, no fog, no
reveal geometry, no travel. Regions are a **list you pick from**, and they unlock
**linearly**: only the home region is open at the start, and clearing a region's
eighth stage unlocks the next one. A locked region is shown, greyed, with the gate
that opens it — locking hides availability, never information.

**A cleared region stays repeatable at full payout.** That's the grind valve: if
you're short of money for the car you want, you can go back and earn it. What
stops "farm region 1 forever" is that **the payout scales with region index** —
the same index that tightens the clock also raises the reward, so grinding an
early region is strictly worse per hour than pushing forward. The valve is open;
it just isn't the fast road.

**Stages are drawn from an authored pool, not generated fresh.** Every region owns
a pool of hand-authored point-to-point events (seed, turn count, surface mix,
weather), and a run draws its eight from that region's pool, seeded so a run is
reproducible for debugging. The pool floor is **16 events per region — two full
runs with no repeats** — so a run feels drawn rather than recited, and back-to-back
runs in the same region don't replay the same eight stages.

The drawn eight are **ordered by difficulty**, so stage 8 is the hardest of the
set. Escalation is felt in the road, not just in the number on the clock.

## Cars & the shop

Cars are **bought with money**, from a flat shop. Every car has a price; buying it
is permanent; the garage is simply the set of cars you own. A new player starts
with money rather than a hand-picked starter, so **the car shop is the first
screen that carries a decision** — buy the cheap thing now, or bank for something
that survives deeper.

Cars are shown as a **3D turntable**: the real model, slowly rotating, against a
plain background. The models are the game's main authored art and a flat UI must
not hide them.

There are **no eligibility restrictions**. No drivetrain gates, no country classes,
no power-to-weight bands, no "you don't own a car for this event". Any car can
enter any region. The clock is the filter — a slow car in a late region simply
loses — and that is a far more legible gate than a categorical one.

**What this gives up, stated honestly:** cars used to be *won*, at prize rallies,
with a slot-machine reveal. That was a better acquisition hook than a price list,
and with acquisition now purely transactional, **clearing a region rewards only
the next region's unlock**. We're taking that trade for the simplicity, with a
first-clear money bounty as the cheapest fix if region clears end up feeling flat.

## Damage model

Damage survives the pivot almost unchanged — it's one of the systems the pivot
exists to protect. What changes is what it *means*: damage no longer costs stars
or follows a car across a career. **It costs you the clock**, and it resets when
the run does.

- Each car has an **HP pool**. HP loss is unified on **deceleration**: a wall, a
  tree, a cliff face, a nose-first drop, a brushed bush or crowd all shed velocity,
  and that *is* the signal — nothing on the track has bespoke damage logic. It's a
  square-law (kinetic-energy) curve above a braking-proof threshold, so hard
  braking and clean landings are free, a low-speed nudge barely scratches, and a
  big hit bites hard.
- **Effects scale with damage**, and they're *audible* rather than merely slower:
  a **wheel-alignment pull** that drags the car to one side, an intermittent
  **misfire** that cuts fuel in stumbling bursts, and a **rev cap** that walks the
  usable redline down so every gear runs out early. None of it starts until health
  drops past a threshold — a scuffed car runs clean.
- **0 HP is a floor, not a fail state.** HP bottoms out at zero and the car keeps
  driving. There is no wreck, no DNF-by-damage, no "car destroyed" screen and no
  moment the game takes the wheel away. A maximally damaged engine is stumbling
  and rev-capped, not dead.
- **Damage kills you indirectly.** That's the point of keeping the floor: a wrecked
  car doesn't end the run, it makes you *slow*, and slow misses the timer. The
  failure is always the clock, and it's always something you can see coming on the
  split. (The spec also floats a direct time penalty for impacts as a second damage
  channel — same idea, more immediate.)
- **HP carries across stages within a run** and is wiped at run end. Chip damage on
  stage 2 is a debt you carry into stage 7 unless you spend a pick on repair; a new
  run always starts on a clean car.
- **Getting stuck auto-recovers for free.** Pinned, flipped or dropped into a pit
  it can't climb out of, the car is snapped back onto the road at its last good
  spot after a few seconds, with no penalty — you've already lost the time.
- **In-run feedback.** The HUD carries a live **Health** gauge (a percentage, not a
  raw HP number — "HP" reads as horsepower), a low-health warning and an impact
  cue, so the "back off or push?" call can be made in the moment rather than
  discovered at the finish.

*(Implementation: `features/damage.md`. Per-car max HP, HP-per-impact and the
degradation curves are tuning numbers, settled by playtesting.)*

## Between stages: repair or boost

Clear a stage and you get **one pick**: a **repair**, or one of a few **randomly
drawn boosts**. Nothing else happens between stages — no leaderboard, no shop, no
detour.

Making repair *compete* with a boost is what turns damage into a decision. Under
the old design repair happened automatically and damage was just a tax; here,
taking the repair costs you the boost you didn't take, and skipping it means
carrying the misfire into a tighter target. The repair also **shrinks as the run
goes on**, so late damage is genuinely threatening rather than something you can
always patch out.

Boosts are **temporary, run-scoped** multipliers on the car's physics — engine
force, grip, brakes, weight, shift time, downforce, drag. They stack over the
course of a run and are **wiped at run end**, which is what makes stage 8 feel
different from stage 1 in the car as well as on the clock.

## The meta shop: boost levels

Money buys **boost levels** in the hub shop. A level does **not** make your car
faster directly — it scales the magnitude of *future in-run picks*. Buying a level
of Engine doesn't add power; it means the engine boosts you draw during runs roll
bigger.

That indirection is the point: it keeps the run's own upgrade curve intact (you
still have to draw the boost and choose it over repair) while giving money a sink
that compounds across runs. Levels are priced exponentially with a cap, and the
shop **shows the effect range per level** — "engine boosts now roll +8–15%" rather
than a bare level number — because a level is meaningless without a live car to
compute it against.

The **engine swap** survives here as a purchasable unlock rather than a rally
prize: buy it once, then swap engines between owned cars freely. It's the one
piece of permanent per-car modification that outlives the pivot.

**What retires with this:** the entire car-bound persistent parts model — seven
slots, a parts catalogue, install-and-consume commitments, parts gated behind
winning specific rallies. Boosts replace it, and they're better suited to a
run-based game: a part you fit forever is a decision you make once, while a boost
you draw under pressure is a decision you make every stage.

## Perks & lifetime stats

**Lifetime stats** are counters that only ever grow and never reset: stages
cleared, runs started and failed, damage taken, money earned and spent, distance
driven, deepest region reached. They're the visible proof that a failed run still
moved you forward.

They're also **load-bearing**, because they gate **perks**. A perk is unlocked by
crossing a lifetime threshold, *bought* separately with money, and only a few can
be equipped at once. Their effects are the flavour layer the run loop otherwise
lacks. The shipped seven each bend one number the run already turns on: a wider
coin pickup radius, slow self-repair while driving, softer impacts, more coins per
stage, a bigger fast-completion bonus, a more generous stage target, and a bigger
base payout per stage clear.

RR's own set leans harder on *how* you drive — money for near-misses with trees or
crowds, money for drifting, a once-per-stage nitrous burst. Those want detectors
the driving sim does not have yet (a near-miss test, a sustained-drift test), so
they are the obvious direction to grow the catalogue in rather than a gap in it.

Two things follow from the unlock-then-buy shape. First, **playing unlocks perks
and money buys them** — neither alone is enough, so the perk screen always has
both a "keep playing" goal and a "keep earning" goal on it. Second, because the
gates are lifetime counters, they reward *breadth of play*: the coin-magnet perk
unlocks by clearing stages, the self-repair one by taking damage, so each gate is a
nudge toward a particular kind of play rather than a single number to grind.

The three-equipped cap keeps a build legible. Perks are a loadout, not a list of
everything you've ever bought.

## Collectables

Stages carry **coins**: pickups that boost what the stage pays.

They sit **deliberately off the racing line**. A coin on the line would be a
reward for driving well, which the fast-completion bonus already pays for; a coin
*off* the line is a **gamble against the clock**, which is the only interesting
version. Money comes mostly from finishing fast, so a detour that costs you the
target costs every remaining stage's payout too.

Two things that gamble requires:

- **Signposting is not optional.** Stages are drawn from a pool the player may
  never have driven, so a coin they can't see coming isn't a decision — it's a
  memory test. Coins get flagged far enough ahead to commit or decline (the
  pacenote strip is the natural place), and placed in clear sight.
- **Coins bank at stage clear**, not at run end. With off-line placement the
  detour already risks the run; losing the coins as well would punish the same
  gamble twice.

**Late stages will price coins out, by design.** As the target tightens with stage
and region, a detour that's affordable on stage 2 of region 1 becomes untakeable
on stage 8 of region 5. The gamble getting steeper as the run gets deeper is a
good curve — it just means late-run coin placement has to get *easier* as the
clock gets harder, or they become decorative.

## Tuning & appearance

- **Tuning** — free, reversible, per-car adjustments made before a stage: front/rear
  grip balance, brake bias, aero balance. All three axes are **ungated on every
  car** now that parts are gone; tuning is a skill expression, not a purchase.
  The start line offers **Tune Car and nothing else** — it's the one adjustment
  that's per-stage useful.
- **Appearance** — any car's **wheels** can be fitted to any owned car, free and
  ungated, with every set available from the start. No stat consequence of any
  kind. It's the hub's one non-shopping activity, and it survives precisely
  because it costs nothing and asks nothing.

Every tuning value and boost effect resolves into `GameConfig` values, never
script literals.

## The economy

**One currency: money.** Stars, placement tiers and everything built on them are
gone — a placement-shaped economy makes no sense in a game with no placements.

**Three sources:**

1. **Per-stage payout**, growing with stages cleared — so surviving deep into a run
   is where the money is, and a stage-7 death costs real value.
2. **A fast-completion bonus**, proportional to time saved against the target — the
   reason to drive well rather than merely clear.
3. **Coins**, banked at stage clear.

**Five sinks:** cars, boost levels, perks, the engine-swap unlock, and cosmetic
wheels. Against the career's single source and two sinks, that's an economy with
somewhere to go — and every sink competes with every other, which is what makes
"what do I buy?" a question worth asking after a failed run.

Money is never reset by a failed run, and there is no run-scoped second currency.
One number, always going up, always spendable.

## The hub — flat, not diegetic

The hub is **ordinary menu screens**: title, hub, region select, car select and
buy, boost shop, perks, stats, between-stage pick, run summary, settings. Every one
of them keyboard- and gamepad-navigable, with a nav test — that rule doesn't bend
for a flat UI.

The diegetic 3D hub is dropped: no camera flying between stations, no clickable
props, no garage shell, no map table, no tuning lift, no present box, no drivable
open-world hub. Menus stop being a place and become menus.

**This is a real loss and worth naming.** The 3D hub was a lot of the game's
character, and the environment, the map table, the present-box reveal and the lift
are substantial authored work being deleted rather than mothballed. What buys it:
the hub was the largest script in the project and a visible loading beat on
startup, it forced a second navigation regime that every screen had to work in,
and it was the single biggest obstacle between "we changed the loop" and "we can
play the new loop". A run-based game lives or dies on how fast you can start the
next run.

The car turntable is what keeps the art in the game. Cars remain the thing you
look at.

## The daily / weekly / monthly challenge

The rotating **Daily / Weekly / Monthly challenge** survives the pivot intact,
with its own cloud leaderboard and username. It's a run against a globally shared
seed rather than a regional draw — structurally the same object as a region run,
which is exactly why it survives: **both are "N sequential stages, no rivals, with
a fail rule"**, and they share one session type rather than two.

**One run at a time, one slot.** Starting a region run discards a paused challenge
run and vice versa, behind a confirm. Two parallel runs would need two of every
piece of run state for very little play value.

## No endgame, for now

Clearing the last region leaves every region unlocked and repeatable, and that's
where the game currently stops. No credits roll, no ascension mode, no difficulty
ladder — accepted deliberately rather than overlooked. The old design's final
showdown and its star-gated special-event ladder are both gone with the career
that framed them.

If an endgame is wanted later, the meta ratchet (perks, boost levels, lifetime
stats) is the natural surface to build it on, and a repeatable region set is a
better foundation for one than a finite map that could be exhausted.

## The decisions behind all this

**There are no open questions.** Every design question raised across the pivot's
review passes is settled, and the settled record is
**`todo/roguelike-pivot.md` › _Decisions already taken_** — that is the
authoritative list, deliberately not duplicated here so the two can't drift. Read
it for the *why* behind anything above; read
`todo/roguelike-pivot-plan.md` for the order the work happens in.

What remains genuinely open is **tuning, not design**: the pace values that set
the difficulty curve, per-car HP and impact costs, boost and perk pricing, coin
placement density, and how fast the payout grows with depth. Those are numbers to
find by playing, and they all live in `config/game_config.tres` and the authored
content tables.
