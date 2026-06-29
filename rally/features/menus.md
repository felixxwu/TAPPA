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
   main.tscn ─StageManager.stage_completed─▶ report_event_result ─▶ standings.tscn ─Continue─▶ next event
                                          └─ car.wrecked ─▶ WreckScreen (crash → orbit + menu) ─Return to HQ─▶ report_wreck (DNF)
   final event / DNF ─rally_finished─▶ podium.tscn ─Continue─▶ HQ
```

## HQ (`hq.gd`)

The boot scene (`project.godot` `run/main_scene`), a lightweight **`Node3D`** (no
track generation). On first visit it grants the **immortal starter** (`mx5`) — the
anti-soft-lock floor. Building the HQ (ground, buildings, the billboard tree ring, the
garage, the parked lineup) is synchronous and takes a beat, so on a real display
`_ready` shows a **`LoadingScreen` cover** the moment the scene starts, builds behind
it (`_build_hq`), then reveals — bridging the gap after Godot's boot bar so the load
never looks frozen. Under the headless test runner it builds synchronously with no
cover (so tests see a ready HQ after one frame). HQ is **one diegetic 3D space** the camera flies through; an
`enum View { EXTERIOR, GARAGE, TABLE, LIFT, CARPARK, SETTINGS, OVERFLOW }` names the camera **stations** and
`_go_to(view)` tweens the single `Camera3D` between their poses
(`GameConfig.hq_*_cam_eye/look`, eased over `menu_camera_move_time`). Clickable 3D
objects (the table, the lift, the rally pins) are `Area3D` with `input_ray_pickable`
(`get_viewport().physics_object_picking` is on); their handlers also respond to
`menu_*` keyboard/gamepad input. The environment — a block-building skyline
**behind the garage** (`_build_buildings`, kept clear of the title camera's view),
billboard **trees** framing the lot (`_build_trees`, reusing the stage's
`BillboardField`), the garage shell, the lift — is built from `BoxMesh`
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
the title shows off every car. Start (or `menu_select`) flies the camera into the
garage; Settings opens the SETTINGS overlay.

**SETTINGS.** A flat overlay over the exterior shot (no dedicated camera pose)
hosting the **shared `SettingsMenu`** (`scripts/settings_menu.gd`, `class_name
SettingsMenu`) — the SAME component the in-run pause menu uses, so the two pages
match. It opens on a **category list** with one row per area, and each row drills
into **its own sub-page**:

- **Camera** — pick the **camera angle** (chase / bonnet, from `CameraManager.MODES`);
  the choice persists under `CameraManager.SETTING_KEY` and is applied on the next run
  (or live, in the pause menu, via the `camera_changed` signal). See
  [camera.md](camera.md).
- **Mobile controls** — pick the **touch control scheme**. Each of the six schemes
  ([mobile-controls.md](mobile-controls.md)) is a tappable row with a vector
  **diagram** of its layout (`ControlSchemeDiagram`, `scripts/control_scheme_diagram.gd`),
  its name and how-to.
- **Dev** — a debug page: **Wipe all progress** (`Save.reset_new_game`, back to a
  fresh new game), plus one button per car (`Save.grant_car`, from `CarLibrary.CARS`)
  and per upgrade/repair-kit (`Save.add_item`, from `UpgradeLibrary.UPGRADES`) to
  unlock anything in the game. A status line reports the last action.

Navigation lives inside the component: `show_list()` / `show_camera()` /
`show_schemes()` / `show_dev()` swap which page is visible (only the visible page contributes
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
The car is framed to one side (`hq_lift_cam_*`) so the **tuning menu** — a solid panel
anchored to the other side of the screen (`hq_lift_menu_width_frac`) — never covers
it. The panel holds **only** the interactive controls (change-car, the tab strip, the
scrollable menu content, Back) so it stays short on small screens; the **bay title and
the car's name/description** sit in a separate **bottom-left** panel beside the car.
Two menus toggled by the tab strip: **Tune** (a slider per tuning axis — grip /
brake-bias / aero — locked axes greyed with a "needs X kit" note, plus **Reset to
neutral**; each change saves via `Save.set_tuning`) and **Upgrades** (per-slot
install from inventory via `Save.install_upgrade` — fitting **fully consumes** the
part, confirmed via a dialog first since it can't be undone — plus the **Repair Kit**
action `Save.use_repair_kit`). A change-car
control cycles all owned cars, updating the **selected car**
(`Save.selected_car`/`set_selected_car`) and re-spawning it on the lift. See
[tuning.md](tuning.md) for the underlying config pipeline.

**TABLE (the 3D world map).** A zoomed-in, near-top-down look at the table's flat map
plane — a **square** table top (`hq_table_size`/`hq_map_plane_size` are equal in
X/Z) surfaced with a **satellite map photo** (`textures/map_table.jpg`, an unshaded
albedo texture so the aerial colours read true under the garage lighting). Every
rally is a 3D **pin** (`_make_pin`) at its normalised `map_pos`: a
**state-coloured flag marker** (`RallyFlag` — a pole + waving pennant + finial
bead), a billboarded `Label3D` name, and a row of small **sphere stars** above it
— 1st-place best = 3 gold, 2nd = 2, 3rd = 1, else grey (`_stars_for`). The flag's
pennant colour is the medal ladder (`RallyFlag.state_color`): locked = charcoal
grey (with a grey finial, so it reads as disabled), 0 stars = race red, then
bronze / silver / gold for 1 / 2 / 3 stars — so the colour alone conveys the best
result, with the sphere stars as the exact readout. (3D sphere stars sidestep the
font's missing ★/☆ glyphs — same reason the UI uses ASCII `<`/`>` for nav.) Each
unlocked pin carries a pickable `Area3D` (rally id bound to the handler) and its
`rally_id`/`locked` in metadata; the **showdown** pin is grey + **non-pickable**
until every other rally is completed. A progress meter sits on the HUD. **Drag to pan** the map (mouse, or
finger via `emulate_mouse_from_touch`): `_pan_table` shifts the camera in the table
plane, clamped to the map extents (`hq_table_pan_speed`). Pin selection fires on
**release** and only if the press wasn't a drag (`_table_dragged`), so panning never
opens the pin under the finger. **Crucially the station overlays are made
pass-through** (`_passthrough_overlay` sets every non-button control to
`MOUSE_FILTER_IGNORE`) — otherwise the full-rect HUD container/labels/spacer (all
default `STOP`) would swallow every touch and the 3D pins would never get a pick.
Tapping a pin opens the **rally detail** sub-panel (name, difficulty, eligible-cars
restriction, event count, best finish + stars); **Enter Rally** flies out to the
car park, **◄ Map** dismisses the panel, and the table Back returns to the garage.

**CARPARK (the outdoor lineup).** Only the owned cars **eligible for the chosen
rally** (`RallyLibrary.is_eligible`) are parked at `GameConfig.hq_carpark_origin`,
in a **centred row ALONG X** — one car per painted bay (`menu_car_spacing` wide), with
fewer cars than bays centred within the grid — each **parked nose-out toward the
courtyard / menu camera (+Z)** so the camera frames its front with the garage behind;
each is a silenced `Car` prop (reusing `Car.apply_owned`). The exterior/title camera is
shifted by `menu_car_park_offset` (the same lot-centre offset) so it stays centred on
the row. Parking is shared with the title via `_build_lineup(cars)` — the car-select
screen passes the eligible cars, the title passes all owned. The props **drop in live**
(raised by `menu_car_drop_height` onto a collision floor under the lot) so they
**settle onto their suspension**, then `_freeze_lineup` freezes the settled pose after
`menu_car_settle_seconds` (guarded by a generation id so re-entering the lot cancels a
stale freeze) — so a full car park costs nothing to keep parked. `◄ ►` (or
`menu_left`/`menu_right`) move the focus and the camera eases to a **front 3/4 hero
shot from in front of the car** (`menu_camera_offset` is added in world space; +Z sits
the eye ahead of the nose-out car, looking back past it at the garage) over
`menu_camera_move_time`; the focused car **is** the selected car. A billboarded
`Label3D` shows its name +
stats beside it (drive / country / type / tier / power-to-weight / **Health %**),
mirrored into the overlay. A **wrecked** focused car (`Save.car_is_wrecked`) is
**too damaged to enter**: Start is disabled and a warning explains why; if a **Repair
Kit** is owned, a **Repair (1 kit)** button fully restores it (`Save.use_repair_kit`)
and unlocks Start. A **banner** names the rally + restriction; **Start** shows the
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
`Save.scrap_car` (returns its upgrades to inventory, refuses the immortal starter —
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
labels were shifted left to clear it) that **freezes the game** (`get_tree().paused
= true`) and shows an overlay with **Resume**, **Settings** and **Quit to HQ**.
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
Covered by `tests/headless/test_pause_menu.gd`.

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
3. **CAR_REVEAL** (only if `car_reward != ""`) — a **slot-machine** spin through the
   car roster that decelerates and **locks onto the car won**, then that car turns
   on a **showroom turntable** with its name + a `(NEW)` tag when first owned.
4. **UPGRADE_REVEAL** (only if an upgrade was won) — the same slot-machine spin for
   the **single per-rally upgrade**, landing on its name.

The **Next button is hidden during a slot spin** and only reappears once it locks
on (`_reveal_done`). The final Next returns to HQ, setting
`RallySession.return_to_garage` so HQ opens on the **garage** view. Slot durations /
drop height / settle time / turntable speed are `GameConfig` tunables
(`podium_*`). Headless runs build synchronously and resolve the spins instantly so
tests can step the stages.

`last_result` carries `rally_name`, `standings` (each entry with `car_id`),
`upgrades` (the one id won, `[]` on a DNF), `car_reward`, `car_reward_is_new`, and
`showdown_won` alongside the original `placed`/`completed`/`combined_ms`/`dnf`.

## Start line (location 2)

The pre-event **start-line scene** — the diegetic **briefing** panel (rally, event
N/3, restriction, fielded car + HP bar) and the **pre-launch presence** cars — is
built inside the run scene before the countdown; the player launches it into the
`StageManager` countdown. See [start-line.md](start-line.md). The in-run **Pause**
menu is covered above (`pause_menu.gd`); the between-event **standings**
(`standings.tscn`) interstitial remains the open part of this location.

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
restores it to full health and unlocks Start); **Back** steps car park → table →
garage and clears the lineup; pin → enter →
car → Start launches a session; the **between-event standings interstitial** renders
the cumulative leaderboard; the podium renders the finish summary **and the reward
reveal + standings**; and the run scene fields the bound session car. The settings
test also checks the shared `SettingsMenu` exposes a **camera-angle row per mode** and
**persists the chosen angle**. The pure `RallyLibrary.build_standings` ranking and the
enriched `RallySession` result are covered in `test_rally_library.gd` /
`test_rally_session.gd`.

`tests/headless/test_pause_menu.gd` — the **Pause button freezes the game** and opens
the menu; **Resume unfreezes** and closes it; **Settings exposes the shared
`SettingsMenu`** (camera + control rows); **Quit to HQ abandons the active rally** and
unfreezes the game; and **picking a camera applies live** to the `CameraManager` (and
persists). Camera cycling / `set_mode` persistence is covered in `test_camera_manager.gd`.
