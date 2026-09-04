# Per-car tuning

**Sources:** `scripts/tuning_library.gd` (`TuningLibrary`), the brake-bias split in
`scripts/drivetrain.gd`, the `Tuning` group in `scripts/game_config.gd`, the
fielding hook in `scripts/car.gd` (`apply_owned`), the reusable slider UI in
`scripts/tuning_panel.gd` (`TuningPanel`), and its one remaining host — the pre-event
start line (`scripts/start_line.gd`). The garage tuning lift, its other host, is deleted
with the diegetic hub.
Player state lives on each `OwnedCar` (`Save`,
[save-persistence.md](save-persistence.md)).

**Tests:** `tests/headless/test_tuning_library.gd`, `tests/headless/test_tuning_panel.gd`, `tests/headless/test_drivetrain.gd`

**Tuning** is the **free, reversible** per-car handling nudge, made at the start line
before a stage. It used to be the free half of *Tuning & upgrades*, opposite the
persistent parts model — that model is deleted, and what
[upgrade-catalogue.md](upgrade-catalogue.md) documents now is the effects funnel run
boosts and perks share. Tuning is **ungated on every axis** (decision 24); the "needs X
kit" locks below are gone with the parts that set them. A third, purely
**cosmetic** system — swapping any car's wheels onto this one — shares tuning's
free-and-reversible character but touches no stat at all; see
[wheel-customization.md](wheel-customization.md). Tuning is stored as
per-car deltas, costs nothing, and is reset instantly; it is never written back to
the authored `.tres`.

## The three axes

Each owned car stores `tuning = { grip_balance, brake_bias, aero_balance,
engine_detune }`. The first three are the **handling axes** — a single
normalized slider in `[-1, +1]`, default `0` (= the baseline, neutral) — and are
the only entries in `TuningLibrary.AXES`; `engine_detune` is a direct `[0, 1]`
torque scale, default `1.0` (full power), stored in the same `tuning` bag but with **no
slider anywhere** (see below).

| Axis | Slider | Maps to | Gated by |
|------|--------|---------|----------|
| `grip_balance` | −1 understeer ↔ +1 oversteer | shifts `wheel_friction_slip_front`/`_rear` | always available |
| `brake_bias` | −1 rearward ↔ +1 forward | the front/rear `brake_bias` split (drivetrain) | always available |
| `aero_balance` | −1 front ↔ +1 rear | shifts `downforce_front`/`_rear` | always available (decision 24 ungated it) |

**`grip_balance` changed character with grip-servo steering** ([car-physics.md](car-physics.md)
→ Steering). It trims each axle's **μ** — the force a tire makes at a given slip — not
`slip_peak`, which is *where* that peak sits. The steering servo targets **slip**, so front
grip tuning no longer changes how far the car can turn; it changes how much force the car gets
for turning that far. The slider still shifts the understeer/oversteer balance, but the felt
mechanism is force, not angle.

**`engine_detune`** ([engine-swap.md](engine-swap.md)) is stored in the per-car
`tuning` bag alongside the three handling axes, and `TuningLibrary.apply` still
reads it and applies it **last** (after grip/brake/aero) — a direct `0–100%`
scale on the fitted engine's torque, so it scales whatever torque the swapped-in
engine + upgrade kits produced. But it is **not** a `TuningLibrary.AXES` entry
and it has **no slider at all right now**: it was never in the tuning panel (detune is a
power / power-to-weight knob, not a handling axis), it lived in the `UpgradesGrid`'s
`tune` tile, and that grid is deleted with the parts model.

**So the field is stored, read and applied, but unreachable.** `Save.set_engine_detune` and
`TuningLibrary.apply`'s clamp are both live, and it still feeds
`UpgradeLibrary.effective_meta`, so a detuned car reads as less powerful everywhere — which
matters for the Rally Challenge's rating ceiling, the one place a car can still be too
powerful to enter ([rally-challenge.md](rally-challenge.md)). A future screen that wants to
let a player duck under that ceiling has the whole mechanism waiting; nothing today writes
it.
An over-ceiling car (over a Rally Challenge's performance ceiling — career rallies have
none) still parks in the lineup
with a plain Start; pressing Start pops a **"Too powerful"** prompt whose only
route through is **Change Upgrades**, which opens the gated upgrades menu so the
player sheds power themselves (detune slider / ballast / stripping parts). That
fix is a **permanent** garage edit — it persists after the rally, not a temporary
per-rally detune — and once the build is under the cap the player closes the menu
and re-presses Start to launch. See [menus.md](menus.md) →
CARPARK. The **pre-event start-line** menu offers the same
Change-Upgrades prompt on Start (see [start-line.md](start-line.md)). (Rallies
have no hard power floor, so an underpowered car can still enter a higher class — it
just gets a non-blocking "Underpowered" warning at car selection in the HQ car park.) In the
upgrades grid the detune slider lives behind the `tune` tile, and its value label reads the
car's live power-to-weight at that setting (`200 HP/T`, via
`UpgradesGrid._detune_label_text` → `effective_meta`) while the tile beneath carries the
percentage — the slider is the place you care about the OUTCOME, so you can dial to a
target band by eye. The label shows **only** that power-to-weight readout — no
cap or limit text — the whole-build **performance rating** and any ceiling live in the
page's own readout row and on the **gated close button** (which turns red and blocks
closing while over — see [menus.md](menus.md)). Hosts source that ceiling from
`DrivingContext.rating_limit()`; only a Rally Challenge has one, and the HQ lift omits it
for free tuning. The
detune slider always spans the full 0–100 % — eligibility is enforced by that
gated button, not by capping the slider.

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

- **grip:** `front *= (1 + t·grip_authority)`, `rear *= (1 − t·grip_authority)` — so
  `+1` (oversteer) adds front grip / removes rear grip, and `−1` (understeer) is the mirror.
- **aero:** same shape on `downforce_front`/`_rear`, **only** with the aero kit; a
  no-op otherwise. The aero kit's visual wing (spoiler/splitter) is covered in [aero-parts.md](aero-parts.md).
- **brake bias:** each car authors its own default `brake_bias` in `CarLibrary`,
  seeded onto `cfg` by `apply_car`. The slider shifts it about that per-car
  baseline: `brake_bias += t·brake_authority`, ungated (no upgrade needed). Free-roam
  (`apply_car`, no `OwnedCar`) uses the car's default directly. A car that omits the
  field falls back to the `GameConfig.brake_bias` default.

Tuning is resolved **once at fielding**, like `apply_car` — not re-applied mid-run.

**Live re-derive baseline (start line).** `Car.retune` (tune change) and
`Car.refit_upgrades` (upgrade change) re-derive the live config without re-fielding.
Both go through one shared `Car._rederive_live_config`: restore a **single full baseline**
(`_live_baseline`, a `{property: value}` snapshot of every `GameConfig` script variable,
captured once at fielding after `apply_car` + engine swap, before upgrades/tuning), then
re-apply the upgrade and tuning layers top-to-bottom. `refit_upgrades` additionally
re-syncs mass / suspension / drivetrain / engine audio (a turbo or drivetrain change
touches those). Because every re-derive starts from the *complete* baseline, no field can
carry stale state from a prior upgrade/tuning into the next re-derive — the class of bug
where `refit` left an old detune baked into `peak_torque` (a "really slow" car that could
never climb back to full power) is impossible by construction. There is deliberately no
per-library "touched fields" list to drift out of sync with `apply()`. The baseline is a
plain dict rather than `config.duplicate()` because the live engine fields (`peak_torque`,
`redline`, …) are non-`@export` vars that `Resource.duplicate()` would reset to defaults.
Regressions: `test_retune.gd` — `test_refit_then_retune_matches_a_fresh_field_no_compounding`
(+ grip / aero-overlap / opposite-order / repeated-refit siblings), all asserting the
invariant *live re-derive == a fresh `apply_owned` of the same final state*.

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

Health is restored only by the free between-event field repair (tuned by the
`field_repair_*` fractions — see [damage.md](damage.md)); there is no full-restore
action and a wrecked car never comes back. The lift shows **Health** as a percentage
(not a raw HP number, which reads as horsepower) and flags a wrecked (0%) car.

## The tuning UI (`TuningPanel`)

The three handling-axis sliders live in one reusable control, `TuningPanel`
(`scripts/tuning_panel.gd`, a `VBoxContainer`), shared by both places tuning is
offered. Each labeled slider row (name + value column, slider, extremity labels,
and the focus highlight) is built by the shared `SliderRow.build` helper
(`scripts/slider_row.gd`), which the upgrades grid's detune slider popup uses too
(`UpgradeSlotPopup.open_slider`) — so a slider looks and behaves the same wherever the
game offers one. It owns the slider rows, the **Reset to neutral** action, and the
immediate `Save.set_tuning`
persistence; a host binds it with `setup(owned_car, on_change, on_wheels := Callable())`
and calls `refresh()`, and is notified via `on_change` after each edit so it can re-field
the car. There are no locked axes to grey out any more: tuning is ungated on every axis
(decision 24), and `TuningLibrary.axis_unlocked` went with the parts model that gated it.
**Reset to neutral** clears the three handling axes back to `0`.

### The action buttons live in the HOST's bottom row

`TuningPanel` **builds** its two action buttons — **Reset to neutral** (`_reset_button`) and
**Wheels** (`_wheels_button`) — but deliberately does **not** parent them. It exposes them via
`action_buttons() -> Array[Button]` (in left-to-right order) and the HOST places them in the
page's single centred bottom action row, beside that page's own `< Back`: `start_line.gd` →
`_build_menu_overlay` picks them up generically via
`component.has_method("action_buttons")`, which is the pattern for any future host (the
deleted lift overlay did the same by name). They used to be full-width rows
stacked inside the panel's own body, which made the page read as a different kind of screen —
see [ui-design-system.md](ui-design-system.md) → *A page's actions go in ONE bottom row*. A host
that never adds them shows them nowhere and never frees them.

The **Wheels** button (native `FOCUS_ALL` like the sliders and Reset) fires `on_wheels()`.
`on_wheels` defaults to an invalid `Callable`, and `TuningPanel` **hides** the button
whenever the host did not wire one (`_wheels_button.visible = _on_wheels.is_valid()`) — the
start line has nowhere sensible to send a mid-run wheel swap, so it leaves `on_wheels`
unset and the button is hidden. **That makes the button unreachable today**: its only host
was the HQ lift, which wired it to the car park's solo wheel view. See
[wheel-customization.md](wheel-customization.md).

`TuningPanel`'s sibling for the upgrades half, `UpgradesGrid` (`scripts/upgrades_grid.gd`),
is deleted with the parts model — and with it the **engine detune** slider it owned. Only
the handling axes are tunable now.

- **Pre-event start line** (`start_line.gd`) — a **Tune Car** button under
  **Start** opens a centered overlay hosting the panel, bound to the car
  about to race (`Save.get_car(RunSession.car_instance_id())`). Its `on_change`
  calls **`Car.retune`** (NOT `apply_owned`): tuning only shifts config fields
  read live each physics step, so `retune` restores the pre-tuning baseline (a
  snapshot taken in `apply_owned` before `TuningLibrary.apply`) and re-applies the
  new tuning — no wheel relocation, pose reset, or engine rebuild. Re-fielding a
  live, staged `VehicleBody3D` via `apply_owned` would relocate its wheels
  (detach/re-attach) and reset its pose, corrupting the body (wheels drop through
  the floor — see the `Car.respawn` note). Handling tuning only: the start line's
  **Upgrades** overlay, which used to host the engine detune and enforce a rating
  ceiling on closing, is deleted with the parts model. Car swaps are not offered.

## The tuning lift is DELETED

Tuning's other home was the garage **tuning lift** — a diegetic 3D bay in `hq.tscn` where
the selected car rose on a platform beam and the camera flew to a front three-quarter
shot, with a hub page offering Tune / Upgrades / Test Drive and a `[ < ] [ CAR ] [ > ]`
selector that swapped the car on the lift in place. All of it went with the hub (decision
9), along with the `UpgradesGrid` page beside it and the `SettingsMenu` dev-page hook that
rebuilt the lift car after a dev fit.

**The start line is the only place tuning is offered now.** Nothing in the flat hub tunes a
car — see [hub-shell.md](hub-shell.md) for what its pages do offer. `Save.selected_car` /
`set_selected_car` (the "car on the lift" pointer) still exist and are still persisted; see
[save-persistence.md](save-persistence.md).

## Tests

- `tests/headless/test_tuning_library.gd` — neutral is a no-op; grip shifts rearward
  forward (oversteer) monotonically; brake bias is tunable; every axis is ungated
  (decision 24); slider clamp.
- `tests/headless/test_drivetrain.gd` — the brake-bias split sends the foot brake to
  the chosen axle (`brake_bias` 1.0 locks the front, 0.0 the rear); `0.5` regression.
- `tests/headless/test_tuning_panel.gd` — the shared `TuningPanel` in isolation: a
  slider per axis, editing writes the axis + fires `on_change`, Reset clears the deltas,
  and a tune bakes into the config via `TuningLibrary.apply`. (The lift-hosted cases that
  lived in `test_menu_flow.gd` went with the lift.)
- `tests/headless/test_start_line.gd` — the pre-event overlay offers a focusable
  **Tune Car** button; opening it shows the tuning overlay (hiding Start) and Back
  returns.
- `tests/headless/test_retune.gd` — `Car.retune` applies a changed tuning to the
  live config, is idempotent (no compounding), and does NOT reshape/reset the body
  (the start-line drop-through-floor regression).
