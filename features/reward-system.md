# Reward System

`RewardSystem` (`scripts/reward_system.gd`, `class_name RewardSystem`) is the
reward **draw policy** — what the player is granted after an event (an upgrade
item) and after a top-3 rally finish (a car). Pure static functions over the
authored libraries + the save profile, with no state beyond an injected RNG
(mirrors `RallyLibrary` / `UpgradeLibrary`, not an autoload).

**Scope:** it answers *what* to grant. It does **not** own *when* a reward fires
(the flow controller, `features/rally-session.md`) or *how* it's revealed (menus
rig 5). The draw functions return an id; the **caller** delivers it via
`Save.add_item` / `Save.grant_car` and then `Save.save()`. Saving immediately
after a draw resolves is what makes the unseeded RNG savescum-proof — reloading
can't re-roll a grant (no seeded reward RNG needed).

## Tier model & the progress clamp

Both upgrades (`UpgradeDef.tier`) and cars (`CarLibrary` `reward_tier`) carry an
integer tier. A draw resolves at one **target tier**:

```
target_tier = clamp( f(rally.difficulty), 1, tier_ceiling(completed_count) )
```

- `f(difficulty)` defaults to identity (reward tier = rally difficulty).
- `tier_ceiling(completed_count)` is **monotonic** (placeholder: `1 +
  completed/2`, capped at `MAX_TIER = 4`) so an early lucky win can't yield a
  top-tier reward. The curve values are a `GameConfig` tunable in the balance
  pass (deferred).
- `target_tier(rally_difficulty, profile)` exposes the clamp for UI/tests.

## Upgrade draw (per event)

`draw_upgrade(rally_difficulty, profile, rng=null, owned_car={}) -> item_id`
checks the **mystery-box branch** first, before building the normal pool: if
`_car_has_nothing_left(owned_car)` (every non-consumable, non-`free` part this
car is eligible for at every tier up to `MAX_TIER` is already in
`installed_upgrades` — checked against the absolute ceiling, not the
progress-clamped `target_tier`, so a car isn't "maxed" just because progress
hasn't raised the tier ceiling yet) AND the player holds at least
`MYSTERY_BOX_TOKEN_THRESHOLD` engine swap tokens (`_tokens_owned(profile)`,
read straight off `profile.get("inventory", {})` the same tolerant way
`Save.engine_swap_tokens_owned()` does — `RewardSystem` never touches the
`Save` autoload) AND `_other_car_has_room(profile, owned_car)` (some other
owned car in `profile.cars` is NOT itself maxed — otherwise the box would have
nowhere to land), the draw returns `UpgradeLibrary.MYSTERY_BOX_ID` instead of
picking from the usual pool. Any one condition failing falls through to the
unchanged normal draw. This exclusion survives ONLY here, because it gates a
different question: the car being rewarded is by definition full, so a box is
only worth awarding if somewhere else can receive it. `any_car_has_room(profile)`
is the room-check exposed publicly for the HQ garage row's Mystery Box button
(re-verified at open-time, since the garage can change between grant and open)
and it excludes NOTHING — see *Opening it* below.

Otherwise: pool = parts at the target tier (stepping down to the nearest lower tier that has
an eligible part, since not every tier has one; `_parts_at_or_below` also skips
**`free` parts** — the ballast is always available, so it's never a reward —
and any part whose `requires_upgrade_id` **prerequisite isn't yet fitted to the
driven car** (per-car, not garage-wide), via `UpgradeLibrary.prerequisite_met`;
e.g. Big Turbo stays out of the pool until that car has Small Turbo — see
`upgrade-catalogue.md`'s "Prerequisite gate") **plus
the
engine swap token as a low-weight entry** (`ENGINE_SWAP_TOKEN_DROP_WEIGHT`, a
placeholder). The **mystery box is deliberately NOT in this pool** — it is awarded by
the gated branch above, and adding it here would hand out a box in exactly the cases
that gate exists to exclude. Parts **already
fitted to `owned_car`** — the driven car the flow controller passes in — are
**excluded**, so the draw never awards a part the car already carries. This
exclusion is also what dedups the multi-reward draw: the flow controller fits
each won part onto the car **before** the next draw, so re-reading the live car
each pass stops the same part being won twice in one rally. With every part
at/below the tier fitted, only the swap token remains — which is what keeps the draw
always paying out. (The retired repair kit sat in this pool too, but at weight 0, so
it never actually dropped.) Weighted pick → returns an `item_id`;
most rolls are a part, occasionally a consumable.

**When:** one upgrade is drawn at each **non-final event boundary** — i.e. after
events 1 and 2 of a 3-event rally, in `RallySession.report_event_result` (not once
per rally at resolve). It's **earned by finishing the event**: no top-3/placement
gate, and the part is **kept even if the player later DNFs or places poorly**. The
final event awards no upgrade (the podium reveals the **car** instead).

**Delivery:** upgrades are **car-bound** — the flow controller fits each drawn
part straight onto the driven car **disabled**
(`Save.install_upgrade(car_instance_id, item_id, false)`) and saves immediately
(savescum-proof); a drawn consumable goes to `Save.add_item` instead.
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
non-empty `MAX_TIER`-eligible pool (`_parts_at_or_below(MAX_TIER, ...)` on the
candidate, so the recipient's own tier/prerequisite gating is respected —
e.g. it won't hand out Big Turbo before Small Turbo), then a uniformly random
item from that pool. Returns `{"instance_id": ..., "item_id": ...}`, or `{}`
if no car has room.

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

## Car draw (per top-3 finish, including re-wins)

`draw_car(profile, rally_difficulty=0, rng=null) -> model_id`. Fires on
**every** top-3 finish (renewable supply — re-winning a completed rally
re-grants a car). It is **guaranteed** — a car is always granted. Two paths:

1. **Standard draw** — candidates = every `CarLibrary` model whose `reward_tier`
   is at or below the **progress-clamped draw ceiling**:
   `clamp(_difficulty_to_tier(rally_difficulty), 1, tier_ceiling(completed_count))`
   — the SAME progress clamp the per-event upgrade draw uses (`gameplay.md`). So a
   higher-difficulty rally pays a better car, but only up to the tier the player's
   **progress** (rallies completed) has earned; a lucky early win at a hard rally
   can't drop a top car. This replaces the old `max(garage_tier, difficulty)` ceiling,
   which let one difficulty-2 win open the whole roster (all cars were tier ≤ 2).
   `rally_difficulty` defaults to 0 (→ tier 1 floor) for callers that don't supply it.
2. **Unlock fallback** (`_unlock_candidates`) — takes over only when the player
   is *stuck*: every rally their garage can currently enter is already completed
   (each owned car is checked on its **effective** stats via
   `UpgradeLibrary.effective_meta`, with a `floor_meta` of `max_potential_meta` so the
   pw_min floor is judged at the car's max potential, against
   `RallyLibrary.incomplete_rallies_enterable_by`, which is reveal-aware — a rally
   counts as enterable only once **revealed** (`rally_revealed`: its `reveal_after`
   met, and for a showdown its own region's showdown gate open — `RegionLibrary.
   showdown_unlocked`, not a "region unlocked" concept, which no longer exists),
   see [regions.md](regions.md)).
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
(a duplicate at worst), so the reward never returns empty. The upgrade draw is
unchanged and still uses the `target_tier` clamp above.

## Showdown

The final showdown grants no reward — winning it is the game's win/credits beat,
handled by the flow controller.

## Tests

`tests/headless/test_reward_system.gd` (injected seeded RNG): tier-ceiling
monotonic + clamped; `target_tier` never exceeds the ceiling; upgrade draws land
at the target tier with the swap token a rare minority; a part already fitted to
the driven car is never drawn (the token is what's left when the car has everything); car draws never exceed
the **progress ceiling** (`tier_ceiling(completed_count)`) even off a top-difficulty
rally, and a low-difficulty rally caps the draw at its difficulty tier even when the
progress ceiling is high; car draws prefer un-owned before falling back to a duplicate; a stuck
player's grant opens a locked rally with a car eligible for it; and `draw_car` still
pays a real car even with everything completed (the guaranteed-reward property).
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
