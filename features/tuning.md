# Per-car tuning

**Sources:** `scripts/tuning_library.gd` (`TuningLibrary`), the brake-bias split in
`scripts/drivetrain.gd`, the `Tuning` group in `scripts/game_config.gd`, the
fielding hook in `scripts/car.gd` (`apply_owned`), the reusable slider UI in
`scripts/tuning_panel.gd` (`TuningPanel`), and its two hosts — the garage tuning
lift (`scripts/hq.gd`) and the pre-event start line (`scripts/start_line.gd`).
Player state lives on each `OwnedCar` (`Save`,
[save-persistence.md](save-persistence.md)).

**Tuning** is the **free, reversible** half of *Tuning & upgrades* — handling
nudges the player makes at the garage **tuning lift**, as distinct from consumable
**upgrades** ([upgrade-catalogue.md](upgrade-catalogue.md)). A third, purely
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
torque scale, default `1.0` (full power), stored in the same `tuning` bag but
**no longer a tuning-panel slider** (see below).

| Axis | Slider | Maps to | Gated by |
|------|--------|---------|----------|
| `grip_balance` | −1 understeer ↔ +1 oversteer | shifts `wheel_friction_slip_front`/`_rear` | always available |
| `brake_bias` | −1 rearward ↔ +1 forward | the front/rear `brake_bias` split (drivetrain) | always available |
| `aero_balance` | −1 front ↔ +1 rear | shifts `downforce_front`/`_rear` | the **aero** upgrade (`unlocks_aero_tuning`) |

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
and its **slider no longer lives in the tuning panel** — it moved to the
**upgrades grid** (`UpgradesGrid`, behind its `tune` tile), because detune is a power / power-to-weight
knob rather than a handling axis. It needs no upgrade to unlock — every car can
be detuned, e.g. to duck under a rally's power-to-weight ceiling. (Detune isn't
the only p/w lever — the weight slot's **free ballast** adds mass to drop p/w the
other way; see [upgrade-catalogue.md](upgrade-catalogue.md).) It also feeds
`UpgradeLibrary.effective_meta`, so a detuned car's reduced torque affects
displayed power-to-weight and rally eligibility, not just the live-fielded car.
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
game offers one. It owns the slider rows, the locked-axis greying/"needs X kit" notes,
the **Reset to neutral** action, and the immediate `Save.set_tuning`
persistence; a host binds it with `setup(owned_car, on_change, on_wheels := Callable())`
and calls `refresh()`, and is notified via `on_change` after each edit so it can re-field
the car. **Reset to neutral** clears only the three handling axes back to `0`
and **preserves** `tuning.engine_detune` (detune is now owned by the upgrades
menu, so tuning no longer resets it to full power).

### The action buttons live in the HOST's bottom row

`TuningPanel` **builds** its two action buttons — **Reset to neutral** (`_reset_button`) and
**Wheels** (`_wheels_button`) — but deliberately does **not** parent them. It exposes them via
`action_buttons() -> Array[Button]` (in left-to-right order) and the HOST places them in the
page's single centred bottom action row, beside that page's own `< Back`: `hq_overlays.gd` →
`build_lift_overlay` adds them to `_lift_page_actions` (kept as `hq._tune_action_buttons` so
gating is a loop, not named buttons), and `start_line.gd` → `_build_menu_overlay` picks them up
generically via `component.has_method("action_buttons")`. They used to be full-width rows
stacked inside the panel's own body, which made the page read as a different kind of screen —
see [ui-design-system.md](ui-design-system.md) → *A page's actions go in ONE bottom row*. A host
that never adds them shows them nowhere and never frees them.

The **Wheels** button (native `FOCUS_ALL` like the sliders and Reset) fires `on_wheels()` — the
HQ lift wires it to `_enter_wheel_swap`, leaving the lift for the car park's solo
wheel view (see [wheel-customization.md](wheel-customization.md)). It moved here
from the lift hub row so Wheels is reached *through* Tuning rather than sitting
alongside it. `on_wheels` defaults to an invalid `Callable`, and `TuningPanel`
**hides** the button whenever the host didn't wire one (`_wheels_button.visible =
_on_wheels.is_valid()`) — the start-line's copy of the panel (below) has nowhere
sensible to send a mid-rally wheel swap, so it leaves `on_wheels` unset and the
button stays hidden there.

`TuningPanel` has a sibling for the **upgrades** half: `UpgradesGrid`
(`scripts/upgrades_grid.gd`, also a reusable `VBoxContainer` with the same
`setup(owned, on_change, …)` shape), shared by the HQ lift, the car-park
detune-to-enter prompt's Change-Upgrades popup, the start line and the reward reveal — see
[upgrade-catalogue.md](upgrade-catalogue.md). `UpgradesGrid` also owns the
**engine detune**, as a `tune` tile in its grid whose popup is a slider (0–100%, step 5)
with the power-to-weight value label described above (the rating ceiling lives on the
page's performance readout and the gated close button, not on this label) and its
immediate `Save.set_engine_detune` persistence.

- **Garage tuning lift** (`hq.gd`, `LiftPage.TUNE`) — embeds the panel with a
  no-op `on_change` (the change lands on the car's next fielding) and
  `on_wheels = _enter_wheel_swap`, so the Wheels button is shown here.
- **Pre-event start line** (`start_line.gd`) — a **Tune Car** button under
  **Start** opens a centered overlay hosting the same panel, bound to the car
  about to race (`Save.get_car(RallySession.car_instance_id())`). Its `on_change`
  calls **`Car.retune`** (NOT `apply_owned`): tuning only shifts config fields
  read live each physics step, so `retune` restores the pre-tuning baseline (a
  snapshot taken in `apply_owned` before `TuningLibrary.apply`) and re-applies the
  new tuning — no wheel relocation, pose reset, or engine rebuild. Re-fielding a
  live, staged `VehicleBody3D` via `apply_owned` would relocate its wheels
  (detach/re-attach) and reset its pose, corrupting the body (wheels drop through
  the floor — see the `Car.respawn` note). Handling tuning only — the
  engine detune now lives in the start line's **Upgrades** overlay
  (`UpgradesGrid`, behind its `tune` tile), which is where `StartLine._rating_limit()` is passed so the overlay's
  gated **Done** button enforces the ceiling (red, blocks closing while over); car swaps
  are not offered.

## The tuning lift (UI)

The garage **tuning lift** ([menus.md](menus.md)) is where this is driven. The
player always has one owned car **selected** (`Save.selected_car` /
`set_selected_car`); it is the car on the lift — resting lowered on the ground in the
garage and **raised slowly by the lift** when the bay is entered (`hq_lift_raise_time`,
between the lowered pose and `hq_lift_car_height`). The lowered pose is not a fixed
constant — when lowered the car rests on the lot **floor** (`hq_lift_pos.y`) at its
**calculated body rest** height (`hq.gd` → `_lift_car_lowered_height`, from `car.gd` →
`settled_ride_height`), exactly as it sits parked, so each car settles on its own
suspension (a low sports car lower than a tall 4x4) rather than being floated up by the
beam thickness. The **platform beam**
the car rests on (`hq_environment.gd` → `_build_lift`, sized by `hq_lift_platform_size`
— a short strip that spans post-to-post but tucks into the gap between the wheels)
rides up and down **with** the car; both are tweened in parallel by
`hq.gd` → `_apply_lift_height`. Clicking the lift flies
the camera to the bay, framing the car as a **front** three-quarter shot
(`hq_lift_cam_*` — see the export's doc comment in `game_config.gd` for why the eye sits round
at −Z, in front of the nose-out car, and on the −X side). The bay opens on
a **hub** (`LiftPage.HUB`): bottom-left, TWO boxed readout rows — the **car selector**
`[ < ] [ CAR NAME ] [ > ]` over the car's **stats line** — with the actions row
**< Back / Upgrades / Tuning / Test Drive** under them. The chevrons put the previous / next
owned car on the lift **in place** (`hq.gd` → `_cycle_lift_car`), so swapping cars no longer
means backing out to the garage; the hub is a two-row cursor (up/down between rows, left/right
within one) — see [menus.md](menus.md) → *Menu navigation* and *LIFT*. Each menu button opens
that menu as its own page — a `MenuPage` whose body box is centred and sized to its contents
(see [menus.md](menus.md) → *Upgrades / Tune panel width*), with the car readout hidden while
it's up; the page's bottom action row leads with a
**< Back** that returns to the hub, and the hub's Back returns to the
garage. Splitting the menus onto their own pages keeps each one from needing to scroll.

- **Tune** (`LiftPage.TUNE`) — one row per axis (locked axes greyed with a "needs X
  kit" note), with **Reset to neutral** and **Wheels** in the page's bottom action row
  beside `< Back` (shown only while this page is up — `hq.gd` → `_refresh_lift_ui`, set
  after `_tune_panel.setup`, which reasserts the Wheels button's own visibility on every
  refresh). Each row uses horizontal space: a left column
  with the axis name above its current value, beside a right column with the slider above
  its two extremity labels. Each change saves immediately via `Save.set_tuning`.
- **Upgrades** (`LiftPage.UPGRADES`) — the reusable `UpgradesGrid` component
  (`scripts/upgrades_grid.gd`): a heading row carrying the star balance, a single
  `PERFORMANCE` line, and a 3-column grid of icon **tiles**, one per
  `UpgradeOptions.grid_slots()` entry — the seven catalogue slots plus the `engine`
  (swap) and `tune` (detune) pseudo-slots, so every lever the page offers is found by
  looking rather than by scrolling. A tile reads `<slot>: <current pick>` and opens
  `UpgradeSlotPopup` listing that slot's options, with locked ones shown greyed and
  captioned with their reason and buyable ones carrying a star price. Upgrades are
  **car-bound**: nothing is consumed from an unlocked pool — picking an option toggles the
  part on/off via `Save.set_upgrade_enabled` (one enabled per slot), or buys it first
  (drivetrain is instead an RWD/AWD/FWD pick). See
  [upgrade-catalogue.md](upgrade-catalogue.md) and [engine-swap.md](engine-swap.md).
  (There is no Repair action any more — see [damage.md](damage.md).)

**Dev-page fits rebuild the lift car too.** `SettingsMenu`'s Dev sub-page (title screen →
Settings → Dev) can fit any upgrade straight onto `Save.selected_instance_id()` for
testing — but it has no reference back to whichever host has that car on screen, so a
plain `Save.install_upgrade` there would leave an already-fielded car (the lift) showing
stale stats until you left and re-entered. `SettingsMenu.dev_car_upgraded` closes that
gap: `hq.gd::_on_dev_car_upgraded` (connected in `hq_overlays.gd`, alongside
`page_changed`) reruns the same rebuild `_on_lift_upgrade_changed` runs for the real
upgrades menu — `_ensure_lift_car()` (the changed `installed_upgrades` flips the cached
`owned.hash()`, so it doesn't skip the rebuild) then `_refresh_lift_car_label()`. Only
wired for HQ; the in-run pause menu (`pause_menu.gd`) also hosts `SettingsMenu` but has
no lift to rebuild, and refitting the car you're actively driving mid-run is a separate,
unhandled concern. See `tests/headless/test_menu_flow.gd` →
`test_dev_page_upgrade_fit_rebuilds_the_lift_car`.

## Tests

- `tests/headless/test_tuning_library.gd` — neutral is a no-op; grip shifts rearward
  forward (oversteer) monotonically and needs no upgrade; brake bias is tunable with no
  upgrades; aero gating; slider clamp.
- `tests/headless/test_drivetrain.gd` — the brake-bias split sends the foot brake to
  the chosen axle (`brake_bias` 1.0 locks the front, 0.0 the rear); `0.5` regression.
- `tests/headless/test_menu_flow.gd` — the lift raises the selected car; sliders save
  per-car; locked sliders gate by upgrade; changing the lift car updates the
  selection; installing a part from the upgrades menu.
- `tests/headless/test_tuning_panel.gd` — the shared `TuningPanel` in isolation: a
  slider per axis, editing writes the axis + fires `on_change`, locked axes aren't
  editable, Reset clears the deltas, and a tune bakes into the config via
  `TuningLibrary.apply`.
- `tests/headless/test_start_line.gd` — the pre-event overlay offers a focusable
  **Tune Car** button; opening it shows the tuning overlay (hiding Start) and Back
  returns.
- `tests/headless/test_retune.gd` — `Car.retune` applies a changed tuning to the
  live config, is idempotent (no compounding), and does NOT reshape/reset the body
  (the start-line drop-through-floor regression).
