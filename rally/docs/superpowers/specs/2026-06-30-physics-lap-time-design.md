# Physics-based optimum lap time (QSS) — design

**Date:** 2026-06-30
**Status:** approved design, ready for implementation plan

## Problem

Opponent and target times are derived by a pure heuristic in
`scripts/rally_library.gd`:

```
target_s = length / REF_SPEED_MPS + corner_count * CORNER_PENALTY_S   (blended by surface)
```

This ignores the car entirely — power, weight, drag, grip and brake force play
no part, so a more powerful or grippier car posts the same "time" as a slow one.
We want a physics-grounded **theoretical optimum lap time**: treat the car as a
point mass that follows the centerline exactly, subject to its real forces.

## Approach: quasi-steady-state (QSS) lap-time simulation

Not an optimization search — a deterministic three-pass sweep over the track's
**curvature profile** κ(s), constrained by the tyre **friction circle** (grip
spent cornering is unavailable for accel/braking). This is the standard QSS
forward–backward velocity-profile method.

### New module: `scripts/lap_time_model.gd` (`LapTimeModel`)

Pure static math — no scene, no physics server. Trivially unit-testable.

- `optimum_ms(track_result, car_meta, event := {}) -> int`
- `optimum_profile(track_result, car_meta, event := {}) -> Dictionary`
  returns `{ "s": PackedFloat32Array, "v": PackedFloat32Array,
  "t": PackedFloat32Array, "total_ms": int }` — the shared velocity/time
  profile that both the scalar time and the turn-splits are read off.

`optimum_ms` is `optimum_profile(...).total_ms`.

### Step 1 — curvature profile κ(s)

Bake the `centerline` (`Curve2D`) into N samples (~every 2 m). At each sample,
`κ = |Δheading| / Δs` from successive tangent angles. Light 3-tap smoothing to
kill discretization spikes. Output parallel arrays `s[i]`, `kappa[i]`. This is
the only new track-geometry extraction.

### Step 2 — car physical envelope from `car_meta`

- **µ (grip):** `0.5 * (grip_front + grip_rear)`, blended by surface fraction
  using `GameConfig.gravel_grip` (1.0) / `tarmac_grip` (1.3):
  `µ_eff = gravel_frac*µ*gravel_grip + tarmac_frac*µ*tarmac_grip`.
  (`event_tarmac_fraction` already gives the split.)
- **P_peak:** from `peak_torque × redline` — reuse the conversion already in
  `CarLibrary.power_to_weight`.
- **Drive force (power-limited):** `F(v) = P_peak / v`, grip-capped at low
  speed. Ignores gearbox/torque-curve shape (standard QSS shortcut).
- **drag accel:** `drag * v² / mass`. **rolling:** ~0.2 g baseline.
- **downforce:** folds into normal load, so effective `µg` grows with v² in fast
  corners (small refinement; wired but minor).

### Step 3 — three-pass velocity profile

1. **Ceiling:** `v_cap[i] = sqrt(µg / κ[i])` (∞ where straight).
2. **Forward accel:** march `i = 0 → N`,
   `a = min(F(v)/m − drag − rolling, sqrt((µg)² − (v²κ)²))`,
   integrate `v` upward, clamp to `v_cap`.
3. **Backward braking:** march `i = N → 0`,
   `a = sqrt((µg)² − (v²κ)²)` (braking is grip-limited, not engine-limited),
   clamp.

Final `v[i] = min` of the three passes. Cumulative time `t[i] = Σ ds / v[i]`;
`total_ms = round(t[N] * 1000)`. The trail-brake-in / power-out shape emerges
from the physics — no search.

## Wiring into `rally_library.gd`

### Event target (par)

Par = **best eligible car**'s floor × a driver-imperfection factor:

```
target_ms = optimum_ms(track, best_eligible_car, event) * DRIVER_FACTOR
```

- `best_eligible_car`: strongest car in the rally's eligible roster
  (`_eligible_cars`).
- `DRIVER_FACTOR`: new `GameConfig` field (~1.08). The physics floor assumes a
  flawless driver; the factor makes par a beatable human time.
- `target_ms_override` still short-circuits as today.

Remove `REF_SPEED_MPS`, `TARMAC_SPEED_MPS`, `CORNER_PENALTY_S`,
`TARMAC_CORNER_PENALTY_S`.

### Opponent field

Each rival gets their own floor from their **assigned car** × a **per-rival
driver factor** (a seeded spread around `DRIVER_FACTOR`) — so a faster car
genuinely posts a faster time, and the field has realistic spread. A DNF still
disqualifies as today.

### Turn splits (car-parameterized)

`derive_turn_splits(track_result, car_meta, event)` now reads off the SAME
velocity profile as that car's `optimum_ms`:

1. Compute `optimum_profile(track, car_meta, event)`.
2. For each piece, map its end-offset onto `t[i]` → that turn's cumulative ms.
3. `cum_ms` per turn; final turn equals the car's `total_ms`.

`target_ms_override` rescaling behaviour is preserved.

## The in-stage "vs P1" pace popup — consistency requirement

The popup (`StageManager.setup_splits` / `_update_stage_delta`,
`HUD.show_stage_delta`) reconstructs P1's pace at each turn as
`p1_total_ms * turn_time_frac[i]`. For this to match the **real** time P1
drives, the total and the fractions must come from the SAME profile, computed
from **P1's actual car**:

- `p1_total_ms` = P1's leaderboard time = `optimum_ms(P1_car, event) ×
  p1_driver_factor` (the same number on the standings).
- `turn_time_frac[i]` = P1's clean physics fractions from
  `derive_turn_splits(track, P1_car, event)` (cum_ms / total).

Because the driver factor is uniform, `p1_total_ms * turn_time_frac[i]` lands
exactly on P1's real cumulative time at every turn boundary — **decision: same
total, clean shape** (no per-turn imperfection model). The popup now shows
genuine P1 pace: if P1's car corners better, the popup shows P1 gaining there.

**`world.gd` change:** pass **P1's car** into the splits call, not the par car.

## Testing

`tests/headless/test_lap_time_model.gd` (new):

- Monotonicity: more power → lower time; more grip → lower time; tighter corners
  (higher κ) → higher time; more drag → higher time.
- Analytic check: a straight-only track matches the closed-form accel+drag time
  within tolerance.
- Friction-circle sanity: a constant-radius corner holds
  `v ≈ sqrt(µg / κ)` mid-corner.
- Profile consistency: `optimum_profile(...).total_ms == optimum_ms(...)`, and
  `derive_turn_splits` final `cum_ms == total_ms`.

`tests/headless/test_rally_library.gd` (update):

- Target now derives from `LapTimeModel` + `DRIVER_FACTOR`; faster eligible
  rosters yield faster pars.
- Opponent spread: faster assigned car → faster opponent time.
- Popup consistency: `p1_total_ms * turn_time_frac[last] ≈ p1_total_ms`, and
  intermediate fractions are monotonic.

## Out of scope (YAGNI)

- Gearbox / torque-curve through gears (using power-limited shortcut).
- Racing-line optimization (car follows centerline exactly, per the brief).
- Per-turn driver-imperfection noise model.
