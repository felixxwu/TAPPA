# Dust puffs (opaque blocky dust clouds)

`DustPuffs` (`scripts/dust_puffs.gd`, `class_name DustPuffs extends CpuParticlePool`)
leaves a trail of **opaque, flat-shaded low-poly clouds** behind all four wheels while
the car drives on a road: gravel-coloured on gravel, near-white on tarmac. It **replaced** the gravel clods that
[`WheelParticles`](wheel-dust.md) used to throw on wheelspin; that pool now throws
only off-road debris (grass blades, snow clods). Created + wired by
`world.gd._generate_track` (`_dust_puffs`, reused across regenerations) and in free
roam by `free_roam.gd._ready`, where `BiomeDirector._seat_particle_look` re-seats the
region colour on every ring change.

**Tests:** `tests/headless/test_dust_puffs.gd`. **Look check:** `tools/dust_capture.tscn`
(boots free roam, holds the throttle on a gravel road, writes a chase and a side
screenshot to `tools/dust_capture_<n>.png`; run line in the script header).

## Why opaque meshes

Big see-through puffs behind a chase camera are the classic mobile fill-rate trap:
every layer is blended over the same pixels and the pool has to be depth-sorted.
Opaque, depth-writing puffs are drawn once per pixel with no sorting, and the
flat-shaded facets fit the low-poly look. The cost is that a puff cannot fade: it
**simply disappears** at the end of its life (parked at `HIDE_Y`, like every pool).

## One mesh, everything else in the transform

`DustPuffs.build_blob_mesh()` builds ONE 20-face icosahedron at load, with its
corners pushed in/out a little (fixed `BLOB_SEED`) so it reads as a lump rather than
a die, and **flat-shaded**: every face has its own three vertices and one normal.
All instances share it through one MultiMesh (one draw call). Nothing about the mesh
changes after load.

Variety and growth live in each instance's basis:
- At emit, `_emit_puff` picks a random tumble (a random unit quaternion) times an
  uneven per-axis stretch times an overall size spread, and stores that unit-size
  "birth shape" in `_shape` (9 floats per slot).
- Every tick `_advance` writes `birth shape x size_at(t)` into the buffer, so a puff
  grows by changing 9 basis floats, not by touching vertices. `size_at` eases out
  from `dust_puff_size_m` to `size x dust_puff_growth`, so a puff billows fast then
  hangs. Colour (jittered per puff) is written once at emit.

The whole buffer is still pushed with one `multimesh.buffer` assignment per tick,
and only when something is alive or spawned.

## Shader — `shaders/dust_puff.gdshader`

Unshaded with the car's fake per-vertex sun/sky/ground lighting (the
`ps1_models_lit` block, fed by `GameConfig.apply_car_light`, re-applied each tick a
puff is alive so weather changes reach a live trail). Normals go through
`MODEL_NORMAL_MATRIX` because puffs are non-uniformly stretched.

**Near-camera hiding:** the chase camera drives straight through the trail, and a
solid polygon sliding through the lens would black out the screen. The vertex
shader scales each puff by `smoothstep(camera_hide_m, camera_show_m, distance from
camera to the puff's centre)`, so puffs near the lens shrink to nothing.

## Emission

`_emit_from_wheels` walks `drivetrain.front_wheels + drivetrain.rear_wheels`. A wheel raises dust when it is
in contact, its ground speed (`velocity_at` at the contact patch, horizontal) is at
least `dust_puff_min_speed_mps` **or the tyre is sliding** (same grip-usage test as tarmac
smoke, below — so wheelspin puffs at any speed), and `color_for_surface(surface_at(...))` returns a
colour (the same `ROAD_WEIGHT_MIN` / `TARMAC_WEIGHT_MAX` midpoints as the wheel
debris): the gravel colour on gravel, `dust_puff_tarmac_color` on tarmac, and alpha 0
(nothing) on grass. Tarmac dust is new — the wheel debris throws nothing there.

**Tarmac only smokes while a tyre slides, and never in the wet.** Gravel dust comes
off any rolling wheel, but on tarmac `tarmac_smokes(cfg, grip_usage)` also requires
`Drivetrain.wheel_grip_usage(wheel)` (the combined fore/aft + sideways figure the HUD
grip grid shows; above 1.0 the tyre is sliding) to be at least
`dust_puff_tarmac_min_grip`. So wheelspin, a lockup and a drift all smoke on dry
tarmac; clean driving doesn't.

**Nothing in the wet.** While `WeatherLibrary.is_wet(cfg.weather)` (rain, storm) no
puffs are raised on any surface: wet gravel makes no dust and a wet road no tyre smoke. Emission is **by distance**: each wheel accumulates
metres travelled in `_travel` and drops a puff every `dust_puff_spacing_m`, so the
trail density is the same at any speed and frame rate. Grip doesn't matter, unlike
the wheelspin clods.

**Emission rate** is the faster of the wheel's horizontal ground speed and its
**slip speed** (`scrub.length()`, below). Only the ground speed is gated at
`dust_puff_min_speed_mps`; the slip speed counts whenever the tyre slides
(`tarmac_smokes`), so a standing or slow burnout raises dust from a stationary car.

### Throw: slip vs wake

At the contact patch the tread slides over the ground at
`scrub = velocity_at(cp) - wheel_forward * wheel_omega * radius` (the same quantity
the wheel debris throws along). `puff_velocity(cfg, car_vel, scrub)` is
`car_vel * dust_puff_inherit + scrub * dust_puff_slip_throw`:
- **standing burnout** — scrub is `-fwd x spin speed`, so puffs shoot straight back
  at about the slip speed;
- **rolling cleanly at speed** — scrub ~0, so puffs only get the wake term and drift
  after the car a little;
- **locked wheel** — scrub is the car's velocity, so dust sprays ahead;
- **drift** — scrub has a sideways part, so puffs fling out to the side.

The same rule applies on gravel and tarmac (tarmac only emits while sliding anyway).
On top: `dust_puff_rise_mps` up and random `dust_puff_scatter_mps`. A new puff starts
on the ground at the contact patch (lifted by its own radius, scattered across the tyre
width), then slows under `dust_puff_drag`. Lifetime is `dust_puff_lifetime_s` +/- 20%.

### Warm-up

`DustPuffs` overrides `warm_up` / `clear_warm_up` to switch the near-camera hide off
for the warmed frame. The warm-up point is 2 m in front of the camera, inside the hide
range, so otherwise the warm puff drew shrunk; this way it draws full-size through the
real path and the shader compiles behind the loading cover.

## Colour

Gravel dust is the gravel's own colour. `GameConfig.dust_puff_color` is the average
of `textures/gravel.jpg`; a region with its own `gravel_texture` authors the matching
average as its `dust_color` look key (in `RegionLibrary.LOOK_KEYS`), read by
`apply_region_look(look)`: Greece (`gravel-greece.jpg`) and the Alps
(`snow-road.jpg`). **If you change a region's gravel texture, re-average it** (e.g.
PIL: `Image.open(f).convert("RGB").resize((1,1), Image.BOX)`). The averages are
authored rather than read off the texture at runtime because the imported textures
are VRAM-compressed, and decompressing them is not reliable on every platform.

Tarmac dust is `GameConfig.dust_puff_tarmac_color`, near-white, for every region.

## Configuration

`GameConfig` "Dust Puffs" group: `dust_puffs_enabled`, `dust_puff_color`,
`dust_puff_tarmac_color`, `dust_puff_tarmac_min_grip`,
`dust_puff_color_jitter`, `dust_puff_max`, `dust_puff_size_m`, `dust_puff_growth`,
`dust_puff_lifetime_s`, `dust_puff_spacing_m`, `dust_puff_min_speed_mps`,
`dust_puff_inherit`, `dust_puff_slip_throw`, `dust_puff_rise_mps`, `dust_puff_scatter_mps`,
`dust_puff_drag`, `dust_puff_camera_hide_m`, `dust_puff_camera_show_m`. First-pass
values pending playtest. If it costs too much on a weak device, the dials are
`dust_puff_max`, `dust_puff_spacing_m` and `dust_puff_lifetime_s`.

## Not done yet (ideas)

Shrink or dither out at end of life instead of popping; dust off-road in dry/snowy
regions; size scaled by speed.
