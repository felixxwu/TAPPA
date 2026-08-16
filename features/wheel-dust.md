# Wheel particles (surface debris)

`WheelParticles` (`scripts/wheel_particles.gd`, `class_name WheelParticles extends
CpuParticlePool`) flings cheap debris backwards from the **driven** wheels whenever
they spin faster than the ground — a standing burnout, a wheelspin launch, or a
spinning slide. **One pool serves every surface**, with each particle carrying its
own colour, dimensions and roll picked at emit time: grey-brown clods on gravel,
slim green blades on grass, nothing on tarmac (see "Per-particle look" below). Created + wired by `world.gd._generate_track` (reused
across event regenerations), exactly like `TireMarks`.

## Why a hand-rolled CPU pool + MultiMesh

The project renders with `gl_compatibility` (desktop + mobile), which has no
`Decal` support and only thin GPU-particle physics. So the spray is the **cheapest
particle that still reads as a bit of thrown-up ground**: a CPU particle pool drawn
through a single `MultiMesh` of small **billboarded quads** — one draw call, one
shared 2-triangle mesh, a fixed `instance_count`, no per-particle scene nodes. The
material is unshaded, cull-disabled and opaque.

## Shared pool base — `CpuParticlePool`

The ring-buffer machinery is shared with [engine smoke](engine-smoke.md) via a
common base, `CpuParticlePool` (`scripts/cpu_particle_pool.gd`, `extends
MultiMeshInstance3D`). The base owns the parallel `_pos` / `_vel` / `_life` arrays
and the live transform `_buffer`, the ring-buffer write cursor (`_next`) + live/max
counters, `_clear()` / hide-off-screen, the `warm_up()` / `clear_warm_up()`
shader-compile dance, `_emit_slot()` (the ring recycle), and the `live_count()` /
`max_particles()` test readouts. Subclasses supply only what differs: their `STRIDE`
(via `_stride()`), the per-slot buffer writer (`_build_slot()` for a warmed-up slot,
plus their own writer), how a dead slot is parked (`_hide_slot()`), the per-tick
integration (`_advance()`), and the emission source (`_physics_process()`). Direct
coverage of the base ring lives in `tests/headless/test_cpu_particle_pool.gd`.

## Per-particle look (colour, dimensions, roll)

Every particle carries its own **colour**, **half-extents** and **roll**, chosen at
emit time by `_look_for_surface` from the one `surface_at` sample the emitter
already takes, then **frozen for the particle's whole life**. A `Look` (an inner
`RefCounted`: `half_w`, `half_h`, `color`) is built by `_gravel_look` (a square
clod at `wheel_particle_size_m`) or `_grass_look` (a slim blade at
`wheel_particle_grass_width_m` x `wheel_particle_grass_length_m`); tarmac returns
`null` and throws nothing. `_jittered` then varies the brightness per particle by
+/- `wheel_particle_color_jitter` so a burst reads as many separate bits of debris
rather than one flat smear.

The grass blade colour is per-region: `_grass_look` uses `wheel_particle_grass_color`
(`game_config.gd`, tuned to the home world's `textures/grass.jpg`) unless
`world.gd` has set `WheelParticles._grass_color_override` from the driven rally's
`RegionLibrary.look_of()["grass_particle_color"]` (e.g. Greece's dry olive/tan,
tuned to `textures/grass-greece.jpg`, instead of the home green). `world.gd` sets
the override once via `set_grass_color_override()` right after `_wheel_particles.setup()`,
since the region is fixed for the world's lifetime. A region that authors no
override falls back to the GameConfig default (alpha-0 `Color()` is the "unset"
sentinel).

A region may also override the off-road particle's SHAPE, via
`RegionLibrary.look_of()["grass_particle_square"]` and the matching
`WheelParticles.set_grass_square_override()`. The default particle is modelled as a
torn-up blade of grass — slim and tall (`wheel_particle_grass_width_m` /
`wheel_particle_grass_length_m`) — which stays wrong when merely recoloured: the Alps
throws clods of powder, not white blades. When set, `_grass_look` returns the square the
gravel clod already uses, sized off the same `wheel_particle_size_m` so the two cannot
drift apart. The COLOUR is still the region's, so this stays white spray rather than
becoming dirt. Every other region omits the key and keeps the blade.

### Why a hand-written billboard shader

`BaseMaterial3D`'s `BILLBOARD_ENABLED` rebuilds the model-view basis from the
camera columns every frame and **discards whatever basis the MultiMesh supplied**,
keeping only the origin. That is free when every particle is an identical square —
the pool used to pre-seed an identity basis and rewrite only the origin — but it
leaves nowhere for a per-particle rotation to live. `billboard_keep_scale`
re-applies the instance *scale* after the fact, but never a roll.

So the billboard is done by hand in `shaders/billboard_particle.gdshader`
(screen-aligned off `INV_VIEW_MATRIX`'s right/up columns, direct `POSITION`
rewrite — the same approach as `shaders/billboard.gdshader`), and the instance
basis is *read* instead of thrown away:

    column 0 = (cos * half_w,  sin * half_w, 0)   -> length = half_w, direction = roll
    column 1 = (-sin * half_h, cos * half_h, 0)   -> length = half_h

Column **lengths** carry the half-extents and column 0's **direction** carries the
roll, so the transform stride stays the standard 12 floats — no `INSTANCE_CUSTOM`,
no extra per-instance stream. `_write_slot` in `wheel_particles.gd` writes that
layout (row-major, so column 0 is floats 0/4/8 and column 1 is floats 1/5/9); the
shader header documents the same contract from the other side. Keep the two in
sync if you change it.

The **spawn angle is frozen**, not tumbling: a tumbling blade would mean rewriting
nine basis floats per particle per tick, where a fixed angle costs nothing after
emit. `_advance` still touches only the three origin floats.

## Ring buffer

The pool is a fixed-size **ring buffer** of `wheel_particle_max` slots (parallel
`_pos` / `_vel` / `_life` arrays, index == MultiMesh instance). A new clod is
written at `_next = (_next + 1) % max`, so once full it **overwrites the oldest
slot first**. Memory and draw cost are hard-capped no matter how long the wheels
spin. Dead slots are parked far below the world (origin Y = `HIDE_Y`) rather than
zero-scaled — billboard materials don't reliably honour a zero instance scale
under `gl_compatibility`, and a quad that far down is always off-screen.

## Shader warm-up (no first-gravel hitch)

Under `gl_compatibility` a material's shader variant compiles on its **first
visible draw**. Because the pool sits off-screen at `HIDE_Y` until the first
gravel wheelspin, that compile used to land as a one-frame stutter the moment a
car crossed onto gravel. `warm_up(pos)` parks one full-size clod in front of the
camera so the variant compiles up front, and `clear_warm_up()` hides it again;
`world.gd._generate_track` calls this (for the dust, smoke, and tyre-mark
materials) while the loading overlay still covers the view, so the compile is
hidden. It only runs when a loading screen is up — on a bare regeneration the
variant is already cached (identical renderer settings) and there's no overlay to
hide a flash.

## Performance — one buffer upload, not N transform calls

The instance transforms are pushed as a **single `multimesh.buffer` assignment
per tick**, not per-instance `set_instance_transform()` calls. A slot's basis
(size + roll) and colour are written **once at emit** and never touched again, so
only the three origin floats per slot are rewritten each tick in a persistent
`PackedFloat32Array` (`_buffer`, `STRIDE` = 16 floats/instance: a 3x4 row-major
transform with the origin at offsets 3/7/11, then RGBA at 12-15, via
`multimesh.use_colors`). N
per-instance engine round-trips a frame is the classic MultiMesh trap — it murders
mobile/WebGL; one bulk upload sidesteps it. The upload is **skipped entirely when
nothing changed**: `_advance` is a no-op while `_alive == 0`, so an idle car (or
one driving cleanly with no wheelspin) does ~zero per-frame particle work. The
surface gate is a single `TerrainManager.surface_at` dictionary lookup (no
centerline search), evaluated only after a wheel has already passed the wheelspin
test.

Because **all surfaces share one pool**, total particle cost is bounded by
`wheel_particle_max` wherever the car is — driving on grass does not add a second
pool, a second draw call, or a second cap. If the spray still costs too much on a
weak device, the cheapest dials (in order of impact) are `wheel_particle_max`
(pool size = the per-tick loop length), `wheel_particle_spawn_count`, and
`wheel_particle_lifetime_s` (fewer particles alive at once).

## Per-tick logic

Each `_physics_process` (skipped when `wheel_particles_enabled` is off):
- **Advance** the live pool: each clod gets `wheel_particle_gravity_mps2`
  downward (sells the weight) and a slight `wheel_particle_air_resistance` linear
  drag (so fast clods decelerate a touch in flight rather than flying dead
  straight), then ages by `delta` and recycles at `wheel_particle_lifetime_s`.
  This runs every tick so airborne clods finish their arc after the wheels stop.
- **Emit** from each wheel that is (1) **driven** (`Drivetrain.is_wheel_driven`,
  per the drive mode — undriven wheels free-roll and never throw dirt), (2) in
  contact, (3) **past its longitudinal grip limit**, and (4) on the gravel or grass:
  - **Traction-break test** — `Drivetrain.wheel_long_grip_usage(wheel) >=
    wheel_particle_min_long_grip` (default `1.0`). Longitudinal grip usage is the slip
    ratio over the slip ratio the tire actually peaks at, so above 1.0 the tread has
    passed the point where it grips best and is **tearing material loose** rather than
    driving through it. That is the condition that throws debris.

    This replaced a raw slip-SPEED floor (`surface_speed − v_long > 1.5 m/s`), which
    could not make that call: the slip a tire tolerates scales with how fast it is
    going, and with the surface (loose gravel peaks at roughly twice the slip ratio
    tarmac does — see the `gravel_slip_peak` / `tarmac_slip_peak` split in
    [drivetrain-and-tires.md](drivetrain-and-tires.md)). Any fixed m/s threshold
    therefore sprays dirt from a tire that is still gripping at speed, while a
    genuinely spinning wheel at walking pace throws none.

    The reading is **unsigned**, so a wheel LOCKED under braking counts as well as one
    spinning up under power. It is also purely the fore/aft axis, so a big lateral
    slide neither triggers nor suppresses the spray — a car drifting sideways at speed
    still throws dirt exactly as long as its tread is breaking traction fore/aft.

    Note the throw below still keys off `surface_speed`, so a lockup (little tread
    speed) throws a short spray near the contact patch rather than a rooster tail.
  - **Surface chooser** (`_look_for_surface`) — one
    `Drivetrain.terrain.surface_at(x, z)` lookup returns `(road_weight,
    tarmac_weight)` and picks the flavour rather than merely rejecting:
    `road_weight < ROAD_WEIGHT_MIN` is off the road footprint -> **grass blades**;
    otherwise `tarmac_weight > TARMAC_WEIGHT_MAX` is **tarmac** -> nothing;
    otherwise **gravel clods**. Both thresholds sit at the midpoint of the same
    feather bands the road colour/grip blend across. With no terrain wired (flat
    fixtures), nothing is thrown. This reuses the surface system added for
    per-surface grip — see `features/drivetrain-and-tires.md`.

## Throw direction & speed

Dirt sprays the way the tread is really dragged across the ground. The tread at
the contact patch slides over the ground at `scrub = vel − fwd * surface_speed`
(chassis velocity minus the backward-running tread surface velocity); clods are
thrown along `scrub.normalized()`:
- A **standing burnout** → straight backwards along the wheel's heading (`−fwd`).
- A **spinning slide** → tilts sideways too, so the spray follows the real scrub
  direction.

Speed tracks the wheel's spin (`surface_speed * wheel_particle_speed_scale`),
tipped up by `wheel_particle_up_speed_mps` and scattered into a cone by
`wheel_particle_spread` (which grows with how hard the wheel spins). `wheel_particle_spawn_count`
clods are emitted per spinning wheel per tick.

## Configuration

All in `GameConfig` (the "Wheel Particles" group): `wheel_particles_enabled`,
`wheel_particle_color`, `wheel_particle_grass_color`,
`wheel_particle_grass_width_m`, `wheel_particle_grass_length_m`,
`wheel_particle_color_jitter`, `wheel_particle_max`, `wheel_particle_size_m`,
`wheel_particle_min_long_grip`, `wheel_particle_lifetime_s`,
`wheel_particle_speed_scale`, `wheel_particle_up_speed_mps`,
`wheel_particle_gravity_mps2`, `wheel_particle_air_resistance`,
`wheel_particle_spawn_count`, `wheel_particle_spread`.

## Surfaces

The live `surface_at` sample drives all three cases: **gravel** road throws square
grey clods, **grass** (off the road footprint) throws slim green blades, and
**tarmac** (paved) throws nothing. Adding a further surface means one more `Look`
in `_look_for_surface` — no new pool, mesh, material or draw call.

## Tests

`tests/headless/test_wheel_particles.gd` — a stub car with a stub drivetrain, stub
wheels and a stub terrain surface drive the gating / emission / ring-buffer logic
without a real vehicle or rendering: dirt flies from a driven, spinning, on-gravel
wheel; none from an undriven wheel, a wheel rolling no faster than the ground, or a
wheel on tarmac; a wheel on grass throws grass; a spinning *and* sliding wheel
still emits and throws backward + sideways; and the ring buffer caps the live count.

The per-particle look has its own cases: gravel and grass share one pool/cap,
`_write_slot`'s basis encodes the half-extents as column lengths and the roll as
column 0's direction (asserted against the values passed in, not against authored
config), the two half-extent axes stay independent (a slim blade stays slim), the
colour lands in the trailing RGBA floats, `_advance` moves a particle's origin
while leaving its basis + colour frozen, and `_look_for_surface` returns grass /
gravel / `null` for the three surfaces.
