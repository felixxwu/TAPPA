# Menu navigation (keyboard / gamepad)

**Sources:** `scripts/menu_nav.gd` (`class_name MenuNav` — the flat-menu framework:
`attach`, `of`, `forget`, `remembered_target`, `is_on_screen`, `is_text_editing`,
`input_blocked`, `screen_claimer`), the diegetic-HQ spatial handlers in `scripts/hq.gd`
(`_unhandled_input` and its per-station branches), and `scripts/ui_theme.gd`
(`focus_grab`, `first_focusable`, the focus stylebox that paints the cursor).

**Tests:** `tests/headless/test_menu_nav.gd`, `tests/headless/test_menu_flow.gd`

Every menu in the game is navigable with **up / down / left / right / enter / back**, on
keyboard *and* controller, alongside mouse / touch. This doc is the framework; the screens
themselves are in [menus.md](menus.md).

> **This is a project rule, not a nicety** (CLAUDE.md): when you ADD a menu or CHANGE an
> existing one, wire its navigation in the SAME piece of work and add or update a nav test.
> Don't ship a menu reachable only by pointer.

Every menu is fully navigable with **up / down / left / right / enter / back**, on
keyboard *and* controller, alongside mouse / touch. There are **two regimes**, and
which one a screen uses depends on whether its layout is a flat widget list or a 3D
space:

> **A third HOST exists (not a third regime): `WorldPanel`** — see
> [world-panel.md](world-panel.md). A menu can be hosted in the 3D world instead of on a
> `CanvasLayer`, welded off-square to an anchor, behind `Config.data.world_space_menus` —
> which `config/game_config.tres` ships **ON**, so this is the path players actually get.
> Either navigation regime
> works inside a panel, because the panel pumps *all* input — keyboard and gamepad
> included — across into its `SubViewport`, which receives no window events on its own.
> Two rules that follow from it:
>
> - **A screen may only become a panel if its camera pose is authored and static.** The
>   start-line pre-stage orbit and the **pause** menu stay
>   screen-space **permanently, by design** — a hard-welded panel under an orbiting camera
>   can be viewed edge-on with no recovery. This is a design rule, not unfinished work.
> - **Shared components stay host-neutral.** `SettingsMenu` backs both the HQ settings
>   overlay and the (permanently flat) pause menu, so it must work in either host without
>   knowing which.

- **Flat / overlay menus** use **Godot's native focus**, wired by the **`MenuNav`
  framework** (`scripts/menu_nav.gd`) so a menu author doesn't hand-roll (or forget)
  the per-widget setup. A menu calls **`MenuNav.attach(root, {first = ..., on_back = ...})`**
  once and the node it spawns handles all four chores: (1) walks `root` and sets every
  interactive Control to `FOCUS_ALL` (a widget opts OUT with the `menu_nav_skip` meta —
  used by the diegetic HQ buttons that keep `FOCUS_NONE`); (2) grabs the cursor onto
  `first` (or the first focusable) — deferred, and again whenever the menu is re-shown;
  (3) **fills the one gap in Godot's defaults** — the built-in `ui_up/down/left/right`
  actions bind arrow keys + D-pad + left-stick but **not WASD**, so `MenuNav` translates
  the game's `menu_up/down/left/right` actions (which bind W/A/S/D) into focus-neighbour
  moves. Native `ui_*` still consumes arrows / stick / D-pad in the GUI phase *before*
  `_unhandled_input`, so only the WASD presses reach `MenuNav` — no double-movement, and
  no fragile `project.godot` surgery. **On a slider** (any `Range`) left/right instead
  *adjusts the value* by its `step` rather than moving focus, so the cursor merely
  resting on a slider is enough to change it (WASD matches what arrows / D-pad / stick
  already do natively) — up/down still move focus off to the next row; (4) routes
  **both** `ui_cancel` **and** `menu_back`
  to `on_back` (omit it and the host keeps its own back handling); (5) switches every
`ScrollContainer` under `root` to **`follow_focus`**, so directional nav onto a row that's
scrolled out of view auto-scrolls it into view — without this the cursor can walk onto
items the user can't see (`follow_focus` is a no-op when nothing overflows, so it's safe
everywhere). `MenuNav` goes inert
  while its `root` is hidden — including a hidden `CanvasLayer` ancestor (how HQ toggles
  overlays), which `Control.is_visible_in_tree()` alone misses — so a hidden overlay never
  steals input from the station behind it.

  **Remembering the selected row (`remember = true`).** By default a menu re-opens on
  its `first` row. Pass `remember = true` to `MenuNav.attach` and the cursor instead
  returns to whichever row the player last had selected, falling back to `first` on the
  very first open, or when the remembered row has gone away or is hidden (it lives on a
  sub-panel the host is not currently showing). The framework tracks focus through the
  **viewport's `gui_focus_changed`**, not per-widget `focus_entered` signals, so rows
  built *after* `attach` (a menu that rebuilds itself) are covered with no re-wiring, and
  focus landing outside the menu is ignored rather than recorded as this menu's row.
  `MenuNav.remembered_target()` exposes the resolved answer for a host that needs to ask.
  **Do not hand-roll this in a menu script** — a per-widget `focus_entered` tracker has to
  know which of its widgets count as rows, misses ones added later, and has to re-derive
  the hidden-sub-panel rule; one flag here covers every `MenuNav` menu. Covered by
  `tests/headless/test_menu_nav.gd` (the `test_remember_*` group).

  **One owner for opening focus.** A menu that attaches `MenuNav` must **not** also fire
  its own `UITheme.focus_grab` when it opens. Showing the root fires `visibility_changed`,
  which the framework already answers; a second grab from the host silently wins on the
  same deferred flush, so any change made *through* `MenuNav` looks like it did nothing.
  `pause_menu.gd::open()` used to do exactly this, and it was masking a real bug — its
  `_show_settings(false)` call grabbed the Settings row unconditionally, even when the menu
  had never been showing Settings, and only the host's extra re-grab hid it. `_show_settings`
  now grabs only on a genuine *return* from the sub-panel.

  **Gamepad select / back.** Godot's built-in `ui_up/down/left/right` ship with D-pad
  + left-stick bindings, but `ui_accept` and `ui_cancel` ship with **keyboard only**
  (Enter/KP-Enter/Space, and Esc). Since a focused button fires on `ui_accept` and back
  routes through `ui_cancel`, a controller could move the cursor but neither select nor
  go back until `project.godot` [input] adds the face buttons: **`ui_accept` → gamepad
  button 0 (A)** and **`ui_cancel` → gamepad button 1 (B)**, alongside the keyboard
  defaults. This is the single global fix that makes *every* menu gamepad-selectable and
  gamepad-back-able — no per-menu wiring — because every back path already runs through
  `ui_cancel` (host handlers) or `MenuNav`'s `on_back` (which also listens for `menu_back`
  = B). Guarded by `test_menu_nav.gd` → `test_accept_and_cancel_have_a_gamepad_button`.

  `ui_accept` fires the focused control and the **focus highlight is the theme's `focus`
  stylebox**, which `tools/build_ui_theme.gd` defines to match the **hover** look — so a
  focus cursor and a mouse hover read identically (see [ui-design-system.md](ui-design-system.md)).
  `UITheme.focus_grab(ctrl)` is the guarded, call-deferred grab helper (grab a specific
  control); `UITheme.focus_grab_first(root)` / `UITheme.first_focusable(root)` seat the
  cursor on the first focusable control under a root (shared by `MenuNav` and HQ's
  native-focus pages). `MenuNav` covers:
  the shared **`SettingsMenu`** (rows + bottom action button — used by both the HQ
  settings overlay and the pause menu), the **pause** menu (Resume/Settings/Quit),
  the HUD **finish panel**'s single `NEXT` button (`StageCompletePanel`, attached in
`hud.gd._ready` with `first = NextButton`; re-grabs focus whenever the panel is
shown, so `ui_accept` proceeds to the results flow — [hud.md](hud.md),
[stage.md](stage.md)), the **standings** interstitial's single action button —
`FOCUS_ALL`, re-grabbed via
  `UITheme.focus_grab` both when the scene first opens and again on every
  `_build_ui()` rebuild (e.g. the overlay's show/hide toggle), so the
  cursor never drops when the button text/target changes — the **podium** Next, and
  the tuning-lift **Tune** (sliders — left/right nudges the focused one) and
  **Upgrades** (install parts / engine swap) pages, and — **the one nav that is attached to a
  shared component from OUTSIDE it** — the overworld hub's **rally-detail card**
  (`Overworld._build_rally_detail`; [overworld.md](overworld.md) → "Arriving opens the card").
  `RallyDetail` ships every button `FOCUS_NONE` because the HQ drives that card from
  `hq_table.gd`'s own input handler and has no cursor; the overworld instead calls
  `MenuNav.attach(page, {on_back, first = enter_button, grab = false})`, and `_enable` flips the
  buttons to `FOCUS_ALL` **for that instance only** — so one component serves a
  bespoke-input host and a `MenuNav` host without either knowing about the other. `grab: false`
  is required there: the card is built while hidden, and a Control inside a hidden `CanvasLayer`
  still reports `is_visible_in_tree()`, so the build-time grab would steal the cursor from
  whatever is on screen — MenuNav's `visibility_changed` re-grab seats it when the card opens.

  Its sibling the overworld **car picker** deliberately does **NOT** use `MenuNav` — see the
  second regime below. On the standings interstitial specifically,
  the `MenuNav` `on_back` callback (`_on_back_pressed`) is a deliberate **no-op**: it
  is a single page mid-rally with nowhere to go back TO, and consuming the press stops
  it falling through to whatever is behind (pause / the replay host).
  Standings re-runs `MenuNav.attach`
  on every `_build_ui()` rebuild; `attach` reuses the existing node rather than stacking
  handlers, and re-seats the cursor on the freshly-built button.

  **Page 2: the global stage leaderboard (`GlobalStandings`, see
  [global-leaderboards.md](global-leaderboards.md)).** `Standings._advance()` is
  the **SOLE exit** from the whole standings screen and a strict two-step ladder:
  page 1 (local standings) → page 2 (world standings) → resume. The
  1st `_advance()` call shows page 2; the 2nd resumes the rally via
  `RallySession.continue_to_next_event()` — still the only call site for it.
  Page 1's action button is now
  unconditionally **"Next >"** — it only ever does one thing (open page 2), and the
  wording is deliberately generic rather than naming the destination. Page 2 is a sibling `Control` added over page 1 that REPLACES its content
  rather than sitting beside it: page 1's root VBox is hidden — `visible = false`
  — which, because nothing else ever takes over the screen, means page 1's
  root VBox is ALWAYS still there to hide — which also makes page 1's
  `MenuNav` inert (`MenuNav._unhandled_input` is gated on its root being visible), so
  only page 2's own `MenuNav.attach(self, {first = cont, on_back = _on_back})` (inside
  `global_standings.gd`) is live and the two can never race on a Back press. **This
  only works because `standings.gd` attaches page 1's `MenuNav` to the node it hides,
  not to itself** — `_build_ui` calls `MenuNav.attach(root, …)` and
  `_on_global_back` calls `MenuNav.attach(_root_box, …)`, both onto the same VBox that
  gets `visible = false`. Attaching either one to `self` (the screen, which is never
  hidden) instead of `root`/`_root_box` was a real bug: `MenuNav` would stay live
  behind page 2 regardless of the hide, and input would leak through to it. Five
  states —
  `LOADING`/`SIGNED_OUT`/`NO_USERNAME`/`POSTED`/`UNAVAILABLE` — each with its own body
  built by `_build_body`. Separately from `_state`, an extra full-width affordance
  button (Sign in / Choose a name) can appear above the Back/Continue row — this is
  now this page's **fallback** name-capture tier (see
  [global-leaderboards.md](global-leaderboards.md) for the primary, at-sign-in tier
  and why the fallback exists), driven by `_prompt_kind()` off LOCAL facts
  (signed-in / has-a-username / has-a-time), **not** off `_state` or the fetch
  result — an earlier version gated it on a successful fetch, which meant the
  player most likely to hit a failed read (the first one on a brand-new board)
  could never be prompted at all. Each button opens its own `MenuNav`-wired
  overlay (`AccountMenu` in a `CanvasLayer`, or `UsernamePopup` — dismissable, does
  not reopen on decline) that re-runs the fetch on close so a just-set time can
  post without re-driving; the cursor seats on this button, not Continue, whenever
  it's showing. Back is offered on **every** stage now (`show_back :=
  is_instance_valid(_root_box)`, which is always true
  in practice, since page 1 is never torn down before page 2 runs); `_on_back`'s
  `if not show_back: return` no-op guard is a defensive backstop for the case,
  not something the current flow exercises.
  `Standings._on_global_back` frees page 2, un-hides page 1, and re-attaches page 1's
  `MenuNav` with focus back on the action button — deliberately NOT re-running page 1's
  row reveal, since replaying a board the player already read is noise.

  **Page 2's action button is the exit.** It reads **`Continue to next stage >`** on a
  non-final event and a generic **`Next >`** on the last one, and pressing it calls
  `RallySession.continue_to_next_event()`. There is no third rung: nothing is awarded
  between stages any more, so the interstitial's only job is to show the player where
  they stand locally and globally and hand them back to the rally. (Cars are still
  revealed at the podium — see [reward-system.md](reward-system.md).)

  A few flat menus keep their own `_unhandled_input` and attach `MenuNav` **without**
  `on_back`: the **pause** menu (its handler also *opens* the menu when closed, and
  steps sub-page → list → menu, which a plain back callback can't express), and the HQ
  overlays (**title**, **settings**, **Tune/Upgrades**), where `hq.gd._unhandled_input`
  owns `menu_back`. There they lean on `MenuNav` purely for the WASD gap + `FOCUS_ALL`.
  The HQ lift attaches `MenuNav` to the **Tune/Upgrades sub-boxes only** — never the lift
  root — so the diegetic HUB buttons (`FOCUS_NONE`, manual left/right cursor) stay
  untouched. The **Upgrades** page is the reusable `UpgradesGrid` component
  (`scripts/upgrades_grid.gd`), which owns its OWN focus-preserving
  `rebuild()` + `MenuNav.attach` (`upgrades_grid.gd` → `rebuild`) — the lift root itself is
  never attached. `UpgradesGrid.rebuild()` runs on every refresh (per car / after an
  option is applied); it frees only the grid children (**not** the `MenuNav`
  child — freeing it would kill WASD/gamepad nav) and re-runs `MenuNav.attach` (carrying its
  own stored `_on_back`, so no caller ever has to re-attach) so the new
  buttons become focusable and its cursor-revive `first` re-seats on a live control. Note
  `UITheme.first_focusable` skips any control in a **dying subtree** (an ancestor
  `queue_free`d this frame) — the rebuild frees whole row containers, whose descendant
  buttons aren't themselves `is_queued_for_deletion()`, so a deferred grab that ignored
  ancestors would land on a doomed button and lose focus next frame. To keep the cursor
  put when applying an option triggers the rebuild (rather than flinging it to the
  first tile), each tile carries a stable `upgrade_focus_key` meta (its slot);
  `rebuild()` captures the focused
  control's key before clearing and `_restore_focus` re-grabs the FRESH control with that
  key afterward (using the same dying-subtree guard so it doesn't grab the about-to-be-
  freed old one).

  The **`start line`** pre-event overlay carries ONE horizontal action row across the
  bottom — **`< Exit | Upgrades | Tune Car | Start`** (`start_line.gd::_build_overlay`,
  built via `_row_button`) — the same shape the garage row and lift hub use. It uses
  `MenuNav.attach(root, {first = _start_button})` for keyboard/gamepad focus; a pointer
  tap on the clear band still launches. Two things about it are load-bearing:

  * **The pause menu is SUPPRESSED for the whole staged window.** `world.gd` calls
    `pause_menu.set_input_enabled(false)` when it builds the start line and re-arms on
    `StartLine.sequence_finished` (`_on_start_line_finished`), which fires at the
    hand-off. Note the "world is ready" arming chokepoint runs AFTER `_build_start_line`,
    so it arms with `not is_instance_valid(_start_line)` — arming unconditionally there
    re-enabled the Pause button the start line had just switched off, which is how a
    pause overlay ended up stacked over the start line's own menu with the two fighting
    for the same taps. `PauseMenu._pause_button.visible` follows `_input_enabled` for
    the same reason: an inert-but-visible button is a trap. **Exit** exists precisely
    because pause is gone — it routes to `PauseMenu.confirm_quit_to_hq()` so the
    "abandon a rally vs. pause a challenge" wording and the benchmark/challenge/rally
    branching live in one place.
  * **The buttons drop `UITheme.BUTTON_MIN_W`.** That 180-unit floor is right for a
    stacked column, but four of them side by side need ~750 logical units against a
    canvas only ~556 wide on a 16:9 aspect (narrower still on a portrait/narrow phone aspect), so the row
    ran off both edges. `_row_button` keeps the house row HEIGHT and lets each button
    hug its own label.
  `world.gd._show_repair_popup` builds the between-event **pit-repair popup**
  (`repair_reveal.gd`, its own `MenuNav.attach(self, {first = _continue_button})`)
  in a CanvasLayer stacked ON TOP of an already-built, already-attached start-line
  overlay — but freeing that popup's Continue button (`layer.queue_free()`) clears the
  viewport's focus owner outright, and nothing re-grabs it: `MenuNav` only re-grabs on
  its OWN root's `visibility_changed`, which the start-line overlay never fires here.
  Left alone this strands keyboard/gamepad players with no focus after dismissing the
  popup. The fix, mirroring the `hq.gd` in/out pattern but on the way OUT of an overlay:
  after `queue_free()`, `_show_repair_popup` calls `get_viewport().gui_release_focus()`
  then `_start_line.grab_start_focus()` (`start_line.gd`), a small public wrapper around
  `_start_button.grab_focus()`. Opening
  **Tune Car** hides the start overlay and attaches `MenuNav` to the tune overlay (Back
  routed via `on_back`); it opens the shared `TuningPanel` (three handling-axis sliders)
  for the car about to race (see [tuning.md](tuning.md)), edits re-field the live car via
  `car.retune()`. Opening
  **Upgrades** hides the start overlay and attaches `MenuNav` to the upgrades overlay
  (close routed via `on_back` — here the gated `request_close`); it opens the shared
  `UpgradesGrid` (see below) — whose `tune` tile hosts the **engine-detune slider** —
  edits re-field the live car via `car.refit_upgrades()`.
  Here `UpgradesGrid` is passed `StartLine._rating_limit()` (a thin wrapper over
  `DrivingContext.rating_limit()`), so the overlay's close button reads **Done** and, while
  the build exceeds the ceiling, turns red (**"Over limit — reduce to N performance"**) and
  blocks closing — both the button and Esc / back are refused until the build is back
  under. Only a Rally Challenge sets a ceiling; a career rally and the HQ garage lift leave
  it at `NO_LIMIT` (`-1`) so the button stays a plain **Back** that closes freely. The detune slider in the `tune` tile's popup
  spans the full **0–100 %** in both places — eligibility is enforced by the gated Done
  button, not by capping the slider. The upgrade
  re-field is the upgrade-only re-field path
  parallel to `retune()` for tuning, which does NOT reshape the staged body. Pressing
  **Start** runs the eligibility gate: an over-powered car gets a **"Too powerful"**
  `ConfirmPopup` with **Change Upgrades** / **Cancel** (mirroring the
  HQ car park); any other ineligibility gets the reason with **Change Upgrades** /
  **Cancel**. **Change Upgrades** opens the gated upgrades menu (the player sheds power
  via the detune slider / ballast / stripping parts — a **permanent** garage edit, no
  auto-revert) and, once the build is under the cap and the menu closes, the player
  re-presses Start to launch. (The **wreck screen** used to be listed here as the one
  *press-anything-to-continue* screen that skipped `MenuNav`; it is gone — damage can no
  longer end a run, so there is nothing to press through. See
  [damage.md](damage.md).)
- **Diegetic 3D HQ stations** can't be a focus graph — "left/right" means *cycle the
  3D car / fly the camera*, not "move focus to the neighbour widget" — so they keep
  HQ's bespoke **`menu_*` action** handlers in `hq.gd._unhandled_input` (the
  `menu_left`/`menu_right`/`menu_up`/`menu_down`/`menu_select`/`menu_back` actions,
  which bind arrows + WASD + D-pad + Enter/Esc + gamepad A/B). The **car park**
  cycles the focused car with left/right (flipping pages at a page boundary, see
  `CarList`) and fires Start with select; the lineup is also **pointer-navigable**
  (`_lineup_pointer_input`): a horizontal **swipe** (mouse drag, or finger via
  `emulate_mouse_from_touch`) past `GameConfig.menu_swipe_min_px` cycles the focus
  (drag left pulls the next car in, carousel-style), and a **tap** (total travel under
  `GameConfig.menu_tap_max_px`) raycasts into the lot (`_car_index_at`, a plain
  space query — the frozen props keep their bodies in the physics space) and focuses
  the parked car under the pointer directly, so a touch or mouse player never has to
  find the small ◄ ► buttons (both overlays are `_passthrough_overlay`'d — everything
  but the buttons is `MOUSE_FILTER_IGNORE`, or the full-rect HUD would swallow the
  click before `_unhandled_input` sees it) — the
  car park's **engine-swap mode** (`_carpark_swap_mode`, [engine-swap.md](engine-swap.md))
  is the same station reused with a mode flag, so it inherits this nav for free: left/right
  cycles the swap-eligible target cars, select confirms the swap (`_select_swap_target`),
  and back (`_car_back`) returns to the tuning-lift Upgrades page instead of the map table;
  the car park's **cosmetic wheel mode** (`CarparkMode.WHEELS`,
  [wheel-customization.md](wheel-customization.md)) reuses the same station for one car
  ALONE under a low side-on camera (`hq_wheel_cam_offset`), where left/right **and**
  up/down cycle wheel styles live on the settled car (`_cycle_focus` → `_cycle_wheel`),
  select fits them and back discards the preview and returns to the lift;
  the **map table** is driven by a **camera glide**: holding
  `menu_up/down/left/right` slides the camera smoothly over the map (polled in
  `hq.gd._process`, glide speed `hq_table_pan_glide`; the pan step itself is
  `hq_table.gd._pan_table_step`), and selection tracks whichever
  target sits nearest the view centre — a reticle over the map, not a jump between pins.
  Because that selection step runs every frame while a direction is held, it repaints the
  focus highlight only when the selection actually changes
  (`hq_table.gd._select_target_under_center` guards on `_table_focus_node`) — repainting
  allocates a `StyleBoxFlat` per pin, so doing it unconditionally cost ~28 allocations a
  frame at full unlock. The guard keys on the pin NODE, not `_table_focus_index`, because
  `_refresh_map_pins` rebuilds the pin nodes without resetting the index.
  The target set is **every** rally pin. There is **one world map**
  (`RegionLibrary.DEFAULT_MAP_IMAGE`) carrying the WHOLE roster
  (`_refresh_map_pins` builds a pin per `RallyLibrary.all()` entry), so there are no
  map-swap arrows and no viewed region — an unrevealed rally is still pinned, just
  locked (grey and non-pickable). It **is** in the focus ring, though
  (`_unlocked_pins` returns every pin): readouts are hover-only, so a pin the cursor
  could not reach would be a shape on a dark table that never answers when you point at
  it. It's `_activate_table_focus` that refuses to OPEN a locked pin, not the cursor that
  refuses to land on it.
  `_select_target_under_center()` seats `_table_focus_index` on the
  target nearest `_table_center_pos()` (the fixed table camera's look point offset by the
  live `_table_pan` — `_table_plane_axes` derives on-screen up/right from the camera pose)
  — but **only within `GameConfig.map_select_radius_m`** of it. Past that nothing is
  selected at all (`_clear_table_focus`), so Select over empty sea opens nothing instead of
  whichever rally happened to be least far away. Every distance compared against that radius
  is measured in the map PLANE (`_nearest_target_to_center` zeroes Y): a pin stands a
  table-height above the plane the view centre lies in, so a raw 3D distance never comes
  under it.
  **On entry (`_enter_table`) the map doesn't open dead-centre: it steers straight to the
  toughest event still to beat.** `_focus_hardest_incomplete()` picks the highest-difficulty
  (hidden authored tier) rally pin the player hasn't completed (`Save.rally_completed`),
  ties breaking toward the first in rally order, and pans the camera onto it so selection
  sticks there. Only when every pin is done (or there are none) does it fall back to
  `_focus_nearest_target()` — which seats the cursor on the nearest pin **and pans onto
  it**, at any distance. That fallback deliberately ignores `map_select_radius_m` (the rule
  for a cursor the *player* is driving, not for seating one): entry re-centres the map, and
  the middle of the map is rarely within 0.55 m of a pin, so testing what already lies under
  the reticle opened the table with nothing selected at all.
  **Unless there is something new to reveal** — see
  "New-rally reveal" below, which takes over the entry instead.
  Pan is clamped to the map extents, so at an edge the camera simply stops. The selected
  pin gets the hover-style readout underline. `menu_select` fires the selected target,
  opening that pin's rally detail (`_activate_table_focus` — pins are the only kind of
  target). `menu_back`
  exits to the garage. Clicking a pin with the pointer still works (`_on_rally_pin`),
  and mouse drag still pans the map (selection re-tracks the centre as it
  slides); the **tuning hub** is a **two-row** manual cursor, so it binds all four
  directions (`enum LiftRow { SELECTOR, ACTIONS }`, `_lift_row` says which row holds the
  cursor):

  **The overworld's car picker is the newest member of this regime** (`OverworldPicker`;
  [overworld.md](overworld.md) → "Picking a car in place"). It is a **carousel**, not a widget list:
  one car shown at a time in a bar along the bottom, cycled with left/right. That is why it cannot
  use `MenuNav` — a focus cursor would take `ui_left`/`ui_right` to hop between the two chevrons and
  the **car would stop changing**, which is two competing selection models on one screen (the trap
  the map cursor fell into). So every button in the bar stays `FOCUS_NONE` (pointer/touch
  affordances, chevrons additionally `menu_nav_skip`ped), nothing consumes input in the GUI phase,
  and the picker's own `_unhandled_input` maps left/right → change car, accept → confirm,
  back → cancel. In STARTER mode the back branch is simply absent, so the press falls through and
  **Esc still reaches the pause menu** rather than sealing the player in.

  ```
  SELECTOR row:  [ < ]  CAR NAME  [ > ]                 _lift_selector_cursor / _lift_selector_focus
  ACTIONS row:   < Back | Upgrades | Tuning | Test Drive  _hub_cursor / _hub_focus
  ```

  `menu_up`/`menu_down` move BETWEEN the rows (`_move_lift_row`), `menu_left`/`menu_right`
  move WITHIN whichever row is active (`_move_hub_focus`), and `menu_select` fires the
  active row's item (`_activate_hub_focus`). `_refresh_hub_focus` paints **exactly one**
  row: the inactive cursor is refreshed at an out-of-range index, which clears every button
  in it, so there is never doubt which row a press will hit. `_enter_lift` seats
  `_lift_row = LiftRow.ACTIONS` with the cursor on Upgrades (`menu_back` is also a shortcut
  back to the garage). **Test Drive** (`_test_drive`) launches free roam with the car
  already on the lift — no car picker, since we're already focused on one; it delegates to
  `_start_free_roam` (see below). To work on a **different** car you don't leave the bay:
  the selector chevrons put the previous / next owned car on the lift in place
  (`_cycle_lift_car`, also clickable), which is why there is no Change Car button and why
  the garage's **Garage** button no longer opens a picker first.
  (There is no **Repair** button on this row — repair kits are gone and damage is
  one-way; see [damage.md](damage.md).) **Wheels** no longer lives on this hub row — it's a
  button inside the **Tuning** page itself (`tuning_panel.gd`, `TuningPanel._wheels_button`,
  native `FOCUS_ALL` matching the panel's sliders), wired via a `setup(owned_car,
  on_change, on_wheels)` callback the lift passes as `_enter_wheel_swap`; the start-line's
  copy of the same panel (`start_line.gd`) passes no `on_wheels`, so `TuningPanel` hides
  the button there (a no-op button would be confusing pre-rally). The **garage** is likewise a
  left/right cursor (`_garage_focus`, painted by `UITheme.mark_focused`,
  `_activate_garage_focus`) over a **single** side-by-side row (`_refresh_garage_row`),
  seated on **Career** (`_garage_career_index`) on entry, with `menu_back` leaving for
  the exterior exactly as the row's own Back button does. The row is
  **Back / Career / Garage / Online / Multiplayer** — a **fixed five stops**, with no
  conditional members, so the row's length and focus chain are **static**: left/right
  walks the same five every time, on every save. (Still ask `_garage_career_index` / the
  cursor's `buttons` array rather than hardcoding an index — that survives a reorder.)
  `_station_xform(View.GARAGE)` has one
  framing, the wide shell view. **No header caption** on this view: it used to carry
  "GARAGE — tap the map table to choose a rally, or the lift to tune your car", which named
  the room you can see and gave instructions for two objects already lit, labelled and
  pickable in the 3D scene. The station IS the menu, so a line of prose over it only competes
  with what it describes. Same reasoning removed the
  car park's "Choose your car" line (see the present box below, the one mode that still shows
  that label).

  **NOTHING ELSE stands over the room** — the action row is the whole overlay.
  *There used to be one more line:* the **next carrot**, a top-left `UITheme.readout_box()`
  naming the nearest locked special, built in `build_garage_overlay` and written by
  `hq._carrot_line` / `hq._refresh_carrot_line` (both **deleted**, along with
  `_carrot_panel` / `_carrot_label` and their three `test_menu_flow.gd` guards). It began as
  a progress quote — "2 MORE RALLIES → THE FOOTHILLS TRIAL" — which was the part that earned
  it: a live number that existed nowhere else in the hub. Exploration replaced the tally
  with a *position* on the map, leaving no number to quote; and because a part-unlock
  special is titled after its own reward, `hq._special_unlock_line` returns `""` for exactly
  those, so the line ended up a bare rally name ("UPGRADE: SUPERCHARGER") standing over the
  garage with nothing saying what it was or why it was there. The **map table still teases
  the same special** (`hq._build_special_teaser_label`, see the TABLE section) — on the map
  the name sits on the ground the player has to light to reach it, which is the context the
  garage line could not carry.

  *This row used to be TWO levels:* a **Drive** button swapped it for
  Back / Career / Free Roam / Online, with its own Back going up a level and its own
  low 3/4 hero-shot framing. That bought an extra press in and an extra press back on
  the way to every stage, so it was flattened — Career and Online sit alongside Garage,
  **Free Roam moved to the title screen** (it needs no owned car, session or lift), and
  the drive-level camera pose (`_drive_cam_xform`, `hq_drive_cam_*`) went with it.
  **Multiplayer** joined the row afterwards, last (see the Entry point section of
  [multiplayer-lobby.md](multiplayer-lobby.md)), as a modal overlay over the garage the
  same way Online is — not a sixth View, just a fifth garage-row stop.
  **Garage** (`_enter_lift`) drops **straight into the tuning lift bay** for the currently
  selected car. It used to open the car park FIRST (a `CarparkMode.GARAGE` mode, parking the
  whole owned collection, whose Select committed the focused car and then entered the bay);
  the lift's own **selector chevrons** change the car on the lift in place now
  (`_cycle_lift_car` — see LIFT below), which made that picker a press in and a press back
  on the way to the only screen anyone wanted. The mode, `_open_garage_picker` and
  `_select_garage_car` are all gone. **Free Roam** (`_enter_free_roam`,
  `CarparkMode.FREEROAM`, reached from the **title screen**) parks the WHOLE catalogue as base-model previews (`_all_car_previews`,
  owned or not); Start (`_start_free_roam` → `_launch_free_roam`) drops into a session-less
  drive in the picked car — an owned car fields its tuned instance, a not-yet-owned preview
  fields the base model via `RallySession.free_roam_model_id` (see the free-roam machinery
  below and `world.gd`) — and Back returns to the **title screen**, which is where Free Roam
  is now entered from. **Neither Settings nor Free Roam lives on this
  row** — both moved to the title screen (see the EXTERIOR section below), since Settings
  from the garage and Settings from the title now always return to the same place
  (EXTERIOR), so there's no reason to offer it twice. Both of these
  manual rows, plus the title row (see below), share a small **`ButtonCursor`** helper
  (`scripts/button_cursor.gd`): `hq.gd` keeps the index (`_title_focus` / `_garage_focus` /
  `_hub_focus`), the cursor owns the shared
  wrap / repaint / fire behaviour, and each button's `pressed` callable is also the
  cursor's action for that index, so a mouse click and a keyboard/gamepad select can
  never fall out of step. The cursor **skips `disabled` buttons** (like native focus):
  `wrapped` steps past them, `settled(index)` re-seats off a button that just greyed out,
  and `activate` no-ops on a disabled item — leaving an unavailable action unreachable
  without rebuilding the row. (The map-table pin cursor stays bespoke — it paints a
  billboarded pin panel and pans the camera, not a flat button row.) **Free roam** has two
  entries, both funnelling through `_launch_free_roam(instance_id, model_id)`: **Test Drive**
  on the tuning-bay hub (`_test_drive`) drives the on-lift OWNED car (its tuned instance),
  and the garage **Free Roam** picker (`_start_free_roam`) drives the focused catalogue car —
  an owned entry by instance, a not-yet-owned preview by `model_id`. `_launch_free_roam` sets
  `RallySession.free_roam_instance_id` / `free_roam_model_id` accordingly (the id normalised
  to −1 when a model is given), writes a fresh random seed + neutral
  (0.5) terrain settings into the live Config (`_prepare_free_roam`) — plus a randomised
  landscape each entry: lake depth (`track_water_level_m` in −15..−5), large-scale relief
  (`terrain_layer1_amplitude` in 10..35), and a random home/Greece location
  (`RallySession.free_roam_region_id`, read by `world.gd._current_region_look`) — and loads the run
  scene with NO active `RallySession`. `world.gd` fields that car — the owned instance if set,
  else the base model via `CarLibrary.index_of(free_roam_model_id)`, falling back to the
  default library car — and skips the rally/start-line/podium wiring; the player
  leaves via Pause → Quit to HQ, or by finishing the track — with no session to report
  to, the finish panel's **Next** returns straight to HQ
  (`world._on_session_event_completed`'s no-session branch).
  Because HQ hides overlays by toggling their
  **`CanvasLayer`** (which does *not* clear a `Control`'s focus — a CanvasLayer breaks
  the visibility chain), `go_to` / `_lift_hub` call `hq.gd::_release_all_focus()`
  on every transition so a button on the view just left can't keep focus and silently
  swallow arrow keys / Enter in the next, spatially-navigated station; the
  native-focus views re-grab a control right after.

> **When you add or change a menu, wire its navigation in the same piece of work.**
> A flat list: call **`MenuNav.attach(root, {first = <button>, on_back = <Callable>})`**
> once after building it — the framework makes the widgets focusable, seats + re-seats
> the cursor, fills the WASD gap, and routes `ui_cancel`/`menu_back` to `on_back`. Omit
> `on_back` if the host owns "back" itself (e.g. a toggle handler); mark a widget with
> the `menu_nav_skip` meta to leave it `FOCUS_NONE`. A new HQ station: add a `menu_*`
> branch in `hq.gd._unhandled_input` and release focus on entry. Add a nav test (see
> `tests/headless/test_menu_nav.gd` / the nav cases in `test_menu_flow.gd` /
> `test_pause_menu.gd`).
>
> **Attach ONCE, not on every state change.** `attach` defers a focus **grab** (chore 2), so
> re-attaching to refresh something — typically to keep an `on_back` route alive after a
> rebuild — yanks the cursor to the first control every time. That is a real bug that shipped:
> the upgrades page's host re-attached `MenuNav` after each edit to keep its back route alive,
> and left/right on the engine-detune slider adjusted the value and then jumped the cursor to
> the top of the page. The fix is for the page to **own** the thing that was being refreshed
> and re-apply it from its own `rebuild()`, so
> `attach` runs once per build and nobody re-attaches from outside.

#### A third pattern: the single-action screen

A screen whose menu offers exactly **one** action needs neither framework, because there is
nothing to move a cursor between: the button stays `FOCUS_NONE` and the screen's own
`_unhandled_input` fires the action on `menu_select` (plus a screen touch / left click,
matching the start line). `MenuNav.attach` would add a focus ring and arrow-key handling
that have nowhere to go.

**There is no live instance today.** The canonical one was `scripts/wreck_screen.gd`, whose
single *Return to HQ* button ended a wrecked run — and that whole flow was deleted when
damage stopped being able to end a run at all (see [damage.md](damage.md)). The pattern is
kept written down because it is the right shape the next time a one-action screen appears,
and because of the two obligations it carries, which are easy to miss:

- **Gate on the phase.** The wreck screen only accepted the input once its orbit had begun,
  so a press during the crash animation couldn't skip past the screen entirely. Any
  press-anything screen with a lead-in needs the same guard.
- **Test the input ACTION, not the button's `pressed` signal.** Those are separate code
  paths, so `pressed.emit()` alone leaves the keyboard/gamepad route unexercised — exactly
  the kind of pointer-only menu the project's nav rule forbids.

Reach for this only at one action. At two, use `MenuNav.attach`.

