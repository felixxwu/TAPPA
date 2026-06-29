# Low-poly opaque ground cover

A single low-poly low-vegetation model: a low, wide spreading patch of ground
cover.

| Model                 | File                     | Verts | Notes                                       |
| --------------------- | ------------------------ | ----- | ------------------------------------------- |
| Ground cover (opaque) | `groundcover_opaque.glb` | ~660  | Solid leaf-shaped polys, **no alpha cutout** |

It is built from small **opaque leaf-shaped diamonds** whose silhouette is the
geometry itself — there is no alpha cutout, so every fragment is opaque, keeps
early-Z, and avoids the overdraw cost that alpha-tested leaf cards incur on
mobile. UVs sample small green windows of the tiling foliage texture for colour
variety; the material is two-sided but fully opaque (no blending).

A 4-angle preview contact sheet (front-¾, side, back-¾, elevated hero) is in
`previews/`.

## How it was made

Generated procedurally in `../../tools/build_vegetation.gd` (SurfaceTool),
rendered to the preview sheet, and exported to `.glb` via `GLTFDocument`. No
Blender needed. Regenerate with:

```sh
xvfb-run -a godot --path rally --rendering-driver opengl3 \
    --script tools/build_vegetation.gd
```

(Headless GL via Mesa llvmpipe under `xvfb`, the same pattern as
`tools/render_model.gd`.) Tune leaf count/size/spread in
`build_groundcover_opaque`, then re-run.

## Texture (online-sourced)

`textures/foliage.jpg` — "dark grass" tiling texture, via mrdoob/three.js
(`examples/textures/terrain/grasslight-big.jpg`), licensed **CC-BY-3.0**
(http://creativecommons.org/licenses/by/3.0/), originally from opengameart.org.
Attribution is required by the licence.

The `groundcover_opaque__albedo.png` next to the `.glb` is Godot's import-time
extraction of the embedded texture (regenerated on import).
