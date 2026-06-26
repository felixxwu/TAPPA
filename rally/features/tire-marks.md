# Tire marks (gravel ruts)

`TireMarks` (`scripts/tire_marks.gd`, `class_name TireMarks extends Node3D`) lays
subtle, gravel-coloured ruts behind the car's wheels while it drives on the road.
Created + wired by `world.gd._generate_track` (reused across event regenerations,
re-targeted on a car swap in `world.gd.cycle_car`). See the design in
[../todo/tire-marks.md](../todo/tire-marks.md).

## Why a ribbon mesh

The project renders with `gl_compatibility` (desktop + mobile), which has **no
`Decal` support** — so each wheel gets a **persistent ribbon mesh**: a child
`MeshInstance3D` whose `ArrayMesh` is rebuilt as segments are appended. Same
unshaded, cull-disabled material style as the `wheel_force_debug` overlay, but
accumulated rather than rebuilt-from-scratch each frame.

## Per-tick logic

Each `_physics_process` (skipped when `tire_marks_enabled` is off, the centerline
is missing, or the car is gone):
- **Speed gate** — below `tire_mark_min_speed_mps` every ribbon is broken (no marks
  while parked / during the countdown).
- **Road frame** — one windowed nearest-offset on the centerline for the car centre
  (`_windowed_offset`, the same local-search idea as `TrackProgress`), giving the
  local road point + left normal. Wheels are within a couple of metres, so this one
  frame gates all four.
- **Per wheel** (duck-typed on `is_in_contact()`, so `VehicleWheel3D` and test stubs
  both work): when in contact and within `track_width/2 + tire_mark_gravel_margin_m`
  of the centerline (on the gravel), and it has moved ≥ `tire_mark_segment_step_m`
  since its last point, append a ribbon segment — a left/right pair across the road
  normal at the wheel's **contact patch** (`y = hub.y − wheel_radius +
  tire_mark_ground_offset_m`, NOT `terrain.height_at` — near the road the terrain
  mesh is flattened to the baked road height the car rides on, so the raw noise
  height would sink the ribbon under the road in cuts/dips).
  Off the gravel or airborne, the ribbon **breaks** (a fresh strip starts later, no
  line across the gap).
- **Cap** — each wheel's segment list is a ring buffer of `tire_mark_max_segments`
  (oldest recycled); only the wheel's own surface rebuilds on a new segment. Memory
  is bounded and the chase cam looks forward, so far-behind marks are off-screen.

## Configuration

All in `GameConfig` (the "Tire Marks" group): `tire_marks_enabled`,
`tire_mark_color` (solid, a shade darker than the gravel), `tire_mark_width_m`,
`tire_mark_min_speed_mps`, `tire_mark_segment_step_m`, `tire_mark_max_segments`,
`tire_mark_ground_offset_m`, `tire_mark_gravel_margin_m`.

## Tests

`tests/headless/test_tire_marks.gd` — a straight `Curve2D` + stub car/wheels drive
the logic without a vehicle or rendering: four ribbons collected, marks accumulate
on the gravel, none off it, a sub-step move adds nothing, the ring buffer caps the
count, below the speed floor lays nothing, and an airborne wheel stops marking.

## Out of scope (todo/tire-marks.md)

Per-surface variation (grass/mud), alpha fade-out over distance, and
skid-intensity colouring — gravel-only, uniform, hard-capped for now.
