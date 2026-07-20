# Rally progression rebalance

Grounds the fix for the six progression "leaps" found in the career analysis into
concrete, implementation-ready changes. The **goal** is the design invariant from
`gameplay.md` ("Progression & rewards" / "World map & rallies"): **at any point the
player has ~1–2 new incomplete rallies they can meaningfully enter** — a steady
ladder, no dumps, no RNG cliffs.

> Status: spec / not yet implemented. Numbers below are the **proposed authored
> values** (tunable content in `RALLIES` / `CarLibrary`); the *mechanisms* are the
> real deliverable. Per `CLAUDE.md`, tests must pin the LOGIC, never these numbers.

## The six leaps (why we're doing this)

Derived p/w figures (hp/tonne, `CarLibrary.power_to_weight` × `KW_KG_TO_HP_TONNE`):
Acty ~59, Twingo ~82, Focus ~114, MX-5 ~159, XJS ~175, Charger ~216, 911 ~220,
Viper ~264, Beast ~350.

1. **Starter over-exposed.** No p/w floor (`ineligibility_reason` checks only
   `pw_max`, `rally_library.gd:317`), so the mid-power MX-5 (159) is *eligible* for
   5 of 8 home rallies at turn one. Player sees 5 pins, not 1–2.
2. **Car tiers toothless + no progress clamp.** Every `reward_tier` in `CARS` is 1
   or 2, and `RewardSystem.draw_car` (`reward_system.gd:111-117`) clamps by
   `max(garage_tier, rally_difficulty)`, NOT by `completed_count` as `gameplay.md`
   promises. So one difficulty-2 win unlocks the whole roster — a d2 rally can drop
   the Beast (350).
3. **Coastal ≡ Shakedown.** `pw_max` 210 vs 180 admit the identical 5-car set (no
   car sits between XJS 175 and Charger 216).
4. **Single-car rallies.** American Muscle (`country`+`car_type`+`pw_max`, `rally_library.gd:157`)
   fields only the Charger; Grand Tour's well-fit band is Beast-only; Heavy Hitters'
   is Viper-only.
5. **Region dump.** `hq.gd._refresh_map_pins` (`hq.gd:434`) makes a pin for every
   `RegionLibrary.rallies_in(region_id)` with `locked` gating only the showdown
   (`hq.gd:523`). A region opens with the player's full garage, so all its
   non-showdown rallies are enterable at once (Greece = 3 in one go).
6. **Acty dead-ends.** At 59 hp/t AWD it's below Sh*tbox Cup's warn floor and its
   AWD excludes it from the themed rallies — well-fit for nothing.

## Mechanism 1 — bands (`pw_min` alongside `pw_max`)

Make the p/w gate a **band**, not a ceiling. A car must sit inside `[pw_min, pw_max]`
to make a rally enterable.

- **`rally_library.gd` `ineligibility_reason`**: after the existing `pw_max` block
  (`:316-318`), add the floor:
  ```gdscript
  if r.has("pw_min") and pw < float(r["pw_min"]):
      return "Power-to-weight too low (%d hp/t, min %d)" % [roundi(pw), roundi(float(r["pw_min"]))]
  ```
  `pw` is already computed at `:316`. `pw_min` is authored in hp/tonne like `pw_max`.
- **`underpower_warning` — RETIRED** (decision). With a hard `pw_min` there is no
  eligible-but-underpowered state, so `underpower_warning` / `PW_WARN_FRACTION` and the
  start-line "Start Anyway" flow + the car-park "N underpowered" caution are gone. Rival
  fielding now draws from `_eligible_cars` (in-band) directly (`_fieldable_cars` deleted).
- **Floor judged at MAX potential** (refinement): the `pw_min` check takes an optional
  `floor_meta` (`is_eligible(rally, car_meta, floor_meta := {})`). Owned-car callers pass
  the car's `UpgradeLibrary.max_potential_meta` (full tune + all installed kits enabled +
  ballast dropped), so a car detuned/ballasted to fit a *lower* rally isn't ruled too weak
  for a *higher* one it could reach by tuning up — the mirror of an over-cap car detuning
  DOWN to duck the ceiling. Defaults to a point check for stock catalogue cars / rivals.
- **Safety:** adding `pw_min` to `is_eligible` automatically flows through the
  anti-soft-lock queries — `incomplete_rallies_enterable_by` (`:693`),
  `_eligible_cars`/`_fieldable_cars`, and `RewardSystem._unlock_candidates`
  (`reward_system.gd:149`) — so the reward system only ever grants in-band cars and
  the showdown stays open-class (no band) as the ultimate floor. The starter-floor
  invariant still holds (MX-5 fits Shakedown's band below).
- **`qualifying_detune`** (`:357`) only ever *reduces* power, so it can push a car
  under `pw_max` but never up to `pw_min`; that's correct — detuning can't fix
  "underpowered". No change needed, but the "duck under the cap" over-limit prompt in
  the car park is unaffected.

## Mechanism 2 — real 4-tier car ladder + progress-clamped car draw

- **`CarLibrary` `reward_tier`** reassigned so tiers span 1–4 by power:

  | Tier | Cars |
  |---|---|
  | 1 | Acty, Twingo, Focus |
  | 2 | MX-5, XJS |
  | 3 | Charger, 911 |
  | 4 | Viper, Beast |

- **`RewardSystem.draw_car`** (`reward_system.gd:111-117`): replace the
  `max(garage_tier, difficulty)` ceiling with the `gameplay.md` progress clamp —
  `reward tier = clamp(f(difficulty), 1, tier_ceiling(completed_count))`:
  ```gdscript
  # after the _unlock_candidates fallback check
  var ceiling := clampi(_difficulty_to_tier(rally_difficulty), 1,
      tier_ceiling(RallyLibrary.completed_count(profile)))
  pool = _cars_at_or_below_tier(ceiling)
  ```
  `tier_ceiling` (`:35`, `clamp(1 + completed/2, 1, MAX_TIER)`) and
  `_difficulty_to_tier` (`:41`, identity) already exist. `garage_tier` (`:122`)
  becomes unused by `draw_car` — leave it (still used by tests/UI) or delete if no
  other caller (grep first).
- **Effect:** reward car tier = `min(rally difficulty, progress ceiling)`. A lucky
  early d2 win can't drop a tier-4 car; the Beast needs `completed_count ≥ 6` AND a
  d4 win. Difficulty, band, and clamp now advance together.
- `MAX_TIER` is already 4 (`:18`); the `tier_ceiling` curve is a placeholder slated
  to become a `GameConfig` tunable in the balance pass (unchanged by this spec).

## Mechanism 3 — intra-region reveal order (fixes the dump)

Bands + clamp keep the *home* start tight, but a player enters a *later* region with
a broad garage, so ownership-based eligibility opens everything at once (leap 5).
Gate **first reveal** within a region on region-local completion.

- **New authored field** on each non-showdown `RALLIES` entry: `reveal_after: int`
  — the number of *completed rallies in the same region* required before this rally's
  pin appears. `0` (or omitted) = visible from the start. Showdown keeps its existing
  gate (`showdown_unlocked`).
- **New pure query**, `RallyLibrary.rally_revealed(rally, profile)` (or on
  `RegionLibrary`, next to `rally_showdown_gate_open`, `region_library.gd:136`):
  ```gdscript
  static func rally_revealed(rally: Dictionary, profile: Dictionary) -> bool:
      if bool(rally.get("showdown", false)):
          return RegionLibrary.rally_showdown_gate_open(rally, profile)
      var region_done := _completed_in_region(String(rally.get("region","")), profile)
      return region_done >= int(rally.get("reveal_after", 0))
  ```
  `_completed_in_region` counts completed non-showdown rallies whose `region` matches
  (mirror `completed_count`, `:670`, scoped by region).
- **`hq.gd._refresh_map_pins`** (`:448`): skip (or lock) a pin when
  `not RallyLibrary.rally_revealed(rally, Save.profile)`. Cleanest: keep building the
  pin but treat unrevealed like `locked` (grey, non-pickable — the seam at `:523`,
  `:559`) so the map still hints "more to come"; or `continue` to hide it entirely.
  Decide in review (open question — hint vs hide).
- **Anti-soft-lock:** reveal gating must NOT hide the only rally a stuck player can
  enter. `RewardSystem._unlock_candidates` (`reward_system.gd:149`) and
  `incomplete_rallies_enterable_by` walk rallies for grants — gate those on
  `rally_revealed` too, so the reward system never assumes an unrevealed rally is
  reachable. Author `reveal_after` so each region's wave-0 rallies are always
  enterable by the cars that region is reached with.
- Completed rallies stay farmable — this gates first *reveal* only, never re-entry.

## Proposed authored data

### Home region bands, difficulty, reveal order

| Rally | Diff | Restriction (new) | `reveal_after` | Well-fit cars |
|---|---|---|---|---|
| Sh*tbox Cup | 1 | `pw_min` 40, `pw_max` 100 | 0 | Acty, Twingo |
| Front Runners | 1 | FWD, `pw_min` 80, `pw_max` 140 | 0 | Twingo, Focus |
| Shakedown | 1 | `pw_min` 100, `pw_max` 180 | 0 | Focus, MX-5, XJS |
| Coastal Sprint | 2 | `pw_min` 150, `pw_max` 230 | 2 | MX-5, XJS, Charger, 911 |
| American Muscle | 2 | `country` US, `pw_min` 150, `pw_max` 300 | 2 | Charger, Viper |
| RWD Masters | 3 | RWD, `pw_min` 170, `pw_max` 270 | 3 | XJS, Charger, 911, Viper |
| Heavy Hitters | 3 | `pw_min` 210, `pw_max` 320 | 4 | Charger, 911, Viper |
| Grand Tour | 4 | `pw_min` 260, `pw_max` 400 | 5 | Viper, Beast |
| The Showdown | 4 | open (showdown gate) | — | all |

`reveal_after` counts region-local completions (home has 8 non-showdown). Wave 0 =
the three tier-1 rallies always visible; the rest surface as the player wins. Tune
the cadence so ~1–2 fresh pins exist at each step.

### Greece region bands, difficulty, reveal order

Greece mirrors the shape with **bands and reveal order but no drivetrain/country
themes** (it's a fresh-scenery re-run of the power ladder). By the time it unlocks
the garage is broad, so `reveal_after` is what keeps it to 1–2 at a time.

| Rally | Diff | Restriction | `reveal_after` |
|---|---|---|---|
| Olive Coast | 2 | `pw_min` 150, `pw_max` 230 | 0 |
| Mountain Pass | 3 | `pw_min` 210, `pw_max` 320 | 1 |
| Ancient Ruins | 3 | `pw_min` 260, `pw_max` 400 | 2 |
| The Aegean Crown | 4 | open (showdown gate) | — |

(Region-0 completions do NOT count toward Greece's `reveal_after` — the count is
region-scoped, so Greece starts its own wave-0 at Olive Coast.)

## Restriction relaxations (leap 4)

- **American Muscle**: drop `car_type` "muscle" (`rally_library.gd:157`), keep
  `country` US, widen the band to admit both US performance cars (Charger 216, Viper
  264). Established practice here — `rising_sun`/"Heavy Hitters" was already reworked
  from a country gate to a band when no car fit (`:128-134`).
  **Alternative:** author a second US muscle car in `CARS` and keep the `muscle`
  theme (bigger content task — open question).
- Grand Tour / Heavy Hitters single-car bands are resolved by the wider bands above
  (2–4 occupants each).

## Progression walk-through (MX-5 start, to validate the invariant)

Own MX-5 (t2, 159) → **Shakedown + Coastal** eligible; Coastal `reveal_after` 2 so
only **Shakedown** is a wave-0 pin → 1 clear next step (+ the two other tier-1 pins
Front Runners/Sh*tbox, which MX-5 can't fit — grey). Win Shakedown (d1, ceiling t1)
→ tier-1 car (Focus/Twingo/Acty), opens a matching tier-1 rally. Region completions
climb → Coastal (d2) reveals; win it once ceiling ≥ t2 → XJS (t2) → RWD Masters
reveals… Each step exposes ~1–2 fresh, in-band, winnable rallies. Difficulty →
reward tier → next band all advance in lockstep.

## Fix map

| Leap | Fixed by |
|---|---|
| 1 starter over-exposed | Mechanism 1 (bands) + Mechanism 3 wave-0 |
| 2 toothless tiers / no clamp | Mechanism 2 |
| 3 Coastal ≡ Shakedown | Mechanism 1 (distinct bands) |
| 4 single-car rallies | Mechanism 1 (wider bands) + restriction relax |
| 5 region dump | Mechanism 3 (reveal order) |
| 6 Acty dead-ends | Mechanism 1 (Sh*tbox floor 40 admits Acty) |

## Test implications (`tests/headless/test_rally_library.gd`)

Update tests to assert the NEW logic, keeping the `CLAUDE.md` rule (pin behaviour,
never authored numbers):

- `test_power_to_weight_restriction_filters` (`:154`) currently asserts "no hard
  floor" (`:170-173`) — this ENCODES the old ceiling-only decision and now flips:
  add a synthetic `{pw_min, pw_max}` band and assert a below-floor car is ineligible,
  an in-band car eligible, an over-ceiling car ineligible. Derive the band from the
  synthetic cars' own p/w, not authored values.
- Roster-shape test (the "tier-1 has no floor, tier-3+ uses a band" assertion in the
  invariants block, per `features/rally-roster.md` Tests): update to "every
  non-showdown rally is a band (`pw_min` ≤ `pw_max`), the showdown is open-class".
- `reward_system` tests (`test_reward_system.gd`): the car-draw ceiling test must
  assert the NEW clamp — `draw_car` tier ≤ `tier_ceiling(completed_count)` and never
  exceeds `min(difficulty, ceiling)` — not `max(garage_tier, difficulty)`. Keep the
  guaranteed-reward + prefer-unowned + unlock-fallback assertions.
- New tests: `rally_revealed` gates on region-local completion (synthetic profile +
  synthetic rallies via `RallyLibrary.override_for_test`); an unrevealed rally is
  excluded from `incomplete_rallies_enterable_by` / `_unlock_candidates`.
- Menu nav / pin tests (`test_menu_flow.gd`, `test_menu_nav.gd`): if pins hide when
  unrevealed, ensure the map still has a focusable target set (`_table_targets`).

## Docs to update (same piece of work, per `CLAUDE.md`)

- `features/rally-roster.md` — band (`pw_min`/`pw_max`) + `reveal_after` fields,
  eligibility semantics, the anti-soft-lock note.
- `features/reward-system.md` — the progress-clamped `draw_car` (replace the
  `max(garage tier, difficulty)` description in "Car draw").
- `features/regions.md` / `features/menus.md` — intra-region reveal gating on pins.
- `gameplay.md` — the "Decided" trace already promises a progress clamp; reconcile.

## Status — IMPLEMENTED

All three mechanisms + the floor-at-max refinement are in. Tests updated and green
(`test_rally_library`, `test_reward_system`, `test_upgrade_library`, `test_start_line`,
`test_menu_flow`, `test_menu_nav`). Decisions taken (below). Remaining open item is only
the play-calibration of the numbers.

## Decisions taken

1. **American Muscle** → relaxed to `country` US (drops `car_type` muscle) so it fields
   both US performance cars (Charger, Viper) — no new content.
2. **`underpower_warning`** → **retired** (hard floor makes it redundant; see Mechanism 1).
3. **Unrevealed pins** → shown **greyed + non-pickable** (reuse the `locked` look) — a
   "coming up" hint, not hidden.
4. **Floor judged at max potential** (added mid-implementation, per review) — see
   Mechanism 1.

## Open (calibration only)

1. **Exact band numbers + `reveal_after` cadence** — the tables above are a first cut;
   needs a play/calibration pass (like the target-time formula tuning). Values are
   authored content, so retuning them won't break tests (which pin logic, not numbers).
2. **`tier_ceiling` curve**: still the `1 + completed/2` placeholder — a `GameConfig`
   tunable in the final balance pass (shared with the upgrade draw).

## Implementation order

1. Mechanism 1 (`pw_min` in `ineligibility_reason`) + update the eligibility test —
   smallest, unblocks band authoring.
2. Author home + Greece bands / difficulties / restriction relax in `RALLIES`.
3. Mechanism 2 (`reward_tier` reassignment + `draw_car` clamp) + reward tests.
4. Mechanism 3 (`reveal_after` + `rally_revealed` + `hq.gd` pin gate + query wiring)
   + reveal tests.
5. Docs pass + targeted test run (`test_rally_library`, `test_reward_system`,
   `test_menu_flow`, `test_smoke`).
