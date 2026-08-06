# Tire marks (gravel ruts + tarmac skids)

`TireMarks` (`scripts/tire_marks.gd`, `class_name TireMarks extends Node3D`) lays
tyre marks behind the car's wheels while it drives on the road. The mark depends on
the surface under each wheel:
- **Gravel** — a gravel-coloured **rut**, laid whenever moving, whose **opacity tracks
  the tire FORCE** (newtons) going through the contact.
- **Tarmac** — a dark **skidmark**, laid only near the limit, whose **opacity tracks
  GRIP USAGE** across a narrow high band; a cleanly rolling wheel on tarmac leaves
  nothing at all.

The grass off the road footprint never marks. Created + wired by
`world.gd._generate_track` (reused across event regenerations, re-targeted on a car
swap in `world.gd.cycle_car`).

## Opacity: how hard the tire is working

Every segment carries its own **vertex alpha**, so a mark deepens through a corner
instead of every segment landing at one flat shade. The two surfaces read *different
quantities*, and the split is the interesting part:

| | Signal | Range | Why that signal |
|---|---|---|---|
| **Gravel** | tire **force**, N (`Drivetrain.wheel_force_n`) | linear, `0` → `tire_mark_gravel_full_force_n` | A rut is **shear work**, not proximity to the limit. A heavy car tracking straight is nowhere near letting go (low usage) yet still scuffs a visible line; a light car at 100% usage in a slow corner barely disturbs the surface. Force separates those, usage doesn't. |
| **Tarmac** | **grip usage** (`Drivetrain.wheel_grip_usage`) | `tire_mark_tarmac_grip_min` → `_max`, ~0.8 → 1.0 | Paved road takes no mark from normal driving *however heavy the car*. A tarmac skid is the tire **giving up**, which is exactly what usage measures (1.0 = on the limit) — so it starts high rather than ramping from zero. |

Both readings come off the **live** drivetrain, not its `readouts` dict — that is gated
on `publish_readouts` (the debug overlay's visibility) and the marks need these numbers
in every build. Same contract as `front_axle_state` for the steering servo; see
[drivetrain-and-tires.md](drivetrain-and-tires.md) → *Live per-wheel tire state*. The
debug grip grid and the marks therefore read the same fields and cannot disagree.

Two behaviours fall out of this rather than needing their own gates:
- **Below `tire_mark_min_alpha` nothing is laid at all** and the ribbon breaks. A quad
  that faint is invisible but still rasterises and still sorts in the transparent pass,
  so skipping it is free frame time — and it is what keeps a normally-driven tarmac
  road clean, replacing the old explicit "driven wheel + wheelspin" skid gate.
- Because the gate is grip usage and not wheelspin, an **undriven** wheel now marks too
  when it is at the limit — a locked front under braking, or the outside front in a
  hard corner. That is the physically right call and it is a deliberate change from the
  driven-only wheelspin gate this replaced.

The authored colour's own alpha multiplies the result, so a surface can be tuned never
to reach fully solid without touching the scales.

### Toggling the fade

`tire_mark_alpha_enabled` (default on) switches the whole thing off: ribbons render
**opaque**, exactly as before this landed. It changes only how *solid* marks are, never
*where* they appear — the min-alpha cull is gated on the raw strength, not the final
alpha, so both modes lay the identical set of segments. The flag is checked once per
`flush_uploads()` (one bool compare) and rebuilding the material re-dirties every
ribbon, so it is a **live** toggle: flip it in the inspector and the next frame that
lays a mark switches the look, without regenerating the track.

### Draw-call cost: none

Transparency adds **zero draw calls**. The count is fixed by the node structure — four
`MeshInstance3D`s, one surface each (`_upload` makes a single `add_surface_from_arrays`
call), and the two surface flavours already share one material via vertex colour, so
alpha rides in the existing colour channel with no material split. The four draws simply
move from the opaque pass to the alpha pass. What transparency *does* cost is per-pixel:
no early-Z rejection (which `terrain_chunk.gd` deliberately protects on tile GPUs), and
`DEPTH_DRAW_DISABLED` (see below) so crossing ribbons don't double-blend.

## Why a ribbon mesh

The project renders with `gl_compatibility` (desktop + mobile), which has **no
`Decal` support** — so each wheel gets a **persistent ribbon mesh**: a child
`MeshInstance3D` whose `ArrayMesh` grows as segments are appended. The triangle
buffer is maintained **incrementally** — a new segment appends one quad and a
dropped one trims a quad off the front — rather than reconstructed from the whole
segment list on every emit (`_build_ribbon` is the reference that incremental
buffer must equal, asserted in `test_tire_marks`).

**Uploads are coalesced to one per wheel per rendered frame.** Emitting a segment only
flags that wheel dirty (`_mark_dirty`); the snapshot copy plus the
`clear_surfaces` + `add_surface_from_arrays` + `surface_set_material` rebuild happen in
`_process` → `flush_uploads()`. Physics runs at 60 Hz and can tick twice per rendered
frame on a capped web build, and at speed a wheel emits nearly every tick, so this cuts
a large fraction of the driver-level buffer re-uploads with no visual change (the flush
runs after the frame's physics and before the draw, so a mark still appears on the frame
it was laid). `_process` is self-disabling — nothing dirty, no per-frame work.
`flush_uploads()` is also the explicit entry point tests use, since they drive
`_physics_process` directly. Same unshaded, cull-disabled
material style as the `wheel_force_debug` overlay. Each segment carries its
own **vertex colour** (the shared material has `vertex_color_use_as_albedo`), so one
ribbon per wheel shows both the gravel rut and the tarmac skid in their own shades —
and, with the fade on, its own **alpha**, so that one mesh also carries the whole range
of mark strengths.

With `tire_mark_alpha_enabled` the material adds `TRANSPARENCY_ALPHA` +
**`DEPTH_DRAW_DISABLED`**. The depth setting is not optional: ribbons are flat, coplanar
and they cross — the four wheels' trails over each other through a hairpin, one trail
over itself in a spin. Writing depth makes those crossings fight in the buffer, and
blending them twice darkens every overlap into a blob so the marks stop reading as
separate lines. `engine_smoke.gd` makes the same call for stacked puffs.

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
  - **Gravel** (`tarmac_weight ≤ 0.5`): colour `tire_mark_color`, strength from
    `_gravel_strength` — the tire FORCE over `tire_mark_gravel_full_force_n`. With no
    drivetrain to ask (flat fixtures) there is nothing to measure, so a solid rut is
    laid — the "gravel always marks" behaviour those fixtures had before.
  - **Tarmac** (`tarmac_weight > 0.5`): colour `tire_mark_tarmac_color`, strength from
    `_tarmac_strength` — GRIP USAGE ramped across
    `tire_mark_tarmac_grip_min`..`_max`. With no drivetrain we cannot tell a skid from
    cruising, so nothing is reported and paved road stays clean, as it did before.

  A strength at or below `tire_mark_min_alpha` **breaks the ribbon and lays nothing** —
  that is what keeps a normally-driven tarmac road clean, and it is gated on the raw
  strength so the fade toggle never moves where marks appear. Otherwise, once the wheel
  has moved ≥ `tire_mark_segment_step_m` since its last point,
  append a ribbon segment — a left/right pair across the road normal at the wheel's
  **contact patch** (`y = hub.y − wheel_radius + tire_mark_ground_offset_m`, NOT
  `terrain.height_at` — near the road the terrain mesh is flattened to the baked road
  height the car rides on, so the raw noise height would sink the ribbon under the
  road in cuts/dips). On the grass, below the strength floor, or airborne, the
  ribbon **breaks** (a fresh strip starts later, no line across the gap).
- **Cap** — each wheel's segment list is a ring buffer of `tire_mark_max_segments`
  (oldest recycled, and its leading quad trimmed off the mesh buffer); only the
  wheel's own surface re-uploads on a new segment. Memory is bounded and the chase
  cam looks forward, so far-behind marks are off-screen.
  The trail length is `tire_mark_max_segments × tire_mark_segment_step_m` — at the
  configured 20 × 0.5 m that is a **10 m** trail behind each wheel.

## Centerline lookups (performance)

`_search_offset` (car and per-wheel), the road gate and `_normal_at` do **not** call
`Curve2D.sample_baked`. They read the shared baked centerline table that `TrackProgress`
owns — `TrackProgress.baked_points(centerline)`, resolved once in `setup` — through the
interpolating `point_on` accessor. See [progress.md](progress.md) → *Baked centerline
table* for why, and for the rule that the lookup must interpolate rather than truncate.

## Colour

Per-segment vertex colour, so the two surfaces read differently in one ribbon:
- `tire_mark_color` — the gravel rut, a touch darker than the gravel (gravel.jpg
  averages ~0.42 grey).
- `tire_mark_tarmac_color` — the tarmac skid, a dark near-black scuff.

Each colour's **alpha is the fully-worked ceiling**, multiplied by the segment's
strength (see *Opacity* above) — so a surface can be tuned never to reach solid without
touching the force/usage scales. Unshaded material, cull disabled,
`vertex_color_use_as_albedo` on, plus `TRANSPARENCY_ALPHA`/`DEPTH_DRAW_DISABLED` while
the fade is enabled.

## Configuration

All in `GameConfig` (the "Tire Marks" group): `tire_marks_enabled`,
`tire_mark_color`, `tire_mark_tarmac_color`, `tire_mark_width_m`,
`tire_mark_min_speed_mps`, `tire_mark_segment_step_m`, `tire_mark_max_segments`,
`tire_mark_ground_offset_m`, `tire_mark_gravel_margin_m`.

Opacity: `tire_mark_alpha_enabled` (the master toggle),
`tire_mark_gravel_full_force_n` (newtons for a solid gravel rut),
`tire_mark_tarmac_grip_min` / `tire_mark_tarmac_grip_max` (the grip-usage band a tarmac
skid fades in across), `tire_mark_min_alpha` (below this nothing is laid).

## Tests

`tests/headless/test_tire_marks.gd` — a straight `Curve2D` + stub car/wheels + a stub
drivetrain (reporting a force and a grip usage) drive the logic without a vehicle or
rendering. Placement: four ribbons collected, gravel ruts accumulate, none off the
footprint (grass), a sub-step move adds nothing, the ring buffer caps the count, below
the speed floor lays nothing, an airborne wheel stops marking, and a jump leaves a real
gap (the landing point starts a new strip, not a stretched quad bridged back to the
take-off point). Opacity: a gravel rut darkens with tire force and clamps solid at the
reference, a negligible force lays no segment at all, a tarmac skid is absent below the
grip band, fades in across it and is solid past it, and disabling the fade lays the SAME
segments at full opacity. Material: the ribbons sit in the alpha pass with depth-write
off only while the fade is on, and flipping the toggle re-uploads every ribbon against
the rebuilt material.

The band/reference values are set BY the tests rather than read from the config, so they
exercise the ramp rather than pinning whatever is currently authored.

`tests/headless/test_drivetrain.gd` covers the source of those numbers: the live
per-wheel state is published without the debug overlay, matches the overlay's `applied`
/ `grip` readings when it IS up, and reports zero for an airborne wheel.

## Shader warm-up

The ribbon material has the same `gl_compatibility` first-visible-draw compile
cost as the particle pools. `warm_up(pos)` draws a throwaway quad (same material)
in front of the camera and `clear_warm_up()` frees it, so
`world.gd._generate_track` primes the shader behind the loading overlay rather
than hitching on the first mark laid — see
[wheel-dust.md → Shader warm-up](wheel-dust.md).

## Out of scope (features/tire-marks.md)

Alpha fade-out **over distance / age** — a mark's opacity is set once when it is laid
and never changes, so a trail does not fade behind the car; the ring-buffer cap is what
bounds it. (Opacity by tire load IS modelled now — see *Opacity* above. An earlier
attempt at load-based COLOUR variation was tried and reverted, since darkening the hue
rather than the alpha didn't read well.)

Marks are laid for the **player's car only** — opponents and replay ghosts leave none.
