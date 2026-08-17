# Menus & game-loop shell

**Sources:** `hq.tscn` + `scripts/hq.gd` (`class_name HqController`), the 2D
overlay/menu-layer builders in `scripts/hq_overlays.gd` (`class_name HqOverlays` —
the `build_*_overlay()` methods, split out of `hq.gd` to shrink it; each holds a
back-reference to the `HqController` and reaches into it for state + button
callbacks), the Rally Challenge screen in `scripts/hq_challenge.gd` (`class_name
HqChallenge`), the map table in `scripts/hq_table.gd` (`class_name HqTable`), the car park in
`scripts/hq_carpark.gd` (`class_name HqCarpark`) — all three the same shape as `HqOverlays`,
described below — `podium.tscn` + `scripts/podium.gd`, plus the
session-aware fielding
in `scripts/world.gd`. See the full design in [../todo/menus.md](../todo/menus.md).

This is the **diegetic 3D build** of the menu shell: HQ is one continuous 3D space
the camera flies through (an exterior title shot, a garage interior, the map table,
and the outdoor car park) rather than flat overlay screens. It still closes the
whole meta-game loop — pick a rally on a 3D map, choose an eligible car in the car
park, run it, see the podium — and wires [rally-session.md](rally-session.md) into
the run scene. The podium + between-event standings are still flat scenes (the 3D
reward rig / podium are later refinements); remaining diegetic polish (tuning UI,
per-car paint, camera fly-throughs *between* far stations) is tracked in the
"Deferred (rest of the diegetic 3D build)" section below.

## The loop

```
exterior title ─Start─▶ garage ─tap table─▶ map table (pick rally pin) ─▶ rally detail ─Enter─▶ car park (pick eligible car) ─Start─▶ RallySession.start_rally ─▶ main.tscn (event 0) ─start line: briefing + presence ─launch─▶ countdown ─▶ RUN
   main.tscn ─StageManager.stage_completed─▶ report_event_result ─▶ standings.tscn (EVERY event pauses here) ─Continue─▶ next event
                                          └─ car.wrecked ─▶ WreckScreen (crash → orbit + menu) ─Return to HQ─▶ report_wreck (DNF)
   final event's standings.tscn ─Continue─▶ continue_to_next_event resolves ─rally_finished─▶ podium.tscn ─Continue─▶ HQ
   (DNF / abandon) ─rally_finished─▶ podium.tscn or HQ
```

## Button order — leaving is left, proceeding is right

**In any row of buttons: the action that LEAVES (Back / Exit / Cancel / Quit / Decide
later) is leftmost, and the action that PROCEEDS (Start / Enter / Confirm / Drive) is
rightmost.** Everything else sits between them. This is a house rule, not a per-screen
choice — apply it to every new row without asking.

Reference rows: `start_line.gd::_build_overlay` (`< Exit | Upgrades | Tune Car | Start`),
`hq_overlays.gd::build_title_overlay` (`Exit Game | Free Roam | Settings | Start`),
`hq.gd::_refresh_garage_row` (`< Back | Career | Garage | Online` — a fixed four),
`build_detail_overlay` (`< Map | Enter Rally >`), `build_challenge_overlay`
(`< Back | Start`).

**Two traps when reordering an existing row:**

1. **`ConfirmPopup.open`'s `default_index` and `back_index` are POSITIONAL.** Reversing
   the `actions` array without updating them silently changes which button is focused
   and which one Esc / gamepad-B fires. `back_index` now defaults to the **first**
   action (it used to be the last, correct only while dismiss sat on the right) — get
   this wrong and Escape abandons a rally or overwrites a career. Single-action popups
   are unaffected: first and last are the same button.
2. **Cursor seat indices are not constants.** `ButtonCursor` rows seat the cursor by
   index, and some rows have CONDITIONAL members — "Exit Game" is skipped on web. So
   "the proceeding action is last" can be a different index per platform. Compute it
   (`hq.gd::_title_start_index`, `hq.gd::_garage_career_index`) rather than hardcoding,
   and have tests assert by button IDENTITY rather than by literal index. (The garage
   row is no longer one of the varying ones — its four stops are unconditional, so its
   focus chain is static — but keep asking `_garage_career_index` anyway: identity-based
   lookups survive the next reorder, literals don't.)

**Vertical columns are a separate convention and are deliberately NOT changed by this
rule:** they put the exit at the BOTTOM (last) — see `pause_menu.gd::_build_menu_panel`
(`Resume / Reset to track / Settings / Quit to HQ`), `account_menu.gd::_build_email_form`
and the `< Back` at the foot of every scrolled modal page. That is consistent across the
game; treat any change to it as its own decision.

## Menu navigation (keyboard / gamepad)

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
>   start-line pre-stage orbit, the wreck-screen orbit and the **pause** menu stay
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
  **Upgrades** (install parts / engine swap) pages. On the standings interstitial specifically,
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
  re-presses Start to launch. The
  **`wreck screen`** is still a *press-anything-to-continue* screen (a tap anywhere,
  or `menu_select` = Enter / gamepad A, proceeds), not a multi-item navigable menu, so
  it doesn't use `MenuNav`.
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
  **Back / Career / Garage / Online** — a **fixed four stops**, with no conditional
  members, so the row's length and focus chain are **static**: left/right walks the same
  four every time, on every save. (Still ask `_garage_career_index` / the cursor's
  `buttons` array rather than hardcoding an index — that survives a reorder.)
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
nothing to move a cursor between. `scripts/wreck_screen.gd` is the one instance: its Return
to HQ button stays `FOCUS_NONE`, and its own `_unhandled_input` fires the action on
`menu_select` (plus a screen touch / left click, matching the start line). `MenuNav.attach`
would add a focus ring and arrow-key handling that have nowhere to go.

Two things this pattern must still do, and the reason it is written down rather than left as
a one-off: it has to **gate on the phase** — `wreck_screen.gd` only accepts the input once
`_seq == Seq.ORBIT`, so a press during the crash animation can't skip it — and it needs a
test that drives the **input action**, not the button's `pressed` signal. Those are separate
code paths, so `pressed.emit()` alone leaves the keyboard/gamepad route unexercised (see
`test_menu_select_returns_to_hq_without_a_pointer` and
`test_menu_select_is_ignored_before_the_menu_appears` in
`tests/headless/test_wreck_screen.gd`).

Reach for this only at one action. At two, use `MenuNav.attach`.

### Developer-only pages

**Benchmark, Dev and Seed lab are hidden from players.** `_build_list_page` adds
those three category buttons only when `SettingsMenu.dev_tools_enabled()` — which
keys off `OS.is_debug_build()`, the same signal `car.gd` / `hud.gd` / `world.gd` /
`perf_log.gd` use, so an exported release build never shows them while the editor,
debug exports and the headless test runner do.

The pages are still **built**, and `show_benchmark()` / `show_dev()` /
`show_seedlab()` still work — only the way in is removed. That keeps `_pages`,
focus handling and the tests that drive those pages directly unchanged.
`dev_tools_override` (static, `-1` = real build type) exists so a test can assert
the player-facing case, which `OS.is_debug_build()` alone makes untestable.

**Reset progress is NOT one of them.** Wiping the save used to sit on the Dev page
and so was invisible in release builds; it is now its own **player** category
(`show_reset`, added to the list unconditionally) and the Dev page no longer offers
a second copy — one route to an irreversible action, guarded by a confirm modal
rather than by hiding. Dev builds simply see both categories.

## New-rally reveal (map table)

When rallies become enterable the player is **told**, rather than being left to notice
that a grey pin turned green. Opening the map table pans the camera to each new rally in
turn and flips its pin from the locked to the unlocked look.

- **Where.** `hq_table.gd._enter_table()`, before the usual `_focus_hardest_incomplete()`
  entry steer. There is no separate scene and no podium teaser — the map is the only
  place a reveal happens. The camera motion is the EXISTING map pan (`_pan_table_to` →
  `_move_camera_to`, `menu_camera_move_time`), not a second bespoke tween.
- **The queue** (`_pending_reveals()`) is derived **fresh on every map open from current
  state** — never hooked to rally completion. A rally is queued only when it is unlocked
  (`RallyLibrary.rally_revealed`), the player owns a car that can actually enter it
  (`_has_eligible_car` → `_entry_plan`, the same authoritative answer the green/grey pin
  flag uses), and it isn't already `Save.rally_revealed_seen`. That makes it a standing
  condition rather than an event, so it works for *any* unlock route: finishing a rally,
  buying a car, an engine swap that moves a car into a class, a cloud
  restore. A rally with no qualifying car is simply held back and appears later; nothing
  expires.
- **The sequence** (`_run_reveal_sequence`) builds the pending pins in their LOCKED look
  first (`_refresh_map_pins(hold_locked)`) so the flip is watchable, then per rally:
  pan → settle (`hq_reveal_pan_time`) → rebuild that pin unlocked, focus it, banner it
  ("NEW RALLY — <name>", or "SPECIAL EVENT UNLOCKED" and a doubled hold for a special)
  → hold (`hq_reveal_hold_time`). `hq_reveal_max_queue` caps one opening's parade (the
  dev "3-star everything" cheat opens the whole roster at once); the rest are banner'd as
  "+N more" and marked seen anyway. `_finish_reveals` marks every queued id seen, saves,
  and leaves selection on the **last revealed pin** — the player wants to look at the new
  thing, not be yanked back to `_focus_hardest_incomplete()`.
- **Controls are LOCKED for the parade (keyboard + gamepad + pointer).** `_revealing` is
  checked in the same three places `_detail_open` is: the `_process` glide,
  `_table_pan_input`, and the `View.TABLE` branch of `_unhandled_input` — plus
  `_on_pin_input`, so a pin can't be opened mid-parade. A press is **swallowed**
  (`set_input_as_handled`, so nothing underneath reacts) and otherwise does nothing.
  It used to SKIP the whole queue, and that was wrong: skipping ran `_finish_reveals`, which
  marks every queued rally seen, so one stray keypress permanently burned the
  "NEW RALLY - …" beat for up to `hq_reveal_max_queue` rallies — and the reveal is the only
  place the game announces a new rally. The parade is short (`hq_reveal_pan_time` +
  `hq_reveal_hold_time` each, a special holding double, capped at `hq_reveal_max_queue`), so
  it simply plays out. Guarded by
  `test_menu_flow.gd::test_a_press_during_the_reveal_cannot_cancel_it`. Leaving the map
  mid-parade (`go_to`) still banks the queue.
- **Persistence + backfill.** A per-rally `revealed` bool beside `completed`. The seeding
  itself lives entirely in `Save` (`Save._seed_reveals_if_needed`), run at the points a
  profile actually becomes live — `load_or_new` and `adopt_profile` — rather than as a
  call `hq.gd` has to remember to make at every scene/entry point that reaches the map or
  replaces the profile. Details (what it seeds, why the eligible-car clause is
  deliberately NOT part of it) are in [save-persistence.md](save-persistence.md).
- **Generation guard.** `_run_reveal_sequence` bumps `hq_table.gd::_reveal_token` and captures it as
  `token` before its first `await`; every abort check calls `_reveal_continue(token)`
  instead of a bare predicate. This stops a STALE coroutine — parked mid-`await` after a
  skip, then woken up next to a second sequence that started before it resumed — from
  going on to pan the camera / rebuild pins / `erase()` entries out of the new sequence's
  queue. `_reveal_active()` itself stays a pure predicate (see next point); `_reveal_continue`
  is what actually calls `_finish_reveals()` when the player left the map view mid-parade.
- **`_reveal_active()` is a pure predicate.** It used to also call `_finish_reveals()` (a
  disk save + pin rebuild) when the view had changed away from `TABLE` — a side effect
  hiding inside what read as a query. That abort step now lives in `_reveal_continue`,
  the only thing `_run_reveal_sequence` actually calls between its steps.
- **Headless.** `_enter_table` drains the queue instantly under `Platform.is_headless()`
  (marking everything seen, then opening the table normally focused) — the final state
  with none of the awaits, which would otherwise hang the suite. Skip the animation,
  never the decision.

## Text input (`text_field.gd`)

`TextField` is the project's **only** text input (there was none at all before
the account form — see [cloud-save.md](cloud-save.md)). A labelled `LineEdit`,
built in code like every other menu widget. Making typing coexist with a menu
driven by bare letter keys took four things:

- **`MenuNav._make_focusable` now walks `LineEdit` too**, not just `BaseButton`
  and `Slider` — otherwise a form is unreachable without a mouse.
- **Up/down leave the field, left/right stay caret movement.**
  `TextField.wire_column([...])` chains a form's controls explicitly (top and
  bottom do not wrap — wrapping reads as the cursor teleporting) rather than
  relying on Godot's automatic neighbour search.
- **WASD is safe by construction**: a focused `LineEdit` consumes printable keys
  in the GUI phase, before `_unhandled_input`. **Esc is not**, so
  `MenuNav._unhandled_input` turns Back-while-typing into "release the field"
  instead of "leave the page", and any host with its own `_unhandled_input`
  (`hq.gd`) stands down via the shared **`MenuNav.is_text_editing()`** static.
  One predicate, so those guards cannot drift apart.
- **Enter submits** (`submitted` signal) — on a phone the on-screen keyboard can
  cover the button, so this is sometimes the only way to submit at all.
  `virtual_keyboard_enabled` is on for Android/web.

Note that **Space is both `ui_accept` and a legal password character**; the
focused field consumes it first, so typing wins. That is correct, but it is the
thing to re-check by hand if the input map ever changes.

Covered by `tests/headless/test_text_field.gd`.

## Account page (`account_menu.gd`)

`AccountMenu` is the optional cloud-save UI — one builder with **two hosts**: a
category page inside Settings (`show_account`, the canonical route) and an inline
overlay on the standings page's sign-in prompt (`global_standings.gd`). It used to
have a third, a dedicated title-row Account button with its own modal layer; that was
removed as a duplicate of the Settings page (see [cloud-save.md](cloud-save.md)).
It exposes `at_root()` / `go_back()` so its
hosts treat its sub-forms exactly like Settings sub-pages —
`SettingsMenu.go_back()` gives it first refusal before backing out of the page.
See [cloud-save.md](cloud-save.md).

## ConfirmPopup (`confirm_popup.gd`)

A reusable on-brand confirm modal for blocking decisions — a full-screen **dim
mouse-consuming backdrop** (`MOUSE_FILTER_STOP`, swallows clicks) + **centred house
`UITheme.panel`** with a title, an autowrap body, and one button per action. Each action is
a dict `{ "label": String, "callback": Callable, "disabled": bool (optional) }`. When an
action's button is pressed, the popup dismisses and runs its callback; Back routes to the
configured action (default: the **first** one — dismiss/leave sits leftmost, see
"Button order" above).

**Contract:** `ConfirmPopup.open(host, title, body, actions, default_index := 0, back_index := -1, allow_stack := false) -> ConfirmPopup` — **returns `null` when refused; callers must not assume a popup came back.**

- `host` — parent Node to attach under (its process mode is inherited — a paused host's
  popup still processes).
- `title` / `body` — confirm header + message text.
- `actions` — Array of action dicts; disabled actions are greyed and unselectable.
- `default_index` — 0-based index to focus on open (defaults to 0, falls back to first
  enabled if the default is disabled).
- `back_index` — 0-based index of the action to fire on Back / cancel. **Defaults to the
  FIRST action**, because the house order puts the leaving/cancel action leftmost (it used
  to default to the last, which after that reorder pointed Esc at the *confirming* button —
  see the comment in `ConfirmPopup.open`). Pass an explicit index to override; a negative
  one is replaced by the default rather than dismissing silently.

The popup **builds its own CanvasLayer** under `host` (layer 101, above overlays), so it's
independent of the hosting scene. It's **MenuNav-wired** (keyboard + gamepad navigable),
emits `finished`, and **`queue_free`s on dismiss** — the host doesn't track it. **New
confirm dialogs should use `ConfirmPopup.open()` instead of Godot's native
`ConfirmationDialog`**, which is unstyled and not `MenuNav`-wired. Examples: the **pause
menu quit-to-HQ confirm** (`PauseMenu`), HQ **engine-swap confirms** (`hq.gd::_show_swap_confirm`, which is just two branches now
— capability locked, or go ahead — since a permitted swap costs nothing to spend), HQ **detune-to-enter confirm** (over-powered car), and the HQ **"Update available" prompt** on the native builds (`hq.gd::_check_for_update` — see [update-check.md](update-check.md)).

**Body scrolls, buttons stay pinned.** A ConfirmPopup has no touch dismissal other than its
own action buttons (`trigger_back` is reachable only from `ui_cancel`/`menu_back` — Escape
or gamepad B) and its dim backdrop swallows taps, so a long caller-supplied body (server
error text via `cloud_busy.gd::report_failure`, a computed multi-line reward via
`world.gd`) must never be able to push the buttons past reach. `_build` wraps the body
`Label` in a `TouchScrollContainer` (`scripts/touch_scroll_container.gd`, `horizontal_scroll_mode
= SCROLL_MODE_DISABLED`); the button row stays a sibling OUTSIDE the scroll so focus never
has to enter it. Because a `ScrollContainer` doesn't report its child's minimum size on an
axis it's allowed to scroll (that's what makes clipping work — vertical here defaults to
`AUTO`), an untouched scroll would collapse to ~0 tall and never hug a short body either.
So `_build` hands the sizing to **`UITheme.fit_body_scroll(scroll, body_label, wrap_width)`**
(see `features/ui-design-system.md` → "Sizing a scrolled body"), which gives the scroll the
body's true wrapped height and caps it against the viewport only as a fallback. **In practice
nothing scrolls**: these popups are fullscreen and their bodies are short, so the panel hugs
the text and all of it is visible. The panel width is likewise adaptive: `clampf(420.0,
200.0, viewport_width - 32.0)` instead of a bare `420` — on a narrow/portrait device
(`DisplayStretch`) the logical width can be well under 420.
`scripts/username_popup.gd` shares this exact shape and calls the same
`UITheme.fit_body_scroll` — keep the two in sync if this changes.

### One modal at a time (`ConfirmPopup.MODAL_GROUP`)

Every modal in the game is a `ConfirmPopup` or a `UsernamePopup`, both on layer 101,
and both join the scene-tree group **`"modal"`** when built. `ConfirmPopup.open` and
`UsernamePopup.open` refuse (return `null`, with a `push_warning`) when
`ConfirmPopup.any_open(tree)` reports one already on screen. `allow_stack := true`
opts out — used only by `CloudBusy.report_failure`, because a silently dropped
"couldn't sync" is how a failed resolution becomes invisible. There is deliberately
**no queue**: re-showing a modal the player has moved past invents an ordering nobody
asked for.

`any_open` skips nodes that are `is_queued_for_deletion()`. A dismissed popup emits
`finished` and *then* `queue_free`s, and a freed node stays in its groups until the
end of the frame — without the skip, a host that re-checks from its own `finished`
handler (`account_menu.rebuild` does exactly this) would be refused by the very popup
that just closed.

**The rule this encodes, worth generalising:** *a shared helper whose correctness
depends on "how many of these exist right now" must answer that from a scene-tree
group it owns — never from a per-host bool.* Centralising **what** a helper does while
leaving each caller to track **whether** it is already doing it is only half a
consolidation, and the half that is left behind is the half that drifts. This has now
been arrived at independently three times: `"loading_screen"` (queried by
`music_director.gd`), `CloudBusy.GROUP`, and this group. The bug that forced it: one
`Cloud.conflict_detected` broadcast reached two subscribers, each checking its own
private latch, so **both** opened a conflict prompt — dismissing the top one appeared
to "do nothing" except reveal a twin with the focus cursor reset. `hq.gd` and
`account_menu.gd` no longer keep modal latches at all; `account_menu` in particular
can be instantiated three times over (Settings, the HQ title overlay, the standings
page), so a per-instance bool could never have answered the question.

#### Commit AFTER you have the screen (`ConfirmPopup.open_committing`)

Because `open` can be **refused**, *an irreversible mutation must never run before the
presentation that reports it.* Doing it the other way round is a silent data loss:
the rule was learned the hard way by a since-deleted consumable flow that *consumed the
item, installed the part and saved* and only **then** opened the reveal — so a player
holding two of them spent both and saw one reveal, the second popup having been refused
behind the first. The mechanism is gone; the ordering rule it taught is not.

`ConfirmPopup.open_committing(host, title, placeholder, actions, commit, …)` inverts
the order so that state is unrepresentable: it **acquires the modal slot first**, and
runs `commit` only once the popup that will report the result is already on screen. If
the slot cannot be had it returns `null` and **`commit` is never called** — the caller
has mutated nothing and can just return.

The body is **deferred**, not a return value, because `world.gd`'s challenge reward has
to `await` its grant (`ChallengeSession.try_grant_completion_reward`) and a synchronous
`Callable -> String` contract cannot express that. So the popup is built with
`placeholder`; `commit` may be a plain function *or* a coroutine (its result is awaited
either way), and either returns a non-empty `String` to become the body or writes one
itself via `popup.set_body(...)` on the popup it is handed. `open_committing` is
therefore itself a coroutine — call it as `await ConfirmPopup.open_committing(...)`.
There is deliberately no `allow_stack` here: the refusal *is* the feature.

Covered by `test_confirm_popup.gd` — the commit does not run when a modal is already
up, does run (once) when the slot is free, a coroutine commit is awaited, `set_body`
fills the placeholder, and the popup it returns behaves like any other (buttons, Back,
dismissal).

#### `MenuNav.input_blocked(node)` — the one "am I deaf right now?" question

Every menu host needs to know whether to ignore menu input, for two reasons that used
to be asked separately (or not at all): the player is **typing**
(`MenuNav.is_text_editing`), and **a modal owns the screen** (`ConfirmPopup.any_open`).
`MenuNav.input_blocked(node)` folds both into one shared predicate, the same convention
`is_text_editing` established. `hq.gd`'s `_unhandled_input` had rolled its own version
that allowlisted its two overlays but not `ConfirmPopup`, so HQ station rows still fired
behind an open popup — which is exactly what made the double-open reachable.

**The carve-out: a node inside the open modal is NOT blocked.** The popup builds a
`MenuNav` of its own on its centring container (`ConfirmPopup._build`), and that nav has
to keep answering Back and directional nav — block it and the player is trapped in a
popup that no longer responds to anything. So the modal blocks everyone *except its own
subtree* (`node == modal or modal.is_ancestor_of(node)`), and the carve-out is tested
before the text-editing arm so a field inside a modal (`UsernamePopup`) keeps its own
typing rules.

`MenuNav._unhandled_input` applies the guard itself, so every MenuNav-driven page
(settings, upgrades, standings, account, the HQ overlays) goes inert behind a modal
rather than relying on tree ordering to mask it — tree ordering is not a rule, and it
never covered `menu_select` at all.

Covered by `test_menu_nav.gd` — blocked behind a modal, not blocked with nothing up,
blocked while typing, **not** blocked inside the open modal, a MenuNav page neither
moves its cursor nor fires Back behind a modal, and the modal's own nav still answers
Back.

Covered by `test_confirm_popup.gd` — joins the group, a second popup is refused, a
*different host* is refused, a popup being freed does not block its replacement,
`allow_stack` gets through, and the exclusivity holds in both directions between the
two popup kinds.

## Modal page shape — scrolled body, pinned exit (`hq.gd::_make_modal_overlay`)

**Every modal menu page must scroll its content and pin its exit control outside the
scroll.** `hq.gd::_make_modal_overlay(margin)` is the builder: it returns
`[layer, body, footer, root]` — `body` is a `VBoxContainer` inside a
`TouchScrollContainer` (`SIZE_EXPAND_FILL`), `footer` is an `HBoxContainer` pinned
below it as a sibling, and `root` is the outer full-rect VBox you hand to
`MenuNav.attach` / `UITheme.enforce`. Variable-height content goes in `body`; the
control that LEAVES the page (Back / Done / Close / "Continue") goes in `footer`.
`hq_carpark.gd::_make_carpark_modal(build_body, build_footer)` is the same contract for the
car-park's centred house panel. It is now a thin wrapper over `MenuPage`
(`{"dim": true, "margin": 16.0, "padding": 20}`) rather than a hand-rolled stack: `MenuPage`
gained a **`dim`** option for true modals like this one, and its `_sync_body_height` already
budgets the box against the frame height instead of centring it at its full minimum size —
which is what stops a tall body pushing the footer off screen. Note the footer callable is
handed an **`HBoxContainer`** (the page's action row, outside the box), not a `VBoxContainer`.

### Hosting a modal (`MenuPage.open_modal`) — not optional either

**A modal page never goes on a station's `CanvasLayer`.** `MenuPage.open_modal(host, opts)`
is the one way to put a full-screen page on screen; it owns three things callers kept getting
wrong, each with a silent failure mode:

1. **Its own `CanvasLayer`.** `WorldPanelHost.sync` migrates a station's UI tree into a 3D
   `WorldPanel` and sets `flat_layer.visible = false` whenever `world_space_menus` is on —
   which `game_config.tres` **ships on**. A page added to `_car_layer` was built, gated and
   nav-wired but rendered NOWHERE: "Change Upgrades" on the car park's "Too powerful" prompt
   looked like it dropped the player straight back to car-select.
2. **`MenuPage.MODAL_LAYER` (100) — above the station overlays, strictly below
   `ConfirmPopup`'s 101.** A modal page HOSTS confirms rather than being one. On a tie the confirm can be drawn *under* the page's
   opaque panel while its full-screen `MOUSE_FILTER_STOP` dim goes on swallowing clicks — an
   invisible confirm behind a menu that has gone dead.
3. **A screen claim via `MenuNav.SCREEN_CLAIMER_GROUP`.** `WorldPanel._input` projects clicks
   landing inside its 3D quad into the panel's `SubViewport` and marks them handled, standing
   down only for `MenuNav.input_blocked`. A page outside that predicate renders on top while
   the station underneath eats its clicks. It is deliberately NOT `ConfirmPopup.MODAL_GROUP`
   (see "One modal at a time") — that group *refuses* a second modal, and these pages must be
   allowed to open the confirms they host. Membership sits on the page, not its layer, so
   hiding the page releases the claim (hosts keep these pages alive and toggle `visible`).

`hq.gd::_make_modal_overlay` and `hq_carpark.gd::_make_carpark_modal` are both thin wrappers
over it now, so all three HQ modals (rally detail, challenge, Android notice) get the same
hosting. The **Android boot notice** additionally stands the title down through
`update_overlays` — `_title_layer.visible = false` only ever addressed the flat host, so
with world menus on it stood nothing down and left two live `MenuNav`s fighting one keypress.

**Why it isn't optional.** Overlays are laid out against a logical canvas whose HEIGHT is
fixed — `DisplayStretch.DESIGN_HEIGHT`, read from `project.godot`'s
`window/size/viewport_height` (currently 400) on every target — while the WIDTH follows the device aspect
(`DisplayStretch.logical_size`) and gets narrow on a phone, which makes autowrapped
labels wrap to more lines. So a fixed, unscrolled column whose Back button is laid out
AFTER the content does not overflow by device roulette: with a long restriction string or
a server error string spliced in, the exit is *deterministically* pushed off the bottom.
And there is no second way out — `menu_back` binds Escape and gamepad B only
(`project.godot`), so there is NO touch-reachable back and the player is simply trapped
in the page. Pinning makes that unreachable-by-construction.

**Focus still crosses into the footer.** Footer controls are `FOCUS_ALL`; `MenuNav` moves
focus across container boundaries by geometry, so down-nav off the last body row lands on
the footer, and `MenuNav._enable_scroll_follow` sets `follow_focus = true` on every
`ScrollContainer` under the attached root so walking back up scrolls the body to reveal
the row the cursor moved onto. `build_settings_overlay` (title → scroll → `< Back`
sibling) and `build_lift_overlay` are the reference implementations.

**The passthrough carve-out.** This is for MODAL pages only. The diegetic 3D stations —
garage, map table, car park (`build_garage_overlay`, `build_table_overlay`,
`build_car_overlay`) — call `hq.gd::_passthrough_overlay`, which sets
`MOUSE_FILTER_IGNORE` on the overlay root and its non-button children so taps fall through
to the `Area3D` pickers behind the HUD. A `ScrollContainer` defaults to
`MOUSE_FILTER_STOP` and would eat those picks (and its drag gesture would fight the map
pan). Plain `_make_overlay` stays as-is for those; **never** wrap a passthrough overlay in
`_make_modal_overlay`.

Pages on this shape: the rally detail card (`build_detail_overlay` — its `< Map` stays
`FOCUS_NONE` because the panel has no MenuNav; `hq._unhandled_input` drives it from the
TABLE view), the challenge entry screen (`build_challenge_overlay`), Settings
(`build_settings_overlay`), the Android
app notice (`hq._show_android_app_notice`), and the car-park Change-Upgrades popup
(`hq_carpark.gd::_show_upgrades_popup`, whose Done is additionally p/w-gated).

**Widths, not just heights.** A centred modal column asking for a fixed pixel width can
also exceed the frame: a narrow/portrait phone aspect can leave well under 445 logical units wide.
`hq.gd::_modal_body_width(preferred, chrome)` clamps an authored desktop width to what the
current canvas can actually show (`viewport width - chrome`, floored at 160); the upgrades
popup and the account menu both go through it.

## HQ (`hq.gd`)

The boot scene (`project.godot` `run/main_scene`), a lightweight **`Node3D`** (no
track generation). A first-time player (no `starter_picked`) is **not** auto-granted
a car: pressing **Start** on the title routes them into the car park's
**starter picker** (`_enter_starter_pick`, `_carpark_starter_mode`) showing the three
authored-body cars (Miot Roadster, Fjord Focal, Rondel Twist) as preview cars from `CarLibrary`; choosing one
(`_confirm_starter`) grants it as a normal first car, records
`starter_picked` / `starter_model_id` / the selection, and enters the garage. Back
returns to the title. Returning players skip the picker and Start goes straight to
the garage. The picker reuses the car park's keyboard/gamepad nav (`_cars_input`:
left/right/select/back). Building the HQ (the ground — grass with the tarmac apron
feathered into it via the shared road-blend mesh, `MeshUtil.feathered_ground_mesh`,
the same treatment as the track verges and podium pads — buildings, the tree ring plus an
interleaved bush ring and three static spectator crowds — pure scenery, no steering
(`HQEnvironment._build_bushes` / `_build_spectators`) — the garage, the parked
lineup) is synchronous and takes a beat, so on a real display
`_ready` shows a **`LoadingScreen` cover** the moment the scene starts, builds behind
it (`_build_hq`), then reveals — bridging the gap after Godot's boot bar so the load
never looks frozen. Under the headless test runner it builds synchronously with no
cover (so tests see a ready HQ after one frame). HQ is **one diegetic 3D space** the camera flies through; an
`enum View { EXTERIOR, GARAGE, TABLE, LIFT, CARPARK, SETTINGS }` names the camera **stations** and
`go_to(view)` tweens the single `Camera3D` between their poses
(`GameConfig.hq_*_cam_eye/look`, eased over `menu_camera_move_time`). Clickable 3D
objects (the table, the lift, the rally pins) are `Area3D` with `input_ray_pickable`
(`get_viewport().physics_object_picking` is on); their handlers also respond to
`menu_*` keyboard/gamepad input. The **static 3D world** — everything that never
changes once built — is split into **`HQEnvironment`** (`scripts/hq_environment.gd`),
a small `RefCounted` collaborator `hq.gd._build_hq` drives via `_env.build(self,
_on_table_input, _on_lift_input)`: it parents all the geometry to the HQ node (so the
scene tree is unchanged), wires the pickable table/lift areas back to hq's own click
handlers, and hands back the `camera` / `map_table` / `pins_root` handles hq keeps
driving (the dynamic props — the parked-car lineup, the lift car, the map pins — stay
in `hq.gd`). Its pieces: a block-building skyline **behind the garage**
(`_build_buildings`, kept clear of the title camera's view), low-poly mesh **trees**
framing the lot (`_build_trees`, reusing the stage's `TreeMeshField` via
`MeshUtil.first_mesh`), the garage shell, the lift — built from `BoxMesh`
blocks via `_block()` (placeholder art; the framing/positions that the flow depends
on are in `GameConfig`). The **map table** is the exception: `_build_map_table`
instantiates a proper `MapTable` model (`scripts/map_table.gd`) — a wooden tabletop
on four legs, with a skirt apron under the top edge and low stretcher rails, all
wearing a procedurally-generated wood-grain texture. Its origin is the floor centre
and its top surface stays at `hq_table_size.y`, so the satellite map plane and the
rally pins still align. The model is standalone-renderable for visual iteration via
`tools/render_map_table.sh` (→ `docs/map_table/*.png`). The ground is a **grass-textured field** (the run scene's
`textures/grass.jpg`, tiled by `terrain_tile_per_meter`) with a **grey concrete
apron** laid on top around the garage + car park (`hq_concrete_center`/`hq_concrete_size`),
so the lot reads as paved and everything beyond it as field. The car park itself is a
**painted parking-bay surface** (`_build_carpark`): a tarmac plane over the apron with
white bay dividers (one bay per `carpark_page_size`, `menu_car_spacing` wide) generated
procedurally as an `ImageTexture` (`_carpark_bay_texture`), so each parked car sits in
its own marked bay.

**EXTERIOR (boot/title).** A side-by-side row of **Start / Settings / Free Roam** and —
on non-web builds only — **Exit Game** (`_on_exterior_exit` → `get_tree().quit()`;
skipped on web, where the tab owns the process lifecycle), sitting at the bottom (in
that left-to-right order) over an establishing shot of the
outdoor car park, with a block skyline **behind the garage** and trees framing the
lot. The player's **whole owned collection** is parked in the car park here
(`_build_title_lineup`, rebuilt on entering EXTERIOR) so the title shows off every
car. Because `_render_lineup_page`'s per-car build is progressive (one fresh prop per
frame — below), and `_build_hq` never awaits it, `hq.gd::_ready` explicitly `await
lineup_built` after `_build_hq()` (EXTERIOR boot only, before `loading.finish()`):
without that await, `_build_hq()`'s call returns the instant the first uncached owned
car yields a frame, so the rest of that page's fresh spawns — bounded to
`carpark_page_size`, but still the expensive `CarProp.spawn` per car (below) — would
trickle out **after** the loading cover lifts, landing as the "big lag spike right
after the game first loads" for a player with several owned cars. Awaiting
`lineup_built` keeps that whole page's worth of cold-instantiate cost **behind the
cover**, where a brief wait reads as loading rather than gameplay jank, and it warms
`_car_cache` for every parked car so the car park and tuning lift (above) start
from a hit, not a cold build.

**The map table is likewise split out** into **`HqTable`** (`scripts/hq_table.gd`), held as
`_table_ui`: entering the table, the new-rally reveal sequence, pin focus / panning / target
selection, and the rally detail panel — 25 functions.

Three things stayed on `HqController` and are worth knowing about, because they sat *inside*
the moved region: **`_process`** (an engine callback — Godot would never fire it on a
`RefCounted`, so the table pan and reveal animation would silently stop advancing), and
**`_eligibility_summary` / `_qualifying_cars_text`**, which `hq_challenge.gd` also calls. They
now live directly below the table code under a banner saying so.

**The Rally Challenge screen is likewise split out** into **`HqChallenge`**
(`scripts/hq_challenge.gd`), held by `hq.gd` as `_challenge_ui` and built alongside `_overlays`
in `_build_hq`. It owns the 18 `*_challenge_*` functions — building and refreshing the
Daily/Weekly/Monthly overlay, fetching its leaderboard placing and cutoff, and the entry path
into a challenge stage.

The cut started **functions-only**, then followed up by moving the state each collaborator is
the SOLE user of — see "Where a field lives" below. The two player-facing text constants moved
with the functions and are reached statically as `HqChallenge._CHALLENGE_WIN_CONDITION` /
`._CHALLENGE_REWARD_TEXT`. See [../todo/hq-split.md](../todo/hq-split.md).

**The car park is likewise split out** into **`HqCarpark`** (`scripts/hq_carpark.gd`), held as
`_carpark_ui`: the eligible-lineup build, the parked-car prop cache and its Free-Roam prewarm,
focus cycling, the swap/damage readouts and the carpark modals — 35 functions, the largest of
the three cuts.

Two things stayed on `HqController` here for reasons the parser will not tell you about. The
`lineup_built` **signal** is declared on the node, so `HqCarpark` emits it as
`_hq.emit_signal("lineup_built")` — a `RefCounted` has no such signal. And anywhere the old
code passed `self` as a parent or host `Node` (`CarProp.spawn`, `ConfirmPopup.open`) it now
passes `_hq`; `self` would compile fine and fail only when the line ran. The boot-instrumentation
helpers (`_log_boot_cost` and friends, driven from `_ready`) and the shared `_car_stats_text` /
`_restriction_text` also stayed, below the carpark code under a banner saying so.

### Where a field lives: ONE user means it is not shared state

The rule the cuts settled on. A field belongs to a collaborator when **exactly one**
collaborator reads or writes it and `hq.gd` itself never does; it stays on `HqController` when
two or more touch it. That second case is common and not a failure — `hq_overlays.gd` BUILDS
most of the widgets that `hq_table.gd` / `hq_challenge.gd` then read, so a widget handle
genuinely has two owners.

The tell for a field on the wrong side is `@warning_ignore("unused_private_class_variable")` on
`hq.gd`: the analyzer sees one file at a time, so a field only a collaborator touches reads as
dead there, and the tag was suppressing that. Nineteen such fields have moved to their single
user — the reveal parade's queue/token (`HqTable`), the Change-Upgrades popup handles, the
lineup settle generation, the focus-rev audio player and the prewarm stow marker (`HqCarpark`),
the challenge refresh generation and its two per-period board caches (`HqChallenge`), and the
title row's Free Roam / Settings / Exit buttons, the build watermark and the dev-win button
(`HqOverlays`). The tags that remain name genuinely shared state. **Don't add a new
`@warning_ignore` to `hq.gd` for a field one collaborator owns — put the field there instead.**

`hq.gd` grew a small **public** API for what collaborators legitimately need back from the
controller, so those calls stop reading as private reach-through: **`view()`** (which station is
live), **`go_to(view_id, snap)`**, **`update_overlays()`**, and the widget factories
**`label()`**, **`detail_heading()`**, **`detail_wrap_label()`**, **`challenge_info_row()`**.
The rest of the traffic is still `_hq._field` state access, deliberately: converting it all
would be churn without a boundary, and the fields above are where the boundary actually was.

### Input: one branch per station, and each cluster owns its own

`hq.gd::_unhandled_input` is a **dispatch**, not a switchboard. It still owns the things that
apply to every station in order — the `MenuNav.is_text_editing()` bail, the debug F7 world-menu
A/B and F8 config reload, and the `ConfirmPopup.any_open()` modal bail — and then hands the
event on:

```
if _challenge_ui.handle_input(event):   # the challenge modal owns the screen: stations stand down
    return
match _view:
    View.EXTERIOR: _exterior_input(event)
    View.SETTINGS: _settings_input(event)
    View.GARAGE:   _garage_input(event)
    View.LIFT:     _lift_input(event)
    View.TABLE:    _table_ui.handle_input(event)
    View.CARPARK:  _carpark_ui.handle_input(event)
```

Every handler returns **whether it consumed the event**. Nothing chains off the answer after
the `match` — `_unhandled_input` is the last stop, and the one handler that must really mark the
viewport handled (the reveal parade's press swallow, now `hq_table.gd::_is_any_press`) does that
itself — but the contract is what lets `HqChallenge.handle_input` stand every station down by
answering `true` instead of `hq.gd` reading `_challenge_shown` by hand. The four stations whose
handlers stayed on `HqController` (title, settings, garage, lift) have no collaborator of their
own; their widgets are built by `HqOverlays` but their focus cursors and transitions are
`hq.gd`'s.

**No binding moved.** The keyboard/gamepad map is unchanged: EXTERIOR left/right/select, GARAGE
left/right/select/back, LIFT hub up/down/left/right/select/back (sub-page: back), TABLE
select/back plus `dev_complete_rally` and pointer pan, CARPARK left/right/select/back plus
up/down in the wheel view. `test_menu_nav.gd`, `test_menu_flow.gd` and `test_world_panel.gd`
guard it.

**A car that fails to spawn must never hang boot forever (regression, fixed).**
`_spawn_lineup_progressive` (`hq_carpark.gd`) loops `_obtain_parked_car` → `_spawn_parked_car`
→ `CarProp.spawn` (`car_prop.gd`) for each car on the page; if the underlying model
scene fails to instantiate (e.g. a texture dependency the export stripped — see the
`export_presets.cfg` note below), `CarProp.spawn`'s `scene.instantiate()` itself
returns null, and that null propagates all the way up. Each GDScript runtime error
along the way (`use_isolated_config` on null, `set_meta` on null) aborts only the
**current function's** execution and returns to its caller — so the null bubbles up
one frame at a time until it reaches `_spawn_lineup_progressive`'s own
`car.get_meta("lineup_fresh", false)` check. Erroring there aborted
`_spawn_lineup_progressive` itself **permanently**, before the `for` loop could reach
its later cars or the trailing `emit_signal("lineup_built")` — so `_ready`'s
`await lineup_built` (above) never resolved and the `LoadingScreen` cover stayed up
forever, even though the scene underneath had already finished building and was
rendering at a steady frame rate (confirmed via `adb logcat` on a real device: the
`[perf]` counter kept ticking at 60fps behind the stuck "Preparing the garage…" cover).
The fix is a plain `if car == null: push_warning(...); continue` right before that
`get_meta` call — a single bad car is now skipped and logged, and the rest of the page
(and `lineup_built`) still complete normally. See
`tests/headless/test_lineup_cache.gd::test_a_car_that_fails_to_spawn_is_skipped_not_hung`
and the test double `tests/headless/carpark_null_spawn_double.gd`, which subclasses
`HqCarpark` and is installed over `hq._carpark_ui`.

The title camera is a **low, near-ground front-3/4 hero shot** posed ~45° off
the front of the **first (leftmost) parked car**, looking diagonally down the line
to reveal the rest of the lineup. Its `hq_exterior_cam_eye`/`_look` (GameConfig) are
**offsets from that lead car** (`_station_xform` → `_first_car_anchor`), so the framing
**tracks the first car** as the centred lineup grows and its leftmost car slides toward
−X with more cars owned — it's not a fixed world pose. The **build version** (`v0.<n> (<sha>)`) is shown in the bottom-right corner
here only — not on the in-run HUD (see [hud.md](hud.md) → Build version). The title row
is **no longer a native-focus list** — it's the same diegetic **`ButtonCursor`** idiom
the garage row and lift hub use: `FOCUS_NONE` buttons (`_station_button`) over a single
left/right cursor (`_title_cursor`/`_title_focus`), painted by `UITheme.mark_focused`
and driven by `menu_left`/`menu_right`/`menu_select` in the EXTERIOR branch of
`_unhandled_input` (mirroring the GARAGE branch exactly). The cursor re-seats on **Start**
(index 0) every time `go_to(View.EXTERIOR)` runs. Start (`_on_exterior_start`) flies the
camera into the garage; **Free Roam** (`_enter_free_roam`, `CarparkMode.FREEROAM`) opens
the whole-catalogue car park for a session-less drive — it lives here rather than in the
garage because it needs no owned car, no session and no lift, so reaching it through the
garage was a detour through state it doesn't use, and backing out of its picker returns
to this screen (`CarparkMode.FREEROAM` in `_carpark_back`);
**Settings** (`_open_settings(false)`) opens the shared camera/controls page — it moved
here from the garage action row (see the GARAGE section above), and because it now only
ever opens from the title, backing out of it (`_on_settings_action`) always returns to
EXTERIOR, never the garage; **Exit Game** (`_on_exterior_exit` → `get_tree().quit()`)
quits the app — it's built only on non-web builds, since a browser tab owns its own
lifecycle.

**Account is deliberately NOT on this row.** It used to sit next to Start, but it is
also a **Settings page** (`settings_menu.gd::show_account`), and two routes to one
optional-cloud-save form is one more than the screen needs — Free Roam took the slot.
The reinstall/new-device case it existed for is still served: Settings is right there on
the same row, before any career is started.

**SETTINGS.** A flat overlay over the exterior shot (no dedicated camera pose)
hosting the **shared `SettingsMenu`** (`scripts/settings_menu.gd`, `class_name
SettingsMenu`) — the SAME component the in-run pause menu uses, so the two pages
match. It opens on a **category list** — one button per area, laid out in a
**2-column grid** so the list stays short instead of overflowing into a scroll —
and each button drills into **its own sub-page**:

- **Display** — pick the **frame-rate cap**: **30 / 60 / uncapped**
  (`FpsSetting.OPTIONS`, `scripts/fps_setting.gd`). The choice persists under
  `FpsSetting.SETTING_KEY` (`"fps_cap"`) and applies **live** — `select_fps` writes
  `Engine.max_fps` directly (the frame cap is a global engine property, so no
  live-scene signal is needed; both hosts take effect immediately), and
  `world._ready()` re-derives it next run. Defaults to the platform's natural cap when
  unset (web-touch 30, else 60, via `FpsSetting.default_cap()`); the default option
  reads as selected. See [rendering.md](rendering.md) → frame cap.
- **Camera** — pick the **camera angle** (chase / bonnet, from `CameraManager.MODES`);
  the choice persists under `CameraManager.SETTING_KEY` and is applied on the next run
  (or live, in the pause menu, via the `camera_changed` signal). See
  [camera.md](camera.md).
- **Key bindings** — **rebind** the keyboard and controller controls. One row per
  driving action (`InputRemap.ACTIONS`) with a keyboard button and a controller
  button showing the current binding; tap one and press the new key / gamepad input
  to reassign it (Esc cancels), plus a **Reset to defaults** row. The model is the
  `InputRemap` autoload (`scripts/input_remap.gd`), which patches the global InputMap
  from overrides saved under `InputRemap.SETTING_KEY`. See [controls.md](controls.md).
- **Mobile controls** — pick the **touch control scheme**. Each of the six schemes
  ([mobile-controls.md](mobile-controls.md)) is a tappable row with a vector
  **diagram** of its layout (`ControlSchemeDiagram`, `scripts/control_scheme_diagram.gd`),
  its name and how-to. The choice persists under `MobileControls.SETTING_KEY` and is
  applied on the next run (or **live**, in the pause menu, via the `scheme_changed`
  signal — the on-screen controls rebuild the instant you pick a scheme).
- **Benchmark** — configure and launch the **in-game performance benchmark**
  ([benchmark.md](benchmark.md)): one ON/OFF row per `Benchmark.TOGGLES` entry
  (vegetation, spectators, render distance, uncap FPS, …) and a **Start benchmark**
  row that hands off to the `Benchmark` autoload (config overrides + run-scene
  load). Toggle states are session-scoped, not saved.
- **Reset progress** — the player-facing **start over**, shown to EVERYONE (it is
  deliberately not gated on `dev_tools_enabled()` — wiping your own save is
  something any player is allowed to do, and hiding it would leave no way to do
  it). One **Wipe all progress** button, a standing warning line above it, and a
  `ConfirmPopup` in between: `_prompt_wipe_progress` raises the modal (Cancel
  leftmost = default focus AND the Back target, "Wipe everything" right, per
  "Button order" below) and only its confirming action calls `_wipe_progress`,
  which runs `Save.reset_new_game()` (back to a fresh new game) and, when signed
  in, `Cloud.publish_local_wipe()` so the cloud copy is cleared too — otherwise
  the next pull restores everything and the wipe undoes itself; see
  [cloud-save.md](cloud-save.md). The status line reports the outcome, including a
  failed cloud clear ("it may come back"). `_wipe_progress` stays the plain "do it"
  entry point (what the tests drive); asking is the prompt's job.
- **Dev** — a debug page: **3-star all rallies** (`Save.dev_three_star_all_rallies`, unlocks
  every region), **Add 1 star** (`Save.award_stars(1)` — the same entry point the Rally
  Challenge banks through, rather than poking `stars_earned` directly, so the shortcut can
  never drift from how stars are really credited; the status line quotes the new spendable
  balance). One star at a time is deliberate: it lets you sit exactly on a price boundary and
  check the present box's affordable / unaffordable / free states — see
  `features/star-economy.md`. Plus one button per car (`Save.grant_car`, from
  `CarLibrary.CARS`) and per upgrade (from `UpgradeLibrary.UPGRADES`) to unlock anything in
  the game.
  **Complete rally (win now)** appears ONLY while a rally is active (i.e. from the
  in-run pause menu, gated on `RallySession.is_active()`): it unfreezes the tree and
  calls `RallySession.dev_complete_rally`, which credits every event a perfect 0 ms
  time, resolves to a P1 (top-3) finish, and routes straight to the podium — so the
  player banks the stars (and sees the stars beat) without driving the stages. Note it no
  longer yields a CAR: no rally pays one, and cars are bought at the present box.
  Upgrades are car-bound, so a slottable part **fits straight onto the selected car**
  (`Save.install_upgrade` — no-op with a "own a car first" note when nothing's owned);
  a consumable would instead go to the inventory (`Save.add_item`) — a path that still
  works but has no occupants, since `UpgradeLibrary` ships no consumable entries today.
  A status line reports the last action.

Navigation lives inside the component: `show_list()` / `show_camera()` /
`show_schemes()` / `show_benchmark()` / `show_dev()` swap which page is visible (only the visible page contributes
height, so the long schemes page scrolls while the short list/camera pages don't),
and `page_changed(is_root)` lets the host steer its single bottom button — on a
sub-page it reads **< Back** (returns to the list); on the list it is the host's own
action. The saved choice in each section is highlighted and persisted via
`Save.set_setting`. Settings is also shown as a **pre-rally gate**: on mobile, if no
scheme has been chosen yet, Start opens this page (`_open_settings(true)`) instead of
launching — jumping **straight to the Mobile controls page** (skipping the category
list) so the player only picks a touch layout. The bottom button reads **Start >**
and confirms the pick (the highlighted default if untouched), saving it so the gate
never reappears, then begins the rally; pressing back cancels the gate to the car park.

All the scrollable menu lists (Settings, the tuning lift, the standings/podium
leaderboards) use **`TouchScrollContainer`** (`scripts/touch_scroll_container.gd`)
in place of a plain `ScrollContainer`: it drag-scrolls under touch even when the
finger lands **on a list-item button** (a plain `ScrollContainer`'s touch-scroll is
swallowed by the pressed child). It watches raw input in `_input` (before the GUI
pass) — a press arms a gesture, vertical motion past a small deadzone becomes a
scroll, a press that never moves passes through as a normal tap, and only the
release that ended a real drag is swallowed so the row under the finger doesn't also
fire. Scrolling is driven from the emulated mouse events (`emulate_mouse_from_touch`,
the same path the map-table pan uses).

**GARAGE.** A block garage interior holding the **map table** and the **tuning
lift**, with the player's **selected car sitting on the lift** (`_ensure_lift_car`,
spawned whenever the camera is inside — garage/lift — and dropped otherwise). The
**map table is the one exception**: `go_to(View.TABLE)` deliberately KEEPS the lift
car rather than clearing it. The table never shows the lift, but tearing the prop
down landed in the very frame the camera starts its flight to the table, which is
exactly where a hitch is most visible; the car is frozen with process disabled, so
leaving it standing costs nothing and the player is one Back away from wanting it
again. Every other station still clears it, which is what matters — the car park and
title lineup BORROW that node out of `_car_cache` (below), so the lift has to hand it
back before those build. Like the
car park, the lift prop is **reused only while both its instance id and a deep
`owned.hash()` match** — so any in-place data change to the selected car (repair, upgrade
toggle, engine swap, tuning) auto-respawns the prop; no mutator has to force a rebuild.

The lift and the car park **share the same `_car_cache`** (`hq.gd` → `_spawn_lift_car`
checks `_car_cache` before building, exactly like `_obtain_parked_car`): a car already
warmed by the parked lineup — the title screen, an engine-swap pick, or
Free Roam — is *borrowed* onto the lift by reconfiguring its transform/process-mode
rather than paying `CarProp.spawn` again (the expensive step: `car.tscn` embeds every
car glb, so instantiating it — even to immediately prune 8 unused bodies — is the "small
lag every time the tuning-lift car changes"). `_clear_lift_car` returns the favour: if
the departing lift car is the node `_car_cache` tracks for it, it's hidden + stowed
(same pattern as `_release_page_props`), never freed, so the next parked-lineup build or
lift visit reuses it. GARAGE/LIFT and CARPARK are mutually exclusive views, so handing
the one live node back and forth between the two contexts is safe — but it means
`_ensure_lift_car`'s id/hash "already there, no-op" fast path must also check
`_lift_car.visible`: a car-park mode that returns to the lift (engine-swap, wheels)
borrows the lift's node into its parked lineup and then hides + stows that lineup
(`_clear_lineup`) on the way back — so returning with the SAME car used to hit the id/hash
match while the shared node was still stowed off-screen, vanishing from the lift instead of
staying shown. Requiring `.visible` too forces the fall-through spawn path, whose cache hit
just repositions the node back onto the lift. (This bit the retired GARAGE-mode picker
first, which is where the guard came from.) See
[tuning.md](tuning.md) → *The tuning lift (UI)*. In the
garage the car rests **lowered on the ground** at its calculated settled ride height
(`car.gd` → `settled_ride_height`; see [tuning.md](tuning.md)).
Tapping the table drops to the map view; tapping the lift flies to the **tuning bay**
(LIFT view) for the currently-selected car. A HUD hint + Back (to the exterior) +
convenience buttons sit on top: the garage station row is **Back / Career / Garage /
Online** — four fixed stops, so the left/right focus chain never changes length.
**Garage** (`_enter_lift`) drops straight into the **tuning bay**
for the selected car — the car is changed there, on the lift (see below). **Free
Roam** (`_enter_free_roam`) — reached from the **title screen**, not here — opens the car
park across the WHOLE catalogue for a session-less drive in any car (owned or not). Because `car.tscn` embeds **all** the
authored car glb bodies (it reveals one and hides the rest — `car.gd` →
`_apply_model_visibility`), every parked prop is heavy to build, and Free Roam builds the
whole catalogue at once. Two mitigations keep the click from hitching: (1) each frozen
display prop **prunes the bodies it will never show** before duplicating meshes
(`car.gd` → `prune_inactive_bodies`, called from `CarProp.spawn`), and (2) the whole
catalogue is **pre-warmed once just after HQ boot** (`hq.gd` → `_ready` starts
`_prewarm_free_roam_deferred` *after* the `LoadingScreen` lifts, spawning **one prop per
frame**), each preview becoming a hidden cached prop **kept in memory** for the session —
preview entries use negative instance ids and are **exempt from
`_evict_unowned_cached_cars`**, so opening Free Roam is a cache hit, never a build. It used
to run synchronously behind the cover, but measured ~3x the entire rest of HQ boot
(see [debug-tools.md](debug-tools.md) → "HQ boot cost logging"), and HQ is
`run/main_scene` — so the warm now happens off the boot critical path while the player
looks at the title shot.

**It also only spawns while the player is STILL** (`hq_carpark._await_prewarm_window` asks
`hq._prewarm_should_wait` before every car). Each spawn is one indivisible `car.tscn`
instantiate — a ~100 ms frame on a slow device — so what decides whether it reads as a hitch
is not *when* it runs but *what the player is doing* while it lands: nothing, on a static
title shot; everything, mid-navigation. "Busy" is a reveal parade, a camera glide in flight,
a menu direction held, or any input inside `PREWARM_IDLE_MS`, and input is stamped in
`hq._input` (not `_unhandled_input` — a click on a garage button is exactly the interaction
to stay out of the way of, and those never reach the unhandled pass). A boot that does NOT
land on the title stamps its own arrival as interaction, because such a boot is a RETURN
(the podium's Continue, a quit back to HQ) and the player is heading somewhere within the
second. `PREWARM_MAX_STALL_MS` caps the waiting so a player who never sits still still ends
up with a warm catalogue rather than a permanently half-warm one.
If the player opens Free Roam *before* it finishes, nothing is
lost: `_obtain_parked_car` reuses whatever is warm and builds the remainder on the spot
(the old first-entry cost, for that remainder only), and the deferred loop skips those on
its next frame. (The underlying cost is that each car still *instantiates* all
embedded bodies before pruning; a deeper fix — lazy per-model body loading in `car.tscn` —
is noted but not yet done.) Settings no longer lives on this row — it's on the title
screen now (see the EXTERIOR section above).

**LIFT (the tuning bay).** Entering the bay **raises the car on the lift** — a slow
tween from the lowered (garage) pose up to `hq_lift_car_height` over
`hq_lift_raise_time` (`_apply_lift_height`); returning to the garage lowers it again.
The car is framed to one side (`hq_lift_cam_*`) as a **front three-quarter** shot — the eye
sits ~35° off the car's nose axis (it noses −Z, so the eye is round at −Z, in FRONT of it),
close enough to show face and near flank together, and on the −X side because +X leaves only
~0.7 m to the garage's side wall. The front is the readable end of a car (grille, lights,
stance) and the bay is where you pick one, so that's the end the shot leads with; it used to
be the mirrored **rear** three-quarter. See the export's doc comment in `game_config.gd` for
the full framing reasoning.

The bay opens on a **HUB page**
(`LiftPage.HUB`): a **bottom-left** readout of TWO equal-height boxed rows
(`_lift_info_panel`, a `VBoxContainer`) — row 1 the **car selector**
`[ < ] [ CAR NAME ] [ > ]` (`_lift_prev_button` / a boxed `_lift_car_label` /
`_lift_next_button`), row 2 the car's **stats line** (`_lift_car_stats_label`) — and UNDER
it the actions row: **< Back / Upgrades / Tuning / Test Drive**. (It was one panel holding a
single "name\nstats" label.) Both boxes wear `UITheme.readout_box()` with
`custom_minimum_size.y = UITheme.MENU_ROW_H` so a passive readout matches the buttons beside
it in height and shade — see [ui-design-system.md](ui-design-system.md). The two rows are
the hub's two cursor rows (see *Menu navigation* above).

To put a **different** car on the lift you stay in the bay: `< ` / `>` fire
`_cycle_lift_car(±1)` (the same callable the cursor activates), which sets the **selected
car** (`Save.set_selected_car`) and respawns the prop + refreshes the whole page. They walk
`_lift_cycle_order()` — the owned cars sorted by **ascending `instance_id`** (acquisition
order, which is stable). That is deliberately **not** `profile["cars"]` order:
`Save.set_selected_car` promotes the selected car to the FRONT of that array, so cycling by
list position would renumber the list on every press and ping-pong between two cars instead
of touring the collection. A wrecked car is cyclable too (it can sit on the lift). With only
**one** car owned there is nothing to cycle to, so `_refresh_lift_car_label` sets both
chevrons `visible = false` **and** `disabled = true` — hidden so the row reads as a plain
nameplate, disabled because `ButtonCursor` skips disabled stops but knows nothing of
visibility — and forces `_lift_row` back to `ACTIONS`; `_move_lift_row` is then a no-op
toward the empty selector row (`_selector_has_stops`). **Test
Drive** (`_test_drive`) launches free roam with the car already on the lift — no picker,
delegating to `_start_free_roam`. Each menu button opens that menu as its **own page** — a
`MenuPage` (`scripts/menu_page.gd`) whose solid body box is **centred on both axes and sized
to its contents**, not to a fraction of the screen; the car-description panel **hides** while
a sub-menu is open so the page has room. Every sub-page ends in ONE
centred horizontal **bottom action row** (`_lift_page_actions`, gapped off the body above):
**< Back** leads it (`_lift_back_button` → the hub; the hub's own Back returns to the garage),
and the TUNE page's own actions — `TuningPanel.action_buttons()`, i.e. **Reset to neutral**
and **Wheels** (`_tune_action_buttons`) — follow it. `_refresh_lift_ui` shows those only while
`_lift_page == LiftPage.TUNE`, set **after** `_tune_panel.setup` (which reasserts the Wheels
button's own visibility every refresh). The row lives inside `_lift_menu_bg`, so it hides with
the rest of the page on the HUB and needs no gating of its own. See
[ui-design-system.md](ui-design-system.md) → *A page's actions go in ONE bottom row*. Because
the hub controls and page chrome live on the hub, each menu page gets the **full panel height
to itself** and doesn't need to scroll. The two pages:

### Upgrades / Tune panel width

**The panel takes its width from its widest ROW, not from a configured fraction.** The lift
sub-pages are built as a `MenuPage` with no `set_body_width` call
(`hq_overlays.gd` → `build_lift_overlay`), so the body box hugs its contents; the only bound
is the page margin, plus the box's `clip_contents` as a last resort. There is no
width-fraction knob any more — a `hq_lift_menu_centered_width_frac` config field drove this
before the `MenuPage` migration and has been removed.

What still matters is **what the rows are measured against**, because it is the thing everyone
gets wrong: the space available is the **logical UI canvas**, which `scripts/display_stretch.gd`
lays out at `DisplayStretch.DESIGN_HEIGHT * window_aspect / Config.data.horizontal_stretch`
(a real per-instance `content_scale_size`, not the raw window). `horizontal_stretch`
(authored ~1.2) is a purely visual anamorphic widening applied via the stretch system, and it
SHRINKS the canvas UI actually lays out against — any measurement that skips the
`/ horizontal_stretch` step overstates available space by that same factor.

At the narrowest supported aspect (4:3, `project.godot`'s
`window_width_override`/`window_height_override` = 1280×960) that canvas is tight, which is
part of why the upgrades page is a **3-column grid of tiles** rather than a row of options
per slot: a tile's width is set by the layout, not by how many parts a slot happens to hold,
so the widest row on the page is a known quantity instead of a function of the catalogue.
The option labels that used to have to fit side by side now each get a full-width row inside
`UpgradeSlotPopup`, which is sized and centred independently of the page behind it. Hugging
the content does not make an over-wide row fit — it just pushes the box out to the margin
(and then clips) — so keeping the page's widest element bounded by construction is the
actual fix.

When re-measuring this by hand, always go through `DisplayStretch.logical_size()` (or an
equivalent `/ horizontal_stretch` step) and replicate the actual worst-case
selected/bracketed option — a measurement that skips either one will look fine in a
throwaway test and still clip in the real game.

- **Tune** (`LiftPage.TUNE`) — a slider per handling tuning axis (grip / brake-bias /
  aero; aero is greyed with a "needs Aero Kit" note until the kit is fitted — grip and
  brake bias are always tunable). **Reset to neutral** and **Wheels** sit in the page's
  bottom action row, not in the body; Reset clears only the handling axes and
  **preserves** engine detune. Each change saves via
  `Save.set_tuning`. The engine-detune slider is NOT here — it lives on the **Upgrades**
  page's `tune` tile (detune is a power / power-to-weight knob, not a handling axis).
  The slider holding the cursor lights up (its row wraps in a panel painted by
  `UITheme.mark_panel_focused` on `focus_entered`/`focus_exited`) so it's obvious which
  is selected, and left/right nudges it in place (see the `MenuNav` slider note above).
  No page title/subtitle — the sliders take the full height.
- **Upgrades** (`LiftPage.UPGRADES`) — the reusable **`UpgradesGrid`** component
  (`scripts/upgrades_grid.gd`). It is **one view, not a pair of pages**: a heading row, a
  performance line, and a grid of slot tiles, each of which opens a popup listing that
  slot's options. See "The upgrades page: a grid of slots" just below for the shape and the
  reasoning; this entry covers what the page contains.

  **The heading row** (`UpgradesGrid.build_title_row("Upgrades")`) carries the page title
  and the player's **star balance** — the digits of `Save.stars_available()` beside a drawn
  `StarRow` star. The balance rides on the component rather than on any one host's page
  chrome, because the option popups quote **prices**: all four hosts show it, and every
  `rebuild()` (which a purchase triggers) re-reads it.

  **A single `PERFORMANCE <n>` line** sits under the heading — the whole build's
  `CarPerformance.rating` (`current_rating()`), with the ceiling beside it (`512 / 480`, red
  when over) when a host sets one. It is a plain `Label`, so it adds nothing to
  keyboard/gamepad nav, and it is the page's only aggregate number: everything else on the
  page is a part and its current setting.

  **The grid** is a `GridContainer` of **3 columns and 9 tiles** — the seven
  `UpgradeLibrary.SLOTS` (turbo, gearbox, aero, tires, weight, drivetrain, nitrous) plus two
  **pseudo-slots**, `engine` (engine swap) and `tune` (engine detune). Swap and detune being
  tiles rather than bespoke rows is the point of the layout: every way of changing this car
  is one of nine equally-weighted squares, so "where do I change X?" is answered by looking
  rather than by scrolling to the end of a list. Tile order and membership come from
  `UpgradeOptions.grid_slots()`, not from the widget code.

  **Each tile is a focusable `Button`** wrapping a full-rect `VBoxContainer`
  (`MOUSE_FILTER_IGNORE`, so the whole tile stays one press target) holding an **SVG icon**
  above a `Label` reading `"<slot>: <value>"` — `turbo: Small`, `tune: 80%`, `engine: V12`.
  The value comes from `UpgradeOptions.current_label`, so a tile always states what is
  fitted right now and the grid reads as a summary of the car before the player presses
  anything.

  **The label is ONE line — it neither wraps nor clips.** Wrapping makes a tile taller and
  a grid of uneven rows stops reading as a grid; clipping truncates silently, which is worse
  than overflowing because the player cannot tell it happened. Fitting is handled by keeping
  the TEXT short rather than by growing the tile, in two places:

  - `UpgradeOptions.tile_slot_name` abbreviates the long slot NAMES for the tile only —
    `drivetrain` → `drive`, `gearbox` → `gears`, `nitrous` → `nos`.
  - An option's optional `tile_label` abbreviates the VALUE, and the popup ignores it: the
    engine shows its layout shorthand (`V12`) rather than its marketing name
    (`27L Merlin V12`), and drivetrain drops the `(Stock)` qualifier that earns its place in
    the list but not on a square that has to fit three across a phone.

  With both, every stock caption fits inside `TILE_MIN_W` with room to spare (widest is
  `WEIGHT: STOCK`). Tiles also `EXPAND_FILL`, so on any page wider than the phone floor
  there is more room again — the floor is what the longest fitted part names lean on. Icons load
  through `UpgradeIcons.texture(slot)` (`scripts/upgrade_icons.gd`) from
  `textures/icons/<slot>.svg` into a `TextureRect`, tinted via `modulate` — an SVG rather
  than a glyph for the same reason as the price star below: Syne Mono has no icon glyphs and
  the web export has no system font to borrow one from, so a character would be a tofu box
  on mobile web.

  **A tile GREYS OUT when the slot offers no choice** (`UpgradeOptions.has_choice`, which
  asks whether any option is selectable AND not already current — testing "is it current"
  rather than "is it Stock", because drivetrain's options are drive MODES with no empty-id
  Stock entry and the car's own layout is always selectable). If every part in a slot is
  still locked, the only thing the popup could offer is the state the car is already in — a press, a read of greyed lines and a back-out that teach
  nothing. The tile still shows what is fitted, dims, and drops out of the focus order, so
  the grid says up front where there is a decision to make. It comes back the moment the
  gating rally is won.

  **The `engine` tile is an ACTION, not a list.** A swap TRADES this car's engine with
  another car the player owns, so the choice being made is *which car* —
  and the host owns that screen (`hq.gd::_enter_engine_swap` puts the car park into SWAP
  mode). Pressing the tile calls the host's `on_swap`; it never opens the engine catalogue,
  which would imply you can simply fit any engine. Only the HQ lift supplies that action, so
  on the other three hosts the tile is informational and greyed. The only other thing that
  greys it is the capability still being locked — `UpgradeOptions.engine_swap_blocked_reason`
  returns just `"Locked"` or `""`, and the reason goes in the tooltip. Winning the
  unlock rally is the WHOLE gate: after that, swapping is **free and unlimited**, so the
  tile is permanently live and never has to report a spent resource.

  **The `tune` popup carries a Done button**, and it is the only variant that does. The
  option list closes itself the moment a row is picked, so its exit is the gesture the
  player already wanted; a slider has no equivalent, and Esc / gamepad-B are undiscoverable
  and absent entirely for a pointer or touchscreen. The detune writes through live on every
  drag, so Done confirms nothing — it just leaves.

  **Pressing a tile opens `UpgradeSlotPopup`** (`scripts/upgrade_slot_popup.gd`) — see "The
  slot popup" below. Applying an option closes the popup and rebuilds the page; **focus
  survives the rebuild** via an `upgrade_focus_key` meta on each tile plus a deferred
  `_restore_focus`, so pressing a tile and coming back lands the cursor on that same tile
  rather than at the top of the grid.

  What the individual slots hold is [upgrade-catalogue.md](upgrade-catalogue.md)'s subject,
  but three are worth knowing here because their options do not read like "a part or not":
  the **drivetrain** tile is an FWD/RWD/AWD picker (a `drive_mode` override, gated as a
  whole on the swap kit); the **weight** tile is the one slot whose rows are NOT part names
  — `UpgradeOptions._option_label` labels each weight option with a bare signed mass delta
  (`+200`, `-200`, with `Stock` still reading `Stock`), because "Heavy Ballast" is three
  words for a slot that is really one number and what the player is picking is how much
  mass to add or shed. The kilos are derived from the part's mass MULTIPLIER against the
  car with the slot empty, then rounded to the nearest 100 (floored at 100, so a real part
  never reads `+0`) — a multiplier lands on figures like 243, which is precision the player
  cannot act on where a round number reads as a decision. The tile caption — which is just
  `UpgradeOptions.current_label` — reads `weight: +200`, and the two ballast options are
  free while the lightweight kit is earned; and the **tune** tile is the one
  slider in the grid (below). The `nitrous` tile is an ordinary slot tile — see
  [nitrous.md](nitrous.md) for why the part installs pre-enabled.

  Prices in the popup are quoted as `Name N★` where **the star is DRAWN**
  (`StarRow.price_icon()` on the row's `icon`, `icon_alignment` RIGHT), never the `★`
  CHARACTER: Syne Mono has no `★` glyph, so a `★` in a label only rendered at all because
  the OS supplied a fallback font, and the **web export has no system fonts** — every price
  read as a tofu box on mobile web. The heading's balance does it the other way round (a
  sibling `StarRow` beside digit-only text, since a Label carries no icon), as does the
  hub's **Repair N★**; see [star-economy.md](star-economy.md) → "Where the player sees it"
  for both shapes. Guarded by
  `test_menu_flow.gd::test_hq_lift_text_only_uses_characters_the_bundled_font_can_draw`,
  which sweeps the whole lift station for any character the bundled font cannot draw.

  **`UpgradesGrid.setup(owned, on_change, on_swap, rating_limit)`** takes an optional
  `rating_limit` (a `CarPerformance` rating ceiling, `NO_LIMIT` = `-1` for none); when set
  ≥ 0, the overlay's **close button is gated** (`bind_close_button` + `request_close` /
  `can_close` / `over_rating_limit`): it reads **Done**, turns red with **"Over limit —
  reduce to N performance"** and blocks closing (button + Esc / back) while the live build
  exceeds the ceiling — over it the car is ineligible, so closing would only defer the
  refusal to the start line. Used by the start-line upgrades overlay, the reward reveal and
  the HQ car-park Change-Upgrades modal, all of which source it from `DrivingContext`; only
  a Rally Challenge actually has one, and the HQ garage lift omits it entirely.
  (There is no Repair anywhere — see [damage.md](damage.md).)

  The **`engine` tile** is the engine swap (`UpgradeOptions.SLOT_ENGINE`): it reads the
  car's current engine, and its options are the swap targets, gated **only** on the
  capability having been won (not on HP, and not on any consumable — swaps are free and
  repeatable once unlocked). The lineup is **every other owned
  car regardless of health**. It is effectively **lift-only** — the HQ lift is the one host
  that passes `on_swap`, since pressing through opens the car park in **swap mode**
  (`_enter_engine_swap` / `_carpark_swap_mode`), where the normal car-park cycle / confirm /
  back flow exchanges the two cars' engines (`Save.swap_engines`, which consumes nothing)
  and returns here; the
  other hosts leave `on_swap` unset, because that flow would tear down the screen they are
  running on. See [engine-swap.md](engine-swap.md).

  **The upgrades page: a grid of slots.** All four hosts — the HQ lift (`hq_overlays.gd`),
  the HQ car-park Change-Upgrades popup (`hq_carpark.gd`), the start-line upgrades overlay
  (`start_line.gd`) and the reward reveal (`upgrade_reveal.gd`) — instantiate the same
  **`UpgradesGrid`**, and the host-facing contract (`setup` / `rebuild` / `first_control` /
  `bind_close_button` / `request_close` / `can_close` / `over_rating_limit` /
  `current_rating`) is what they all speak, so the gated-close machinery is written once
  rather than four times.

  **Why a grid and not a list of rows.** A slot's options are a *choice among a few*, and a
  row that lays every option out horizontally has to fit an unknown number of buttons into a
  fixed width — which is what drove the old page's squeezing, wrapping and hidden-option
  rules. Pushing the options into a popup makes the page itself a fixed 3×3 shape that never
  reflows, gives each option a full-width row it can caption freely ("Needs Big", "3
  stars"), and turns the top level into something the player can read at a glance: nine
  tiles, each stating what is currently fitted. It is also **one page deep and no more**:
  the whole car is on screen at once, so nothing needs a second page, a stat-to-category
  index or a filter to reach it — the tile IS the index.

  **The slot popup** (`UpgradeSlotPopup`, `scripts/upgrade_slot_popup.gd`) is a
  `CanvasLayer` modal joining **`ConfirmPopup.MODAL_GROUP`** — so one modal at a time (see
  "One modal at a time"), and `MenuNav.input_blocked` deafens the grid behind it rather than
  the two competing for arrow keys. It draws a dim backdrop and a centred `UITheme.panel`
  and then, deliberately, **no title and no Cancel/OK row**. The tile the player just
  pressed is the title, and a button row would only add a second way to do what pressing an
  option or backing out already does.
  - **One explainer line at the top**, from `UpgradeOptions.slot_description(slot)`, saying
    what the slot *does* in plain language ("which wheels get the power"). Not a title —
    a heading repeating "TURBO" over a list of turbos says nothing, while this is the only
    thing telling a player who knows nothing about cars why the slot is worth opening. It
    is dim and word-wrapped (reference text, must not compete with the options), and being
    a `Label` it is never focusable, so the cursor still opens on the fitted option and the
    keyboard/gamepad path is unchanged. A slot with no entry draws no row at all. Both
    entry points take it — the option list and the detune slider. See
    [upgrade-catalogue.md](upgrade-catalogue.md) → `slot_description`.
  - Selectable options are `FOCUS_ALL` buttons; **locked or unaffordable ones are shown
    GREYED and `FOCUS_NONE`**, captioned with their reason ("Locked", "Needs Big",
    "3 stars"). Showing them is a deliberate reversal of the old "hide what you can't have"
    rule — a tile hides its ladder until pressed, so a popup that listed only the reachable
    rungs would leave the player unable to learn the slot has more in it (see
    [upgrade-catalogue.md](upgrade-catalogue.md) → "Locked options are LISTED, GREYED").
    `FOCUS_NONE` is what keeps that from costing anything at the keyboard: nav **skips** the
    dead rows, so the cursor only ever stops on something that does something.
  - The current option is marked with `UITheme.mark_selected` and **the cursor opens on
    it**, so the popup starts by answering "what is fitted now" without the player moving.
  - Purchase options carry the drawn star price. The digits and the star sit **together at
    the right edge**, as a full-rect `HBoxContainer` overlay aligned to the end
    (`_add_price_tag`) — not as `b.text + b.icon`, which is what this was. A `Button` draws
    all its text as one left-aligned run and its icon at the far right, so a price appended
    to the text hugged the option's NAME with the whole row's slack between it and the star
    it belonged to, reading as part of the label rather than as its price. The overlay
    ignores the mouse so the row still presses as one button, and sets `MENU_ROW_H` by hand
    because having a child makes it skip `UITheme.enforce`'s single-line-button branch.
  - **Every row quotes the performance rating that option would give the car** —
    `UpgradeSlotPopup._row_label` renders it as `Small (412)`, and both the pickable-button
    and the greyed locked-row paths go through it, so a rung the player cannot take yet
    still says what it would be worth. The figure is **parenthesised** precisely so it
    cannot be misread as the star price, which is drawn after it with its own icon. There
    is deliberately **no per-row "before → after" progression**: `Stock` is always the first
    row and always rates the car as it stands, so the before-figure is stated once at the
    top of the list instead of being repeated on every line.
    The numbers come from `UpgradeOptions.rating_with` (via `UpgradeOptions.build_with`, a
    pure hypothetical build — nothing is written to the save), stamped onto the rows by
    `UpgradesGrid._rated_options` on the way into the popup rather than inside
    `options_for`, because a rating is a simulated benchmark lap and `options_for` runs for
    every tile on every grid rebuild — see
    [upgrade-catalogue.md](upgrade-catalogue.md) → "The option model is pure data".
  - **Clicking a row applies and closes**; back closes without applying. One press per
    decision — the option list IS the confirmation step, since the player chose the slot,
    then chose the option. Applying a PURCHASE now also **switches the part on**
    (`UpgradesGrid._apply_option` calls `Save.set_upgrade_enabled` after a successful
    `Save.buy_part`): a granted part arrives parked precisely so
    an unasked-for gift never changes how the car drives, but here the player opened the
    slot, picked the rung and spent the stars — leaving it parked meant the menu took the
    payment and visibly did nothing.

  **The `tune` tile is the one exception: a SLIDER popup**
  (`UpgradeSlotPopup.open_slider`) — a single `SliderRow`, 0–100 step 5, with a live label,
  writing through `Save.set_engine_detune` on change. Detune is a continuous power /
  power-to-weight knob (it lives here rather than on the Tune page for that reason, see
  below), and chopping it into list rows would throw away the fine control the player
  reaches for it for. It is the same widget the tuning sliders use, so left/right nudges the
  value in place.

  **Navigation.** The grid is navigable on **both axes** — up / down / left / right, keyboard
  AND gamepad — via `MenuNav` over the `GridContainer`'s geometry; because the tiles are
  equal-sized cells in a real grid, Godot's geometric neighbour search is reliable here in a
  way it was not for the old page's mix of full-width rows and right-pinned buttons, so
  nothing needs hand-wiring. The popup list is navigable vertically, its unselectable rows
  skipped, and back closes it. Both halves are covered by nav tests — a menu reachable only
  by pointer is not shippable (see "Menu navigation" above).

  The page's **`< Back`** button (`_lift_back_button`, returns to the hub) sits in the page
  `root` **below** the scroll container — a different node level from the tune/upgrades
  body — but it's `FOCUS_ALL`, so `menu_down` off the bottom row of tiles reaches it by
  geometry (the box `MenuNav`s move focus across container boundaries). It's also the focus
  fallback (`_grab_lift_page_focus`) when a page body has no focusable control at all, so
  the page is never dead to keyboard/gamepad.

`_refresh_lift_ui` toggles which face (hub vs. a menu page) is shown from `_lift_page`.
See [tuning.md](tuning.md) for the underlying config pipeline.

**TABLE (the 3D world map).** A zoomed-in, near-top-down look at the table's flat map
plane — a **square** table top (`hq_table_size`/`hq_map_plane_size` are equal in
X/Z) surfaced with a **satellite map photo** (`RegionLibrary.DEFAULT_MAP_IMAGE` —
`textures/map_world.jpg`, an unshaded albedo texture so the aerial colours read true
under the garage lighting). There is **ONE world map**: no swap arrows, no viewed
region, no way to change maps. `_refresh_map_pins` loads that one texture and pins
**every** rally in `RallyLibrary.all()` at once, so a corner the player hasn't earned
is visible from the first minute — its rallies simply render locked. Under the pins it
also draws the **reveal graph** — faint dotted lines joining rallies whose circles reach
each other, but **only where both ends are already revealed**, so the lines chart the route
the player has lit rather than spoiling the dark (`hq._build_reveal_links` /
`RallyLibrary.reveal_link_pairs`, see
[map-exploration.md](map-exploration.md) → "The graph on the table").
See [regions.md](regions.md) for the region look (it no longer gates anything —
regions are look + waterline only; the completion-gated specials are
[rally-roster.md](rally-roster.md)'s territory). Every
rally in the roster is a 3D **pin** (`_make_pin`) at its normalised `map_pos`: a
**state-driven marker** — an ordinary rally gets a **flag** (`RallyFlag` — a small
**base disk** the pin stands on + a pole + waving pennant + finial bead), a
**SPECIAL** gets a **trophy** (`RallyTrophy`, see below) — topped by a **billboarded design-system box** (`_build_pin_label`) that
holds the rally name and a row of proper **five-pointed stars** — 1st-place best = 3
gold, 2nd = 2, 3rd = 1, else dim (`_stars_for`). The box is a real `UITheme` panel
(Syne Mono, uppercase) composited in an off-screen `SubViewport` and shown
on a `Sprite3D`, so text and stars live in **one box** that always faces the camera;

**EVERY readout wears the same pure-black panel** — house rule 4 with no exception. A
special event's box used to be INVERTED (a light-brown face via the retired
`ACCENT_READOUT_BG` / `ACCENT_READOUT_INK` and `_build_readout_sprite`'s `accent` flag);
that is gone, because the 3D markers now carry the "this one is different" job (a car
model, a trophy, or a flag) and a panel colour saying it on top of a marker that already
says so was the same emphasis twice.

**No drop shadow on a floating readout.** The global theme gives every `Label` a hard black
shadow (`tools/build_ui_theme.gd` → `font_shadow_color` + `shadow_offset_*`), which is the
terminal look on a flat menu — but on a black readout it is invisible. `_build_readout_sprite`
clears it per-label rather than changing the theme, so the rest of the UI keeps the house look.

the stars are drawn by **`StarRow`** (`scripts/star_row.gd`) as polygons, sidestepping
the font's missing ★/☆ glyphs (same reason the UI uses ASCII `<`/`>` for nav) — a rule that
holds for **every** star in the game, including the star PRICES on buttons, which take
`StarRow.price_icon()` as their `icon` because a Button lays out no children. **The
rasteriser itself now lives in `PolygonIcon`** (`scripts/polygon_icon.gd`): its
`texture(key, points, color)` supersamples a flat polygon (`PolygonIcon.SUPERSAMPLES`) into
a cached, centred `ImageTexture`, and `StarRow.texture` is a thin delegate onto it. It was
extracted from `StarRow` — which had the only copy — when a second drawn icon needed the
same rasteriser; two hand-rolled supersamplers would drift, and the
tofu-box rationale above is identical for every drawn icon, not just stars.
(`StarRow.TEXTURE_SS` and its private texture cache are gone with the move.) The
flag encodes the rally's state on **two axes** (`RallyFlag.pennant_kind` /
`RallyFlag.accent_color`). **Pennant:** placed 3rd or better → a **black-and-grey
checkered** racing flag; else **bright green** when the player owns a car eligible to
enter (`_has_eligible_car`); else **dark grey** (no qualifying car — also a locked
special). **Tip + base** (the finial bead and base disk, always one colour): **warm
gold** once the rally is **won** (1st place, 3 stars), **metal grey** otherwise. The
stars in the box remain the exact readout.

**A special event stands a TROPHY instead of a flag** (`RallyTrophy`, procedural like
the flag — base coin, square plinth, stem, tapered bowl with two ring handles, finial
bead). Two reasons it isn't just a differently-coloured flag: a special is the
**prestige event** on its corner and shouldn't read as one more pennant, and a cup can
show **which** medal you took where a pennant only says "podiumed". It keeps the flag's
two axes so the map speaks one language: **cup + finial** = best result — **gold** (1st)
/ **silver** (2nd) / **bronze** (3rd) / **plain metal** (never podiumed, including
locked); **plinth + coin** = raceability — a deep **racing green** when an eligible car
is owned, else **grey** (the green is *darkened* from the flag's pennant green, which
covers far less area and would overpower the cup at plinth size). It shares the flag's
base radius/thickness so pin spacing and hit spheres need no special case, and stands
the same height as a flag pole (`RallyTrophy.HEIGHT` ≈ `RallyFlag.POLE_HEIGHT`) so
`_make_pin` hangs the readout box off whichever marker it built and specials never look
diminished beside ordinary rallies.

**The readout box is HOVER-ONLY, on every pin.** One rule for all of them, whatever they
stand and whatever state they are in: `_make_pin` always builds the box, always starts it
`visible = false`, and the focus pass shows it only while the cursor is on that pin — which
is what keeps the table a map rather than a noticeboard (a dozen open boxes at once read as
a wall of menus). A rally that isn't enterable — out in the fog, or reachable with nothing
in the garage that fits — keeps its box but renders it faded (`FOGGED_PIN_DIM_ALPHA`), so a
pin the player can't enter yet still *answers* when they point at it. The **3D marker stands
at every pin** regardless, so the map always marks where the unavailable rallies are.
An available pin carries **two** pickable `Area3D` hit spheres bound to the same handler
(`_add_pick_sphere`, rally id bound) — one over the flag/pole and one over the
floating **readout box itself**, so a click on the menu enters the rally just like a
click on the flag — while an unlocked-but-ineligible pin has only the flag sphere (no
live box to click). Each pin also
carries its `rally_id`/`locked` in metadata; a pin is grey + **non-pickable**
whenever it isn't **revealed** yet (`RallyLibrary.rally_revealed`). Reveal is
**purely geometric** now — `rally_revealed` → `position_revealed` asks whether the
rally's `map_pos` falls inside any of `RallyLibrary.lit_sources`, the circles grown
around what the player has already completed. There is **no star gate and no
`reveal_after`/`requires_completions` count** any more (the old wave counters, and
before them the roster-wide STAR TOTAL, are both gone — stars became a spendable
balance, see [star-economy.md](star-economy.md)). The fog mask on the map plane
shades with the SAME predicate, so what looks lit and what can be entered cannot
drift — see [map-exploration.md](map-exploration.md).
**The next locked special still gets a teaser box:** it renders a **full-opacity,
non-pickable** teaser (`hq._build_special_teaser_label`, via `hq._make_pin`) naming the
event over an unlock line (`hq._special_unlock_line` — "unlocks engine swaps" for
`RallyLibrary.ENGINE_SWAP_UNLOCK_RALLY`, and **empty** where the rally's own name already
carries its reward, i.e. anything in `UpgradeLibrary.unlocked_by`). No count is quoted:
with reveal geometric there is no counter to quote, so the line names a *destination*
rather than a requirement. The grey trophy below already carries the "not yet" signal, so
the teaser doesn't need dimming to read as locked.
**ONLY the nearest one is teased** — `RallyLibrary.nearest_locked_special_id` (which
replaced `next_locked_special_id`) picks the locked special with the smallest
`distance_beyond_frontier`, and every other locked special hangs **no box at all**, just
its trophy: a special further out isn't something the player can work on yet, and eight
teasers at once buried the map under unreachable menus. It is **hoisted out of the pin
loop** in `_refresh_map_pins` and passed in per pin — the answer is the same for every pin
and the query walks every special through `distance_beyond_frontier` (which rebuilds
`lit_sources`), so asking it per pin was ~32× the work for one answer.
**This is the ONLY place that event is named.** The garage used to carry it too, as a
permanent next-carrot line; that line is gone (see the GARAGE section above) — off the map
the name has no context to stand in, while here it is placed on the world.
An unlocked special's pin names its unlock too. A meter sits at the **bottom centre** of
the HUD (`build_table_overlay`) — a drawn gold star (a one-star `StarRow`, since Syne Mono
has no ★) beside the **digits alone**: `hq._refresh_meter` writes `"%d"` and the glyph
replaces the word. Centre-bottom rather than the top-left corner it started in: it is the
map's one number and the currency the special pins are gated on, so it sits on the centre
line the eye already travels instead of over the pins. One star and a count, deliberately
NOT a `StarRow` of N-lit-of-M — that shape is the rally MEDAL readout and would imply a
maximum. It shows the **spendable balance**
(`Save.stars_available`) with **no denominator**: stars are currency now, so what
matters is what the player can take to the present box, and there is no meaningful
maximum to divide by (the balance falls on a purchase and the Rally Challenge tops it
up without bound).
### What a map-table entry actually costs

Where the hitch on "tap the table" came from, and what a rebuild still costs when one is
genuinely needed. Measured headless (32-rally roster, fast x86, **no GPU work included** —
treat these as a CPU floor, not the device cost):

| step | cost | notes |
|---|---|---|
| `_refresh_map_pins()` — real rebuild | **~20 ms** | frees all 32 pins and rebuilds them |
| ↳ 32 × `_make_pin` | ~8.4 ms | flag/trophy meshes + one readout `SubViewport` each |
| ↳ `_apply_map_fog` / `_build_fog_mask` | ~0.8 ms | 64² `Image` loop — cheap, not the problem |
| ↳ `_build_reveal_links` | ~0.9 ms | |
| ↳ 32 × `_has_eligible_car` | ~0.0 ms | |
| ↳ `nearest_locked_special_id` | ~0.2 ms | hoisted out of the pin loop |
| `_enter_table()` — before the skip | **~42 ms** | the rebuild above, plus focus/pan setup |
| `_refresh_map_pins()` — **skipped** | **~0.04 ms** | stamp matched; the stamp itself is 0.04 ms |

**"Warming the table" is NOT the fix, and the numbers above are why.** `_build_hq` calls
`_refresh_map_pins()` unconditionally at boot, behind the `LoadingScreen` cover, so the map
texture, the fog shader, the wood grain (`MapTable._wood_tex`, a `static var` generated once
per *process*) and the cached prize-car props (`_prize_car_props`) are all live before the
player ever sees HQ. There was no cold cache to pre-warm — the cost was work being **redone**
at the worst possible moment. Three things fixed it, and the reasons they are safe are the
part worth keeping:

1. **A table entry no longer rebuilds pins that would come out identical.**
   `_refresh_map_pins` opens by comparing `_map_pins_stamp(hold_locked)` against
   `_pins_stamp` and returning early when they match (it still re-seats selection and
   rewrites the meter, because a table entry re-centres `_table_pan` and so moves the
   cursor). The stamp is deliberately **coarse and conservative** — the whole profile hash,
   the whole of each authored table, `hold_locked`, and the map/fog Config values — because a
   missed input means a STALE MAP (a pin still grey after the rally that lights it), which is
   far worse than an occasional needless rebuild. **Add to it if you make the pins read
   something new.** Measured: **0.04 ms** on the skip path against **22 ms** for the rebuild,
   and the stamp itself is 0.04 ms, so the check pays for itself ~500×. Everything that
   should still rebuild does: the reveal parade varies `hold_locked` per step, and every
   other caller (`_on_cloud_profile_replaced`, `_enter_present_box`,
   `_dev_complete_selected_rally`, `_finish_reveals`) writes the profile first.
   Guarded by `test_menu_flow.gd::test_hq_table_entry_reuses_unchanged_pins` and
   `::test_hq_map_table_focus_highlight_survives_a_pin_rebuild` (which clears the stamp to
   force a real rebuild, since that is what it is about).
2. **Only the HOVERED readout's `SubViewport` renders.** They are built `UPDATE_DISABLED`,
   and `hq._paint_pin_readout` — now the single place a readout's visibility changes, and it
   carries the focus repaint too — arms `UPDATE_ALWAYS` on the one box that is up and
   disables it again when it closes. `UPDATE_ALWAYS` rather than a one-shot `UPDATE_ONCE`
   on purpose: it is one viewport at a time, and a single render can be taken *before* a
   `Control` finishes its deferred container sort, which would bake a blank panel and never
   correct it. Guarded by `::test_hq_only_the_hovered_pin_readout_renders`.
3. **The Free-Roam prewarm waits for stillness** (see the GARAGE section's Free Roam
   paragraph, and `hq._prewarm_should_wait`) instead of firing ~100 ms car-instantiate
   frames into whatever the player is doing.

**Podium → map table was the worst case, and #3 is the reason.** The podium's Continue boots
a FRESH HQ, and `_ready` only awaits `lineup_built` when `_view == View.EXTERIOR`. A podium
return opens on the GARAGE (or, after the opening rally, straight on the TABLE), so the cover
lifted and the deferred prewarm then instantiated one `car.tscn` **per catalogue car, one per
frame** (9 today, measured at ~3× the rest of HQ boot) *while the player was already reaching
for the table* — and the pin rebuild landed on top of those frames. Note the `return_to_map`
path also builds the pins **twice** at boot (`_build_hq`, then `_enter_table`); with the
stamp in place the second pass is a no-op rather than a second full build.

**Drag to pan** the map (mouse, or
finger via `emulate_mouse_from_touch`): `_pan_table` shifts the camera in the table
plane, clamped to the map extents. **The map tracks the pointer 1:1** — the drag delta is
measured by raycasting the pointer's before/after screen positions onto the map plane
(`_map_drag_delta` / `_map_point_at`) and moving the camera by the difference, so the map
point you grabbed stays under your finger. It used to be pixels × a fixed metres-per-pixel
constant (`hq_table_pan_speed`), which was only ever right for one camera height / FOV /
viewport height and for the shipped ones ran **~2.1× too fast across and ~1.9× down** (the
table camera is tilted, so one constant can't even be right on both axes at once): the map
raced ahead of the finger, so a pin you started a drag beside had slid well away by the
time you let go.
Projection is exact for free and survives re-posing the table camera or adding a zoom.
`hq_table_pan_gain` remains as a multiplier on top, and 1.0 (exact tracking) is the only
value that doesn't reintroduce the old feel. Guarded by
`test_hq_dragging_the_map_keeps_the_grabbed_point_under_the_pointer`. Pin selection fires on
**release** and only if the press wasn't a drag (`_table_dragged`), so panning never
opens the pin under the finger. **Crucially the station overlays are made
pass-through** (`_passthrough_overlay` sets every non-button control to
`MOUSE_FILTER_IGNORE`) — otherwise the full-rect HUD container/labels/spacer (all
default `STOP`) would swallow every touch and the 3D pins would never get a pick.
**THE PRESENT BOX — the one non-rally target on the map.** Cars are no longer won by
finishing a rally; they are **bought with stars** at a procedural gift box standing on
the map (`scripts/present_box.gd` — `class_name PresentBox`, `build()` for the map prop
and `build_openable(scale)` for the openable reveal copy). `hq._make_present_pin` builds
it at `hq.PRESENT_MAP_POS` — **(0.52, 0.50), deliberately not dead centre**, because
`front_runners` is pinned nearby (0.465, 0.615) and every hit radius must stay under half the
closest pin spacing (`_add_pin_hit`), so a box at the exact centre would leave the
nearest-to-centre cursor ambiguous between the two. Its readout is an
**accent (inverted) box** — the box is not a rally and must not read as one more pin, see
[ui-design-system.md](ui-design-system.md) rule 4 — reading **"BUY NEW CAR"** over a cost
line, **"COST: N STARS"** or **"COST: FREE"** (`hq._present_cost_line`; the price comes from
`RewardSystem.car_price`, normally `GameConfig.star_cost_per_car`, dropping to 0 **only**
when the player is *stranded* — `RewardSystem.is_stranded` — AND cannot afford one).

**The pin only exists once the player can afford a car**, and disappears again when the
balance drops below the price (`_refresh_map_pins` guards on
`Save.stars_available() >= RewardSystem.car_price(...)`; the free rescue price of 0 always
qualifies, so a stranded player always sees it). Note this is the **opposite** of the
locked-special rule ("locking hides availability, never information"): a special is a
destination worth signposting long before you can reach it, whereas the box is a **button**,
and a button you cannot press is clutter and a standing tease. There is consequently no
"can't afford it" wording anywhere — that state has no pin.

The box is kept **OUT of `hq._pins`** on purpose —
everything walking that array (`_unlocked_pins`, `_node_with_rally_id`, the reveal
parade) assumes a `rally_id` meta and the box has no rally.
- **Keyboard + gamepad reach it with no extra wiring.** `hq_table._build_table_targets`
  returns `{node, kind, pos}` entries of kind `"pin"` **or** `"present"`, and
  `_activate_table_focus` dispatches on that kind; because the map cursor is simply
  "whichever target sits nearest the view centre" (`_select_target_under_center`), a new
  kind of target becomes reachable by pan/glide, drag and stick alike just by appearing in
  that list. `_focus_hardest_incomplete` skips non-`"pin"` kinds so the box never steals
  the opening cursor.
- **One entry point for both input paths.** `hq_table.activate_present_box()` is called by
  BOTH the tap handler (`hq._on_present_input`, which honours the same release-and-not-
  dragged rule as a rally pin so panning can't spend stars) and the keyboard/gamepad
  `_activate_table_focus`, so the pointer and the cursor can never diverge. It goes
  **straight to `hq._enter_present_box()`** — there is deliberately **NO confirm dialog in
  front of the box**: the box screen IS the confirmation, and its bottom button is the till.
- **The box screen** (`CarparkMode.PRESENT`, `hq._enter_present_box`): the car park emptied
  of cars with one oversized openable box in the middle, and **nothing bought yet**. It
  reuses the ordinary car-park chrome rather than a modal — `_start_button` is the bottom
  button and doubles as the **price tag** (`_refresh_present_button`: "Open (4 stars)",
  or "Open (free)" for the rescue, and **disabled** rather than silently no-opping when the
  balance is short), `_car_stats_label` carries the shortfall or the reason it is free, and
  the prev/next **arrows are hidden** (`_set_carpark_arrows_visible`) because there is
  nothing to cycle — though the centre label they share a row with is where the revealed
  car's name lands. `_car_hint_label` — hidden and empty in every ordinary lineup — is
  SHOWN here, and only here, for "Open it to see what is inside": the box is the one target
  with no other affordance, whereas a lot full of cars with a ◄ / ► row needed no caption.
- **The empty lot still needs one marker — the panel is welded to it.** In world-space-menu
  mode the car-park chrome rides a `WorldPanel` anchored to `_markers[_focus]`
  (`hq.gd::_car_panel_xform`), and `_clear_lineup()` frees every marker
  (`hq_carpark.gd::_release_page_props`). With no marker the transform is `null`,
  `WorldPanel.place` early-returns, and the panel — bottom button and all — stays wherever
  it last was, i.e. nowhere the player can see it. So `_enter_present_box` calls
  `hq.gd::_add_present_marker()` immediately after clearing and seats `_focus = 0` **before**
  `update_overlays()`: one bay marker at `HQEnvironment.carpark_center()` with the same
  `rotation.y = PI` every other bay marker uses. It is kept on `_present_marker` and
  **`_open_present` reuses it** to seat the revealed car rather than making a second one —
  which is the point of the arrangement: "Open it" and the car detail that replaces it after
  the name reveal are read at exactly the same position and angle, so the panel does not jump
  when the lid comes off. See [world-panel.md](world-panel.md) → "The car-park host swap" for
  the general rule; any future car-park mode that clears the lineup loses its panel the same
  way.
- **Opening it** (`hq._open_present`, on the bottom button): buys the car, then **puts it in
  the box BEFORE a single wall moves** — the car is spawned at the box centre while the
  walls still hide it, so the reveal is the box genuinely opening *on* the car rather than a
  car fading in afterwards. This is exactly why the purchase happens on the button press and
  not on entry: you cannot put a car in the box until you know which car it is. It seats the
  car on the `_present_marker` created on entry (above), which already carries
  `rotation.y = PI` so the nose faces the courtyard/camera, matching every other bay marker
  (`hq_carpark._render_lineup_page`) — without that the car presents its back. Then
  `hq._refresh_map_pins()` (the balance dropped, so the box may now be gone entirely; and a
  new car can make previously un-enterable rallies raceable, so pin state changes too), and
  the car's name goes into `_car_name_label` **under the car** — **no result card, no
  modal**. A draw that comes back empty costs nothing: `purchase_car` resolves the car before
  debiting, and the failure surfaces on `_car_warning_label`.
- **Once open, the bottom button becomes the way OUT** — `_refresh_present_button` relabels it
  **"Back to garage"** and leaves it ENABLED (`_leave_present_to_garage`). It is never left
  disabled: a dead action row is a dead end, and the player has somewhere to go next — the
  garage, where their new car is. The **"< Back"** action goes to the garage from this screen
  too, for the same reason. That also makes a second purchase impossible without a
  `_present_opened` re-entrancy check doing the work.
- **The animation** (`hq._animate_present_open`): the **lid tweens up** out of frame while
  the **four walls fall outward**, each hinged on the axis parallel to its own base edge
  (see `PresentBox.build_openable`). The walls use **`TRANS_QUAD` + `EASE_IN` — the gravity
  curve**, so displacement goes as t²: a wall barely moves at first and then accelerates
  into the floor like a panel tipping past its balance point. Deliberately **not
  `TRANS_BACK`**, which overshoots *backwards* before travelling and made every wall visibly
  suck inward through the box before falling out. `PRESENT_WALL_TIME` is a slow 1.1 s — the
  panels should read as having weight.
- **Sizing is DERIVED, not tuned.** `PresentBox.build_openable(width, depth, body_h)` takes
  **metres**, and the car park sizes it from `CarLibrary.max_car_bounds()` — the per-axis
  maximum across the whole roster — plus `hq.PRESENT_CLEARANCE_M`. So the box fits the widest
  and longest car by construction and keeps fitting when a bigger one is authored. A single
  scale multiplier could not express this: the roster spans **3.8 m to 5.9 m** of length
  against ~1.9 m of width, so a square box either clips the long cars or dwarfs the narrow
  ones (an earlier 24× square footprint clipped the 5.9 m car badly). `max_car_bounds` takes
  the greater of the body box and `track + wheel width` for WIDTH, because on the
  widest-tracked cars the wheels stand proud of the bodywork. Trim sizes (ribbon, bow, wall
  thickness) scale off the box's NARROW dimension so a long thin box does not get a 6 m ribbon
  on a 2 m face.
- Under `Platform.is_headless()` the whole beat **resolves immediately** — the car is parked
  and named with no tweens and no awaited timers, so tests pay no cinematic time.
  `_cleanup_present_reveal` is shared by the generic car-park Back and restores the arrows
  and hint, so backing out mid-reveal can't leave a giant box parked in the lot.

Tapping a pin opens the **rally detail** sub-panel — a **single-column card** built
in `build_detail_overlay` (`hq_overlays.gd`) / populated in `_show_detail`. Header:
rally name **with the stage count appended** (`"Pinewood Sprint - 3 stages"`, singular
"stage" for a one-stage rally), region tag, and a gold **SPECIAL EVENT** chip
(`hq._detail_special`) on special rallies. There is deliberately **no per-stage breakdown** — the old left-hand STAGES
column (one row per event with its gravel/tarmac surface mix) was removed to free the
full panel width on small screens; the stage count on the title is the whole story.
**Body (full width):** the eligible-cars **restriction** (the
power-to-weight gate, not the hidden difficulty tier — the band is printed as a bare
`N–M hp/tonne`, the unit carries the meaning); an **eligibility read-out** —
`_eligibility_summary(rally, owned)` collects the qualifying cars and
`_qualifying_cars_text` **names them** (GREEN), up to `MAX_QUALIFY_NAMES` with a
`+N more` tail, or RED "no cars qualify" / muted "no cars owned yet" — with a GOLD
caution for how many **need a tune / swap to
fit** — and a **YOUR RECORD** line (best finish + a
`StarRow`, hidden entirely until the rally has a placement).
Everything is uppercase + one font size (`UITheme.enforce`), so
hierarchy comes from **layout, colour, and separators**, not font size. The
summary is tallied on top of `_entry_plan` so it always agrees with the map pin.
**Enter Rally** flies out to the car park, **◄ Map** dismisses the panel, and the
table Back returns to the garage. Nav stays diegetic (`menu_select` → Enter,
`menu_back` → Map; both buttons `FOCUS_NONE`).

**CARPARK (the outdoor lineup).** The owned cars **eligible for the chosen
rally** (`RallyLibrary.is_eligible`) — plus any car a **drivetrain conversion**
would qualify (below) — are parked at `GameConfig.hq_carpark_origin`,
in a **centred row ALONG X** — one car per painted bay (`menu_car_spacing` wide), with
fewer cars than bays centred within the grid — each **parked nose-out toward the
courtyard / menu camera (+Z)** so the camera frames its front with the garage behind;
each is a silenced `Car` prop (reusing `Car.apply_owned`). The exterior/title camera is
shifted by `menu_car_park_offset` (the same lot-centre offset) so it stays centred on
the row. Parking is shared with the title via `_build_lineup(cars)` — the car-select
screen and the title both pass **all owned cars** — or, for a fresh player
with an empty garage, the three starter-car previews (`_starter_previews`) so the lot
is never empty behind the title. Each `Car` prop is a full
physics scene (chassis + wheels + drivetrain + per-instance mesh duplication), so
`_build_lineup` lays out all the lot **markers up front** (cheap `Marker3D`s — the
camera framing and focus cursor key off `_markers`/`_eligible`, not the props) and then
streams the heavy car props in **one-per-frame** via `_spawn_lineup_progressive`,
rather than instantiating the whole lineup in a single frame (which hitched on every
rebuild — notably the new Change-Car lineup). A `lineup_built` signal fires once the
stream finishes. The props **drop in live**
(raised by `menu_car_drop_height` onto a collision floor under the lot) so they
**settle onto their suspension**, then `_freeze_lineup` freezes the settled pose after
`menu_car_settle_seconds` (both the per-frame stream and the freeze are guarded by the
same `hq_carpark.gd::_settle_generation` id so re-entering the lot — or backing out — abandons a
half-spawned lineup and cancels a stale freeze) — so a full car park costs nothing to
keep parked. Re-entry is also cheap: a **reuse cache** (`_car_cache`, keyed by the
owned car's `instance_id` → the built node + a deep `owned.hash()`) means
`_build_lineup` **rebuilds only the cars whose data actually changed** — an unchanged
car is shown at its new bay from the cache with no re-instance, mesh duplication, or
settle (`_obtain_parked_car`), so an unchanged re-entry parks instantly and only a
freshly-built car pays the per-frame stream + settle. `_release_page_props` **hides +
stows off-screen** the parked page's cars instead of freeing them (they stay parented to
HQ, frozen; stowed so a hidden car can't intercept a tap-to-focus ray meant for the next
page's car at the same bay); the cache is shared across every car-park lineup (car-select,
engine-swap, wheels, starter, Free Roam, title), **evicts** entries for cars no
longer offered (`_evict_unowned_cached_cars`, run each build), and is freed wholesale with the HQ node
on exit-to-race. `◄ ►` (or
`menu_left`/`menu_right`) move the focus and the camera eases to a **front 3/4 hero
shot from in front of the car** (`menu_camera_offset` is added in world space; +Z sits
the eye ahead of the nose-out car, looking back past it at the garage) over
`menu_camera_move_time`; the focused car **is** the selected car. The overlay shows
its name + stats (drive / **horsepower (HP)** / **weight (kg)** / **Health %**) via
`_car_stats_text` — the single stat-list formatter shared by the car-select and LIFT
overlays. Power-to-weight is deliberately **not** shown here; the p/w ratio
only surfaces where it matters, in the upgrades-menu detune readout. There is
no floating 3D label above the car. A **wrecked** focused car (`Save.car_is_wrecked`) is
**permanently too damaged to enter**: Start is disabled and the warning reads as final
("wrecked beyond repair") rather than as an instruction, because nothing revives it.

Rally entry is **purely categorical** — body type, country, doors, cylinders,
displacement, drive mode. There is no performance band: a car is never too fast or too
slow for a career rally, only the wrong KIND of car (`RallyLibrary.ineligibility_reason`).
The one restriction the player can fix without changing car is **drive mode**, because a
drivetrain conversion changes it: `_entry_plan` parks such a car as eligible and records
the target mode in `_drivetrain_needed`, and the detail panel counts it under "N need a
drivetrain conversion to fit".

The **"Too powerful" modal** (`_show_over_limit_prompt` → `_make_carpark_modal`, i.e. a
`MenuPage` with `dim`: a full-screen dimmer + centred house panel, NOT a native grey
dialog) therefore belongs to **Rally Challenge only** — the one mode that still enforces a
performance ceiling (as a `CarPerformance` rating, see
[rally-challenge.md](rally-challenge.md)). Its **Change Upgrades** button
(`_detune_change_upgrades`) opens the **Change-Upgrades popup** — the shared
`UpgradesGrid` component (see [upgrade-catalogue.md](upgrade-catalogue.md)) in a
matching centred modal (`_show_upgrades_popup`, engine-swap row dropped, passed the
challenge's rating ceiling; `_make_carpark_modal` hosts it via **`MenuPage.open_modal`** — see
"Hosting a modal" below, which is not optional) so the player can shed performance. Its
close button is the gated **Done** (blocking both the button and back) until the build is
under the ceiling; closing it (`_close_upgrades_popup`) rebuilds the lineup if anything
changed, and the player re-presses Start (**close → re-press**, no auto-launch). Both
modals are wired with `MenuNav.attach` (the upgrades popup hands its gated
`request_close` as `on_back` so Esc is gated too), and `_carpark_modal_open` makes
`_unhandled_input` hand navigation to the modal instead of the lineup beneath. Any fix
the player makes is an ordinary garage edit and **persists after the run**.

The map pin's green "raceable" pennant counts every owned car that fits the restriction
(or could after a drivetrain conversion) — `_has_eligible_car` builds on `_entry_plan`. Rivals field only cars that fit the restriction: the
opponent field is drawn from `RallyLibrary._eligible_cars` (the restriction's own pool). A **banner** names the rally + restriction; **Start** records the
fielded car as the **selected car** (`Save.set_selected_car` in `_begin_rally_start`,
so the tuning lift shows the car last raced), shows the
`LoadingScreen` overlay immediately and (after a fully presented frame, so it paints)
calls `RallySession.start_rally(rally, owned)` — the handoff derives event target
times by generating each track, which is heavy, so the overlay covers that work
instead of freezing HQ. **◄ Back** (or `menu_back`) returns to the map table and
clears the lineup. If no owned car qualifies, a hint shows and Start is disabled.

**Unbounded collection + pagination.** There is **no ownership cap** — the player can
own any number of cars, and there is no "garage full" gate or scrapping (both removed).
Instead every car-park screen **paginates**: `_build_lineup(cars, start_global)` hands
the WHOLE list to `CarList` (`scripts/car_list.gd`, the `_lineup` member) and
`_render_lineup_page` spawns only the current page — at most `GameConfig.carpark_page_size`
(10, the painted-bay count) heavy props at once. `CarList` treats the list as one wrapped
ring: `_cycle_focus` → `_lineup.advance(step)` moves the cursor car-by-car and, when it
crosses a page boundary, flips the page and re-spawns its props (snapping the camera);
past the very first / last car it wraps around (a single page wraps within itself). The
`(n of N)` label counts across the WHOLE list (`_lineup.global_index()` / `total()`). This
is the same machinery for rally car-select, engine-swap, the starter
picker, Free Roam and the title backdrop, so they all page identically.

Star ratings come from `Save.best_placement(rally_id)` — the best (lowest)
finishing position ever recorded there, stored by `Save.complete_rally(id, ms,
placed)` on each finish (`RallySession` passes the placement). A rally's
displayed rating is therefore always `RallyLibrary.stars_for_placement` of that
best placement; the SPENDABLE balance shown on the map meter is a separate,
persisted ledger (`complete_rally` returns what it credited for THIS finish, which
can be less than the displayed rating on a replay that finished worse) — see
[star-economy.md](star-economy.md).

Each parked car gets its **own duplicated meshes** (`CarProp.dup_meshes`) so a mixed
lineup renders each at its true size despite `car.tscn`'s shared mesh
sub-resources. The shared-`Config.data` write from `apply_owned` is harmless here —
the props don't simulate and `world.gd` re-applies the fielded car's config per run.

### Android app notice (mobile web boot)

Booting the **web build in an Android browser** (`OS.has_feature("web_android")`,
checked by `_should_show_android_app_notice`) shows a one-per-boot overlay over the
title shot: mobile-web performance is poor, so it points the player at the itch.io
page (`ANDROID_APP_URL`) hosting the much-faster APK. Two buttons: **Get the Android
app** (`OS.shell_open` → opens the itch page in a new tab) and **Continue in
browser** (dismiss). Desktop web and iOS never see it (nothing to install there),
and it only appears over a normal title boot.
While the notice is up, `_title_layer` is hidden so the title's MenuNav can't fight
the notice's for focus; dismissing (button, Esc, or gamepad B via the notice's
`MenuNav.attach(..., on_back = ...)`) frees the layer and re-shows the title, whose
MenuNav re-grabs the Start button through `visibility_changed`. Covered by the
Android-notice tests in `tests/headless/test_menu_flow.gd`.

## Run-scene fielding (`world.gd`)

When a `RallySession` is active, `world._ready` fields the player's OwnedCar via
`Car.apply_owned` (CarLibrary baseline → installed upgrades → bound damage from
the saved HP) instead of the default `apply_car(0)`, and wires this event's
`StageManager.stage_completed` → `report_event_result(elapsed_ms, hp_lost)`. The
car's `wrecked` builds a **`WreckScreen`** (`scripts/wreck_screen.gd`): the crash
plays out, then a slow orbit camera + a **"CAR WRECKED"** menu offers **Return to
HQ**, which calls `report_wreck` (the DNF). `rally_finished` loads the podium. With
no session (a plain dev boot of `main.tscn`) the default car is fielded and none of
this runs — `main.tscn` is still independently runnable. (Headless runs skip the
wreck cinematic and report immediately.)

## Pause menu (`pause_menu.gd`)

A `PauseMenu` `CanvasLayer` (`scripts/pause_menu.gd`) in `main.tscn`, set to
`PROCESS_MODE_ALWAYS` so its UI keeps working while the tree is frozen. It owns a
**top-right Pause button** (always visible during gameplay; the HUD's version/timer
labels were shifted left to clear it) — a square button bearing a **proper drawn
pause glyph** (`PauseIcon`, `scripts/pause_icon.gd`: two sharp-cornered ink bars,
since the font has no ⏸ glyph) rather than a cramped `| |` string — that **freezes the
game** (`get_tree().paused = true`) and shows an overlay with **Resume**, **Reset to
track**, **Settings** and **Quit to HQ**.
Resume unfreezes and closes. **Reset to track** snaps the car **onto the centerline
beside its current position** — "the middle of the road, regardless of where the car
is right now" (`TrackProgress.manual_reset_pose()`, a fresh nearest-point query).
This is deliberately **not** `recovery_pose()` (which the off-track reset / stuck
watchdog use): that pose is pinned to the *furthest* offset reached and freezes the
moment the car stops banking progress, so a strayed car would reset to a stale point that's
no longer beside it — feeling like the button does nothing. It's also **not** the full
start-line reset (`Car._reset()` / `reset_to(_start_transform)`). This "Reset to track"
menu item is now the **only** player-facing way to reset — there is no direct reset
input any more (see [controls.md](controls.md)). The menu owns no car reference, so it
emits `reset_to_track_requested`; `world.gd` connects that in `_ready` and performs
the reset (`$Car.reset_to(_track_progress.manual_reset_pose())`, which zeroes motion
and suppresses the teleport's impact damage — free), then the menu `resume()`s so the
player drops straight back in. `reset_to()` does **not** trust a bare `global_transform`
write — that only sticks when done inside the physics step, so a reset fired from a menu
signal (outside the physics frame) or on a stuck, **sleeping** body was silently reverted
by the physics server next frame (the car looked like it never moved, while the `R` reset,
which runs inside `_physics_process`, always worked). Instead it wakes the body and
**queues** the pose; `car.gd::_integrate_forces` applies it via `state.transform` — the
authoritative physics-write point — so it lands regardless of when the reset was fired.
Settings shows the **shared `SettingsMenu`** (camera
angle + mobile controls, identical to the title-screen page), with a **◄ Back** to
the Resume/Settings menu. **Quit to HQ** pops an *"Abandon rally?"* confirm and, on
accept (`quit_to_hq`), unfreezes and calls `RallySession.abandon()` — the rally is
left **incomplete with no retry penalty** (damage persisted, no reward); `abandon`
emits `rally_finished` which `world.gd` routes **straight back to HQ** (the garage
view) instead of the podium. (With no active session — a plain dev boot of
`main.tscn` — it just loads `hq.tscn` directly.) `ui_cancel` (Esc / gamepad B)
toggles the menu and backs out of Settings first; the gamepad **Start** button
(`pause` action) also opens it (open-only — it does not double as a menu "back"). A camera pick applies
**immediately** to the live `CameraManager` (wired via the `SettingsMenu.camera_changed`
signal → `CameraManager.set_mode`), so the angle changes the moment you choose it.
A **mobile-control** pick applies just as immediately to the live `MobileControls`
(the `SettingsMenu.scheme_changed` signal → `MobileControls.set_scheme`), so the
on-screen touch layout rebuilds the instant you choose it rather than only on the next
run.
The menu is **default-inert** (`_input_enabled` starts `false`, mirroring
`StageManager`'s `_armed` gate): the Pause button and `ui_cancel` do nothing until
`world.gd` calls `set_input_enabled(true)` **after world generation completes**. This
stops the player pausing *during* the awaited generation window (loading overlay up) —
opening the menu then would freeze the tree mid-build and allow quit/resume into a
half-built world. Covered by `tests/headless/test_pause_menu.gd`.

## Podium (`podium.gd`)

A **3D reward sequence** (the scene root is a `Node3D`), stepped through with a
single **Next** button, reading `RallySession.last_result()`. The stages present
depend on the result (`_compute_stages`): the first two always show; the reveals
only when something was won.

1. **PODIUM** — the **top-3 finishers' cars stand on a 3D podium** (1st centred +
   tallest, 2nd/3rd to the sides). The cars are spawned above their steps and drop
   in live so they **settle onto their suspension** (then freeze the settled pose,
   like the HQ car park), reading the `car_id` now carried on each standings entry.
   The headline result (rally, placement + time, or DNF; top-3 → `RALLY WON!`) sits
   over it. The camera (`_podium_cam`) sits **low and close, looking up** at the cars
   from just off head-on, and **always frames the player's car** — whichever step
   they finished on, not just the centre P1 step (tracked as `_player_car` when the
   player is in the top 3; falls back to the podium centre otherwise).
2. **LEADERBOARD** — the full ranked field (`RallyLibrary.build_standings`):
   position, name + car, time / `WRECKED`, the player's row tinted + marked.
3. **STARS** — the reward beat, and it **always runs, even on a DNF**: three dim stars is
   honest feedback about the miss, where hiding the beat would read as a missing screen
   rather than a result. Three **big** stars (the same `StarRow` widget as the map pins and
   the rally detail, just scaled up — `podium.STAR_BEAT_RADIUS`/`_GAP`) fill in gold one at
   a time (`_reveal_stars`, gated by `_reveal_gen`, instant under headless) up to the
   rally's rating — what the player's BEST-EVER placement here is worth
   (`RallyLibrary.stars_for_placement`, still the single definition of a placement's
   worth). The caption (`podium._stars_caption`) reports the **ledger delta**, not the
   rating: `"+2 stars — 7 in the bank"`, or on a re-win that didn't improve
   `"No new stars — your best here is already N"` (lighting gold stars while the balance
   didn't budge would look like a bug). It always ends on the **spendable balance** and
   **never** an "x of N" denominator — see [star-economy.md](star-economy.md).
4. **SPECIAL_UNLOCK** (only if `special_unlock != {}`, i.e. the FIRST top-3 win of a
   special that gates a part) — a milestone card naming the upgrade the
   special just opened, and whether it was fitted to the car that earned it. Deliberately
   **not** the slot-machine reel the other two reveals use: a reel implies a random draw and
   this outcome is fixed by which special was won. **Inverted** (light face, dark ink, drop
   shadow cleared — same house-rule-4 exception as a special's map pin), so a milestone does
   not read as another routine reward card. No spin, so it is instantly steppable and
   headless needs no special case. The panel's stylebox and text colour are reset in
   `_enter_stage`, or the following CAR_REVEAL would inherit the inverted look.
   See [reward-system.md](reward-system.md) → Special-event unlock.
5. **CAR_REVEAL** — **retired.** A won car is now revealed at HQ, in the present box the
   player has to open (`hq.gd::_enter_present_box`, handed over by
   `RallySession.pending_car_reveal_instance_id`). The podium stage put the game's biggest
   moment on the results screen, away from the garage the car arrives in, and over in a
   moment. The box puts the reveal where the car is, and makes the player perform it —
   Back is hidden and the Back ACTION is refused until the lid is off, so it cannot be
   skipped past. The enum member and its showroom/slot helpers remain in `podium.gd` but
   are no longer reachable: `_compute_stages` never appends the stage.

**No upgrade is revealed on the podium** — parts are unlocked by winning the prize
rally that carries them, not handed out per event (see
[reward-system.md](reward-system.md)); the podium
closes on the **stars** beat (or the special-unlock card after it).

During the car reveal the overlay's content stack drops to the **bottom of the
screen** (`_middle.alignment = ALIGNMENT_END`) so the slot card clears the
camera's view of the revealed car; the podium + leaderboard stay centred.

The **Next button is hidden during a slot spin** and only reappears once it locks
on (`_reveal_done`). The final Next returns to HQ, setting
`RallySession.return_to_garage` so HQ opens on the **garage** view. Slot durations /
drop height / settle time / turntable speed are `GameConfig` tunables
(`podium_*`). Headless runs build synchronously and resolve the spins instantly so
tests can step the stages.

**Environment & scenery.** The floor is **grass with two feathered tarmac pads**
(one under the podium, one under the showroom) — built as a subdivided mesh whose
per-vertex `COLOR.a`/`UV2.x` drive `shaders/ps1_models.gdshader`, the **same
grass↔tarmac crossfade the generated road uses**, so each pad feathers softly into
the grass. Its triangles are **wound front-face-up** — that shader culls back
faces, so a downward-wound floor draws nothing when viewed from above. Both focal areas are dressed with **trees, bushes and a standing
crowd** (`_build_scenery`): the same billboard trees (`textures/tree.png`),
`groundcover_opaque.glb` bushes and `spectator.glb` crowd the world uses, routed
through `Foliage` / placed as plain decorative `MultiMesh`es (seeded, no
collision, no steering AI — the
spectators just face the podium / showroom). Scenery is **skipped under headless**
(pure dressing; keeps the test budget). Counts / ring radii / pad size + feather
are `podium_*` `GameConfig` tunables.

`last_result` carries `rally_name`, `standings` (each entry with `car_id`),
`upgrades` (the part ids this rally's win unlocked, if any), `car_reward`, `car_reward_is_new`, and
`game_won` (renamed from `showdown_won`; see [rally-session.md](rally-session.md))
alongside the original `placed`/`completed`/`combined_ms`/`dnf`.

## Start line (location 2)

The pre-event **start-line scene** — the diegetic **briefing** panel (rally, event
N/3, restriction, fielded car + HP bar) and the **pre-launch presence** cars — is
built inside the run scene before the countdown; the player launches it into the
`StageManager` countdown. See [start-line.md](start-line.md). The in-run **Pause**
menu is covered above (`pause_menu.gd`); the between-event **standings**
(`standings.tscn`) interstitial is covered next.

## Standings interstitial (`standings.gd`)

Shown after **every** event (`RallySession.report_event_result` always enters
`Phase.STANDINGS`), not just the ones before a next event. For any event after the
first it stacks **two leaderboards on ONE page**. There is deliberately **no screen
title or rally-name line** — the section headings already say what each list is, and
those two lines cost enough height to push the second leaderboard below the fold on a
phone. Both lists are built by the same `UITheme.standings_row`
renderer (the row's `combined_ms` field carries the stage time in the first section,
the cumulative time in the second), each behind a dim section heading added by
`_add_section`:

1. **"STAGE n RESULT"** — that one event's finishing times, ranked via
   `RallySession.current_event_standings()`. A rival who DNF'd just that event sinks
   to the bottom of this section (they may still be alive overall).
2. **"OVERALL — stages 1 + 2"** — the cumulative leaderboard via
   `RallySession.current_standings()`. The heading spells out exactly which stages
   are summed, built by the pure `Standings.overall_heading(done)`: "OVERALL — stage 1
   only" after stage 1, then "OVERALL — stages 1 + 2", "OVERALL — stages 1 + 2 + 3".

Each section is **trimmed to the top `Standings.PODIUM_ROWS` (3)** so both fit on one
screen. When the player finished outside that, their own row is appended at the
bottom — with a dim `...` marker between when the two aren't adjacent — so they can
always see where they came. The pure `Standings.visible_rows(rows, top)` does that
selection and is unit-tested directly (it returns `{"gap": true}` for the marker).

The action row is an **`HBoxContainer`** — in overlay mode **Watch Replay sits left
and the forward action right**, each `SIZE_EXPAND_FILL` — rather than two stacked
full-width buttons, for the same vertical-space reason. Geometry gives `MenuNav`
left/right between them for free (`find_valid_focus_neighbor`).

BOTH sections show on **every** stage, including the first — where the two lists are
necessarily identical (one stage's time IS the combined time). The duplication is
deliberate: the screen keeps the same shape from stage 1 to stage 3 rather than
changing layout under the player, and the "stage 1 only" heading is what stops the
repeated list reading as a bug. Every stage — including
the **final** one — then has a single action button reading **"Continue to next
stage >"** which calls `continue_to_next_event()`. On a middling event that loads the next event;
on the final event `continue_to_next_event()` instead resolves the rally
(`_resolve_results` → `PODIUM`, `rally_finished`), and the scene (connected to
`RallySession.rally_finished` in non-overlay mode) then changes to `podium.tscn` itself
— the finished rally's full leaderboard lives on the podium's LEADERBOARD stage.

**Overlay mode** (`overlay_mode := false`, set by the host BEFORE `_ready`): `world.gd`
hosts this scene over the in-world **event-replay** cinematic instead of as a flat
interstitial — see [event-replay.md](event-replay.md) for the recorder/camera/car
playback this sits on top of, and [rally-session.md](rally-session.md) for how
`RallySession.standings_overlay_host` routes the scene here instead of a scene swap. In
overlay mode: the `Background`
`ColorRect` is transparent (alpha 0) instead of opaque `UITheme.BLACK`, so the replay
shows through; `_ready` does NOT connect `RallySession.rally_finished` (the live host
owns the rally-finished -> podium transition, not the overlay); and a
**Hide/Show leaderboard** toggle (`toggle_leaderboard()`,
`leaderboard_hidden_changed(hidden)` signal, `leaderboard_hidden` var) lets the player
watch the replay full-screen — hidden state rebuilds with ONLY a "Show leaderboard >"
button, still `FOCUS_ALL` and re-seated via `MenuNav.attach` with `first = show_btn` and
`on_back = toggle_leaderboard` (so Esc/gamepad B also re-shows it, mirroring the
attach-without-on_back convention elsewhere in this file — here `on_back` IS wired
because showing the leaderboard again is the natural "back" action from the hidden
state); shown state adds a "Hide leaderboard" button next to Continue, and the row of
buttons (Continue + Hide leaderboard) stays reachable the same way the non-overlay
button is — both states are fully keyboard/gamepad focusable, never mouse-only. The
host (`world._on_leaderboard_hidden_changed`) listens
for `leaderboard_hidden_changed` to mute/unmute the car's engine audio while the
leaderboard is shown vs. hidden. Non-overlay mode is unchanged (opaque bg, owns the
podium transition, no hide/show button).

## Deferred (rest of the diegetic 3D build)

The diegetic HQ space (exterior / garage / 3D map table / car park / tuning lift,
with the camera flying between stations) is in. Still deferred:
per-car paint + duplicate-model name suffixes,
designed environment art (blocks are placeholder), the 3D
reward-reveal rig + 3D podium, and camera fly-through transitions for the longer
hops. The podium + between-event **standings interstitial** still ship as flat
scenes (`podium.tscn` / `standings.tscn`); the diegetic 3D versions are later
refinements.

## Tests

The **present box** map target is covered in `tests/headless/test_menu_flow.gd`: it appears
in `hq_table._build_table_targets` with a `label_panel` and no `rally_id`, it is never in
`hq._pins`, `_activate_table_focus` reaches it **with no pointer and opens no confirm** (it
lands in `CarparkMode.PRESENT` with the box built), the bottom button prices itself and
disables when broke, opening it buys exactly one car and names it under the car with no
modal, and a second press cannot buy again. `test_the_present_box_panel_is_anchored_before_it_is_opened`
covers the anchor trap: the world panel already has a `Transform3D` anchor while the box is
still shut, and that anchor is unchanged after opening — a relationship check, not authored
offsets, so retuning the placement can't break it. The purchase LOGIC itself is in
`tests/headless/test_reward_system.gd` (`purchase_car` / `car_price` / `is_stranded`).

`tests/headless/test_menu_flow.gd` — HQ boots to the **exterior title** (one 3D map
pin per rally, a locked special pin non-pickable); **Start flies into the garage**;
tapping the table shows the **map view**; **stars reflect best placement** (1st→3,
3rd→1, unplayed→0); the map table **pans and clamps to its edges**, and a drag does
**not** open the pin under the finger (selection is release + no-drag); tapping a pin
opens the **rally detail**, and Enter flies to the
**car park**, which parks the **whole garage — eligible or not**. A car that cannot enter
is parked and **marked** rather than hidden: focusing it disables Start and puts the
rally's own `RallyLibrary.ineligibility_reason` on the warning label
(`hq_carpark.gd::_refresh_focus_eligibility`), so "why is my car not in the list?" is
answered on the car itself. **There is no auto-switch:** a wrong-drivetrain car used to be
counted as eligible and silently converted at the Start button for the duration of the
rally, then reverted. That is gone — conversion now costs stars per car
([upgrade-catalogue.md](upgrade-catalogue.md) → "Drivetrain conversion"), so a free silent
switch handed the player exactly what the garage charges for; the player converts the car
themselves, where the price is on screen. The rally-detail panel's
`N need a drivetrain conversion to fit` line counts those cars, and Enter is gated on
**owning** a car rather than on one qualifying — walking into a lineup with nothing
eligible is now where you find out why. An open rally parks the whole lineup with **per-car meshes** (a
mixed lineup keeps each body at its true size); cycling focus re-selects the car and
wraps; a **wrecked car is gated in the car park permanently** (Start stays disabled —
there is no repair); an **over-ceiling Rally Challenge car parks with the
over-limit prompt** (looks eligible; Start pops the on-brand modal offering
Cancel / Change Upgrades — Change Upgrades opens the gated shared `UpgradesGrid` to
shed performance permanently, then the
player re-presses Start); **Back** steps car park → table →
garage and clears the lineup; pin → enter →
car → Start launches a session; the **between-event standings interstitial** renders
both the stage-only and cumulative leaderboards stacked on one page (and the
final event's interstitial hands off to the podium on `rally_finished`); the podium
renders the finish summary **and the car reveal + standings**; and the run scene
fields the bound session car. The settings
test also checks the shared `SettingsMenu` exposes a **camera-angle row per mode** and
**persists the chosen angle**. The pure `RallyLibrary.build_standings` ranking and the
enriched `RallySession` result are covered in `test_rally_library.gd` /
`test_rally_session.gd`.

`tests/headless/test_pause_menu.gd` — the **Pause button freezes the game** and opens
the menu; **Resume unfreezes** and closes it; **Settings exposes the shared
`SettingsMenu`** (camera + control rows); **Quit to HQ abandons the active rally** and
unfreezes the game; and **picking a camera applies live** to the `CameraManager` (and
persists). Camera cycling / `set_mode` persistence is covered in `test_camera_manager.gd`.
