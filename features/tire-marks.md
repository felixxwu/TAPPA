# Tire marks (gravel ruts + tarmac skids)

`TireMarks` (`scripts/tire_marks.gd`, `class_name TireMarks extends Node3D`) lays
tyre marks behind the car's wheels while it drives on the road. The mark depends on
the surface under each wheel:
- **Gravel** — a **rut**, laid whenever moving, whose **opacity tracks
  the tire FORCE** (newtons) going through the contact.
- **Tarmac** — a **skidmark**, laid only near the limit, whose **opacity tracks
  GRIP USAGE** across a narrow high band; a cleanly rolling wheel on tarmac leaves
  nothing at all.

Both marks are **pure black**; only their opacity differs. See *Colour* below for why
that is the whole design and not just a palette choice.

The grass off the road footprint never marks. Created + wired by
`world.gd._generate_track` (reused across event regenerations).

**Tests:** `tests/headless/test_tire_marks.gd`, `tests/headless/test_drivetrain.gd`

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

The authored colour's own alpha multiplies the result — it is the per-surface ceiling,
so a surface is tuned by how dark it may ever get, without touching the scales.

### Toggling the fade — a debug/perf fallback, not a second look

`tire_mark_alpha_enabled` (default on) is a **debug and performance escape hatch**, not
an alternative art direction. Off, the ribbons go back in the **opaque** pass, which
discards alpha — and since both mark colours are now pure black, that means **solid
black trails**, not the flat grey it used to give. It buys back early-Z and the alpha
pass; it does not give a usable look. It changes only how *solid* marks are, never
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

**Uploads happen eagerly, one per emitted segment.** Emitting a segment immediately
runs the snapshot copy plus the `clear_surfaces` + `add_surface_from_arrays` +
`surface_set_material` rebuild for that wheel (`_upload`, called from `_emit_segment`).
This used to be batched to once per rendered frame (flagging the wheel dirty and
flushing in `_process`), but physics can tick more than once per rendered frame, and a
wheel's ribbon could then visibly lag the tick that laid it — so it uploads on every
tick instead, trading some redundant driver-level re-uploads for marks that are never a
frame behind. `flush_uploads()` still exists as an explicit re-upload of every wheel,
used by the live `tire_mark_alpha_enabled` toggle (a rebuilt material needs the
*existing* ribbons re-pushed, not just the next one laid) and as the entry point tests
use. Same unshaded, cull-disabled
material style as the `wheel_force_debug` overlay. Each segment carries its
own **vertex colour** (the shared material has `vertex_color_use_as_albedo`), so one
ribbon per wheel carries both the gravel rut and the tarmac skid — which, both being
black, differ *only* in their **alpha**, so with the fade on that one mesh carries both
surfaces and the whole range of mark strengths in a single channel.

With `tire_mark_alpha_enabled` the material adds `TRANSPARENCY_ALPHA` +
**`DEPTH_DRAW_DISABLED`**. The depth setting is not optional: ribbons are flat, coplanar
and they cross — the four wheels' trails over each other through a hairpin, one trail
over itself in a spin. Writing depth makes those crossings fight in the buffer, and
blending them twice darkens every overlap into a blob so the marks stop reading as
separate lines. `engine_smoke.gd` makes the same call for stacked puffs.

## Ungated mode (the overworld)

`setup(centerline, …)` accepts a **null** centerline, which switches the node into
*ungated* mode (`_ungated`). The overworld hub has no single `Curve2D` — it has a road
NETWORK (the deleted `overworld.gd::_road_polylines`) — so there is no corridor to test against.
In ungated mode:

- the car-offset cache and both windowed nearest-point searches are skipped entirely
  (`_pts` stays empty, `_baked_length` 0);
- whether a wheel may mark is decided by `TerrainManager.surface_at()` alone: its road
  weight (`.x`) must exceed `UNGATED_ROAD_WEIGHT_MIN`, since the hub's roads are carved
  into the terrain's surface weights. Open ground reads as grass and breaks the ribbon,
  the same outcome the stage's half-width gate produces;
- the last-resort across-direction (see *Width and direction* below) falls back to the CAR's
  right axis rather than a curve tangent.

Everything else — the gravel/tarmac split, the force/grip-driven strength and colour,
the ring buffers, the eager upload, the material and the shader warm-up — is shared.
Supplying a centerline restores the stage's corridor gate; nothing else differs.

## Width and direction

A segment point is the tyre's contact CENTRE, spread half the mark's width either side of it
along a unit XZ direction. Two rules, both in `tire_marks.gd`:

- **The direction is perpendicular to TRAVEL, never to the tyre's heading** (`_across_dir`).
  It used to come from the road normal (stage) / the car's right axis (overworld), i.e. from the
  heading — which is only perpendicular to travel while the car tracks straight. In a slide or a
  spin the travel direction rotates away from the heading, and once travel lines up with the
  spread direction the pair's two verts advance ALONG the ribbon rather than across it:
  consecutive pairs go collinear and every quad collapses into a sliver. The mark went narrow
  exactly when the car was doing the thing that should mark most. Sources in order: this wheel's
  own travel since its last point, then the car's `linear_velocity`, then (only if the car is
  somehow at rest, which the speed gate already excludes) the old heading-derived normal
  `_across_normal` / `_normal_at`.
- **The width is the TYRE's width** (`_tire_width_of`): `GameConfig.wheel_width_front` /
  `wheel_width_rear`, which `car.gd` writes from the fielded car's `CarLibrary` spec — the same
  numbers that size the tyre cylinders and feed load sensitivity. Steering wheels count as the
  front axle, exactly as `car.gd::_relocate_wheels` decides it, so a staggered car leaves wider
  rear marks than front ones. `tire_mark_width_m` is now only the FALLBACK for a spec that
  authors no width (and for the flat test fixtures, whose stub wheels have no
  `use_as_steering`).

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
  append a ribbon segment — a left/right pair spread around the wheel's contact centre
  perpendicular to its TRAVEL (see *Width and direction*), at the wheel's
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

Both authored colours — `tire_mark_color` (the gravel rut) and `tire_mark_tarmac_color`
(the tarmac skid) — are **pure black**. Their RGB carries no information at all; the
only thing that distinguishes the two surfaces is the **alpha**, which is that
surface's **ceiling**: how dark a fully-worked tire can ever get on it. `tire_marks.gd`
multiplies the segment's strength (see *Opacity* above) by that authored ceiling, so the
ceiling sets the top of the range and the strength picks a point inside it. Gravel's
ceiling is the **shallower** of the two, and that is the physical claim: a rut is
*displaced surface*, while a tarmac skid is *deposited rubber* and goes darker at its
worst. Both live in `config/game_config.tres` and are free to be retuned.

**Why black rather than an authored grey.** Every material in this renderer is
`unshaded`, so nothing dims because the world got darker — the bug class
[weather.md](weather.md) → *Unshaded means nothing dims for free* documents. A constant
grey rut was exactly that bug: it stayed as bright at night, in fog and on snow as it
did on a sunlit gravel road, and so it read as a stripe of **paint sitting on top of
the world** rather than a scuff *in* it. Black at partial opacity instead **darkens
whatever ground is underneath it**, so the mark is derived from the surface it is laid
on and tracks the environment for free — every weather condition, every region,
including snow — with **no per-weather plumbing**, no `weather_lit` call and nothing to
re-seed per stage. Same problem as the `weather_lit` family, solved from the other
side: opacity rather than a lit colour.

Unshaded material, cull disabled,
`vertex_color_use_as_albedo` on, plus `TRANSPARENCY_ALPHA`/`DEPTH_DRAW_DISABLED` while
the fade is enabled.

## Configuration

All in `GameConfig` (the "Tire Marks" group): `tire_marks_enabled`,
`tire_mark_color`, `tire_mark_tarmac_color`, `tire_mark_width_m` (fallback only — the
width normally comes from the tyre, see *Width and direction*),
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
segments. The opacity tests assert the segment reaches its surface's **authored
ceiling** at full strength (they used to assert a hardcoded 1.0, which the ceilings
made wrong). Colour: `test_both_mark_colours_are_pure_black` and
`test_a_laid_mark_is_black_whatever_the_surface` guard the contract that the RGB is
black on both surfaces and stays black through the laying path — the alpha is the only
channel allowed to differ, so a future retune can move the ceilings but not
re-introduce a grey. Material: the ribbons sit in the alpha pass with depth-write
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
