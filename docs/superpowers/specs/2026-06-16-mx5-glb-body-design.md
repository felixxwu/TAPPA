# MX-5 glb body model

## Goal

Render the Mazda MX-5 (CarLibrary index 0) using the authored model at
`blender/mx5.glb` instead of the procedural chassis+cabin boxes. The other five
cars keep their procedural boxes.

## Decisions

- **Scope:** MX-5 only. Other cars unchanged.
- **Shading:** PS1 with the baked texture — `ps1_models.gdshader` with
  `albedo_texture = blender/mx5_texture.png` and `albedo_color` white, so the
  model's painted detail shows through the quantize/dither/fog pipeline.
  (Originally specced as flat `chassis_color`; switched to the texture per user
  request so the model's detail is visible.)
- **Wheels:** keep the four procedural cylinder+spoke `VehicleWheel3D` visuals.
  The glb is body-only.
- **Scale:** 1:1 from the glb. Bounds: L 4.10 m, W 1.94 m (incl. mirrors),
  H 1.08 m — within ~5% of the real MX-5 on length, more realistic height than
  the old 0.5 m box. Width is wider at the mirrors; the (invisible) collision
  box stays at the spec dimensions.

## Components

1. **`car.tscn`** — instance `res://blender/mx5.glb` as a child of `Car` named
   `Mx5Body`, `visible = false` by default. Transform rotates the glb's X-length
   axis onto the game's Z (car faces -Z), with a Y offset so the body sits over
   the radius-0.30 wheels. Rotation/offset tuned empirically via screenshots.
2. **`car_library.gd`** — add `"use_model": true` to the MX-5 entry only.
3. **`car.gd` `apply_car()`** — if `spec.get("use_model", false)`: hide
   `$Chassis`/`$Cabin`, show `$Mx5Body`, and assign the PS1 shader material to
   the model's `MeshInstance3D`; else show the boxes and hide `$Mx5Body`.
   Collision box logic unchanged.
4. **`world.gd`** — push `chassis_color` into the Mx5Body material alongside
   Chassis/Cabin.

## Tests (`tests/headless/`)

- glb resource loads and `Mx5Body` node exists in `car.tscn`.
- MX-5 spec carries `use_model`; no other car does.
- `apply_car(0)` (MX-5) → `Mx5Body` visible, `Chassis`/`Cabin` hidden.
- `apply_car(other)` → `Mx5Body` hidden, `Chassis`/`Cabin` visible.

## Docs

- Update `features/rendering.md` (materials/colors table + a note on the model)
  and the car-roster note in `car_library.gd`.
