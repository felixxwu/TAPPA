# Reward System

`RewardSystem` (`scripts/reward_system.gd`, `class_name RewardSystem`) is what's
left of the reward **policy** after `todo/roguelike-pivot.md` decisions 21 and 28:
the special-event part unlock a special hands to the car that earned it. A pure
static function over the authored libraries + the save profile, with no state
beyond what it's handed (mirrors `RallyLibrary` / `UpgradeLibrary`, not an
autoload).

**Tests:** `tests/headless/test_reward_system.gd`

## What used to live here and is now gone

- **The car draw** (`draw_car`, `target_tier`, `tier_ceiling`,
  `_difficulty_to_tier`, `MAX_TIER`, `highest_owned_tier`,
  `_cars_at_or_below_tier`, and the pick helpers `_pick_prefer_unowned` /
  `_all_owned` / `_last_granted_model_id` / `_owned_model_ids` / `_ensure_rng`).
  Car acquisition is a money shop now (decision 28), not a rally-win draw or a
  tier-clamped random pick — `RallyLibrary.prize_car_id`, the thing the draw's
  tier ladder was pitched against, is itself neutered (its backing `prize_car`
  field is deleted off every `RALLIES` entry; see that function's own comment in
  `rally_library.gd` for why the accessor survives as an always-`""` stub rather
  than being deleted outright).
- **`stars_available_in`**. The star ledger it mirrored is deleted outright
  (decision 21) — see `Save._default_profile()`'s "Star ledger: DELETED" note.
- Everything upstream of both of those was *already* gone before this pass: no
  per-event random upgrade draw, no mystery box, no engine-swap token, no
  purchasable car price. See the pivot doc's Economy section for what replaces
  stars (RR-style money — per-stage payout, a fast-completion bonus, mid-stage
  coins) and car acquisition (a shop with a `cost` per `CarLibrary` entry).

## What survives: the special-event part unlock

`RewardSystem.grant_special_unlock(car_instance_id, item_id) -> Array` is
untouched — it is parts-model machinery (a later wave's territory), not
prize/star machinery, so this pivot leaves it exactly as it was:

- Grants the part a special's unlock names to the car that just won it,
  cascading DOWN the `UpgradeLibrary.requires_upgrade_id` chain so the award is
  usable on that car (a per-car prerequisite ladder sits alongside the
  garage-wide `UpgradeLibrary.rally_gate_met` gate).
- Returns the ids granted, **headline first**, or `[]` when nothing was (already
  fitted, or `item_id` empty/unknown).
- The headline is fitted **enabled**; cascaded prerequisite rungs are fitted
  **disabled** (a ladder shares one slot, so the rungs are mutually exclusive
  alternatives — `Save._enable_exclusive` enforces one-enabled-per-slot anyway).
- A consumable (none in the shipped catalogue) would be added to inventory
  instead of fitted.

`RewardSystem.NO_REWARD` (`""`) is the sentinel for "nothing was awarded this
event" — callers must not install it, append it to a won list, or fire a reveal.

**Caller today:** `Save._grant_rally_prizes` (the dev cheat's mirror of the real
award path — see `dev_three_star_rally`). The real gameplay caller is whatever
the pivot's `RunSession` stage-clear path becomes; it does not exist yet.

## Event gate (upgrades) — unaffected by this pivot

`UpgradeLibrary.unlocked_by_rally(id)` authors the gate; `rally_gate_met(item_id,
profile)` (`scripts/upgrade_library.gd`) returns `true` when the field is absent,
else whether that rally is recorded `completed` in `profile.rallies`.
`completed` is written by `Save.record_podium_rally` (a top-3 finish) — that
bookkeeping SURVIVES the star-ledger deletion (only the star-crediting half of
that function was removed; see its own comment). The gate decides what the
player may **buy** (`Save.can_buy_part`), not what a draw pool contains — there
is no draw pool. Alongside it sits the per-car prerequisite gate
(`UpgradeLibrary.prerequisite_met`). See `features/upgrade-catalogue.md`.

## Stale cross-references pending the stage-9 features/ audit

Earlier versions of this doc described a `draw_car` / tier-ladder system, a
`podium.gd` reveal stage, and a `rally_session.gd` resolve path — all deleted in
earlier demolition waves before this one. `todo/roguelike-pivot.md` decision 40
schedules a full audit of all `features/` docs in stage 9; this rewrite only
straightens what this pass itself touched (`reward_system.gd`,
`RallyLibrary.prize_car_id` / the star ledger). Anything below this doc's own
scope — how a reward reaches the player once `RunSession` exists — is stage 9's
job, not this one's.
