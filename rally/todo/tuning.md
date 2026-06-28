# Tuning — implementation spec

> Status: **✅ IMPLEMENTED.** See [`features/tuning.md`](../features/tuning.md)
> (`TuningLibrary`, the `brake_bias` drivetrain split, the `Tuning` GameConfig group,
> the `apply_owned` step-3 hook, and the tuning-lift UI in `hq.gd`). The sections
> below are the original brief, kept for reference.
>
> Original brief for the **free,
> reversible per-car tuning** half of `gameplay.md` › *Tuning & upgrades* — the
> garage adjustments the player makes for free, as distinct from consumable
> *upgrades* (`todo/upgrade-catalogue.md`). Follow the config-first convention
> (`CLAUDE.md`): every tuning value resolves into a `GameConfig` field at
> field-the-car time, never hardcoded in flow logic. Update the relevant
> `features/*.md` doc and add tests in the same piece of work.
>
> **Scope decided (with the user): minimal — exactly the three knobs `gameplay.md`
> names** (grip balance, brake bias, aero balance). Deeper GT-style tuning (ride
> height, gear ratios, tyre pressure) is noted in *Out of scope* as a future
> expansion, not built now.

## Goal

Let the player nudge a car's handling for free in the garage (tuning lift,
`todo/menus.md`), store those nudges per owned car, and apply them on top of the
`CarLibrary` baseline + installed upgrades when the car is fielded — all through
existing (or one new) `GameConfig` knobs, with nothing written back to the
authored `.tres`.

## Distinguish from upgrades

| | **Tuning** (this spec) | **Upgrades** (`todo/upgrade-catalogue.md`) |
|---|---|---|
| Cost | free | won as rewards, consumed to install |
| Reversible | yes, instantly | no — returned only on wreck |
| Stored as | `OwnedCar.tuning` deltas | `OwnedCar.installed_upgrades` |
| Effect | re-balances existing knobs | changes the baseline / unlocks a knob |

Aero balance is gated by the **aero upgrade** and brake bias by the **brakes
upgrade**'s `unlocks_brake_bias` flag — tuning a knob an upgrade hasn't unlocked
is locked out at the lift (`todo/upgrade-catalogue.md` › effect dict).

## Current state (measured from the code)

- **The two grip knobs already exist** and are read every tick:
  `wheel_friction_slip_front := 0.8` (`game_config.gd:106`) /
  `wheel_friction_slip_rear := 0.6` (`:107`).
- **The two aero knobs already exist:** `downforce_front := 0.0`
  (`game_config.gd:76`, `@export_range(-2.0, 2.0)`) / `downforce_rear := 0.0`
  (`:80`).
- **Brake bias does NOT exist.** Braking today is a single per-axle value:
  `brake_torque := 2645.0` (`game_config.gd:66`), applied in `drivetrain.step`
  as `front_brake := brake * cfg.brake_torque` (per front wheel) and
  `rear_brake := front_brake + (handbrake ? handbrake_torque : 0)`
  (`drivetrain.gd:89-90`). Front and rear foot-brake torque are **equal**. The
  front/rear split is the one **new knob** this spec adds (see §3).
- **`apply_car` already mutates `Config.data` at runtime** (`car.gd:253,267`) —
  tuning rides the same path: read the baseline, apply deltas to `Config.data`,
  never touch the `.tres`.
- **The save already models the storage.** `OwnedCar.tuning` (a delta dict) +
  `Save.set_tuning(instance_id, tuning)` exist in `todo/save-persistence.md`;
  this spec defines the dict's keys and how they map to config.

## The three tuning axes (decided — minimal set)

Each is a **single normalized slider in `[-1, +1]`**, default `0` (= the
CarLibrary baseline, neutral). One axis = one slider, so the UI and the stored
delta stay legible. The slider maps to a symmetric shift of the underlying
config pair:

| Tuning axis | Slider meaning | Maps to | Gated by |
|---|---|---|---|
| **grip_balance** | −1 understeer ↔ +1 oversteer | shifts grip front↔rear: `wheel_friction_slip_front`/`_rear` | always available |
| **brake_bias** | −1 rearward ↔ +1 forward | front/rear split of `brake_torque` (new knob, §3) | brakes upgrade (`unlocks_brake_bias`) |
| **aero_balance** | −1 front ↔ +1 rear downforce | shifts `downforce_front`↔`downforce_rear` | aero upgrade (`unlocks_aero_tuning`) |

`OwnedCar.tuning = { grip_balance: float, brake_bias: float, aero_balance: float }`,
each clamped to `[-1, 1]`; absent keys default to `0`.

## Application (where tuning slots in the pipeline)

This is **step 3** of the field-the-car pipeline in `todo/upgrade-catalogue.md`:

```
1. CarLibrary baseline   apply_car(index) -> Config.data            (car.gd:253,267)
2. Installed upgrades    UpgradeLibrary.apply(owned, cfg)           (upgrade-catalogue)
3. Per-car tuning        TuningLibrary.apply(owned, cfg)            (THIS SPEC)
4. Damage multipliers    power/steer degraded by HP fraction        (damage-model)
```

`TuningLibrary.apply(owned_car, cfg)` (`scripts/tuning_library.gd`,
`class_name TuningLibrary`, pure static) reads `owned_car.tuning` and re-balances
the live `cfg` (`Config.data`). Each axis is a **balance transfer that conserves
the pair's total**, scaled by a `GameConfig` authority knob so the magnitude is
tunable and never inverts a value:

```gdscript
# grip_balance: move grip front<->rear about the baseline pair, total preserved
var t := clampf(owned.tuning.get("grip_balance", 0.0), -1.0, 1.0)
var span := cfg.tuning_grip_authority          # max fraction shifted at |t|=1
cfg.wheel_friction_slip_front = base_front * (1.0 - t * span)
cfg.wheel_friction_slip_rear  = base_rear  * (1.0 + t * span)
# aero_balance: same shape on downforce_front/_rear (only if aero kit installed)
# brake_bias: splits brake_torque into front/rear components (see §3)
```

Because step 3 runs **after** upgrades (step 2), tuning balances whatever
baseline the upgrades produced (e.g. a stiffer aero kit), and **before** damage
(step 4), so a damaged car's power/steer loss still stacks on top. Tuning is
**not** re-applied mid-run; it's resolved once at fielding, like `apply_car`.

## 3. The new brake-bias knob (the one code prerequisite)

Today `brake_torque` is one value split equally (`drivetrain.gd:89-90`). Add a
front/rear split so brake_bias has something to drive:

- New `GameConfig` field **`brake_bias`** *(float, default `0.5`)* — fraction of
  total brake torque sent to the **front** axle (`0.5` = today's equal split;
  higher = more front, stabilises but risks understeer-on-brakes).
- In `drivetrain.step` (`drivetrain.gd:89`), replace the equal split with:
  ```gdscript
  var total := brake * cfg.brake_torque * 2.0          # preserve today's total
  var front_brake := total * cfg.brake_bias            # per front wheel share
  var rear_brake := total * (1.0 - cfg.brake_bias) + (handbrake ? cfg.handbrake_torque : 0.0)
  ```
  Choose the `* 2.0` normalisation so `brake_bias = 0.5` reproduces today's
  numbers exactly (regression guard — see Testing).
- The **brake_bias tuning slider** maps `[-1,+1]` → `brake_bias` around `0.5`
  with `tuning_brake_authority` as the half-span (e.g. authority `0.3` →
  slider ∈ `[0.2, 0.8]`).

This knob is also what the **brakes upgrade** unlocks for tuning
(`todo/upgrade-catalogue.md`); the upgrade gates the slider, this spec owns the
underlying split.

## New `GameConfig` tunables (authority/magnitude only — values via playtest)

Add an `@export_group("Tuning")` to `scripts/game_config.gd`:

| Field | Type | Default | Purpose |
|---|---|---|---|
| `brake_bias` | float | `0.5` | Front share of foot-brake torque (the new split; `0.5` = today). |
| `tuning_grip_authority` | float | `0.15` | Max grip fraction shifted front↔rear at slider \|1\|. |
| `tuning_brake_authority` | float | `0.3` | Half-span of brake_bias the slider can move from `0.5`. |
| `tuning_aero_authority` | float | `0.5` | Max downforce fraction shifted front↔rear at slider \|1\|. |

Per-car baselines stay in `CarLibrary`/`GameConfig`; tuning only re-balances
them within these authority bounds, so a slider can never zero or invert a value.

## Reset & wreck behaviour

- **Reset to neutral** at the lift sets all axes to `0` (free, instant) — a
  Reset action `todo/menus.md`'s tuning lift exposes alongside the sliders.
- Tuning is **per owned instance**; a wrecked car's tuning vanishes with the
  chassis (it's free, so nothing is "returned" — only `installed_upgrades` come
  back, `todo/upgrade-catalogue.md`).

## Dependencies

- **Save / persistence** (`todo/save-persistence.md`) — owns `OwnedCar.tuning`
  and `Save.set_tuning`. This spec defines the dict keys.
- **Upgrade catalogue** (`todo/upgrade-catalogue.md`) — the aero/brakes upgrades'
  `unlocks_*` flags gate the aero/brake sliders; the brake split here is what the
  brakes upgrade unlocks. Pipeline step 3 runs after step 2.
- **Menus** (`todo/menus.md`) — the tuning-lift sliders + Reset action are the UI
  for these axes (the spec already lists grip/aero/brake-bias knobs there).
- **Drivetrain** (`scripts/drivetrain.gd`) — the brake-split change lands here.

## Testing

Headless GUT tests (`tests/headless/`):
- **Neutral is a no-op:** all axes `0` → `TuningLibrary.apply` leaves the grip /
  aero / brake values identical to the baseline.
- **Grip balance:** `+1` shifts grip rearward (rear up, front down) by
  `tuning_grip_authority`, total conserved; `-1` the reverse; monotonic.
- **Aero gating:** aero_balance only changes `downforce_*` when the aero upgrade
  is installed; otherwise it's a no-op.
- **Brake split regression:** with `brake_bias = 0.5`, `drivetrain.step` produces
  the **same** front/rear brake torques as today (guards the `* 2.0`
  normalisation). `brake_bias = 0.7` sends more to the front.
- **Brake bias gating:** brake_bias tuning only moves `brake_bias` when the
  brakes upgrade is installed.
- **Clamp:** out-of-range slider values clamp to `[-1, 1]`; authority bounds
  never invert or zero a config value.

## Out of scope / open questions

- **Deeper tuning** — ride height, suspension stiffness
  (`suspension_stiffness` `game_config.gd:115`), gear ratios, tyre pressure.
  Deliberately **not** in the minimal set; the `OwnedCar.tuning` dict and
  `TuningLibrary.apply` shape already accommodate more axes if added later.
- **Authority values** — the four magnitudes above are a balance pass, deferred
  to playtest (`gameplay.md` defers tuning numbers generally).
- **Per-car tuning ranges** — whether some cars should allow wider/narrower
  tuning than others (a per-car authority override in `CarLibrary`); start
  global.
- **Telemetry / preview** — showing the handling effect before a run (e.g. a
  predicted balance bar); cosmetic, defer.
