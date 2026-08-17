# Exhaust Flames

**Source:** `scripts/exhaust_flames.gd` (`ExhaustFlames`, `extends Node3D`).

Flame drawn at each of the car's exhaust pipes — a visual companion to the
[exhaust crackle](engine-audio.md) pop, plus a continuous flame while nitrous is
delivering.

**It is not a particle system.** Each pipe gets a fixed piece of geometry that is simply
shown or hidden, with its **texture swapped** between a handful of generated flame frames
so a sustained flame flickers instead of sitting static. A backfire is one shape that
appears and vanishes, not a spray of debris, so a pool of flying particles was both the
wrong look and more machinery than the effect needs. (It *was* built on
`CpuParticlePool` first; that base still serves [`EngineSmoke`](engine-smoke.md) and
[`WheelParticles`](wheel-dust.md), which genuinely do throw debris.)

## Geometry: crossed quads, not a billboard

A flame has a **direction** — it shoots out of the pipe, rearward along the car's +Z. A
camera-facing billboard cannot express that: it would keep the flame pointing screen-up
however the car was oriented, so a car crossing the view would appear to flame sideways.

So each pipe carries **two perpendicular quads** sharing the flame axis — the standard
trick for fire and foliage — which reads correctly from every angle for four triangles.
A `QuadMesh` lies in its own XY plane with the texture's +Y up; rotating +90° about X maps
that up-axis onto +Z and leaves the quad in the XZ plane, and rotating that a further 90°
about Z stands it up into the YZ plane. Both are pushed back by half their length so the
quad's **root** sits at the pipe rather than its centre.

The material is **additive and unshaded** (fire is light), with depth write off so the two
quads don't fight each other, culling off so each is visible from both sides, and shadow
casting off — a flame-shaped shadow under the car would be an obvious artefact.

## Triggers

Two, with deliberately different shapes.

- **Rev-limiter cut — a short, retriggerable hold.** `EngineSim` keeps a monotonic
  `limiter_cut_count`, incremented on each limiter cut *onset* in `_update_limiter`.
  `ExhaustFlames` lights the flame for `exhaust_flame_pop_seconds` whenever the count has
  moved since last tick, and **any further bang re-arms the hold** rather than queueing
  behind it. Bouncing off the limiter therefore reads as rapid flicker, which is what a
  real backfire looks like. Reading the counter delta rather than an edge-detected bool
  means no cut is missed regardless of frame/substep timing.

  This is the **same signal the audio crackle burst fires on**, so the flame and the pop
  land together. A **damaged engine's misfire drives neither**: that is a stumble, not a
  bang (see [damage.md](damage.md) — the misfire deliberately does not fire the crackle,
  and `engine_audio.gd` keys the crackle on `engine.limiting`, not on `fuel_cut`).

- **Nitrous — lit continuously.** The flame stays open for as long as
  `EngineSim.nitrous_delivering`, ignoring the pop hold entirely. That is the sim's
  **latched delivery state** (held AND charged AND combusting), never "a bottle is
  fitted" — so an empty tank puts the flame out. See [nitrous.md](nitrous.md).

## Where the pipes are

Emission is **per pipe**: the car exposes `exhaust_locals`, a `PackedVector3Array` of
car-local points, one per exit — so a single-exit car has one entry and a quad-exit car
four. `car.gd` recomputes it per spec in `_apply_physics_spec`.

The resolution lives in **one place**, `GameConfig.exhaust_locals_for(spec)`, shared by
`car.gd` and by `ExhaustFlames` (which falls back to it for a bare stub car):

- **Authored** positions come from `GameConfig.exhaust_offsets`, a
  `{ car_id: [Vector3, ...] }` dictionary in `config/game_config.tres`. Car-local metres,
  **+Z rearward** (forward is −Z), +Y up, +X right.

  **Every shipped car has an entry**, seeded from its own geometry rather than a shared
  constant: the ground plane is `−(0.1 + wheel_radius)` below the car origin (wheels mount
  at y −0.1 in `car.tscn`, so the contact patch is a radius below that), and the tail is
  `body.z × 0.5`, the body box being centred on the wheelbase midpoint. Pipe count and
  layout follow the real car — the Viper's are **side exits at the sills** (`z ≈ 0`, wide
  X), the 930 Turbo and the two hatchbacks have a **single** pipe, the rest are twin. These
  are starting points to nudge in the lab, not measurements.
- **Fallback** for a car with no entry (or an empty / malformed one): a mirrored pair
  derived from `exhaust_offset_fallback` — its X mirrored to both sides, its Y as-is, and
  its **Z discarded** in favour of the rear of that car's own wheelbase
  (`wheelbase × 0.5`, the rear axle). A fixed Z would sit inside a long car and short of
  a small one; a wheelbase-derived one lands near the tail of any car, which is all an
  un-dialled-in car needs.

### Gotcha: a pipe inside the bodywork is invisible

The flame is **static geometry**, not particles, and it is depth-tested — so a pipe
authored even slightly inside the car's body mesh has its flame buried and drawn away.
This bit the Viper: its body is 1.92 m wide (flank at x ±0.96) and its side pipes were
first authored at x ±0.94, two centimetres inside, which rendered nothing at all. Under
the old particle version the same numbers looked fine, because particles were launched at
several m/s and escaped the body immediately.

So when a pipe sits anywhere other than past the rear bumper — side exits especially —
place it **outside** the body surface and use the yaw to aim it, rather than tucking it
in and relying on the flame to escape. If a car flames everywhere except one pipe, this
is the first thing to check.

### Why the offsets live in the config resource, not in CarLibrary

By precedent they belong in `CarLibrary.CARS` next to `bonnet_cam_offset` — also a
per-car local-space visual nudge. They are in `game_config.tres` for one reason: **F8
hot-reload re-reads that resource, and a `.gd` script cannot be reloaded.** Positioning a
pipe by eye is a tweak-reload-look loop, and only a resource gives you that without
restarting the game. Once a car's pipes are dialled in, its entry is settled data and
could reasonably move to `CarLibrary`.

## Frames

The frames are **generated at runtime** from config rather than loaded from disk: nothing
ships in the PCK, and the shape stays tunable (and F8-reloadable) instead of being frozen
into a PNG. `build_frames` draws `exhaust_flame_frames` small images
(`exhaust_flame_texture_px` square), each seeded on its frame index so the same config
always yields the same frames — the variation between them is authored, not a per-run
accident that could differ between two cars.

In texture space the image **top is the flame tip** and the bottom row is the pipe mouth,
which is what maps the frame onto the quad's up-axis and hence onto the car's rearward
+Z. Each row's half-width follows a teardrop profile — a real mouth width at the root,
widest about a third of the way along, tapering to nothing at the tip — with soft edges,
a fade toward the tip, a hot→cool gradient along the length
(`exhaust_flame_color_hot`/`_cool`) and a white-hot core near the mouth
(`exhaust_flame_core_fraction`).

What differs between frames is the **length**, the **wobble phase** and the **wobble
frequency**: the flame wanders further sideways the closer to its tip, while the root
stays pinned to the pipe. `exhaust_flame_wobble` is therefore the main dial for how lively
the flicker reads.

While lit, the material's texture is swapped every `exhaust_flame_frame_seconds`.
`next_frame` picks a **different** index each time rather than cycling in order — a short
in-order loop is recognisable as a loop, which is exactly what a long nitrous flame would
expose.

## Coordinate space

The pipe offsets are car-**local**, and how they reach world space depends on parenting:

- **Event mode** (`setup(car)`): `world.gd` parents this to the world **root** and reuses
  it across regenerations, so the rig copies `car.global_transform` each tick. Without
  that the flames would sit at the world origin while the car drove away.
- **Lab mode** (`setup_forced(car)`): parented to the car itself, so the scene tree
  already composes the transform — writing it here would fight the parent and stack the
  offset twice. Only the exhaust lab uses this.

## Wiring

Created + wired by `world.gd` alongside `WheelParticles` / `TireMarks` / `EngineSmoke`
(reused across event regenerations via `_ensure_child`, re-targeted on a car swap).
Shader warm-up is **automatic**: `world.gd`'s warm-up pass auto-discovers every node
implementing the `warm_up()`/`clear_warm_up()` contract, and this implements that pair
directly (the pass keys on the methods, not on the type, so it works even though this is
no longer a particle pool) — the shader variant compiles behind the loading overlay
instead of hitching on the first bang.

`exhaust_flames_enabled` is the master switch. Per-frame cost is a visibility flag and, only
while lit, a texture swap — an unlit flame does essentially nothing.

## Note on lighting

The flames are **unshaded and additive**, so unlike the [tyre marks](tire-marks.md) they
do not dim with the environment at night or in snow. That is deliberate — fire emits
light rather than reflecting it — but it does mean they read as brighter at night than in
daylight, which is the correct direction.

## The exhaust lab

**Source:** `scripts/exhaust_lab.gd` (`ExhaustLab`), scene `exhaust_lab.tscn`.

A standalone dev scene for positioning each car's pipes by eye. Run it **directly from
the editor** (F6 / Run Current Scene) or with
`Godot res://exhaust_lab.tscn` — it is not the project's main scene and nothing in the
game links to it, exactly like `corner_catalog.tscn`. See
[debug-tools.md](debug-tools.md).

One frozen car on a plain neutral apron, with its `ExhaustFlames` rig in **forced mode**
(`setup_forced`) so the flame is lit continuously — you aim at
a steady target instead of waiting for the car to bounce off the limiter. The rig is
parented to the car, so what you see is the car-local offset directly, with no world
transform in the way.

| Input | Action |
|-------|--------|
| Drag (left mouse) | Orbit the camera |
| Wheel | Zoom (clamped) |
| `[` / `]`, or Left/Right (keyboard + pad) | Previous / next car |
| **F8** | Re-read `config/game_config.tres` and re-apply the pipes, no restart |

The on-screen readout names the car and its id, says whether its offsets are **authored
or falling back**, and prints each pipe as a literal `Vector3(x, y, z)` ready to paste
into `exhaust_offsets`. The camera pitch is clamped short of vertical so the orbit can
never flip over the pole, and the framing distance is derived from the car's wheelbase so
a long saloon and a city car both fill the view.

Being an editor-only dev scene, it is outside the "every menu is keyboard + gamepad
navigable" rule in `CLAUDE.md` — but car cycling is wired to `ui_left`/`ui_right` anyway,
so a pad works.

## Tests

- `tests/headless/test_exhaust_flames.gd` — triggers, the retriggerable hold, per-pipe
  rig construction, warm-up, and frame generation/cycling (including that the generated
  frames genuinely differ and are deterministic), against a stub car exposing
  `drivetrain.engine` (no vehicle, no rendering).
- `tests/headless/test_exhaust_offsets.gd` — `GameConfig.exhaust_locals_for` against
  synthetic specs (authored, single/quad pipe, every fallback and malformed branch), plus
  the lab's camera clamp.
- `tests/headless/test_engine_logic.gd` — `limiter_cut_count` counts bangs, not ticks,
  and survives a reset.

## Related

- [engine-smoke.md](engine-smoke.md) — a genuine particle pool, and where the warm-up contract comes from
- [wheel-dust.md](wheel-dust.md) — the shared `CpuParticlePool` base these two use
- [engine-audio.md](engine-audio.md) — the crackle burst that fires on the same signal
- [nitrous.md](nitrous.md) — the delivery state the stream reads
- [debug-tools.md](debug-tools.md) — the other dev-build affordances, including F8
