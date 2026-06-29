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
Terrain material. The shader itself runs no lighting math and has **no
`vertex()` stage** — a deliberate performance choice, since the terrain is the
heaviest geometry in the scene (tens of thousands of vertices across the loaded
chunk ring) and must keep its pass-through vertex path. Its shading is instead
**baked into the vertex colours** at generation time (see below / [terrain.md](terrain.md)),
which the fragment already multiplies in for free. Car lighting, which can't be
baked, lives in the separate `ps1_models_lit.gdshader` (below).
Uniforms: `albedo_texture` and `road_texture` (both source_color, nearest,
default white), `albedo_color`, `texture_tile`, `blend_road` (bool, default
`false`), `road_uv_scale` (road tiling relative to the ground; set from
`road_tile_per_meter / terrain_tile_per_meter` in `world.gd`), and `tarmac_color`
(the flat tarmac fill, set from `cfg.tarmac_color`). Fragment:
`road = mix(road_texture, tarmac_color, UV2.x)` then
`ALBEDO = mix(albedo_texture, road, blend_road ? COLOR.a : 0) × albedo_color × COLOR.rgb`.
When `blend_road` is on (the terrain material sets it), the per-vertex `COLOR.a`
cross-fades the ground texture (grass) to the road where the terrain bakes road
weight into vertex-colour alpha, and the road itself fades from the gravel
texture to the flat tarmac colour by the per-vertex tarmac weight in **UV2.x**
(0 = gravel, 1 = tarmac), feathered across the gravel↔tarmac switch (see
[terrain.md](terrain.md)/[track.md](track.md)). Tarmac is a placeholder solid
grey — [../todo/tarmac-texture.md](../todo/tarmac-texture.md). `COLOR.rgb` is the
ground tint **times the baked static lighting** (`terrain_manager._bake_light`,
mirroring the car shader's math) — so the hills (and tarmac) get the same
hemisphere+sun shading as the car at zero per-frame cost, valid because the
terrain and sun never move.

Used by: the terrain floor.

### `ps1_models_lit.gdshader` — `spatial`, `unshaded`
Car-only variant of `ps1_models.gdshader` with cheap fake per-vertex (Gouraud)
lighting. Kept SEPARATE from the terrain shader on purpose: only the handful of
car/wheel/MX-5 vertices run the `vertex()` stage, so the terrain pays nothing
for a feature it doesn't use. (Folding the `vertex()` stage into the shared
shader was a real mobile regression — every terrain vertex ran the lighting math
each frame even though `light_amount` discarded it.)

The material stays `unshaded` — the engine runs *no* lighting pass, casts no
shadows, and there are still no light nodes. `vertex()` computes a PS1/PS2-style
term in world space and the fragment multiplies it into `ALBEDO`: a hemisphere
ambient (`mix(ground_color, sky_color, N.y·0.5+0.5)`) plus one hardcoded
directional "sun" (`max(dot(N, light_dir), 0) × sun_color`) — a dot product per
vertex, interpolated for free by the rasteriser. `light_amount`
(`mix(vec3(1.0), lit, light_amount)`) blends the whole effect in: 0 = flat,
1 = full. Uniforms `albedo_texture`, `albedo_color`, `texture_tile`,
`light_amount`, `light_dir`, `sun_color`, `sky_color`, `ground_color`.
`world.gd` calls `cfg.apply_car_light()` on the chassis/cabin/wheel/spoke
materials, and `car.gd._apply_model_material()` does the same for the MX-5 body.
The values (`car_light_amount` + the shared `sun_direction`, `sun_color`,
`sky_color`, `ground_color`) live in `GameConfig` under the **Lighting** group,
alongside `terrain_light_amount` for the baked terrain shading.

Used by: car chassis/cabin/wheels/spokes, and the MX-5's authored body model
(see below).

### `ps1_post_process.gdshader` — `canvas_item` (full-screen)
Applied via the `PostProcess/ColorRect`. Uniforms: `screen_texture`
(hint_screen_texture, nearest, repeat disabled), `virtual_resolution`
(set from `cfg.virtual_resolution`, [480,360], by `world.gd`).

Algorithm: sample screen → quantize to virtual resolution → apply a 4×4 ordered
(Bayer) dither matrix → truncate to 5-bit RGB (32 levels/channel) → output.

### `speed_lines.gdshader` — `canvas_item` (full-screen overlay)
Anime "edge speed lines": black streaks radiating inward from the screen edges
toward the centre, leaving the middle clear — the classic manga sense-of-speed
effect, ramped in with the car's velocity. Applied to `SpeedLines/ColorRect`, a
full-screen `ColorRect` on its **own CanvasLayer** sitting ABOVE the PS1 dither
post-process (so the streaks stay crisp instead of being broken up by the
quantise/dither) and BELOW the HUD layer (so the readouts stay on top). The
overlay's `mouse_filter` is `IGNORE` so it never eats touch/clicks meant for the
HUD or mobile controls.

Uniforms: `intensity` (0..1 overall strength, 0 = invisible), `line_color`
(source_color, black), `density` (angular streak count), `inner_radius` /
`outer_radius` (the normalised-radius fade band that keeps the centre clear and
ramps the streaks to full toward the edges), `flicker_speed` (per-streak flicker
rate in discrete steps/sec — time is quantised so each streak snaps to a new
random brightness rather than pulsing smoothly, for a choppy hand-drawn look).
Fragment: aspect-corrected centre-origin coords → bucket the angle into `density`
slots (one streak each) → per-slot random width + stepped flicker → multiply by a
radial mask → output `line_color` with the computed alpha.

`scripts/speed_lines.gd` (on the `SpeedLines` CanvasLayer) pushes the static
look from config once in `_ready()`, then each frame maps the car's airspeed
across `[speed_lines_start_kmh, speed_lines_full_kmh]` → `[0, 1]`, scales by
`speed_lines_max_intensity`, and eases the `intensity` uniform toward that target
(`speed_lines_response`) so the streaks fade in/out rather than pop. `world.gd`'s
`cycle_car()` re-points the overlay at the swapped car, like the HUD. All tunables
live in `GameConfig` under the **Speed Lines** group.

## MX-5 authored body model

The Mazda MX-5 (CarLibrary index 0) renders an authored body model
(`blender/mx5.glb`, instanced as `Car/Mx5Body`) instead of the procedural
chassis+cabin boxes; every other car still uses the boxes. `car.gd`'s
`apply_car()` toggles visibility (`use_model` flag on the spec) and assigns the
`ps1_models_lit.gdshader` material to the model's mesh — `albedo_texture` set to the
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
| Car meshes + MX-5 body | fake-light uniforms | Lighting group (`cfg.apply_car_light`) |
| Floor (terrain) | baked vertex-colour shading | Lighting group (`cfg.apply_terrain_light`) |
| PostProcess/ColorRect | `virtual_resolution` | `virtual_resolution` [480,360] |

## Environment

- No light nodes and no engine lighting pass — the materials stay `unshaded`.
  Car meshes get cheap fake per-vertex (Gouraud) lighting from the car-only
  `ps1_models_lit.gdshader` (computed live, since the car rotates). The terrain
  gets the same hemisphere+sun look **baked into its vertex colours** once at
  generation time, so its shader keeps a pass-through vertex path and the
  heaviest geometry pays nothing per frame. Trees/bushes/signs stay flat.
- **Skybox** (`main.tscn` env `background_mode = Sky`): a `PanoramaSkyMaterial`
  with a CC0 photographic open-field sky equirect (`textures/sky_field.png`, a tonemapped
  LDR downscale of a Poly Haven HDRI). The full-screen post-process quantizes it
  to the same 5-bit + dither look, so it reads as native PS1, not a pasted photo.
  `hq.gd` builds the same sky in code so HQ matches.
- **Sun alignment.** The car/terrain fake light (`sun_direction`) must point at
  the visible sun. Convention: panoramas are pre-rolled with
  `tools/align_sky_sun.py` so the sun sits at the image CENTRE — which is `+Z` in
  Godot's panorama mapping (verified in-engine) — so `sun_direction`'s azimuth is
  always `+Z` (`x≈0, z>0`) and only its elevation tracks the sky's sun
  height. Dropping in a new sky: run the tool (it rolls the image and prints the
  `sun_direction` to paste into `GameConfig`). The roll is a pure yaw, so the
  horizon stays level. (HQ uses its own `DirectionalLight3D`, independent of this.)
- **Distant terrain** (`scripts/distant_terrain.gd`, `DistantTerrain`): a coarse,
  collision-free backdrop mesh sampling the same noise as the real terrain,
  extending past the detailed 3×3 chunk ring (~75 m) so the reduced fog reveals a
  horizon for the sky instead of the ring's hard edge. Re-centres on the car.
  Built in `world._generate_track()`; tunables in `GameConfig` (`distant_terrain_*`).
- **Fog** demoted from edge-hider to thin aerial haze now that the backdrop hides
  the edge: `fog_density` (0.005), `fog_sky_affect` (0.15, so the sky reads above
  the haze), `fog_light_color = background_color` — and `background_color`
  (0.589, 0.544, 0.520) is **matched to the skybox's horizon** so the distant
  terrain dissolves into the sky seam. All applied in `world._ready()` from config.
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
