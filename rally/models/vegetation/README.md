# Low-poly low-vegetation models

Procedurally-built low vegetation for the rally stages — bushes, shrubs and
ground cover (no trees). Two surface styles are combined per model:

- **Solid faceted blobs** — flat-shaded low-poly geometry (per-face normals),
  textured with the tiling `foliage.jpg`.
- **Leaf cards** — double-sided alpha-cutout quads textured with `leaves.png`,
  each sampling a zoomed sub-window of the leaf sprig so **individual leaves are
  visible** on the silhouette.
- **Solid leaf polys** — small opaque leaf-shaped diamonds whose silhouette is
  the geometry itself (no alpha). They keep early-Z and avoid the alpha-test
  overdraw cost of leaf cards, so they suit mobile (see `groundcover_opaque`).

| Model             | File              | Surfaces        | Notes                                         |
| ----------------- | ----------------- | --------------- | --------------------------------------------- |
| Blob bush         | `bush_blob.glb`   | solid           | Clean faceted convex blob (cheapest)          |
| Leafy bush        | `bush_leafy.glb`  | solid + leaves  | Round bush, dense leaf cards for detail        |
| Shrub             | `shrub.glb`       | solid + leaves  | Taller upright leafy form                      |
| Ground cover      | `groundcover.glb` | leaves          | Low, wide leafy patch of undergrowth          |
| Ground cover (opaque) | `groundcover_opaque.glb` | solid leaf polys | Same patch, **no alpha cutout** — mobile-friendly overdraw |
| Grass / weed tuft | `grass_tuft.glb`  | leaves          | Upright leafy blades radiating from the base  |

Preview contact sheets (4 angles each: front-¾, side, back-¾, elevated hero)
live in `previews/`.

## How they were made

Geometry is generated procedurally in `../../tools/build_vegetation.gd`
(SurfaceTool), textured, rendered to the preview sheets, and exported to `.glb`
via `GLTFDocument`. No Blender needed. Regenerate with:

```sh
xvfb-run -a godot --path rally --rendering-driver opengl3 \
    --script tools/build_vegetation.gd
```

(Headless GL via Mesa llvmpipe under `xvfb`, the same pattern as
`tools/render_model.gd`.) Tune each model by editing its `build_*` function —
the leaf density/size/zoom knobs live in the `scatter_leaves` calls — then
re-run.

## Textures (online-sourced)

Stored in `textures/`. Downscaled for the low-poly look and to keep the
embedded-texture `.glb` files small.

| File          | Used as            | Source                                                                                            | License   |
| ------------- | ------------------ | ------------------------------------------------------------------------------------------------- | --------- |
| `foliage.jpg` | Solid blob foliage | "dark grass" tiling texture, via mrdoob/three.js (`examples/textures/terrain/grasslight-big.jpg`) | CC-BY-3.0 |
| `leaves.png`  | Leaf cards         | "tree low-poly" leaf sprig (alpha cutout), via godotengine/godot-demo-projects (`3d/truck_town`)  | CC-BY-4.0 |
| `bark.jpg`    | (spare)            | "tree low-poly" trunk texture, via godotengine/godot-demo-projects (`3d/truck_town`)              | CC-BY-4.0 |

### Attribution (required by CC-BY)

- Leaf & bark textures are from **"tree low-poly"** by **Ricardo Sanchez**
  (https://sketchfab.com/3d-models/tree-low-poly-4cd243eb74c74b3ea2190ebcec0439fb),
  licensed **CC-BY-4.0** (http://creativecommons.org/licenses/by/4.0/),
  obtained via the godotengine/godot-demo-projects repository.
- Foliage texture is **"dark grass"** from opengameart.org, licensed
  **CC-BY-3.0** (http://creativecommons.org/licenses/by/3.0/), obtained via the
  mrdoob/three.js repository.

The `__albedo*.png` files next to each `.glb` are Godot's import-time
extraction of the embedded textures (regenerated on import).
