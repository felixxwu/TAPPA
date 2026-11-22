# Level editor

A hand-built patch of world, edited in a browser lab and driven in the game. Temporary dev tooling
beside free roam, not part of it.

**Source:** `tools/level_editor_lab.html`, `scripts/level_view.gd` (`LevelView`), `level_view.tscn`,
`scripts/level_map.gd` (`LevelMap`), `scripts/scenes.gd` (`change_to`'s redirect), `scripts/settings_menu.gd` (`_toggle_dev_level`)

**Tests:** `tests/headless/test_level_view.gd`, `tests/headless/test_export_presets.gd`, `tests/headless/test_level_trees.gd`, `tests/headless/test_level_data.gd`, `tests/headless/test_level_bake.gd`, `tests/headless/lab_parity.js`, `tests/headless/lab_history.js`

## The lab

`tools/level_editor_lab.html` is a standalone page: a 2D top-down editor of a square (600 m by default) beside a
live three.js render of it. Serve the repo over http (`python3 -m http.server`) so it can load the
game's textures; `?level=levels/<name>.json` opens a save. `tools/open_level_editor.sh` does both for the Hafren level.

- **Undo / redo:** toolbar buttons, Ctrl/⌘ Z and Ctrl/⌘ Shift Z (or Ctrl Y). Every `save()` (the end of each edit) pushes a copy of `level` (`snapshot`); `stepHistory` restores one through `loaded()` with `restoring` set, which skips the history reset and the big-level shading rebuild. The cover grid is copied only when `coverEdited` (set by `paintCover` / `coverRebuild`); the height grid is shared. 100 steps; loading, Reset and Random start a fresh history.
- **Biome:** the save's `biomeRle` (run-length encoded like `coverRle`), one id per `BIOME_CELL` (10 m) square, row 0 = north: 0 Forest, 1 Snow (`BIOMES` in the lab). A save without one gets it filled from the saved ground height (`biomeFromHeight`, snow above the "Snow above" value, default 90 m). The **Biome** tool paints it with a round brush (Shift paints Forest); "Fill from height" refills the whole grid. The 3D view shades it like the game: `setSnowTex` uploads the grid as a linearly filtered texture, the ground mixes in `snow-ground.jpg` lit by the sun alone (the `lt` attribute), and the road is lightened by `SNOW_ROAD_LIGHTEN` with its moss turned to snow. 2D only in the lab (legend layer "Biome"). In the game, `LevelStreamer.snow_at` reads it (blended between cell centres) and the level view draws snow ground that sinks the car and bogs it down (see [snow-region.md](snow-region.md), "The level view's snow biome"). Hafren's snow-biome trees were swapped once, in the save itself, to the snow species (`levels/trees/snow_laden_spruce.png`, `dusted_spruce.png`, `snowy_young_spruce.png`, `snow_bowed_birch.png`, rendered from the tree lab's snow presets), keeping each tree's real height; nothing switches species at runtime.
- **Spectators:** the save's top-level `spectators: [{x, z, r, n}]` (origin and radius in metres, same x east / z south frame as `logPiles`; people count `n`; omitted when empty, kept in the autosave, not part of `bakeKey`). The **Spectators** tool (toolbar, or `P`) adds a group on a click of empty ground (r 8, n 10); drag a group to move it, drag the rim handle, scroll or `[` `]` to change `r`, the pop-up edits `r` and `n`, Delete removes it. 2D draws each as a circle with its count (legend layer "Spectators"). 3D (`rebuild3DSpectators`) scatters `n` seeded people per group inside `r` on `heightAt`, each facing the nearest road point, built with `tools/spectators.js` into one merged mesh; only groups in the ground window are built.
- **Teleports:** the save's top-level `teleports: [{x, z}]` (omitted when empty, not part of `bakeKey`), the only places the in-game map teleports to, one per cluster of buildings (Hafren's 24 were placed once on the road nearest each cluster's centre, buildings within 100 m sharing one). The **Teleport** tool (toolbar, or `T`) adds one on a click; in any tool a cyan diamond can be dragged to move it, Delete removes it (legend layer "Teleports"). 2D only.
- **Size:** a save's `size` (metres, square centred on the origin; missing = 600, and a save of 600 omits it) sets `SIZE`; the
  height grid is `N` cells a side (read from the heightmap's length, ~3 m; `make_level.py` uses `round(size / 3)`), the cover grid
  is `size * size` bytes. Up to `WIN_M` (600) everything is as described below. Above it (`big()`, e.g. `tools/levels/hafren_5km.json`,
  5 km, ~185k trees, from `make_level.py <name> --size 5000` then `pack_level.js`; OSM there has no width tags, so
  `make_level.py` → `half_width` guesses each road's half-width from its `highway` class and `tracktype` grade):
  - 2D: the map shades the saved height grid once into one offscreen image (`buildBigShade`, contours every 10 m on every third cell,
    only drawn at zoom 0.4 and up); roads and road nodes are culled to the viewport, and zoomed out below 0.5 the roads are one
    constant-width stroke (`roadPath`); trees are bucketed into 50 m squares (`treesInView`) and drawn as an evenly thinned set of
    dots when more than `TREE_DRAW_MAX` are on screen. Loading fits the whole square; the zoom floor follows it.
  - 3D: the ground, road ribbons and trees exist only in a `WIN_M` window (`T`, `placeWindow`) around the view centre, rebuilt when
    the centre moves `WIN_MOVE` (100 m) from the window's centre; nothing is drawn outside it. `heightAt` falls back to the saved
    ground outside the window. The grass texture is offset so it stays put in the world as the window moves.
  - Junctions: the shader reads the window's junctions (nearest `JUNC_MAX`, with a status-line note if any are cut) from a float
    data texture (`setJuncTex`, `uJT` / `uJN`), not a fixed array.
  - Off: the localStorage autosave is skipped. Ground cover works at any size.
- **Terrain:** seeded noise, or a real height grid (`heightmap`) carried in the save. Near the road the
  ground is pulled to the road's own level, smoothed along it, and stays flat for `GameConfig.level_road_flat_margin` (2 m) past the road edge, then blends back to the LiDAR height over `FALLOFF` (1 m). The lab rebuilds the ground on a 1.5 m grid (`G`), the same as the game, so that blend shows.
- **Road network:** `level.roads` is an array of chains, each a Hermite spline through nodes with a
  half-width and an optional hand-set tangent scaled by a tension (a legacy single `road` loads as one chain;
  saves write `roads` only). `roadSamples` concatenates the chains' samples in chain order; a chain's first
  sample has `first: true` and segments never span it (`nearestRoad`, terrain, drawing skip them).
  Junctions are derived, never stored (`junctions`): chain ends within 0.75 m of each other or of another
  chain's node, centre = mean, half-width = widest member. Road height is smoothed per chain, then eased to the
  junction's level over `JUNC_BLEND_M` (25 m); that level is the mean of each member chain's smoothed height at its
  sample nearest the centre (`LevelData._junction_levels`), so a road ending on a slope meets the others halfway
  instead of dropping to the bare ground in a few metres. In 3D each junction's weight (1 − smoothstep(1.5·w, 3·w, d))
  is computed per pixel (`junc_at`, `uJ`) and passed as the fifth argument of `gravel`; roads overlapping at a
  junction are separate ribbons lifted 1 cm apart, with the per-pixel edge discard making the union. In 2D a junction
  is an orange disc. The bake rows use the concatenated sample index.
  Editing: the toolbar's Tool select decides what a click on empty ground does: **Pan** (the default) only pans and selects, **Trees** adds a tree of the "New tree" species, **Roads** extends the selected road
  end (or starts a road if none is selected). Click a node to select, drag it to move; clicking the selected node again selects the next node within reach of the pointer (`nodesNear`), so nodes stacked under it (a junction's road ends) can be reached; **n** then click starts a road; double-click a road inserts a node; **x** splits the road at the selected
  node; Delete removes a node, shift+Delete the whole road. Dragging or placing a road end within 12 px of another
  road's node snaps onto it, forming a junction. `tools/geo/pack_level.js` clears trees and cover off every road (segments bucketed, so it copes with ~200k trees).
  A selected node's **Clear trees off road** button (`clearRoad`) does the same for that node's whole road, with the
  same margins (cover within 0.5 m of the edge; a tree goes when its trunk is within 0.5 m plus its kind's `low` x its scale,
  where `low` in the lab's `KINDS` is how far that species' leaves spread in its lowest 3 m, so wide-skirted spruces stay
  well back while sparse broadleaves can stand at the edge). Re-measure `low` with `tools/tree_low_reach.py` after
  re-exporting an atlas. Re-running `pack_level.js` on a packed save (`node pack_level.js ../level_editor_lab.html ../levels/<name>.json`,
  from `tools/geo`) re-clears it in place; it only removes trees, so a looser margin never brings trees back. A lab download
  keeps cover and heights as `coverWebp` / `heightWebp`, which node can't decode, so the script round-trips them through libwebp's `dwebp` / `cwebp` (`brew install webp`).
  It also clears trees (same per-kind margin) and cover off every building's footprint, and levels a pad under each building on a slope,
  since the game seats a building on the lowest ground under it: buildings whose pads would overlap share one, ground on and beside a
  road keeps its height, and a pad that would leave any building on rougher ground is dropped. Re-running it changes nothing.
- **Trees:** the game's 6-card star atlases ([trees.md](trees.md)) or the lab's own in `tools/levels/trees/`.
- **Visibility** is no longer baked in the lab: `tools/bake_level.gd` renders it into the game's bake (see "Tree tiles" below). The lab shows every tree.
- **WASD** (`walk`) moves the view centre, the sight-line eye and the 3D camera's target, relative to the
  3D camera's facing (40 m/s, 400 with shift), kept inside the square.
- **Map legend** (top-right of the 2D view, `LAYERS` / `show` in `draw2D`): checkboxes hide trees, buildings,
  log piles (`level.logPiles`, drawn as their real footprint — `pileFootprints` mirrors `level_view.gd` → `_log_pile`), roads, ground cover and contours. Hidden trees and roads
  can't be clicked or selected. 2D map only; the 3D view always shows everything.
  The 3D view draws log piles too (`rebuild3DLogPiles`: one InstancedMesh of cylinders stacked like
  `log_pile.gd` → `_stack`, minus its random jitter).
- **Ground cover** (`level.cover`, `level.coverTypes`): a 1 m grid of type ids over the square, `SIZE * SIZE`
  bytes, row 0 = north edge (z = -SIZE/2), col 0 = west edge, 0 = none. `coverTypes` is `[{id, name, col}]`
  (defaults 1 verge grass, 2 molinia, 3 heather, 4 bilberry/scrub). The **Ground cover** tool (toolbar select, or
  `c`) paints a round brush (`[` `]` size, `e` paint/erase, shift-drag erases, `1`-`4` pick the type, right-drag
  pans); the **Ground cover** box in the map legend tints the 2D map; **Import cover mask** loads a greyscale PNG where pixel value = type id
  (`tools/geo/cover_mask.py` writes `tools/geo/data/<name>/cover_index.png`), stretched to the square.
  Cover is not part of `bakeKey`. The 3D view draws it as opaque tufts (`rebuild3DCover`): one InstancedMesh per
  (type, preset) in `COVER_RENDER` (tufts per m² each), positions from `hash2(cell, layer, k)` seated on
  `heightAt`, only within `COVER_REACH` of the 3D target, each hidden past its own cut-off within `COVER_FADE` in the shader, and
  regenerated when the cover or terrain changes or the target moves 10 m. The tuft geometry and presets come from
  `tools/groundcover_tufts.js`, shared with the Ground Cover Lab ([trees.md](trees.md)).
- **Buildings**: `level.buildings` (read-only in the editor for now) are drawn as footprints on the 2D map and as `tools/buildings.js` meshes in 3D (`rebuild3DBuildings`, one shared atlas, unshaded with baked sun); see [buildings.md](buildings.md).
- **Saves** are packed: trees as `treesBin` (base64, 7 bytes per tree, little-endian: x and z uint16 of `round((v + size/2) * 10)` clamped, rot uint8 of 256 per turn, scale uint8 hundredths (sx == sy), kind uint8 index into `kinds`; `packTrees`/`unpackTrees` in the lab, `LevelData.unpack` in the game; the legacy `[x, z, rot, sx, sy, kind index]` rows still load; `bakeKey` mixes rot in 1/256 turns so a bake survives the quantisation), the height
  grid and the cover as base64 (int16 decimetres / bytes). A save with no cover loads as all zero, and an empty
  cover is left out of the save. Cover is saved run-length encoded as `coverRle` (base64 of `(type byte, run length varint)` pairs, row-major; `rleEncode`/`rleDecode` in the lab, `GroundCover.decode_cover` in the game, which needs the save's `size`); the legacy raw `cover` still loads. `tools/geo/webp_pack.py` (last step of the geo pipeline, after `pack_level.js`) rewrites a packed save to `heightWebp` (lossless WebP, (N+1)², int16 decimetres + 32768 as R = high byte, G = low byte) and `coverWebp` (lossless WebP, `size`², R = type id, row 0 = north); `LevelData.unpack` and `GroundCover.decode_cover` read both these and the legacy keys, and the lab reads them async (`unpackAsync`) on file load and `?level=`. The lab's **Save .json** writes the WebP keys too (`packForDownload`: canvas `toBlob("image/webp", 1)`, which Chrome encodes losslessly; each image is decoded back and the legacy key kept if any value differs), so a download can go straight into `tools/levels/`. Its localStorage autosave stays in the legacy formats. The 2D overlay is one cached `size x size` offscreen canvas (`coverOverlay`), repainted per brushed rectangle (`coverPaintRect`), so painting stays cheap at 5 km.

`tools/levels/hafren_5km.json` is a 5 km square of Hafren Forest (Wales): Welsh Government LiDAR
ground heights, OSM roads, and trees at LiDAR canopy peaks with species picked from canopy
height and satellite colour.

## In the game

**Map (M, the pad's Back button, or the pause menu's first row, Map):** `LevelMap`, added by `LevelView` once loaded, pauses the game (`toggle`; from the pause menu `open_over_pause`, where closing emits `closed` and `LevelView._on_map_closed` hands back to the menu, or after a teleport re-arms it and drives on). A top-right **< Back** button (`back_button`, the touch screen's way out; `_input` leaves clicks on it to the button) closes it like M / Esc. It shows the bake's road
samples as polylines (orange gravel, grey tarmac, split where `st` crosses 0.5), roads and buildings (`LevelMap.footprint`) at true size, log piles drawn on top
at no less than `MIN_MARK_PX` so they show zoomed out, over a `IMAGE_PX`² image of tree dots on ground faintly tinted by the cover
grid (`_cover_image`: sampled at `COVER_PX`², each type's tuft colour mixed in by `COVER_TINT`) (painted on a background thread (`_paint`) from before the ground prefill, and uploaded with its road lines traced by `build()` at the end of the shader warm-up, behind the loading screen, since the 4096² upload stalls a frame for about 30 ms; the map's input stays off until the level has loaded; not the satellite image).
Drag / WASD / arrows / left stick pan, wheel / +- / LB RB zoom; click (or Enter / A on the centre crosshair) teleports to the nearest of the save's
teleport points (`nearest_teleport`, drawn as yellow diamonds, the car as a white arrow; nowhere if the save has none), onto the road beside it (`LevelView.road_pose`), facing away from the dead end when that road has one at one end only (`LevelData.away_from_dead_end`), prefilling the streamer there before unpausing so the car doesn't fall through.

**Map discovery** (`scripts/level_discovery.gd`, `LevelDiscovery`; tests `tests/headless/test_level_discovery.gd`): the map only
shows ground the player has driven near. `LevelMap` keeps a byte grid over the level (`level_map_reveal_cell_m` cells, 0 hidden,
255 shown) and every `REVEAL_TICK_S` while driving (and on opening the map) stamps a disc of `level_map_reveal_radius_m` round the car,
fading over its last `level_map_reveal_feather_m` (`reveal_at_car`, skipped until the car has moved a cell). Everything under the
roads, buildings and log piles is then covered by a fog texture, one pixel per cell (`LevelDiscovery.fog_image`, wrapped in a linear-filtered
`CanvasTexture` so its edge is soft at any zoom), in the same dark colour as the ground off the level's edge (`LevelMap.FOG`), with a faint line (`LevelMap.BORDER`) round the level's edge so the end of the world shows. On a touch screen two fingers pinch to zoom round their midpoint and pan as it moves (`LevelMap.touch`, from `InputEventScreenTouch` / `ScreenDrag`; a phone's own magnify / pan gestures are ignored while two fingers are down, and lifting them after a pinch doesn't teleport); one finger pans through the emulated mouse. Teleport points and the car are drawn over
the fog: **every teleport still works, discovered or not** (Felix, 2026-11-20: locking them to discovery comes later). The grid is saved as the
`level_map_seen` setting (`LevelDiscovery.to_save`: level path, size, cell size, the grid deflated + base64) whenever `LevelView.save_pose` runs,
if it has grown; a save from another level file, size or cell size is ignored. `tools/level_map_capture.tscn` walks the car along the road
samples and photographs the map (`user://level_map_capture_*.png`).

With **Settings → Dev → "Level instead of free roam"** on (or `GameConfig.dev_level_instead_of_free_roam`),
`Scenes.change_to` sends the title's world entry to `level_view.tscn` instead of free roam. Flipping the toggle from inside
either world (pause → Settings → Dev) saves and swaps to the other world at once (`SettingsMenu._toggle_dev_level`). That scene is
free roam's car, cameras, HUD and pause menu around one `LevelView` node, which reads
`GameConfig.dev_level_path`, fields a stock `GameConfig.dev_level_car_id` (not the world's car; the pause menu's Garage, `open_garage`, picks any catalogue car and reloads the level with it parked where the old one stood, as free roam does; the pause menu's Shop, `open_shop`, is free roam's shop with every part free and unlocked, kept on the static `LevelView.owned` across the reload that fits them; that car and its parts are also saved to the `level_car` setting (`Save.set_setting`) every time the level fields it, and `restore_saved_car` brings them back on the next launch, ignoring a car since dropped from the roster; where the car stands is saved too (the `level_pose` setting, `save_pose` every 5 s, on `Save.flushing` and on leaving the level), and `saved_pose` starts the next launch there, upright on the ground, unless it was saved on a different level file; the car takes damage as anywhere else, and the pause menu's Repair, `_on_extra`, fixes it for free via `DamageModel.repair`), and:

- rebuilds the lab's terrain and road network (the same splines and blend) on a 1.5 m grid, the road painted as gravel by
  `shaders/level_ground.gdshader` per pixel from the baked road frame textures (`LevelBake`; see "Gravel road" below),
  so the edge is a smooth line rather than the 1.5 m triangles; ground steeper than the shader's `rock_start_deg`
  (fading to all rock at `rock_full_deg`) is drawn as bare rock (`rock`), the slope read from `COLOR.a`, which
  `LevelStreamer._pack_vertex` fills with the smooth vertex normal's y; streamed by the free-roam streamer
  with the sizes in `LevelStreamer.level_settings` (48 m chunks; 1.5 / 6 / 12 m near / mid / far out to 11 chunks;
  the horizon level, one quad per chunk in 12×12-chunk blocks, out to 3 km; see [free-roam.md](free-roam.md));
  `HeightMapShape3D` collision per near tile, as in free roam;
- draws the bake's trees through `LevelTrees` (see "Tree tiles" below);
- answers `height_at` / `surface_at`, so the car seats itself and the tyres read road grip from it;
- draws trees as MultiMeshes (one per tile, all its species) of `Foliage._alpha_card_mesh` stars, in `shaders/level_tree.gdshader`
  (unshaded, alpha scissor, nearest filter, `LevelTrees.KIND_TINT`) which sways with the same `wind_sway.gdshaderinc` globals as free roam's trees;
- adds free roam's driving effects once the car is ready (`_add_effects`): wheel particles and dust puffs in the `home` region's
  colours, engine smoke, tyre marks (reset by the pause menu's reset), exhaust flames, car lamps, and the night headlight cone
  pushed each frame; `GameConfig.dev_level_weather` (a `WeatherLibrary` id) sets `cfg.weather`, the wind and the weather particles on
  the chase camera (`apply_weather`; no road tint or environment look). `_warm_up` compiles the effects' and every weather's
  shaders with the car locked, then `WorldRuntime.look_around` (free roam's spin round the spawn) draws the car, ground, trees and near and far ground cover once. Leaving the scene resets the headlight cone, wind and weather;
- parks the car on the first road's first node, facing the second; the pause menu's reset puts it back there.
- puts the car back on the road with free roam's `RoadRecovery` (R, the pause menu's reset, off the road for `off_road_reset_timeout_s` via `LevelView.is_off_road`, with a top-centre `off_road_label` countdown in free roam's prompt-box style once `off_road_warning_after_s` has passed, stuck or fallen through, which
  includes driving off the square's edge), answering its `road_pose` with the nearest road point (`LevelView.road_pose`, which asks `LevelData.road_pose`);
- loads behind a `LoadingScreen` (`Scenes.change_to` covers `LEVEL_VIEW` too, without the cold-open story) until the shader
  warm-up ends, then applies the player's frame cap (`FpsSetting.resolve`) and arms the pause menu

The toggle is not saved: it resets to the `GameConfig` default on the next boot (currently ON, so every
build boots into the Hafren level). Level files and atlases load from `res://tools/levels/`, so every
export preset must bundle that folder: each one's include filter lists `tools/levels/*.json` and
`*.bake.res`, and its exclude filter names only tools' scripts and sources, never `tools/*` (Android's
old `tools/*` exclude left the save out and hung the APK on the loading screen; `test_export_presets.gd`
guards it). A save that can't be read puts "The level file is missing from this build." on the cover
instead of spinning forever.
`tools/level_view_capture.tscn` photographs the scene for checking.

### In the game: the bake

`scripts/level_bake.gd` (`LevelBake`, a Resource) holds what is worked out once per save: final ground heights on a 1.5 m grid
(uint16 centimetres over `height_base`; `height` clamps into the square so the edge repeats outwards), the road frame as one
RGBA8 texture at 2 m texels (`frame`: across (signed, within ±16 m), half-width (0-16 m), along (modulo 64 m), junction
weight (low 4 bits) and tarmac weight (high 4 bits); 8 bits each, so 5 km is about 25 MB) and the road samples (`sx..sc`, so `surface_at` / `road_pose` / `spawn_pose`
run without `LevelData._build_road`). `LevelBake.bake(data, key)` is pure; `load_or_bake(save_path, data)` reads `<save>.bake.res`
and compares `source_key` (md5 of the save minus `coverKinds`, which isn't baked, + `BAKE_VERSION`): stale or missing bakes in process on desktop (`LevelView.load_level` puts up a "Baking the level" loading screen and runs the bake on a thread, showing `LevelBake.progress` as a percentage; warns,
saves beside the save), returns null on web and sets `last_error`; an empty path bakes in memory only. Bump `BAKE_VERSION`
when the bake's maths changes. Run `BAKE_LEVEL=res://tools/levels/<name>.json godot --headless --path . res://tools/bake_level.tscn`; for the rendered tree visibility use `tools/bake_level.sh [N]`, which runs N silent (`--audio-driver Dummy`) windows over contiguous slices of the road and merges them (decode is a sort plus `bsearch` per view, not a per-pixel loop).

**Shipping bakes.** `*.bake.res` is git-ignored. `tools/bake_level.sh` publishes its result itself by running `tools/publish_bake.sh tools/levels/<name>.json` (run that by hand after an in-process bake): it refuses a missing, stale or incomplete bake (checked by `tools/bake_key.tscn`, which prints `LevelBake.key_of`) and uploads `<name>-<key>.bake.res` to the `bakes` release. Every export job (web, Android APK, Play AAB, Windows) runs `tools/fetch_bakes.sh` before exporting, which downloads the asset matching each level's key and fails naming the publish command if it is missing. Flow: edit level, bake (which publishes), push. Every preset bundles `tools/levels` (its include filter lists `*.bake.res`); without a fetched bake a native build would bake in process on the device, minutes on a phone. The test workflow bakes in-process and needs none.
`apply_to(material)` hands the textures to `level_ground.gdshader`, which reads it nearest and blends the four texels by
hand: across is blended signed where the four values differ by about one texel gradient (so ruts near the centreline stay exact),
else |across| is blended with the nearest texel's sign (a signed blend would fake a road between two roads); along is blended circularly. The shader no longer reads vertex UV/UV2: COLOR.rgb is sun light x cover tint, COLOR.a the ground normal's y (rock on steep ground)
only (the shader is unshaded, so normals are unused), and the lime grass boost fading out near the road edge lives in the
shader. The gravel noises that take `along` (`gnp`) repeat every 64 m (1 and 8 noise cells per 64 m) in both the shader and the
lab's `GRAVEL_GLSL`.

### In the game: road network and junctions

`scripts/level_data.gd` (`LevelData`, RefCounted, no nodes) owns everything parsed from a save and every road/terrain
query: `unpack`, the road samples (`sx/sz/sw/sh/sa/sc`), `junctions`, `natural` / `ground` / `surface_at` / `road_frame` /
`nearest` / `nearest_sample` / `road_pose` / `spawn_pose`. `LevelView.load_level` builds a `LevelData` (`data`) and builds
the scene from it. The square's `size` and the height grid's side (`grid_n`) come from the save, so a non-600 save reads
its own grid. Junctions are bucketed (`_near_junctions`), so the height blend in `_build_road` and `junction_at` cost
O(samples). Lab parity: `tests/headless/fixtures/level_parity.json` holds a synthetic save and the expected road samples,
junctions and ground heights; `test_level_data.gd` checks `LevelData` against it and `node tests/headless/lab_parity.js`
checks the lab's own functions (pulled out of `level_editor_lab.html` by text, so keep `rebuildRoads` / `rebuildGrid` and
their helpers between the markers it searches for) against it; `--write` regenerates the expected values from the lab.
Each road sample eases only to its nearest junction within `JUNCTION_BLEND`, as the lab does; the fixture includes two
junctions closer than that.

The save's `roads` is an array of chains (each an array of the lab's node dicts); an older save's single `road` loads as
`[road]` (`LevelData.chains`). `LevelData._build_road` samples each chain's Hermite spline and concatenates them (`_sc` = chain
of each sample, so a segment is a sample pair with the same chain; buckets, `nearest_sample`, `road_frame` and
`nearest` only ever use such pairs). Sample indices are the concatenated ones, which is what the bake's `every` rows
count. Junctions are not saved: `LevelData._find_junctions` clusters chain ends within `JUNCTION_TOL` (0.75 m) of each other and
any end within it of another chain's node; the centre is the mean, its half-width the widest clustered node. Each chain's
height is smoothed on its own, then eased over `JUNCTION_BLEND` (25 m) to the junction's level, the mean of its chains' smoothed heights there (`_junction_levels`).
`junction_at` gives a point's junction weight, 1 - smoothstep(1.5 wj, 3 wj, d); `road_frame` returns it as `.w`, the
bake stores it in `frame`, and it eases the half-width to the junction's so the edge has no step where two roads'
frames meet. `gravel()` takes it as `junc` and fades ruts, crown, verge moss and streaks to an even pad (the lab's copy
takes it too). `tools/level_view_capture.gd` takes `CAP_LEVEL` (a level file) and a sixth pose field, how far below the eye
the camera aims, for a top-down look at a junction.

### In the game: ground cover

The save's `coverRle` (run-length encoded, see above; legacy raw base64 `cover` also read; one byte per 1 m cell, row 0 = north edge) and `coverKinds` (type id to
`[[full tuft recipe, tufts per m²], ...]`, written by the lab's `pack` from `COVER_RENDER` + `PRESETS`, so the
game carries no preset copy) feed `scripts/ground_cover.gd` (`GroundCover`, owned by `LevelStreamer.cover`):

- `build_tuft` ports the lab's `buildTuft` to an ArrayMesh (vertex colours, up normals);
- `placements` mirrors `rebuild3DCover`: per cell within `ground_cover_reach` a hash decides the tufts of each
  layer, seated on `height_at`. `GroundCover.stream` builds `TILE` (32 m) squares (`build_tile`: `placements` with its `tile` rect, one MultiMesh per layer, `visibility_range_end` at
  `ground_cover_reach` (far bushes: `ground_cover_far_reach`) plus half a tile) out to `ground_cover_far_reach`, nearest first, from the frame budget `LevelStreamer._process` has left after the ground queue, and drops tiles far behind;
  `update_centre` only moves the shaders' fade centre;
- bush layers also slow the car: `GroundCover.bush_spots` lists a tile's bush XZs (the same spots
  `placements` draws) and each tile's `build_tile` gives each bush layer a `BushField` (freed with the tile), as free roam's bushes have, its hit
  radius the layer's `bushRadius` × `bush_hit_radius_frac`;
- the tuft shader (opaque, both sides lit) dithers each instance out with a 4x4 screen-space Bayer pattern (`discard`, no
  shrinking) as its distance goes from `ground_cover_fade_start` to `_end` (`GroundCover.near_alpha`);
- bush layers (preset shape `bush`) also get a far version (`build_far_bush`: the same bush builder with a 6 x 2 dome, so it keeps the near bush's colours, outline and painted leaves) from the same `placements` pass (`far_out`, out to `ground_cover_far_reach`, same transforms).
  The far shader (`is_far`) uses the inverted Bayer test, so the dome fills exactly the pixels the near bush drops,
  then dithers out itself between `ground_cover_far_fade_start` and `_end` (`GroundCover.far_alpha`). Grass layers get no far version. Not mirrored in the lab's 3D view;
- beyond that range the ground shows the cover: `LevelView._build_ground` multiplies its baked vertex light
  (`COLOR.rgb`, which `level_ground.gdshader` already multiplies into the surface) by `GroundCover.ground_multiplier`,
  each type's colour being the density-weighted average of its layers' tuft colours (`GroundCover.tints`), with
  hash-jittered cell edges. The lab mirrors this in `paintCoverTint` and its `tuftMaterial` cut-off.

### In the game: look

The level view is graded to read as a daytime photo, not the free-roam overcast: its own `Environment` in
`level_view.tscn` (a seamless noise-cloud `PanoramaSkyMaterial` ramped blue to white, `fog_light_color` pale blue, depth fog ending at `GameConfig.level_tree_draw_m`,
`fog_sky_affect` 0);
`LevelView._build_ground` multiplies the grass vertex colour by `(0.95, 1.25, 0.72)`, fading out over the few metres around the road's edge, to push the ground
lime; `KIND_TINT` in `level_trees.gd` tints each Welsh species (spruce near-black green, broadleaves yellow-green); the shader then squashes leaf contrast and saturation so trees sit in the muted palette.
Global grade values in `GameConfig`: `grade_saturation` 0.85, `grade_contrast` 1.1, neutral `grade_shadow_tint` / `grade_highlight_tint`,
`fog_density` 0.0025. `tools/level_view_capture.gd` takes `CAP_POSES="x,z,tx,tz,name;..."` (+ `CAP_EYE`, `CAP_FOV`,
`CAP_OUT`) for eye-height photo-match renders.

The lab's 3D view copies this look so it matches the game: unshaded ground with the same baked sun light
(`lightAt`) and grass multiplier, `KIND_TINT` as each tree kind's `tint`, the sky's mid
colour behind, Godot-style `exp(-density·d)` fog in `fog_light_color`, and a CSS saturate/contrast for the grade.
It skips the grade's warm tints, vignette and dither. When the game's look changes, update both.

### In the game: spectators

The save's `spectators` ({x, z, r, n}) become live crowds in the level view: see [spectators.md](spectators.md) -> "Level spectator groups". Spawn/despawn distances are `level_spectator_spawn_m` / `level_spectator_despawn_m`; the key is excluded from the bake key, so editing groups never forces a rebake.

### Gravel patches

The save's `gravelPatches` (`[[{x, z}, ...], ...]`, polygons) are level gravel pads: turning areas at dead ends and yards
round buildings, so the player can turn round and buildings look reachable. `LevelData` (`parse_patches`, `polygon_distance`,
`patch_at`, `_level_patches`) and the lab's `rebuildRoads` / `rebuildGrid` share the maths (pinned by the parity fixture):

- **Level:** a patch sits at the mean height of the road samples inside it, or, with none, the mean ground at its corners.
  The ground inside is that level (5 cm under it, like a road) and blends back over `PATCH_FALLOFF` (4 m) past its edge plus the
  road flat margin.
- **Roads onto it:** only a road that enters a patch is eased to its level, by distance *along the road network*
  (`_network_distances`, crossing junctions through `_junction_links`, so every road at a nearby junction moves together and
  meets level; a hairpin or a road merely passing beside the patch is untouched), over `JUNCTION_BLEND` m, longer when it has more height to make up (`PATCH_RAMP`,
  capped at `PATCH_BLEND_MAX`). Two patches joined by a road are first pulled toward each other's level until the road
  between them climbs no more than it did before (so the pads' height gap doesn't become a ramp); between them the levels are
  blended, weighted toward the nearer by inverse square distance, so the road never steps from one level to the other.
- **Look:** the bake writes a patch's texels into the road frame as an even junction pad (`LevelBake.PATCH_HALF` half-width,
  junction weight 1, never tarmac) wherever it is nearer the patch's inside than any road's edge, so `gravel()` draws it
  with no ruts or direction and the existing shader needs nothing new. The polygons are stored in the bake (`z_patches`).
- **Driving:** `surface_at` counts a patch as road (gravel grip); `LevelView.is_off_road` doesn't run the reset clock on one.
- **Made by** `tools/geo/pack_level.js` when the save has no `gravelPatches` (delete the key to remake them): a jittered
  disc of `DEAD_END_R` m just past each dead end (a road end meeting no other road, away from the square's edge), and each
  building's footprint grown by `YARD` m plus a mouth on the nearest road within `DRIVE_MAX` m. Patches within `MERGE_GAP`
  m merge (convex hull), since two nearby pads at different heights leave a steep ramp. Trees and cover are cleared off them.
- **Lab:** the "Gravel patches" layer in 2D; the **Gravel patch** tool (G) adds a 12 m square with a click; drag corners,
  double-click an edge to add one, Delete removes a corner, Shift+Delete the patch. 3D draws each as `gravel()` with junction
  weight 1, pulled in front of the road ribbons by a depth offset. The level map (M) draws them under the roads.

### Tarmac roads

A road node with `tarmac: true` is paved; the flag blends between nodes like the half-width (`LevelData.st`, the lab's sample `t`), so a
road that changes surface fades over one segment. `make_level.py` paves the OSM public roads (`unclassified` and up, the 3 m
half-width ones); everything else is a gravel track. In the lab the node pop-up's **Tarmac** box sets one node and **Whole road to this
surface** copies it along the chain; 2D draws paved samples grey.

- **Grip:** `LevelData.surface_at` returns the tarmac weight as `.y`, so the drivetrain, dust and tyre marks treat it as tarmac with no
  level-specific code. `LevelData.nearest` carries it as `.w`.
- **Bake:** the frame's alpha keeps the junction weight in its low 4 bits and the blended tarmac weight in its high 4
  (`LevelBake.frame_tarmac`), so the surface fades over the segment in the game as in the lab; the samples' `st` is stored in `z_road`.
- **Look:** `tarmac()` in the shader (and the lab's copy beside `gravel()`): `textures/tarmac.png` (also from `tools/bake_gravel.js`,
  1.25 cm texels over 3.2 m) holds chippings whose alpha is how much wear strips their binder, so the wheel tracks (one lane each side
  above 2.4 m half-width) show pale stone and the rest stays dark; an oily strip mid-lane, squared repair patches every 8 m along, and a
  crumbly, mossy edge (`tarmac_edge`, less ragged than `gravel_edge`). The two are mixed by the frame's blended tarmac weight.

### Gravel road

The default road is a gravel forestry track, drawn the same way in the game (`shaders/level_ground.gdshader` → `gravel`) and the
lab (`GRAVEL_GLSL`, a verbatim copy patched into the road's `MeshBasicMaterial`; keep the two in step):

- **Stones** are baked, not computed: `textures/gravel-forest.png` (`node tools/bake_gravel.js`) is a seamless 256 px tile over
  6.4 m (2.5 cm texels, nearest filtered with mipmaps, so distance doesn't shimmer). RGB is the stone colour; alpha is each
  stone's rank. A stone shows only where the road's looseness exceeds its rank, so one tile serves both the bare ruts and the
  stony crown; big stones have high ranks and appear only on loose ground. Gaps (rank 1) show the shader's dust colour.
- **Road-shaped masks** are a few value-noise lookups per pixel: two wheel ruts about 0.8 m either side of the centre that
  wander along the road, swept mostly clean, with tyre-polished streaks and damp patches; moss on the crown and verges; a
  ragged edge up to 0.45 m inside the half-width (`gravel_edge`).
- **Inputs:** world xz, signed metres across, half-width, metres along. The game's shader reads them per pixel from the baked frame textures (`LevelBake`), filtering |across| unsigned so a sign flip between roads can't fake a road. The lab's
  road mesh carries `rd` = (across, along, half-width) and discards past the edge instead of blending into grass.
- The lab decodes the tile to linear light (its one line that differs from the game) and gamma-encodes the result, as Godot does, so the colours match.

### Tree tiles and baked visibility (Phase 3)

`LevelBake` stores the trees: numbered tile by tile (`TREE_TILE_M` 100 m squares), species by species inside a tile,
as `tree_xf` (12 floats each, the MultiMesh buffer layout), `tree_kind` and `tree_tile_first`. `tree_xf[i * 12 + 5]` is the
tree's height. The visibility rows (`vis_every`; `set_visibility`, `visible_in`) are per viewpoint row (every 4 road
samples), ascending tree numbers, so one tile's trees are a binary-searched slice. They are kept as diffs against the row
before (`vis_add` / `vis_rem` with their `*_start`; a whole row every `VIS_KEY` rows) and `visible_in` decodes the row it
is asked for, caching the last four (`_rows`): the trees ask for rows r and r+1 in turn for every tile, and with only one
cached each call decoded back from the keyframe, about 3 ms a tile.

**Storage:** the big arrays are not exported; `_get_property_list` / `_get` / `_set` save each as a zstd blob (`z_*`,
`BLOBS`) and decode it on load, so the file is plain `ResourceSaver.save` with no `FLAG_COMPRESS`. Heights are stored as
1 cm differences in two byte planes (`_zip_heights`); integer lists the same with four planes (`_zip_ints`). 5 km is about 20 MB on disk (heights 9, frame 2.7, trees 4.8, visibility about 3).

`tools/bake_level.gd` (needs a window, not `--headless`; headless skips visibility and draws every tree) renders
every tree in its ID colour (`shaders/level_tree_id.gdshader`, real alpha cut-out) from 3 lateral offsets, 2 eye heights
and 4 directions per row, at 384 px, 90 degrees, to `level_tree_draw_m`; one pixel marks a tree visible. The renderer
bends dark colour bytes, so ids are not plain RGB: `_calibrate` finds which bytes of 0-255 come back unchanged
(`_levels`) and writes an id in digits of those (`_tag_colour`, no colour transform in the shader); `_self_check` then
draws known ids (0, 1, 255, 256, 65535, 65536, the max) through the real shader and aborts if any reads back wrong. Pixels
whose bytes are not all exact levels (cut-out edges) are ignored. Before saving, `LevelBake.visibility_problem` fails the
bake if a row holds an id outside the trees or many of its trees are beyond `level_tree_draw_m` + 50 m of its viewpoint.
(A to-linear conversion in the shader once dropped the id's top bits, so trees past id 65535 never showed up.) On the 600 m level: about 0.4 s for heights/frame/trees, about 11 s for 118 rows, a 395 kB bake.

`LevelTrees` (`level_trees.gd`, built by `LevelView.load_level`, updated each frame by `_process`): one MultiMesh per
tile (up to `KINDS_PER_DRAW`, 6, species each; a tile with more gets a second), made lazily within `level_tree_draw_m` of the camera and culled by `visibility_range_end`. When the
camera's road row changes it repacks each queued tile (3 per frame) to the trees rows r and r+1 see, packed to the front
(`visible_instance_count`); no bake means every tree. Each instance carries `INSTANCE_CUSTOM` (`STRIDE` 16 floats: the transform's 12, then r = its
species' slot), and `level_tree.gdshader` picks that slot's `albedoN` texture and `tints[N]`; `_material_for` keeps one material per species
list, shared by tiles. This made trees one draw call per tile instead of one per tile and species (Hafren: about 43 to 15 a frame). Collision (`Hitboxes`, a node per tile, shape index plus the tile's first
tree number = tree number) exists only for tiles within `level_tree_collision_m` of the car and goes at twice that.
`size_factor` / `knock_down` answer the car by tree number; felled trees (`_fallen`, `_fall_pose`) stay felled when a tile
is rebuilt. Tests: `test_level_trees.gd`, tree parts of `test_level_bake.gd`.

At runtime `LevelView.load_level` loads the saved bake first (`LevelBake.load_fresh`) and decodes the save with `LevelData.load_save(d, false, false)` when it is fresh: the trees and the ground (height grid, `_build_road`) live in the bake, so the 185k tree dictionaries (about 150 MB at 5 km) and the road build are never made; only the cover grid and tints are read from the save. A stale bake decodes them and bakes in process.
