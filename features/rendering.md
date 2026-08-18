# Rendering & PS1 Look

The game targets a PlayStation-1 aesthetic: low internal resolution, unshaded
flat colors, nearest-neighbor textures, color quantization + dithering, and fog.

**Tests:** `tests/headless/test_display_stretch.gd`, `tests/headless/test_render_smoke.gd`

## Display / renderer (`project.godot`)

- Logical frame height: `display/window/size/viewport_height` (`project.godot`) — the
  value every menu is laid out against, read by `DisplayStretch.DESIGN_HEIGHT`
  (`scripts/display_stretch.gd`, a `static var` initialised from that project setting).
  Logical WIDTH is not a fixed number: it follows the device's aspect ratio off
  `DESIGN_HEIGHT` (`DisplayStretch.logical_size()`), then `Config.data.horizontal_stretch`
  applies the stylistic horizontal stretch on top. Raised once from an earlier, lower
  value; the post-process dither grid (`virtual_resolution`, below) was deliberately NOT
  changed with it, since it is a look value rather than a render size.
- Post-process dither grid: `GameConfig.virtual_resolution` (`cfg.virtual_resolution`) —
  a **separate, deliberately decoupled** value from the logical viewport size above; it
  is the PS1 look's fragment grid, not a render resolution. Window size is upscaled from
  the logical size (`stretch/mode="viewport"`).
- Stretch mode: viewport, `keep_height` aspect — but the `DisplayStretch`
  autoload (below) overrides the aspect at runtime to apply the stylistic
  horizontal stretch.
- Renderer: **GL Compatibility** (D3D12 driver on Windows).
- Texture filtering: nearest-neighbor globally. The 2D canvas default is
  `default_texture_filter=0` (nearest); every shader sampler uses `filter_nearest`;
  and every 3D `StandardMaterial3D` that carries a texture sets
  `texture_filter = TEXTURE_FILTER_NEAREST_WITH_MIPMAPS` (nearest magnification,
  mipmaps kept for distance — see the mipmap note below). This includes
  GLB-baked materials whose importer-default linear filter is overridden to
  nearest, e.g. the ground-cover bush in `Foliage.bush_mesh()`. The sole
  exception is the panorama sky, a smooth
  gradient where filtering is intended.
- **Anisotropic filtering is off** (`textures/default_filters/anisotropic_filtering_level=0`).
  Nothing in the game filters linearly, so anisotropic sampling on top of nearest was
  pure wasted bandwidth on a tile GPU.
- **Mesh LOD** switches at `mesh_lod/lod_change/threshold_pixels=4.0` (default 1.0).
  The car GLBs import with `meshes/generate_lods=true`, so the levels exist and were
  barely being used.
- **`limits/opengl/max_lights_per_object=4`** (default 8) — it sizes the
  GL-Compatibility light loop. The stage has no lights, the HQ one sun, the garage one
  sun plus per-bay omnis.
- **Texture compression / import settings** — which textures are VRAM-compressed,
  which are lossy, why the car bodies are deliberately 512² lossy, and why
  `detect_3d/compress_to=0` matters, are all in
  [asset-pipeline.md](asset-pipeline.md). Note `[importer_defaults] compress/mode=1`
  is **Lossy, not VRAM-compressed** — the ETC2/ASTC export flags do nothing for a
  mode-1 texture.

## Horizontal stretch (`scripts/display_stretch.gd`)

A purely stylistic anamorphic widening of the **entire** frame — the 3D world
and every UI CanvasLayer on top of it, in every scene. The `DisplayStretch`
autoload draws everything `Config.data.horizontal_stretch`× wider than reality
(default **1.1**, set in the "PS1 Look" group of `config/game_config.tres`;
`1.0` disables it).

It works through the stretch system rather than a post-process shader,
precisely so it reaches the UI: the post-process pass only sees the 3D
viewport, while the HUD/menus live on higher CanvasLayers drawn after it. On
boot (and every window resize) the autoload switches the root window's aspect to
`IGNORE` (per-axis scaling) and drives `content_scale_size`: the logical height
stays the design height (`DisplayStretch.DESIGN_HEIGHT`, so vertical is never
distorted) while the logical
width is shrunk by the stretch factor, forcing the window to scale it back out
horizontally by exactly that factor. `DESIGN_HEIGHT` is read at load from
project.godot's `display/window/size/viewport_height` — that
project setting is the single source of truth for the fixed vertical resolution;
the horizontal one is dynamic (it follows the window aspect). Because the width
is derived from `DESIGN_HEIGHT / stretch` and not the raw window width, the
stretch stays constant on any
device aspect, and wider screens still reveal more world width — just fatter.
The width math is the pure static `DisplayStretch.logical_size()`, unit-tested in
`tests/headless/test_display_stretch.gd`.

## Shaders (`shaders/`)

### `water.gdshader` — `spatial`, `unshaded`
Lake surface (see [lakes.md](lakes.md)). **Flat and opaque** — a solid PS1 colour
block, because a screen-door dither read as noise against the low-res pixelation. No
reflections, no transparency, no screen-texture read (preserves the Compatibility
no-backbuffer choice). A faint scrolling ripple tint (world position × `TIME`) plus
a sparkle band give the surface a little life. One shared material across all of a
stage's lake meshes. `cull_back` (the lake is only ever seen from above, so back
faces are pure waste).

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

It `#include`s `shaders/headlight_cone.gdshaderinc` and adds the night cone into
that light term in the fragment — `ALBEDO = surface * (COLOR.rgb + hl_color *
headlight_lit(world_pos))`, with `world_pos` recovered from `INV_VIEW_MATRIX`
since there is no vertex stage to hand one down. The no-`vertex()` rule is
untouched by this and stays test-enforced. See "The fake headlight cone" below.

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
`world.gd` calls `cfg.apply_car_light()` on the chassis/cabin/wheel
materials, and `car.gd._apply_model_material()` does the same for the authored bodies (MX-5, Focus, Twingo).
The values (`car_light_amount` + the shared `sun_direction`, `sun_color`,
`sky_color`, `ground_color`) live in `GameConfig` under the **Lighting** group,
alongside `terrain_light_amount` for the baked terrain shading. `sun_color` and
`sky_color` are pushed **scaled by the runtime `GameConfig.weather_sun_mult`**,
so the car dims with the world on an overcast/dark condition instead of staying
at full daylight. The scaling itself is `GameConfig.weather_lit` — the shared rule
for every fake-lit material, see below.

The night headlight cone folds into the existing `varying vec3 v_light` in
`vertex()` (`v_light += hl_color * headlight_lit(...)`), so lit models need no
new interpolator and no fragment cost.

Used by: car chassis/cabin/wheels, and the authored body models (MX-5, Focus, Twingo)
(see below).

### `ps1_post_process.gdshader` — `canvas_item` (full-screen)
Applied as the material of a `PostProcess` **SubViewportContainer**
(`scripts/post_process_view.gd`), hosted by **both `main.tscn` (the driving
stage) and `hq.tscn` (the hub)** so the PS1 treatment covers the whole game's 3D
rather than stopping at the garage door. The 3D world stays in the main tree but
is rendered through `PostProcess/View`, a `SubViewport` that shares the host's
`World3D` (`own_world_3d = false`) and carries a `ViewCamera` mirror camera
synced every frame to the active camera; the root viewport's own 3D pass is
disabled while such a scene is in the tree (restored on exit). The host script is
entirely generic — it mirrors whatever `get_viewport().get_camera_3d()` returns,
so it needed no HQ-specific camera wiring. The shader samples the container's `TEXTURE` (the
subviewport frame) directly — deliberately NOT `hint_screen_texture`, which
would force a full-screen backbuffer copy (render-pass break + mid-frame GPU
submit) every frame on the Compatibility backend.

Every uniform — the `virtual_resolution` dither grid plus the whole colour grade
— is pushed by **`GameConfig.apply_post_process`**, called from `world.gd`'s
`_ready` and `hq.gd`'s `_apply_post_process`. That single helper is deliberately
the only writer: two hosts each setting their own uniforms would eventually drift
into grading the stage and the hub differently. Read the config for the current
values; the grid is authored to match the design height, so don't restate the
numbers here.

Algorithm: sample frame → **colour grade** (below) → quantize to virtual
resolution → apply a 4×4 ordered (Bayer) dither matrix → truncate to 5-bit RGB
(32 levels/channel) → output. The dither applies to the 3D world only:
SpeedLines / HUD / menus live on CanvasLayers drawn above the container.

#### Colour grade (Race Driver: GRID look)

A desaturate + contrast + warm-brown **split tone** + vignette, in the same pass
ahead of the dither. GRID's look was never a uniform sepia wash — it was muddy
warm-brown crushed blacks against yellowed highlights — so shadows and
highlights are tinted separately, crossfaded by luma. Knobs live in the **PS1
Look** group of `game_config.tres` (`grade_amount`, `grade_saturation`,
`grade_contrast`, `grade_shadow_tint`, `grade_highlight_tint`,
`grade_vignette_strength`, `grade_vignette_radius`), pushed by `world.gd`'s
`_ready` alongside `virtual_resolution`. `grade_amount = 0` is an exact
passthrough. Read the config for the values; don't restate them here.

Five things about it that are load-bearing rather than incidental:

- **It grades BEFORE the quantize**, so the 5-bit banding lands in the graded
  palette. Grading afterwards would smear the 32 quantised levels back into
  intermediate values and soften the exact banding this renderer is built on.
  Pinned by `test_render_smoke.gd` → `test_post_process_grades_before_quantising`.
- **The tint is luma-normalised** (`luma_normalized`, with a `max(..., 1e-3)`
  guard). A plain tint multiply can only ever darken — the inspector clamps a
  `Color` export to 1.0 — so a brown tint would dim the whole stage, the tuner
  would fight it with contrast, and the result is mud. Normalising keeps hue and
  exposure independent knobs. The guard matters because a near-black shadow tint
  is exactly what "crushed warm blacks" invites.
- **Luma is taken once from the untouched sample**, feeding both the desaturation
  and the split-tone crossfade, so retuning contrast doesn't slide the
  shadow/highlight boundary around.
- **The vignette sits inside the graded branch**, before the `grade_amount` blend,
  or `0` would still darken the corners and the bypass contract would be a lie.
  It's computed in UV space, so it's an ellipse whose shape follows the window
  aspect (the frame is ~1.48:1 in pixels at 16:9 before the anamorphic stretch
  widens it further) — intended, but wide displays get a more stretched vignette.
- **The maths is sRGB-space**, not linear: `TEXTURE` is the SubViewport's
  already-encoded output. That suits the era; don't "correct" it.

Scope is the 3D frame of **both** the stage and the HQ — world, props, cars and
sky. In the HQ that includes the hub geometry, the map table and the parked
lineup; its station **overlays** are CanvasLayers above the container and stay
ungraded, exactly like the HUD. Note the HQ's clickable stations (table, lift,
pins) are `Area3D`s picked through the ROOT viewport, which is why the container
sets `mouse_filter = IGNORE` — `disable_3d` only skips the render pass, so the
camera stays current and picking is unaffected. `test_render_smoke.gd` →
`test_hq_hosts_the_same_post_process_pass` pins both the shared world and the
mouse-filter.

**The one exception, and it is deliberate: a `WorldPanel` IS graded.** A menu hosted
in the 3D world (see [world-panel.md](world-panel.md)) is a `Sprite3D` *inside* the
scene, not a `CanvasLayer` above the container — so the grade, fog and tonemap reach
it exactly as they reach the car beside it. That cohesion is the point of putting a
menu in the world, so its fog/exposure flags are **not** disabled. The standing risk
is that the grade was tuned against terrain and car paint rather than UI text, so a
grade retune can quietly hurt panel legibility — worth an eyeball when the grade
changes. Shipped ON in `config/game_config.tres`.

The HUD, menus **and the speed
lines** are all on CanvasLayers above the container, so the shader never sees them.
Speed lines being outside it is worth remembering: they're a *world* effect, and
a non-black `speed_lines_color` would visibly break out of the grade.

Shader-grading the UI was considered and rejected — it needs a top layer sampling
`hint_screen_texture`, whose `BackBufferCopy` render-pass break is a fixed
per-frame cost that doesn't shrink with resolution and forces a tile-buffer
resolve on mobile GPUs. Don't "fix" the gap that way. Instead the UI matches by
**palette bake**: `UITheme`'s colour constants are pre-graded offline by
`tools/bake_ui_palette.gd`, giving the same cohesion for zero runtime cost — see
[ui-design-system.md](ui-design-system.md) → "The palette is grade-baked". That
tool's maths must stay in step with the shader's `fragment()`.

Several world colours in `GameConfig` were authored against the *ungraded* image
and read a little oddly under warm brown — the fog/horizon most of all. Note the
fog is tuned via **`GameConfig.background_color`** and the per-region look tables,
NOT `main.tscn`: `world.gd` overwrites `env.fog_light_color` from
`cfg.background_color` every boot and `_apply_region_look` overrides it again.

### `billboard_particle.gdshader` — `spatial`, `unshaded`, `depth_draw_opaque`
Screen-aligned billboard with a **per-instance roll, size and colour** — the
material behind the wheel-particle pool (`scripts/wheel_particles.gd`, see
[wheel-dust.md](wheel-dust.md)). It exists because `BaseMaterial3D`'s
`BILLBOARD_ENABLED` rebuilds the model-view basis from the camera columns and
**discards the basis the MultiMesh supplied**, keeping only the origin — so a
per-particle rotation has nowhere to live under the stock material
(`billboard_keep_scale` restores the scale, never a roll).

The instance basis is therefore *read* rather than thrown away: column **lengths**
are the quad's half-extents and column 0's **direction** is `(cos, sin)` of the
roll, which keeps the MultiMesh stride at the standard 12 transform floats (+4 for
`use_colors`) with no `INSTANCE_CUSTOM` stream. The vertex shader scales the unit
quad, rolls it in the billboard plane, then projects onto `INV_VIEW_MATRIX`'s
right/up columns and rewrites `POSITION` directly (same bypass as
`billboard_opaque.gdshader`). Fully screen-aligned (spherical) rather than the
world-Y-up cylindrical form the tree billboards use — a flung clod has no
meaningful "upright". Per-instance `COLOR` goes straight to `ALBEDO` (unshaded).
Opaque, so a pool at its cap costs no transparency sorting. **The basis layout is a
contract shared with `wheel_particles.gd._write_slot` — change both together.**

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
`outer_radius` (each streak starts at a random radius in this band and runs SOLID
out to the screen edge — a higher `inner_radius` keeps more of the centre clear /
shorter streaks, and the gap between the two varies the streak lengths),
`flicker_speed` (per-streak flicker rate in steps/sec — time is quantised and a
per-streak random is thresholded so each streak is either fully drawn or gone for
the step: a hard on/off cut, like hand-inked lines blinking in and out, not a
smooth opacity fade).
Fragment: aspect-corrected centre-origin coords → bucket the angle into `density`
slots (one streak each) → thin hard-edged streak (a `step`, no feathering) + a
hard-cut flicker → mask by a hard, per-streak-varied radial start → output
`line_color` with the computed alpha.

`scripts/speed_lines.gd` (on the `SpeedLines` CanvasLayer) pushes the static
look from config once in `_ready()`, then each frame maps the car's airspeed
across `[speed_lines_start_kmh, speed_lines_full_kmh]` → `[0, 1]`, scales by
`speed_lines_max_intensity`, and eases the `intensity` uniform toward that target
(`speed_lines_response`) so the streaks fade in/out rather than pop. All tunables
live in `GameConfig` under the **Speed Lines** group.

The overlay is **driving-only**: `world.gd::_hide_driving_ui` switches the `SpeedLines`
layer off alongside the HUD and the touch controls when a run hands over to the
cinematic replay, so the streaks never play over a replay the player is only watching.
See [event-replay.md](event-replay.md).

## Authored body models (MX-5, Focus, Twingo, Acty, Charger, The Beast)

Cars with `use_model` on their CarLibrary spec render an authored glb body
instead of the procedural chassis+cabin boxes; a car without the flag falls back
to the boxes. Every car in the shipped roster now carries a model: the **MX-5**
(`blender/mx5/mx5.glb`, node `Car/Mx5Body`), the **Focus**
(`blender/focus/focus.glb`, node `Car/FocusBody`), the **Renault Twingo**
(`blender/twingo/twingo.glb`, node `Car/TwingoBody`), the **Honda Acty**
(`blender/acty/acty.glb`, node `Car/ActyBody`), the **Charger R/T**
(`blender/charger/charger.glb`, node `Car/ChargerBody`), **The Beast**
(`blender/thebeast/mrbeast.glb`, node `Car/TheBeastBody`), the **911 Turbo**
(`blender/911/911.glb`, node `Car/Porsche911Body`), the **Jaguar XJS**
(`blender/xjs/xjs.glb`, node `Car/XjsBody`) and the **Viper RT/10**
(`blender/viper/viper.glb`, node `Car/ViperBody`). All are
instanced in `car.tscn`, hidden by default. The procedural-box path still exists
as the fallback for any spec that omits `use_model`.

The mapping is spec-driven (not hard-coded per car): each model car names its
`model_node` (the body node to show) and `model_texture` (the baked albedo). The
glb axes vary per export, so each body's `car.tscn` transform is a pure rotation
that points its length axis down the car's forward (-Z) axis; each body's
vertical offset is tuned per model so it seats on the wheels. `car.gd`'s `apply_car()` hides
**all** model bodies (`_model_node_names()`) and the boxes, shows the spec's
`model_node`, and assigns the `ps1_models_lit.gdshader` material to its mesh —
`albedo_texture` = the spec's `model_texture`, `albedo_color` white — so the
painted detail renders through the same quantize/dither/fog pipeline as the rest
of the scene. The four wheels stay procedural; the collision box is unchanged
(and invisible). Models are used at 1:1 scale.

## Per-car wheel-cap textures

The four wheels are procedural cylinders; the flat cap faces (the disc seen from
the side) take a per-car texture via `ps1_wheel_tire.gdshader`. `apply_car()`
assigns each tire a `ShaderMaterial` from `car.gd:_wheel_material()`, keyed by the
spec's optional `wheel_texture`: the MX-5 uses `blender/mx5/wheel.png`, the Focus
`blender/focus/wheel.png`, the Twingo `blender/twingo/wheel.png`. A car **without**
a `wheel_texture` (the cars that
still render boxes) gets a **blank dark disc** — a shared 1×1 near-black
`ImageTexture` — so the cap reads as a plain hubcap until that car gets a real
model. Each per-car material also carries the tread `albedo_color`
(`cfg.wheel_color`) and the fake-light uniforms (`cfg.apply_car_light`), which
`world.gd` previously set on the single shared tire material.

## Materials & colors

`world.gd._ready()` pushes config colors into the shared shader materials:

| Node | Param | Config |
|------|-------|--------|
| Car/Chassis | `albedo_color` | `chassis_color` (red) |
| Car/Cabin | `albedo_color` | `cabin_color` (dark blue) |
| Wheels (all 4) | `albedo_color` | `wheel_color` (black) — now carried by each per-car tire material (see "Per-car wheel-cap textures") |
| Car meshes + authored body | fake-light uniforms | Lighting group (`cfg.apply_car_light`) |
| Floor (terrain) | baked vertex-colour shading | Lighting group (`cfg.apply_terrain_light`) |
| PostProcess (SubViewportContainer) | `virtual_resolution` | `cfg.virtual_resolution` |

### `weather_lit` — the shared rule for fake lighting

Every material here is `unshaded`, so **nothing dims when the world gets darker
unless it is told to**. A material that is never told keeps rendering full
daylight against a dimmed scene and reads as glowing. `GameConfig.weather_lit(col)`
is the one place that knows the rule: multiply RGB by the runtime
`weather_sun_mult`, preserve alpha (alpha carries meaning — scaling it would make
a dim lake transparent rather than dark).

Route any new fake-lit material through it. The existing users:
`apply_car_light` (`ps1_models_lit.gdshader`), `apply_foliage_light`
(`billboard_opaque.gdshader`, mirroring the car helper so trees and car can't
drift apart), `LakeField.build` (`water.gdshader` colours + the sun-glint sparkle)
and `SignField._material_for` (`albedo_color`). Terrain is the exception — it
takes the same dimming through the vertex-colour bake instead. Full write-up in
[weather.md](weather.md) → "Unshaded means nothing dims for free".

## Environment

- No light nodes and no engine lighting pass — the materials stay `unshaded`.
  Car meshes get cheap fake per-vertex (Gouraud) lighting from the car-only
  `ps1_models_lit.gdshader` (computed live, since the car rotates). The terrain
  gets the same hemisphere+sun look **baked into its vertex colours** once at
  generation time, so its shader keeps a pass-through vertex path and the
  heaviest geometry pays nothing per frame. Trees/bushes/signs stay flat.
  **This still holds with the night headlight cone** — the cone added no light
  node either; it is arithmetic in the fragment/vertex code. What it did add is
  a *named mechanism* for fake LOCAL lighting, so "we have no lights" no longer
  means "we cannot light a spot": see "The fake headlight cone" below.
- **Skybox** (`main.tscn` env `background_mode = Sky`): a `PanoramaSkyMaterial`
  with a CC0 photographic open-field sky equirect (`textures/sky_field.png`, a tonemapped
  LDR downscale of a Poly Haven HDRI). The full-screen post-process quantizes it
  to the same 5-bit + dither look, so it reads as native PS1, not a pasted photo.
  `hq.gd` builds the same sky in code so HQ matches.
  **The panorama is re-seeded every stage boot, not conditionally overridden.**
  `world.gd._apply_region_look` assigns it unconditionally, falling back to
  `GameConfig.default_sky_panorama` when the region names none, then
  `_apply_weather_look` may swap it again for the condition — **night does, and
  only night** (`textures/sky-night.jpg`, via `GameConfig.night_sky_panorama`
  named by the night entry's optional `sky_panorama` key). The material is a
  shared `main.tscn` sub-resource with no `resource_local_to_scene`, so without
  that unconditional re-seed a Greece/snow/night sky followed the player into the
  next home stage and stayed — the same leak the ground-material re-seed below
  prevents. See [regions.md](regions.md) → "The sky no longer leaks between
  stages".
- **Sun alignment.** The car/terrain fake light (`sun_direction`) must point at
  the visible sun. Convention: panoramas are pre-rolled with
  `tools/align_sky_sun.py` so the sun sits at the image CENTRE — which is `+Z` in
  Godot's panorama mapping (verified in-engine) — so `sun_direction`'s azimuth is
  always `+Z` (`x≈0, z>0`) and only its elevation tracks the sky's sun
  height. Dropping in a new sky: run the tool (it rolls the image and prints the
  `sun_direction` to paste into `GameConfig`). The roll is a pure yaw, so the
  horizon stays level. (HQ uses its own `DirectionalLight3D`, independent of this.)
- **Distant terrain** (`scripts/distant_terrain.gd`, `DistantTerrain`): a coarse,
  collision-free backdrop of static `250 m` tiles sampling the same
  `height_at`/`light_at` as the real terrain, covering the whole precomputed
  corridor (`TerrainManager.corridor_bounds()`) plus a margin so the reduced
  fog reveals a horizon instead of the ring's hard edge. Built **once**, behind
  the loading screen, in `world._generate_track()` — the play area is bounded by the
  precomputed corridor, so it never re-centres or rebuilds at runtime (see
  [terrain.md](terrain.md) for the caveat on a car that outruns it). Tunables in
  `GameConfig` (`distant_terrain_*`).
- **Fog** demoted from edge-hider to thin aerial haze now that the backdrop hides
  the edge: `fog_density` (0.012), `fog_sky_affect` (0.15, so the sky reads above
  the haze), `fog_light_color = background_color` — and `background_color`
  (0.589, 0.544, 0.520) is **matched to the skybox's horizon** so the distant
  terrain dissolves into the sky seam. All applied in `world._ready()` from config.
- No bloom, no shadows.

### Weather look override (`world.gd::_apply_weather_look`)

A second override layered on top of the region look, driven by the condition's entry
in **`WeatherLibrary`** (`scripts/weather_library.gd`) — looked up once from
`GameConfig.weather` (seated per event — see `weather.md`). There is **no
per-condition branching here**: the entry's `look` block names the GameConfig fields
to read, its `road_tint` block names the field and the mode, and its `particles` key
names the particle kind. It is called **after** `_apply_region_look()`
and after `apply_terrain_light()` / the `tarmac_color` push, so it gets the last word
on both the sky and the ground, while still landing before the initial terrain build
in `_generate_track()` (so the darker sun/ambient is baked into the first chunks'
vertex colours). The two ground-material parameters the road tint modifies
(`tarmac_color`, `albedo_color`) are **re-seeded from the authored baseline** in
`_ready` just before this runs — the floor `ShaderMaterial` is a shared sub-resource
of `main.tscn`, so a read-modify-write tint would otherwise compound across stages
and leak into later dry ones (see [weather.md](weather.md) → "Look"). **A dry stage touches nothing** — dry's table entry has no `look`,
no `road_tint` and no `particles`, so all three blocks are skipped, nothing is
written and no node is built.

Wet applies `rain_background_color` (to `background_color` + `fog_light_color`),
`rain_fog_density_mult` × the config `fog_density`, `rain_fog_sky_affect`,
`rain_sky_color` and `rain_sun_energy_mult` onto the `TerrainManager`'s baked-light
inputs (written onto the manager, never onto the shared `GameConfig`, so a later dry
stage isn't left dimmed), and scales the floor material's `albedo_color` /
`tarmac_color` by `rain_road_darken`.

Night is the exception that proves the fog rule below: it is the one condition whose
entry names a `sky_panorama`, applied here **after** the region look so it wins, and
it is the only extra sky texture in the bundle.

**Overcast/dust look is made of fog, not a second sky.** Dry keeps `fog_sky_affect`
low (0.15) so the panorama reads above the haze; rain and sandstorm each invert that
— push it to their own `*_fog_sky_affect` (~0.9) with a flat background colour (grey
for rain, dusty tan for sandstorm) and the fog washes the *existing* panorama into a
featureless dome. No second sky texture to author, import or carry in the Android
bundle (download size gates installs on the low-end phones this game targets) and no
extra draw call — the environment half of any condition is free (but see "Fog does
not shorten the cull" below: it is not *cheaper* than dry, because nothing culls on
fog density). `world.gd._apply_weather_look` applies this override via the shared
`_apply_overcast_look`/`_tint_road` helpers, fed the field names from the condition's
table entry — so every condition is one mechanism with its own colour/parameter set,
not a copy-pasted path per condition.

**Particle field** (`scripts/rain_field.gd`, class `WeatherField` — kept under its
original filename to avoid churning the res:// path/uid rain shipped under, but the
class now covers both conditions): one `GPUParticles3D` parented to the **chase
camera**, so `rain_particle_count`/`sand_particle_count` quads cover the whole
visible field without simulating the world. Unshaded billboards, `SHADOW_CASTING_OFF`,
`COLLISION_DISABLED`, a single draw pass. `world.gd` calls
`WeatherField.spawn(camera, kind, count, wind_deg, speed)` — every value including the
travel speed comes from the field the entry names, so `WeatherField` reads no
condition's config field itself — and it dispatches on the table's
particle KIND to `spawn_rain` / `spawn_sandstorm` (both still public, and used
directly by tests); an empty kind — dry, and any future no-particle condition such as
fog — spawns nothing at all, so a dry stage builds no node and pays exactly zero new
per-frame cost — asserted by
`test_render_smoke.gd::test_no_weather_field_on_a_dry_stage`.

**World-space simulation is what makes speed matter, not a per-frame hack.**
`local_coords = false`: the node still follows the camera (so the emission box
stays where the player can see it), but each particle's own motion is simulated in
WORLD space once spawned. Driving forward genuinely carries the car through
standing rain/dust, so streaks past the windscreen and correct parallax emerge from
the simulation itself — faster automatically at higher speed, correct even while
sliding sideways — with **zero per-frame script cost**: no `car.linear_velocity`
read, no per-frame material writes. (An earlier iteration used
`local_coords = true` and faked the speed response by reading the car's velocity
each frame and tilting `process_material.direction`/resizing the quad off it — that
only ever looked right at a fixed camera angle, since the rain was actually glued to
the camera the whole time, and it didn't respond correctly to the car spinning; it
was removed in favour of the true world-space simulation.) The one thing still
authored per-particle-for-free is streak *orientation*: the draw material's
`billboard_mode = BILLBOARD_PARTICLES` (an engine feature, not hand-rolled geometry)
faces each quad to its own world-space velocity, so a falling/wind-blown drop reads
as a streak rather than a dot.

**Sandstorm** (`WeatherField.spawn_sandstorm`): dust blown in a single fixed WORLD
direction (`GameConfig.sand_wind_dir_deg`, a compass heading — 0 = world +X, 90 =
world +Z — resolved once at spawn) at the speed the entry's `particle_speed` names
(`sand_wind_speed`), using a squarer/softer
quad (`_SAND_QUAD_SIZE`) than rain's thin drop. The road tint that goes with it lerps
the ground albedo toward `sand_road_tint_color` — a config value the entry's
`road_tint` block names, not a literal in `world.gd`, which is why a future snow
condition could whiten the ground with no code change at all. A fixed world direction only reads
correctly under world-space simulation — under the old `local_coords = true` scheme
the "wind" would have rotated with the camera, which is exactly backwards. Covered
by `test_render_smoke.gd::test_sandstorm_field_is_a_single_cheap_draw_with_wind_direction`.
Sandstorm is authored only onto `region == "greece"` events — see
`RallyLibrary.WEATHER_SANDSTORM` and `test_rally_library.gd::test_sandstorm_only_authored_on_greece_events`.

**Fog** is the cheapest condition in the table and the purest use of this section's
"look is made of fog" mechanism: it is *only* a look block. `mist_fog_density_mult`
(the dominant knob — the whole effect) × the config `fog_density`, a high
`mist_fog_sky_affect` so the panorama washes out as rain's does, and a **pale,
luminous** grey (`mist_background_color` / `mist_sky_color`). Two deliberate
authoring choices, easy to get wrong: the colour must be *bright* — mist glows, and
making it dark reads as dusk rather than fog — and `mist_sun_energy_mult` stays near
1.0, because the diffuse glare of an un-dimmed sun through thick haze is what sells
it. Fog names no `particles`, no `grip_mult` and no `road_tint` (a foggy road is
dry), so it constructs no node at all.

**Lightning** (storm only, `world.gd::_start_lightning`): a brief spike in the same
environment colours the look block already drives — `fog_light_color` /
`background_color` tweened up by `storm_lightning_flash` and back (fast rise, slower
fall), re-armed by one self-scheduling `Timer` at a random interval in
`[storm_lightning_interval_min_s, storm_lightning_interval_max_s]`. The tween is
`TWEEN_PAUSE_STOP`, so a paused game is visually still rather than flashing behind the
pause menu. Deliberately
**not a light node**: this renderer is unshaded with baked vertex lighting and ships
with no lights at all (see "Environment" above), so a real flash would mean adding
the one thing the pipeline is built to avoid. It never touches the `TerrainManager`'s
baked sun/ambient (that would need a chunk rebake, not a per-frame tween). Kept
subtle and infrequent by authoring — a flash that blanks the screen mid-corner is a
gameplay event, not an effect — and purely cosmetic, so it may use `randf()`.

### The fake headlight cone (`shaders/headlight_cone.gdshaderinc`)

A dark weather condition re-lights a wedge in front of the player's car. Design
doc: `todo/night-weather-and-headlights.md`; the weather-table half is in
[weather.md](weather.md) → "Night".

**Which conditions have it is authored, not hardcoded.** The cone is armed by the
weather table's optional `headlights` key, naming the GameConfig field that holds
its STRENGTH (0..1); an entry without the key runs with the lights off. Night and
storm author it today. **The strength is the only per-condition part** — colour,
range, angles, offset, pitch and lamp separation are shared `headlight_*` fields —
and it is per-condition for a specific reason spelled out under "additive" below:
the cone is ADDED to a light term whose brightness differs per condition, so
night's strength on a storm's dimmed-day bake sums past 1 and clips the lit pool
to white. Storm therefore authors a much lower value than night. Retuning the
strengths, or adding the key to a third condition, is pure authoring — no driver,
shader or test change.

**Why it is not a light node.** Every material here is `unshaded`, so the engine
runs no lighting pass at all — a `SpotLight3D` would have literally zero effect
on any existing material. That is not a limitation to route around; it is the
design, and the cone respects it.

**Why it is not a vertex-colour rebake.** Terrain shading is baked on the CPU by
`TerrainManager.vertex_colors` (RGB = light, alpha = road blend). Driving a
*moving* light that way would mean regenerating `ARRAY_COLOR` for the whole
loaded ring — ~49 chunks × 51×51 verts, ~127k verts at LOD0 — **every frame**.
That is chunk-*generation* cost paid per frame. It is the one approach the
design exists to rule out.

**What it is instead:** an analytic cone pair, evaluated in the shaders from nine
global uniforms. No geometry, no draw calls, no per-frame CPU work beyond one
uniform push. The include declares the uniforms (`hl_pos`, `hl_dir`, `hl_right`,
`hl_color`, `hl_range`, `hl_cos_inner`, `hl_cos_outer`, `hl_separation`,
`headlight_amount`) and two functions: `_headlight_cone_at(world_pos, apex)` — a
`smoothstep` between the outer and inner cosines against `dot(dir, to_fragment)`,
times a linear range attenuation — and `headlight_lit(world_pos)`, which combines
the lamps and scales by `headlight_amount`. It is the ONE source of truth — the
five shaders the headlights can fall on all `#include` it rather than restating
the maths.

**Two lamps, combined with `max()` not a sum.** The pair shares aim, range, angles
and colour; only the apex differs, offset along `hl_right` by half `hl_separation`.
So the second lamp costs one more `_headlight_cone_at` and no extra parameters.
Summing them would produce a double-bright wedge straight ahead that reads as a
third light; `max()` holds the overlap at lamp brightness so the pair reads as a
widened pool. **`hl_separation == 0` skips the second cone entirely** on a branch
taken uniformly across the whole draw — the cheap case for a GPU — which is why the
single-cone setting is genuinely cheaper and not just a look. The doubling is paid
per-FRAGMENT only on terrain; the other four shaders evaluate per-vertex.

**Aim.** `hl_dir` is not simply the car's forward: the driver pitches it down by
`headlight_pitch_deg` about the car's own right axis. Without that the cone runs
parallel to the ground and the lit pool only begins where the outer edge descends
to ground level, several metres past the bumper. Pitching about the car's axis
(rather than the world's) keeps the aim glued to the road over crests and camber.

**It returns a `float`, not a colour**, so a shader that must carry it across the
vertex→fragment boundary can use a `varying float` instead of a whole `vec3`
interpolator. `hl_color` is multiplied in at the point of use. Bushes are
instanced densely and interpolator bandwidth is a real cost on tile-based mobile
GPUs.

**It is ADDITIVE on the light term — never a multiply.** This is the load-bearing
detail. The darkening is not done in any shader: it comes from the low
`night_sun_energy_mult`, which the terrain has already baked into `COLOR.rgb`. By
the time a shader runs the bake is near-zero, and a near-zero light term
multiplied by a bright cone factor is still near-zero — **a multiplicative cone
cannot re-light a darkened bake.** Every shader here already separates surface
from light (`COLOR.rgb` on terrain, `v_light` in `ps1_models_lit`, `v_tint` in
`billboard_opaque`), so the form is always:

```glsl
ALBEDO = surface * (light + hl_color * headlight_lit(world_pos));
```

At `headlight_amount == 0` the function returns exactly `0.0`, making every one of
these shaders a **bit-for-bit no-op** — which is what lets the cone ship inside
shaders that every unlit stage, the podium and the HQ also use.

**The flip side, and why the strength is per-condition:** a condition that only
*dims* the day rather than blacking it out (storm — its `sun_energy_mult` is a
fraction, not near-zero) lands the same additive cone on a much brighter light
term. Night's strength there sums past 1 and clips the pool to white. The fix is
authored — a lower `headlights` value on that entry — never a shader change.

**Fragment on terrain, vertex everywhere else:**

| Shader | Stage | Why |
|---|---|---|
| `ps1_models` (terrain), `ps1_terrain_snow` | **fragment** | Terrain cells reach 25 m across at the coarsest LOD band, so a per-vertex cone would snap its soft edge to triangle boundaries. World position comes from `(INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz` — a mat4 multiply per fragment, accepted because `ps1_models` is banned from having a `vertex()` stage to hand one down. |
| `ps1_models_lit` (cars, barriers, arch) | vertex | Folded into the existing `varying vec3 v_light` — no new interpolator. |
| `billboard_opaque` (trees) | vertex | Folded into the existing `varying vec3 v_tint`, in **both** branches — the felled branch computes an ambient-only tint, so a knocked-over tree would otherwise sit unlit inside the pool. Cards are small, so per-vertex is visually identical. |
| `tree_canopy` (bushes) | vertex + fragment | Had no lighting term at all, so it gets a new `varying float v_headlight`; `hl_color` is applied in the fragment so the varying stays scalar. |

Fragment cost therefore lands only on terrain — the one surface with near-total
screen coverage — while everything else rides an existing vertex computation.

**Transport is `global uniform`**, declared in `project.godot`'s
`[shader_globals]` section (the project had none before) and written via
`RenderingServer.global_shader_parameter_set`. The rationale is **correctness
under streaming, not speed**: materials are already shared per batch, so a
per-material push would only be ~10–30 calls a frame — but those materials are
built in five different scripts with no common registry, and terrain chunks
stream in continuously, so a per-material push would need re-registration
bookkeeping on every chunk load. Globals cannot go stale when a chunk appears
mid-frame.

**The scene-leak trap:** global shader parameters **persist across scene
changes**, and the podium and HQ draw trees and ground with these same shaders.
A stage that lit its headlights and did not clear up after itself would leave a
stray cone burning on those screens. `world.gd::_exit_tree` therefore calls `HeadlightCone.reset()`
unconditionally — every exit path, regardless of destination — which a
per-destination reset would not cover. Same reasoning as
`_apply_deep_snow_ground` being called unconditionally each stage boot.

**The driver** is `scripts/headlight_cone.gd` (`class_name HeadlightCone`), all
statics: `amount(cfg)` is the live condition's strength straight out of the
table and `has_headlights(cfg)` is that being above zero — the gate is authored
data, so no consumer tests `== WEATHER_x`; `params(cfg, xform)` returns
the name→value dictionary (split out from the push so the maths is testable
without a live `RenderingServer`, and so it can force the outer half-angle
strictly wider than the inner one however the two are authored); `push()` is
pure transport; `reset()` zeroes `headlight_amount`. `world.gd::_process` calls
`push()` once per frame with `$Car.global_transform` and early-outs on a
condition that authors no cone, and `world.gd::_ready` seeds it once so the opening frame is already
correct rather than dark for a tick.

**Not yet verified on a real GPU.** Headless tests confirm the shaders parse and
the maths is right, but whether `global_shader_parameter_set` actually reaches
shaders under this project's `gl_compatibility` renderer has not been observed in
a running frame. Five stages now author night (one per region — see
[weather.md](weather.md) → "Night"), so this is checkable simply by driving one;
do that before trusting any of it. Known open risks, all from the design doc: the
PS1 post-process grade
and 5-bit quantise were never tuned for a near-black frame (banding), the baked
light quantises to RGB8 so dark ambient steps coarsely, fog is environment-side
so the cone lights the ground but not the haze above it, and night is the
*most* expensive weather, not the cheapest — full render distance still draws a
nearly-black frame, plus the cone ALU on top.

### Fog does not shorten the cull (an unclaimed performance win)

**Known gap, verified — do not assume the fog "pays for itself".** Fog density is
*only* an `Environment` write. Nothing in the cull reads it:

- the terrain chunk ring is a compile-time `TerrainManager.RADIUS` (7×7 × 50 m
  chunks), and the LOD cutoffs come from `GameConfig.terrain_lod_bands_m` via
  `apply_terrain_lod()` — see [terrain.md](terrain.md);
- tree/bush/sign/spectator/arch draw distance is the single shared
  `GameConfig.tree_render_distance_m`, resolved once at boot by
  `tree_render_distance_for(web, touch)` and written back in `world.gd::_ready` —
  see "Shared render distance" below and [trees.md](trees.md).

So on a rain (×1.5), sandstorm (×2.0) or fog (much higher) stage the game still
builds, submits and shades every chunk and every tree the thickened fog then hides.
The smallest safe fix, if it is ever wanted, is a single multiplier on
`cfg.tree_render_distance_m` at the one `world.gd::_ready` write-back (it runs before
every foliage/prop spawn, and they all read that one field) — sourced from the
condition's `look["fog_density_mult"]`, since `_apply_weather_look` has not run yet
at that point. It was **deliberately not done here**: shortening the tree cull is a
visible pop-in/quality trade-off that needs tuning and playtesting rather than a
derived constant (at rain's density, objects at the shortened distance are still
~45% visible), and touching the terrain LOD bands additionally perturbs
`TerrainManager.detail_ring()` and the corridor precompute pruning.

## Tests

## Shader pre-warm (gl_compatibility first-use compiles)

The GL Compatibility backend compiles a shader program (and uploads its textures)
the **first time each material renders**, which on web stalls that frame — confirmed
via the benchmark's cold-vs-warm two-pass (a fresh WebGL context spikes to ~80 ms on
first-use draws; a warm second pass of the same stage drops to ~30 ms — see
[benchmark.md](benchmark.md)). Two load-time warm passes pay those compiles behind
the loading cover instead of mid-drive:

- **Contract walk** (`world.gd` warm block, ~line 517): after the world is built,
  `find_children()` discovers **every** node implementing the
  `warm_up(pos)`/`clear_warm_up()` contract and primes each — instead of a hardcoded
  list. Each `warm_up()` draws one throwaway instance **through its real draw path**
  (single mesh / MultiMesh / particle / 2D), so the correct gl_compatibility program
  *variant* compiles (not a synthetic quad that would compile the wrong one). Cleared
  after the rendered frame. Implementers today: `tire_marks.gd`, `wheel_particles.gd`,
  `engine_smoke.gd` (via `cpu_particle_pool.gd`), and `spectator_group.gd` (the
  ragdoll's single-instance crowd-mesh variant, distinct from the crowd MultiMesh).
  **Any new effect is included automatically just by implementing the contract** — no
  edit to `world.gd` — which is the guardrail against future first-use spikes silently
  shipping. (A runtime-only variant that isn't in the tree at load must still be
  primed by a node that IS in the tree — e.g. `SpectatorGroup` warms its own ragdoll.)
- **Corridor pre-warm** (`world._prewarm_corridor`, every platform): flies a
  throwaway camera along the whole built road centreline while loading, so the
  static-world materials (terrain, trees, signs, the crowd MultiMesh) all render —
  and compile — once up front. Runs behind the loading cover (its call site inside
  `_generate_track` is gated on `loading != null and not _headless`, before the
  overlay drops, so the fly is never visible). Measured to cut cold-run benchmark
  spikes ~3× (9 → 3).
  Residual spikes are gameplay-only draw variants that a static camera fly can't
  reproduce; these are web-only (the native APK keeps a persistent shader cache) and
  need on-device GL tooling (chrome://inspect) to pin further. NOTE: the knocked
  spectator's single-instance ragdoll mesh — long cited here as the example — now
  implements the warm-up contract and is primed by the contract walk, so it is no
  longer a residual. The last known gap was the **speed-lines overlay**, which is a
  `CanvasLayer` the corridor fly structurally cannot reach (see below); it now
  implements the contract too.

  **Anything a camera fly can't bring into view needs the contract, not the
  corridor.** The corridor pre-warm only compiles 3D materials that fall inside a
  forward-looking frustum along the racing line. A screen-space overlay, or anything
  hidden until a gameplay event fires, must implement `warm_up()`/`clear_warm_up()`
  or it will compile mid-drive. `speed_lines.gd` is the worked example: it starts
  hidden (`_apply_intensity(0.0)` hides the rect so a stationary car never shades a
  transparent full screen), so its full-screen program used to compile the first
  time the car crossed `speed_lines_start_kmh` — mid-acceleration off the start
  line. Its `warm_up()` simply shows the rect for the warmed frame with `intensity`
  still at 0, so the compile lands while the shader outputs fully transparent.
- **Per-chunk terrain resolution** (`terrain_manager.gd`, behind the loading cover):
  the corridor precompute classifies each chunk near/far from the racing line and
  only builds the LOD levels a far chunk can ever display — far chunks skip the full
  `SAMPLES²` grid + collision entirely, cutting precompute (and cache size) sharply.
  The on-the-fly runtime chunk build was removed at the same time: a corridor cache
  miss leaves a **hole** rather than a mid-drive hitch. Tunables:
  `terrain_precompute_prune_enabled` (master toggle) and
  `terrain_precompute_safety_slack_m` (extra reach so replay-camera shots never expose
  a pruned level). See [terrain.md](terrain.md) → per-chunk classification.

## Performance defaults (inherently low-end)

The game ships one lean pipeline for every device (no quality tiers). Relevant
shipped knobs in `GameConfig`:
- **Frame cap** — the applied `Engine.max_fps`, resolved in `world._ready()`
  (skipped under `--headless`, so it never throttles the test runner) from
  **`FpsSetting`** (`scripts/fps_setting.gd`): the player's **Settings → Display**
  choice of **30 / 60 / uncapped**, persisted under `FpsSetting.SETTING_KEY`
  (`"fps_cap"`). When the player hasn't chosen, `FpsSetting.default_cap()` falls back
  to the platform's natural cap via `GameConfig.target_fps_for(Platform.is_mobile_or_web(),
  Platform.is_web(), Platform.is_touch())`. The picker (`settings_menu.gd` →
  `select_fps`) writes `Engine.max_fps` **live** (the frame cap is a global engine
  property, so no live-scene signal is needed — both the HQ and pause hosts take
  effect immediately) and `world._ready()` re-derives it next run. During a benchmark
  the config-driven cap wins (`Benchmark.active` → `default_cap()`), so the uncap
  toggle still works regardless of the player's saved setting. **`target_fps`**
  (desktop/native, default 60) / **`target_fps_mobile`** (native mobile, default 60) /
  **`target_fps_web`** (web, default 30) remain the *default* source: the web cap
  applies only to a web **touch device** (phone/tablet browser); a **desktop browser**
  (web but not touch) gets the full desktop `target_fps` — the 30fps ceiling is a phone
  concession, not a browser one. `Platform.is_touch()` is the same reliable check the
  mobile control picker uses (`DisplayServer.is_touchscreen_available()` + the
  `mobile_controls_force` override). Web-touch still wins over the mobile branch since
  both are true on web.
  Web is capped lower than native for thermal/battery headroom, but the floor is set
  by **audio**: on the **single-threaded web build** audio is serviced by the main
  loop (no audio thread), so a lower frame rate drains the generator + WebAudio
  output buffers between frames and produces gaps/crackle. 30 fps on web is viable
  only because the audio buffers are sized to bridge a ~33 ms inter-frame gap plus
  jitter — the engine generator buffer (`BUFFER_SECONDS_TOUCH` 0.2 s on web-touch,
  per `engine_audio.gd`'s `buffer_seconds()`) and
  `audio/driver/output_latency.web` (150 ms) in `project.godot`. Raise those before
  lowering the web cap further; the tradeoff is added throttle→sound latency. The
  native Android APK has a real audio thread and runs fine at 60. `0` = uncapped.
  Physics stays at the project physics tick. See [engine-audio.md](engine-audio.md).
- **`texture_lod_bias`** (default 0.75) — biases distant foliage sampling toward
  cheaper mip levels (a `lod_bias` uniform in `shaders/billboard_opaque.gdshader`, set
  from `BillboardField.build()`). The tree/bush textures now have **mipmaps
  enabled** — every texture in `textures/` does, including the snow/taiga trees
  (`tree-snow.webp`, `tree-snow-laden.webp`, `tree-taiga.webp`) and the snow ground
  and road tiles; see [asset-pipeline.md](asset-pipeline.md) → "Texture import
  settings" — so distant
  billboards no longer thrash the texture cache. `filter_nearest` is kept (PS1
  look) — mipmapping is independent of the magnification filter.

### Shared render distance

Every roadside prop culls at **one shared distance** — `cfg.tree_render_distance_m`
(fade `tree_render_fade_m`) — so foliage, spectators, signs and the start/finish
arches all pop in at the same range instead of each system choosing its own (or
drawing across the whole stage).

That shared distance is **per-target**: a web **touch** device (phone/tablet browser
— the same low-end target as the 30fps `target_fps_web` cap) gets the shorter
`tree_render_distance_web_touch_m` (60 m); every other target (native mobile, desktop,
desktop browser) gets the longer `tree_render_distance_m` (120 m). `world.gd._ready`
resolves the effective value ONCE at boot via `GameConfig.tree_render_distance_for(web,
touch)` and writes it back onto `cfg.tree_render_distance_m`, so all the readers below
stay unchanged. The terrain LOD bands split the same way —
`terrain_lod_bands_for(web, touch)` picks `terrain_lod_bands_web_touch_m`
(`[40,70,80,90]`, finer levels dropped sooner) for web-touch vs the higher-quality
`terrain_lod_bands_m` (`[60,100,115,120]`, finer terrain held out to the longer
desktop render distance) for everyone else — resolved into `cfg.terrain_lod_bands_m`
before `apply_terrain_lod()` (see [terrain.md](terrain.md)).

The mechanism is a `GeometryInstance3D`
`visibility_range_end` + `visibility_range_end_margin` (fade mode `SELF`, so the
cull dithers rather than pops):

- **Trees / bushes** set it per-bin in `TreeMeshField` (`foliage.gd` passes the
  distance).
- **Spectators** set it on the group `MultiMeshInstance3D` (anchored at the crowd
  centroid so the single test measures camera→crowd distance) — see
  [spectators.md](spectators.md).
- **Signs** set it on each resting-sign `MultiMeshInstance3D` (`sign_field.gd`).
- **Start / finish arches** apply it to the whole arch subtree (structure, banners,
  ropes) after build — see [finish-arch.md](finish-arch.md).

Non-foliage props go through `MeshUtil.apply_visibility_range(root, end_m, fade_m)`,
which walks a subtree and sets the fields on every `GeometryInstance3D`
(MeshInstance3D / MultiMeshInstance3D / Label3D); `end_m <= 0` leaves the subtree
uncapped (flat test fixtures). The distance reaches spectators/signs via their
`GameConfig` param dicts (`render_distance_m` / `render_fade_m`). Because it's one
field, the benchmark's **Full render distance** toggle (which halves
`tree_render_distance_m`) now scales every prop's cull together.

Rendering **setup** (environment, mesh shader materials, post-process shader,
shader sources) is covered by `test_render_smoke.gd` — see
[testing.md](testing.md). There is no pixel-diff golden test: it only worked
windowed and was chronically flaky, so the actual rendered look is not asserted
pixel-for-pixel. Eyeball intentional look changes in the running app.

### Flat ground planes (HQ apron / podium floor)

The HQ hub and the podium share one flat-ground builder,
`MeshUtil.feathered_ground_mesh(size, subdiv, pads, feather)` — a grass plane with
rectangular tarmac `pads` cut into it, the tarmac weight written per vertex into
`COLOR.a` and blended by the road-blend shader (`ps1_models.gdshader`,
`blend_road = true`), the same treatment the generated track's verges get.

The plane is **flat**, so the ONLY thing subdivision buys is resolution for the
smoothstep feather band around the pad edges — a few metres of a 120–240 m plane.
A uniform `(subdiv+1)²` grid therefore spends essentially all its vertices on
nothing: the HQ ground alone used to be **58,081 verts / 115,200 tris**, drawn
every frame on `hq.tscn`, the game's first screen. With no lights, no shadows and
a low virtual resolution, the game is vertex- and draw-call-bound, not
fragment-bound, so that was the single largest vertex outlier in the project.

The grid is now **non-uniform** (`MeshUtil._ground_grid_lines`). Per axis, the
vertex lines are the union of

- a **coarse** lattice of `subdiv` divisions across the whole plane, and
- a **fine** lattice covering only the feather band either side of each pad edge
  on that axis (step `feather/4`, spanning `feather*0.5` inside to `feather*1.25`
  outside the edge), de-duplicated against the coarse lines.

It stays a tensor-product grid (sorted x line-set × sorted z line-set), so the
triangulation is unchanged and pad **corners** are covered too — a fine x line
spans the full z extent. Net effect: the feather band is sampled *finer* than the
old uniform grid managed, at ~3% of the vertices (HQ: 1,681 verts / 3,200 tris;
podium floor: 2,337 / 4,480).

`subdiv` is now only the coarse lattice, and both callers read it from
`GameConfig.ground_subdiv_for(web, touch)` (`ground_subdiv` /
`ground_subdiv_web_touch`) rather than hardcoding it — `HQEnvironment.build` and
`podium.gd::_build_environment`. Verification aid:
`tools/render_ground_feather.gd` renders the apron and a podium pad with the old
uniform grid and the new one (`docs/perf/ground_*.png`) so the band can be
compared directly.

> **The speed-lines rect is hidden below `VISIBLE_EPSILON`.** It used to stay `visible`
> whenever `speed_lines_enabled`, so below `speed_lines_start_kmh` the shader still
> rasterised the whole screen (an `atan` plus three `sin`-based hashes) to blend a
> fully transparent result. `speed_lines.gd::_apply_intensity` now toggles visibility and
> skips the `set_shader_parameter` when the value hasn't changed.


## The snow terrain shader variant

`shaders/ps1_terrain_snow.gdshader` is `ps1_models.gdshader` plus a single vertex stage
that raises the ground off-road, so the car visibly sinks into deep snow.

It exists as a **separate shader** rather than a uniform on the shared one because the
terrain shader is deliberately kept free of any vertex stage — terrain is the heaviest
geometry in the game and this renderer targets low-end phones — a ban enforced by
`test_render_smoke.gd::test_terrain_shader_has_no_vertex_stage`. Same pattern as
`ps1_models_lit.gdshader`, which exists so the car's fake lighting does not land on the
terrain either. Only snow stages pay for it.

**The two fragment stages must be kept in sync**, and so must their **uniform
sets** — `ps1_terrain_snow` `#include`s `headlight_cone.gdshaderinc` and applies
the cone exactly as `ps1_models` does, because the swap below relies on
`ShaderMaterial` keeping its by-name parameter map across a shader change. A
uniform added to one and not the other silently drops its value on a snow stage.
`world.gd._apply_deep_snow_ground`
swaps the floor material between them every stage boot, including restoring the base
shader, because that material is a shared `main.tscn` sub-resource that survives scene
instantiation. See [snow-region.md](snow-region.md).
