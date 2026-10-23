# Rest-stop log cabin

One log cabin stands on every rest stop's pad (players call rest stops checkpoints). It
replaced the placeholder post. Placement, collision and the lit glow are in
`TerrainStreamer._site_marker`; see `features/free-roam.md`.

| File | What |
| --- | --- |
| `log_cabin.glb` | The cabin: 1,836 triangles, one 1024² base-colour texture, plus a dark interior floor |
| `log_cabin_0.png` | The texture, extracted by Godot's importer on import |

In its own space the cabin sits on `y = 0`, its door faces `+z`, and it is about 9.6 m
square under the roof and 6.7 m tall. The log walls (the collision box, `CABIN_WALLS`) span
about 7.4 m across and 7.5 m deep.

## Licence and credit (required)

**CC BY 4.0. Attribution is required.** Ship this credit with the game (credits screen,
store page or both):

> This work is based on "Lowpoly simple Log Cabin"
> (https://sketchfab.com/3d-models/lowpoly-simple-log-cabin-3b2e2197dedf4970b239934ee12a2513)
> by tamminen (https://sketchfab.com/tamminen), licensed under CC-BY-4.0
> (http://creativecommons.org/licenses/by/4.0/). Modified: ground plane removed, texture
> downsized, materials made matte.

## How it was prepared

The Sketchfab glTF download was cleaned once into `log_cabin.glb` by `tools/prep_log_cabin.py`
(rerun it on a fresh download to redo the cleanup):

1. dropped the model's 16 m textured ground plane (the game has its own ground);
2. downsized the 2048² cabin texture to 1024² and embedded it;
3. set both materials' roughness to 1 (Sketchfab exported 0, a glossy plastic look) and renamed
   the black interior plane's node to `Interior`, which the lit glow finds by name.

Node transforms and meshes are otherwise as shipped.
