# Menus & game-loop shell

**Sources:** `hq.tscn` + `scripts/hq.gd`, `podium.tscn` + `scripts/podium.gd`,
plus the session-aware fielding in `scripts/world.gd`. See the full design in
[../todo/menus.md](../todo/menus.md).

This is the **diegetic 3D build** of the menu shell: HQ is one continuous 3D space
the camera flies through (an exterior title shot, a garage interior, the map table,
and the outdoor car park) rather than flat overlay screens. It still closes the
whole meta-game loop — pick a rally on a 3D map, choose an eligible car in the car
park, run it, see the podium — and wires [rally-session.md](rally-session.md) into
the run scene. The podium + between-event standings are still flat scenes (the 3D
reward rig / podium are later refinements); remaining diegetic polish (tuning UI,
per-car paint, camera fly-throughs *between* far stations) lives in
[../todo/diegetic-hq.md](../todo/diegetic-hq.md) / [../todo/menus.md](../todo/menus.md).

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
  no fragile `project.godot` surgery; (4) routes **both** `ui_cancel` **and** `menu_back`
  to `on_back` (omit it and the host keeps its own back handling). `MenuNav` goes inert
  while its `root` is hidden — including a hidden `CanvasLayer` ancestor (how HQ toggles
  overlays), which `Control.is_visible_in_tree()` alone misses — so a hidden overlay never
  steals input from the station behind it.

  `ui_accept` fires the focused control and the **focus highlight is the theme's `focus`
  stylebox**, which `tools/build_ui_theme.gd` defines to match the **hover** look — so a
  focus cursor and a mouse hover read identically (see [ui-design-system.md](ui-design-system.md)).
  `UITheme.focus_grab(ctrl)` is the guarded, call-deferred grab helper (grab a specific
  control); `UITheme.focus_grab_first(root)` / `UITheme.first_focusable(root)` seat the
  cursor on the first focusable control under a root (shared by `MenuNav` and HQ's
  native-focus pages). `MenuNav` covers: the **title** (Start/Settings),
  the shared **`SettingsMenu`** (rows + bottom action button — used by both the HQ
  settings overlay and the pause menu), the **pause** menu (Resume/Settings/Quit),
  the HUD **finish panel**'s single `NEXT` button (`StageCompletePanel`, attached in
`hud.gd._ready` with `first = NextButton`; re-grabs focus whenever the panel is
shown, so `ui_accept` proceeds to the results flow — [hud.md](hud.md),
[stage.md](stage.md)), the **standings** interstitial's single action button —
`FOCUS_ALL`, re-grabbed via
  `UITheme.focus_grab` both when the scene first opens and again every time
  `_build_ui()` rebuilds for a page switch (event page ↔ combined page), so the
  cursor never drops when the button text/target changes — the **podium** Next, and
  the tuning-lift **Tune** (sliders — left/right nudges the focused one) and
  **Upgrades** (install / repair) pages. On the standings interstitial specifically,
  the `MenuNav` `on_back` callback (`_on_back_pressed`) steps **back** from the combined
  page to the event page — but only when there's an event page to return to (2+ events
  completed); on the first event (combined-only) and while showing the event page
  itself, back does nothing (there's nowhere to go). Standings re-runs `MenuNav.attach`
  on every `_build_ui()` rebuild; `attach` reuses the existing node rather than stacking
  handlers, and re-seats the cursor on the freshly-built button.

  A few flat menus keep their own `_unhandled_input` and attach `MenuNav` **without**
  `on_back`: the **pause** menu (its handler also *opens* the menu when closed, and
  steps sub-page → list → menu, which a plain back callback can't express), and the HQ
  overlays (**title**, **settings**, **Tune/Upgrades**), where `hq.gd._unhandled_input`
  owns `menu_back`. There they lean on `MenuNav` purely for the WASD gap + `FOCUS_ALL`.
  The HQ lift attaches `MenuNav` to the **Tune/Upgrades sub-boxes only** — never the lift
  root — so the diegetic HUB buttons (`FOCUS_NONE`, manual left/right cursor) stay
  untouched.

  The **`start line`** and **`wreck screen`** are *press-anything-to-continue* screens
  (a tap anywhere, or `menu_select` = Enter / gamepad A, proceeds), not multi-item
  navigable menus, so they don't use `MenuNav` — there is nothing to navigate.
- **Diegetic 3D HQ stations** can't be a focus graph — "left/right" means *cycle the
  3D car / fly the camera*, not "move focus to the neighbour widget" — so they keep
  HQ's bespoke **`menu_*` action** handlers in `hq.gd._unhandled_input` (the
  `menu_left`/`menu_right`/`menu_up`/`menu_down`/`menu_select`/`menu_back` actions,
  which bind arrows + WASD + D-pad + Enter/Esc + gamepad A/B). The **car park** /
  **overflow** cycle the focused car with left/right and Start/Scrap with select; the
  same lineups are also **pointer-navigable** (`_lineup_pointer_input`, shared by both
  stations): a horizontal **swipe** (mouse drag, or finger via
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
  the
  **map table** carries a **keyboard pin cursor** (`_table_pin_index`) that cycles the
  unlocked pins (left/right or up/down, wrapping), highlights the selected pin's
  readout box with the same hover-style lift a menu button gets (`UITheme.mark_panel_focused`
  — all pins stay one size, no scale-up), centres the camera on it, and opens its detail
  on select; the **tuning hub** is a left/right cursor (`_hub_focus`, painted by
  `UITheme.mark_focused`) over **Back / Change Car / Tuning / Upgrades** (its buttons
  sit side by side in one row), fired with select (`_activate_hub_focus`) — Change Car
  drops into the car park in change-car mode; the cursor seats on Change Car on entry
  (`menu_back` is also a shortcut back to the garage). The **garage** is likewise a
  left/right cursor (`_garage_focus`, painted by `UITheme.mark_focused`,
  `_activate_garage_focus`) over its side-by-side **Back / Career / Tune Car / Free Roam**
  row, seated on Career on entry (`menu_back` shortcuts to the exterior). Both of these
  manual rows share a small **`ButtonCursor`** helper (`scripts/button_cursor.gd`):
  `hq.gd` keeps the index (`_garage_focus` / `_hub_focus`), the cursor owns the shared
  wrap / repaint / fire behaviour, and each button's `pressed` callable is also the
  cursor's action for that index, so a mouse click and a keyboard/gamepad select can
  never fall out of step. (The map-table pin cursor stays bespoke — it paints a
  billboarded pin panel and pans the camera, not a flat button row.) **Free Roam**
  (`_enter_free_roam`) opens the car park in FREE-ROAM mode (`_carpark_freeroam_mode`,
  parking the whole owned collection); Start (`_start_free_roam`) hands the picked
  instance to `RallySession.free_roam_instance_id`, writes a fresh random seed + neutral
  (0.5) terrain settings into the live Config (`_prepare_free_roam`), and loads the run
  scene with NO active `RallySession`. `world.gd` fields that owned car (falling back to
  the default library car) and skips the rally/start-line/podium wiring; the player
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

## HQ (`hq.gd`)

The boot scene (`project.godot` `run/main_scene`), a lightweight **`Node3D`** (no
track generation). A first-time player (no `starter_picked`) is **not** auto-granted
a car: pressing **Start** on the title routes them into the car park's
**starter picker** (`_enter_starter_pick`, `_carpark_starter_mode`) showing the three
authored-body cars (MX-5, Focus, Twingo) as preview cars from `CarLibrary`; choosing one
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
`enum View { EXTERIOR, GARAGE, TABLE, LIFT, CARPARK, SETTINGS, OVERFLOW }` names the camera **stations** and
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
white bay dividers (one bay per `max_owned_cars`, `menu_car_spacing` wide) generated
procedurally as an `ImageTexture` (`_carpark_bay_texture`), so each parked car sits in
its own marked bay.

**EXTERIOR (boot/title).** A **Start** button and a **Settings** button over an
establishing shot of the outdoor car park, with a block skyline **behind the
garage** and trees framing the lot. The player's **whole owned collection** is
parked in the car park here (`_build_title_lineup`, rebuilt on entering EXTERIOR) so
the title shows off every car. The **build version** (`v0.<n> (<sha>)`) is shown in
the bottom-right corner here only — not on the in-run HUD (see [hud.md](hud.md) →
Build version). This is a flat two-button menu driven by **native focus** —
`menu_select`/`ui_accept` fires whichever button is focused (Start grabs focus on
entry; `menu_up`/`menu_down` move between the two). Start flies the camera into the
garage; Settings opens the SETTINGS overlay. (The EXTERIOR branch in
`_unhandled_input` deliberately does *not* route `menu_select` to Start, or accepting
on Settings would start the run instead.)

**SETTINGS.** A flat overlay over the exterior shot (no dedicated camera pose)
hosting the **shared `SettingsMenu`** (`scripts/settings_menu.gd`, `class_name
SettingsMenu`) — the SAME component the in-run pause menu uses, so the two pages
match. It opens on a **category list** with one row per area, and each row drills
into **its own sub-page**:

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
  fresh new game), plus one button per car (`Save.grant_car`, from `CarLibrary.CARS`)
  and per upgrade/repair-kit (`Save.add_item`, from `UpgradeLibrary.UPGRADES`) to
  unlock anything in the game. A status line reports the last action.

Navigation lives inside the component: `show_list()` / `show_camera()` /
`show_schemes()` / `show_benchmark()` / `show_dev()` swap which page is visible (only the visible page contributes
height, so the long schemes page scrolls while the short list/camera pages don't),
and `page_changed(is_root)` lets the host steer its single bottom button — on a
sub-page it reads **< Back** (returns to the list); on the list it is the host's own
action. The saved choice in each section is highlighted and persisted via
`Save.set_setting`. Settings is also shown as a **pre-rally gate**: on mobile, if no
scheme has been chosen yet, Start opens this page (`_open_settings(true)`) instead of
launching — on the list the bottom button reads **Start >** and confirms the pick
(the highlighted default if untouched), saving it so the gate never reappears, then
begins the rally.

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
spawned whenever the camera is inside — garage/lift — and dropped otherwise). In the
garage the car rests **lowered on the ground** (`hq_lift_car_lowered_height`).
Tapping the table drops to the map view; tapping the lift flies to the **tuning bay**
(LIFT view). A HUD hint + Back (to the exterior) + convenience buttons sit on top.

**LIFT (the tuning bay).** Entering the bay **raises the car on the lift** — a slow
tween from the lowered (garage) pose up to `hq_lift_car_height` over
`hq_lift_raise_time` (`_apply_lift_height`); returning to the garage lowers it again.
The car is framed to one side (`hq_lift_cam_*`). The bay opens on a **HUB page**
(`LiftPage.HUB`): a **bottom** panel with the **car's name/description** spanning the
full page width, and UNDER it a **Change Car** button plus **Tuning** and
**Upgrades** buttons. **Change Car** (`_enter_change_car`) drops into the **car park**
in **change-car mode** (`_carpark_change_mode`): the WHOLE owned collection is parked,
framed on the car currently on the lift, and **Select Car** (`_on_start_pressed` →
`_select_changed_car`) sets the **selected car** (`Save.set_selected_car`) and returns
to the bay, re-spawning it on the lift; **Back** (`_car_back`) returns to the bay with
the selection unchanged. Any owned car is pickable here — a wrecked one can sit on the
lift to be repaired. Each menu button opens that menu as its **own full-height
page** — a solid panel **centred horizontally** and wide
(`hq_lift_menu_centered_width_frac`, using most of the screen); the car-description
panel **hides** while a sub-menu is open so the page has room — with a **< Back** that
returns to the hub; the hub's own Back returns to the garage. Because the hub controls
and page chrome live on the hub, each menu page gets the **full panel height to
itself** and doesn't need to scroll. The two pages:

- **Tune** (`LiftPage.TUNE`) — a slider per tuning axis (grip / brake-bias / aero /
  **engine detune**; locked axes greyed with a "needs X kit" note — detune is never
  locked) plus **Reset to neutral**; each change saves via `Save.set_tuning`. See
  [engine-swap.md](engine-swap.md) for the detune axis.
- **Upgrades** (`LiftPage.UPGRADES`) — per slot: every part **applied** to the car
  gets an **Enable/Disable toggle** (`Save.set_upgrade_enabled`; free, instant, at
  most one enabled per slot — enabling one switches off a same-slot sibling), and
  each matching **unlocked** item gets an **Apply** button (`Save.install_upgrade`;
  applying consumes the item from the unlocked pool and fits it to this car for
  good, confirmed via a dialog first since it can't be moved or recovered) plus
  the **Repair Kit** action `Save.use_repair_kit`. Above the slot rows sits an
  **engine-swap row** (`_make_engine_swap_row`): the car's current engine name and
  a **Swap Engine** button, disabled (with a tooltip) unless this car is at 100%
  HP. Pressing it opens the car park in **swap mode** (`_enter_engine_swap` /
  `_carpark_swap_mode`) — parking only the OTHER owned cars that also sit at 100%
  HP (self excluded) — where the normal car-park cycle/confirm/back flow exchanges
  the two cars' engines (`Save.swap_engines`) and returns to this page. See
  [engine-swap.md](engine-swap.md).
  The repair row also shows a green note **"All your cars were wrecked — a free Repair
  Kit was provided."** on the refresh where `Save.ensure_repair_safety_net` (called from
  `_refresh_lift_ui`) just granted a free kit (all owned cars wrecked + none held).

`_refresh_lift_ui` toggles which face (hub vs. a menu page) is shown from `_lift_page`.
See [tuning.md](tuning.md) for the underlying config pipeline.

**TABLE (the 3D world map).** A zoomed-in, near-top-down look at the table's flat map
plane — a **square** table top (`hq_table_size`/`hq_map_plane_size` are equal in
X/Z) surfaced with a **satellite map photo** (`textures/map_table.jpg`, an unshaded
albedo texture so the aerial colours read true under the garage lighting). Every
rally is a 3D **pin** (`_make_pin`) at its normalised `map_pos`: a
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
the flag — plus its `rally_id`/`locked` in metadata; the **showdown** pin is grey +
**non-pickable** until every other rally is completed. A progress meter sits on the HUD. **Drag to pan** the map (mouse, or
finger via `emulate_mouse_from_touch`): `_pan_table` shifts the camera in the table
plane, clamped to the map extents (`hq_table_pan_speed`). Pin selection fires on
**release** and only if the press wasn't a drag (`_table_dragged`), so panning never
opens the pin under the finger. **Crucially the station overlays are made
pass-through** (`_passthrough_overlay` sets every non-button control to
`MOUSE_FILTER_IGNORE`) — otherwise the full-rect HUD container/labels/spacer (all
default `STOP`) would swallow every touch and the 3D pins would never get a pick.
Tapping a pin opens the **rally detail** sub-panel (name, eligible-cars
restriction — the power-to-weight gate, not the hidden difficulty tier — event
count, best finish + stars); **Enter Rally** flies out to the
car park, **◄ Map** dismisses the panel, and the table Back returns to the garage.

**CARPARK (the outdoor lineup).** The owned cars **eligible for the chosen
rally** (`RallyLibrary.is_eligible`) — plus any **over-powered** car a detune
would qualify (below) — are parked at `GameConfig.hq_carpark_origin`,
in a **centred row ALONG X** — one car per painted bay (`menu_car_spacing` wide), with
fewer cars than bays centred within the grid — each **parked nose-out toward the
courtyard / menu camera (+Z)** so the camera frames its front with the garage behind;
each is a silenced `Car` prop (reusing `Car.apply_owned`). The exterior/title camera is
shifted by `menu_car_park_offset` (the same lot-centre offset) so it stays centred on
the row. Parking is shared with the title via `_build_lineup(cars)` — the car-select
screen passes the eligible cars, the title passes all owned. Each `Car` prop is a full
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
freshly-built car pays the per-frame stream + settle. `_clear_lineup` **hides + detaches**
the parked cars instead of freeing them (they stay parented to HQ, frozen at their
settled pose); the cache is shared across the car-select, title, and overflow lineups
(all build from the same owned cars), **evicts** entries for cars the player has sold
(`_evict_unowned_cached_cars`, run each build), and is freed wholesale with the HQ node
on exit-to-race. `◄ ►` (or
`menu_left`/`menu_right`) move the focus and the camera eases to a **front 3/4 hero
shot from in front of the car** (`menu_camera_offset` is added in world space; +Z sits
the eye ahead of the nose-out car, looking back past it at the garage) over
`menu_camera_move_time`; the focused car **is** the selected car. The overlay shows
its name + stats (drive / **lateral G** / power-to-weight / **Health %**); there is
no floating 3D label above the car. A **wrecked** focused car (`Save.car_is_wrecked`) is
**too damaged to enter**: Start is disabled and a warning explains why; if a **Repair
Kit** is owned, a **Repair (1 kit)** button fully restores it (`Save.use_repair_kit`)
and unlocks Start. An **over-powered** focused car — its p/w sits over the rally's
`pw_max` cap but detuning the engine would duck it under — still parks
(`_build_eligible_lineup` records its qualifying tune from
`RallyLibrary.qualifying_detune` in `_detune_needed`) and **looks eligible** — no
warning label, the plain enabled Start (saves overlay space). Pressing Start pops a
**`ConfirmationDialog`** (`_show_detune_confirm`) that explains the car doesn't
qualify as-is and names the engine tune that would fix it; its OK button —
**Detune to N% & Start** — is the explicit agreement that applies the tune
(`Save.set_engine_detune`) before fielding the car (`_on_detune_confirmed` →
`_proceed_with_start`). The tune is **temporary, for that rally only** (unlike a
garage-lift detune): the confirm registers the prior value with
`RallySession.register_detune_revert`, and the session restores it when the rally
ends — only at the actual end (finish/wreck/abandon), never between events. The dialog is a native `ConfirmationDialog` (same pattern as
the pause menu's quit confirm), so OK/Cancel are keyboard/gamepad reachable via the
window's built-in focus handling. The map pin's green
"raceable" pennant counts these detunable cars too (`_has_eligible_car` mirrors the
lineup filter). A **banner** names the rally + restriction; **Start** records the
fielded car as the **selected car** (`Save.set_selected_car` in `_begin_rally_start`,
so the tuning lift shows the car last raced), shows the
`LoadingScreen` overlay immediately and (after a fully presented frame, so it paints)
calls `RallySession.start_rally(rally, owned)` — the handoff derives event target
times by generating each track, which is heavy, so the overlay covers that work
instead of freezing HQ. **◄ Back** (or `menu_back`) returns to the map table and
clears the lineup. If no owned car qualifies, a hint shows and Start is disabled.

**OVERFLOW (scrap a car to make room).** The player may own at most
`GameConfig.max_owned_cars` (10) cars. A top-3 finish still grants its car even
when the garage is full, so on the **next HQ entry** `_build_hq` checks
`_over_car_limit()` and, if over, routes to the OVERFLOW station instead of the
title. It parks the **whole collection** (the just-won car included) with the same
`_build_lineup` + focus machinery as the car park, shows a `GARAGE FULL — (n / cap)`
banner, and a **Scrap this car** action removes the focused instance via
`Save.scrap_car` (returns its upgrades to inventory, refuses the player's last car —
its scrap button is disabled with a note). Scrapping re-evaluates: still over →
re-prompt; back at the cap → fly to the title. There is no Back — the player can't
leave until the garage is under the cap.

Star ratings come from `Save.best_placement(rally_id)` — the best (lowest)
finishing position ever recorded there, stored by `Save.complete_rally(id, ms,
placed)` on each top-3 finish (`RallySession` passes the placement).

Each parked car gets its **own duplicated meshes** (`_dup_meshes`) so a mixed
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
and it only appears over a normal title boot — never over the garage-overflow gate.
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
game** (`get_tree().paused = true`) and shows an overlay with **Resume**, **Settings**
and **Quit to HQ**.
Resume unfreezes and closes; Settings shows the **shared `SettingsMenu`** (camera
angle + mobile controls, identical to the title-screen page), with a **◄ Back** to
the Resume/Settings menu. **Quit to HQ** pops an *"Abandon rally?"* confirm and, on
accept (`quit_to_hq`), unfreezes and calls `RallySession.abandon()` — the rally is
left **incomplete with no retry penalty** (damage persisted, no reward); `abandon`
emits `rally_finished` which `world.gd` routes **straight back to HQ** (the garage
view) instead of the podium. (With no active session — a plain dev boot of
`main.tscn` — it just loads `hq.tscn` directly.) `ui_cancel` (Esc / gamepad B)
toggles the menu and backs out of Settings first. A camera pick applies
**immediately** to the live `CameraManager` (wired via the `SettingsMenu.camera_changed`
signal → `CameraManager.set_mode`), so the angle changes the moment you choose it.
A **mobile-control** pick applies just as immediately to the live `MobileControls`
(the `SettingsMenu.scheme_changed` signal → `MobileControls.set_scheme`), so the
on-screen touch layout rebuilds the instant you choose it rather than only on the next
run. Covered by `tests/headless/test_pause_menu.gd`.

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
   over it.
2. **LEADERBOARD** — the full ranked field (`RallyLibrary.build_standings`):
   position, name + car, time / `WRECKED`, the player's row tinted + marked.
3. **UPGRADE_REVEAL** (one stage **per won upgrade** — a rally grants
   `cfg.rally_upgrade_reward_count`, default 2) — a slot-machine spin for each
   per-rally upgrade, landing on its name. These come **before the car reveal**
   and are staged at the **podium camera**, so the upgrades are handed out while
   the player's car still stands on the podium. The lock-in opens an
   **Apply/Keep choice** (two focusable buttons, Apply focused first): *Apply*
   fits the part straight onto the owned car the player just drove
   (`Save.install_upgrade` on the result's `car_instance_id`); *Keep for later*
   leaves it unlocked for the garage upgrades menu. Next is **hidden until the
   choice is made** (`_choice_pending`). Repair kits and a missing driven car
   skip the choice — the item just lands in the unlocked pool.
4. **CAR_REVEAL** (only if `car_reward != ""`) — the camera **flies over to the
   showroom** and the same slot-machine reel spins through the car catalogue's
   names, decelerating onto the won car; on the lock-in the car appears on the
   showroom turntable (hidden until then) and the card collapses to a **single
   line**: the big slot label hides and the caption alone carries
   `"<car> (NEW) — delivered to your garage"` (the `(NEW)` tag only when first
   owned), so the name isn't shown twice.

During the two reveals the overlay's content stack drops to the **bottom of the
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
crowd** (`_build_scenery`): the same low-poly `low_poly_tree.glb` /
`groundcover_opaque.glb` / `spectator.glb` models the world scatters, placed as
plain decorative `MultiMesh`es (seeded, no collision, no steering AI — the
spectators just face the podium / showroom). Scenery is **skipped under headless**
(pure dressing; keeps the test budget). Counts / ring radii / pad size + feather
are `podium_*` `GameConfig` tunables.

`last_result` carries `rally_name`, `standings` (each entry with `car_id`),
`upgrades` (the one id won, `[]` on a DNF), `car_reward`, `car_reward_is_new`, and
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
first it is **two pages**, both built by the same `UITheme.standings_row` renderer (the
row's `combined_ms` field carries the event-only time on page 1, the cumulative time
on page 2):

1. **Event page** ("EVENT n RESULT") — that one event's finishing times, ranked via
   `RallySession.current_event_standings()`. A rival who DNF'd just that event sinks
   to the bottom of this page (they may still be alive overall).
2. **Combined page** ("STANDINGS — after event n of 3") — the cumulative leaderboard
   via `RallySession.current_standings()`.

The **first** event skips the event page and opens straight on the combined page (a
single event's time already equals its combined time, so there's nothing extra to
show). The **final** event shows only the event page, with its button reading
**"Continue >"**; pressing it calls `continue_to_next_event()`, which resolves the
rally, and the scene (connected to `RallySession.rally_finished`) then changes to
`podium.tscn` itself — the combined view for the finished rally lives on the podium's
LEADERBOARD stage instead of a second standings page. On a middling event the event
page's button reads **"See overall standings >"** and advances to the combined page
in place (`_showing_event_page = false; _build_ui()`); the combined page's button
reads **"Continue to next event >"** and calls `continue_to_next_event()` to load the
next event.

## Deferred (rest of the diegetic 3D build)

The diegetic HQ space (exterior / garage / 3D map table / car park / tuning lift,
with the camera flying between stations) is in. Still deferred
([../todo/diegetic-hq.md](../todo/diegetic-hq.md), umbrella in
[../todo/menus.md](../todo/menus.md)): per-car paint + duplicate-model name suffixes,
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
detune-to-enter prompt** (looks eligible; Start pops the confirm dialog; agreeing applies the qualifying
`engine_detune` and launches the rally); **Back** steps car park → table →
garage and clears the lineup; pin → enter →
car → Start launches a session; the **between-event standings interstitial** renders
both the event-only and cumulative leaderboards across its two pages (and the
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
