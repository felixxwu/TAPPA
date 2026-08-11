# Reward System

`RewardSystem` (`scripts/reward_system.gd`, `class_name RewardSystem`) is the
reward **draw policy** — what the player is granted after an event (an upgrade
item), plus the pick + pricing policy for a car (bought with stars, or handed over
free by the wreck safety net; no rally awards one — see
[star-economy.md](star-economy.md)). Pure static functions over the
authored libraries + the save profile, with no state beyond an injected RNG
(mirrors `RallyLibrary` / `UpgradeLibrary`, not an autoload).

**Scope:** it answers *what* to grant. It does **not** own *when* a reward fires
(the flow controller, `features/rally-session.md`) or *how* it's revealed (menus
rig 5). The draw functions return an id (or `RewardSystem.NO_REWARD`, `""`, for
"nothing this time" — see below); the **caller** delivers a real id via
`Save.add_item` / `Save.grant_car` and then `Save.save()`.

Savescum-proofing does **not** come from that immediate save (a failed roll
writes nothing at all, so there'd be nothing to protect). It comes from
`rally_session.gd`'s `_event_index` / `_event_times_ms` being **pure session
state, never persisted** (`report_event_result`) — there is no mid-rally save
to reload into. Re-rolling a failed box means replaying the rally from event 1
with the damage already banked, not reloading a save.

## Tier model — a CAR-draw concept only

`UpgradeDef.tier` is **gone**; upgrades are no longer tier-gated (see
`upgrade-catalogue.md` for what replaced it). `CarLibrary`'s `reward_tier`
survives, and cars still resolve at one **target tier**:

```
target_tier = clamp( f(rally.difficulty), 1, tier_ceiling(completed_count) )
```

- `f(difficulty)` defaults to identity (reward tier = rally difficulty).
- `tier_ceiling(completed_count)` is **monotonic** (placeholder: `1 +
  completed/2`, capped at `MAX_TIER = 4`) so an early lucky win can't yield a
  top-tier reward. The curve values are a `GameConfig` tunable in the balance
  pass (deferred).
- `target_tier(rally_difficulty, profile)` exposes the clamp for UI/tests.
  `challenge_session.gd` also calls `tier_ceiling()` directly to derive
  challenge difficulty.

With no rally paying a car, nothing feeds `f(rally.difficulty)` a real difficulty any
more — `purchase_car` passes 0 and the wreck net passes the wrecked car's tier — so in
practice the clamp reduces to `tier_ceiling(completed_count)`: **progress**, not rally
difficulty, decides how good a car can be. The old "harder rally → better prize"
correlation is therefore gone from both draws; what a hard rally pays instead is more
stars (`stars_for_placement` is the same everywhere, but a harder rally is harder to
podium — and off the podium it pays the smaller finishing amount).

## Event gate (upgrades)

The best upgrades are withheld from the reward pool until the player has
**won** a specific special event, replacing the old tier walk entirely.
`UpgradeLibrary.unlocked_by_rally(id)` reads the authored gate;
`UpgradeLibrary.rally_gate_met(item_id, profile)` (`scripts/upgrade_library.gd`
→ `rally_gate_met`) returns `true` when the field is absent, else whether that
rally is recorded `completed` in `profile.rallies`. `completed` already means a
**top-3 finish** (`Save.complete_rally`), so the gate genuinely reads "was the
event won". It is keyed on a **rally id**, never on a star balance — the special
itself opens on completed ordinary rallies (`RallyLibrary.completions_required`,
see [rally-roster.md](rally-roster.md)), and the spendable star balance
([star-economy.md](star-economy.md)) gates nothing.

The gate is about **earning** a part, never about **keeping** one:
`UpgradeLibrary.apply` walks `installed_upgrades` and never consults the gate,
so a part fitted before a gate closes (or that never needed one) keeps working.

Gated parts, per the authored `UPGRADES` table: `turbo_large` →
`sp_woodland_trial`, `drivetrain_swap` (renamed "Drivetrain Conversion") →
`sp_dust_trial`, `supercharger` → `sp_lakeshore_trial`, and `nitrous` →
`the_showdown`.
See `upgrade-catalogue.md` and (for the nitrous mechanic itself)
`features/nitrous.md`.

## Upgrade draw (per event)

`RewardSystem.draw_upgrade(profile, rng=null, owned_car={}) -> String` — note
the old `rally_difficulty` parameter is **gone**, since tier no longer governs
the pool. It can return `RewardSystem.NO_REWARD` (`""`), the sentinel for "no
event reward" — see *Retiring "always pays out"* below.

Pool building goes through `_eligible_parts(profile, exclude, owned_car)`, a
**flat** filter (no tier walk) over `UpgradeLibrary.all()` that excludes:

- consumables (added separately as weighted pool entries),
- `free` parts (the ballast — always available, never a reward),
- ids already in `exclude` (fitted to the driven car — this is also what
  dedups a multi-reward rally, since the flow controller fits each won part
  before the next draw),
- parts whose per-car `UpgradeLibrary.prerequisite_met` fails (e.g. Big Turbo
  stays out until that car has Small Turbo — see
  `upgrade-catalogue.md`'s "Prerequisite gate"),
- parts whose event gate `UpgradeLibrary.rally_gate_met` fails.

**Rule, in order:**

1. While `_eligible_parts` is non-empty, award a real part — weighted pick
   over `{"id": item_id, "weight": UpgradeLibrary.pool_weight(item_id)}` for
   every eligible part, plus the engine swap token at its own low weight
   (`ENGINE_SWAP_TOKEN_DROP_CHANCE`, placeholder). This is the common case and
   must never be pre-empted by what follows.
2. Once the car is maxed (`_eligible_parts` empty) — a mystery-box roll, gated
   by `_box_gate_open`: requires `_other_car_has_room` (a box with nowhere to
   land is useless, so that failing means nothing is awarded), and only once
   `_engine_swaps_unlocked` (`RallyLibrary.engine_swaps_unlocked`) does it also
   require `_tokens_owned(profile) >= MYSTERY_BOX_TOKEN_THRESHOLD` — before
   that unlock, tokens are inert, so gating on them would be unfair, and a
   pre-unlock maxed car pays out a box **more** often, not less. When the gate
   is open, roll succeeds with probability `_box_chance = 1/(boxes_owned+1)`;
   the `+1` is load-bearing — a literal `1/owned` is undefined at 0 and equals
   1.0 at 1, so both would be certain, whereas `1/(owned+1)` gives 0→certain,
   1→1/2, 2→1/3, … a self-throttling tail.
3. Otherwise: `NO_REWARD` (`""`). No consolation token, no reveal.

The **mystery box is deliberately NOT in the weighted pool** — it is only
ever awarded by branch 2, and putting it in the pool would hand one out in
exactly the cases that gate exists to exclude.

**"Every event always awards something" is retired.** Event-gating
(`_eligible_parts`) makes a car read as maxed much earlier than the old tier
ceiling did, so keeping the always-pays-out guarantee would have degenerated
into a mystery-box firehose. The swap token remains a legitimate low-weight
**pool entry** — it still drops — but it is no longer the always-there payout
floor that backstopped every draw.

`_car_has_nothing_left(profile, owned_car)` now takes a `profile` and checks
`_eligible_parts(profile, ...)` (the **gated** pool): a car with every
*currently unlocked* part fitted counts as maxed, even though more parts may
unlock later as specials are won. `any_car_has_room(profile)` and
`pick_mystery_box_grant(profile, rng)` also route through `_eligible_parts`.

**When:** one upgrade is drawn at each **non-final event boundary** — i.e. after
events 1 and 2 of a 3-event rally, in `RallySession.report_event_result` (not once
per rally at resolve). It's **earned by finishing the event**: no top-3/placement
gate, and the part is **kept even if the player later DNFs or places poorly**. The
final event awards no upgrade (the podium reveals the **car** instead).

**Delivery:** upgrades are **car-bound** — the flow controller fits each drawn
part straight onto the driven car **disabled**
(`Save.install_upgrade(car_instance_id, item_id, false)`) and saves; a drawn
consumable goes to `Save.add_item` instead. On a `NO_REWARD` (`""`) draw, the
flow controller skips the install/append entirely and does **not** emit
`upgrade_revealed` — the standings interstitial still fires separately, so the
player goes straight to it with no reward beat. See *Savescum* above for why
none of this needs a seeded RNG.
The reward is then revealed on **that event's standings interstitial** via the
shared `UpgradeReveal` card (`scripts/upgrade_reveal.gd`) — same slot-machine
spinner as the podium, anchored to the **bottom** of the screen so it doesn't
block the car in the replay behind it — behind a **Collect reward** button that hides the
leaderboard (see `features/menus.md`). While the reel is actually animating (real
play, non-zero `podium_slot_spin_time`) a **Skip** button
(`UpgradeReveal._on_skip_pressed`) appears so impatient players can fast-forward
straight to the landed result — it kills the running tween and runs the exact
landing steps a natural finish would, so it always lands on the real won item and
every downstream finish path behaves
identically to letting the spin play out. Hidden headless / when the spin is
already instant, since there's nothing to skip. For a normal slottable part, the reveal
displays a single **Next** step: the part (already fitted disabled by the flow
controller) is confirmed with the caption "added to your garage — install it at
the next stage", and the player enables it later from the upgrades menu at the next
event (see `features/upgrade-catalogue.md`). A won part never moves to another car
and a car never holds two of the same (per-car dedup). A won **consumable** simply
lands in inventory — there is no Apply/Keep choice on the card any more, because the
only thing that ever used it was a won repair kit offering to be spent on the driven
car, and repair kits are gone. The **Drivetrain Swap** kit likewise has no
enable/disable, so the reveal installs it enabled and the player picks a
drive mode later in the garage (see `features/upgrade-catalogue.md`).

## Mystery box (drawn instead of a normal upgrade)

`UpgradeLibrary.MYSTERY_BOX_ID` (`"mystery_box"`) is a consumable, delivered
and stored exactly like the engine swap token —
`Save.add_item(MYSTERY_BOX_ID, 1)` into `profile.inventory`, stacks freely.
`Save.mystery_boxes_owned()` mirrors `engine_swap_tokens_owned()`. It's the
payoff for a fully-upgraded car: once nothing is left to gain, event rewards
stop being wasted on more swap tokens and instead occasionally gift an
upgrade to a *different* owned car.

**Resolving what it grants** — `RewardSystem.pick_mystery_box_grant(profile,
rng=null) -> Dictionary`: a pure resolver (no `Save`
mutation) that picks a uniformly random owned car — **every** car is a
candidate, the currently selected one included — among those with a
non-empty `_eligible_parts(profile, ...)` pool on the candidate, so the
recipient's own prerequisite AND star gating are respected — e.g. it won't
hand out Big Turbo before Small Turbo, or a still-gated part before its
event is won — then a uniformly random item from that pool. Returns
`{"instance_id": ..., "item_id": ...}`, or `{}` if no car has room.

There used to be a "never the car it came from" exclusion here, on the
reasoning that a box was won BY a maxed car through the rally reward loop, so
gifting back to it would be a no-op. Boxes now also arrive from the **online
Rally Challenge** (`ChallengeSession._COMPLETION_REWARD` — 2/3/4 per
Daily/Weekly/Monthly), where they are tied to no car at all, so that
assumption stopped describing anything real: it just made a box permanently
unopenable for a one-car garage. A box now fills empty slots on any owned car,
your current one included; cars with nothing left are still skipped, on
*room*, not on identity.

**Wrecked out? The box pays a CAR.** `open_mystery_box` checks
`Save.all_cars_wrecked()` **first**, ahead of the part grant: with every owned car a
write-off, a part fitted to one would be worthless, so the box grants a whole new car
via `RewardSystem.draw_car` (whose stuck-player fallback already picks something that
re-opens progression). This is the game's anti-soft-lock floor now that repair kits are
gone — see [damage.md](damage.md). The button and its label are unchanged; which of the
two outcomes you get is decided at OPEN time by the state of the garage.

**Opening it** — `Save.open_mystery_box(rng=null) ->
Dictionary` (`save_manager.gd`) is the atomic transaction: it consumes the box
(`consume_item(MYSTERY_BOX_ID, 1, false)`, no save yet — `consume_item` gained
the same trailing `do_save := true` param `add_item` already had, precisely so
this call can defer the save), then calls `pick_mystery_box_grant`, then
either `install_upgrade(recipient, item, false)` (fitted **disabled**, same
delivery model as any other per-event reward) or, if no candidate had room or
the install unexpectedly fails, leaves the box UNSPENT and returns `{}` —
either branch's call is the one save covering both the consume and the grant,
so a crash mid-sequence can't spend the box without granting anything (before
that save: nothing persisted; after: both persisted). Returns `{}` if no box
was held, else `{"fallback": bool, "item_id": String,
"recipient_instance_id": int (only when not fallback)}`.

**Reveal (HQ garage row)** — the garage action row gets a "Mystery Box (N)"
button (`hq.gd._refresh_garage_row` -> `_on_open_mystery_box`), OMITTED
entirely when no box is held and shown disabled when no car has room
(`RewardSystem.any_car_has_room`, re-checked at open-time since the garage can
change after the grant). **Order matters: check, then mutate.** Opening is an
irreversible save transaction while the reveal is a `ConfirmPopup`, which is
REFUSED while another modal is on screen (`ConfirmPopup.MODAL_GROUP`) — so
`_on_open_mystery_box` bails on `ConfirmPopup.any_open` BEFORE spending
anything. Opening first and revealing second meant a stacked press silently ate
a box and its part with nothing shown. `hq.gd._unhandled_input` carries the
same guard for the station rows generally, so no station action fires behind an
open modal. Pressing it calls `Save.open_mystery_box`
and shows a plain `ConfirmPopup` card ("You won a *item* for your *car*!" or
the wrecked-out new-car message) — deliberately **not** the race-context
`UpgradeReveal`, whose drive-mode branch assumes the revealed item
belongs to the car the player just drove, which would misfire for a gift to a
different car. See `features/upgrade-catalogue.md` for the catalogue entry and
`features/menus.md` → "Menu navigation" for the Lift's native-focus button
regime the row reuses.

## Car draw (the pick; NOT a rally reward any more)

`draw_car(profile, rally_difficulty=0, rng=null) -> model_id` is the **pick policy**
only. **No rally pays a car** — ordinary or special. Winning a rally pays stars, and
cars are bought with them at the HQ present box (see
[star-economy.md](star-economy.md) for the whole loop and the WHY: a guaranteed car
per win made the `restriction` bands meaningless and left the player no choice in
when a car arrived). `rally_session.gd`'s resolve draws no car at all now, and
`challenge_session.gd`'s `_COMPLETION_REWARD` no longer carries a `car_tier`.

Only **two** callers remain, and both are deliberate:

- `Save.open_mystery_box` — the **wreck safety net**: the one place a car is still
  free, because a player whose last car wrecked has no way to earn.
- `RewardSystem.purchase_car` — the **purchase**, so a bought car inherits the
  anti-soft-lock pick below for free. It passes `rally_difficulty = 0`, letting the
  progress clamp alone choose the tier: a purchase isn't tied to any rally.

Two paths inside the draw:

1. **Standard draw** — candidates = every `CarLibrary` model whose `reward_tier`
   is at or below the **progress-clamped draw ceiling**:
   `clamp(_difficulty_to_tier(rally_difficulty), 1, tier_ceiling(completed_count))`.
   This is now the only place `target_tier`'s clamp shape survives (the
   per-event upgrade draw dropped tier entirely — see above). So a
   higher-difficulty rally pays a better car, but only up to the tier the player's
   **progress** (rallies completed) has earned; a lucky early win at a hard rally
   can't drop a top car. This replaces the old `max(garage_tier, difficulty)` ceiling,
   which let one difficulty-2 win open the whole roster (all cars were tier ≤ 2).
   `rally_difficulty` defaults to 0 (→ tier 1 floor) for callers that don't supply it.
2. **Unlock fallback** (`_unlock_candidates`) — takes over only when the player
   is *stuck*: every rally their garage can currently enter is already completed
   (each owned car is checked on its **effective** stats via
   `UpgradeLibrary.effective_meta`, with a `floor_meta` of
   `UpgradeLibrary.max_potential_meta(car, entry, profile)` — passing `profile`
   selects the REACHABLE ceiling, event gates respected, not the aspirational
   one; see `upgrade-catalogue.md` — so the pw_min floor is judged at what the
   car can *actually* reach right now, against
   `RallyLibrary.incomplete_rallies_enterable_by`, which is reveal-aware — a rally
   counts as enterable only once **revealed** (`rally_revealed`: its `reveal_after`
   met — `rally_revealed` now applies that one rule to specials too, keyed on the
   global count of completed ordinary rallies, not a per-region concept), see
   [regions.md](regions.md)).
   That query also counts a rally the car can reach by **detuning** under its `pw_max`
   as enterable — the same definition `hq.gd._entry_plan` uses on the screen that
   actually gates entry. Judging it more strictly here made the reward system see
   phantom soft-locks and hand rescue cars to players who were never stuck. It does not
   loosen the safety net: detuning only rescues an over-CEILING car, while a real
   soft-lock is a car too weak for everything left.
   Candidates then become the models eligible for the still-locked, **revealed**
   rallies at the **lowest difficulty any catalogue car can actually enter** — e.g.
   all tier-1/2 rallies beaten with nothing new enterable ⇒ a car for a difficulty-3
   rally, never 4. A locked difficulty whose restriction bands no catalogue car fits
   is stepped past (giving up there would leave the player soft-locked even though a
   grant one difficulty up re-opens progression). This guarantees a fresh rally opens
   after every reward whenever one is openable.
3. **Exhausted-tier step-up** — the standard draw's tier is
   `min(rally_difficulty, earned_ceiling)`, so a low-difficulty rally keeps drawing the
   low-tier pool however far the player has come. The roster has **more low-difficulty
   rallies than low-tier cars** (six difficulty-1 rallies against three tier-1 cars), so
   that pool runs out and every later win hands back a car already in the garage. When
   every model at the drawn tier is owned, `draw_car` climbs a tier at a time toward the
   ceiling the player has actually EARNED until something new appears. It never exceeds
   that ceiling, so the progress clamp still holds — it only stops an exhausted pool
   turning a win into a no-op reward.
4. **Prefer un-owned** — either path draws uniformly from the not-yet-owned
   candidates when any exist, else grants a duplicate of an owned one.
5. **Never the same car twice running** — the model granted last (the newest entry in
   `profile["cars"]`, since `grant_car` appends, so there is no extra state to persist)
   is dropped from the candidates whenever doing so still leaves something to pick. A
   preference, not a filter: a single-entry pool still grants that car. Back-to-back
   duplicates read as a broken reward even where a duplicate is the honest outcome.

With every rally completed the fallback is moot and the standard draw still pays
(a duplicate at worst), so the draw never returns empty in practice (the upgrade
draw, by contrast, legitimately can — see *Retiring "always pays out"* above).

## Buying a car

The purchase API is pure over whatever profile it is handed (like `draw_car`), so the
HQ can price against the live profile and `sim_career` against a synthetic one and get
the same answer:

- `stars_available_in(profile)` — the spendable balance, mirroring
  `Save.stars_available()` but reading the dict it is given.
- `car_price(profile)` — normally `GameConfig.star_cost_per_car`. See the
  **dead-end rescue** below.
- `is_stranded(profile)` — nothing the player owns can enter any incomplete, revealed
  rally. THE shared predicate: the present box's price readout and the purchase itself
  must agree on it, or the pin would quote a price the purchase then refuses. It also
  drives `_unlock_candidates`. **Wrecked cars don't count** — a wreck can never be
  repaired, so a garage whose only in-band car is wrecked is as stuck as an empty one,
  and counting it would deny the rescue to exactly the player who needs it most. The
  `pw_min` floor is judged at `max_potential_meta(car, entry, profile)` — the
  REACHABLE ceiling, since the aspirational one would conclude nobody is ever stuck.
- `purchase_car(rng)` — buys exactly ONE car (a reveal is a moment, not a slot
  machine), mutating through `Save`. **Nothing to give = nothing spent:** the draw is
  resolved BEFORE any stars move, and the whole transaction is abandoned if it comes
  back empty — the same rule `Save.open_mystery_box` applies to a box it can't fill.

**The dead-end rescue.** `car_price` returns **0** when the player `is_stranded` AND
cannot afford a car. Without it, a stranded, broke player has no eligible rally, so no
way to earn, so no way to buy the car that would unlock one — an unrecoverable state
the old free-car model couldn't produce. **Both** halves of the condition are
load-bearing: free-whenever-merely-stranded is farmable (take the free car, finish the
rally it unlocks, be stranded again, repeat a whole career for nothing), and requiring
the player to also be BROKE closes that, because anyone making progress is earning
stars and so isn't broke. It's a rescue, not a discount.

## The LAST special won (was "the final showdown")

Winning the special that completes the set is the game's win/credits beat, handled by
the flow controller. Note the predicate
is **not** "this is the top rung": `rally_session.gd` fires `game_won` when
`RallyLibrary.is_special(_rally) and RallyLibrary.all_specials_completed(profile)`,
so it is whichever special happens to be the last one outstanding (normally the
top rung, since the rungs open in completion order, but the rule is set-completion,
not a designated finale). Every other special pays out exactly like an
ordinary rally — the per-event upgrade draws plus the placement's stars (specials
award stars now; they used to award none) — plus its own unlock, below.

## Special-event unlock (a special's own reward)

Winning a special for the **first time** opens an upgrade gate for the whole garage
(`UpgradeLibrary.rally_gate_met` reads `completed`), and now also **hands that upgrade to the
car that earned it**. The podium announces it as its own stage
(`Podium.Stage.SPECIAL_UNLOCK`, between `LEADERBOARD` and `CAR_REVEAL`).

- **First completion only.** `rally_session.gd` captures whether the rally was already
  completed **before** `Save.complete_rally` runs — afterwards the profile cannot tell a
  first win from a re-win. A re-win reveals nothing and re-awards nothing.
- **Top-3 only**, because `completed` is only recorded inside the resolve's `if top3:` branch.
  A 4th-place finish neither opens the gate nor reveals anything.
- **The grant cascades.** `RewardSystem.grant_special_unlock(car_instance_id, item_id)` walks
  DOWN the `requires_upgrade_id` chain and grants bottom-up, so the awarded part has the
  prerequisite rungs it needs on *that* car (the gate is garage-wide, but
  `prerequisite_met` is per-car). Generalised, not turbo-specific — `nitrous_shot` sits two
  rungs above `nitrous`. Cycle-guarded, so a bad authored `requires_upgrade_id` pair can't
  hang a podium.
- **Only the headline is ENABLED**; the cascaded rungs are fitted but parked. A ladder shares
  ONE slot (`turbo_small` / `turbo_large` / `supercharger` are all `slot: "turbo"`), so the
  rungs are mutually exclusive alternatives and the lower ones exist only to satisfy the
  prerequisite. `Save._enable_exclusive` enforces one-enabled-per-slot regardless.
- **Already fitted → grant nothing**, and the card says "now appears in rally rewards"
  instead of claiming a fitting. Returning a partial cascade there would leave the reveal
  naming a *prerequisite* rather than the headline.
- The card is **inverted** (light face, dark ink, no drop shadow) and deliberately **not** the
  slot-machine reel the car/upgrade reveals use: a reel implies a random draw, and this
  outcome is fixed by which special was won. Same documented house-rule-4 exception as a
  special's map pin ([ui-design-system.md](ui-design-system.md)).

**A special may gate a CAPABILITY instead of a part.** Engine swapping is authored the other
way round — `RallyLibrary.ENGINE_SWAP_UNLOCK_RALLY`, not an `unlocked_by_rally` field — so it
is not in `UpgradeLibrary`'s index and there is nothing to grant: winning the rally *is* the
unlock. It still gets the reveal (`special_unlock.capability == "engine_swap"`), which matters
because it sits on the **lowest rung**, so without it the first unlock a player ever earns
would pass in silence. It also grants **one `ENGINE_SWAP_TOKEN_ID`** immediately, so the
station is usable the moment it is announced — unlocking it and then making the player wait on
a rare drop (`ENGINE_SWAP_TOKEN_DROP_CHANCE`) would make the reveal a promise rather
than a reward. The map pin has always had this branch
(`hq.gd::_special_unlock_line`); the podium mirrors it.

The ladder order is authored, not derived — engine swaps first, then the forced-induction and
drivetrain parts, then the nitrous rungs. Two invariants are tested rather than the numbers
(they are tunable): a gated part's **prerequisite opens no later than the part itself**, or a
player reaches a part whose chain they cannot have earned; and the engine-swap capability sits
on the lowest rung. See `test_rally_library.gd`.

Carried to the podium as `last_result()["special_unlock"]` =
`{item_id, granted: [ids, headline first]}`, or `{}` for an ordinary rally, a re-win, or a
special that gates no part.

## Tests

`tests/headless/test_reward_system.gd` (injected seeded RNG): car-side
tier-ceiling monotonic + clamped; `target_tier` never exceeds the ceiling; a
part already fitted to the driven car is never drawn; a car with an unlocked
part still to win always gets it (the real-reward branch is never pre-empted);
`draw_upgrade` returns `NO_REWARD` only once a car is maxed under the gated
pool; box probability falls as boxes accumulate and is certain at zero owned;
the box branch skips the token requirement while swapping is locked and
requires it once unlocked; `_other_car_has_room` failing yields nothing rather
than a box; car draws never exceed
the **progress ceiling** (`tier_ceiling(completed_count)`) even off a top-difficulty
rally, and a low-difficulty rally caps the draw at its difficulty tier even when the
progress ceiling is high; car draws prefer un-owned before falling back to a duplicate; a stuck
player's grant opens a locked rally with a car eligible for it; and `draw_car` still
pays a real car even with everything completed (the guaranteed-reward property).
Purchase side: `car_price` charges the authored price when the player can afford it,
`purchase_car` debits exactly that and grants one car, an unaffordable purchase moves
nothing, and the rescue frees the price only when stranded AND broke (never when merely
stranded, never when merely broke) — with `is_stranded` ignoring wrecked cars.
Mystery-box coverage (synthetic cars/upgrades, per CLAUDE.md — never the real
catalogue): a maxed owned car with tokens at/above `MYSTERY_BOX_TOKEN_THRESHOLD`
and a non-maxed second car draws the box; the same maxed car draws normally
when tokens are below threshold or no other car has room (regression on the
existing fallback); `pick_mystery_box_grant` only ever targets a car with room
(a maxed car is skipped) while a one-car garage resolves onto that one car,
respecting the recipient's own prerequisite gating.
`tests/headless/test_save_manager.gd` covers `Save.open_mystery_box`'s atomic
install, its box-retained no-op (no car has room, or install fails), its new-car
grant when every owned car is wrecked, fitting a
part to your only car, and the no-box no-op. `tests/headless/test_menu_flow.gd`
covers the garage button's disabled states, that a one-car garage is openable,
and the two modal-ordering regressions (a second box is not spent behind an
open reveal; the garage row ignores select while a modal is up).
