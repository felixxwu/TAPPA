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
                                          └─ car.wrecked ─▶ report_wreck (DNF)
   final event / DNF ─rally_finished─▶ podium.tscn ─Continue─▶ HQ
```

## HQ (`hq.gd`)

The boot scene (`project.godot` `run/main_scene`), a lightweight **`Node3D`** (no
track generation). On first visit it grants the **immortal starter** (`mx5`) — the
anti-soft-lock floor. HQ is **one diegetic 3D space** the camera flies through; an
`enum View { EXTERIOR, GARAGE, TABLE, CARPARK }` names the camera **stations** and
`_go_to(view)` tweens the single `Camera3D` between their poses
(`GameConfig.hq_*_cam_eye/look`, eased over `menu_camera_move_time`). Clickable 3D
objects (the table, the lift, the rally pins) are `Area3D` with `input_ray_pickable`
(`get_viewport().physics_object_picking` is on); their handlers also respond to
`menu_*` keyboard/gamepad input. The environment — block buildings, the garage
shell, the table, the lift — is built from `BoxMesh` blocks via `_block()`
(placeholder art; the framing/positions that the flow depends on are in `GameConfig`).

**EXTERIOR (boot/title).** A title + **Start** button over an establishing shot of
the block skyline and the outdoor car park. Start (or `menu_select`) flies the
camera into the garage.

**GARAGE.** A block garage interior holding the **map table** and the **tuning
lift**. Tapping the table drops to the map view; tapping the lift flashes
"Tuning bay — coming soon" (the tuning slice is later). A HUD hint + Back (to the
exterior) sit on top.

**TABLE (the 3D world map).** A zoomed-in, near-top-down look at the table's flat map
plane. Every rally is a 3D **pin** (`_make_pin`) at its normalised `map_pos`: a
tier-coloured cone marker, a billboarded `Label3D` name, and a row of small
**sphere stars** above it — 1st-place best = 3 gold, 2nd = 2, 3rd = 1, else grey
(`_stars_for`). (3D sphere stars sidestep the font's missing ★/☆ glyphs — same
reason the UI uses ASCII `<`/`>` for nav.) Each unlocked pin carries a pickable
`Area3D` (rally id bound to the handler) and its `rally_id`/`locked` in metadata;
the **showdown** pin is grey + **non-pickable** until every other rally is
completed. A progress meter sits on the HUD. **Drag to pan** the map (mouse, or
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
in a centred row spaced by `menu_car_spacing`, each a silenced `Car` prop (reusing
`Car.apply_owned`). The props **drop in live** (raised by `menu_car_drop_height` onto
a collision floor under the lot) so they **settle onto their suspension**, then
`_freeze_lineup` freezes the settled pose after `menu_car_settle_seconds` (guarded by
a generation id so re-entering the lot cancels a stale freeze) — so a full car park
costs nothing to keep parked. `◄ ►` (or `menu_left`/`menu_right`) move the focus
and the camera eases to a 3/4 hero shot (`menu_camera_offset` / `menu_camera_move_time`);
the focused car **is** the selected car. A billboarded `Label3D` shows its name +
stats beside it (drive / country / type / tier / power-to-weight / HP), mirrored into
the overlay. A **banner** names the rally + restriction; **Start** shows the
`LoadingScreen` overlay immediately and (after a fully presented frame, so it paints)
calls `RallySession.start_rally(rally, owned)` — the handoff derives event target
times by generating each track, which is heavy, so the overlay covers that work
instead of freezing HQ. **◄ Back** (or `menu_back`) returns to the map table and
clears the lineup. If no owned car qualifies, a hint shows and Start is disabled.

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
`StageManager.stage_completed` → `report_event_result(elapsed_ms, hp_lost)` and
the car's `wrecked` → `report_wreck`. `rally_finished` loads the podium. With no
session (a plain dev boot of `main.tscn`) the default car is fielded and none of
this runs — `main.tscn` is still independently runnable.

## Podium (`podium.gd`)

Reads `RallySession.last_result()` (a scrollable layout like HQ) and shows three
things:
- **Headline result** — rally name, placement + combined time, or DNF; a top-3
  reads as `RALLY WON!` (or `THE SHOWDOWN IS WON` for the final rally).
- **Reward reveal** — the won car by name with a `⭐ NEW` badge when first owned
  (`car_reward` / `car_reward_is_new`), plus the per-event **upgrades** collected,
  aggregated as `Name ×N`. Both were already granted by `RallySession`; the podium
  only reveals them.
- **Standings** — the full ranked field (`RallyLibrary.build_standings`): position,
  name, time / `WRECKED`, with the player's row marked `▶` and tinted.

`last_result` carries `rally_name`, `standings`, `upgrades`, `car_reward`,
`car_reward_is_new`, and `showdown_won` alongside the original
`placed`/`completed`/`combined_ms`/`dnf`. **Continue** returns to HQ.

## Start line (location 2)

The pre-event **start-line scene** — the diegetic **briefing** panel (rally, event
N/3, restriction, fielded car + HP bar) and the **pre-launch presence** cars — is
built inside the run scene before the countdown; the player launches it into the
`StageManager` countdown. See [start-line.md](start-line.md). Between-event
**standings** (`standings.tscn`) and the **Pause** overlay remain the open parts of
this location.

## Deferred (rest of the diegetic 3D build)

The diegetic HQ space (exterior / garage / 3D map table / car park, with the camera
flying between stations) is in. Still deferred
([../todo/diegetic-hq.md](../todo/diegetic-hq.md), umbrella in
[../todo/menus.md](../todo/menus.md)): the **tuning lift** UI + inventory (the lift
is a clickable placeholder for now), per-car paint + duplicate-model name suffixes,
designed environment art (blocks are placeholder), a pause overlay, the 3D
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
wraps; **Back** steps car park → table → garage and clears the lineup; pin → enter →
car → Start launches a session; the **between-event standings interstitial** renders
the cumulative leaderboard; the podium renders the finish summary **and the reward
reveal + standings**; and the run scene fields the bound session car. The pure
`RallyLibrary.build_standings` ranking and the enriched `RallySession` result are
covered in `test_rally_library.gd` / `test_rally_session.gd`.
