# Level editor

A hand-built patch of world, edited in a browser lab and driven in the game. Temporary dev tooling
beside free roam, not part of it.

**Source:** `tools/level_editor_lab.html`, `scripts/level_view.gd` (`LevelView`), `level_view.tscn`,
`scripts/scenes.gd` (`change_to`'s redirect), `scripts/settings_menu.gd` (`_toggle_dev_level`)

**Tests:** `tests/headless/test_level_view.gd`

## The lab

`tools/level_editor_lab.html` is a standalone page: a 2D top-down editor of a 600 m square beside a
live three.js render of it. Serve the repo over http (`python3 -m http.server`) so it can load the
game's textures; `?level=levels/<name>.json` opens a save.

- **Terrain:** seeded noise, or a real height grid (`heightmap`) carried in the save. Near the road the
  ground is pulled to the road's own level, smoothed along it, and stays flat for `GameConfig.level_road_flat_margin` (1 m) past the road edge, then blends back to the LiDAR height over 1 m. The lab rebuilds the ground on a 1.5 m grid (`G`), the same as the game, so that blend shows.
- **Road:** one Hermite spline through nodes, each with a half-width and an optional hand-set
  tangent scaled by a tension.
- **Trees:** the game's 6-card star atlases ([trees.md](trees.md)) or the lab's own in `tools/levels/trees/`.
- **Baked visibility** (`bake`, `bakedSight`): **Bake visibility** renders the level from viewpoints every
  4 road samples (~8 m): road centre and both verges (`BAKE_SIDE` m past the edge), at bonnet and chase-camera
  heights, 4 × 90° views at 512 px. Each tree is drawn in its own ID colour through its real atlas alpha
  (alpha test 0.5), the terrain in black, and a tree covering at least `BAKE_MIN_PX` pixels of one view is visible. The result is
  `level.visibility = { key, every, rows }` (one sorted tree-index list per viewpoint row), saved with the
  level. At runtime the road point nearest the view centre picks a segment, and the trees in the rows either
  side of it are shown (hidden ones faded in 2D). `key`
  fingerprints trees, road, seed and relief (`bakeKey`); after any edit the bake is ignored and every tree
  shows until it's baked again. Needs the page served over http (real cut-outs). The 3D view culls the same set
  (`cull3DTrees` zeroes hidden instances' matrices). A save drops a bake that no longer matches
  (`pack`), so a reader can trust any bake it finds.
- **WASD** (`walk`) moves the view centre, the sight-line eye and the 3D camera's target, relative to the
  3D camera's facing (40 m/s, 400 with shift), kept inside the square.
- **Ground cover** (`level.cover`, `level.coverTypes`): a 1 m grid of type ids over the square, `SIZE * SIZE`
  bytes, row 0 = north edge (z = -SIZE/2), col 0 = west edge, 0 = none. `coverTypes` is `[{id, name, col}]`
  (defaults 1 verge grass, 2 molinia, 3 heather, 4 bilberry/scrub). The **Ground cover** tool (toolbar select, or
  `c`) paints a round brush (`[` `]` size, `e` paint/erase, shift-drag erases, `1`-`4` pick the type, right-drag
  pans); **Cover overlay** tints the 2D map; **Import cover mask** loads a greyscale PNG where pixel value = type id
  (`tools/geo/cover_mask.py` writes `tools/geo/data/<name>/cover_index.png`), stretched to the square.
  Cover is not part of `bakeKey`. The 3D view draws it as opaque tufts (`rebuild3DCover`): one InstancedMesh per
  (type, preset) in `COVER_RENDER` (tufts per m² each), positions from `hash2(cell, layer, k)` seated on
  `heightAt`, only within `COVER_REACH` of the 3D target, each hidden past its own cut-off within `COVER_FADE` in the shader, and
  regenerated when the cover or terrain changes or the target moves 10 m. The tuft geometry and presets come from
  `tools/groundcover_tufts.js`, shared with the Ground Cover Lab ([trees.md](trees.md)).
- **Saves** are packed: trees as `[x, z, rot, sx, sy, kind index]` rows with a `kinds` list, the height
  grid and the cover as base64 (int16 decimetres / bytes). A save with no cover loads as all zero, and an empty
  cover is left out of the save.

`tools/levels/hafren_forest.json` is a 600 m square of Hafren Forest (Wales): Welsh Government LiDAR
ground heights, an OSM forestry track, and trees at LiDAR canopy peaks with species picked from canopy
height and satellite colour.

## In the game

With **Settings → Dev → "Level instead of free roam"** on (or `GameConfig.dev_level_instead_of_free_roam`),
`Scenes.change_to` sends the title's world entry to `level_view.tscn` instead of free roam. Flipping the toggle from inside
either world (pause → Settings → Dev) saves and swaps to the other world at once (`SettingsMenu._toggle_dev_level`). That scene is
free roam's car, cameras, HUD and pause menu around one `LevelView` node, which reads
`GameConfig.dev_level_path` and:

- rebuilds the lab's terrain and road (the same spline and blend) on a 1.5 m grid, the road painted as gravel by
  `shaders/level_ground.gdshader` per pixel from each vertex's place on the road (`_road_frame`; see "Gravel road" below),
  so the edge is a smooth line rather than the 1.5 m triangles; trimesh collision;
- if the save has a bake, draws only the trees it lists for the two viewpoint rows either side of the
  road point nearest the camera (`show_from`, re-run when that row changes): each species' visible
  instances are packed to the front of its MultiMesh and `visible_instance_count` cuts off the rest;
- answers `height_at` / `surface_at`, so the car seats itself and the tyres read road grip from it;
- draws each species as one MultiMesh of `Foliage._alpha_card_mesh` stars, in `shaders/level_tree.gdshader`
  (unshaded, alpha scissor, nearest filter, `KIND_TINT`) which sways with the same `wind_sway.gdshaderinc` globals as free roam's trees;
- adds free roam's driving effects once the car is ready (`_add_effects`): wheel particles and dust puffs in the `home` region's
  colours, engine smoke, tyre marks (reset by the pause menu's reset), exhaust flames, car lamps, and the night headlight cone
  pushed each frame; `GameConfig.dev_level_weather` (a `WeatherLibrary` id) sets `cfg.weather`, the wind and the weather particles on
  the chase camera (`apply_weather`; no road tint or environment look). `_warm_up` compiles the effects' and every weather's
  shaders with the car locked, then `WorldRuntime.look_around` (free roam's spin round the spawn) draws the car, ground, trees and near and far ground cover once. Leaving the scene resets the headlight cone, wind and weather;
- gives every tree a box hitbox (`ObstacleBody.build`, shape index = tree index) and answers the car's
  `size_factor` / `knock_down` like a `BillboardField`: a tree's size is its height over
  `GameConfig.level_tree_full_height_m`, and a felled tree's card topples (`_step_falls`) by rewriting its
  transform in the species' full buffer, so the baked-visibility repack keeps it fallen;
- parks the car on the road's first node, facing the second; the pause menu's reset puts it back there.
- puts the car back on the road with free roam's `RoadRecovery` (R, the pause menu's reset, stuck or fallen through, which
  includes driving off the square's edge), answering its `road_pose` with the nearest road point (`LevelView.road_pose`);
- loads behind a `LoadingScreen` (`Scenes.change_to` covers `LEVEL_VIEW` too, without the cold-open story) until the shader
  warm-up ends, then applies the player's frame cap (`FpsSetting.resolve`) and arms the pause menu

The toggle is not saved: it resets to the `GameConfig` default on the next boot. Level files and
atlases load from `res://tools/`, so this works in the editor, not in an exported build.
`tools/level_view_capture.tscn` photographs the scene for checking.

### In the game: ground cover

The save's `cover` (base64, one byte per 1 m cell, row 0 = north edge) and `coverKinds` (type id to
`[[full tuft recipe, tufts per m²], ...]`, written by the lab's `pack` from `COVER_RENDER` + `PRESETS`, so the
game carries no preset copy) feed `scripts/ground_cover.gd` (`GroundCover`, built by `LevelView._build_cover`):

- `build_tuft` ports the lab's `buildTuft` to an ArrayMesh (vertex colours, up normals);
- `placements` mirrors `rebuild3DCover`: per cell within `ground_cover_reach` a hash decides the tufts of each
  layer, seated on `height_at`. `GroundCover.build` places the whole square once at load (about 150k tufts on Hafren)
  and bins them into `TILE` (32 m) squares, one MultiMesh per (tile, layer), each with `visibility_range_end` at
  `ground_cover_reach` (far bushes: `ground_cover_far_reach`) plus half a tile, so driving regenerates nothing;
  `update_centre` only moves the shaders' fade centre;
- bush layers also slow the car: `GroundCover.bush_spots` lists every bush's XZ over the whole square (the same spots
  `placements` draws) and `LevelView._add_bush_fields` gives each bush layer a `BushField`, as free roam's bushes have, its hit
  radius the layer's `bushRadius` × `bush_hit_radius_frac`;
- the tuft shader (opaque, both sides lit) hides each instance outright (no shrinking) at its own hash-picked distance between
  `ground_cover_fade_start` and `_end`, so tufts thin out one by one rather than all at once;
- bush layers (preset shape `bush`) also get a far version (`build_far_bush`: the same bush builder with a 6 x 2 core and a quarter
  of the leaves at twice the size, so it keeps the near bush's colours and outline) from the same `placements` pass (`far_out`, out to `ground_cover_far_reach`, same transforms).
  The far shader (`is_far`) uses the near tuft's own hash cut-off: the dome appears exactly when the near bush is
  hidden, then disappears at its own cut-off between `ground_cover_far_fade_start` and `_end`
  (`GroundCover.far_scale`). Grass layers get no far version. Not mirrored in the lab's 3D view;
- beyond that range the ground shows the cover: `LevelView._build_ground` multiplies its baked vertex light
  (`COLOR.rgb`, which `level_ground.gdshader` already multiplies into the surface) by `GroundCover.ground_multiplier`,
  each type's colour being the density-weighted average of its layers' tuft colours (`GroundCover.tints`), with
  hash-jittered cell edges. The lab mirrors this in `paintCoverTint` and its `tuftMaterial` cut-off.

### In the game: look

The level view is graded to read as a daytime photo, not the free-roam overcast: its own `Environment` in
`level_view.tscn` (a seamless noise-cloud `PanoramaSkyMaterial` ramped blue to white, `fog_light_color` pale blue,
`fog_sky_affect` 0);
`LevelView._build_ground` multiplies the grass vertex colour by `(0.95, 1.25, 0.72)`, fading out over the few metres around the road's edge, to push the ground
lime; `KIND_TINT` in `level_view.gd` tints each Welsh species (spruce near-black green, broadleaves yellow-green).
Global grade values in `GameConfig`: `grade_saturation` 0.85, `grade_contrast` 1.1, neutral `grade_shadow_tint` / `grade_highlight_tint`,
`fog_density` 0.0025. `tools/level_view_capture.gd` takes `CAP_POSES="x,z,tx,tz,name;..."` (+ `CAP_EYE`, `CAP_FOV`,
`CAP_OUT`) for eye-height photo-match renders.

The lab's 3D view copies this look so it matches the game: unshaded ground with the same baked sun light
(`lightAt`) and grass multiplier, `KIND_TINT` as each tree kind's `tint`, the sky's mid
colour behind, Godot-style `exp(-density·d)` fog in `fog_light_color`, and a CSS saturate/contrast for the grade.
It skips the grade's warm tints, vignette and dither. When the game's look changes, update both.

### Gravel road

The road is a gravel forestry track, drawn the same way in the game (`shaders/level_ground.gdshader` → `gravel`) and the
lab (`GRAVEL_GLSL`, a verbatim copy patched into the road's `MeshBasicMaterial`; keep the two in step):

- **Stones** are baked, not computed: `textures/gravel-forest.png` (`node tools/bake_gravel.js`) is a seamless 256 px tile over
  6.4 m (2.5 cm texels, nearest filtered with mipmaps, so distance doesn't shimmer). RGB is the stone colour; alpha is each
  stone's rank. A stone shows only where the road's looseness exceeds its rank, so one tile serves both the bare ruts and the
  stony crown; big stones have high ranks and appear only on loose ground. Gaps (rank 1) show the shader's dust colour.
- **Road-shaped masks** are a few value-noise lookups per pixel: two wheel ruts about 0.8 m either side of the centre that
  wander along the road, swept mostly clean, with tyre-polished streaks and damp patches; moss on the crown and verges; a
  ragged edge up to 0.45 m inside the half-width (`gravel_edge`).
- **Inputs:** world xz, signed metres across, half-width, metres along. The game's ground vertices carry them as `UV` = (signed
  across, |across| − one grid step) and `UV2` = (half-width, along), from `LevelView._road_frame`; the shader takes
  max(|UV.x|, UV.y) so the sign flip between vertices inside a bend (far off the road) can't fake a road there. The lab's
  road mesh carries `rd` = (across, along, half-width) and discards past the edge instead of blending into grass.
- The lab decodes the tile to linear light (its one line that differs from the game) and gamma-encodes the result, as Godot does, so the colours match.
