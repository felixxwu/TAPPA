# Per-car tuning

**Sources:** `scripts/tuning_library.gd` (`TuningLibrary`), the brake-bias split in
`scripts/drivetrain.gd`, the `Tuning` group in `scripts/game_config.gd`, the
fielding hook in `scripts/car.gd` (`apply_owned`), and the tuning-lift UI in
`scripts/hq.gd`. Player state lives on each `OwnedCar` (`Save`,
[save-persistence.md](save-persistence.md)). Full design:
[../todo/tuning.md](../todo/tuning.md).

**Tuning** is the **free, reversible** half of *Tuning & upgrades* — handling
nudges the player makes at the garage **tuning lift**, as distinct from consumable
**upgrades** ([upgrade-catalogue.md](upgrade-catalogue.md)). Tuning is stored as
per-car deltas, costs nothing, and is reset instantly; it is never written back to
the authored `.tres`.

## The three axes

Each owned car stores `tuning = { grip_balance, brake_bias, aero_balance }`, each a
single normalized slider in `[-1, +1]`, default `0` (= the baseline, neutral).

| Axis | Slider | Maps to | Gated by |
|------|--------|---------|----------|
| `grip_balance` | −1 understeer ↔ +1 oversteer | shifts `wheel_friction_slip_front`/`_rear` | always available |
| `brake_bias` | −1 rearward ↔ +1 forward | the front/rear `brake_bias` split (drivetrain) | the **brakes** upgrade (`unlocks_brake_bias`) |
| `aero_balance` | −1 front ↔ +1 rear | shifts `downforce_front`/`_rear` | the **aero** upgrade (`unlocks_aero_tuning`) |

## Application (`TuningLibrary.apply`)

Pure static, mutates the live `cfg` (`Config.data`) in place. It is **step 3** of
the field-the-car pipeline (`car.gd.apply_owned`):

```
1. CarLibrary baseline   apply_car(index)         -> Config.data
2. Installed upgrades    UpgradeLibrary.apply()     (changes the baseline)
3. Per-car tuning        TuningLibrary.apply()      (re-balances it)   ← here
4. Damage multipliers    power/steer degraded by HP
```

Running after step 2 means tuning balances whatever baseline the upgrades produced,
and the gating reads the same installed upgrades. Each axis is a symmetric shift of
its config pair scaled by a `GameConfig` authority knob, so a slider can never zero
or invert a value:

- **grip:** `front *= (1 − t·grip_authority)`, `rear *= (1 + t·grip_authority)`.
- **aero:** same shape on `downforce_front`/`_rear`, **only** with the aero kit; a
  no-op otherwise.
- **brake bias:** with the brakes kit, `brake_bias = 0.5 + t·brake_authority`;
  without it, forced to the neutral `0.5` (so a re-fielded car can't keep an
  unlocked bias). Free-roam (`apply_car`, no `OwnedCar`) leaves `brake_bias` at the
  config default `0.5`.

Tuning is resolved **once at fielding**, like `apply_car` — not re-applied mid-run.

## The brake-bias split (`drivetrain.gd`)

`brake_bias` is the fraction of foot-brake torque sent to the **front** axle. In
`Drivetrain.step` the foot brake is `total = brake · brake_torque · 2`, split
`front = total · brake_bias`, `rear = total · (1 − brake_bias) + handbrake`. The
`· 2` normalisation makes `brake_bias = 0.5` reproduce the old equal split exactly
(regression-guarded by `test_drivetrain.test_brake_lockup`).

## `GameConfig` knobs (`Tuning` group)

| Field | Default | Purpose |
|-------|---------|---------|
| `brake_bias` | `0.5` | Front share of foot-brake torque (the split; `0.5` = even). |
| `tuning_grip_authority` | `0.15` | Max grip fraction shifted front↔rear at slider \|1\|. |
| `tuning_brake_authority` | `0.3` | Half-span of `brake_bias` the slider moves from `0.5`. |
| `tuning_aero_authority` | `0.5` | Max downforce fraction shifted front↔rear at slider \|1\|. |

`repair_kit_hp` (`Damage` group, default `300`) is the HP one Repair Kit restores at
the lift (clamped to max HP by `Save.use_repair_kit`).

## The tuning lift (UI)

The garage **tuning lift** ([menus.md](menus.md)) is where this is driven. The
player always has one owned car **selected** (`Save.selected_car` /
`set_selected_car`); it is the car raised on the lift. Clicking the lift flies the
camera to the bay, framing the car to one side (`hq_lift_cam_*`) so the menu panel —
anchored to the other side (`hq_lift_menu_width_frac`) — never covers it. Two menus:

- **Tune** — one slider per axis (locked axes greyed with a "needs X kit" note) plus
  **Reset to neutral**. Each change saves immediately via `Save.set_tuning`.
- **Upgrades** — per-slot install/remove from the inventory (`Save.install_upgrade` /
  `uninstall_upgrade`, parts returned on swap) plus the **Repair Kit** action
  (`Save.use_repair_kit`). Re-spawns the raised car so its body reflects the change.

A change-car control cycles all owned cars (updating the selection), shared by both
menus.

## Tests

- `tests/headless/test_tuning_library.gd` — neutral is a no-op; grip shifts rearward
  monotonically and needs no upgrade; aero/brake-bias gating; slider clamp.
- `tests/headless/test_drivetrain.gd` — the brake-bias split sends the foot brake to
  the chosen axle (`brake_bias` 1.0 locks the front, 0.0 the rear); `0.5` regression.
- `tests/headless/test_menu_flow.gd` — the lift raises the selected car; sliders save
  per-car; locked sliders gate by upgrade; changing the lift car updates the
  selection; installing a part from the upgrades menu.
