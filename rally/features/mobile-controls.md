# Mobile / Touch Controls

**Source:** `scripts/mobile_controls.gd` (`class_name MobileControls`, extends
`CanvasLayer`). Node `MobileControls` (layer 3, above the HUD) in `main.tscn`.

On-screen touch controls for phones, with **six selectable schemes** chosen on the
title screen's Settings page (see [menus.md](menus.md)) and persisted per-player.

## Schemes (`MobileControls.SCHEME_*`)

`SCHEMES` holds the display name + how-to for each; the enum order is the id.

| Id | Scheme | Steering | Throttle / Brake |
|----|--------|----------|------------------|
| 0 | `SLIDER_GAS_BRAKE` (default) | bottom-left slider | GAS + BRAKE pedals |
| 1 | `BUTTONS_GAS_BRAKE` | left/right steer buttons | GAS + BRAKE pedals |
| 2 | `SLIDER_BRAKE_AUTO` | bottom-left slider | **auto gas** + BRAKE |
| 3 | `BUTTONS_BRAKE_AUTO` | left/right steer buttons | **auto gas** + BRAKE |
| 4 | `SIMPLE_LR_AUTO` | tap left/right half | **auto gas**; **both halves = brake** |
| 5 | `TILT_GAS_BRAKE` | tilt the phone (accelerometer) | GAS + BRAKE pedals |

**Auto gas** = full throttle held *unless braking* — `accelerate` is pressed
whenever the brake isn't (in the simple scheme, "braking" is both halves at once).

The chosen scheme is stored in the **save profile** under
`MobileControls.SETTING_KEY` (`"mobile_control_scheme"`) via `Save.set_setting`, and
read in `_ready` (`_scheme_from_save`, clamped to a valid id). It's a per-player
preference, **not** a `GameConfig` field. `set_scheme(id)` switches at runtime
(releasing anything held first) and rebuilds the overlay.

## Behavior

- **Drives existing input actions.** All schemes press the same actions as the
  keyboard via `Input.action_press/release` (`accelerate`, `brake_reverse`,
  `steer_left`, `steer_right`), so `car.gd` needs no touch awareness. See
  [controls.md](controls.md).
- **Per-scheme layout.** `_compute_rects` lays the active scheme's hit regions out
  as fractions of the viewport (re-laid-out on `size_changed`): a right-hand pedal
  stack (BRAKE at the bottom, GAS above when present), and on the left either the
  steering **slider**, two **steer buttons**, or full-height **left/right halves**
  (simple scheme). `_build` creates only the panels the scheme uses.
- **Steering slider** (schemes 0/2). Touching inside it **captures** that pointer
  (`_slider_owner`); the thumb X sets analog steer via `_steer_from_x`
  ([-1 .. +1], centre = straight). Lifting the finger clears the owner so steering
  **springs back to centre**. Strength is fed in via `Input.action_press(action,
  strength)`, so a half-thrown slider gives half steering.
- **Steer buttons** (1/3) press `steer_left`/`steer_right` at full strength.
- **Simple left/right** (4): one side steers that way; **both sides at once is the
  brake** (and suppresses steering); throttle is automatic otherwise.
- **Tilt** (5): `tilt_steer(Input.get_gravity(), tilt_sensitivity, tilt_deadzone)`
  maps the device roll (X gravity, normalised per g, past a deadzone) to analog
  steer. `tilt_steer` is a pure static so the maths are unit-testable without a
  sensor.
- **Multitouch.** Raw `InputEventScreenTouch`/`Drag` are handled directly (indexed
  by pointer), so steering and a pedal register simultaneously. Mouse events also
  drive the controls (index -1) for desktop testing.
- Held actions are tracked in `_action_held` so they only press/release on
  transitions; `_release_all()` (on scheme switch + `_exit_tree`) clears everything
  so no phantom input lingers.

## When it appears

`_active = mobile_controls_force or DisplayServer.is_touchscreen_available()`.
On non-touch devices the layer is hidden and its input/process are disabled, so
desktop keyboard play is unchanged. On the web export `is_touchscreen_available()`
reflects the browser's touch support, so it is true on phones and false on ordinary
desktops. (The game uses `stretch/mode="viewport"`, so the *internal* viewport is
always 480×360 — viewport width can't distinguish phone from desktop, which is why
touch availability is the detection signal.)

## First-run pick (pre-rally gate)

On mobile, a player must choose a scheme before their first event. If no scheme is
saved yet, HQ's Start button opens the Settings picker as a **gate**
(`hq.gd._open_settings(true)`) instead of launching; confirming saves the chosen
scheme (the highlighted default if untouched) and proceeds, so the gate never shows
again. See [menus.md](menus.md) › Settings.

## Related config

`mobile_controls_force` (force the controls on for testing on desktop/in the
editor), `tilt_sensitivity`, `tilt_deadzone` (the TILT scheme). See
[configuration.md](configuration.md).

## Tests

`tests/headless/test_mobile_controls.gd` — visibility gating, the default scheme
(gas / brake / analog slider, recentring, multitouch), steer buttons, the auto-gas
throttle-unless-braking rule, the simple both-sides-brake, the pure `tilt_steer`
maths, and scheme switching releasing old inputs. The Settings page + pre-rally gate
are covered in `test_menu_flow.gd`; the saved-setting round-trip in
`test_save_manager.gd`.
