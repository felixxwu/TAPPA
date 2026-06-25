# Diegetic HQ — first 3D location (kickoff slice)

> Status: **planned, not yet implemented — brainstorm-first.** This is the
> actionable *first slice* of the diegetic 3D menu build whose full vision lives
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

1. **HQ 3D shell** — new `Node3D` HQ scene: ground, lighting, N car-park station
   markers (`Marker3D`), marker positions in `GameConfig`. Keep `hq.gd`'s starter
   grant + Start handoff; render the rally board as a flat overlay child.
2. **Menu camera** — add a `MENU` camera that tweens to a target marker over
   `GameConfig.menu_camera_move_time`. Reuse the `retarget`/`_apply` shape.
3. **Showroom rig** — spawn owned cars frozen at the markers; focus index drives
   the camera + the stats label. Disambiguate duplicate models with the
   `instance_id` suffix ("MX-5 #2"), as menus.md rig 1 specifies.
4. **Stats label** — `Label3D` beside the focused car: name, HP, drivetrain /
   country / type / power-to-weight (the data the flat card already computes).
5. **Wire selection** — focusing a car sets the same `_selected_instance_id`
   `hq.gd` already uses, so the existing rally board + Start path is unchanged.

## Open questions (decide while building)

- **New `MENU` mode in `CameraManager` vs a separate HQ-only cinematic camera?**
  (Driving modes and menu framing have little in common — leaning separate.)
- **Tween mechanism** — `Tween` on the camera transform vs a `ChaseCamera`-style
  per-frame smooth toward the marker. Tween is simpler for discrete focus jumps.
- **Headless testability** — the flat loop is fully headless-tested; a 3D scene
  with a camera is harder. What's the minimum assertable contract (e.g. "N frozen
  car nodes spawned for N owned cars", "focus index clamps", "selecting sets
  `_selected_instance_id`") so this slice keeps a test like the others?
- **Boot scene swap** — make the 3D HQ the boot scene, or keep flat HQ as a
  fallback behind a flag until the 3D one is proven on a phone?
- **Environment art** — placeholder until the look is designed (menus.md defers
  HQ art too); only marker positions are config in this slice.

## Relationship to other specs

- **Umbrella:** `todo/menus.md` (full diegetic vision — this is its first slice).
- **Reuses:** `features/camera.md` (camera modes), the `Car` spawn API
  (`features/car-physics.md`), `Save` / `CarLibrary` (the owned-car data the flat
  HQ already reads).
- **Later slices** (separate kickoffs like this one, as they come up): map table +
  3D pins, tuning lift + inventory, reward-reveal rig + 3D podium, fly-through
  transitions, the full `menu_*` input pass.
