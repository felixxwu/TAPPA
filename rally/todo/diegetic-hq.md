# Diegetic HQ — first 3D location (kickoff slice)

> Status: **🟢 SHIPPED (full diegetic space — camera flies between stations).** HQ
> (`hq.tscn` is a `Node3D`, `scripts/hq.gd`) is now ONE 3D space the camera moves
> through; `enum View { EXTERIOR, GARAGE, TABLE, CARPARK }` names the stations and
> `_go_to(view)` tweens the single `Camera3D` between their poses (the old flat
> overlay "screens" are gone). The environment is built from `BoxMesh` blocks
> (`_block()`): a skyline of buildings, the garage shell, the map table, the lift.
> - **Exterior (title):** establishing shot of the buildings + the outdoor car park
>   with just a **Start** button; Start (or `menu_select`) flies into the garage.
> - **Garage:** block interior with the **map table** + the **tuning lift**. Tapping
>   the table → map view; tapping the lift flashes "coming soon" (tuning is a later
>   slice). Both are `Area3D` clickables (`get_viewport().physics_object_picking`).
> - **Table (3D world map):** zoomed-in, near-top-down look at the table's flat map
>   plane, **drag to pan** (clamped to the map; `hq_table_pan_speed`). Each rally is
>   a 3D **pin** (`_make_pin`) at its `map_pos`: a tier-coloured cone, a billboarded
>   `Label3D` name, and a row of **sphere stars** (1st-place best → 3 gold, 2nd → 2,
>   3rd → 1, else grey, from `Save.best_placement`). The showdown pin is grey +
>   **non-pickable** until all others are completed; a progress meter sits on the
>   HUD. Tapping an (unlocked) pin opens the rally-detail sub-panel; **Enter Rally**
>   flies to the car park, **◄ Map** dismisses it. (Pin picking needs the HUD
>   overlays made pass-through via `_passthrough_overlay`, else the full-rect HUD
>   swallows the touch; selection fires on release + no-drag so a pan doesn't open a
>   pin.)
> - **Car park (reused for car select):** the cars **eligible for the chosen rally**
>   are parked outside at `GameConfig.hq_carpark_origin` as physics-frozen, silenced
>   `Car` props (via `Car.apply_owned`); a menu camera **pans between** them on cycle
>   (`◄ ►` + `menu_left/right`), a billboarded `Label3D` shows the focused car's
>   stats, a banner names the rally + restriction, and Start / ◄ Back act. Each
>   parked car gets its **own duplicated meshes** (`_dup_meshes`) so a mixed lot
>   renders each at its true size despite `car.tscn`'s shared mesh sub-resources.
>
> Config (`GameConfig` "Menu / HQ"): `hq_exterior_cam_eye/look`, `hq_garage_cam_eye/look`,
> `hq_table_cam_eye/look`, `hq_carpark_origin`, `hq_garage_size`, `hq_table_pos/size`,
> `hq_map_plane_size`, `hq_lift_pos/size`, plus `menu_camera_offset` /
> `menu_camera_move_time` / `menu_camera_look_height` / `menu_car_spacing`; rally
> `map_pos` in `RallyLibrary.RALLIES`; input actions `menu_left/right/select/back`
> in `project.godot`. Tests in `tests/headless/test_menu_flow.gd` (station flow,
> 3D-pin + lock + eligibility-filter + per-car-mesh-uniqueness assertions); doc in
> `features/menus.md`.
>
> **Still open** (later slices, stay in `todo/menus.md`): the **tuning lift** UI +
> inventory (the lift is a clickable placeholder), the 3D reward-reveal rig + 3D
> podium, camera fly-throughs for the longer hops, designed environment art (blocks
> are placeholder), and per-car paint / name-suffix polish.
>
> This is the actionable *first slice* of the diegetic 3D menu build whose full
> vision lives
> in [`todo/menus.md`](menus.md) (the umbrella spec: 3 locations, 6 rigs, 4
> overlays, camera fly-throughs, `menu_*` input). That spec is large and
> all-at-once; this file carves off the **smallest end-to-end 3D chunk** that
> proves the approach, so the diegetic work can start without committing to the
> whole thing. **menus.md stays the source of truth for the end state**; when a
> section here lands, strike the matching menus.md item and update
> `features/menus.md`.
>
> The flat-UI meta-loop (HQ car cards + rally board + podium reveal + standings)
> already exists and is the fallback — this slice replaces the **HQ car-park
> surface** with a real 3D staging while leaving the rest flat for now. Follow the
> config-first convention (`CLAUDE.md`): camera move times, station-marker
> positions, and panel offsets go in `GameConfig`
> (`scripts/game_config.gd` + `config/game_config.tres`), never hardcoded.

## Why this slice first

The car park / showroom rig is **menus.md rig 1 — "the workhorse"**: the same rig
is later reused for the starter pick, owned-car browse, and field-a-car. Building
it first de-risks the two hardest unknowns (a menu camera that tweens between
markers, and parking real `Car` nodes as frozen props) on the surface that pays
back the most. Everything else (map table, tuning lift, fly-throughs) can stay
flat and bolt on once this pattern is proven.

## Scope of THIS slice (deliberately small)

**In:**
- A **3D HQ scene** (replaces the flat `hq.tscn` `Control` with a `Node3D` world:
  a ground plane + a few car-park **station markers**; environment art is
  placeholder).
- A **menu camera** that frames the focused parked car and **tweens** to the
  next/previous car on input — a new `MENU` mode in `CameraManager` (or a small
  dedicated cinematic camera), reusing the existing `retarget` pattern.
- The **showroom rig**: instantiate the player's owned cars as **parked,
  physics-frozen** `Car` nodes at the markers, reusing `Car.apply_owned` /
  `apply_car`; no new render path.
- A **world-anchored stats label** beside the focused car (start with `Label3D`
  for the model name + HP + tags; the richer SubViewport panel is deferred).
- The existing flat **rally board + Start** kept as a simple overlay on this 3D
  scene (so the loop still closes) — porting the map to 3D pins is a later slice.

**Out (stays in menus.md, not this slice):** the map table + 3D pins, the tuning
lift, the reward-reveal rig, the 3D podium, camera fly-throughs *between*
locations, the full `menu_*` input action set + mobile gestures, and the
SubViewport stats panel. This slice only needs left/right "focus next car" input.

## Grounding in current code (verified)

- **Camera is already retargetable.** `CameraManager`
  (`scripts/camera_manager.gd`) has `enum Mode { CHASE, BONNET }` (`:7`),
  `ORDER` (`:10`), `cycle()` (`:31`), `retarget(car)` (`:42`) and `_apply()`
  (`:53`); `ChaseCamera` smooths toward `target` (`scripts/chase_camera.gd`). The
  menu camera is a **new mode + a marker-driven cinematic camera** that animates
  its transform toward the focused station marker, reusing this structure. Add it
  to `Mode`/`ORDER` or keep it a separate camera selected only in HQ.
- **The car is a reusable, freezable node.** `Car.apply_car(index)` (`car.gd:253`),
  `Car.apply_owned(owned)` (used by `world._field_session_car`,
  `world.gd:212`), and `Car.respawn(old, index, spawn_xform)` (`car.gd:226`) build
  a car at a transform. Parked props set `freeze = true` (the spec's
  physics-frozen lineup). `next_car_index()` (`car.gd:239`) already cycles models.
- **HQ is currently a flat `Control`.** `hq.tscn` is a bare `Control` running
  `scripts/hq.gd`; it's the boot scene (`project.godot` `run/main_scene`). This
  slice turns it into a `Node3D` (or adds a 3D subtree) while keeping the
  `_ensure_starter` + Start-handoff logic that already wires `RallySession`.
- **Owned cars come from the save.** `Save.profile["cars"]` (instances with
  `model_id` / `hp` / `immortal` / `installed_upgrades`); resolve display metadata
  via `CarLibrary.by_id` and `CarLibrary.power_to_weight` (already used by the
  flat car cards in `hq.gd`).
- **No scene pauses / no `menu_*` input yet** — consistent with menus.md current
  state; this slice adds only a minimal focus-next/prev input.

## Proposed build steps

1. ~~**HQ 3D shell**~~ **DONE** — `hq.tscn` is a `Node3D`; `hq.gd._build_world()`
   makes the lit lot (ambient + sun + ground plane) + the camera, and
   `_build_showroom()` lays out one `Marker3D` per owned car in a centred row
   (`GameConfig.menu_car_spacing`). Starter grant + Start handoff kept.
2. ~~**Menu camera**~~ **DONE** — a dedicated `Camera3D` (decided: separate from
   `CameraManager`) tweens its `global_transform` into the 3/4 framing over
   `GameConfig.menu_camera_move_time` (`_ease_camera_to_focus`), panning along the
   lot to the focused car.
3. ~~**Showroom rig**~~ **DONE (full lineup)** — `_build_showroom` parks one
   frozen/silenced `Car` per owned car via `apply_owned`, each with its own meshes
   (`_dup_meshes`); `_cycle_focus` / `focus_instance` pan between them (no respawn);
   `_ensure_showroom_current` rebuilds when the owned set changes (reward / wreck).
   **Open polish:** duplicate-model name suffixes ("MX-5 #2") and per-car paint.
4. ~~**Stats label**~~ **DONE** — billboarded `Label3D` beside the car (name + the
   drivetrain/country/type/tier/power-to-weight/HP line), mirrored into the overlay.
5. ~~**Wire selection**~~ **DONE** — the focused car sets `_selected_instance_id`;
   the existing rally board + Start path is unchanged.

## Open questions

**Decided during the slice:**
- **Camera:** a **separate HQ-only `Camera3D`** (not a `CameraManager` `MENU`
  mode) — driving modes and menu framing share nothing.
- **Tween mechanism:** a `Tween` on the camera `global_transform` (one ease per
  focus change), snapping when `menu_camera_move_time <= 0`.
- **Headless contract:** the slice asserts a focused `Car` prop spawns + is frozen,
  the camera exists, cycling focus respawns/reselects the model, focus wraps, and
  the rally board reflects the focused car (`test_menu_flow.gd`). Tween/visual
  framing is not asserted (no display in headless).
- **Boot scene:** the 3D HQ **is** the boot scene (replaced the flat `Control`
  outright); the flat loop logic is preserved inside it as the overlay.

**Resolved by the lineup:**
- **Simultaneous parked lineup — DONE.** `_dup_meshes` gives each parked car its
  own copies of the shared `car.tscn` mesh sub-resources right after `apply_owned`,
  so a mixed lineup renders each at its true size (asserted in
  `test_hq_parks_the_whole_lineup_with_per_car_meshes`). The `Config.data` stomp by
  the last `apply_car` is harmless: the props don't simulate, and `world.gd`
  re-applies the fielded car's config before any run.

**Still open:**
- **Per-car visual identity** — duplicate-model name suffixes ("MX-5 #2") and
  distinct paint per car (the chassis material is still shared/one colour).
- **Lineup scale** — every owned car is parked; if a garage grows large this may
  want a cap / scroll. Fine at current roster sizes; revisit if it bites.
- **Environment art** — placeholder lot/lighting until the look is designed
  (menus.md defers HQ art too); marker layout becomes config when the lineup lands.
- **Mobile/gamepad polish** — `menu_select`/`menu_back` are mapped but HQ only uses
  left/right + Start today; swipe-to-cycle and a Back affordance come with the
  wider `menu_*` pass in `menus.md`.

## Relationship to other specs

- **Umbrella:** `todo/menus.md` (full diegetic vision — this is its first slice).
- **Reuses:** `features/camera.md` (camera modes), the `Car` spawn API
  (`features/car-physics.md`), `Save` / `CarLibrary` (the owned-car data the flat
  HQ already reads).
- **Later slices** (separate kickoffs like this one, as they come up): map table +
  3D pins, tuning lift + inventory, reward-reveal rig + 3D podium, fly-through
  transitions, the full `menu_*` input pass.
