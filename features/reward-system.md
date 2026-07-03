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
an eligible part, since not every tier has one) **plus the repair kit as a
low-weight entry** (`REPAIR_KIT_DROP_WEIGHT`, placeholder). Parts **already
fitted to `owned_car`** — the driven car the flow controller passes in — are
**excluded**, so the draw never awards a part the car already carries. This
exclusion is also what dedups the multi-reward draw: the flow controller fits
each won part onto the car **before** the next draw, so re-reading the live car
each pass stops the same part being won twice in one rally. With every part
at/below the tier fitted, only the repair kit remains (the draw still always pays
out). Weighted pick → returns an `item_id`; most rolls are a part, occasionally
the repair kit.

**Delivery:** upgrades are **car-bound** — the flow controller fits each drawn
part straight onto the driven car **disabled**
(`Save.install_upgrade(car_instance_id, item_id, false)`) and saves; a drawn
repair kit (consumable) goes to `Save.add_item` instead. The podium's upgrade
reveal then offers an **Apply/Keep choice** per part — the part is already on the
car, so the choice is only enable-now vs enable-later: *Apply* enables it
(`Save.set_upgrade_enabled(..., true)`), *Keep* leaves it disabled to enable later
from the garage upgrades menu (see `features/upgrade-catalogue.md`). A won part
never moves to another car and a car never holds two of the same (per-car dedup);
repair kits skip the choice and just land in inventory.

## Car draw (per top-3 finish, including re-wins)

`draw_car(profile, rng=null) -> model_id`. Fires on **every** top-3 finish
(renewable supply — re-winning a completed rally re-grants a car). The rally's
*difficulty is not an input*: the draw keys off the save profile alone, and it
is **guaranteed** — a car is always granted. Two paths:

1. **Standard draw** — candidates = every `CarLibrary` model whose `reward_tier`
   is at or below the **garage tier** (`garage_tier(profile)`: the highest
   `reward_tier` among cars the player owns; 1 for an empty garage). Owning a
   tier-3 car means any tier ≤ 3 car can drop.
2. **Unlock fallback** (`_unlock_candidates`) — takes over only when the player
   is *stuck*: every rally their garage can currently enter is already completed
   (each owned car is checked on its **effective** stats via
   `UpgradeLibrary.effective_meta`, so installed upgrades count, against
   `RallyLibrary.incomplete_rallies_enterable_by`). Candidates then become the
   models eligible for the **lowest-difficulty still-locked** rallies (incomplete,
   showdown only once unlocked) — e.g. all tier-1/2 rallies beaten with nothing
   new enterable ⇒ a car for a difficulty-3 rally, never 4. This guarantees a
   fresh rally opens after every reward.
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
the garage tier and prefer un-owned before falling back to a duplicate; a stuck
player's grant opens a lowest-difficulty locked rally; and `draw_car` still pays
a real car even with everything completed (the guaranteed-reward property).
