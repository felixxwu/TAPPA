# Tire Marks (gravel ruts) — implementation spec  ✅ DONE

> Status: **SHIPPED.** `TireMarks` (`scripts/tire_marks.gd`) is wired in
> `world.gd._generate_track` (re-targeted in `cycle_car`): per-wheel ribbon meshes,
> **always** laid while rolling, **all four wheels**, **only on the gravel** (road
> footprint + verge margin), **capped** per wheel (ring buffer). Config in the
> `GameConfig` "Tire Marks" group; tests in `tests/headless/test_tire_marks.gd`;
> doc in `features/tire-marks.md`. The sections below are the as-built design; the
> *Out of scope* items remain open.
>
> Decided with the user: **always show** marks while rolling (not just on skids),
> **all four wheels**, **only on the gravel** (the road footprint), with a
> **capped** length. Follow the config-first convention (`CLAUDE.md`): every tunable
> lives in `GameConfig`. Update `features/` + add tests in the same piece of work.

## Why a ribbon mesh (not decals)

The project renders with the **`gl_compatibility`** renderer on desktop *and*
mobile (`project.godot:155-157`, `force_vertex_shading`). `Decal` nodes are **not
supported** in Compatibility — so the marks are a **persistent ribbon mesh** laid
on the ground behind each wheel. Precedent: `wheel_force_debug.gd` already draws
procedural ground geometry on a `top_level` `MeshInstance3D` with an unshaded,
`vertex_color_use_as_albedo` material; tire marks use the same material style but
**accumulate** geometry (an `ArrayMesh` per wheel) instead of rebuilding each tick.

Rejected: Decals (unsupported here), render-to-texture splatmap (heavy for mobile),
ground particles (don't read as continuous tracks).

## Node & wiring

A new `TireMarks` node (`scripts/tire_marks.gd`, `MeshInstance3D` or `Node3D`
parenting four ribbon `MeshInstance3D`s — one per wheel). Created in
`world._generate_track` alongside `TrackProgress` (`world.gd:160-168`), reusing the
node across event regenerations, and given the **centerline** (`result["centerline"]`),
the **terrain** (`$Floor`, for `height_at`), and the **car** (`$Car`). On a car
swap (`world.cycle_car`) it re-targets the fresh car and clears its marks (like
`TrackProgress.retarget`). Guards `is_instance_valid(_car)`.

## Per-tick logic (`_physics_process`)

1. **Speed gate** — skip when `car.linear_velocity.length() < tire_mark_min_speed_mps`
   (no marks while parked / in the countdown).
2. **Road frame** — one windowed nearest-offset on the centerline for the car
   origin (cheap, seeded from last tick — same pattern as
   `TrackProgress._local_closest_offset`), giving the local road point + tangent
   (hence the road normal). Wheels are within ~2.5 m of the car, so this local
   frame applies to all four.
3. **Per wheel** (`drivetrain.front_wheels + rear_wheels`, or
   `find_children VehicleWheel3D`): when `wheel.is_in_contact()`:
   - lateral = `(wheel_xz − road_point) · road_normal`.
   - **on_gravel** = `abs(lateral) <= track_width * 0.5 + tire_mark_gravel_margin_m`.
   - **on gravel** and the wheel has moved ≥ `tire_mark_segment_step_m` since its
     last point: append a quad bridging the previous left/right pair to a new pair,
     centred at the wheel's contact patch (`x,z` of the hub, `y = hub.y −
     wheel_radius + tire_mark_ground_offset_m` — the wheel's real contact, NOT
     `terrain.height_at`, which is the raw noise height and sinks under the
     flattened road in cuts/dips), `tire_mark_width_m`
     wide across the road normal.
   - **off gravel** (or not in contact): break the ribbon (next on-gravel point
     starts a fresh strip — no long line across the gap).
4. **Cap** — each wheel's ribbon is a ring buffer of `tire_mark_max_segments`; the
   oldest segment recycles when exceeded (memory bounded; the chase cam looks
   forward so far-behind marks are off-screen anyway). Rebuild only the wheel's own
   `ArrayMesh` surface on a new segment.

## Colour

Solid, close to the gravel but a shade darker (compacted/disturbed gravel reads
darker, not black). The road is a *texture* cross-faded by vertex alpha
(`terrain_manager.vertex_colors`), so there's no single road `Color` to read — the
mark colour is an authored `GameConfig` value, calibrated by eye against the road
texture. Unshaded vertex-colour material to match the flat PS1 look; a small
`tire_mark_ground_offset_m` lift avoids z-fighting with the Gouraud road.

## Config (`GameConfig`, new "Tire Marks" group)

- `tire_marks_enabled := true`
- `tire_mark_color := Color(…)` — dark gravel grey (calibrate vs the road texture)
- `tire_mark_width_m := 0.22`
- `tire_mark_min_speed_mps := 2.0`
- `tire_mark_segment_step_m := 0.5`
- `tire_mark_max_segments := 200` (≈100 m per wheel at 0.5 m)
- `tire_mark_ground_offset_m := 0.03`
- `tire_mark_gravel_margin_m := 0.3`

## Testing (headless — no rendering)

Drive the logic with a stub car + a straight `Curve2D` (mirrors
`test_track_progress.gd`):
- on-gravel emits points; off-gravel (lateral beyond the gate) emits none / breaks.
- moving ≥ step appends a segment; moving less appends nothing.
- the per-wheel buffer never exceeds `tire_mark_max_segments` (ring-buffer cap).
- below `min_speed` emits nothing.
- four ribbons exist (one per wheel).

## Out of scope / later

- Per-surface variation (grass marks, mud) — gravel only for now.
- Fade-out alpha over distance (the hard cap is enough for v1).
- Skid-intensity colouring (darker when sliding) — always-on uniform marks for now.
- The eventual diegetic/3D-map work is unrelated.
