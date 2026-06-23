# Gameplay Design — "Gran Turismo, but with rally stages"

> **This is a design / vision document, not an implementation spec.** It captures
> the intended game and the decisions made while brainstorming it. Concrete
> implementation is broken out into `todo/` specs (grounded in real code, per
> `CLAUDE.md`); this file is the north star those specs ladder up to. Where it
> names real systems it's to show feasibility, not to prescribe code.

## Tagline & fantasy

**Gran Turismo, but with rally stages.** You build and tune a garage of cars,
enter seeded rallies around a world map, and chase a clean combined time across
three events — but every car you field (except the starter) is a real,
depreciating asset that can be damaged and ultimately destroyed. The pull is the
collection-and-tuning loop of GT crossed with the **high-stakes attrition of a
roguelike**: do you risk your best car to win, or play it safe?

## Core loop

1. Pick a rally on the world map you have an **eligible car** for.
2. Choose **which** of your eligible cars to field (risk vs. reward).
3. Watch the **pre-launch scene** (car ahead launching, car behind waiting),
   then run the **3 events**; combined time sets your rally result.
4. See the **leaderboard** after each event vs. AI opponents.
5. Earn a **random upgrade** per event (lootbox reveal); **win the rally** → a
   **random car** (lootbox reveal). Damage you took **carries over**.
6. **Tune & upgrade** between rallies. Repeat, working toward the **final
   showdown** unlocked by a points threshold.

## Locked decisions (from design brainstorm)

| Topic | Decision |
|---|---|
| Economy | **No currency.** Progression is purely cars + upgrades won. |
| Damage repair | **Repair only via rare items** (a "repair kit" lootbox reward). |
| Run stakes | **Retry allowed, but damage sticks.** Opponent results are fixed per rally seed; damage from a failed attempt persists. |
| Showdown unlock | **Threshold / points total** (not literally every rally). |
| Soft-lock guard | **Both:** an always-available open-class rally pool the immortal starter qualifies for, **and** reward logic guarantees every car granted is eligible for ≥1 incomplete rally and never leaves zero enterable rallies. |
| Reward balancing | **Both:** reward tier = f(rally difficulty), **clamped** by an overall-progress ceiling so a lucky early win can't drop a top-tier car. |
| Upgrades on car death | **Returned to inventory.** Only the chassis is lost; installed upgrades go back to the player. |

---

## Cars & the garage

- **Starters:** the player picks **1 of 3** starter cars at the beginning. Each is
  low-performance and, crucially, **damage-immune** — the permanent safety net so
  the player can never be left with nothing drivable. *(Proposed: the other two
  starters are not obtainable later; they're just a starting-flavour choice.)*
- **Car metadata for restrictions.** Every car needs tags so rallies can filter
  it: **engine size/type**, **drivetrain layout** (FWD/RWD/AWD — the sim already
  has drive modes via `drivetrain.cycle_drive_mode`), **country**, **car type**
  (e.g. hatch/coupe/saloon), and **power-to-weight** (derivable from engine
  torque + `mass`). Home for this: extend **`CarLibrary`** (per-car overrides
  already live there) with these tags. *(New: metadata schema → its own todo.)*
- **Owned vs. catalog.** The garage holds owned cars + their per-car damage and
  installed upgrades. The lootbox reveals double as the player's window into what
  cars/upgrades *exist* in the game.

## Damage model

- Damage is a per-car value that **only accumulates** between events and between
  rallies (no passive healing). It rises from **hitting objects** (the roadside
  signs / trees already have collision; impacts feed the damage value).
- **Effects scale with damage:**
  - **Wheel alignment** → a steering pull (the car drifts to one side). The sim
    has no alignment-offset knob today; add one (a constant toe/steer bias fed
    into the steering in `car.gd`).
  - **Engine power** → reduced output. No single power multiplier exists today
    (power comes from the `engine_type` preset / `ENGINE_PRESETS`); add a
    **damage power-multiplier** applied to engine torque.
- **Carry-over & cap.** Damage persists across events and rallies. At a **damage
  cap** the car is **destroyed**: disqualified for the rest of the current rally
  *and* unusable in all future rallies. **Its installed upgrades return to the
  player's inventory** (only the chassis is lost).
- **Starter is immune** (never damaged, never destroyed) — the anti-soft-lock
  floor.
- **Repair** is possible **only via a rare "repair kit" item** from the lootbox,
  spent between rallies to reduce a car's damage.
- *(Implementation: damage→effect mapping and the cap value are tuning numbers;
  defer exact values to a damage todo + playtesting. Reuses the existing
  collision on signs/trees as impact sources.)*

## World map & rallies

- The world map offers a **large number of rallies**, each **generated from an
  RNG seed** (the track generator is already seeded — `track_seed`).
- Each rally has a **restriction** (engine size, drivetrain layout, country, car
  type, p/w ratio, …). The player must **own a matching car** to enter. An
  **open-class** pool (no restriction) is always present so the starter always
  has somewhere to race.
- A rally = **3 events**. **Combined time across all 3** sets the final rally
  time and finishing position.
- After **each event** the player sees a **leaderboard**: their time vs. the AI
  field, so they always know how they're doing.

## Events, target times & opponents

- Each event has a **hidden target time** representing "correct" difficulty.
  - **Tension:** with a *large number of seeded* rallies, hand-setting a target
    per event isn't feasible. **Proposed resolution:** target time is an
    **auto-derived function of the seeded track** (length + corner-difficulty
    mix), **calibrated by Felix during testing** on a sample of seeds so the
    formula lands correct difficulty everywhere. A curated few (e.g. the
    showdown) can still get hand-set targets. **Decided.** A dedicated
    fine-tuning session (run sample seeds, eyeball the derived targets, adjust
    the formula's difficulty weights) is planned once the formula exists.
- **Opponents:** each AI gets a random time in **[target, 2 × target]**. **Some
  opponents DNF** an event, disqualifying them from that rally. Opponent times +
  who DNFs are **fixed per rally seed** so the leaderboard is stable across
  retries (you're chasing a fixed field, not a re-rolled one).
- **Field size: 10–15 opponents** per rally — a full leaderboard, with some DNFs
  thinning it out.
- **Retry, damage sticks:** the player can re-attempt, but any damage from the
  failed attempt persists and the opponent field is unchanged.
- *(Proposed: DNF for the player = car destroyed mid-rally or failing to finish
  an event.)*

## Progression & rewards

- **Per event:** a **random upgrade** drops into the inventory.
- **Per rally win (all 3 events):** a **random car** is granted.
- **Reveal as a lootbox / slot machine** — spinning reels that settle on the
  reward, so the player glimpses the breadth of cars/upgrades that exist (a
  discovery hook, not just a grant).
- **Reward balancing (both):** tier = **f(rally difficulty)** (harder rally →
  better reward) **clamped by an overall-progress ceiling** (early game can't
  yield a top car even on a lucky win).
- **Anti-soft-lock (both):** open-class rallies as the floor **+** reward logic
  that guarantees every granted car is eligible for **≥1 still-incomplete rally**
  and the player is **never** left with zero enterable rallies.
- *(Implication: a points/progress metric underlies both the reward ceiling and
  the showdown unlock — define it once and share it.)*

## Tuning & upgrades

Two distinct systems:

- **Tuning** — **free, reversible** adjustments made in the garage, per car. Maps
  directly onto existing `GameConfig` car knobs:
  - **Front/rear grip balance** (understeer ↔ oversteer): `wheel_friction_slip_front`
    (0.8) vs `wheel_friction_slip_rear` (0.6).
  - **Brake bias**: not a knob today — `brake_torque` is per-axle/equal; **add a
    front/rear brake-split** parameter.
  - **Aero balance** (only if the **aero upgrade** is installed): how much front
    vs rear downforce — `downforce_front` / `downforce_rear`.
- **Upgrades** — **inventory items** applied to a car (consumable to install),
  won as rewards and returned to inventory if the car is destroyed. Examples:
  engine/power, aero kit (unlocks aero tuning), suspension, brakes, plus the
  **repair kit** (consumed to heal damage). *(Exact upgrade list + how each maps
  to config knobs → its own todo.)*

Per the project's config-first rule, every tuning value and upgrade effect should
resolve into `GameConfig`/`CarLibrary` values, never hardcoded.

## Presence & atmosphere

The player should never feel alone in the rally:
- **Pre-countdown scene:** a car **ahead** launching its run and a car **behind**
  waiting its turn — an animated start-area beat before control is handed over.
- **Podium scene:** at the rally's end, an animated **podium** showing who placed.
- *(These hook into the start/end flow — see `todo/stage-start-and-end.md`; the
  pre-countdown scene precedes that spec's 3-second countdown.)*

## The final showdown

- A **final showdown rally** with **extra-long events**, entered **only** once a
  **points threshold** is reached (not literally every rally).
- It should read clearly as **the main goal**; the **events-selection menu shows
  progress toward it** (a points/▰▰▱ meter), so the player always knows how close
  they are.
- *(Proposed: winning the showdown is the game's "win" / credits beat.)*

## Foundations this implies (cross-cutting)

These underpin everything above and likely each become their own todo:
- **Save / persistence** — owned cars, per-car damage, installed upgrades,
  inventory, rally completion/points, reward history. Nothing here works without
  it.
- **CarLibrary metadata** — the restriction tags (engine/drivetrain/country/
  type/p-w).
- **Points/progress metric** — shared by the reward ceiling and the showdown
  unlock + meter.
- **Meta-game UI shell** — world map, garage, tuning screen, inventory, lootbox
  reveal, leaderboard, podium. (The in-car HUD already exists; this is the
  surrounding menu layer, which barely exists today.)

## Relationship to existing todos

- `todo/stage-start-and-end.md` — countdown, elapsed timer, stage-complete. The
  **pre-countdown presence scene** and **podium** extend its start/end flow; the
  **event timer** is the per-event time that sums into the rally result.
- `todo/track-progress-and-reset.md` — progress %, on-road reset. Drives "event
  complete" and the off-track recovery during a run.
- `todo/roadside-signs.md` — sectors + start/finish + collision. Sign collisions
  are an **impact source for the damage model**; the 4 sectors can show split
  times within an event.

## Open questions / to decide later

- **Target-time model** for seeded rallies: confirm the auto-derived,
  Felix-calibrated formula (vs. hand-authoring a curated subset only).
- **Opponent count** per rally and exact **DNF trigger** for the player.
- **Starter cars:** are the unchosen two ever obtainable, or purely a starting
  pick?
- **Points metric** definition (placement-based? completion-based?) feeding the
  reward ceiling and showdown meter.
- **Damage tuning:** cap value, damage-per-impact, and how steeply alignment/
  power degrade — settle via playtesting.
- **Upgrade catalogue:** the full list of upgrade types and each one's config
  mapping.
