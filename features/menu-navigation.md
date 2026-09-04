# Menu navigation (keyboard / gamepad)

**Sources:** `scripts/menu_nav.gd` (`class_name MenuNav` — the flat-menu framework:
`attach`, `of`, `forget`, `remembered_target`, `is_on_screen`, `is_text_editing`,
`input_blocked`, `screen_claimer`) and `scripts/ui_theme.gd` (`focus_grab`,
`focus_grab_first`, `first_focusable`, the focus stylebox that paints the cursor).

**Tests:** `tests/headless/test_menu_nav.gd`, `tests/headless/test_menu_flow.gd`

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

> **There used to be a second regime here: the diegetic 3D HQ's `hq.gd::_unhandled_input`**,
> a set of bespoke per-station `menu_left`/`menu_right`/`menu_up`/`menu_down` branches for a
> continuous 3D space where "left/right" meant *cycle the parked car* or *pan the map camera*
> rather than *move focus to the neighbour widget*. That whole hub — `hq.tscn`, `hq.gd` and
> its nine collaborator scripts — was deleted in the roguelike pivot (decision 9,
> `todo/roguelike-pivot.md`; demolition in `todo/roguelike-pivot-plan.md` stage 2b). With no
> spatial hub left to navigate, the second regime is gone with it, not merely undocumented:
> **every menu in the game is a flat widget list now**, and `CLAUDE.md` has already been
> corrected to point here rather than at `hq.gd`. If a future screen ever needs a
> non-widget-grid navigation model again, it gets its own regime written up here — don't
> revive the old section as a template, its call sites no longer exist.

**What `MenuNav.attach(root, {first = ..., on_back = ...})` does, once:**

1. **Focus** — walks `root` and sets every interactive Control to `FOCUS_ALL` (a widget
   opts OUT with the `menu_nav_skip` meta).
2. **Grab** — deferred-grabs the cursor onto `first` (or the first focusable descendant),
   and re-grabs whenever the menu is re-shown.
3. **WASD** — fills the one gap in Godot's defaults: the built-in `ui_up/down/left/right`
   actions bind arrow keys + D-pad + left-stick but **not WASD**, so `MenuNav` translates
   the game's `menu_up/down/left/right` actions (which bind W/A/S/D) into focus-neighbour
   moves. Native `ui_*` still consumes arrows / stick / D-pad in the GUI phase *before*
   `_unhandled_input`, so only the WASD presses reach `MenuNav` — no double-movement, and
   no fragile `project.godot` surgery. **On a slider** (any `Range`) left/right instead
   *adjusts the value* by its `step` rather than moving focus, so the cursor merely
   resting on a slider is enough to change it — up/down still move focus off to the next
   row.
4. **Back** — routes **both** `ui_cancel` **and** `menu_back` to `on_back` (omit it and
   the host keeps its own back handling).
5. **Scroll-follow** — switches every `ScrollContainer` under `root` to `follow_focus`,
   so directional nav onto a row that's scrolled out of view auto-scrolls it into view
   (`follow_focus` is a no-op when nothing overflows, so it's safe everywhere).

`MenuNav` goes inert while its `root` is hidden — including a hidden `CanvasLayer` ancestor
(`Control.is_visible_in_tree()` alone misses that), so a hidden overlay never steals input
from whatever is behind it.

**Remembering the selected row (`remember = true`).** By default a menu re-opens on its
`first` row. Pass `remember = true` to `MenuNav.attach` and the cursor instead returns to
whichever row the player last had selected, falling back to `first` on the very first open,
or when the remembered row has gone away or is hidden. The framework tracks focus through
the **viewport's `gui_focus_changed`**, not per-widget `focus_entered` signals, so rows
built *after* `attach` (a menu that rebuilds itself) are covered with no re-wiring, and
focus landing outside the menu is ignored rather than recorded as this menu's row.
`MenuNav.remembered_target()` exposes the resolved answer for a host that needs to ask.
**Do not hand-roll this in a menu script** — a per-widget `focus_entered` tracker has to
know which of its widgets count as rows, misses ones added later, and has to re-derive the
hidden-sub-panel rule; one flag here covers every `MenuNav` menu. Covered by
`tests/headless/test_menu_nav.gd` (the `test_remember_*` group). **No shipped screen opts
into it today** — it's exercised directly by that test group, not by a live caller — so the
first flat-shell screen that wants "reopen where I left it" (a strong candidate: the car
shop, or the region-select grid once stage 4 builds it) can turn it on with no framework
work of its own.

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
control); `UITheme.focus_grab_first(root)` / `UITheme.first_focusable(root)` seat the
cursor on the first focusable control under a root. `UITheme.first_focusable` skips any
control in a **dying subtree** (an ancestor `queue_free`d this frame) — a rebuild that
frees whole row containers leaves their descendant buttons not-yet-`is_queued_for_deletion()`
themselves, so a deferred grab that ignored ancestors would land on a doomed button and lose
focus next frame.

**Live `MenuNav.attach` callers today:** the shared `SettingsMenu` (rows + bottom action
button — backs both the title-screen Settings page and the pause menu's), the **pause**
menu (Resume / Reset to track / Settings / Quit to HQ), `ConfirmPopup` and `UsernamePopup`
(the modal layer — see [modals.md](modals.md)), the HUD's **stage-complete panel**'s single
`NEXT` button (`hud.gd`, [hud.md](hud.md)), `AccountMenu` ([cloud-save.md](cloud-save.md)),
the pre-stage **start line**'s MENU row and its **Tune Car** overlay
(`start_line.gd` — see [start-line.md](start-line.md)), the between-stage **repair popup**
(`repair_reveal.gd`), and `BenchmarkResults` ([benchmark.md](benchmark.md)).
`scripts/upgrade_slot_popup.gd` (`UpgradeSlotPopup`, the shared detune-slider modal) still
attaches `MenuNav` too, but has **no live caller left** since the persistent parts model
that hosted it was deleted (`todo/roguelike-pivot.md` — the upgrades grid it used to pop out
of, `upgrades_grid.gd`, is gone) — it's orphaned code, not a reachable menu, until something
(the stage-5/6 boost shop, most likely) re-hosts it or it's deleted outright.

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

## A third host, not a third regime: `WorldPanel`

`scripts/world_panel.gd` (`WorldPanel`) / `scripts/world_panel_host.gd`
(`WorldPanelHost`) let a menu tree be hosted in a `SubViewport` shown on a 3D
`Sprite3D`, welded off-square to an anchor, instead of on a flat `CanvasLayer` — see
[world-panel.md](world-panel.md). It does **not** add a second navigation model: a
panel pumps *all* input, keyboard and gamepad included, across into its `SubViewport`
(which receives no window events on its own), so `MenuNav` works identically inside one.

**Today this is dead machinery with no live caller.** Every station that used to swap
itself into a `WorldPanelHost` (`hq_overlays.gd`, `hq_challenge.gd`, `rally_detail.gd`'s
old host, `upgrade_slot_popup.gd`'s old host) was hub-side and either deleted outright or
had its `WorldPanelHost` usage removed with the hub (`todo/roguelike-pivot.md` decision 9).
`config/game_config.tres` still ships `world_space_menus = true`, and `menu_page.gd` /
`ui_theme.gd` / `rally_detail.gd` still reference the class for layout math
(`WorldPanel.layout_frame_size`, used to size a body against the SubViewport frame rather
than the main viewport — that part is a genuinely host-neutral helper, not 3D-hosting), but
nothing currently constructs a `WorldPanelHost` and swaps a live menu tree into 3D space.
The pivot spec's read is that `WorldPanel` retires outright once nothing is left to weld a
panel to (`todo/roguelike-pivot.md` → "`WorldPanel` goes too") — that deletion hadn't
landed as of this writing. Until it does, or a future screen deliberately revives the host
swap, treat this section as describing dead code, not a live path players hit.

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
  Back-while-typing into "release the field" instead of "leave the page", via the shared
  **`MenuNav.is_text_editing()`** static.
- **Enter submits** (`submitted` signal) — on a phone the on-screen keyboard can cover the
  button, so this is sometimes the only way to submit at all. `virtual_keyboard_enabled` is
  on for Android/web.

Note that **Space is both `ui_accept` and a legal password character**; the focused field
consumes it first, so typing wins. Covered by `tests/headless/test_text_field.gd`.

## A third pattern: the single-action screen

A screen whose menu offers exactly **one** action needs neither `MenuNav` nor a focus ring,
because there is nothing to move a cursor between: the button stays `FOCUS_NONE` and the
screen's own `_unhandled_input` fires the action on `menu_select` (plus a screen touch / left
click).

**There is no live instance today.** The canonical one was `scripts/wreck_screen.gd`, whose
single *Return to HQ* button ended a wrecked run — deleted when damage stopped being able to
end a run at all (see [damage.md](damage.md)). The pattern is kept written down because it
is the right shape the next time a one-action screen appears (a plausible candidate: a
future "run over — you missed the timer" beat, if that ever needs its own screen rather than
folding into the run-summary screen stage 3 built), and because of two obligations that are
easy to miss:

- **Gate on the phase.** The wreck screen only accepted the input once its orbit had begun,
  so a press during a lead-in animation couldn't skip past the screen entirely. Any
  press-anything screen with a lead-in needs the same guard.
- **Test the input ACTION, not the button's `pressed` signal.** Those are separate code
  paths, so `pressed.emit()` alone leaves the keyboard/gamepad route unexercised — exactly
  the kind of pointer-only menu the project's nav rule forbids.

Reach for this only at one action. At two, use `MenuNav.attach`.
