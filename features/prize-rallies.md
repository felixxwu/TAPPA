# Prize Rallies

**Source:** `RallyLibrary` — `prize_car_id`, `prize_part_id`, `has_prize`, and the
`prize_car` field authored on `RALLIES` entries; `opening_rally_id_for`; the field pool in
`RallyLibrary._eligible_cars` / `_eligible_combos`; the award in
`rally_session.gd::_resolve` (`car_reward` / `special_unlock`); `Save.owns_model` /
`Save.grant_car`.

A **prize rally** hands over a car or a part on top of its stars. This is the whole
incentive structure of map exploration: the dark map is dotted with things you can SEE and
go and win, instead of a currency you save up to spend on a random draw.

**Cars are no longer bought or drawn.** A car is won at the one rally that awards it, or
not at all — see [star-economy.md](star-economy.md) for what stars buy instead.

## The two halves are authored differently

| | authored where | why |
|---|---|---|
| car prize | `prize_car` on the rally (a `CarLibrary` id) | nowhere else to put it — a car does not know which event awards it |
| part prize | **derived** from `UpgradeLibrary`'s `unlocked_by_rally` | the upgrade catalogue ALREADY names the rally that opens each part |

Authoring the part on both sides would be two sources for one fact, and they would drift
the first time a part was re-gated. `RallyLibrary.prize_part_id(rally)` just asks
`UpgradeLibrary.unlocked_by(rally_id)`.

`has_prize(rally)` is the union — it drives the map marker choice and the "prize rally"
wording.

## Claiming

A **podium finish** (top 3) claims the prize — the same `completed` bar that lights the map
([map-exploration.md](map-exploration.md)), so one good result advances exploration and
hands over the reward together. There is no separate "win outright" tier.

**First win only.** Both halves check `was_completed` (captured *before*
`Save.complete_rally`, which is what sets it):

- **Car** — `Save.grant_car`, guarded by `Save.owns_model` so a re-authored roster pointing
  two rallies at one car cannot mint a duplicate. Reported as `car_reward` /
  `car_reward_is_new` on the result, and hands the new instance to HQ via
  `RallySession.pending_car_reveal_instance_id` for the **present-box reveal**
  (`hq.gd::_enter_present_box`): HQ opens on a giant present in an empty car park and holds
  the player there until they open it. The podium's old `CAR_REVEAL` stage (slot reel +
  showroom turntable) is gone — it happened on the results screen, away from the garage the
  car actually arrives in. `car_reward` was deliberately the SAME pair the retired random draw
  fed, since the beat is identical and a parallel field would mean two podium code paths.
- **Part** — `RewardSystem.grant_special_unlock` fits it to the car that just earned it,
  cascading any prerequisite rungs that car is missing so the award is usable. Keyed on the
  rally having a part prize, **not** on `special`: what a rally awards is its own property
  now, and `special` is a MARKER rather than a reward tier.

Re-running a prize rally still pays stars, but mints nothing. The retired random draw fired
on re-wins too, so one easy rally farmed cars indefinitely — and it filled the garage with
something for every class by about the fifth rally, after which no `restriction` band
excluded the player from anything again (simulation confirmed `revealed` and `eligible`
were identical from rally 5 on).

**Part discovery needs no new save state.** `UpgradeLibrary.rally_gate_met` already reads
"is the gating rally completed", and `complete_rally` has just recorded exactly that. One
fact, one place — the same reasoning as the fog storing nothing.

## The prize tops the band

A car-unlock rally draws its field **exactly like any other rally** — from every car+engine
combo its `restriction` admits. The prize is advertised through the **band** instead: a
prize rally's `pw_max` sits just above its own car, so that car is the fastest thing
admitted and turns up in the field as the one to beat.

This replaced a **one-make grid** — `_eligible_cars` / `_eligible_combos` short-circuiting
to the prize car on its stock engine, with the rally's own `restriction` ignored for the
field. That advertised the prize plainly, but made every grid a row of identical cars and
threw away the engine-swap variety the combo pool exists for.

Removing it exposed a defect the short-circuit had been hiding: **several rallies excluded
the very car they award** (the 911's and the XJS's bands started above their own cars; the
Acty's demanded a hatch when the Acty is a kei; the Island GP demanded a GB car for a US
Viper). Invisible while the field bypassed the restriction — and fatal once a player
*starts* in a prize rally ([opening-rally](../todo/opening-rally.md)).
`test_a_car_prize_tops_the_band_of_the_rally_that_awards_it` now enforces both halves.

Watch the reachability consequence: a band tight around its own prize can make that prize
its **own prerequisite** (roadster-only Island GP meant only a Viper owner could win the
Viper). `tools/sim_career.gd` is what catches it — run it after retuning a prize band.

`prize_car` remains part of `OpponentCache.FIELD_DETERMINANTS`: it no longer swaps the
field wholesale, but it is still what a band is tuned around, and a field cached under the
wrong pairing is the dangerous direction — the cache hits instead of missing.

## Shipped content guards

In `test_rally_library.gd`, none pinning which rally awards what:

- `test_a_rallys_car_prize_is_a_real_catalogue_car` — a prize naming a missing car would
  hand over nothing, silently.
- `test_no_two_rallies_award_the_same_car` — a car won twice wastes a prize rally and
  leaves another car unreachable.
- `test_every_starter_car_opens_in_a_rally_that_admits_it` — each starter's own event
  exists, is lit from the start, and admits the car it awards. A starter's prize rally is
  no longer a dead reward: it is where that player's career begins.
- `test_every_non_starter_car_is_winnable_somewhere` — with buying gone, a car with no
  prize rally is content the player can never own. Adding a car fails this until it is
  given an event.
- `test_a_part_prize_is_derived_from_the_upgrade_catalogue` — the two sides agree because
  there is only one side.
- `test_a_car_prize_tops_the_band_of_the_rally_that_awards_it` — the prize is admitted by
  its own rally and nothing eligible out-guns it.
- `test_a_car_unlock_rally_draws_its_field_like_any_other` /
  `test_a_prize_rallys_restriction_governs_its_field` — carrying a prize buys no exemption
  from the restriction.

Award behaviour lives in `test_rally_session.gd` (first win hands it over, a re-win mints
no duplicate, an ordinary rally hands over nothing).

## Related

[map-exploration.md](map-exploration.md) (what lights the map, and why prizes are the
incentive to explore), [reward-system.md](reward-system.md),
[upgrade-catalogue.md](upgrade-catalogue.md) (`unlocked_by_rally`, the prerequisite
ladders), [star-economy.md](star-economy.md), [rally-roster.md](rally-roster.md).
