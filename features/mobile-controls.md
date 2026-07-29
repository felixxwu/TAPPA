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
(releasing anything held first) and rebuilds the overlay. Picking a scheme in the
**in-run pause menu** calls this **live**: the `SettingsMenu.scheme_changed` signal is
wired (in `main.tscn`) to the scene's `MobileControls.set_scheme`, so the on-screen
controls rebuild the instant you choose a layout rather than only on the next run. (The
title-screen Settings page has no live controls, so there it just saves.)

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
  drive the controls (index -1) for desktop testing. On the web, held pointers are
  reconciled every frame against the browser's own list of fingers down — see
  "Stuck-touch reconciliation" below.
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

## Web fullscreen + landscape

**Source:** the `WebFullscreen` autoload (`scripts/web_fullscreen.gd`).

The game is authored landscape (`display/window/handheld/orientation =
sensor_landscape`), but a mobile browser first loads the canvas at the page's
current (often portrait) size, and browsers only allow fullscreen from a user
gesture. `WebFullscreen` handles this **globally** (it's an autoload, so it works
in every scene — the title, the garage, AND while driving, not just the HQ):

- It tracks the window orientation (polling `DisplayServer.window_get_size()` each
  frame, the same robustness trick `DisplayStretch` uses since `size_changed` can
  be missed on some web configs).
- While the viewport is **portrait** it shows a full-screen "TAP TO PLAY / rotate
  your phone to landscape" overlay (`CanvasLayer` at layer 512, above every
  in-game/menu layer) whose full-rect `Button` provides the gesture — a tap
  anywhere, or `ui_accept` from keyboard/gamepad (it grabs focus, per the menu
  navigability rules). Pressing it calls `request_fullscreen()`.
- `request_fullscreen()` requests canvas fullscreen **only when portrait**
  (idempotent when already landscape, so it never disturbs desktop or an embedder
  like itch.io that auto-presents fullscreen — re-requesting there would flip it to
  portrait). The export's `head_include` (`export_presets.cfg`) then runs
  `screen.orientation.lock('landscape')` on the `fullscreenchange` event.
- The overlay is driven purely by orientation — hidden the moment we're landscape,
  and **re-shown whenever the page falls back to portrait** (browser reopened after
  being closed, fullscreen exited mid-drive), not only at boot.

It deliberately does **not** gate on `DisplayServer.is_touchscreen_available()`,
which can report false on Android Chrome and previously left the game stuck in
portrait — a portrait web viewport is itself the mobile signal (desktop windows are
landscape). `request_fullscreen()` logs `[rally] requesting fullscreen…` to the
browser console for on-device debugging (chrome://inspect). The whole autoload is
inert off the web build. iPhone Safari supports neither the Fullscreen API nor
orientation lock, so there the effective fallback is "Add to Home Screen" / rotating
the device.

## First-run pick (pre-rally gate)

On mobile, a player must choose a scheme before their first event. If no scheme is
saved yet, HQ's Start button opens the Settings picker as a **gate**
(`hq.gd._open_settings(true)`) instead of launching — jumping **straight to the
Mobile controls page** (not the full category list), so the player only picks a
touch layout. Confirming (the bottom **Start >** button) saves the chosen scheme
(the highlighted default if untouched) and proceeds, so the gate never shows again.
Pressing back cancels the gate to the car park. See [menus.md](menus.md) › Settings.

## Related config

`mobile_controls_force` (force the controls on for testing on desktop/in the
editor), `tilt_sensitivity`, `tilt_deadzone` (the TILT scheme). See
[configuration.md](configuration.md).

## Stuck-touch reconciliation (web)

**Source:** `mobile_controls.gd` → `_install_touch_watchdog`, `_poll_live_touches`,
`sync_live_touches`, `_reconcile_pointers`, `_is_lifted`.

Mobile browsers sometimes never deliver the `touchend` for a finger lifted while
other fingers are still down, so a pedal or steer button stays held and the car
drives itself. Godot can't fix this from its side: the engine's web input layer only
reads `evt.changedTouches`, never `evt.touches` — the browser's authoritative list of
fingers **currently down** — so a dropped release leaves `_pointers` /
`_slider_owner` populated with no event that could ever clear them.

So the overlay stops trusting `touchend` and **reconciles** instead:

- A one-time `JavaScriptBridge.eval` (`_TOUCH_WATCHDOG_JS`) registers
  **capture-phase** `touchstart`/`touchmove`/`touchend`/`touchcancel` listeners on
  **`window`**, and publishes the live `evt.touches` identifiers to
  `window.__rallyTouchIds` with a change counter, `window.__rallyTouchSeq`.
  Backgrounding the page (`blur` / `pagehide` / `visibilitychange`) publishes an
  empty list, since that ends every touch with no per-id event to observe.
- `_timed_process` **polls** the counter every frame — one cheap int read on a quiet
  frame; the id list is only fetched and parsed on a change — then reconciles and
  only *then* applies actions, so a dead pointer never reaches the car's input
  actions. Browser touch identifiers are what the engine passes straight through as
  the Godot touch index, so no translation is needed.
- `_reconcile_pointers` drops any tracked pointer missing from the live set (and
  recentres the slider if its owner vanished). Index -1 is the mouse and never
  appears in a touch list, so it's excluded.
- `_is_lifted` also makes `_drag` **discard a drag for a finger the browser says is
  already up**. `_drag` re-polls first, because the engine's buffered-input flush runs
  *before* `_process` — judging a brand-new finger against the previous frame's
  snapshot would throw away the first drag of a press-and-slide that landed in the
  same frame. Polling is cheap enough for that: the counter only moves when the set of
  fingers changes, so a finger merely sliding around costs one int read.

Everything is inert off the web build: with no snapshot, `_live_touches` stays
`null` and reconciliation is a no-op — "no snapshot" is deliberately not treated as
"no fingers down".

### Why the first attempt at this didn't work

The original version diffed the touch list inside the DOM handler and force-released
lost pointers **once, synchronously** — i.e. *ahead of* Godot's buffered-input flush
for that frame (`use_accumulated_input` is on by default). Any `InputEventScreenDrag`
already queued for the lifted finger was then flushed on top and **re-added** the
pointer, and because that finger sends no further events, the one-shot watchdog never
reconciled again — so the button stuck indefinitely. That's exactly why the bug only
appeared when a finger **moved slightly** before being released: a stationary finger
queues no drag to resurrect it.

The two properties that fix it: reconciliation is **polled every frame** (so it is
self-correcting rather than one-shot — a resurrected pointer dies again immediately),
and the listeners sit on **`window` in capture phase**, the first step of every
event's propagation path, so the snapshot can never be staler than an engine touch
event that has already been flushed. That's what makes it safe for `_is_lifted` to
discard a drag outright. It also removes the old version's dependency on finding the
canvas element by id.

## Tests

`tests/headless/test_mobile_controls.gd` — visibility gating, the default scheme
(gas / brake / analog slider, recentring, multitouch), steer buttons, the auto-gas
throttle-unless-braking rule, the simple both-sides-brake, the pure `tilt_steer`
maths, scheme switching releasing old inputs, and the stuck-touch reconciliation
above (a lost finger clears its button / recentres the slider, held fingers and the
mouse pointer survive, no snapshot means no reconciliation, and — the regression —
a stale drag can't resurrect a lifted finger). The Settings page + pre-rally gate
are covered in `test_menu_flow.gd`; the saved-setting round-trip in
`test_save_manager.gd`.

## Touch events are processed once, not twice

`project.godot` leaves `input_devices/pointing/emulate_mouse_from_touch` at its default
`true`, so Godot synthesises a mouse event for every touch. `mobile_controls.gd::_input`
handles touch *and* mouse, so each finger used to be processed twice — once at
`event.index`, once at index -1.

`_input` now early-returns on `_is_emulated_mouse(event)` for both the
`InputEventMouseButton` and `InputEventMouseMotion` branches. Godot stamps synthesised
events with `device == InputEvent.DEVICE_ID_EMULATION` (-1); a real mouse reports a
non-negative device id. So a finger is handled once, and a desktop tester running with
`mobile_controls_force` still drives the overlay with a real mouse.

> **Do NOT "fix" this by setting `emulate_mouse_from_touch = false` project-wide.** The
> menus and the HQ table-pan *depend* on touch-generated mouse events (see
> [menus.md](menus.md)); flipping the project setting would break them. Filtering inside
> `_input` is the safe, local fix.
