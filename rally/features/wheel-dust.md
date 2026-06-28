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
spin. Dead slots are parked far below the world (`HIDE_TRANSFORM`) rather than
zero-scaled — billboard materials don't reliably honour a zero instance scale
under `gl_compatibility`, and a quad that far down is always off-screen.

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
  - **Gravel gate** — the wheel must be within `track_width/2 +
    wheel_particle_gravel_margin_m` of the road centerline (windowed nearest-offset
    search around the car's cached offset, mirroring `TireMarks`). Off that
    footprint (the verge / **grass**) sprays nothing. The car offset is only
    searched once a wheel is actually spinning, so a clean drive skips it.

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
`wheel_particle_spawn_count`, `wheel_particle_spread`,
`wheel_particle_gravel_margin_m`.

## TODO — tarmac

There is no surface type yet; every road is gravel, so the gravel gate is the road
footprint. **Once tarmac is introduced**, wheels spinning on tarmac must spray no
dirt — add that surface check at the gravel gate in `_emit_from_wheels`
(`TODO(tarmac)` marks the spot). Grass is already excluded (off the road footprint).

## Tests

`tests/headless/test_wheel_particles.gd` — a straight `Curve2D` + a stub car with a
stub drivetrain and stub wheels drive the gating / emission / ring-buffer logic
without a real vehicle or rendering: dirt flies from a driven, spinning, on-gravel
wheel; none from an undriven wheel, a wheel rolling no faster than the ground, or a
wheel off the gravel (grass); a spinning *and* sliding wheel still emits and throws
backward + sideways; and the ring buffer caps the live count.
