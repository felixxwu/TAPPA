# Per-car tuning

**Sources:** `scripts/tuning_library.gd` (`TuningLibrary`), the brake-bias split in
`scripts/drivetrain.gd`, the `Tuning` group in `scripts/game_config.gd`, the
fielding hook in `scripts/car.gd` (`apply_owned`), and the tuning-lift UI in
`scripts/hq.gd`. Player state lives on each `OwnedCar` (`Save`,
[save-persistence.md](save-persistence.md)).

**Tuning** is the **free, reversible** half of *Tuning & upgrades* — handling
nudges the player makes at the garage **tuning lift**, as distinct from consumable
**upgrades** ([upgrade-catalogue.md](upgrade-catalogue.md)). Tuning is stored as
per-car deltas, costs nothing, and is reset instantly; it is never written back to
the authored `.tres`.

## The three axes

Each owned car stores `tuning = { grip_balance, brake_bias, aero_balance,
engine_detune }`. The first three are a single normalized slider in `[-1, +1]`,
default `0` (= the baseline, neutral); `engine_detune` is a direct `[0, 1]`
torque scale, default `1.0` (full power).

| Axis | Slider | Maps to | Gated by |
|------|--------|---------|----------|
| `grip_balance` | −1 understeer ↔ +1 oversteer | shifts `wheel_friction_slip_front`/`_rear` | always available |
| `brake_bias` | −1 rearward ↔ +1 forward | the front/rear `brake_bias` split (drivetrain) | the **brakes** upgrade (`unlocks_brake_bias`) |
| `aero_balance` | −1 front ↔ +1 rear | shifts `downforce_front`/`_rear` | the **aero** upgrade (`unlocks_aero_tuning`) |
| `engine_detune` | 0% ↔ 100% torque | `cfg.peak_torque *= detune` | always available |

**`engine_detune`** ([engine-swap.md](engine-swap.md)) is the odd one out: it's
not a symmetric ±1 balance shift but a direct `0–100%` scale on the fitted
engine's torque, applied by `TuningLibrary.apply` **last** (after grip/brake/
aero) so it scales whatever torque the swapped-in engine + upgrade kits
produced. It needs no upgrade to unlock — every car can be detuned, e.g. to
duck under a rally's power-to-weight ceiling. **Reset to neutral** returns it
to `1.0` (100%, full power), same as the other axes reset to their own
neutral (`0`). It also feeds `UpgradeLibrary.effective_meta`, so a detuned
car's reduced torque affects displayed power-to-weight and rally eligibility,
not just the live-fielded car. The car park offers this as a one-press prompt:
an over-powered car (over a rally's `pw_max` cap) still parks in the rally
lineup with Start relabelled **Detune to N% & Start**, which applies the
qualifying tune (`RallyLibrary.qualifying_detune`) on agreement — see
[menus.md](menus.md) → CARPARK. The slider's value label pairs the percent with
the car's live power-to-weight at that setting (e.g. `80% - 200 hp/tonne`, via
`hq.gd._detune_label_text` → `effective_meta`), so you can dial to a target band
by eye. (All tuning-lift sliders share one fixed-width label column so they line
up to the same length regardless of value text.)

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
and the gating reads the same upgrades (only **enabled** parts count — a part
toggled off in the upgrades menu neither changes the baseline nor unlocks sliders). Each axis is a symmetric shift of
its config pair scaled by a `GameConfig` authority knob, so a slider can never zero
or invert a value:

- **grip:** `front *= (1 − t·grip_authority)`, `rear *= (1 + t·grip_authority)`.
- **aero:** same shape on `downforce_front`/`_rear`, **only** with the aero kit; a
  no-op otherwise.
- **brake bias:** each car authors its own default `brake_bias` in `CarLibrary`,
  seeded onto `cfg` by `apply_car`. With the brakes kit the slider shifts it about
  that per-car baseline: `brake_bias += t·brake_authority`; without the kit the car
  keeps its default (so a re-fielded car can't keep an unlocked bias). Free-roam
  (`apply_car`, no `OwnedCar`) uses the car's default directly. A car that omits the
  field falls back to the `GameConfig.brake_bias` default.

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
| `brake_bias` | `0.5` | Fallback front share of foot-brake torque (`0.5` = even). Only used for a car that omits its own `brake_bias`; otherwise `CarLibrary.apply_car` seeds it per-car. |
| `tuning_grip_authority` | `0.15` | Max grip fraction shifted front↔rear at slider \|1\|. |
| `tuning_brake_authority` | `0.3` | Half-span of `brake_bias` the slider moves from the car's default. |
| `tuning_aero_authority` | `0.5` | Max downforce fraction shifted front↔rear at slider \|1\|. |

A Repair Kit **fully restores** a car's health (`Save.use_repair_kit`) — there is no
partial-heal tunable. The lift shows **Health** as a percentage (not a raw HP number,
which reads as horsepower) and flags a wrecked (0%) car.

## The tuning lift (UI)

The garage **tuning lift** ([menus.md](menus.md)) is where this is driven. The
player always has one owned car **selected** (`Save.selected_car` /
`set_selected_car`); it is the car on the lift — resting lowered on the ground in the
garage and **raised slowly by the lift** when the bay is entered (`hq_lift_raise_time`,
between `hq_lift_car_lowered_height` and `hq_lift_car_height`). Clicking the lift flies
the camera to the bay, framing the car to one side (`hq_lift_cam_*`). The bay opens on
a **hub** (`LiftPage.HUB`): the car's name/description bottom-left beside the car, with
a **minimal change-car selector** (cycles all owned cars, updating the selection) and
**Tuning** / **Upgrades** buttons under it. Each button opens that menu as its own
full-height page (a panel on the other side, `hq_lift_menu_width_frac`, so the car
stays in view); a **< Back** returns to the hub, and the hub's Back returns to the
garage. Splitting the menus onto their own pages keeps each one from needing to scroll.

- **Tune** (`LiftPage.TUNE`) — one row per axis (locked axes greyed with a "needs X
  kit" note) plus **Reset to neutral**. Each row uses horizontal space: a left column
  with the axis name above its current value, beside a right column with the slider above
  its two extremity labels. Each change saves immediately via `Save.set_tuning`.
- **Upgrades** (`LiftPage.UPGRADES`) — per slot: Enable/Disable toggles for each
  applied part (`Save.set_upgrade_enabled`; free and reversible, one enabled per
  slot) and an **Apply** button per matching unlocked item (`Save.install_upgrade`;
  applying consumes the item from the unlocked pool and fits it to this car for
  good, confirmed via a dialog first). Plus the **Repair
  Kit** action — shows Health as a percentage and, when a kit is owned and the car isn't
  full, a **restore-to-full** button (`Save.use_repair_kit`). Re-spawns the raised car
  so its body reflects the change.

## Tests

- `tests/headless/test_tuning_library.gd` — neutral is a no-op; grip shifts rearward
  monotonically and needs no upgrade; aero/brake-bias gating; slider clamp.
- `tests/headless/test_drivetrain.gd` — the brake-bias split sends the foot brake to
  the chosen axle (`brake_bias` 1.0 locks the front, 0.0 the rear); `0.5` regression.
- `tests/headless/test_menu_flow.gd` — the lift raises the selected car; sliders save
  per-car; locked sliders gate by upgrade; changing the lift car updates the
  selection; installing a part from the upgrades menu.
