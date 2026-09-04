# Controls / Input Map

Defined in `project.godot` `[input]`. Handled mainly by `scripts/car.gd`; the
HUD buttons mirror the gearbox/drive-mode toggles.

**Tests:** `tests/headless/test_input_remap.gd`, `tests/headless/test_mobile_controls.gd`, `tests/headless/test_menu_nav.gd`

| Action | Key | Alt | Controller | Effect |
|--------|-----|-----|------------|--------|
| `accelerate` | W | ↑ | Right Trigger (RT/R2) | Throttle forward (reverse throttle in R gear) |
| `brake_reverse` | S | ↓ | Left Trigger (LT/L2) | Brake / reverse |
| `steer_left` | A | ← | Left stick ← | Steer left |
| `steer_right` | D | → | Left stick → | Steer right |
| `shift_up` | E | — | Right bumper (RB/R1) | Manual upshift |
| `shift_down` | Q | — | Left bumper (LB/L1) | Manual downshift |
| `handbrake` | Space | — | A / Cross (South) | Rear-axle handbrake (drift) |
| `nitrous` | Left Shift | — | X / Square (West) | Held: spray nitrous while on throttle (see [nitrous.md](nitrous.md)) |
| `cycle_camera` | C | R | Y / Triangle (North) | Cycle through cameras |
| `pause` | — | — | Start | Open the pause menu (Esc / B also toggle it) |
| `toggle_map` | M | — | Back | Opened the overworld's full map; **the overworld is deleted, so this action is unbound to anything**. Kept in `project.godot`, out of `InputRemap.ACTIONS` (that list is the driving controls) |
| `toggle_debug_arrows` | H | — | — | Show/hide force debug overlay + the speed/gear/rpm readout |
| `toggle_perf_overlay` | P | — | — | Show/hide frame profiler overlay |
| `skip_to_finish` | F | — | — | Dev: instantly complete the current event |
| `menu_up` | W | ↑ | D-pad up | Menu navigation: move up |
| `menu_down` | S | ↓ | D-pad down | Menu navigation: move down |
| `menu_left` | A | ← | D-pad left | Menu navigation: move left |
| `menu_right` | D | → | D-pad right | Menu navigation: move right |
| `menu_select` | Enter | — | A / Cross (South) | Menu navigation: activate focused widget |
| `menu_back` | Esc | — | B / Circle (East) | Menu navigation: back out / cancel |
| `reload_config` | F8 | — | — | Dev: re-read `config/game_config.tres` from disk and re-apply, no restart |
| `toggle_world_menus` | F7 | — | — | Dev: toggle A/B world-space menus against the flat overlays (see [debug-tools.md](debug-tools.md)) |
| `dev_complete_rally` | F12 | — | — | Dev: instantly complete the current rally |

All actions use a 0.2 deadzone.

There is **no gearbox toggle input** any more. Manual vs automatic transmission is a
**setting** — Settings → **Gearbox** (`scripts/settings_menu.gd` → `_build_gearbox_page`
/ `select_gearbox`), persisted under `SettingsMenu.GEARBOX_SETTING_KEY` and defaulting
to the authored `GameConfig.auto_gearbox`. `car.gd` mirrors `SettingsMenu.gearbox_auto()`
onto the live engine every tick while the driver is in control, so changing it from the
in-run pause menu applies straight away. The old `toggle_gearbox` (T) action was retired:
T is unreachable on a phone, no mobile control scheme has shift buttons at all (so touch
players need automatic), and its controller button was reassigned to `nitrous`.

There is **no direct "reset car" input** — resetting the car onto the track is only
available from the pause menu's "Reset to track" (`scripts/pause_menu.gd` →
`_on_reset_to_track_pressed`, routed through `world.gd`). The R key and the gamepad
North button (Y/Triangle) that used to reset now cycle the camera instead.

## Rebinding (settings → Key bindings)

Only the driving/menu actions listed in `scripts/input_remap.gd`'s `ACTIONS` can be
**rebound**: `accelerate`, `brake_reverse`, `steer_left`, `steer_right`, `shift_up`,
`shift_down`, `handbrake`, `nitrous`, `cycle_camera` and `pause`. Everything else in the
table above is **not** rebindable — the keyboard-only debug overlays
(`toggle_debug_arrows`, `toggle_perf_overlay`), the dev-only actions (`skip_to_finish`,
`reload_config`, `toggle_world_menus`, `dev_complete_rally`), `toggle_map` (see above),
and the `ui_*`/`menu_*` navigation actions are all excluded — on
the **Key bindings** page of the shared settings menu (`scripts/settings_menu.gd`) —
reachable from the title-screen Settings and the in-run pause menu alike. Each action
gets a row with a **keyboard** button and a **controller** button showing its current
binding; tap one and press the new key / gamepad input to reassign it (Esc cancels).
A **Reset to defaults** row clears all overrides.

The model is the `InputRemap` autoload (`scripts/input_remap.gd`):

- At boot it **snapshots** the pristine `project.godot` bindings, then applies the
  player's saved overrides on top of them (`apply_saved`). Because the InputMap is
  global, this must run before any scene reads input — hence an autoload (ordered
  after `Save`, which it reads).
- Overrides are persisted in the Save profile under `InputRemap.SETTING_KEY`
  (`"input_bindings"`) as `{ action: { keyboard: <event>, controller: <event> } }`.
  Each action keeps **two editable slots** — a keyboard key and a controller
  button/axis — and an override touches only its slot, so the untouched slot keeps
  its default (rebinding the keyboard key leaves the controller binding alone, and
  vice-versa). Keys are stored by **physical keycode** (layout-independent, as
  `project.godot` does); a stick/trigger is stored as an axis + sign.
- `reset_defaults()` drops all overrides and restores the captured defaults.

The camera can also be **picked directly** (rather than cycled) on the settings page —
title-screen Settings or the in-run pause menu (see [menus.md](menus.md)); the choice
persists. The in-run **pause menu** is opened by the top-right Pause button or
`ui_cancel` (Esc / gamepad B), which freezes the game.

## Controller (gamepad)

The standard racing layout maps to any Godot-recognised gamepad (Xbox / Steam
Deck / PlayStation, button glyphs follow the SDL standard layout):

- **Throttle / brake on the analog triggers** — RT accelerates, LT brakes /
  reverses. Because `car.gd` reads them through `Input.get_axis(...)`, trigger
  pressure gives *proportional* throttle and braking, not on/off.
  - A trigger held with steering is arbitrated rather than obeyed literally: longitudinal
    effort and cornering share one friction budget, so `Car.longitudinal_demand_scale` bleeds
    the pedal off as steering winds on (the brake always, the throttle only on a driven front
    axle). This exists because keyboard and touch inputs are 0% or 100% and cannot express the
    compromise a real pedal can — a pinned pedal would otherwise leave the steering no grip to
    work with. Trail braking and power-out emerge from it. It is **not** ABS or traction
    control: with no steering input the pedal is untouched, so lockup and wheelspin remain.
- **Steering on the left stick X axis** — also read via `get_axis`, so stick
  deflection steers proportionally (the 0.2 deadzone ignores stick drift). Note what
  "proportionally" now means: steering input is a **demand on the front tires' available
  cornering grip**, not a wheel angle — half deflection asks for half of the grip they have
  left, and full deflection asks for all of it. See
  [car-physics.md](car-physics.md) → Steering.
- **Bumpers are the shift paddles** (manual gearbox), face buttons cover the
  remaining toggles, and the D-pad cycles drive mode.

The debug overlays (`toggle_debug_arrows`, `toggle_perf_overlay`) and the
`skip_to_finish` event cheat are intentionally keyboard-only. `toggle_debug_arrows`
(**H**) and `skip_to_finish` (**F**) are further gated on
`SettingsMenu.dev_tools_enabled()`, which defaults to **true** — the keys work in
release/web exports too, not just debug builds. See [debug-tools.md](debug-tools.md)
for skip-to-finish.

## Touch / mobile

On touch devices the same actions are driven by on-screen controls: stacked
gas/brake pedals (bottom-right) and an analog steering slider that recentres on
release (bottom-left) — see [mobile-controls.md](mobile-controls.md).

See also: [car-physics.md](car-physics.md),
[engine-and-transmission.md](engine-and-transmission.md),
[drivetrain-and-tires.md](drivetrain-and-tires.md),
[debug-tools.md](debug-tools.md).
