# Controls / Input Map

Defined in `project.godot` `[input]`. Handled mainly by `scripts/car.gd`; the
HUD buttons mirror the gearbox/drive-mode toggles.

| Action | Key | Alt | Controller | Effect |
|--------|-----|-----|------------|--------|
| `accelerate` | W | ↑ | Right Trigger (RT/R2) | Throttle forward (reverse throttle in R gear) |
| `brake_reverse` | S | ↓ | Left Trigger (LT/L2) | Brake / reverse |
| `steer_left` | A | ← | Left stick ← | Steer left |
| `steer_right` | D | → | Left stick → | Steer right |
| `shift_up` | E | — | Right bumper (RB/R1) | Manual upshift |
| `shift_down` | Q | — | Left bumper (LB/L1) | Manual downshift |
| `handbrake` | Space | — | A / Cross (South) | Rear-axle handbrake (drift) |
| `toggle_gearbox` | T | — | X / Square (West) | Toggle manual / auto transmission |
| `cycle_drive_mode` | Y | — | D-pad Up | Cycle RWD → AWD → FWD |
| `reset_car` | R | — | Y / Triangle (North) | Teleport to start, zero velocity |
| `cycle_camera` | C | — | B / Circle (East) | Cycle through cameras |
| `toggle_debug_arrows` | H | — | — | Show/hide force debug overlay |
| `toggle_perf_overlay` | P | — | — | Show/hide frame profiler overlay |

All actions use a 0.2 deadzone.

## Rebinding (settings → Key bindings)

Every action in the table above (the driving controls + the toggles, **not** the
keyboard-only debug overlays or the `ui_*`/`menu_*` navigation) can be **rebound** on
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
- **Steering on the left stick X axis** — also read via `get_axis`, so stick
  deflection steers proportionally (the 0.2 deadzone ignores stick drift).
- **Bumpers are the shift paddles** (manual gearbox), face buttons cover the
  remaining toggles, and the D-pad cycles drive mode.

The debug overlays (`toggle_debug_arrows`, `toggle_perf_overlay`) are
intentionally keyboard-only.

## Touch / mobile

On touch devices the same actions are driven by on-screen controls: stacked
gas/brake pedals (bottom-right) and an analog steering slider that recentres on
release (bottom-left) — see [mobile-controls.md](mobile-controls.md).

See also: [car-physics.md](car-physics.md),
[engine-and-transmission.md](engine-and-transmission.md),
[drivetrain-and-tires.md](drivetrain-and-tires.md),
[debug-tools.md](debug-tools.md).
