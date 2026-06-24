# Rendering & PS1 Look

The game targets a PlayStation-1 aesthetic: low internal resolution, unshaded
flat colors, nearest-neighbor textures, color quantization + dithering, and fog.

## Display / renderer (`project.godot`)

- Internal viewport: **480×360**, window **1280×960** (upscaled). Lower than
  the old 640×480 — fewer fragments to shade (the full-screen post-process runs
  per internal pixel), and closer to the PS1's ~320×240.
- Stretch mode: viewport, `keep_height` aspect.
- Renderer: **GL Compatibility** (D3D12 driver on Windows).
- Texture filtering: nearest-neighbor globally.

## Shaders (`shaders/`)

### `ps1_models.gdshader` — `spatial`, `unshaded`
Flat-shaded material for all 3D meshes (no lighting model).
Uniforms: `albedo_texture` and `road_texture` (both source_color, nearest,
default white), `albedo_color`, `texture_tile`, `blend_road` (bool, default
`false`), and `road_uv_scale` (road tiling relative to the ground; set from
`road_tile_per_meter / terrain_tile_per_meter` in `world.gd`). Fragment:
`ALBEDO = mix(albedo_texture, road_texture, blend_road ? COLOR.a : 0) × albedo_color × COLOR.rgb`.
When `blend_road` is on (the terrain material sets it), the per-vertex `COLOR.a`
cross-fades the ground texture (grass) to the road texture (gravel) where the
terrain bakes road weight into vertex-colour alpha (see
[terrain.md](terrain.md)/[track.md](track.md)); `COLOR.rgb` is a flat tint.
`blend_road` defaults off so meshes that share this shader but carry no
vertex-colour array (the car, the MX-5 body) — whose `COLOR` defaults to opaque
white — keep sampling `albedo_texture` and are unaffected.

Used by: terrain floor, car chassis/cabin/wheels/spokes, and the MX-5's
authored body model (see below).

### `ps1_post_process.gdshader` — `canvas_item` (full-screen)
Applied via the `PostProcess/ColorRect`. Uniforms: `screen_texture`
(hint_screen_texture, nearest, repeat disabled), `virtual_resolution`
(set from `cfg.virtual_resolution`, [480,360], by `world.gd`).

Algorithm: sample screen → quantize to virtual resolution → apply a 4×4 ordered
(Bayer) dither matrix → truncate to 5-bit RGB (32 levels/channel) → output.

## MX-5 authored body model

The Mazda MX-5 (CarLibrary index 0) renders an authored body model
(`blender/mx5.glb`, instanced as `Car/Mx5Body`) instead of the procedural
chassis+cabin boxes; every other car still uses the boxes. `car.gd`'s
`apply_car()` toggles visibility (`use_model` flag on the spec) and assigns the
`ps1_models.gdshader` material to the model's mesh — `albedo_texture` set to the
baked `blender/mx5_texture.png`, `albedo_color` white — so the model's painted
detail (glass, lights, panels) renders through the same quantize/dither/fog
pipeline as the rest of the scene. The four wheels stay procedural; the
collision box is unchanged (and invisible). The model is used at 1:1 scale.

## Materials & colors

`world.gd._ready()` pushes config colors into the shared shader materials:

| Node | Param | Config |
|------|-------|--------|
| Car/Chassis | `albedo_color` | `chassis_color` (red) |
| Car/Cabin | `albedo_color` | `cabin_color` (dark blue) |
| Wheels (all 4) | `albedo_color` | `wheel_color` (black) |
| Spokes (all 8) | `albedo_color` | `wheel_spoke_color` (silver) |
| PostProcess/ColorRect | `virtual_resolution` | `virtual_resolution` [480,360] |

## Environment

- No light nodes — the world is unlit (shaders are unshaded).
- Fog enabled, `fog_density` (0.02), color = `background_color` (purple-ish).
- No bloom, no shadows.

## Tests

## Performance defaults (inherently low-end)

The game ships one lean pipeline for every device (no quality tiers). Relevant
shipped knobs in `GameConfig`:
- **`target_fps`** (default 30) — a render frame cap applied in `world._ready()`
  (skipped under `--headless`, so it never throttles the test runner) to avoid
  thermal throttling on phones. Physics stays at the project physics tick.
- **`texture_lod_bias`** (default 0.75) — biases distant foliage sampling toward
  cheaper mip levels (a `lod_bias` uniform in `shaders/billboard.gdshader`, set
  from `BillboardField.build()`). The tree/bush textures now have **mipmaps
  enabled** (`textures/tree.png.import`, `textures/bush.webp.import`), so distant
  billboards no longer thrash the texture cache. `filter_nearest` is kept (PS1
  look) — mipmapping is independent of the magnification filter.

Rendering **setup** (environment, mesh shader materials, post-process shader,
shader sources) is covered by `test_render_smoke.gd` — see
[testing.md](testing.md). There is no pixel-diff golden test: it only worked
windowed and was chronically flaky, so the actual rendered look is not asserted
pixel-for-pixel. Eyeball intentional look changes in the running app.
