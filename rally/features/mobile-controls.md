# Mobile / Touch Controls

**Source:** `scripts/mobile_controls.gd` (extends `CanvasLayer`). Node
`MobileControls` (layer 3, above the HUD) in `main.tscn`.

On-screen touch controls for phones.

## Layout

Four equal-width buttons fill the bottom strip of the viewport, left-to-right
(`_BUTTONS`; region index == list position):

| Region | Label | Action driven |
|--------|-------|---------------|
| `STEER_LEFT` (0)  | `◀`     | `steer_left` |
| `STEER_RIGHT` (1) | `▶`     | `steer_right` |
| `BRAKE` (2)       | `BRAKE` | `brake_reverse` |
| `THROTTLE` (3)    | `GAS`   | `accelerate` |

The strip occupies the bottom `_STRIP_HEIGHT_RATIO` (0.15) of the viewport
height; touches above it fall through to the game. Panels are built and laid
out in code from the live viewport size, and re-laid-out on `size_changed`.

## Behavior

- **Drives existing input actions.** Each button press/releases the same action
  as the keyboard (`steer_left`, `steer_right`, `accelerate`, `brake_reverse`)
  via `Input.action_press/release`, so `car.gd` needs no touch awareness. See
  [controls.md](controls.md).
- **Multitouch.** Raw `InputEventScreenTouch`/`Drag` are handled directly
  (indexed by pointer) rather than via Control buttons, so e.g. steering and
  throttle register simultaneously. Mouse events also drive the controls
  (index -1) for desktop testing.
- Holds are tracked in `_held` (one flag per button) so actions only
  press/release on transitions; `_exit_tree()` releases anything still held.

## When it appears

`_active = mobile_controls_force or DisplayServer.is_touchscreen_available()`.
On non-touch devices the layer is hidden and its input/process are disabled, so
desktop keyboard play is unchanged (no auto-accelerate). On the web export
`is_touchscreen_available()` reflects the browser's touch support
(`ontouchstart` / `navigator.maxTouchPoints`), so it is true on phones and false
on ordinary desktops. Note: the game uses `stretch/mode="viewport"`, so the
*internal* viewport is always 480×360 regardless of device — viewport width
can't distinguish phone from desktop, which is why touch availability is the
detection signal.

## Related config

`mobile_controls_force` (force the controls + auto-accelerate on for testing on
desktop/in the editor). See [configuration.md](configuration.md).

## Tests

`tests/headless/test_mobile_controls.gd` — visibility gating, throttle, brake,
steering, multitouch, and release.
