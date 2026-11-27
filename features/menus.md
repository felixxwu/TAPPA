# Menus

The game boots through `title.tscn` (`title_boot.gd`) straight into the world (`Scenes.WORLD`, the Hafren level) ([world-session.md](world-session.md)). The live menus are the pause menu, the level's
pages (map, shops, service, part pages) and the title menu, which nothing opens today. **Every menu that is a list of choices is a card list**
(`CardCarousel` built through `CardUI.card_page` / `card_list`) — see
[card-carousel.md](card-carousel.md) for which menus are cards and which stay plain pages.

**Sources:** the scene-routing seam in `scripts/scenes.gd` (`class_name Scenes` —
the path consts `TITLE` / `WORLD` (the game: the Hafren level) / `MAIN` / `CAR`, and
the `car_scene()` cached-load accessor, the ONE place `"res://car.tscn"` is spelled in
production code; `preload(Scenes.CAR)` does not compile in GDScript 4.6, which is why
callers use `Scenes.car_scene()`), the pause overlay in `scripts/pause_menu.gd`
(`class_name PauseMenu`), the shared settings page in `scripts/settings_menu.gd`, the
text input in `scripts/text_field.gd`, the cloud-save form in `scripts/account_menu.gd`,
and the level's part pages in `scripts/free_roam/rest_stop_page.gd`.

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
while `get_tree().paused`, so the level's pages don't overlap the health gauge.
Tests: `test_settings_menu.gd` (wipe unpauses), `test_hud.gd`.

## Button order — leaving is left, proceeding is right

**In any row of buttons: the action that LEAVES (Back / Exit / Cancel / Quit / Decide
later) is leftmost, and the action that PROCEEDS (Start / Enter / Confirm / Drive) is
rightmost.** Everything else sits between them. This is a house rule, not a per-screen
choice — apply it to every new row without asking.

**`ConfirmPopup` layout:** a panel 280 px wide in design units (`280 * UITheme.UI_SCALE`, clamped to the screen), with the title, body and button row all centred (`scripts/confirm_popup.gd` → `_build`).

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
currently hidden from the category list (see cloud-save.md). It exposes `at_root()` / `go_back()` so Settings treats its sub-forms
exactly like its own sub-pages — `SettingsMenu.go_back()` gives it first refusal before
backing out of the page. See [cloud-save.md](cloud-save.md).

## Title screen and pause menu rows

The title menu (`TitleScreen`) is described in [world-session.md](world-session.md); its nav test is
`test_title_screen.gd`. The pause menu has
host-driven **extra rows** (`extra_rows` → `extra_requested(label)`; the host calls
`return_from_extra()` when its page closes; `closed` fires on `resume()`, which `LevelView` uses to bring back the intro shop), and **after-Resume rows** (`after_resume_rows`, the same but placed
right after Resume: Map goes second, since a touch screen has no M key; `open()` puts the
cursor on Resume). The level view has Map, Garage, Parts and Tune car after Resume (`after_resume_rows`; `LevelView._on_extra` opens `open_garage` / `open_parts` / `open_tune` via `CAR_PAGES`, needing a car, and Back returns to the menu through `_back_from_car_page` / `return_from_extra`; Map (`LevelMap.open_over_pause`: closing returns to the menu, a teleport goes straight back to driving) (deliveries are picked on the map: its All Delivery Jobs button, and a found shop picked there opens its stock to buy, see level-editor.md; the money shows top right), and no Repair / Shop: repair is at the teleport points (`LevelView.open_service`, see level-editor.md; Parts = `open_parts`, the part pages' shop alone with `engine_cars` empty (owned upgrades / tires / kits to switch, no engine swaps), Swap car = `open_garage` and Tune car = `open_tune`; a shop's Engine swap card opens `open_engine_swap` (`RestStopPage.open_engines`); repairing is just being near a point, `heal_at_points`). (There was a Journal row from 2026-10-23 to
2026-10-25; the user had it taken out and the journal deleted.)

## Part pages (`free_roam/rest_stop_page.gd`)

`RestStopPage` (a `CanvasLayer` at layer 6, `PROCESS_MODE_ALWAYS`) is the level's Parts, Engine swap
and Tune car pages, opened by `LevelView` (`open_shop` / `open_engines` / `open_tune`). Every page
but TUNE is a card list (`_card_page`, [card-carousel.md](card-carousel.md)) with `MenuNav.attach`;
TUNE is the shared `TuningPanel` on a plain, widened `MenuPage`. Back steps a part page → the shop →
closed. See [loot.md](loot.md). `RestStopPage.cards()` / `pick(title)` are the test readouts.
Covered by `test_level_view.gd` and `test_level_shop_specialties.gd`.

## Pause menu (`pause_menu.gd`)

A `PauseMenu` `CanvasLayer`, `PROCESS_MODE_ALWAYS` so its UI keeps working while the tree is
frozen, in both `level_view.tscn` and the dev stage `main.tscn`. It owns a **top-right Pause
button** bearing a pixel-art pause glyph (`icons/hud/pause.png` in a `PixelIcon`, since the font
has no ⏸ glyph) that **freezes the game** (`get_tree().paused = true`) and shows **PAUSED** over a
card list (`_build_menu_panel` → `CardUI.card_page` / `card_list`): **Resume**, **Reset**,
**Photo Mode**, the host's extra rows, **Settings** and **Quit**. Coming back from Settings,
photo mode or an extra page puts the cursor back on the card that left (`_focus_card`). The
settings page starts hidden, and `open()` selects the first card, so every opening lands the cursor on Resume.

**Per-host options** (exports, set in the hosting scene): `after_resume_rows`, `extra_rows`. The rows' text is free roam's ("Reset to
road", "Quit to title") for every host.

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
and a mobile-control pick to the live `MobileControls` (`scheme_changed` → `set_scheme`).

**Quit to title** has no pause-menu row any more; `quit_to_title` unfreezes, emits `quitting` (free roam saves on it) and goes to `Scenes.TITLE`. Esc and gamepad **Start** (`pause`) toggle the
menu; in Settings, Esc and gamepad B (`ui_cancel`) step out a level first, and B on the menu itself resumes.

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
