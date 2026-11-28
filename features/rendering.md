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
  nearest. The sole
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
(default **1.1**, set in the "PS1 Look" group of `scripts/game_config.gd`;
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
`tests/headless/test_display_stretch.gd`. Its `design_height` parameter defaults to
`DESIGN_HEIGHT`, with two overrides chosen by the pure
`DisplayStretch.design_height_for()`: while a benchmark is active, a positive
`Benchmark.render_height` wins (see [benchmark.md](benchmark.md)); otherwise the `render_height` look value (GameConfig)
applies — a positive value is a fixed logical height, 0 follows the WINDOW
height (device-native; measured effectively free on a low-end phone). UI/touch
controls are laid out in logical units, so they draw smaller as the height
rises — an accepted trade. A degenerate window falls back to the authored
`DESIGN_HEIGHT`.

### Safe area (notch, rounded corners, home indicator)

On mobile, `DisplayStretch` also reads `DisplayServer.get_display_safe_area()` on every
resize (`_update_safe_area`), converts it to logical pixels (`safe_insets`) and keeps it
in the static `inset_start` / `inset_end`. The 3D world still fills the whole screen;
only the UI moves in. It does that once for every screen: each Control that is a direct
child of a CanvasLayer has its offsets shifted (`fit_offsets`) so its anchors resolve
against the safe area instead of the full frame — a full-rect menu shrinks to the safe
area, a bottom-right label moves up and left. `ColorRect`s are skipped so full-screen
dims and backdrops still cover the notch.

Widgets that place themselves every frame by `position` (the HUD dial, the minimap, the
cargo label) would undo that, so they add `DisplayStretch.safe_shift(anchor)` — the same
shift for the corner they hug — to the position they compute. The touch controls
(`mobile_controls.gd`, `photo_mode_controls.gd`) are left alone: their hit areas are
meant to run to the screen edges. Off mobile (desktop, web, tests) none of this runs.

## Shaders (`shaders/`)

### `level_ground.gdshader` — the level's ground
The Hafren ground: its texture blend, baked light and snow lift are covered in
[level-streamer.md](level-streamer.md), [level-ao.md](level-ao.md) and
[snow-region.md](snow-region.md). It `#include`s `shaders/headlight_cone.gdshaderinc` and adds
the night cone into its light term in the fragment; see "The fake headlight cone" below.

### `ps1_models_lit.gdshader` — `spatial`, `unshaded`
Car-only shader with cheap fake per-vertex (Gouraud)
lighting. Kept SEPARATE from the ground shader on purpose: only the handful of
car/wheel/body vertices run its `vertex()` stage, so the ground pays nothing
for a feature it doesn't use.

The material stays `unshaded` — the engine runs *no* lighting pass, casts no
shadows, and there are still no light nodes. `vertex()` computes a PS1/PS2-style
term in world space and the fragment multiplies it into `ALBEDO`: a hemisphere
ambient (`mix(ground_color, sky_color, N.y·0.5+0.5)`) plus one hardcoded
directional "sun" (`max(dot(N, light_dir), 0) × sun_color`) — a dot product per
vertex, interpolated for free by the rasteriser. `light_amount`
(`mix(vec3(1.0), lit, light_amount)`) blends the whole effect in: 0 = flat,
1 = full. Uniforms `albedo_texture`, `albedo_color`, `texture_tile`,
`light_amount`, `light_dir`, `sun_color`, `sky_color`, `ground_color`.
`car.gd` calls `cfg.apply_car_light()` on the chassis/cabin/wheel
materials and, in `_apply_model_material()`, on the authored bodies (MX-5, Focus, Twingo).
The values (`car_light_amount` + the shared `sun_direction`, `sun_color`,
`sky_color`, `ground_color`) live in `GameConfig` under the **Lighting** group. `sun_color` and
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
(`scripts/post_process_view.gd`), packaged as **`post_process.tscn`** and instanced by
**`level_view.tscn`** (as `PostProcess`). The 3D world stays in the main tree but
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
— is pushed by **`GameConfig.apply_post_process`**, called from
`post_process_view.gd`'s `_ready`, so every host gets it without its own call. That single helper is deliberately
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
Look** group of `game_config.gd` (`grade_amount`, `grade_saturation`,
`grade_contrast`, `grade_shadow_tint`, `grade_highlight_tint`,
`grade_vignette_strength`, `grade_vignette_radius`), pushed by `post_process_view.gd`'s
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

Scope is the 3D frame of the **stage** — world, props, cars and sky. (The old
diegetic HQ shared this pass; it is deleted with the pivot — the flat hub needs
no 3D render at all.) The HUD and every menu overlay are CanvasLayers above the
container and stay ungraded. `test_render_smoke.gd` pins the shared world.

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
fog is authored in `level_view.tscn`'s environment, and `LevelWeather` fades it
toward each weather's own colours (`LevelWeather.target_look`).

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
right/up columns and rewrites `POSITION` directly. Fully screen-aligned (spherical) — a flung clod has no
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

**Currently disabled by default** (`speed_lines_enabled = false`); there is no menu row, so it stays off unless that default is flipped back.

**Whether the effect draws at all is a player setting**, owned by
`scripts/speed_lines_setting.gd` (`SpeedLinesSetting`) — the key (`"speed_lines"`),
the fallback default (the authored `GameConfig.speed_lines_enabled`), `resolve()`,
and an `apply(tree, on)` that persists the choice AND pushes it to every live
overlay (they join `SpeedLinesSetting.GROUP` in `_ready`). This follows the
per-setting apply-owner pattern; `scripts/fps_setting.gd` is the exemplar. `Config.data.speed_lines_enabled` is the **authored baseline only** — a
player toggle must never write it, or the default drifts with player input.

`speed_lines.gd` wires itself **unconditionally** (material bound, static look
pushed) and gates only drawing/processing through the idempotent
`set_effect_enabled(on: bool)` (plus `is_effect_enabled()`), which is safe before
or after `_ready` and correct in both directions. That split is deliberate: the
old `_ready` returned early when the effect was off, leaving `_mat` null and
`_process` disabled, so a disabled overlay could never be switched back on without
a scene reload.


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
(`blender/viper/viper.glb`, node `Car/ViperBody`), and the **F-150** (`blender/f150/f150.glb`, node
`Car/F150Body`) — a body modelled by hand over a photogrammetry scan and painted from a video of the
real paint (`tools/car_scan/texture.py`, see [car-scanning.md](car-scanning.md)); its `track`,
`wheelbase` and `wheel_radius` were measured off the scan's wheels and its arches were cut there, so they
must stay matched. It rides on its own scanned `wheel_model` (see Scanned wheel models below). The MX-5 body is a
photogrammetry scan (made with `tools/car_scan/`, see [car-scanning.md](car-scanning.md)) decimated to ~500 tris, with its wheel arches cut where the
scan's wheels were — so its spec `wheelbase` (2.25) must stay matched to the arches
or the wheels clip the body. All are
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
of the scene. The wheels stay procedural (a cylinder), unless the spec names a `wheel_model` (below); the collision box is unchanged
(and invisible). Models are used at 1:1 scale.

## Scanned wheel models

A spec with a `wheel_model` (a glb: axle along +X, outer face toward +X, centred on the origin) shows that model
on every wheel instead of the cylinder: `car.gd` → `_apply_wheel_model`, called per wheel from `_relocate_wheels`,
instances it as `Visual/WheelModel`, hides `Visual/Tire`, scales it uniformly to the spec's `wheel_radius` (by the
model's own half-height) and turns right-hand wheels round, since every wheel's `Visual` faces local +X to the car's
left. It wears the glb's own texture through the same PS1 material as the bodies. A spec without the field gets the
cylinder back, and the model is dropped (`_drop_wheel_model`). Dropping it, or freeing the car
(`_notification` → PREDELETE), first clears its meshes' override materials (`_release_materials`):
freed together, the material could go before the mesh instance, and the renderer then reported
`Parameter "material" is null` (it failed `test_car_library` / `test_rest_pose` until 2026-10-31). The scale is uniform, so a model car's visual tyre width is the scan's,
whatever `wheel_width_front`/`_rear` say (they still set grip). A `wheel_model` that won't load falls back to the
cylinder with a warning. Spin and steer need nothing: `drivetrain.gd` → `_update_visuals` already
turns `Visual`. Built from the car's scan by `tools/car_scan/wheels.py` ([car-scanning.md](car-scanning.md)).
**Tests:** `tests/headless/test_wheel_models.gd`.

## Per-car wheel-cap textures

Cars without a `wheel_model` have procedural cylinder wheels; the flat cap faces (the disc seen from
the side) take a per-car texture via `ps1_wheel_tire.gdshader`. `apply_car()`
assigns each tire a `ShaderMaterial` from `car.gd:_wheel_material()`, keyed by the
spec's optional `wheel_texture`: the MX-5 uses `blender/mx5/wheel.png`, the Focus
`blender/focus/wheel.png`, the Twingo `blender/twingo/wheel.png`. A car **without**
a `wheel_texture` (the cars that
still render boxes) gets a **blank dark disc** — a shared 1×1 near-black
`ImageTexture` — so the cap reads as a plain hubcap until that car gets a real
model. Each per-car material also carries the tread `albedo_color`
(`cfg.wheel_color`) and the fake-light uniforms (`cfg.apply_car_light`).

## Materials & colors

`car.gd._ready()` colours and lights the box body (`Chassis` / `Cabin`); the rest is set where noted:

| Node | Param | Config |
|------|-------|--------|
| Car/Chassis | `albedo_color` | `chassis_color` (red) |
| Car/Cabin | `albedo_color` | `cabin_color` (dark blue) |
| Wheels (all 4) | `albedo_color` | `wheel_color` (black) — now carried by each per-car tire material (see "Per-car wheel-cap textures") |
| Car meshes + authored body | fake-light uniforms | Lighting group (`cfg.apply_car_light`) |
| PostProcess (SubViewportContainer) | `virtual_resolution` | `cfg.virtual_resolution` |

### `weather_lit` — the shared rule for fake lighting

Every material here is `unshaded`, so **nothing dims when the world gets darker
unless it is told to**. A material that is never told keeps rendering full
daylight against a dimmed scene and reads as glowing. `GameConfig.weather_lit(col)`
is the one place that knows the rule: multiply RGB by the runtime
`weather_sun_mult`, preserve alpha (alpha carries meaning — scaling it would make
a dim lake transparent rather than dark).

Route any new fake-lit material through it. The existing users:
`apply_car_light` (`ps1_models_lit.gdshader` — cars, cargo, dust puffs) and the engine
smoke colour. On the Hafren level nothing
sets `weather_sun_mult`, so it stays 1: the level dims everything through `world_light`
instead (end of this file). Full write-up in [weather.md](weather.md) → "On the level".

**Every new fake-lit material must route through here — a hardcoded literal is
a bug, not a style choice.** The (since deleted) barrier modules once shipped with a copy-pasted block
hardcoding `sun_color`/`sky_color`/`ground_color`/`light_dir` as literals instead of calling
`apply_car_light`, so they never dimmed on a night or storm stage while every other prop
around them did. Before adding another hand-built `ShaderMaterial` on
this shader, grep for the literal `Color(0.55, 0.52, 0.48)` to catch a repeat.

## Environment

- **Environment**: authored in `level_view.tscn`; `level_view.gd` sets the fog's end distance
  (`level_fog_end_m`, `level_fog_curve`) and `LevelWeather` layers each weather's look on top.
- No light nodes and no engine lighting pass — the materials stay `unshaded`.
  Car meshes get cheap fake per-vertex (Gouraud) lighting from the car-only
  `ps1_models_lit.gdshader` (computed live, since the car rotates). The level's
  ground light is baked offline (see [level-ao.md](level-ao.md)).
  **This still holds with the night headlight cone** — the cone added no light
  node either; it is arithmetic in the fragment/vertex code. What it did add is
  a *named mechanism* for fake LOCAL lighting, so "we have no lights" no longer
  means "we cannot light a spot": see "The fake headlight cone" below.
- **Skybox** (`level_view.tscn` env `background_mode = Sky`): a `PanoramaSkyMaterial`
  with a CC0 photographic open-field sky equirect (`textures/sky_field.png`, a tonemapped
  LDR downscale of a Poly Haven HDRI). The full-screen post-process quantizes it
  to the same 5-bit + dither look, so it reads as native PS1, not a pasted photo.
  `LevelWeather` swaps the panorama for a condition that names one (`sky_panorama` — only
  night does, `textures/sky-night.jpg`) and back afterwards.
- **Sun alignment.** The car's fake light (`sun_direction`) must point at
  the visible sun. Convention: panoramas are pre-rolled with
  `tools/align_sky_sun.py` so the sun sits at the image CENTRE — which is `+Z` in
  Godot's panorama mapping (verified in-engine) — so `sun_direction`'s azimuth is
  always `+Z` (`x≈0, z>0`) and only its elevation tracks the sky's sun
  height. Dropping in a new sky: run the tool (it rolls the image and prints the
  `sun_direction` to paste into `GameConfig`). The roll is a pure yaw, so the
  horizon stays level. (HQ uses its own `DirectionalLight3D`, independent of this.)
- **Fog** is thin aerial haze, not an edge-hider: `fog_density` (0.012), `fog_sky_affect` (0.15, so the sky reads above
  the haze), `fog_light_color = background_color` — and `background_color`
  (0.589, 0.544, 0.520) is **matched to the skybox's horizon** so the distant
  terrain dissolves into the sky seam.
- No bloom, no shadows.

### Weather look (`LevelWeather`)

The level's weather look is driven by each condition's entry in **`WeatherLibrary`**
(`scripts/weather_library.gd`). There is **no per-condition branching**: the entry's `look`
block names the GameConfig fields to read and its `particles` key names the particle kind.
`LevelWeather.target_look` builds the environment a weather should end at, and `LevelWeather`
cross-fades fog, sky and `world_light` toward it; between fades it writes nothing. See
[weather.md](weather.md).

**Overcast/dust look is made of fog, not a second sky.** Dry keeps `fog_sky_affect`
low (0.15) so the panorama reads above the haze; rain and sandstorm each invert that
— push it to their own `*_fog_sky_affect` (~0.9) with a flat background colour (grey
for rain, dusty tan for sandstorm) and the fog washes the *existing* panorama into a
featureless dome. No second sky texture to author, import or carry in the Android
bundle (download size gates installs on the low-end phones this game targets) and no
extra draw call — the environment half of any condition is free (but see "Fog does
not shorten the cull" below: it is not *cheaper* than dry, because nothing culls on
fog density). Every condition is one mechanism with its own colour/parameter set,
not a copy-pasted path per condition.

**Particle field** (`scripts/rain_field.gd`, class `WeatherField` — kept under its
original filename to avoid churning the res:// path/uid rain shipped under, but the
class now covers both conditions): one `GPUParticles3D` parented to the **chase
camera**, so `rain_particle_count`/`sand_particle_count` quads cover the whole
visible field without simulating the world. Unshaded billboards, `SHADOW_CASTING_OFF`,
`COLLISION_DISABLED`, a single draw pass. `level_view.gd` → `apply_weather` calls
`WeatherField.spawn(camera, kind, count, wind_deg, speed)` — every value including the
travel speed comes from the field the entry names, so `WeatherField` reads no
condition's config field itself — and it dispatches on the table's
particle KIND to `spawn_rain` / `spawn_sandstorm` (both still public, and used
directly by tests); an empty kind — dry, and any future no-particle condition such as
fog — spawns nothing at all, so dry weather builds no node and pays exactly zero new
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
quad (`_SAND_QUAD_SIZE`) than rain's thin drop. A fixed world direction only reads
correctly under world-space simulation — under the old `local_coords = true` scheme
the "wind" would have rotated with the camera, which is exactly backwards. Covered
by `test_render_smoke.gd::test_sandstorm_field_is_a_single_cheap_draw_with_wind_direction`.

**Fog** is the cheapest condition in the table and the purest use of this section's
"look is made of fog" mechanism: it is *only* a look block. `mist_fog_density_mult`
(the dominant knob — the whole effect) × the config `fog_density`, a high
`mist_fog_sky_affect` so the panorama washes out as rain's does, and a **pale,
luminous** grey (`mist_background_color`). Two deliberate
authoring choices, easy to get wrong: the colour must be *bright* — mist glows, and
making it dark reads as dusk rather than fog — and `mist_sun_energy_mult` stays near
1.0, because the diffuse glare of an un-dimmed sun through thick haze is what sells
it. Fog names no `particles` and no `grip_mult`, so it constructs no node at all.

### The fake headlight cone (`shaders/headlight_cone.gdshaderinc`)

The same include also holds `flash_lit(world_pos)`: a short omnidirectional light flash
(globals `fl_pos`, `fl_color` with strength baked in, `fl_range`) used for exhaust flames
([exhaust-flames.md](exhaust-flames.md)). Every shader that adds `hl_color * headlight_lit(...)`
also adds `+ flash_lit(<same pos>)`. It is scaled by `1 - world_light`, so it shows only as far as the weather has darkened the world (none in full day).
`test_lighting_coverage.gd` enforces the pairing.

A dark weather condition re-lights a wedge in front of the player's car. (The
design spec `todo/night-weather-and-headlights.md` is gone; the weather-table
half is in [weather.md](weather.md) → "Headlights".)

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

**Why it is not a light rebake.** The ground's light is baked offline; driving a
*moving* light that way would mean re-baking every loaded tile **every frame**. It is
the one approach the design exists to rule out.

**What it is instead:** an analytic cone pair, evaluated in the shaders from nine
global uniforms. No geometry, no draw calls, no per-frame CPU work beyond one
uniform push. The include declares the uniforms (`hl_pos`, `hl_dir`, `hl_right`,
`hl_color`, `hl_range`, `hl_cos_inner`, `hl_cos_outer`, `hl_separation`,
`headlight_amount`) and two function PAIRS: `_headlight_cone_at(world_pos, apex)`
— a `smoothstep` between the outer and inner cosines against `dot(dir,
to_fragment)`, times a linear range attenuation — and `headlight_lit(world_pos)`,
which combines the lamps and scales by `headlight_amount`. Each has a
normal-aware overload (`..., world_normal)`) that additionally multiplies in
`smoothstep(-0.15, 0.4, dot(world_normal, to_light))`, floored rather than
hard-clamped at zero so faceted low-poly bodywork doesn't step at facet edges
near grazing angles. The car shader (`ps1_models_lit`) uses the
normal-aware overload so a car's REAR panels, still geometrically inside the
cone's angle/range, don't light up from behind;
every other includer uses the plain form. It is the ONE source of truth — the
six shaders the headlights can fall on all `#include` it rather than restating
the maths.

**Two lamps, combined with `max()` not a sum.** The pair shares aim, range, angles
and colour; only the apex differs, offset along `hl_right` by half `hl_separation`.
So the second lamp costs one more `_headlight_cone_at` and no extra parameters.
Summing them would produce a double-bright wedge straight ahead that reads as a
third light; `max()` holds the overlap at lamp brightness so the pair reads as a
widened pool. **`hl_separation == 0` skips the second cone entirely** on a branch
taken uniformly across the whole draw — the cheap case for a GPU — which is why the
single-cone setting is genuinely cheaper and not just a look. The doubling is paid
per-FRAGMENT only on terrain; the other five shaders evaluate per-vertex.

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
from light (`COLOR.rgb` on terrain, `v_light` in `ps1_models_lit`), so the form is always:

```glsl
ALBEDO = surface * (light + hl_color * headlight_lit(world_pos));
```

At `headlight_amount == 0` the function returns exactly `0.0`, making every one of
these shaders a **bit-for-bit no-op** — which is what lets the cone ship inside
the shaders that every unlit stage also uses.

**The flip side, and why the strength is per-condition:** a condition that only
*dims* the day rather than blacking it out (storm — its `sun_energy_mult` is a
fraction, not near-zero) lands the same additive cone on a much brighter light
term. Night's strength there sums past 1 and clips the pool to white. The fix is
authored — a lower `headlights` value on that entry — never a shader change.

**Fragment on the ground, vertex everywhere else:**

| Shader | Stage | Why |
|---|---|---|
| `level_ground` (the ground) | **fragment** | The ground's triangles are large, so a per-vertex cone would snap its soft edge to triangle boundaries. |
| `ps1_models_lit` (cars) | vertex | Folded into the existing `varying vec3 v_light` — no new interpolator. Passes its world normal into the facing-aware overload so rear panels reject the cone. |
| `level_tree` (trees) | vertex | `v_lamps = hl_color * headlight_lit(world_pos)`, added to the tree's light in the fragment. Cards are small, so per-vertex is visually identical. |

Fragment cost therefore lands only on the ground — the one surface with near-total
screen coverage — while everything else rides an existing vertex computation.

**Tree wind sway follows the identical pattern**, one shader over: `level_tree`
also `#include`s `shaders/wind_sway.gdshaderinc` and adds `wind_sway_offset(origin,
VERTEX.y, height)` straight into `world_pos`, entirely in the vertex stage. Its globals (`wind_strength`, `wind_speed`, `wind_dir`) are declared
alongside the cone's in `project.godot`'s `[shader_globals]` and driven by
`scripts/wind_sway.gd` (`class_name WindSway`) — see [trees.md](trees.md) → "Wind
sway" for the full writeup and [weather.md](weather.md) for the per-condition
authoring (`WeatherLibrary`'s `foliage_wind` key).

**Transport is `global uniform`**, declared in `project.godot`'s
`[shader_globals]` section (the project had none before) and written via
`RenderingServer.global_shader_parameter_set`. The rationale is **correctness
under streaming, not speed**: materials are already shared per batch, so a
per-material push would only be ~10–30 calls a frame — but those materials are
built in several scripts with no common registry, and level tiles
stream in continuously, so a per-material push would need re-registration
bookkeeping on every tile load. Globals cannot go stale when a tile appears
mid-frame.

**The scene-leak trap:** global shader parameters **persist across scene
changes**. A level that lit its headlights and did not clear up after itself
would leave a stray cone burning on whatever scene comes next. `level_view.gd` → `_exit_tree`
therefore calls `HeadlightCone.reset()` unconditionally — every exit path, regardless of
destination — which a per-destination reset would not cover.

**The driver** is `scripts/headlight_cone.gd` (`class_name HeadlightCone`), all
statics: `amount(cfg)` is the live condition's strength straight out of the
table and `has_headlights(cfg)` is that being above zero — the gate is authored
data, so no consumer tests `== WEATHER_x`; `params(cfg, xform)` returns
the name→value dictionary (split out from the push so the maths is testable
without a live `RenderingServer`, and so it can force the outer half-angle
strictly wider than the inner one however the two are authored); `push()` is
pure transport; `reset()` zeroes `headlight_amount`. `level_view.gd` → `_timed_process` calls
`push()` once per frame with the car's transform and skips it on a
condition that authors no cone.

**Not yet verified on a real GPU.** Headless tests confirm the shaders parse and
the maths is right, but whether `global_shader_parameter_set` actually reaches
shaders under this project's `gl_compatibility` renderer has not been observed in
a running frame. The level's weather pool can draw night (see
[weather.md](weather.md) → "Headlights"), so this is checkable simply by driving one;
do that before trusting any of it. Known open risks, all from the design doc: the
PS1 post-process grade
and 5-bit quantise were never tuned for a near-black frame (banding), fog is environment-side
so the cone lights the ground but not the haze above it, and night is the
*most* expensive weather, not the cheapest — full render distance still draws a
nearly-black frame, plus the cone ALU on top.

### Fog does not shorten the cull (an unclaimed performance win)

**Known gap — do not assume the fog "pays for itself".** Fog density is *only* an
`Environment` write. Nothing in the cull reads it: the level's tiles stream by distance
(`LevelStreamer`) and the trees cull at the shared `GameConfig.tree_render_distance_m`. So
on a thick-fog weather the game still draws everything the fog then hides. Shortening the
cull with the fog would be a visible pop-in trade-off that needs playtesting, so it was not
done.

## Tests

## Shader pre-warm (gl_compatibility first-use compiles)

The GL Compatibility backend compiles a shader program (and uploads its textures)
the **first time each material renders**, which on web stalls that frame — confirmed
via the deleted island benchmark's cold-vs-warm two-pass (a fresh WebGL context spikes to ~80 ms on
first-use draws; a warm second pass of the same stage drops to ~30 ms). Two load-time warm passes pay those compiles behind
the loading cover instead of mid-drive.:

- **Contract walk** (`level_view.gd` → `_warm_up`): after the level is built,
  `find_children()` discovers **every** node implementing the
  `warm_up(pos)`/`clear_warm_up()` contract and primes each — instead of a hardcoded
  list. Each `warm_up()` draws one throwaway instance **through its real draw path**
  (single mesh / MultiMesh / particle / 2D), so the correct gl_compatibility program
  *variant* compiles (not a synthetic quad that would compile the wrong one). Cleared
  after the rendered frame. Implementers today: `tire_marks.gd`, `wheel_particles.gd`,
  `engine_smoke.gd` (via `cpu_particle_pool.gd`), `spectator_group.gd` (the
  ragdoll's single-instance crowd-mesh variant, distinct from the crowd MultiMesh),
  and `car.gd` (a speck of every catalogue
  car's body + wheel texture, so a rest-stop car switch uploads nothing).
  `_warm_up` also spawns a small field of every weather particle kind, since the level only
  builds one when the weather turns.
  **Any new effect is included automatically just by implementing the contract** — no
  edit to `level_view.gd` — which is the guardrail against future first-use spikes silently
  shipping. (A runtime-only variant that isn't in the tree at load must still be
  primed by a node that IS in the tree — e.g. `SpectatorGroup` warms its own ragdoll.)
- **Look-around** (`WorldRuntime.look_around`): after the contract walk, `_warm_up` turns
  a throwaway camera around the car (and once from above), so the level's static materials
  render — and compile — behind the cover.

  **Anything the camera can't bring into view needs the contract.** A screen-space overlay,
  or anything hidden until a gameplay event fires, must implement
  `warm_up()`/`clear_warm_up()` or it will compile mid-drive. `speed_lines.gd` is the worked
  example: it starts hidden, so its full-screen program used to compile the first time the
  car crossed `speed_lines_start_kmh`. Its `warm_up()` shows the rect for the warmed frame
  with `intensity` still at 0, so the compile lands while the shader outputs fully
  transparent.

## Performance defaults (inherently low-end)

The game ships one lean pipeline for every device (no quality tiers). Relevant
shipped knobs in `GameConfig`:
- **Frame cap** — the applied `Engine.max_fps`, resolved in `level_view.gd` → `_ready`
  (skipped under `--headless`, so it never throttles the test runner) from
  **`FpsSetting`** (`scripts/fps_setting.gd`): the player's **Settings → Display**
  choice of **30 / 60 / uncapped**, persisted under `FpsSetting.SETTING_KEY`
  (`"fps_cap"`). When the player hasn't chosen, `FpsSetting.default_cap()` falls back
  to the platform's natural cap via `GameConfig.target_fps_for(Platform.is_mobile_or_web(),
  Platform.is_web(), Platform.is_touch())`. The picker (`settings_menu.gd` →
  `select_fps`) writes `Engine.max_fps` **live** (the frame cap is a global engine
  property, so no live-scene signal is needed — both the HQ and pause hosts take
  effect immediately) and the level re-derives it next load. During a benchmark
  the config-driven cap wins (`Benchmark.active` → `default_cap()`), not the player's saved setting. **`target_fps`**
  (desktop/native, default 0 = uncapped) / **`target_fps_mobile`** (native mobile, default 0) /
  **`target_fps_web`** (web, default 0 — all three uncapped since 2026-11-23) remain the *default* source: the web cap
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
  `audio/driver/output_latency.web` (50 ms since the export went threaded) in `project.godot`. Raise those before
  lowering the web cap further; the tradeoff is added throttle→sound latency. The
  native Android APK has a real audio thread and runs fine at 60. `0` = uncapped.
  Physics stays at the project physics tick. See [engine-audio.md](engine-audio.md).
- **Mipmaps**: every texture in `textures/` has mipmaps enabled (see
  [asset-pipeline.md](asset-pipeline.md) → "Texture import settings"), so distant trees
  don't thrash the texture cache. `filter_nearest` is kept (PS1 look) — mipmapping is
  independent of the magnification filter.

### Shared render distance

Every roadside prop culls at **one shared distance** — `cfg.tree_render_distance_m`
(fade `tree_render_fade_m`) — so foliage, spectators, signs and the start/finish
arches all pop in at the same range instead of each system choosing its own (or
drawing across the whole stage).

The mechanism is a `GeometryInstance3D`
`visibility_range_end` + `visibility_range_end_margin` (fade mode `SELF`, so the
cull dithers rather than pops):

- **Spectators** set it on the group `MultiMeshInstance3D` (anchored at the crowd
  centroid so the single test measures camera→crowd distance) — see
  [spectators.md](spectators.md).

Non-foliage props go through `MeshUtil.apply_visibility_range(root, end_m, fade_m)`,
which walks a subtree and sets the fields on every `GeometryInstance3D`
(MeshInstance3D / MultiMeshInstance3D / Label3D); `end_m <= 0` leaves the subtree
uncapped (flat test fixtures). The distance reaches spectators/signs via their
`GameConfig` param dicts (`render_distance_m` / `render_fade_m`). Because it's one
field, changing `tree_render_distance_m` scales every prop's cull together.

Rendering **setup** (environment, mesh shader materials, post-process shader,
shader sources) is covered by `test_render_smoke.gd` — see
[testing.md](testing.md). There is no pixel-diff golden test: it only worked
windowed and was chronically flaky, so the actual rendered look is not asserted
pixel-for-pixel. Eyeball intentional look changes in the running app.

> **The speed-lines rect is hidden below `VISIBLE_EPSILON`.** It used to stay `visible`
> whenever `speed_lines_enabled`, so below `speed_lines_start_kmh` the shader still
> rasterised the whole screen (an `atan` plus three `sin`-based hashes) to blend a
> fully transparent result. `speed_lines.gd::_apply_intensity` now toggles visibility and
> skips the `set_shader_parameter` when the value hasn't changed.


## Snow on the ground

The level's snow lift is in `level_ground.gdshader` itself (`snow_depth_m`, with the
snowiness in `UV`); see [snow-region.md](snow-region.md).

## Level view ambient occlusion

The level view fakes AO (ground map plus darker object bases); see [level-ao.md](level-ao.md).


### `world_light` (the level's brightness)

`world_light` (vec3 global shader uniform, default 1, declared in `headlight_cone.gdshaderinc`) scales every lit world shader's light term: `COLOR.rgb * world_light + hl_color * headlight_lit(...)`. `LevelWeather` tweens it during a weather fade and writes nothing otherwise, so night darkens smoothly with no terrain re-bake. A new 3D world shader must reference it (or sit in `WORLD_LIGHT_EXEMPT` in `test_lighting_coverage.gd`).
