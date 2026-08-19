# Reward System

`RewardSystem` (`scripts/reward_system.gd`, `class_name RewardSystem`) is the
reward **policy** — the car tier ladder (`draw_car` / `target_tier`, which the
authored prize cars are pitched against — see
[prize-rallies.md](prize-rallies.md)) and the special-event part unlock a special
hands to the car that earned it. Pure
static functions over the authored libraries + the save profile, with no state
beyond an injected RNG (mirrors `RallyLibrary` / `UpgradeLibrary`, not an
autoload).

**Tests:** `tests/headless/test_reward_system.gd`

**Scope:** it answers *what* to grant. It does **not** own *when* a reward fires
(the flow controller, `features/rally-session.md`) or *how* it's revealed (the
podium). The draw functions return an id; the **caller** delivers it via
`Save.grant_car` / `Save.install_upgrade` and then `Save.save()`.

## Where a NEW end-of-rally reward goes — two named seams

`RallySession._resolve_results()` (`scripts/rally_session.gd`) does not have one
reward block any more. It has **two**, and adding a reward means picking the one
whose *gate* you want:

| Seam | Gate | What lives there today |
|---|---|---|
| `_award_podium_rewards(combined, placed, opening_first)` | top-3 finish, **or** the opening rally's first attempt | stars (`Save.record_podium_rally`), the prize car, special/part unlocks, the game-won beat |
| `_award_any_finish_bonus_stars(combined, placed)` | **any** non-DNF finish | *nothing yet — returns `0`; this is the empty seam* |

`_award_podium_rewards` returns a `Dictionary` of fields for the `rally_finished`
result. `_award_any_finish_bonus_stars` returns an **`int`** — bonus stars, nothing
else. It is called **after** the podium gate has closed, and `_resolve_results`
(the caller) both pays it with `Save.award_stars` and folds it into `stars_gained`
*before* the result dict is built. The seam itself stays pure: do not touch `Save`
in it.

### `stars_gained` is the ONLY star channel the podium reads

`podium.gd::_show_stars` reads exactly two keys off the finish result:
`star_rating` (gold-star rating) and `stars_gained` (what the ledger moved by).
**Nothing else.** A bonus reported under a new key — `stars_bonus`,
`clean_run_stars`, anything — is credited to the save ledger and is *invisible to
the player*, which is why the any-finish seam returns a bare `int` that can only
land in `stars_gained`.

Belt and braces: the result also has an allowlist. `RallySession.RESULT_FIELDS`
lists every key the finish result may carry, and `_merge_result_fields` (the one
merge point, fed by the non-star `_award_any_finish_fields` seam) `push_error`s and
drops any key outside it — so an invented channel announces itself on the first
headless run instead of vanishing. Adding a genuinely new result field means adding
it to `RESULT_FIELDS` **and** to the UI that displays it.

This split exists because everything used to sit inside a single ~60-line
`if podium_or_opening:` block, so any reward added anywhere near the reward logic
silently inherited the **podium gate** — including rewards that were never meant to
be podium-only. A reward that should pay for *any* finish (a clean-run bonus, a
stage-record bonus, a finisher's payout) goes in `_award_any_finish_bonus_stars`, not
in the podium method.

If your reward needs to know whether the run was clean, ask
`RallySession.took_damage_this_rally()` (or the result's `took_damage` field) —
**never** the car's HP, which field repairs and already-damaged entries make
meaningless; see [damage.md](damage.md) → *HP is NOT a damage oracle*.

## There is no per-event random upgrade draw any more

`RewardSystem.draw_upgrade` / `draw_and_grant_upgrade` / `_eligible_parts` are
**gone**, and so is every consumable they used to pay out. The reasoning ran in
two steps:

1. Parts left the pool first, because a stage-by-stage drop undercut both
   deliberate routes to a part — why go and win a turbo, or pay stars for one, if
   it might fall out of the next stage? That left the draw paying only
   consumables: the mystery box and the engine swap token.
2. Both consumables were then deleted (below), so the draw could only ever pay
   **nothing**. A coin flip with no faces isn't a reward beat, it's a pause.

With it went `RallySession._event_upgrade` / its `upgrade_revealed` signal /
`current_event_upgrade()`, `ChallengeSession._stage_upgrade` / `stage_upgrade()`,
and the **reward-reveal rung of the post-stage parade** in `standings.gd`
(`_collect_reward` / `_reward_pending` / `_stage_upgrade` / `_reveal`). The
interstitial ladder is now strictly two rungs: **local standings → world
standings → resume**.

The `UpgradeReveal` **class** (`scripts/upgrade_reveal.gd`) survives — the podium
still uses its statics to drive the slot reel — it just no longer hosts a rung of
its own between stages.

### The Mystery Box is gone

`UpgradeLibrary.MYSTERY_BOX_ID` and its catalogue entry, `Save.open_mystery_box`,
`Save.mystery_boxes_owned`, `RewardSystem.pick_mystery_box_grant` /
`_box_gate_open` / `_box_chance` / `_boxes_owned` / `any_car_has_room` /
`_car_has_nothing_left` / `_other_car_has_room`, `GameConfig.mystery_box_throttle`,
`hq.gd::_on_open_mystery_box` and the garage-row Mystery Box button are all
deleted.

The box was a *random* route to a part, and parts are now **buyable with stars at
any time** from the upgrades grid's slot popups (see
[star-economy.md](star-economy.md) → *Part copies*). Once the player can simply
go and get the part they want, a box that opens onto an arbitrary one has nothing
left to offer: it is strictly worse than the stars it displaced. It also had a
second job once — a free car when every car was a write-off — and that job
disappeared when damage stopped being able to wreck a car at all: HP bottoms out
at 0 and the car keeps driving, just slowly (see [damage.md](damage.md)).

### The Engine Swap Token is gone; swapping is FREE and UNLIMITED

The id, its catalogue entry, `Save.engine_swap_tokens_owned`, the `consume_item`
inside `Save.swap_engines` and the `"Needs token"` branch of
`UpgradeOptions.engine_swap_blocked_reason` are all deleted.

**The rally unlock is the whole gate now.** Winning
`RallyLibrary.ENGINE_SWAP_UNLOCK_RALLY` turns swapping on permanently, and from
then on the player may swap as often as they like at no cost. A per-use
consumable on top of that unlock made the capability read as a teaser — you were
told you could swap engines, then metered on a currency that only fell out of a
random draw. With the draw gone there was no way to earn another token at all, so
the token had to go with it rather than become a one-shot. See
[engine-swap.md](engine-swap.md).

### Persistence: no migration, no version bump

Existing profiles may still hold retired consumables in `inventory`.
`SaveManager._sanitise` simply **erases** a `RETIRED_ITEM_IDS` list
(`repair_kit`, `mystery_box`, `engine_swap_token`) from `inventory` on load, and
`SCHEMA_VERSION` is deliberately **not** bumped — the same tolerant approach the
repair kit already used. A bump makes older builds refuse the profile outright,
and cloud save moves one profile between builds, so a removal that costs the
player nothing must not be expressed as an incompatibility. Nothing else reads
those ids, so a stale count would be inert anyway; erasing it just stops it
lingering in the file forever. See
[save-persistence.md](save-persistence.md).

## Tier model — a CAR-draw concept only

`UpgradeDef.tier` is **gone**; upgrades are not tier-gated (see
`upgrade-catalogue.md` for what replaced it). `CarLibrary`'s `reward_tier`
survives, and cars still resolve at one **target tier**:

```
target_tier = clamp( f(rally.difficulty), 1, tier_ceiling(podium_count) )
```

- `f(difficulty)` defaults to identity (reward tier = rally difficulty).
- `tier_ceiling(podium_count)` is **monotonic** (placeholder: `1 +
  completed/2`, capped at `MAX_TIER = 4`) so an early lucky win can't yield a
  top-tier car. The curve values are a `GameConfig` tunable in the balance
  pass (deferred).
- `target_tier(rally_difficulty, profile)` exposes the clamp for UI/tests.
  `challenge_session.gd` also calls `tier_ceiling()` directly to derive
  challenge difficulty.

With no rally paying a car, nothing feeds `f(rally.difficulty)` a real difficulty
any more — nothing calls it with a real one — so in practice the clamp reduces to
`tier_ceiling(podium_count)`: **progress**, not rally difficulty, decides how
good a car can be. What a hard rally pays instead is more stars
(`stars_for_placement` is the same everywhere, but a harder rally is harder to
podium — and off the podium it pays the smaller finishing amount).

## Event gate (upgrades)

The best upgrades are withheld until the player has **won** a specific special
event. `UpgradeLibrary.unlocked_by_rally(id)` reads the authored gate;
`UpgradeLibrary.rally_gate_met(item_id, profile)` (`scripts/upgrade_library.gd`
→ `rally_gate_met`) returns `true` when the field is absent, else whether that
rally is recorded `completed` in `profile.rallies`. `completed` already means a
**top-3 finish** (`Save.record_podium_rally`), so the gate genuinely reads "was the
event won". It is keyed on a **rally id**, never on a star balance — the special
itself opens geometrically off the map (see [rally-roster.md](rally-roster.md)),
and the spendable star balance ([star-economy.md](star-economy.md)) gates
nothing.

The gate now decides what the player may **BUY** — it is the shop's discovery
rule (`Save.can_buy_part`, see [star-economy.md](star-economy.md)) rather than a
filter on a draw pool. Alongside it sits the per-car **prerequisite** gate
(`UpgradeLibrary.prerequisite_met` — Big Turbo stays out until that car has Small
Turbo; see `upgrade-catalogue.md`). Those two gates outlived the draw that
originally motivated them, and are now the only things standing between a star
balance and a part.

The gate is about **earning** a part, never about **keeping** one:
`UpgradeLibrary.apply` walks `installed_upgrades` and never consults the gate,
so a part fitted before a gate closes (or that never needed one) keeps working.

See `upgrade-catalogue.md` for which parts are gated by which special, and (for
the nitrous mechanic itself) `features/nitrous.md`.

## Car draw (the pick; NOT a rally reward)

`draw_car(profile, rally_difficulty=0, rng=null) -> model_id` is the **pick
policy** only — it never grants anything itself. **No rally draws a car at
random.** A car is won at the rally that ADVERTISES it: `rally_session.gd`'s
resolve reads `RallyLibrary.prize_car_id(_rally)` and grants that authored model
on a first win, so what the player owns is exactly what they went out and won
(see [prize-rallies.md](prize-rallies.md)). `challenge_session.gd`'s
`_COMPLETION_REWARD` carries no `car_tier` either.

That leaves `draw_car` with **no live caller** — it survives as the definition of
the tier ladder (and is exercised directly by its tests), because the clamp shape
below is the thing the car ladder is authored against. The mystery box's wreck
safety net was its last caller; the box is gone, and so is the thing it rescued —
damage can no longer wreck a car at all.

Two steps inside the draw:

1. **Standard draw** — candidates = every `CarLibrary` model whose `reward_tier`
   is at or below the **progress-clamped draw ceiling**:
   `clamp(_difficulty_to_tier(rally_difficulty), 1, tier_ceiling(podium_count))`.
   This is the only place `target_tier`'s clamp shape survives. So a
   higher-difficulty input pays a better car, but only up to the tier the player's
   **progress** (rallies PODIUMED — top-3, see RallyLibrary.podium_count) has earned. This replaces the old
   `max(garage_tier, difficulty)` ceiling, which let one difficulty-2 win open the
   whole roster (all cars were tier ≤ 2). `rally_difficulty` defaults to 0 (→ tier
   1 floor) for callers that don't supply it.
2. **Exhausted-tier step-up** — the standard draw's tier is
   `min(rally_difficulty, earned_ceiling)`, so a low input keeps drawing the
   low-tier pool however far the player has come, and that pool runs out. When
   every model at the drawn tier is owned, `draw_car` climbs a tier at a time
   toward the ceiling the player has actually EARNED until something new appears.
   It never exceeds that ceiling, so the progress clamp still holds — it only
   stops an exhausted pool turning a purchase into a no-op.
3. **Prefer un-owned** — either path draws uniformly from the not-yet-owned
   candidates when any exist, else grants a duplicate of an owned one.
4. **Never the same car twice running** — the model granted last (the newest entry
   in `profile["cars"]`, since `grant_car` appends, so there is no extra state to
   persist) is dropped from the candidates whenever doing so still leaves something
   to pick. A preference, not a filter: a single-entry pool still grants that car.
   Back-to-back duplicates read as a broken reward even where a duplicate is the
   honest outcome.

The standard draw always pays (a duplicate at worst), so the draw never returns
empty in practice.

## Cars are not bought either

`car_price` / `purchase_car` and `GameConfig.star_cost_per_car` are gone — see
the comment block above `stars_available_in` in `reward_system.gd`. Stars buy
repairs and copies of discovered parts, nothing else
([star-economy.md](star-economy.md)). `stars_available_in(profile)` survives as
the pure mirror of `Save.stars_available()`, reading the dict it is handed so this
whole module stays pure over a profile the way `draw_car` is.

There is **no dead-end rescue**. Entry requirements are purely categorical (see
the car-performance rating design), so no build can be too slow to enter
anything, and reachability is a CONTENT invariant proven over the map rather than
a runtime discount or a rescue draw.

## The LAST special won (was "the final showdown")

Winning the special that completes the set is the game's win/credits beat, handled
by the flow controller. Note the predicate is **not** "this is the top rung":
`rally_session.gd` fires `game_won` when
`RallyLibrary.is_special(_rally) and RallyLibrary.all_specials_completed(profile)`,
so it is whichever special happens to be the last one outstanding (normally the
top rung, since the rungs open in completion order, but the rule is set-completion,
not a designated finale). Every other special pays out exactly like an ordinary
rally — the placement's stars (specials award stars now; they used to award none) —
plus its own unlock, below.

## Special-event unlock (a special's own reward)

This is the game's ONE remaining reward draw of a part, and it is not random at
all: which part you get is fixed by which special you won. Winning a special for
the **first time** opens the buy/earn gate for the whole garage
(`UpgradeLibrary.rally_gate_met` reads `completed`), and also **hands that upgrade
to the car that earned it**. The podium announces it as its own stage
(`Podium.Stage.SPECIAL_UNLOCK`, between `LEADERBOARD` and `CAR_REVEAL`) via
`podium.gd::_show_special_unlock`.

- **First completion only.** `rally_session.gd` captures whether the rally was
  already completed **before** `Save.record_podium_rally` runs — afterwards the profile
  cannot tell a first win from a re-win. A re-win reveals nothing and re-awards
  nothing.
- **Top-3 only**, because `completed` is only recorded inside the resolve's
  `if top3:` branch. A 4th-place finish neither opens the gate nor reveals
  anything.
- **The grant cascades.** `RewardSystem.grant_special_unlock(car_instance_id,
  item_id)` walks DOWN the `requires_upgrade_id` chain and grants bottom-up, so the
  awarded part has the prerequisite rungs it needs on *that* car (the gate is
  garage-wide, but `prerequisite_met` is per-car). Generalised, not turbo-specific
  — `nitrous_shot` sits two rungs above `nitrous`. Cycle-guarded, so a bad authored
  `requires_upgrade_id` pair can't hang a podium.
- **Only the headline is ENABLED**; the cascaded rungs are fitted but parked. A
  ladder shares ONE slot (`turbo_small` / `turbo_large` / `supercharger` are all
  `slot: "turbo"`), so the rungs are mutually exclusive alternatives and the lower
  ones exist only to satisfy the prerequisite. `Save._enable_exclusive` enforces
  one-enabled-per-slot regardless.
- **Already fitted → grant nothing**, and the card says the part is now available
  instead of claiming a fitting. Returning a partial cascade there would leave the
  reveal naming a *prerequisite* rather than the headline.
- The card is **inverted** (light face, dark ink, no drop shadow) and deliberately
  **not** the slot-machine reel the car reveal uses: a reel implies a random draw,
  and this outcome is fixed by which special was won. Same documented
  house-rule-4 exception as a special's map pin
  ([ui-design-system.md](ui-design-system.md)).

**A special may gate a CAPABILITY instead of a part.** Engine swapping is authored
the other way round — `RallyLibrary.ENGINE_SWAP_UNLOCK_RALLY`, not an
`unlocked_by_rally` field — so it is not in `UpgradeLibrary`'s index and there is
nothing to grant: **winning the rally IS the unlock, and swapping is free and
unlimited from that moment on.** It still gets the reveal
(`special_unlock.capability == "engine_swap"`), which matters because it sits on
the **lowest rung**, so without it the first unlock a player ever earns would pass
in silence. The announcement carries `granted: []` — there is no item and, since
the swap token was retired, no consumable either; the capability itself is the
whole reward, which is exactly why it needs no top-up to be usable the moment it
is announced. The map pin has always had this branch
(`hq.gd::_special_unlock_line`); the podium mirrors it.

The ladder order is authored, not derived — engine swaps first, then the
forced-induction and drivetrain parts, then the nitrous rungs. Two invariants are
tested rather than the numbers (they are tunable): a gated part's **prerequisite
opens no later than the part itself**, or a player reaches a part whose chain they
cannot have earned; and the engine-swap capability sits on the lowest rung. See
`test_rally_library.gd`.

Carried to the podium as `last_result()["special_unlock"]` =
`{item_id, granted: [ids, headline first]}`, or `{}` for an ordinary rally, a
re-win, or a special that gates no part.

## Tests

`tests/headless/test_reward_system.gd` (injected seeded RNG) — car-side only now,
plus the two gates:

- tier-ceiling monotonic + clamped; `target_tier` never exceeds the ceiling;
- car draws never exceed the **progress ceiling**
  (`tier_ceiling(podium_count)`) even off a top-difficulty input, and a low
  input caps the draw at its own tier even when the progress ceiling is high;
- car draws prefer un-owned before falling back to a duplicate, never repeat the
  previous grant while an alternative exists, and an exhausted tier steps up;
  `draw_car` still pays a real car with everything completed (the
  guaranteed-reward property);
- the rally eligibility query (an unrevealed special is excluded; it opens once
  the map is lit out to it) and `grant_special_unlock`'s cascade — the prerequisite
  rungs are granted, only the headline is enabled, a bottom rung grants only
  itself, an already-fitted part reports nothing, and a prerequisite cycle
  terminates;
- **the two part gates, asserted directly against `UpgradeLibrary`** —
  `test_a_prerequisite_gate_opens_only_once_the_car_has_the_earlier_rung` and
  `test_a_star_gated_part_is_refused_until_its_event_is_won`. They used to be
  observed indirectly, through what the draw pool filtered out; with the draw gone
  they are asserted on the predicates themselves, because those predicates now
  decide what the player can BUY.

Every mystery-box and swap-token test — the box probability curve, the
token-threshold gate, `_other_car_has_room`, `pick_mystery_box_grant`'s recipient
choice, `Save.open_mystery_box`'s atomic install and its box-retained no-op, and
the HQ garage-row button's disabled states and modal-ordering regressions in
`test_menu_flow.gd` — was **deleted with the mechanism**.
