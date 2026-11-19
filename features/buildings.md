# Buildings (Building Lab)

The generator lives in `tools/buildings.js` (`Buildings.build(type, seed, {L, W, h})`, `Buildings.paintAtlas`), shared by
`tools/building_lab.html` (the preview page) and the level editor lab. `tools/building_lab.html` is a standalone browser page (open the file directly, three.js from CDN, like the
tree lab) that generates Hafren-Forest-style buildings from a type + seed: stone cottage, rendered cottage,
stone terrace, timber hut (toilet block, optional solar panel), stone garage (timber gable, roller door) and
Dutch barn (curved rusty tin roof, open front on posts). `?type=<name>` / `?lineup=1` preselect.

Cheap to render by construction: every building is ONE mesh with ONE material and ~100–300 flat triangles.
Walls are plain quads/gable pentagons; doors and windows are cut-out decal quads 2 cm proud of the wall
(alpha-scissor, no holes in the walls).

Textures come from one procedurally painted atlas (`paintAtlas`), shared by all buildings: 512 x 2048 at
32 px per metre, a stack of 8 strips (`STRIPS`: stone, render, clad, darkwood, slate, rust, bluetin, detail).
Each strip is 16 m wide and wraps in U so walls tile along their length; it is 8 m tall and never wraps in V,
so no single face may be taller than 8 m (`Mesh.poly` maps V from the face's lowest point). The detail strip
holds the cut-outs, located by pixel rects in `DETAIL`.

"Download .glb" exports the current building(s) with the atlas embedded; "Download atlas PNG" exports the
atlas alone. `tools/levels/hafren_5km.json` has a `buildings` list (`{x, z, rot, type, L, W, h?, seed}`; `rot` is the ridge
direction in radians on the map, x east / z south). The 24 entries come from the OSM building footprints inside the
square (oriented bounding box of each outline), height from LiDAR DSM - DTM, and a type picked by eye from the
satellite crop and footprint size. The level editor lab draws them as footprints in 2D and as meshes in 3D
(`rebuild3DBuildings`). 
In the game: `node tools/bake_buildings.js tools/levels/<level>.json` runs `buildings.js` under node (tiny three.js and
canvas stand-ins) and writes `<level>.buildings.json` (each building's triangles, already sized) and
`tools/levels/buildings_atlas.png`. Re-run it after changing a level's buildings or `buildings.js`. `LevelView.load_level`
adds a `LevelBuildings` node (`scripts/level_buildings.gd`) that builds one `StaticBody3D` per building: the mesh
(unshaded with the baked sun shading in vertex colours, nearest-filtered atlas, alpha scissor) plus a box collider over
the footprint, seated on the lowest ground under it. No bake file → no buildings.

**Log piles.** The level JSON's `logPiles` list (`{x, z}`) places roadside timber piles (`LogPile.build`, `log_pile.gd`) via
`LevelView._log_pile`: sawn ends facing the nearest road (logs at right angles to it), a two-section pile's stacks side by side along
the road, pushed at least 7 m off its centreline, with a box collider. The list
is left out of `LevelBake.key_of`, so moving piles never forces a rebake. The Hafren sites were picked by script: verges with
no trees within 7 m, dense forest behind and sparser ground across the road, 200 m+ from buildings and 500 m apart.
