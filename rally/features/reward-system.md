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

`draw_upgrade(rally_difficulty, profile, rng=null) -> item_id`: pool = parts at
the target tier (stepping down to the nearest lower tier that has an authored
part, since not every tier has one) **plus the repair kit as a low-weight entry**
(`REPAIR_KIT_DROP_WEIGHT`, placeholder). Weighted pick → returns an `item_id`;
most rolls are a part, occasionally the repair kit. No ownership/slot filtering —
items land in inventory and the player chooses where to fit them.

## Car draw (per top-3 finish, including re-wins)

`draw_car(rally_difficulty, profile, rng=null) -> model_id | null`. Fires on
**every** top-3 finish (renewable supply — re-winning a completed rally re-grants
a car, still tier-clamped), which is what guarantees 100% completion stays
reachable despite permanent car destruction. Steps:

1. `target_tier` as above.
2. Candidates = `CarLibrary` models at that `reward_tier`.
3. **Anti-soft-lock filter** — keep only models eligible for ≥1 still-incomplete
   rally (`RallyLibrary.incomplete_rallies_enterable_by`), so a grant never
   wastes itself.
4. **Prefer un-owned** — draw uniformly from not-yet-owned survivors if any, else
   a duplicate of an owned one.
5. **Step down** through lower tiers if a tier's filtered set is empty; if *no*
   eligible car exists at any tier, return `null` (the caller pays out a
   high-tier upgrade instead).

The roster's starter floor (the immortal `mx5` always has a non-showdown rally in
its power band, plus the open-class showdown) independently guarantees the player
always has an enterable rally, so this filter optimises grant *quality*, not
reachability.

## Showdown

The final showdown grants no reward — winning it is the game's win/credits beat,
handled by the flow controller.

## Tests

`tests/headless/test_reward_system.gd` (injected seeded RNG): tier-ceiling
monotonic + clamped; `target_tier` never exceeds the ceiling; upgrade draws land
at the target tier with the repair kit a rare minority; car draws prefer un-owned
then fall back to a duplicate; granted cars are always eligible for an incomplete
rally; and `draw_car` returns `null` when nothing eligible remains.
