# Menus

The game boots through `title.tscn` (`title_boot.gd`) straight into the free-roam world, with the
title menu drawn over it ([world-session.md](world-session.md)). The live menus are the title, the pause menu (with free roam's Map / Stats cards), the rest-stop
page and the world pages. **Every menu that is a list of choices is a card list**
(`CardCarousel` built through `CardUI.card_page` / `card_list`) — see
[card-carousel.md](card-carousel.md) for which menus are cards and which stay plain pages.

**Sources:** the scene-routing seam in `scripts/scenes.gd` (`class_name Scenes` —
`hub_path()` / `is_hub_scene()`, the path consts `TITLE` / `FREE_ROAM` / `MAIN` / `CAR`, and
the `car_scene()` cached-load accessor, the ONE place `"res://car.tscn"` is spelled in
production code; `preload(Scenes.CAR)` does not compile in GDScript 4.6, which is why
callers use `Scenes.car_scene()`), the pause overlay in `scripts/pause_menu.gd`
(`class_name PauseMenu`), the shared settings page in `scripts/settings_menu.gd`, the
text input in `scripts/text_field.gd`, the cloud-save form in `scripts/account_menu.gd`,
and the rest-stop page in `scripts/free_roam/rest_stop_page.gd`.

**Tests:** `tests/headless/test_menu_nav.gd`, `tests/headless/test_menu_page.gd`,
`tests/headless/test_pause_menu.gd`, `tests/headless/test_photo_mode.gd`, `tests/headless/test_settings_menu.gd`,
`tests/headless/test_text_field.gd`

The navigation framework is [menu-navigation.md](menu-navigation.md); modals are
[modals.md](modals.md). This file does not duplicate them.

**Scene changes unpause.** `Scenes.change_to` sets `tree.paused = false` for every caller (before
the test kill switch): pages that paused the tree (Settings' Wipe all progress from the pause menu
-> title) must not arrive at a scene whose carousel tweens and `MenuNav` need an unpaused tree.
**The HUD hides under paused pages.** `hud.gd` runs `PROCESS_MODE_ALWAYS` and makes its Control
children transparent (`modulate.a`, not `visible`, so photo mode / `hud_enabled` keep control)
while `get_tree().paused`, so rest-stop / map / stats pages don't overlap the health gauge.
Tests: `test_settings_menu.gd` (wipe unpauses), `test_hud.gd`, `test_world_pages.gd` (Stats page nav).

## Button order — leaving is left, proceeding is right

**In any row of buttons: the action that LEAVES (Back / Exit / Cancel / Quit / Decide
later) is leftmost, and the action that PROCEEDS (Start / Enter / Confirm / Drive) is
rightmost.** Everything else sits between them. This is a house rule, not a per-screen
choice — apply it to every new row without asking.

**Two traps when reordering an existing row:**

1. **`ConfirmPopup.open`'s `default_index` and `back_index` are POSITIONAL.** Reversing
   the `actions` array without updating them silently changes which button is focused
   and which one Esc / gamepad-B fires. `back_index` defaults to the **first** action.
   Single-action popups are unaffected: first and last are the same button.
2. **Seat indices are not constants.** A row can have CONDITIONAL members ("Exit Game" is
   skipped on web), so "the proceeding action is last" can be a different index per
   platform. Compute it rather than hardcoding, and have tests assert by button IDENTITY
   (e.g. press by text) rather than by literal index.

**Vertical columns are a separate convention and are deliberately NOT changed by this
rule:** they put the exit at the BOTTOM (last) — the pause menu's card list, 
`account_menu.gd::_build_email_form` and the `< Back` at the foot of every scrolled modal
page. Treat any change to it as its own decision.

## Text input (`text_field.gd`)

`TextField` is the project's **only** text input (see [cloud-save.md](cloud-save.md)). A
labelled `LineEdit`, built in code like every other menu widget. Making typing coexist with
a menu driven by bare letter keys took four things:

- **`MenuNav._make_focusable` walks `LineEdit` too**, not just `BaseButton` and `Slider` —
  otherwise a form is unreachable without a mouse.
- **Up/down leave the field, left/right stay caret movement.**
  `TextField.wire_column([...])` chains a form's controls explicitly (top and
  bottom do not wrap — wrapping reads as the cursor teleporting) rather than
  relying on Godot's automatic neighbour search.
- **WASD is safe by construction**: a focused `LineEdit` consumes printable keys
  in the GUI phase, before `_unhandled_input`. **Esc is not**, so
  `MenuNav._unhandled_input` turns Back-while-typing into "release the field"
  instead of "leave the page", and any host with its own `_unhandled_input` stands down
  via the shared **`MenuNav.is_text_editing()`** static.
- **Enter submits** (`submitted` signal) — on a phone the on-screen keyboard can
  cover the button, so this is sometimes the only way to submit at all.
  `virtual_keyboard_enabled` is on for Android/web.

Note that **Space is both `ui_accept` and a legal password character**; the
focused field consumes it first, so typing wins. That is correct, but it is the
thing to re-check by hand if the input map ever changes.

Covered by `tests/headless/test_text_field.gd`.

## Account page (`account_menu.gd`)

`AccountMenu` is the optional cloud-save UI — a category page inside Settings
(`show_account`). It exposes `at_root()` / `go_back()` so Settings treats its sub-forms
exactly like its own sub-pages — `SettingsMenu.go_back()` gives it first refusal before
backing out of the page. See [cloud-save.md](cloud-save.md).

## Title screen and world pages

The title menu (`TitleScreen`) opens over the world at boot, and free roam's pause menu and rest-stop page open
the map and stats pages (`WorldPages`). Both are described in [world-session.md](world-session.md),
and their nav tests are `test_title_screen.gd` and `test_world_session.gd`. The pause menu has
host-driven **extra rows** (`extra_rows` → `extra_requested(label)`; the host calls
`return_from_extra()` when its page closes) and a configurable quit (`quit_label`, `quit_scene`).

## Rest-stop page (`free_roam/rest_stop_page.gd`)

Free roam's `RestStopPage` (a `CanvasLayer` at layer 6, `PROCESS_MODE_ALWAYS`) opens when the car
stops on a rest stop (`RestStops.opened`). Opening it banks carried loot, repairs the car for
free, freezes the game and disarms the pause menu. Every page but TUNE is a card list
(`_card_page` → `CardUI.card_page` / `card_list`, [card-carousel.md](card-carousel.md)), with
`MenuNav.attach`:
- **MAIN:** the stop's name, "Car repaired" and what was banked above the cards Continue / Tune
  car / Parts / Garage / Travel / Map / Journal. Travel is disabled while no other rest stop is lit.
- **TUNE:** the shared `TuningPanel` (`car.retune` on the funnel view of the car) on a plain,
  widened `MenuPage` — sliders, not a list.
- **PARTS / GARAGE / JOURNAL:** see [loot.md](loot.md).
- **TRAVEL:** a card per other lit rest stop, nearest first, with its distance.

Back (Esc / gamepad B, or the `< Back` button under a sub-page's cards) steps a sub-page → MAIN →
closed. The same page hosts the **wreck page** (`View.WRECKED`, `open_wrecked`): when the car gives up it lists the carried loot left at the wreck, and its single Respawn card (or Back) respawns at the last lit stop. `RestStopPage.cards()` / `pick(title)` are the test readouts. Covered by
`test_free_roam_rest_stops.gd` and `test_loot.gd`.

## Pause menu (`pause_menu.gd`)

A `PauseMenu` `CanvasLayer`, `PROCESS_MODE_ALWAYS` so its UI keeps working while the tree is
frozen, in both `free_roam.tscn` and the dev stage `main.tscn`. It owns a **top-right Pause
button** bearing a drawn pause glyph (`PauseIcon`, `scripts/pause_icon.gd`, since the font has
no ⏸ glyph) that **freezes the game** (`get_tree().paused = true`) and shows **PAUSED** over a
card list (`_build_menu_panel` → `CardUI.card_page` / `card_list`): **Resume**, **Reset**,
**Photo Mode**, the host's extra rows, **Settings** and **Quit**. Coming back from Settings,
photo mode or an extra page puts the cursor back on the card that left (`_focus_card`). The
settings page starts hidden, so the first `open()` lands the cursor on Resume.

**Per-host options** (exports, set in the hosting scene): `offer_photo_mode` (free roam turns it
off — it has no free-fly photo camera), `reset_label` ("Reset to road" in free roam),
`quit_label` / `quit_scene` / `quit_body_override` (free roam quits to the title, saying the
world is saved).

**Reset** emits `reset_to_track_requested`; the menu owns no car reference, so the host performs
it — free roam's `RoadRecovery.reset_now`, the dev stage's `world.gd` via
`TrackProgress.manual_reset_pose()` (a fresh nearest point on the centreline, not the
furthest-progress `recovery_pose()`). It is the **only** player-facing reset — there is no
direct reset input (see [controls.md](controls.md)). `Car.reset_to()` does not trust a bare
`global_transform` write, which only sticks inside the physics step: it wakes the body and
**queues** the pose, and `car.gd::_integrate_forces` applies it via `state.transform`, so a reset
fired from a menu signal or on a sleeping body still lands. The teleport's impact damage is
suppressed.

**Photo Mode** enters a free-fly frozen-world camera (see [camera.md](camera.md)); the tree stays
**paused** and the menu is **disarmed** while it is active, so Esc and the Pause button belong to
the camera. Exiting re-opens the pause menu.

**Settings** shows the shared `SettingsMenu` with a **◄ Back**. A camera pick applies
immediately to the live `CameraManager` (`SettingsMenu.camera_changed` → `CameraManager.set_mode`)
and a mobile-control pick to the live `MobileControls` (`scheme_changed` → `set_scheme`). The dev
page's **Complete stage** relays to `world.gd`'s `_dev_complete_stage` through
`dev_complete_stage_requested` (see [settings.md](settings.md) → "Developer-only pages").

**Quit** pops a confirm (`confirm_quit_to_hq`) and on accept (`quit_to_hq`) unfreezes and goes to
`quit_scene`; a benchmark run exits through `Benchmark.exit_to_hq` so its config overrides are
restored; otherwise it loads `Scenes.hub_path()` (the title). `ui_cancel` (Esc / gamepad B)
toggles the menu and backs out of Settings first; the gamepad **Start** button (`pause` action)
opens it.

The menu is **default-inert** (`_input_enabled` starts `false`): the Pause button and `ui_cancel`
do nothing until the host calls `set_input_enabled(true)` after the world is built, so the player
can't freeze the tree mid-build. Covered by `tests/headless/test_pause_menu.gd`.

## Tests

- `tests/headless/test_pause_menu.gd` — the Pause button freezes the game and opens the
  menu; Resume unfreezes; Settings exposes the shared `SettingsMenu`; Quit leaves and
  unfreezes; picking a camera applies live to the `CameraManager` and persists.
- `tests/headless/test_menu_nav.gd` / `test_menu_page.gd` — the navigation framework and
  the page shape ([menu-navigation.md](menu-navigation.md), [modals.md](modals.md)).
- `tests/headless/test_text_field.gd` — the text input rules above.
- `tests/headless/test_settings_menu.gd` — the shared settings page.
