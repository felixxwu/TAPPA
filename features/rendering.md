# Rendering & PS1 Look

The game targets a PlayStation-1 aesthetic: low internal resolution, unshaded
flat colors, nearest-neighbor textures, color quantization + dithering, and fog.

## Display / renderer (`project.godot`)

- Internal viewport: **480×360**, window **1280×960** (upscaled). Lower than
  the old 640×480 — fewer fragments to shade (the full-screen post-process runs
  per internal pixel), and closer to the PS1's ~320×240.
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
stays the design height (360, so vertical is never distorted) while the logical
width is shrunk by the stretch factor, forcing the window to scale it back out
horizontally by exactly that factor. Because the width is derived from
`360 / stretch` and not the raw window width, the stretch stays constant on any
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
alongside `terrain_light_amount` for the baked terrain shading.

Used by: car chassis/cabin/wheels, and the authored body models (MX-5, Focus, Twingo)
(see below).

### `ps1_post_process.gdshader` — `canvas_item` (full-screen)
Applied as the material of the `PostProcess` **SubViewportContainer**
(`scripts/post_process_view.gd`). The 3D world stays in the main tree but is
rendered through `PostProcess/View`, a `SubViewport` that shares the main
`World3D` (`own_world_3d = false`) and carries a `ViewCamera` mirror camera
synced every frame to the active gameplay camera; the root viewport's own 3D
pass is disabled while the stage scene is in the tree (restored on exit, so the
HQ renders normally). The shader samples the container's `TEXTURE` (the
subviewport frame) directly — deliberately NOT `hint_screen_texture`, which
would force a full-screen backbuffer copy (render-pass break + mid-frame GPU
submit) every frame on the Compatibility backend. Uniform: `virtual_resolution`
(set from `cfg.virtual_resolution`, [480,360], by `world.gd`).

Algorithm: sample frame → quantize to virtual resolution → apply a 4×4 ordered
(Bayer) dither matrix → truncate to 5-bit RGB (32 levels/channel) → output.
The dither applies to the 3D world only: SpeedLines / HUD / menus live on
CanvasLayers drawn above the container.

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
(`speed_lines_response`) so the streaks fade in/out rather than pop. `world.gd`'s
`cycle_car()` re-points the overlay at the swapped car, like the HUD. All tunables
live in `GameConfig` under the **Speed Lines** group.

## Authored body models (MX-5, Focus, Twingo, Acty, Charger, The Beast)

Cars with `use_model` on their CarLibrary spec render an authored glb body
instead of the procedural chassis+cabin boxes; every other car still uses the
boxes. Eight cars carry a model today: the **MX-5**
(`blender/mx5/mx5.glb`, node `Car/Mx5Body`), the **Focus**
(`blender/focus/focus.glb`, node `Car/FocusBody`), the **Renault Twingo**
(`blender/twingo/twingo.glb`, node `Car/TwingoBody`), the **Honda Acty**
(`blender/acty/acty.glb`, node `Car/ActyBody`), the **Charger R/T**
(`blender/charger/charger.glb`, node `Car/ChargerBody`), **The Beast**
(`blender/thebeast/mrbeast.glb`, node `Car/TheBeastBody`), the **911 Turbo**
(`blender/911/911.glb`, node `Car/Porsche911Body`) and the **Jaguar XJS**
(`blender/xjs/xjs.glb`, node `Car/XjsBody`). All are
instanced in `car.tscn`, hidden by default.

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
| PostProcess (SubViewportContainer) | `virtual_resolution` | `virtual_resolution` [480,360] |

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
  collision-free backdrop of static `250 m` tiles sampling the same
  `height_at`/`light_at` as the real terrain, covering the whole precomputed
  corridor (`TerrainManager.corridor_bounds()`) plus a margin so the reduced
  fog reveals a horizon instead of the ring's hard edge. Built **once**, behind
  the loading screen, in `world._generate_track()` — the play area is bounded
  (off-track reset leash), so it never re-centres or rebuilds at runtime (see
  [terrain.md](terrain.md)). Tunables in `GameConfig` (`distant_terrain_*`).
- **Fog** demoted from edge-hider to thin aerial haze now that the backdrop hides
  the edge: `fog_density` (0.005), `fog_sky_affect` (0.15, so the sky reads above
  the haze), `fog_light_color = background_color` — and `background_color`
  (0.589, 0.544, 0.520) is **matched to the skybox's horizon** so the distant
  terrain dissolves into the sky seam. All applied in `world._ready()` from config.
- No bloom, no shadows.

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
  Residual spikes are gameplay-only draw variants (e.g. a knocked spectant's
  single-instance ragdoll mesh) that a static camera can't reproduce; these are
  web-only (the native APK keeps a persistent shader cache) and need on-device GL
  tooling (chrome://inspect) to pin further.

## Performance defaults (inherently low-end)

The game ships one lean pipeline for every device (no quality tiers). Relevant
shipped knobs in `GameConfig`:
- **`target_fps`** (desktop, default 60) / **`target_fps_mobile`** (native mobile,
  default 60) / **`target_fps_web`** (web, default 30) — a render frame cap applied
  in `world._ready()` (skipped under `--headless`, so it never throttles the test
  runner), selected via `GameConfig.target_fps_for(Platform.is_mobile_or_web(),
  Platform.is_web())` (web wins over the mobile branch since both are true on web).
  Web is capped lower than native for thermal/battery headroom, but the floor is set
  by **audio**: on the **single-threaded web build** audio is serviced by the main
  loop (no audio thread), so a lower frame rate drains the generator + WebAudio
  output buffers between frames and produces gaps/crackle. 30 fps on web is viable
  only because the audio buffers are sized to bridge a ~33 ms inter-frame gap plus
  jitter — the engine generator `BUFFER_SECONDS` (0.2 s) in `engine_audio.gd` and
  `audio/driver/output_latency.web` (200 ms) in `project.godot`. Raise those before
  lowering the web cap further; the tradeoff is added throttle→sound latency. The
  native Android APK has a real audio thread and runs fine at 60. `0` = uncapped.
  Physics stays at the project physics tick. See [engine-audio.md](engine-audio.md).
- **`texture_lod_bias`** (default 0.75) — biases distant foliage sampling toward
  cheaper mip levels (a `lod_bias` uniform in `shaders/billboard.gdshader`, set
  from `BillboardField.build()`). The tree/bush textures now have **mipmaps
  enabled** (`textures/tree.png.import`, `textures/tree-greece.webp.import`), so distant
  billboards no longer thrash the texture cache. `filter_nearest` is kept (PS1
  look) — mipmapping is independent of the magnification filter.

### Shared render distance

Every roadside prop culls at **one shared distance** — `cfg.tree_render_distance_m`
(fade `tree_render_fade_m`) — so foliage, spectators, signs and the start/finish
arches all pop in at the same range instead of each system choosing its own (or
drawing across the whole stage). The mechanism is a `GeometryInstance3D`
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
