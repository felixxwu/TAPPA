# Menus & game-loop shell

**Sources:** `hq.tscn` + `scripts/hq.gd` (`class_name HqController`), the 2D
overlay/menu-layer builders in `scripts/hq_overlays.gd` (`class_name HqOverlays` —
the `build_*_overlay()` methods, split out of `hq.gd` to shrink it; each holds a
back-reference to the `HqController` and reaches into it for state + button
callbacks), `podium.tscn` + `scripts/podium.gd`, plus the session-aware fielding
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

## Menu navigation (keyboard / gamepad)

Every menu is fully navigable with **up / down / left / right / enter / back**, on
keyboard *and* controller, alongside mouse / touch. There are **two regimes**, and
which one a screen uses depends on whether its layout is a flat widget list or a 3D
space:

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
  the **SOLE exit** from the whole standings screen and a strict three-step ladder:
  page 1 → page 2 → reward reveal (if this stage drew one) → resume. This is a
  reorder from an earlier version where the reward sat BETWEEN page 1 and page 2
  — see [global-leaderboards.md](global-leaderboards.md) for why the user asked
  for the swap and what it fixed about page 2's Back button (next paragraph). The
  1st `_advance()` call shows page 2; the 2nd collects the reward if one is
  pending, else resumes the rally via `RallySession.continue_to_next_event()` —
  still the only call site for either. Page 1's action button is now
  unconditionally **"Online leaderboard >"**, since that's the only thing it ever
  does. Page 2 is a sibling `Control` added over page 1 that REPLACES its content
  rather than sitting beside it: page 1's root VBox is hidden — `visible = false`
  — which, because page 2 now always runs before any reward reveal, means page 1's
  root VBox is ALWAYS still there to hide (no more "reveal already tore it down"
  case) — which also makes page 1's
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
  is_instance_valid(_root_box)`, which — with the reorder above — is always true
  in practice, since page 1 is never torn down before page 2 runs); `_on_back`'s
  `if not show_back: return` no-op guard is a defensive backstop for the case,
  not something the current flow exercises.
  `Standings._on_global_back` frees page 2, un-hides page 1, and re-attaches page 1's
  `MenuNav` with focus back on the action button — deliberately NOT re-running page 1's
  row reveal, since replaying a board the player already read is noise.

  **Collect reward on the standings.** On the interstitial of a **non-final event**
  that awarded a per-event upgrade (`RallySession.current_event_upgrade() != ""`),
  **page 2's** action button (not page 1's, which is now always the unconditional
  "Online leaderboard >") reads **`Collect reward >`** instead of `Continue to next
  stage >`. Pressing it clears page 2 and takes over the screen with the shared
  `UpgradeReveal` card (`scripts/upgrade_reveal.gd`) — the **same slot-machine spinner
  as the podium** — which lands on the won part. A won repair kit offers **Repair now /
  Save it** when the driven car is damaged (else it auto-resolves; the drivetrain kit
  auto-resolves too) — but NOT when the driven car is locked by an active Rally
  Challenge run (`DrivingContext.is_car_locked`): repairing it would heal the damage
  that run is contracted to carry across stages, so the reveal takes the plain
  Save-it/inventory path and the kit becomes spendable once the run ends (see
  [rally-challenge.md](rally-challenge.md) → "Car lock"). Every other landing shows an **Upgrades / Next** action row
  (`UpgradeReveal._show_actions`) instead of finishing on its own. **Next**
  (`_on_next_pressed`) is the plain continue — exactly the old immediate
  `finished.emit()`. **Upgrades** (`_on_upgrades_pressed`) builds and opens the SAME
  `UpgradesMenu` component the pre-stage start line / HQ garage use
  ([upgrade-catalogue.md](upgrade-catalogue.md)), fed the driven car and the active
  rally's power-to-weight ceiling (`RallyLibrary.by_id(RallySession.rally_id())
  .restriction.pw_max`) so `UpgradesMenu.bind_close_button`/`request_close` gate the
  **Done** button on the SAME over-limit warning the pre-stage popup shows — no
  bespoke warning logic in the reveal. Closing that overlay (`_close_upgrades`) resumes
  the flow exactly as Next would, so the player is never stranded mid-edit. The
  reveal's own **Next** (or Upgrades → Done) IS the continue step — `standings.gd`
  connects `_reveal.finished` directly to `RallySession.continue_to_next_event`
  (`CONNECT_ONE_SHOT`), so a single press resumes the rally. (There used to be a
  separate host-side **Continue to next stage >** button that only appeared once
  `finished` fired, requiring a second, redundant press with no work happening in
  between — removed; `_action_button` is cleared to `null` for the reveal phase since
  the reveal owns its own action row/focus.) While the reel is actually spinning (real
  play, not headless/instant), a **Skip >** button is shown —
  `UpgradeReveal._on_skip_pressed` fast-forwards straight to the actual won item,
  running the same landing steps a natural finish would. The `UpgradeReveal` wires its
  own `MenuNav` across Skip, the repair Apply/Keep choice, and the Upgrades/Next row
  (no `on_back` — same linear, host-owns-back-but-doesn't-wire-one convention the
  podium reward reveal uses), so the whole flow is keyboard/gamepad navigable. The
  **final event** keeps `Continue to podium >` with no reward step (the podium
  reveals the car). See [reward-system.md](reward-system.md).

  A few flat menus keep their own `_unhandled_input` and attach `MenuNav` **without**
  `on_back`: the **pause** menu (its handler also *opens* the menu when closed, and
  steps sub-page → list → menu, which a plain back callback can't express), and the HQ
  overlays (**title**, **settings**, **Tune/Upgrades**), where `hq.gd._unhandled_input`
  owns `menu_back`. There they lean on `MenuNav` purely for the WASD gap + `FOCUS_ALL`.
  The HQ lift attaches `MenuNav` to the **Tune/Upgrades sub-boxes only** — never the lift
  root — so the diegetic HUB buttons (`FOCUS_NONE`, manual left/right cursor) stay
  untouched. The **Upgrades** page is the reusable `UpgradesMenu` component
  (`scripts/upgrades_menu.gd`, `hq.gd:1007`), which owns its OWN focus-preserving
  `rebuild()` + `MenuNav.attach` (`upgrades_menu.gd:45-72`) — the lift root itself is
  never attached. `UpgradesMenu.rebuild()` runs on every refresh (per car / after an
  option press); it frees only the row children (**not** the `MenuNav`
  child — freeing it would kill WASD/gamepad nav) and re-runs `MenuNav.attach` so the new
  buttons become focusable and its cursor-revive `first` re-seats on a live control. Note
  `UITheme.first_focusable` skips any control in a **dying subtree** (an ancestor
  `queue_free`d this frame) — the rebuild frees whole row containers, whose descendant
  buttons aren't themselves `is_queued_for_deletion()`, so a deferred grab that ignored
  ancestors would land on a doomed button and lose focus next frame. To keep the cursor
  put when an **option press** triggers the rebuild (rather than flinging it to the
  top of the list), each interactive row control carries a stable `upgrade_focus_key` meta
  (`opt:<slot>:<id>`, `drivetrain:<mode>`, `swap`); `rebuild()` captures the focused
  control's key before clearing and `_restore_focus` re-grabs the FRESH control with that
  key afterward (using the same dying-subtree guard so it doesn't grab the about-to-be-
  freed old one).

  The **`start line`** pre-event overlay has three buttons — **Start**, **Upgrades**,
  and **Tune Car** — so it uses `MenuNav.attach(root, {first = _start_button})`
  for keyboard/gamepad focus; a pointer tap on the clear band still launches.
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
  `UpgradesMenu` (see below) — which hosts the **engine-detune slider** (at the bottom) —
  edits re-field the live car via `car.refit_upgrades()`.
  Here `UpgradesMenu` is passed the rally's `pw_max` as `pw_limit`, so the overlay's close
  button reads **Done** and, while the build exceeds the cap, turns red
  (**"Over limit — reduce to N hp/tonne"**) and blocks closing — both the button and Esc /
  back are refused until the player detunes under the cap. The HQ garage lift omits `pw_limit`
  (default `-1`) so the button stays a plain **Back** that closes freely. The detune slider
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
  `hq.gd._process`, glide speed `hq_table_pan_glide`), and selection tracks whichever
  target sits nearest the view centre — a reticle over the map, not a jump between pins.
  The unified target set is every unlocked rally pin plus the two map-swap arrows (each
  arrow present whenever a region exists that way, floating a house-style label like the
  rally-pin readout boxes); the arrows are selected the same way, so gliding to the map's
  edge selects one. `_select_target_under_center()` seats `_table_focus_index` on the
  target nearest `_table_center_pos()` (the fixed table camera's look point offset by the
  live `_table_pan` — `_table_plane_axes` derives on-screen up/right from the camera pose).
  **On entry (`_enter_table`) the map doesn't open dead-centre: it steers straight to the
  toughest event still to beat.** `_focus_hardest_incomplete()` picks the highest-difficulty
  (hidden authored tier) rally pin the player hasn't completed (`Save.rally_completed`),
  ties breaking toward the first in rally order, and pans the camera onto it so selection
  sticks there. Only when every pin is done (or there are none) does it fall back to
  `_select_target_under_center()`.
  Pan is clamped to the map extents, so at an edge the camera simply stops. The selected
  pin gets the hover-style readout underline; a selected arrow glows. `menu_select` fires
  the selected target — a pin opens its rally detail; an unlocked arrow (back arrow, or a
  forward arrow whose region is now reachable) swaps the region and re-seats onto the pin
  nearest that edge; a locked forward arrow (whose region exists but the showdown is not
  yet completed) shows **"Complete showdown to unlock"** on its label and is inert
  (select/click does nothing). `menu_back`
  exits to the garage. Clicking a pin or arrow with the pointer still works (`_on_rally_pin` /
  `_on_arrow_input`), and mouse drag still pans the map (selection re-tracks the centre as it
  slides); the **tuning hub** is a left/right cursor (`_hub_focus`, painted by
  `UITheme.mark_focused`) over **Back / Upgrades / Tuning / Test Drive** (its buttons
  sit side by side in one row), fired with select (`_activate_hub_focus`); the cursor
  seats on Tuning on entry (`menu_back` is also a shortcut back to the garage). **Test
  Drive** (`_test_drive`) launches free roam with the car already on the lift — no car
  picker, since we're already focused on one; it delegates to `_start_free_roam` (see
  below). There is no longer a Change Car button on this row — to work on a different car,
  go back to the garage and reopen the **Garage** picker, which brings up the car park.
  (A **Repair** button also lives on
  this hub row — spend a Repair Kit to fully restore the selected car
  (`_repair_selected_car` / `_refresh_lift_repair_button`) — but it is currently
  **hidden** and left out of the hub cursor while earning Repair Kits is disabled; see
  `todo/remove-repair-kits.md`.) **Wheels** no longer lives on this hub row — it's a
  button inside the **Tuning** page itself (`tuning_panel.gd`, `TuningPanel._wheels_button`,
  native `FOCUS_ALL` matching the panel's sliders), wired via a `setup(owned_car,
  on_change, on_wheels)` callback the lift passes as `_enter_wheel_swap`; the start-line's
  copy of the same panel (`start_line.gd`) passes no `on_wheels`, so `TuningPanel` hides
  the button there (a no-op button would be confusing pre-rally). The **garage** is likewise a
  left/right cursor (`_garage_focus`, painted by `UITheme.mark_focused`,
  `_activate_garage_focus`) over its side-by-side **Back / Career / Garage / Free Roam /
  Challenge** row, seated on Career on entry (`menu_back` shortcuts to the exterior).
  **Garage** (`_open_garage_picker`) opens the car park in GARAGE mode (`CarparkMode.GARAGE`,
  parking the whole owned collection); Select (`_on_start_pressed` → `_select_garage_car`)
  commits the focused car as the selected car and drops straight into the tuning lift bay
  for it, while Back returns to the garage. **Free Roam** (`_enter_free_roam`,
  `CarparkMode.FREEROAM`) parks the WHOLE catalogue as base-model previews (`_all_car_previews`,
  owned or not); Start (`_start_free_roam` → `_launch_free_roam`) drops into a session-less
  drive in the picked car — an owned car fields its tuned instance, a not-yet-owned preview
  fields the base model via `RallySession.free_roam_model_id` (see the free-roam machinery
  below and `world.gd`) — Back returns to the garage. **Settings no longer lives on this
  row** — it moved to the title screen (see the EXTERIOR section below), since Settings
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
  the visibility chain), `_go_to` / `_lift_hub` call `get_viewport().gui_release_focus()`
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

`AccountMenu` is the optional cloud-save UI — one builder with **two hosts**,
the same arrangement `SettingsMenu` uses: a category page inside Settings
(`show_account`), and a standalone modal overlay from the title screen
(`hq.gd::_open_account_overlay`). It exposes `at_root()` / `go_back()` so both
hosts treat its sub-forms exactly like Settings sub-pages —
`SettingsMenu.go_back()` gives it first refusal before backing out of the page.
See [cloud-save.md](cloud-save.md).

## ConfirmPopup (`confirm_popup.gd`)

A reusable on-brand confirm modal for blocking decisions — a full-screen **dim
mouse-consuming backdrop** (`MOUSE_FILTER_STOP`, swallows clicks) + **centred house
`UITheme.panel`** with a title, an autowrap body, and one button per action. Each action is
a dict `{ "label": String, "callback": Callable, "disabled": bool (optional) }`. When an
action's button is pressed, the popup dismisses and runs its callback; Back routes to the
configured action (default: the last one — the dismiss convention).

**Contract:** `ConfirmPopup.open(host, title, body, actions, default_index := 0, back_index := -1, allow_stack := false) -> ConfirmPopup` — **returns `null` when refused; callers must not assume a popup came back.**

- `host` — parent Node to attach under (its process mode is inherited — a paused host's
  popup still processes).
- `title` / `body` — confirm header + message text.
- `actions` — Array of action dicts; disabled actions are greyed and unselectable.
- `default_index` — 0-based index to focus on open (defaults to 0, falls back to first
  enabled if the default is disabled).
- `back_index` — 0-based index of the action to fire on Back / cancel (defaults to the
  last action — the dismiss convention). A negative `back_index` (-1) dismisses without
  firing any callback.

The popup **builds its own CanvasLayer** under `host` (layer 101, above overlays), so it's
independent of the hosting scene. It's **MenuNav-wired** (keyboard + gamepad navigable),
emits `finished`, and **`queue_free`s on dismiss** — the host doesn't track it. **New
confirm dialogs should use `ConfirmPopup.open()` instead of Godot's native
`ConfirmationDialog`**, which is unstyled and not `MenuNav`-wired. Examples: the **pause
menu quit-to-HQ confirm** (`PauseMenu`), HQ **engine-swap confirms**, and HQ **detune-to-enter confirm** (over-powered car).

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

Covered by `test_confirm_popup.gd` — joins the group, a second popup is refused, a
*different host* is refused, a popup being freed does not block its replacement,
`allow_stack` gets through, and the exclusivity holds in both directions between the
two popup kinds.

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
`_go_to(view)` tweens the single `Camera3D` between their poses
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

**EXTERIOR (boot/title).** A side-by-side row of **Start / Account / Settings** and —
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
`_car_cache` for every parked car so the garage picker and tuning lift (above) start
from a hit, not a cold build.

**A car that fails to spawn must never hang boot forever (regression, fixed).**
`_spawn_lineup_progressive` (`hq.gd`) loops `_obtain_parked_car` → `_spawn_parked_car`
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
and the test double `tests/headless/hq_null_spawn_double.gd`. The title camera is a **low, near-ground front-3/4 hero shot** posed ~45° off
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
(index 0) every time `_go_to(View.EXTERIOR)` runs. Start (`_on_exterior_start`) flies the
camera into the garage; **Account** (`_open_account_overlay`) opens the optional-cloud-save
modal — it sits right after Start (a player reinstalling or moving devices needs it
*before* starting a fresh career, so burying it in Settings would be the wrong place);
**Settings** (`_open_settings(false)`) opens the shared camera/controls page — it moved
here from the garage action row (see the GARAGE section above), and because it now only
ever opens from the title, backing out of it (`_on_settings_action`) always returns to
EXTERIOR, never the garage; **Exit Game** (`_on_exterior_exit` → `get_tree().quit()`)
quits the app — it's built only on non-web builds, since a browser tab owns its own
lifecycle. (Free roam is reached via the tuning bay's Test Drive button, not here.)

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
- **Dev** — a debug page: **Wipe all progress** (`Save.reset_new_game`, back to a
  fresh new game — and, when signed in, `Cloud.publish_local_wipe()` so the cloud
  copy is cleared too, otherwise the next pull restores everything and the wipe
  undoes itself; see `features/cloud-save.md`), **3-star all rallies** (`Save.dev_three_star_all_rallies`, unlocks
  every region), plus one button per car (`Save.grant_car`, from `CarLibrary.CARS`)
  and per upgrade (from `UpgradeLibrary.UPGRADES`) to unlock anything in the game.
  **Complete rally (win now)** appears ONLY while a rally is active (i.e. from the
  in-run pause menu, gated on `RallySession.is_active()`): it unfreezes the tree and
  calls `RallySession.dev_complete_rally`, which credits every event a perfect 0 ms
  time, resolves to a P1 (top-3) finish, and routes straight to the podium — so the
  player collects the car reward without driving the stages.
  Upgrades are car-bound, so a slottable part **fits straight onto the selected car**
  (`Save.install_upgrade` — no-op with a "own a car first" note when nothing's owned);
  only the repair kit, the one true consumable, still goes to the inventory
  (`Save.add_item`). A status line reports the last action.

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
spawned whenever the camera is inside — garage/lift — and dropped otherwise). Like the
car park, the lift prop is **reused only while both its instance id and a deep
`owned.hash()` match** — so any in-place data change to the selected car (repair, upgrade
toggle, engine swap, tuning) auto-respawns the prop; no mutator has to force a rebuild.

The lift and the car park **share the same `_car_cache`** (`hq.gd` → `_spawn_lift_car`
checks `_car_cache` before building, exactly like `_obtain_parked_car`): a car already
warmed by the parked lineup — the garage picker you just came from, the title screen, or
Free Roam — is *borrowed* onto the lift by reconfiguring its transform/process-mode
rather than paying `CarProp.spawn` again (the expensive step: `car.tscn` embeds every
car glb, so instantiating it — even to immediately prune 8 unused bodies — is the "small
lag every time the tuning-lift car changes"). `_clear_lift_car` returns the favour: if
the departing lift car is the node `_car_cache` tracks for it, it's hidden + stowed
(same pattern as `_release_page_props`), never freed, so the next parked-lineup build or
lift visit reuses it. GARAGE/LIFT and CARPARK are mutually exclusive views, so handing
the one live node back and forth between the two contexts is safe — but it means
`_ensure_lift_car`'s id/hash "already there, no-op" fast path must also check
`_lift_car.visible`: the garage picker (`_open_garage_picker`) borrows the lift's node
into its parked lineup without going through `_go_to` (so `_clear_lift_car` never runs
while the picker is open), and `_select_garage_car` hides + stows that lineup
(`_clear_lineup`) on the way back to the lift — so reselecting the SAME car used to hit
the id/hash match while the shared node was still stowed off-screen, vanishing from the
lift instead of staying shown. Requiring `.visible` too forces the fall-through spawn
path, whose cache hit just repositions the node back onto the lift. See
[tuning.md](tuning.md) → *The tuning lift (UI)*. In the
garage the car rests **lowered on the ground** at its calculated settled ride height
(`car.gd` → `settled_ride_height`; see [tuning.md](tuning.md)).
Tapping the table drops to the map view; tapping the lift flies to the **tuning bay**
(LIFT view) for the currently-selected car. A HUD hint + Back (to the exterior) +
convenience buttons sit on top: the garage station row is **Back / Career / Garage /
Free Roam / Challenge**. **Garage** (`_open_garage_picker`) opens the **car park** to pick
which owned car to work on, then drops into the tuning bay for it (see below); **Free
Roam** (`_enter_free_roam`) opens the car park across the WHOLE catalogue for a
session-less drive in any car (owned or not). Because `car.tscn` embeds **all** the
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
looks at the title shot. If the player opens Free Roam *before* it finishes, nothing is
lost: `_obtain_parked_car` reuses whatever is warm and builds the remainder on the spot
(the old first-entry cost, for that remainder only), and the deferred loop skips those on
its next frame. (The underlying cost is that each car still *instantiates* all
embedded bodies before pruning; a deeper fix — lazy per-model body loading in `car.tscn` —
is noted but not yet done.) Settings no longer lives on this row — it's on the title
screen now (see the EXTERIOR section above). (A **Repair** button lives on the
tuning-lift hub row, spending a **Repair Kit** for a full restore via
`_repair_selected_car` / `_refresh_lift_repair_button`, but is **hidden** for now while
earning kits is disabled — see `todo/remove-repair-kits.md`.)

**LIFT (the tuning bay).** Entering the bay **raises the car on the lift** — a slow
tween from the lowered (garage) pose up to `hq_lift_car_height` over
`hq_lift_raise_time` (`_apply_lift_height`); returning to the garage lowers it again.
The car is framed to one side (`hq_lift_cam_*`). The bay opens on a **HUB page**
(`LiftPage.HUB`): a **bottom** panel with the **car's name/description** spanning the
full page width, and UNDER it **Upgrades** and **Tuning** buttons plus a
**Test Drive** button (the hub's left/right `ButtonCursor` — `_hub_focus` — no longer
carries Wheels; see below). To put a **different** car on the lift, go **Back** to the garage and reopen the
**Garage** picker (`_open_garage_picker`, GARAGE mode): the whole owned collection is
parked, and **Select Car** (`_on_start_pressed` → `_select_garage_car`) sets the
**selected car** (`Save.set_selected_car`) and enters the bay for it, spawning it on the
lift — a wrecked car is pickable too (it can sit on the lift to be repaired). **Test
Drive** (`_test_drive`) launches free roam with the car already on the lift — no picker,
delegating to `_start_free_roam`. Each menu button opens that menu as its **own full-height
page** — a solid panel **centred horizontally** and wide
(`hq_lift_menu_centered_width_frac`, using most of the screen); the car-description
panel **hides** while a sub-menu is open so the page has room — with a **< Back** that
returns to the hub; the hub's own Back returns to the garage. Because the hub controls
and page chrome live on the hub, each menu page gets the **full panel height to
itself** and doesn't need to scroll. The two pages:

### Upgrades / Tune panel width

The panel's actual content width is NOT `hq_lift_menu_centered_width_frac * window
width` — it's that fraction of the **logical UI canvas**, which `scripts/display_stretch.gd`
lays out at `DisplayStretch.DESIGN_HEIGHT * window_aspect / Config.data.horizontal_stretch`
(a real per-instance `content_scale_size`, not the raw window). `horizontal_stretch`
(authored ~1.2) is a purely visual anamorphic widening applied via the stretch system,
and it SHRINKS the logical canvas UI actually lays out against — any width measurement
that skips the `/ horizontal_stretch` step overstates available space by that same
factor. At the narrowest supported aspect (4:3, `project.godot`'s
`window_width_override`/`window_height_override` = 1280×960), the true content width is
tight enough that a busy row (`upgrades_menu.gd`'s WEIGHT slot: Stock + several parts,
with the selected option bracketed — `_option_button` wraps the label in `[...]`, adding
width to whichever option happens to be selected) needed more room than the shared
`theme/ui_theme.tres` Button style's 14px content margins left, even at
`hq_lift_menu_centered_width_frac` maxed to 1.0. The fix (see `_tighten_option_padding`
in `upgrades_menu.gd`) duplicates each option button's stylebox with a smaller
left/right content margin scoped to just these multi-option selector buttons — not the
shared theme — rather than continuing to chase the panel's width_frac upward, since frac
alone tops out below what the row needs at true 4:3. When re-measuring this by hand,
always go through `DisplayStretch.logical_size()` (or an equivalent `/ horizontal_stretch`
step) and replicate the actual worst-case selected/bracketed option — a measurement that
skips either one will look fine in a throwaway test and still wrap in the real game.

- **Tune** (`LiftPage.TUNE`) — a slider per handling tuning axis (grip / brake-bias /
  aero; aero is greyed with a "needs Aero Kit" note until the kit is fitted — grip and
  brake bias are always tunable) plus **Reset to neutral** (which
  clears only the handling axes and **preserves** engine detune); each change saves via
  `Save.set_tuning`. The engine-detune slider is NOT here — it moved to the **Upgrades**
  page's `UpgradesMenu` (detune is a power / power-to-weight knob, not a handling axis).
  The slider holding the cursor lights up (its row wraps in a panel painted by
  `UITheme.mark_panel_focused` on `focus_entered`/`focus_exited`) so it's obvious which
  is selected, and left/right nudges it in place (see the `MenuNav` slider note above).
  No page title/subtitle — the sliders take the full height.
- **Upgrades** (`LiftPage.UPGRADES`) — the reusable `UpgradesMenu` component
  (`scripts/upgrades_menu.gd`): one earn-gated **option selector per slot** — "Stock"
  plus one button per catalogue part in that slot, each part greyed until its kit is
  fitted to this car and the active pick bracketed **and painted accent-green**
  (`Save.set_upgrade_enabled`; free,
  instant, at most one enabled per slot — picking one switches off a same-slot sibling).
  The drivetrain slot is an RWD/AWD/FWD picker instead. The **weight slot** has its own
  bespoke selector (`_make_weight_selector`): options ordered heaviest→lightest with
  **Stock in the middle** (`+500kg  +200kg  [Stock]  -200kg` for a ~1000 kg car), each
  button labelled by its mass delta off the car's base mass (rounded to the nearest
  100 kg, signed, `kg` suffix). The two ballast options are **free** (always enabled)
  while the lightweight (Weight Reduction) option **greys until earned**; picking a free
  ballast the car doesn't own installs it on the spot, Stock disables all weight parts.
  Nothing is consumed from an
  unlocked pool — upgrades are car-bound. It also hosts the **engine-detune slider**
  (0–100%, step 5) at the **bottom** of the menu (below the slot rows and the engine-swap
  row) — detune lives here rather
  than on the Tune page because it's a power / power-to-weight knob (saved via
  `Save.set_engine_detune`; see [engine-swap.md](engine-swap.md)). There is no stats line;
  the live power-to-weight readout rides on the detune slider's value label. Focus keys are
  `opt:<slot>:<id>`, `drivetrain:<mode>`, and `swap`.
  **`UpgradesMenu.setup(owned, on_change, on_swap, pw_limit)`** takes an optional
  `pw_limit` (power-to-weight cap in hp/tonne); when set ≥ 0, the overlay's **close button
  is gated** (`bind_close_button` + `request_close` / `can_close`): it reads **Done**, turns
  red with **"Over limit — reduce to N hp/tonne"** and blocks closing (button + Esc / back)
  while the live build exceeds the cap. The detune value label always shows just
  `N% - M hp/tonne` (no cap text). Used by the start-line upgrades overlay (with
  the rally's `pw_max` limit) and the HQ car-park Change-Upgrades / detune modal (with
  the rally's limit); the HQ garage lift omits it so the button stays a plain **Back** and
  the player upgrades freely.
  (Repair is **not** here — it lives on the **tuning-lift hub row** as a
  `Repair` button, `_repair_selected_car`.) Below the slot rows sits an
  **engine-swap row** (`UpgradesMenu._make_engine_swap_row`, `upgrades_menu.gd:215`): the
  car's current engine name and a **Swap Engine** button gated on engine-swap **tokens**
  (NOT on HP). The swap lineup (`_swap_targets`) is **every other owned car regardless of
  health**; the button is disabled with a tooltip when there's no other car OR no token
  held, and enabled ("Swap Engine (N tokens)") otherwise. Pressing it opens the car park
  in **swap mode** (`_enter_engine_swap` / `_carpark_swap_mode`), where the normal car-park
  cycle/confirm/back flow exchanges the two cars' engines (`Save.swap_engines`) and returns
  to this page. See [engine-swap.md](engine-swap.md).
  The wreck-recovery safety net (`Save.ensure_repair_safety_net`, a free kit when all
  owned cars are wrecked + none held) runs on save load, on garage entry, and on
  `_refresh_lift_ui`; the garage Repair button's label surfaces the resulting kit count.
  Both sub-pages share one **`< Back`** button (`_lift_back_button`, returns to the hub)
  that sits in the page `root` **below** the scroll container — a different node level
  from the tune/upgrades body — but it's `FOCUS_ALL`, so `menu_down` off the last body
  control reaches it by geometry (the box `MenuNav`s move focus across container
  boundaries). It's also the focus fallback (`_grab_lift_page_focus`) when a page body
  has no focusable control at all — a fresh car's Upgrades page (all slots empty, full
  health, Swap Engine disabled) — so the page is never dead to keyboard/gamepad.

`_refresh_lift_ui` toggles which face (hub vs. a menu page) is shown from `_lift_page`.
See [tuning.md](tuning.md) for the underlying config pipeline.

**TABLE (the 3D world map).** A zoomed-in, near-top-down look at the table's flat map
plane — a **square** table top (`hq_table_size`/`hq_map_plane_size` are equal in
X/Z) surfaced with a **satellite map photo** (`textures/map_table.jpg`, an unshaded
albedo texture so the aerial colours read true under the garage lighting). The table
now shows one **region** at a time: two diegetic **left/right arrows**
(`HQEnvironment.arrow_left`/`arrow_right`) on the table's side edges. Each arrow floats
a house-style label (like the rally-pin readout boxes): **"Change map"** on the back arrow
and on an unlocked forward arrow (whose region the player has reached), and
**"Complete showdown to unlock"** (dimmed) on a forward arrow whose region exists but the
showdown is not yet completed. An arrow is absent only when no region exists that way.
Unlocked arrows swap the **viewed** region — clicked/tapped (`_on_arrow_input`), or landed
on by the spatial cursor and fired with `menu_select` (the arrows are focus targets in the
same nav set as the pins; see the map-table nav description above), clamped to the
furthest region the player has unlocked (`hq.gd._swap_region`/`_furthest_unlocked_index`).
Locked arrows are shown but inert (select/click does nothing). Swapping re-textures the
map plane to the region's `map_image` and rebuilds pins from only that region's rallies.
See [regions.md](regions.md) for the full region-swap + unlock model. Every
rally in the viewed region is a 3D **pin** (`_make_pin`) at its normalised `map_pos`: a
**state-driven flag marker** (`RallyFlag` — a small **base disk** the pin
stands on + a pole + waving pennant + finial bead) topped by a **billboarded design-system black box** (`_build_pin_label`) that
holds the rally name and a row of proper **five-pointed stars** — 1st-place best = 3
gold, 2nd = 2, 3rd = 1, else dim (`_stars_for`). The box is a real `UITheme` panel
(pure-black, Syne Mono, uppercase) composited in an off-screen `SubViewport` and shown
on a `Sprite3D`, so text and stars live in **one box** that always faces the camera;
the stars are drawn by **`StarRow`** (`scripts/star_row.gd`) as polygons, sidestepping
the font's missing ★/☆ glyphs (same reason the UI uses ASCII `<`/`>` for nav). The
flag encodes the rally's state on **two axes** (`RallyFlag.pennant_kind` /
`RallyFlag.accent_color`). **Pennant:** placed 3rd or better → a **black-and-grey
checkered** racing flag; else **bright green** when the player owns a car eligible to
enter (`_has_eligible_car`); else **dark grey** (no qualifying car — also the locked
showdown). **Tip + base** (the finial bead and base disk, always one colour): **warm
gold** once the rally is **won** (1st place, 3 stars), **metal grey** otherwise. A
rally that isn't available yet (locked, or no eligible car) also **dims its floating
readout box** (`PIN_LABEL_DIM`) so the whole pin reads as disabled. The
stars in the box remain the exact readout. Each
unlocked pin carries **two** pickable `Area3D` hit spheres bound to the same handler
(`_add_pin_hit`, rally id bound) — one over the flag/pole and one over the floating
**readout box itself**, so a click on the menu enters the rally just like a click on
the flag — plus its `rally_id`/`locked` in metadata; a pin is grey + **non-pickable**
whenever it isn't **revealed** yet (`RallyLibrary.rally_revealed`): the **showdown** until
every other rally in its region is completed, and any rally whose **`reveal_after`**
(intra-region reveal order) hasn't been met — a "coming up" hint so a region reveals
~1–2 fresh rallies at a time rather than all at once. A progress meter sits on the HUD. **Drag to pan** the map (mouse, or
finger via `emulate_mouse_from_touch`): `_pan_table` shifts the camera in the table
plane, clamped to the map extents (`hq_table_pan_speed`). Pin selection fires on
**release** and only if the press wasn't a drag (`_table_dragged`), so panning never
opens the pin under the finger. **Crucially the station overlays are made
pass-through** (`_passthrough_overlay` sets every non-button control to
`MOUSE_FILTER_IGNORE`) — otherwise the full-rect HUD container/labels/spacer (all
default `STOP`) would swallow every touch and the 3D pins would never get a pick.
Tapping a pin opens the **rally detail** sub-panel — a **single-column card** built
in `build_detail_overlay` (`hq_overlays.gd`) / populated in `_show_detail`. Header:
rally name **with the stage count appended** (`"Coastal Sprint - 3 stages"`, singular
"stage" for a one-stage rally), region tag, and a gold **SHOWDOWN** chip on showdown
rallies. There is deliberately **no per-stage breakdown** — the old left-hand STAGES
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
rally** (`RallyLibrary.is_eligible`) — plus any **over-powered** car a detune
would qualify (below) — are parked at `GameConfig.hq_carpark_origin`,
in a **centred row ALONG X** — one car per painted bay (`menu_car_spacing` wide), with
fewer cars than bays centred within the grid — each **parked nose-out toward the
courtyard / menu camera (+Z)** so the camera frames its front with the garage behind;
each is a silenced `Car` prop (reusing `Car.apply_owned`). The exterior/title camera is
shifted by `menu_car_park_offset` (the same lot-centre offset) so it stays centred on
the row. Parking is shared with the title via `_build_lineup(cars)` — the car-select
screen passes the eligible cars, the title passes all owned — or, for a fresh player
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
same `_settle_generation` id so re-entering the lot — or backing out — abandons a
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
garage picker, engine-swap, starter, Free Roam, title), **evicts** entries for cars no
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
**too damaged to enter**: Start is disabled and a warning explains why; if a **Repair
Kit** is owned, a **Repair (1 kit)** button fully restores it (`Save.use_repair_kit`)
and unlocks Start. An **over-powered** focused car — its p/w sits over the rally's
`pw_max` cap but detuning the engine would duck it under — still parks
(`_build_eligible_lineup` records its qualifying tune from
`RallyLibrary.qualifying_detune` in `_detune_needed`) and **looks eligible** — no
warning label, the plain enabled Start (saves overlay space). Pressing Start pops an
**on-brand modal** (`_show_detune_confirm` → `_make_carpark_modal`: a full-screen
dimmer + centred house `UITheme.panel`, NOT a native grey dialog) with a short
"Too powerful" message and **two left/right-navigable buttons**: **Cancel** and
**Change Upgrades**. **Change Upgrades**
(`_detune_change_upgrades`) opens the **Change-Upgrades popup** — the shared
`UpgradesMenu` component (see [upgrade-catalogue.md](upgrade-catalogue.md)) in a
matching centred modal (`_show_upgrades_popup`, engine-swap row dropped, passed the
rally's `pw_limit`) so the player can strip / switch parts — or use the menu's own
**engine-detune slider** (at the bottom of the menu) — to shed power. Because the popup
is passed the rally's `pw_limit`, its close button is the gated **Done** (red,
**"Over limit — reduce to N hp/tonne"**, blocking both the button and back) until the
build is under the cap; closing it
(`_close_upgrades_popup`) rebuilds the eligible lineup if anything changed, and the
player re-presses Start (**close → re-press**, no auto-launch). Both modals are wired with `MenuNav.attach` (the upgrades popup
hands its gated `request_close` as `on_back` so Esc is gated too), and `_carpark_modal_open` makes `_unhandled_input` hand navigation to the
modal instead of the lineup beneath. The fix the player makes in the upgrades menu is
an ordinary garage edit and **persists after the rally** — there is no longer a
temporary, per-rally, auto-reverted detune here (the old **Detune to N%** button and
its `RallySession.register_detune_revert` agreement are gone). Rallies gate p/w as a
**band** (`pw_min`..`pw_max`), and the **floor is judged at the car's MAX potential**
(`UpgradeLibrary.max_potential_meta`: 100% engine tune + every *installed* upgrade
enabled + freely-removable **ballast dropped** — never inventing un-installed parts),
passed to `RallyLibrary.is_eligible` as its `floor_meta`. So a car that's merely detuned,
has parts toggled off, or is carrying ballast the player can shed is **eligible** as long
as maxing it out clears the floor — the player will tune up to enter, the mirror of an
over-cap car detuning down. A car whose max potential is still under the floor is
**ineligible outright** (the old soft "underpowered" warning and the "N underpowered for
the class" detail caution are retired — there is no eligible-but-underpowered state now).
The map pin's green "raceable" pennant counts every owned in-band (or tunable-into-band)
car (`_has_eligible_car` builds on `_entry_plan`). Rivals field only in-band cars: the
opponent field is drawn from `RallyLibrary._eligible_cars` (the restriction's in-band
pool). A **banner** names the rally + restriction; **Start** records the
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
is the same machinery for rally car-select, the garage picker, engine-swap, the starter
picker, Free Roam and the title backdrop, so they all page identically.

Star ratings come from `Save.best_placement(rally_id)` — the best (lowest)
finishing position ever recorded there, stored by `Save.complete_rally(id, ms,
placed)` on each top-3 finish (`RallySession` passes the placement).

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
This is deliberately **not** `recovery_pose()` (which the off-track leash / stuck
watchdog use): that pose is pinned to the *furthest* offset reached and freezes the
moment the car leaves the leash, so a strayed car would reset to a stale point that's
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
3. **CAR_REVEAL** (only if `car_reward != ""`) — the camera **flies over to the
   showroom** and a slot-machine reel spins through the car catalogue's
   names, decelerating onto the won car; on the lock-in the car appears on the
   showroom turntable (hidden until then) and the card collapses to a **single
   line**: the big slot label hides and the caption alone carries
   `"<car> (NEW) — delivered to your garage"` (the `(NEW)` tag only when first
   owned), so the name isn't shown twice.

**Upgrades are no longer revealed on the podium** — the per-event upgrades are
awarded and revealed on the between-event **standings** screens (see the
Collect-reward flow above and [reward-system.md](reward-system.md)); the podium
closes on the car reward only.

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
`upgrades` (the per-event ids won, revealed on the standings not here), `car_reward`, `car_reward_is_new`, and
`showdown_won` alongside the original `placed`/`completed`/`combined_ms`/`dnf`.

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

`tests/headless/test_menu_flow.gd` — HQ boots to the **exterior title** (one 3D map
pin per rally, showdown pin locked + non-pickable); **Start flies into the garage**;
tapping the table shows the **map view**; **stars reflect best placement** (1st→3,
3rd→1, unplayed→0); the map table **pans and clamps to its edges**, and a drag does
**not** open the pin under the finger (selection is release + no-drag); tapping a pin
opens the **rally detail**, and Enter flies to the
**car park** which **filters to the eligible cars** (an AWD car is excluded from an
RWD-only rally); an open rally parks the whole lineup with **per-car meshes** (a
mixed lineup keeps each body at its true size); cycling focus re-selects the car and
wraps; a **wrecked car is gated in the car park** (Start disabled, then a Repair Kit
restores it to full health and unlocks Start); an **over-powered car parks with the
detune-to-enter prompt** (looks eligible; Start pops the on-brand modal offering
Cancel / Change Upgrades — Change Upgrades opens the gated shared `UpgradesMenu` to
shed power permanently via the detune slider / ballast / stripping parts, then the
player re-presses Start); **Back** steps car park → table →
garage and clears the lineup; pin → enter →
car → Start launches a session; the **between-event standings interstitial** renders
both the stage-only and cumulative leaderboards stacked on one page (and the
final event's interstitial hands off to the podium on `rally_finished`); the podium
renders the finish summary **and the reward reveal + standings**; and the run scene
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
