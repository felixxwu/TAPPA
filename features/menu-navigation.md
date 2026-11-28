# Menu navigation (keyboard / gamepad)

**Sources:** `scripts/menu_nav.gd` (`class_name MenuNav` — the flat-menu framework:
`attach`, `of`, `is_on_screen`, `is_text_editing`,
`input_blocked`) and `scripts/ui_theme.gd` (`focus_grab`,
`first_focusable`, the focus stylebox that paints the cursor).

**Tests:** `tests/headless/test_menu_nav.gd`, `tests/headless/test_menu_page.gd`

Every menu in the game is navigable with **up / down / left / right / enter / back**, on
keyboard *and* controller, alongside mouse / touch. This doc is the framework; the screens
themselves are in [menus.md](menus.md).

> **This is a project rule, not a nicety** (CLAUDE.md): when you ADD a menu or CHANGE an
> existing one, wire its navigation in the SAME piece of work and add or update a nav test.
> Don't ship a menu reachable only by pointer.

## One regime: `MenuNav` over native focus

Every menu is a flat widget tree on a `CanvasLayer` and every one of them uses **Godot's
native focus**, wired by the `MenuNav` framework so a menu author doesn't hand-roll (or
forget) the per-widget setup.

> There used to be a second, spatial regime for the deleted diegetic 3D HQ. **Every menu in
> the game is a flat widget list now**; if a future screen needs a non-widget-grid navigation
> model, write it up here as its own regime.

**What `MenuNav.attach(root, {first = ..., on_back = ...})` does, once:**

1. **Focus** — walks `root` and sets every interactive Control to `FOCUS_ALL` (a widget
   opts OUT with the `menu_nav_skip` meta).
2. **Grab** — deferred-grabs the cursor onto `first` (or the first focusable descendant,
   also when `first` can't take focus — an empty `CardCarousel` is `FOCUS_NONE` until its
   first `add_card`, so an empty list's page opens on its `< Back`), and re-grabs whenever
   the menu is re-shown.
3. **WASD** — fills the one gap in Godot's defaults: the built-in `ui_up/down/left/right`
   actions bind arrow keys + D-pad + left-stick but **not WASD**, so `MenuNav` translates
   the game's `menu_up/down/left/right` actions (which bind W/A/S/D) into focus-neighbour
   moves. Native `ui_*` still consumes arrows / stick / D-pad in the GUI phase *before*
   `_unhandled_input`, so only the WASD presses reach `MenuNav` — no double-movement, and
   no fragile `project.godot` surgery. **On a slider** (any `Range`) left/right instead
   *adjusts the value* by its `step` rather than moving focus, so the cursor merely
   resting on a slider is enough to change it — up/down still move focus off to the next
   row. **A widget that owns its own left/right** gets first refusal before the slider
   case: if `focused.has_method("menu_nav_handles_side")`, `MenuNav` calls it and stops —
   the method returns `true` when it consumed the press, `false` to fall through to
   normal focus-neighbour movement (so up/down can still leave the widget).
   `CardCarousel` ([card-carousel.md](card-carousel.md)) is the user: every card-list menu is
   one focusable carousel, where left/right move the selected card instead of moving focus to
   a sibling widget, and up/down leave it for the `< Back` button under the cards. Named
   generically rather than special-casing `CardCarousel` here, so the next such widget
   needs no framework change either.
4. **Back** — routes **both** `ui_cancel` **and** `menu_back` to `on_back` (omit it and
   the host keeps its own back handling).
5. **Scroll-follow** — switches every `ScrollContainer` under `root` to `follow_focus`,
   so directional nav onto a row that's scrolled out of view auto-scrolls it into view
   (`follow_focus` is a no-op when nothing overflows, so it's safe everywhere).

`MenuNav` goes inert while its `root` is hidden — including a hidden `CanvasLayer` ancestor
(`Control.is_visible_in_tree()` alone misses that), so a hidden overlay never steals input
from whatever is behind it.

**One owner for opening focus.** A menu that attaches `MenuNav` must **not** also fire its
own `UITheme.focus_grab` when it opens. Showing the root fires `visibility_changed`, which
the framework already answers; a second grab from the host silently wins on the same
deferred flush, so any change made *through* `MenuNav` looks like it did nothing.
`pause_menu.gd::open()` shipped exactly this bug once — its `_show_settings(false)` call
grabbed the Settings row unconditionally, even when the menu had never been showing
Settings, and only the host's extra re-grab hid it. `_show_settings` now grabs only on a
genuine *return* from the sub-panel.

**Gamepad select / back.** Godot's built-in `ui_up/down/left/right` ship with D-pad +
left-stick bindings, but `ui_accept` and `ui_cancel` ship with **keyboard only**
(Enter/KP-Enter/Space, and Esc). Since a focused button fires on `ui_accept` and back
routes through `ui_cancel`, a controller could move the cursor but neither select nor go
back until `project.godot` `[input]` adds the face buttons: **`ui_accept` → gamepad
button 0 (A)** and **`ui_cancel` → gamepad button 1 (B)**, alongside the keyboard defaults.
This is the single global fix that makes *every* menu gamepad-selectable and
gamepad-back-able — no per-menu wiring — because every back path already runs through
`ui_cancel` (host handlers) or `MenuNav`'s `on_back` (which also listens for `menu_back` =
B). Guarded by `test_menu_nav.gd` → `test_accept_and_cancel_have_a_gamepad_button`.

`ui_accept` fires the focused control and the **focus highlight is the theme's `focus`
stylebox**, which `tools/build_ui_theme.gd` defines to match the **hover** look — so a
focus cursor and a mouse hover read identically (see [ui-design-system.md](ui-design-system.md)).
`UITheme.focus_grab(ctrl)` is the guarded, call-deferred grab helper (grab a specific
control); `UITheme.focus_grab(UITheme.first_focusable(root))` seats the
cursor on the first focusable control under a root. `UITheme.first_focusable` skips any
control in a **dying subtree** (an ancestor `queue_free`d this frame) — a rebuild that
frees whole row containers leaves their descendant buttons not-yet-`is_queued_for_deletion()`
themselves, so a deferred grab that ignored ancestors would land on a doomed button and lose
focus next frame.

**Live `MenuNav.attach` callers today:** the shared `SettingsMenu` (rows + bottom action
button — backs both the title-screen Settings page and the pause menu's), the **pause**
menu (its card list, and the Settings page), `ConfirmPopup`
(the modal layer — see [modals.md](modals.md)), the HUD's **stage-complete panel**'s single
`NEXT` button (`hud.gd`, [hud.md](hud.md)), and `AccountMenu` ([cloud-save.md](cloud-save.md)). Free roam's menus attach it too:
the title screen, the rest-stop page and the world pages (map, stats) — each card page with
`{first = <its CardCarousel>}`.

> **When you add or change a menu, wire its navigation in the same piece of work.** Call
> **`MenuNav.attach(root, {first = <button>, on_back = <Callable>})`** once after building
> it — the framework makes the widgets focusable, seats + re-seats the cursor, fills the
> WASD gap, and routes `ui_cancel`/`menu_back` to `on_back`. Omit `on_back` if the host owns
> "back" itself (e.g. a toggle handler); mark a widget with the `menu_nav_skip` meta to leave
> it `FOCUS_NONE`. Add a nav test (see `tests/headless/test_menu_nav.gd` /
> `test_pause_menu.gd` for the shape).
>
> **Attach ONCE, not on every state change.** `attach` defers a focus **grab**, so
> re-attaching to refresh something (typically to keep an `on_back` route alive after a
> rebuild) yanks the cursor to the first control every time. The fix is for the page to
> **own** the thing that was being refreshed and re-apply it from its own `rebuild()`, so
> `attach` runs once per build and nobody re-attaches from outside.

**Esc over the map's All Delivery Jobs page.** Esc is bound to both `pause` and `ui_cancel`, and
the pause menu would take the `pause` half and open over the map. `LevelView._input` catches
`pause` while that page is up (and no shop / point page owns the screen) and closes the page back
to the map, the same as `< Back` and pad B. Guarded by `test_level_view.gd`.

## Nested card pages: the level's part pages

`RestStopPage._card_page` gives each page a Back that steps one level: part page → Shop → closed
(or closes straight away from the page it was opened on). Guarded by `test_level_view.gd` and
`test_level_shop_specialties.gd`.

## `TextField` and the WASD/typing seam

`scripts/text_field.gd` (`TextField`) is the project's only text input — a labelled
`LineEdit`. Making typing coexist with a menu driven by bare letter keys took four things:

- **`MenuNav._make_focusable` walks `LineEdit` too**, not just `BaseButton` and `Slider` —
  otherwise a form is unreachable without a mouse.
- **Up/down leave the field, left/right stay caret movement.** `TextField.wire_column([...])`
  chains a form's controls explicitly (top and bottom do not wrap) rather than relying on
  Godot's automatic neighbour search.
- **WASD is safe by construction**: a focused `LineEdit` consumes printable keys in the GUI
  phase, before `_unhandled_input`. **Esc is not**, so `MenuNav._unhandled_input` turns
  Back-while-typing into "stop typing, cursor stays on the field" instead of "leave the page",
  via the shared **`MenuNav.is_text_editing()`** static. That asks `LineEdit.is_editing()`,
  not just focus: since Godot 4.4 a field the cursor merely rests on is not being typed into,
  so Back there leaves the page like on any other row.
- **Enter / gamepad A start typing.** A keyboard-focused `LineEdit` only enters edit mode on
  Enter (`ui_text_submit`), so `TextField._on_line_input` calls `edit()` on `ui_accept` too —
  otherwise a pad can reach a field but never type in it.
- **Enter submits** (`submitted` signal) — on a phone the on-screen keyboard can cover the
  button, so this is sometimes the only way to submit at all. `virtual_keyboard_enabled` is
  on for Android/web.

Note that **Space is both `ui_accept` and a legal character in a text field**; the focused field
consumes it first, so typing wins. Covered by `tests/headless/test_text_field.gd`.

## A third pattern: the single-action screen

A screen whose menu offers exactly **one** action needs neither `MenuNav` nor a focus ring,
because there is nothing to move a cursor between: the button stays `FOCUS_NONE` and the
screen's own `_unhandled_input` fires the action on `menu_select` (plus a screen touch / left
click).

**There is no live instance today** (the deleted wreck screen was the canonical one). The
pattern is kept written down because it is the right shape the next time a one-action screen
appears, and because of two obligations that are easy to miss:

- **Gate on the phase.** The wreck screen only accepted the input once its orbit had begun,
  so a press during a lead-in animation couldn't skip past the screen entirely. Any
  press-anything screen with a lead-in needs the same guard.
- **Test the input ACTION, not the button's `pressed` signal.** Those are separate code
  paths, so `pressed.emit()` alone leaves the keyboard/gamepad route unexercised — exactly
  the kind of pointer-only menu the project's nav rule forbids.

Reach for this only at one action. At two, use `MenuNav.attach`.

## Menu-flow replays (keyboard and gamepad golden)

**Sources:** `benchmark/menu_flow.gd` (`class_name MenuFlow`) + `benchmark/menu_flow.tscn`, the script
`benchmark/flows/menus.json`, the blessed log `goldens/menus.jsonl.gz` (see `goldens/README.md`).
**Tests:** `tests/headless/test_menu_flow_log.gd` (the log-line builder on a hand-built page, not the flow).

A change detector for the Rust migration (step 1.5 of `todo/2026-11-27-rust-native-migration.md`). It boots
`Scenes.WORLD` the way a golden level replay does (`Benchmark.active` + `golden`, the blank fixture profile,
`RngStreams.reseed`, streaming on the main thread) at a fixed 1280×720 logical frame (`DisplayStretch` is
switched off for the run), then plays `menus.json`'s steps once per entry in `devices` (`key`, then `pad`),
on a freshly booted world each time so a page one device leaves open can't skew the next:

- `{"press": action}` sends the action's first `InputEventKey` (or, for `pad`, its first joypad button or
  stick event; the key when the pad has none) through `Input.parse_input_event`, press then release, as
  device 0 (InputMap copies carry device -1, which built-in actions like `ui_text_submit` don't match);
  `{"key": "Tab"}` sends one raw key for bindings that aren't actions (the map's deliveries key);
- `{"type": text}` sends unicode key events; `{"paste": text}` uses `DisplayServer.clipboard_set` and the
  platform's `ui_paste` key, or — when the headless clipboard keeps nothing — writes the focused field and
  emits `text_changed`, and the log's `press` says which path ran;
- `"only": "key"|"pad"` on a step plays it on that device alone (Esc and B differ in how many presses leave a page);
- `{"call": method, "args": [...]}` calls a `LevelView` method, for pages no press reaches headless (the wreck
  page needs a dead engine, the service menu a stop at a teleport point); an arg `{"teleport": i}` becomes
  `teleport_points()[i]`; `{"wait": frames}` (default 2). A card confirm's flash is skipped
  (`CardCarousel.skip_confirm_flash`) so the next press lands on the page it opened.

There is no title menu any more (`title.tscn` boots straight into the world), so the flow starts in the world.
After each step it logs `page` (`MenuFlow.page_id`: the focused menu's `MenuPage` title plus the nearest script
class, no node paths), `focus` (the focused control's text, a `CardCarousel`'s selected card title, or for a
textless widget its nearby label and class, e.g. `Master (HSlider)`),
`changed` (`MenuFlow.diff` of `Save.profile.settings`, the `LevelView` session statics, `paused` and the map; not `level_pose` / `level_map_seen`, which change on every drive) and
`boxes` (every visible Control under the page, `[text or class, [x, y, w, h]]` in whole logical pixels).
The flow never presses Send link / Sign in, and `Cloud` stays off under `Benchmark.active`, so it never
touches the network.

    $GODOT --headless --fixed-fps 60 res://benchmark/menu_flow.tscn -- --golden --seed=90210 --out=/tmp/m.jsonl
    ./bless.sh menus                                                  # rewrites goldens/menus.jsonl.gz
    $GODOT --headless --fixed-fps 60 res://benchmark/menu_flow.tscn -- --golden --seed=90210 --check   # exit 1 on the first differing line

A menu change that moves focus or a widget shows up as the first differing line's `focus` or `boxes`; if the
change was meant, re-bless.
