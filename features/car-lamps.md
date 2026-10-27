# Car Lamps

**Source:** `scripts/car_lamps.gd` (`CarLamps`, `extends Node3D`), `shaders/car_lamp.gdshader`.

**Tests:** `tests/headless/test_car_lamps.gd`

Glowing head and tail lamps on the player's car. Each lamp is a **generic point of light**:
one camera-facing quad at the lamp's centre, drawing a hot core, a soft halo and a thin
horizontal lens streak. Matching every car's real lamp shape isn't attempted — the flare
is what hides that it is only a point.

## When they glow

- **Headlights** follow the night headlight cone: their brightness is
  `HeadlightCone.amount(cfg)`, so they light up exactly when (and as strongly as) the
  weather table's `headlights` key switches the cone on. See
  [rendering.md](rendering.md) → "The fake headlight cone".
- **Tail lamps** run at `lamp_tail_running` × that brightness with the headlights on, and
  at full brightness under the foot brake, **day or night**.
- The brake signal is `car.gd`'s `brake_lamp`: the driver's foot brake, but **not** the
  automatic hold that parks a stopped car on a slope (nobody's foot is on the pedal). The
  scripted finish-line stop does count — it is a real braking stop.

## Where the lamps are

Authored per car in `GameConfig.lamp_offsets`, a `{ car_id: { "head": [...], "tail": [...] } }`
dictionary in `config/game_config.tres` — car-local metres, **+Z rearward**, the same axes
as `exhaust_offsets`. `GameConfig.lamp_locals_for(spec)` resolves it; `car.gd` caches the
result into `lamp_locals` per spec in `_apply_physics_spec`. A car with **no entry gets no
lamps** — there is no guessed fallback, since a flare floating off the body looks worse
than none.

**How the points were found** (MX-5): render orthographic front and back views of the
car's glb at a known scale (500 px/m, with a 10 cm grid), read each lamp housing's centre
off the image by eye, then ray-cast that point onto the body for its depth, and convert
from the glb's Blender axes into car-local axes through the body node's transform in
`car.tscn` (`Mx5Body`: glb +X → car −Z, glb up → car +Y, offset −0.5 m in Y).

The **F-150**'s were found the same way, but off its levelled photogrammetry scan (`f150_scan.blend`, see
[car-scanning.md](car-scanning.md)): orthographic front/back views at 200 px/m with a 10 cm grid, a ray cast for
depth, then scan axes (front +Y, ground at 0) to car-local (x as-is, y = z − 0.565 for the body's ride height,
z = −y). Its one exhaust pipe in `exhaust_offsets` was read off the same scan.

## The flare shader

`car_lamp.gdshader` is unshaded and **additive** (light adds to what is behind it) with no
depth write. Two tricks in its `vertex()`:

- **Billboard + depth bias by hand.** The quad is placed in view space at the lamp's
  centre, then pulled `lamp_depth_bias_m` toward the camera, so the bodywork around the
  lamp doesn't slice the flare in half — while a hill or another car still hides it.
- **Facing fade.** Each lamp kind has a `facing` direction (headlights −Z, tail lamps +Z);
  the flare fades as that direction turns away from the camera, so headlights don't glow
  through the car when seen from behind.

The flare shape is procedural (no texture): `lamp_core_radius`, `lamp_halo` and
`lamp_streak` in the "Car Lamps" config group tune it; defaults are deliberately subtle.

## Wiring

Created by `free_roam.gd` (and the stage `world.gd`) next to `ExhaustFlames` and driven the same way: parented to the
world, it copies the car's transform every physics tick. It rebuilds its quads whenever
the car's `lamp_locals` change (the garage swapping cars). It implements the
`warm_up()` / `clear_warm_up()` pair so the shader compiles behind the loading overlay.
Only the player's car has lamps.
