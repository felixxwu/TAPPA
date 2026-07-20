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

`draw_upgrade(rally_difficulty, profile, rng=null, owned_car={}) -> item_id`:
pool = parts at the target tier (stepping down to the nearest lower tier that has
an eligible part, since not every tier has one; `_parts_at_or_below` also skips
**`free` parts** — the ballast is always available, so it's never a reward) **plus
the repair kit and the
engine swap token as low-weight entries** (`REPAIR_KIT_DROP_WEIGHT` /
`ENGINE_SWAP_TOKEN_DROP_WEIGHT`, both placeholders). Parts **already
fitted to `owned_car`** — the driven car the flow controller passes in — are
**excluded**, so the draw never awards a part the car already carries. This
exclusion is also what dedups the multi-reward draw: the flow controller fits
each won part onto the car **before** the next draw, so re-reading the live car
each pass stops the same part being won twice in one rally. With every part
at/below the tier fitted, only the consumables (repair kit + engine swap token)
remain (the draw still always pays out). Weighted pick → returns an `item_id`;
most rolls are a part, occasionally a consumable.

**When:** one upgrade is drawn at each **non-final event boundary** — i.e. after
events 1 and 2 of a 3-event rally, in `RallySession.report_event_result` (not once
per rally at resolve). It's **earned by finishing the event**: no top-3/placement
gate, and the part is **kept even if the player later DNFs or places poorly**. The
final event awards no upgrade (the podium reveals the **car** instead).

**Delivery:** upgrades are **car-bound** — the flow controller fits each drawn
part straight onto the driven car **disabled**
(`Save.install_upgrade(car_instance_id, item_id, false)`) and saves immediately
(savescum-proof); a drawn consumable (repair kit or engine swap token) goes to
`Save.add_item` instead.
The reward is then revealed on **that event's standings interstitial** via the
shared `UpgradeReveal` card (`scripts/upgrade_reveal.gd`) — same slot-machine
spinner as the podium, anchored to the **bottom** of the screen so it doesn't
block the car in the replay behind it — behind a **Collect reward** button that hides the
leaderboard (see `features/menus.md`). For a normal slottable part, the reveal
displays a single **Next** step: the part (already fitted disabled by the flow
controller) is confirmed with the caption "added to your garage — install it at
the next event", and the player enables it later from the upgrades menu at the next
event (see `features/upgrade-catalogue.md`). A won part never moves to another car
and a car never holds two of the same (per-car dedup). A won **repair kit** lands
in inventory, but if the car you just drove is below full health
(`EngineSwap.at_full_health`) the reveal first offers a **Repair now / Save it**
choice: *Repair now* spends the just-won kit on the driven car immediately
(`Save.use_repair_kit`), *Save it* banks it for the garage. A full-health car
skips the choice and the kit just lands in inventory. The **Drivetrain Swap** kit also skips the choice — it has no
enable/disable, so the reveal always installs it enabled and the player picks a
drive mode later in the garage (see `features/upgrade-catalogue.md`).

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
   met, and for a showdown its region unlocked), see [regions.md](regions.md)).
   Candidates then become the models eligible for the still-locked, **revealed**
   rallies at the **lowest difficulty any catalogue car can actually enter** — e.g.
   all tier-1/2 rallies beaten with nothing new enterable ⇒ a car for a difficulty-3
   rally, never 4. A locked difficulty whose restriction bands no catalogue car fits
   is stepped past (giving up there would leave the player soft-locked even though a
   grant one difficulty up re-opens progression). This guarantees a fresh rally opens
   after every reward whenever one is openable.
3. **Prefer un-owned** — either path draws uniformly from the not-yet-owned
   candidates when any exist, else grants a duplicate of an owned one.

With every rally completed the fallback is moot and the standard draw still pays
(a duplicate at worst), so the reward never returns empty. The upgrade draw is
unchanged and still uses the `target_tier` clamp above.

## Showdown

The final showdown grants no reward — winning it is the game's win/credits beat,
handled by the flow controller.

## Tests

`tests/headless/test_reward_system.gd` (injected seeded RNG): tier-ceiling
monotonic + clamped; `target_tier` never exceeds the ceiling; upgrade draws land
at the target tier with the repair kit a rare minority; a part already fitted to
the driven car is never drawn (repair-kit fallback when the car has everything); car draws never exceed
the **progress ceiling** (`tier_ceiling(completed_count)`) even off a top-difficulty
rally, and a low-difficulty rally caps the draw at its difficulty tier even when the
progress ceiling is high; car draws prefer un-owned before falling back to a duplicate; a stuck
player's grant opens a locked rally with a car eligible for it; and `draw_car` still
pays a real car even with everything completed (the guaranteed-reward property).
