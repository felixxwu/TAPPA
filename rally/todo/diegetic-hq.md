# Diegetic HQ — first 3D location (kickoff slice)

> Status: **🟢 FIRST SLICE SHIPPED.** The 3D HQ showroom is in (`hq.tscn` is now a
> `Node3D`, `scripts/hq.gd`): a lit lot, a menu camera that eases into a 3/4 hero
> shot, the focused owned car spawned as a parked, physics-frozen, silenced `Car`
> prop (via `Car.apply_owned`), a billboarded `Label3D` stat panel, prev/next car
> cycling (`◄ ►` + `menu_left`/`menu_right`), and the rally board + Start kept as a
> flat `CanvasLayer` overlay. Config: `GameConfig.menu_camera_offset` /
> `menu_camera_move_time` / `menu_camera_look_height`; input actions
> `menu_left/right/select/back` added to `project.godot`. Tests in
> `tests/headless/test_menu_flow.gd`; doc in `features/menus.md`.
>
> **Shipped vs the build steps below:** steps 1–5 are done **for a single focused
> car** (the chosen scope). **Still open:** the **simultaneous parked lineup** of N
> cars (needs per-instance mesh duplication + visual verification — see *Open
> questions*), and the later slices (map pins, tuning lift, reward rig,
> fly-throughs) that stay in `todo/menus.md`.
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
   makes the lit lot (ambient + sun + ground plane), a `DisplayMarker`, and the
   camera. *(Markers are built in code, not authored; the lineup of N markers is
   the deferred lineup follow-up.)* Starter grant + Start handoff kept.
2. ~~**Menu camera**~~ **DONE** — a dedicated `Camera3D` (decided: separate from
   `CameraManager`, see open questions) tweens its `global_transform` into the 3/4
   framing over `GameConfig.menu_camera_move_time` (`_ease_camera_to_focus`).
3. ~~**Showroom rig**~~ **DONE (single focused car)** — `_spawn_focused_car` builds
   one frozen/silenced `Car` at the marker via `apply_owned`; `_cycle_focus` /
   `focus_instance` swap it. **Open:** the simultaneous N-car lineup (instance-id
   suffixes land with it).
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

**Still open:**
- **Simultaneous parked lineup (the main follow-up).** Showing N cars at once needs
  per-instance **mesh duplication** (the car scene's chassis/cabin/wheel
  `BoxMesh`/`CylinderMesh` sub-resources are shared across `car.tscn` instances, so
  `apply_car` sizing one would resize all) **and** a way to keep `Config.data` from
  being stomped by the last `apply_car`. Plus it wants visual verification, which
  this headless cloud env can't do — so it's deferred until it can be eyeballed.
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
