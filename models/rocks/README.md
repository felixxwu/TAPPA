# Low-poly roadside rocks

Three faceted rock models scattered along the stage verges as collidable obstacles.

| Model     | File               | Tris | Source size (units) | Role                          |
| --------- | ------------------ | ---- | ------------------- | ----------------------------- |
| Large A   | `rock_largeA.glb`  | 80   | 0.79 x 0.26 x 1.02  | Flat slab, sits low and wide  |
| Large D   | `rock_largeD.glb`  | 80   | 1.07 x 0.57 x 1.03  | Rounder lump, the tallest     |
| Small A   | `rock_smallA.glb`  | 16   | 0.36 x 0.19 x 0.36  | Small stone, the common filler |

All three sit on `y = 0` in source, so they need no ground offset — `TreeMeshField`
drops them straight onto the terrain height.

## Licence

**Kenney "Nature Kit" (2.1), CC0 1.0** — <https://kenney.nl/assets/nature-kit>.
Free for personal, educational and commercial use; crediting Kenney is appreciated
but not required. No attribution file needs to ship.

Only these three of the kit's 30 rock models are vendored — the rest of the pack is
not in the repo. Total on-disk cost is ~18.5 KB.

## Why these are meshes and not billboards

Every other piece of scenery in this game that reads as "scattered nature" is a
camera-facing billboard (see `features/trees.md`). Rocks deliberately are not. A tree
card is tall, thin and normally seen at distance, so its flatness never shows; a
boulder is squat and you drive within a metre of it, where a camera-facing quad reads
as cardboard. Real geometry also gives the collision box something honest to match.

## How they are prepared

Not at all offline — there is **no build tool for these**, unlike the vegetation
(`tools/build_vegetation.gd`) or the tree cutouts (`tools/gen_snow_trees.py`). The
`.glb` files are vendored exactly as Kenney ships them, and everything else happens at
load time in `Foliage.rock_mesh`, which:

1. merges the model's 2–3 primitives into **one surface** (one draw call per bin), and
2. rewrites each primitive's material colour into **vertex colours**, remapped to
   `GameConfig.rock_body_color` / `rock_cap_color`.

Step 2 exists because Kenney authors the body as an orange `dirt` material and the cap
as a turquoise `grass` one — a palette built for their own kit, not for this game's
ground. The remap is by material NAME, not surface index, because the order differs
between models (`rock_smallA` lists `grass` first, the other two list `dirt` first).

Retuning is therefore a config change, never a re-export. See `features/rocks.md`.
