# Real-world level pipeline (satellite, OSM, LiDAR)

**Source:** `tools/geo/` — Python scripts that turn a real patch of Wales into a level editor lab save and a
ground-cover mask. Python deps are in `tools/geo/requirements.txt`. Downloaded data and outputs go to
`tools/geo/data/<name>/`, which is git-ignored (the imagery licence doesn't allow redistributing it, and the LiDAR is
~100 MB) and has a `.gdignore` so Godot doesn't import it. Re-run `fetch.py` to get it back.

Run from `tools/geo/`, in order (`cover_mask.py` before `pack_level.js` so the cover is packed into the save):

1. `python fetch.py <name> <easting> <northing> [size_m]` — square centre in British National Grid metres (default
   600 m square). Downloads 1 km Welsh Government LiDAR DTM (ground) and DSM (surface) tiles, using the tile catalogue
   WFS for their links, and stitches each into `lidar/dtm_mosaic.npy` / `dsm_mosaic.npy`; OSM `osm.xml` from the
   OpenStreetMap API; an Esri World Imagery `satellite.jpg` in Web Mercator. `meta.json` records the square centre,
   the mosaic's north-west corner (`mosaic_origin`) and the satellite's lon/lat box (`sat_bbox`), which the other
   scripts read. LiDAR only exists for Wales (2020-23 survey); the script stops if a tile is missing.
2. `python make_level.py <name>` → `level.json` (unpacked): LiDAR ground as the heightmap, the longest drivable OSM
   track/unclassified road (not under full canopy, no hairpins over 100°) as the road, and a tree at each canopy peak
   with its species picked from canopy height and satellite brightness.
3. `node pack_level.js ../level_editor_lab.html data/<name>/level.json ../levels/<name>.json` — packs it with the
   lab's own `pack`/`unpack`/`bakeKey` (sliced out of the HTML, so the format can't drift) and checks the round trip.
   It also removes every tree within 2 m of the road's edge and every cover cell within 0.5 m, measured against the
   lab's own spline (`roadSamples`/`nearestRoad`). Run on a packed save alone (`node pack_level.js ../level_editor_lab.html
   ../levels/<name>.json`) it just clears the road again in place, and gives any building standing in no gravel patch its yard out to the nearest road (the game levels a yard's ground to the road through it, so a building without one can sit well above or below the road); that drops a stale visibility bake, so re-bake after.
4. `python cover_mask.py <name>` → `cover_index.png` (pixel = ground-cover type: 0 none, 1 verge grass, 2 molinia,
   3 heather, 4 bilberry/scrub; 1 m per pixel, row 0 = north edge) plus `cover_mask.png` (coloured) and `sat_crop.png`
   to compare by eye, and writes the cover into `level.json` as the editor's packed `cover` (base64, one byte per cell). A rough estimate to paint over in the level editor: heather and bilberry are hard to tell
   apart from 1 m satellite pixels, and gaps inside plantation come out as grass.
5. `python preview.py <name>` → `level_preview.png`, a top-down hillshade with trees and road.

`tools/tree_lab_lineup.sh "<preset>" …` screenshots tree lab presets with headless Chrome into one line-up image
(serve the repo on port 8941 first), used to compare species against roadside photos.

`pack_level.js` also supplies the lab's `PRESETS`/`PRESET_BASE`/`COVER_RENDER` (sliced from `groundcover_tufts.js` and the lab html), so a packed save carries `coverKinds` (the full tuft recipes per cover type) for the game's `GroundCover`.
