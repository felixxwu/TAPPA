# Tire marks (gravel ruts + tarmac skids)

`TireMarks` (`scripts/tire_marks.gd`, `class_name TireMarks extends Node3D`) lays
tyre marks behind the car's wheels while it drives on the road. The mark depends on
the surface under each wheel:
- **Gravel** — a subtle, gravel-coloured **rut** laid continuously while moving.
- **Tarmac** — a dark **skidmark** laid only while a *driven* wheel is **spinning**
  (the same wheelspin slip gate the gravel spray uses, see `features/wheel-dust.md`);
  a cleanly rolling wheel on tarmac leaves nothing.

The grass off the road footprint never marks. Created + wired by
`world.gd._generate_track` (reused across event regenerations, re-targeted on a car
swap in `world.gd.cycle_car`).

## Why a ribbon mesh

The project renders with `gl_compatibility` (desktop + mobile), which has **no
`Decal` support** — so each wheel gets a **persistent ribbon mesh**: a child
`MeshInstance3D` whose `ArrayMesh` grows as segments are appended. The triangle
buffer is maintained **incrementally** — a new segment appends one quad and a
dropped one trims a quad off the front — rather than reconstructed from the whole
segment list on every emit (`_build_ribbon` is the reference that incremental
buffer must equal, asserted in `test_tire_marks`). Same unshaded, cull-disabled
material style as the `wheel_force_debug` overlay. Each segment carries its
own **vertex colour** (the shared material has `vertex_color_use_as_albedo`), so one
ribbon per wheel shows both the gravel rut and the tarmac skid in their own shades.

## Per-tick logic

Each `_physics_process` (skipped when `tire_marks_enabled` is off, the centerline
is missing, or the car is gone):
- **Speed gate** — below `tire_mark_min_speed_mps` every ribbon is broken (no marks
  while parked / during the countdown).
- **Offset cache** — one windowed nearest-offset on the centerline for the car
  centre (`_windowed_offset`, the same local-search idea as `TrackProgress`),
  seeding each wheel's tighter search.
- **Per wheel** (duck-typed on `is_in_contact()`, so `VehicleWheel3D` and test stubs
  both work): gated by ITS OWN nearest road point (`_wheel_offset`, searched in a
  tight window around the car's offset) — NOT the car's tangent, which on a corner
  would wrongly reject a wheel that's on the road but ahead on the curve. When in
  contact and within `track_width/2 + tire_mark_gravel_margin_m` of the centerline
  (on the road, not the grass), the **surface** picks the mark
  (`TerrainManager.surface_at`'s `tarmac_weight`, split at `0.5` — the same midpoint
  the road colour/grip feather across; terrain is null on the flat test fixtures,
  where everything reads as gravel):
  - **Gravel** (`tarmac_weight ≤ 0.5`): eligible whenever moving — colour
    `tire_mark_color`.
  - **Tarmac** (`tarmac_weight > 0.5`): eligible only when `_wheel_spinning` — the
    car's drivetrain reports the wheel **driven** and its tread outrunning the ground
    by ≥ `wheel_particle_min_slip_mps` (the gravel-spray slip gate) — colour
    `tire_mark_tarmac_color`. No drivetrain (flat fixtures) ⇒ never spinning.

  When eligible and it has moved ≥ `tire_mark_segment_step_m` since its last point,
  append a ribbon segment — a left/right pair across the road normal at the wheel's
  **contact patch** (`y = hub.y − wheel_radius + tire_mark_ground_offset_m`, NOT
  `terrain.height_at` — near the road the terrain mesh is flattened to the baked road
  height the car rides on, so the raw noise height would sink the ribbon under the
  road in cuts/dips). On the grass, on tarmac without wheelspin, or airborne, the
  ribbon **breaks** (a fresh strip starts later, no line across the gap).
- **Cap** — each wheel's segment list is a ring buffer of `tire_mark_max_segments`
  (oldest recycled, and its leading quad trimmed off the mesh buffer); only the
  wheel's own surface re-uploads on a new segment. Memory is bounded and the chase
  cam looks forward, so far-behind marks are off-screen.
  The trail length is `tire_mark_max_segments × tire_mark_segment_step_m` — at the
  configured 20 × 0.5 m that is a **10 m** trail behind each wheel.

## Colour

Per-segment vertex colour, so the two surfaces read differently in one ribbon:
- `tire_mark_color` — the gravel rut, a touch darker than the gravel (gravel.jpg
  averages ~0.42 grey).
- `tire_mark_tarmac_color` — the tarmac skid, a dark near-black scuff.

Unshaded material, cull disabled, `vertex_color_use_as_albedo` on.

## Configuration

All in `GameConfig` (the "Tire Marks" group): `tire_marks_enabled`,
`tire_mark_color`, `tire_mark_tarmac_color`, `tire_mark_width_m`,
`tire_mark_min_speed_mps`, `tire_mark_segment_step_m`, `tire_mark_max_segments`,
`tire_mark_ground_offset_m`, `tire_mark_gravel_margin_m`. The tarmac-skid slip gate
reuses the wheel-dust `wheel_particle_min_slip_mps`.

## Tests

`tests/headless/test_tire_marks.gd` — a straight `Curve2D` + stub car/wheels (and a
stub drivetrain for the skid gate) drive the logic without a vehicle or rendering:
four ribbons collected, gravel ruts accumulate, none off the footprint (grass), no
tarmac skid from a cleanly rolling wheel, a dark skid IS laid when a driven wheel
spins on tarmac, an undriven spinning wheel still lays nothing, a sub-step move adds
nothing, the ring buffer caps the count, below the speed floor lays nothing, an
airborne wheel stops marking, and a jump leaves a real gap (the landing point starts
a new strip, not a stretched quad bridged back to the take-off point).

## Shader warm-up

The ribbon material has the same `gl_compatibility` first-visible-draw compile
cost as the particle pools. `warm_up(pos)` draws a throwaway quad (same material)
in front of the camera and `clear_warm_up()` frees it, so
`world.gd._generate_track` primes the shader behind the loading overlay rather
than hitching on the first mark laid — see
[wheel-dust.md → Shader warm-up](wheel-dust.md).

## Out of scope (features/tire-marks.md)

Alpha fade-out over distance and load-based colour variation — constant per-surface
colours, hard-capped for now. (Load-based darkening was tried and reverted — didn't
read well.) Tarmac skids are gated purely on the longitudinal wheelspin slip (same
as the gravel spray); lock-up/braking and pure lateral-slide skids are not modelled.
