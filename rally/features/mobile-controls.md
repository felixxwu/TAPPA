# Mobile / Touch Controls

**Source:** `scripts/mobile_controls.gd` (extends `CanvasLayer`). Node
`MobileControls` (layer 3, above the HUD) in `main.tscn`.

On-screen touch controls for phones.

## Layout

Two pedals stacked **bottom-right** and a steering **slider** bottom-left, laid out
in code as fractions of the live viewport (re-laid-out on `size_changed`):

| Control | Position | Drives |
|---------|----------|--------|
| `GAS` (0)   | top of the right stack    | `accelerate` (digital) |
| `BRAKE` (1) | below GAS, right-aligned  | `brake_reverse` (digital) |
| Steering slider | bottom-left, horizontal | `steer_left` / `steer_right` (analog) |

`_gas_rect` / `_brake_rect` / `_slider_rect` are the hit regions; touches elsewhere
fall through to the game.

## Behavior

- **Drives existing input actions.** Gas/brake press the same actions as the
  keyboard via `Input.action_press/release`. The slider feeds **analog** strength
  into `steer_left` / `steer_right` via `Input.action_press(action, strength)` —
  `car.gd` reads steering as `Input.get_axis("steer_right", "steer_left")` (strength
  based), so a half-thrown slider gives half steering. `car.gd` needs no touch
  awareness. See [controls.md](controls.md).
- **Steering slider.** Touching inside the slider **captures** that pointer
  (`_slider_owner`); dragging it sets steer from the thumb's X via `_steer_from_x`
  ([-1 full left .. +1 full right], centre = straight, clamped if you slide off the
  rail). Lifting the finger clears the owner so steering **springs back to centre**.
  A thumb `ColorRect` tracks the value.
- **Multitouch.** Raw `InputEventScreenTouch`/`Drag` are handled directly (indexed
  by pointer), so steering (the captured slider pointer) and a gas/brake press
  register simultaneously. Mouse events also drive the controls (index -1) for
  desktop testing.
- Button holds are tracked in `_held` (one flag per pedal) so actions only
  press/release on transitions; `_exit_tree()` releases anything still held,
  including the steer actions.

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

`tests/headless/test_mobile_controls.gd` — visibility gating, gas, brake, the analog
steering slider (full-left / full-right / partial strength), the slider recentring on
release, slider + gas multitouch, and button release.
