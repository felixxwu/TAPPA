# PS1-Style Drivable Car Prototype — Design

**Date:** 2026-06-11
**Project:** rally (Godot 4.6, GL Compatibility renderer, Jolt physics)

## Goal

A single scene: a flat floor with a car the player can drive around using the
keyboard. Simple physics, PS1 retro visual style (low resolution, unshaded
flat-colored meshes, vertex wobble, affine texture mapping, color
quantization + dithering).

## Scene structure (`main.tscn`)

- **Floor** — `StaticBody3D` with a large `BoxShape3D` collider and a flat box
  mesh. Material: PS1 model shader (below) with a checker albedo texture
  (small procedural/generated checker image, nearest-filtered) tiled via the
  shader's UV-tile uniform so speed and motion are readable.
- **Car** — `VehicleBody3D`:
  - Box chassis mesh + `BoxShape3D` collision shape.
  - Four `VehicleWheel3D` nodes with cylinder meshes.
  - Rear wheels: traction (`use_as_traction`). Front wheels: steering
    (`use_as_steering`).
  - Conservative tuning: moderate engine force, clamped steering angle
    (~0.5 rad), reasonable suspension defaults so it doesn't flip or float.
  - Chassis/wheel materials use the PS1 model shader with flat contrasting
    colors (depth perception must work without lighting).
- **Chase camera** — `Camera3D` driven by `chase_camera.gd`: each physics
  frame, lerp toward a point behind/above the car and look at the car.
  Smooth follow, no rigid mounting.
- **WorldEnvironment** — flat solid background color + distance fog to the
  same color (hides the floor edge; very PS1). **No lights in the scene** —
  all materials are unshaded.
- **PostProcess** — `CanvasLayer` > full-rect `ColorRect` with the PS1
  post-process shader.

## Controls (Input Map)

| Action | Keys |
|---|---|
| `accelerate` | W, Up |
| `brake_reverse` | S, Down |
| `steer_left` | A, Left |
| `steer_right` | D, Right |
| `reset_car` | R |

`reset_car` teleports the car upright to its start transform and zeroes
velocities (VehicleBody3D flips are inevitable).

## Scripts

- `car.gd` (on the VehicleBody3D): read input each physics frame; set
  `engine_force`, `brake`, `steering` (steering lerped for smoothness);
  handle reset.
- `chase_camera.gd` (on the Camera3D): lerp-follow behind the car.

## PS1 rendering

### Project settings
- `rendering/textures/canvas_textures/default_texture_filter` → Nearest
- Import defaults: Texture2D → Detect 3D → disabled
- Window: base 320×240 (may bump to 640×480 if too chunky), stretch mode
  `viewport`, aspect `keep_height` (stretches to any window width, no black
  bars, height always equals base height).

### Post-process shader — `shaders/ps1_post_process.gdshader`
`canvas_item` shader on the full-rect ColorRect:
- Sample screen via `hint_screen_texture` with nearest filtering.
- **Color quantization** to 5 bits/channel: `floor(color * 255.0 / 8.0) / 31.0`.
- **Dithering**: the authentic 4×4 PS1 dither matrix, scaled by a small
  offset and added to the color before flooring. Uses `viewport_size` and
  `virtual_resolution` uniforms so the dither pattern is computed at a
  virtual 320×240 grid regardless of window size.

### Model shader — `shaders/ps1_models.gdshader`
`spatial` shader applied to floor and car materials:
- `render_mode unshaded, specular_disabled;` — no lighting, no specular,
  meshes cast no shadows (no lights exist anyway).
- **Vertex snapping**: in `vertex()`, transform position to clip space →
  NDC, round XY to a `snap_resolution` grid, convert back. Uniform bool to
  toggle; uniform float for grid resolution.
- **Affine texture mapping**: pass `clip_w` plus affine and perspective UV
  variants from `vertex()` to `fragment()`; mix by a `affine_weight` uniform
  (UV_affine / clip_w blended against regular UV).
- Uniforms: `albedo_texture` (`source_color`, `filter_nearest`),
  `texture_tile` (vec2, used to tile the floor checker), `snap_enabled`,
  `snap_resolution`, `affine_weight`.

Known knob: affine warping on the large floor will be visible; if too
strong, subdivide the floor mesh (more vertices = less warp per polygon)
rather than lowering `affine_weight` to zero.

## Out of scope (YAGNI)

- Sound, UI/HUD, menus, game state.
- Realistic vehicle tuning; any car model assets.
- Resolution/aspect options menu (settings hardcoded for now).

## Testing

Manual: run the scene, drive, flip the car, press R. Verify: pixelated
output at any window size, visible dither in sky/fog gradients, vertex
wobble when the camera moves, checker floor tiles correctly, car steers and
resets.
