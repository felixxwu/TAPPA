# Low-poly vegetation models

Procedurally-built, flat-shaded low-poly vegetation for the rally stages:

| Model          | File            | Tris (approx) | Notes                                  |
| -------------- | --------------- | ------------- | -------------------------------------- |
| Pine / conifer | `tree_pine.glb` | ~36           | Tapered bark trunk + 3 stacked cones   |
| Oak / round    | `tree_oak.glb`  | ~230          | Bark trunk + 3 lumpy faceted blobs     |
| Bush / shrub   | `bush.glb`      | ~210          | 3 clustered blobs, trunk stub buried   |

Each model is a single mesh with two surfaces — **surface 0 = bark**
(trunk), **surface 1 = foliage** (canopy) — so it draws with two materials and
no shared vertices (per-face normals give the faceted low-poly shading).

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
`tools/render_model.gd`.) Tune the geometry/colours by editing the
`build_pine` / `build_oak` / `build_bush` functions, then re-run.

## Textures (online-sourced)

Stored in `textures/`. Downscaled to 256 px for the low-poly look and to keep
the embedded-texture `.glb` files small (~300 KB each).

| File          | Used as              | Source                                                                                              | License     |
| ------------- | -------------------- | --------------------------------------------------------------------------------------------------- | ----------- |
| `bark.jpg`    | Trunk / bark         | "tree low-poly" trunk texture, via godotengine/godot-demo-projects (`3d/truck_town`)                | CC-BY-4.0   |
| `foliage.jpg` | Canopy / leaves      | "dark grass" tiling texture, via mrdoob/three.js (`examples/textures/terrain/grasslight-big.jpg`)   | CC-BY-3.0   |
| `leaves.png`  | (spare, alpha cutout)| "tree low-poly" leaf atlas, via godotengine/godot-demo-projects (`3d/truck_town`)                   | CC-BY-4.0   |

### Attribution (required by CC-BY)

- Bark & leaf textures are from **"tree low-poly"** by **Ricardo Sanchez**
  (https://sketchfab.com/3d-models/tree-low-poly-4cd243eb74c74b3ea2190ebcec0439fb),
  licensed **CC-BY-4.0** (http://creativecommons.org/licenses/by/4.0/),
  obtained via the godotengine/godot-demo-projects repository.
- Foliage texture is **"dark grass"** from opengameart.org, licensed
  **CC-BY-3.0** (http://creativecommons.org/licenses/by/3.0/), obtained via the
  mrdoob/three.js repository.

The `__albedo*.png` files next to each `.glb` are Godot's import-time
extraction of the embedded textures (regenerated on import).
