# Reward System — implementation spec  ✅ DONE

> Status: **DONE (core).** `RewardSystem` (`scripts/reward_system.gd`) implements
> the pure draw policy: `tier_ceiling` / `target_tier` clamp, `draw_upgrade`
> (target-tier parts + low-weight repair kit), and `draw_car` (anti-soft-lock
> eligibility filter, prefer-un-owned, tier step-down, null when nothing
> eligible). Static functions with an injectable RNG. Tests:
> `tests/headless/test_reward_system.gd` (7, seeded). Doc:
> `features/reward-system.md`. **Still open / deferred:** the curve values
> (`tier_ceiling` shape, `f(difficulty)` remap, `repair_kit_drop_weight`) move to
> `GameConfig` in the balance pass; the call site (per-event / per-rally trigger)
> and reveal are owned by `todo/rally-event-flow.md` + `todo/menus.md`. The draw
> functions return an id — the caller delivers via `Save.add_item`/`grant_car`.
>
> Implementation brief for the reward
> **draw policy** in `gameplay.md` › *Progression & rewards* — what the player is
> granted after an event (an upgrade) and after completing a rally (a car).
> Follow the config-first convention (`CLAUDE.md`): the tier/clamp curves are
> `GameConfig` tunables, never hardcoded. Update the relevant `features/*.md` doc
> and add tests in the same piece of work.
>
> **Three forks are decided** (with the user): car draws **prefer un-owned models,
> falling back to duplicates**; the **repair kit is a low-weight entry in the
> upgrade pool**; and items are **drawn at exactly the clamped tier**. Baked in
> below; see *Decided (kept for trace)*.

## Goal

A small set of **pure draw functions** that answer *what to grant*, given the
finishing context (rally difficulty) and the player's progress — applying the
tier ceiling and the anti-soft-lock guarantee so the grant is always fair and
never bricks the run. It does **not** own *when* rewards fire (the flow
controller, `todo/rally-event-flow.md`) or *how they're revealed* (the
menus reward-reveal rig).

## Current state (measured from the code / specs)

- **Nothing exists yet** — no draw, tier, or clamp logic anywhere.
- **The inputs it draws from are all designed:**
  - Rally `difficulty` + `RallyLibrary.incomplete_rallies_enterable_by(car_meta,
    profile)` and `completed_count(profile)` (`todo/rally-roster.md`).
  - `UpgradeLibrary.UPGRADES` with per-item `tier` and the consumable repair kit
    (`todo/upgrade-catalogue.md`).
  - `CarLibrary` models + metadata (`todo/save-persistence.md` › *Prerequisite*).
    **This spec needs one more metadata field — a car `reward_tier`** (see
    *Dependencies*).
  - The save mutators it calls to deliver a grant: `Save.add_item(item_id)` and
    `Save.grant_car(model_id)` (`todo/save-persistence.md`).
- **Reveal is already a rig, not this spec.** `gameplay.md` framed the reward as a
  lootbox/slot-machine; `todo/menus.md` rig 5 replaced that with a physical reveal.
  This spec resolves the *result*; the rig animates it.

## Tier model & the progress clamp

Both cars and upgrades carry an integer **tier** (upgrades: `UpgradeDef.tier`;
cars: a new `reward_tier`). A draw computes one **target tier**:

```
target_tier = clamp( f(rally.difficulty), 1, tier_ceiling(completed_count) )
```

- **`f(rally.difficulty)`** — default **identity** (reward tier = the rally's
  difficulty); an optional `GameConfig` remap allows decoupling later.
- **`tier_ceiling(completed_count)`** — a **monotonic** mapping from rallies
  completed → the highest tier that can drop, so an early lucky win can't yield a
  top-tier reward (`gameplay.md`: "clamped by an overall-progress ceiling").
  Mechanism here; the curve values are a `GameConfig` tunable, deferred.
- **Draw exactly at `target_tier`** *(decided)* — items are picked from the pool
  whose tier **equals** `target_tier` (predictable, legible progression). The
  only exception is the anti-soft-lock **step-down** in the car draw below, which
  is a safety fallback, not the normal path.

## Upgrade draw (per event)

`RewardSystem.draw_upgrade(rally_difficulty, profile) -> item_id`:
1. `target_tier = clamp(f(rally_difficulty), 1, tier_ceiling(...))`.
2. Pool = `UpgradeLibrary` parts with `tier == target_tier`, **plus the repair
   kit as a low-weight entry** *(decided)* — one roll per event; most of the time
   a part, occasionally the repair kit. The repair-kit weight is a `GameConfig`
   tunable (`repair_kit_drop_weight`), kept low (`gameplay.md`: repairs are rare).
3. Weighted random pick → `Save.add_item(item_id)`.

No ownership/slot filtering at draw time — upgrades land in inventory; the player
chooses where to install them (`todo/upgrade-catalogue.md`). Duplicates of a part
just stack the inventory count.

## Car draw (per rally finished top-3 — including re-wins / farming)

**The car reward fires on every top-3 finish, not only the first**
*(decided — renewable supply)*. `complete_rally` records completion once (it's
the showdown-progress metric, idempotent), but `draw_car` is called **every**
time the player places top-3 — so re-running a completed rally re-grants a car.
This is what makes the supply infinite: a wrecked car is always re-winnable, and
the player can grind any beaten rally for replacements/duplicates. **The tier
ceiling still clamps** the farmed draw (`target_tier` is unchanged on a re-win),
so farming builds breadth, not a difficulty skip. The flow controller
(`todo/rally-event-flow.md`) owns the call site; this function doesn't care
whether it's a first win or a farm.

`RewardSystem.draw_car(rally_difficulty, profile) -> model_id | null`:
1. `target_tier = clamp(f(rally_difficulty), 1, tier_ceiling(...))`.
2. **Candidates** = `CarLibrary` models with `reward_tier == target_tier`.
3. **Anti-soft-lock filter** — keep only models eligible for **≥1 still-incomplete
   rally** (`RallyLibrary.incomplete_rallies_enterable_by(car_meta, profile)`
   non-empty), so the grant always opens or maintains somewhere to race
   (`gameplay.md`).
4. **Prefer un-owned** *(decided)* — partition survivors into not-yet-owned vs
   owned; draw uniformly from the **un-owned** set if non-empty, else from the
   owned set (a duplicate). The un-owned preference is the discovery hook; the
   two unchosen starters (low `reward_tier`, open-class-eligible) naturally surface
   here early.
5. **Fallbacks** (only if step 3 leaves the tier empty):
   a. **Step down** to the nearest lower tier with a filter-passing candidate, so
      a rally win is never wasted.
   b. If *no* eligible car exists at any tier (player already owns everything
      useful), grant a **high-tier upgrade instead** so the win still pays out;
      return `null` for the car.
6. Deliver via `Save.grant_car(model_id)` → a fresh `OwnedCar` instance.

The **open-class floor** (`todo/rally-roster.md`) independently guarantees the
player is never left with zero enterable rallies, so the car draw only has to
avoid *wasting* a grant, not prevent a hard lock. **And because rewards are
farmable** (above), the car draw also can't permanently brick *completion*: a
restriction whose only eligible car was wrecked can be re-satisfied by re-winning
the rally that grants such a car (or any rally whose tier covers it). The
anti-soft-lock filter therefore optimises *quality* of a grant; it is no longer
load-bearing for reachability — renewable supply is.

## RNG & anti-savescum

Draws use a plain (unseeded) `RandomNumberGenerator`. This is safe **without**
seeded reward RNG because the flow controller persists the profile immediately
after a reward resolves (`Save.save()`), so reloading can't re-roll it — exactly
the property the save spec called out. For **tests**, the draw functions accept
an optional injected `rng` so outcomes are reproducible.

## Showdown

The final showdown grants **no reward** — winning it is the game's win/credits
beat (`gameplay.md`), handled by the flow controller, not a loot draw.

## API surface

A pure `RewardSystem` (`scripts/reward_system.gd`, `class_name RewardSystem`) —
static functions, no state beyond an internal RNG (mirrors `RallyLibrary` /
`UpgradeLibrary`, not an autoload):

```
RewardSystem.draw_upgrade(rally_difficulty, profile, rng := null) -> String        # item_id
RewardSystem.draw_car(rally_difficulty, profile, rng := null)     -> String | null # model_id
RewardSystem.tier_ceiling(completed_count) -> int
RewardSystem.target_tier(rally_difficulty, profile) -> int         # the clamp, exposed for UI/tests
```

## Dependencies

- **CarLibrary metadata** (`todo/save-persistence.md` › *Prerequisite*) — needs a
  **`reward_tier`** field per model (the one addition this spec asks of the
  metadata pass; default from a power-to-weight heuristic, overridable per car).
  Plus the restriction tags eligibility matching already uses.
- **Rally roster** (`todo/rally-roster.md`) — `difficulty`, `completed_count`,
  and the `incomplete_rallies_enterable_by` query the anti-soft-lock filter runs.
- **Upgrade catalogue** (`todo/upgrade-catalogue.md`) — the tiered `UPGRADES` pool
  and the repair-kit item.
- **Save / persistence** (`todo/save-persistence.md`) — `add_item` / `grant_car`
  deliver grants; save-after-resolve underwrites the unseeded RNG.
- **Called by** `todo/rally-event-flow.md` (the trigger) and surfaced by
  `todo/menus.md` rig 5 (the reveal).

## Testing

Headless GUT tests (`tests/headless/`), using an injected seeded `rng` for
reproducibility:
- **Clamp:** `tier_ceiling` is monotonic; `target_tier` never exceeds it even when
  `rally_difficulty` is high (early-game ceiling holds).
- **Upgrade draw:** result tier == `target_tier`; over many draws the repair kit
  appears at roughly its low weight and parts dominate.
- **Car draw — prefer un-owned:** with both owned and un-owned eligible candidates
  at tier, only un-owned are returned; when all eligible are owned, a duplicate is
  returned.
- **Anti-soft-lock filter:** a car ineligible for every incomplete rally is never
  drawn at its tier; the step-down fallback finds a lower-tier eligible car; with
  no eligible car anywhere, `draw_car` returns `null` and an upgrade is granted.
- **Invariant:** after any grant the player still has ≥1 enterable rally
  (cross-check with the roster's open-class floor test).

## Out of scope / open questions

- **Curve values** — `tier_ceiling` shape, the `f(difficulty)` remap (default
  identity), and `repair_kit_drop_weight`. Balance pass, deferred.
- **Car `reward_tier` source** — explicit per-car field vs derived from
  power-to-weight. *Proposed: explicit field defaulting from p/w* — confirm when
  the metadata pass is built.
- **Pity / streak protection** — guaranteeing variety or a repair kit after a dry
  spell; deferred until playtest shows whether it's needed.
- **Mid-event wreck** — whether an event the player wrecked out of still drops its
  upgrade; that's the flow controller's call (`todo/rally-event-flow.md`).

### Decided (kept for trace)

- **Duplicates:** prefer un-owned models; grant a duplicate only when all eligible
  models are already owned.
- **Repair kit:** a low-weight entry in the per-event upgrade pool (one roll).
- **Tier pick:** draw at exactly the clamped tier (anti-soft-lock step-down is the
  only exception).
- **Renewable supply:** the car reward fires on **every** top-3 finish, so
  re-winning a completed rally re-grants a car (clamped by the same tier ceiling).
  Completion is recorded once; the reward repeats. This guarantees 100%
  completion is always reachable despite permanent car destruction.
