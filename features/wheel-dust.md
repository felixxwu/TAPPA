# Wheel dust (gravel spray)

`WheelParticles` (`scripts/wheel_particles.gd`, `class_name WheelParticles extends
MultiMeshInstance3D`) flings cheap gravel/dirt clods backwards from the **driven**
wheels whenever they spin faster than the ground — a standing burnout, a wheelspin
launch, or a spinning slide. Created + wired by `world.gd._generate_track` (reused
across event regenerations, re-targeted on a car swap in `world.gd.cycle_car`),
exactly like `TireMarks`.

## Why a hand-rolled CPU pool + MultiMesh

The project renders with `gl_compatibility` (desktop + mobile), which has no
`Decal` support and only thin GPU-particle physics. So the spray is the **cheapest
particle that still reads as a clod of dirt**: a CPU particle pool drawn through a
single `MultiMesh` of small **billboarded quads** — one draw call, one shared
2-triangle mesh, a fixed `instance_count`, no per-particle scene nodes. The
material is unshaded, cull-disabled, billboarded, tinted to the gravel colour (same
style as the tire marks / debug overlays).

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
per tick**, not per-instance `set_instance_transform()` calls. Each slot keeps an
identity basis (the billboard material orients the quad anyway), so only the three
origin floats per slot are ever rewritten in a persistent `PackedFloat32Array`
(`_buffer`, `STRIDE` = 12 floats/instance, origin at offsets 3/7/11). N
per-instance engine round-trips a frame is the classic MultiMesh trap — it murders
mobile/WebGL; one bulk upload sidesteps it. The upload is **skipped entirely when
nothing changed**: `_advance` is a no-op while `_alive == 0`, so an idle car (or
one driving cleanly with no wheelspin) does ~zero per-frame particle work. The
surface gate is a single `TerrainManager.surface_at` dictionary lookup (no
centerline search), evaluated only after a wheel has already passed the wheelspin
test.

If the spray still costs too much on a weak device, the cheapest dials (in order
of impact) are `wheel_particle_max` (pool size = the per-tick loop length),
`wheel_particle_spawn_count`, and `wheel_particle_lifetime_s` (fewer clods alive
at once).

## Per-tick logic

Each `_physics_process` (skipped when `wheel_particles_enabled` is off):
- **Advance** the live pool: each clod gets `wheel_particle_gravity_mps2`
  downward (sells the weight) and a slight `wheel_particle_air_resistance` linear
  drag (so fast clods decelerate a touch in flight rather than flying dead
  straight), then ages by `delta` and recycles at `wheel_particle_lifetime_s`.
  This runs every tick so airborne clods finish their arc after the wheels stop.
- **Emit** from each wheel that is (1) **driven** (`Drivetrain.is_wheel_driven`,
  per the drive mode — undriven wheels free-roll and never throw dirt), (2) in
  contact, (3) **spinning faster than the ground**, and (4) on the gravel:
  - **Wheelspin test** — `surface_speed (omega x radius) − v_long > wheel_particle_min_slip_mps`,
    where `v_long` is the ground speed along the wheel's *rolling* direction
    (`Drivetrain.wheel_forward`), **not** the car's total speed. This is the key to
    the slide case: a car drifting sideways at speed still counts as spinning as
    long as the tread turns faster than it rolls forward.
  - **Surface gate** — one `Drivetrain.terrain.surface_at(x, z)` lookup returns
    `(road_weight, tarmac_weight)`. The wheel must be at least half onto the road
    (`road_weight ≥ ROAD_WEIGHT_MIN`, else it's **grass**) AND on the gravel half
    (`tarmac_weight ≤ TARMAC_WEIGHT_MAX`, else it's **tarmac**, which throws no
    dirt). Both thresholds sit at the midpoint of the same feather bands the road
    colour/grip blend across. With no terrain wired (flat fixtures), nothing
    sprays. This reuses the surface system added for per-surface grip — see
    `features/drivetrain-and-tires.md`.

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
`wheel_particle_color`, `wheel_particle_max`, `wheel_particle_size_m`,
`wheel_particle_min_slip_mps`, `wheel_particle_lifetime_s`,
`wheel_particle_speed_scale`, `wheel_particle_up_speed_mps`,
`wheel_particle_gravity_mps2`, `wheel_particle_air_resistance`,
`wheel_particle_spawn_count`, `wheel_particle_spread`.

## Surfaces

Both excluded surfaces are now handled by the live `surface_at` gate: **grass**
(off the road footprint) and **tarmac** (paved — throws no dirt). Only the gravel
road sprays. This landed once the per-surface system existed; there is no longer a
pending tarmac TODO here.

## Tests

`tests/headless/test_wheel_particles.gd` — a stub car with a stub drivetrain, stub
wheels and a stub terrain surface drive the gating / emission / ring-buffer logic
without a real vehicle or rendering: dirt flies from a driven, spinning, on-gravel
wheel; none from an undriven wheel, a wheel rolling no faster than the ground, a
wheel on grass (off the road), or a wheel on tarmac; a spinning *and* sliding wheel
still emits and throws backward + sideways; and the ring buffer caps the live count.
