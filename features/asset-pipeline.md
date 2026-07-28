# Asset Pipeline & Export Sizing

How source art in `blender/` and `textures/` becomes bytes in the shipped PCK,
which of those bytes are deliberately *not* shipped, and the import settings that
decide the size. Companion to [rendering.md](rendering.md) (how it looks) — this
file is about what it costs.

## Where the size goes

The Web export writes `build/web/index.pck`. To see what is actually in it, parse
the PCK directory rather than trusting the export log — an exclude filter on a
*source* file does not by itself guarantee the already-imported `.ctex` is gone.
The PCK is a `GDPC` archive whose **directory lives at the end of the file** (pack
format 3): a `count` `uint32` followed by `count` entries of
`path_len:u32, path, offset:u64, size:u64, md5[16], flags:u32`.

Measured on the Web preset (2026-07-28), before and after the two size items below:

| build | entries | file size |
|---|---|---|
| baseline | 483 | 17,349,280 B |
| after orphan-texture exclusion | 455 | 12,369,260 B |
| after car-body import hygiene | 455 | **7,612,460 B** |

**−9.74 MB, −56%.** The wasm (~37.7 MB uncompressed) is unaffected and remains the
larger download.

## Car body textures — the live/orphan trap

`CarLibrary.CARS[*].model_texture` names **one** PNG per car, and `car.gd`
(`_apply_model_material`) loads it by path and assigns it to every non-aero
`MeshInstance3D` of the car's GLB body. The GLB scenes themselves reference **no**
textures — the body skin is applied entirely from `model_texture`.

Seven of the nine car folders contain a **second, byte-identical copy** of the body
texture. It exists because the unreferenced `.gltf`/`.bin` sidecars next to each
`.glb` are imported too, and each import extracts its own image. Each orphan cost
~0.667 MB of VRAM-compressed `.ctex` in the PCK.

> ### ⚠️ The orphan is NOT consistently named
>
> For **911, viper and xjs** the *live* file is the bare `texture.png`; for
> **focus, twingo and thebeast** the bare `texture.png` is the *orphan*. A
> `texture.png` glob and a `*_texture.png` glob would each strip three live cars.
> **Every orphan is named individually** in the export presets' `exclude_filter`.
> If you add a car, re-derive this table from `model_texture` — never from the
> filename.

| car | live (`model_texture`) | orphan (excluded from export) |
|---|---|---|
| 911 | `blender/911/texture.png` | `blender/911/911_texture.png` |
| viper | `blender/viper/texture.png` | `blender/viper/viper_texture.png` |
| xjs | `blender/xjs/texture.png` | `blender/xjs/xjs_texture.png` |
| focus | `blender/focus/focus_texture.png` | `blender/focus/texture.png` |
| twingo | `blender/twingo/twingo_texture.png` | `blender/twingo/texture.png` |
| thebeast | `blender/thebeast/mrbeast_texture.png` | `blender/thebeast/texture.png` |
| mx5 | `blender/mx5/mx5_texture.png` | `blender/mx5/mx5_Untitled.png` |

`acty` and `charger` have a single body texture each and are not affected.

The orphans and the `.gltf`/`.bin` sidecars are **kept on disk** (they may be part of
the Blender round-trip) and excluded from the export instead — see the
`exclude_filter` in every preset in `export_presets.cfg`:

```
blender/*/*.gltf, blender/*/*.bin, <the seven orphan PNGs, named individually>
```

The sidecar exclusion also drops the seven duplicate `.scn` scenes (every car model
was being imported twice). The double *import* cost at edit time remains; only the
shipped cost is removed.

## Texture import settings

`project.godot [importer_defaults] texture` sets `compress/mode = 1`. Mode 1 is
**Lossy** (WebP on disk, RGBA8 in VRAM) — it is *not* VRAM compression, so the
`textures/vram_compression/import_etc2_astc` project flag and the presets'
`texture_format/etc2_astc` do nothing for a mode-1 texture.

**The nine live car bodies are deliberately mode 1 (lossy) with
`process/size_limit = 512`, `mipmaps/generate = true` and
`detect_3d/compress_to = 0`.** Rationale:

- Smallest download by a wide margin: ~20–34 KB each, versus 699,116 B each as a
  1024² S3TC `.ctex`.
- **Format-agnostic.** The Web preset ships `vram_texture_compression/for_desktop`
  only, i.e. S3TC. iOS Safari exposes no S3TC, so a VRAM-compressed texture is
  decompressed to RGBA8 at load — slower boot and several times the texture RAM on
  the tightest-budget device. Lossy sidesteps the whole question. Do **not** "fix"
  that by flipping `for_mobile = true`: that *adds* an ETC2/ASTC copy alongside the
  S3TC one and makes the download bigger.
- 512² is invisible at the shipped internal resolution (480×360) with nearest
  filtering. Verified by before/after captures in the HQ car park (several cars in
  frame at once, the worst case) via `tools/render_hq_carpark.sh`.
- **`detect_3d/compress_to = 0` is load-bearing.** With the default `1`, Godot
  silently re-imports a texture as VRAM-compressed the first time it is sampled in
  3D — which is how these files drifted to mode 2 in the first place. Leaving it at
  `1` would undo this within one editor session.

Still mode 2 (VRAM) on purpose: `grass.jpg`, `gravel.jpg`, `sky_field.png`,
`groundcover_opaque__albedo.png`, `blender/mx5/wheel.png`. Still mode 1: the tree
atlas and the UI/garage textures — foliage alpha edges block-compress badly, and
mode 1 keeps them iOS-safe.

Every `blender/*/wheel.*` now has `mipmaps/generate = true`; seven of the eight had
it off while being sampled in 3D, which thrashes the texture cache at distance
(`blender/mx5/wheel.png` was the one already-correct reference).

## Shadow meshes

`meshes/create_shadow_meshes = false` on every `blender/*/*.glb` import. A shadow
mesh is a merged-vertex *duplicate* built purely to speed up shadow passes — turning
it off does not remove any shadow, it just renders the shadow from the normal mesh.
The stage has **no lights at all**; the HQ and podium suns
(`hq_environment.gd`, `podium.gd`) leave `shadow_enabled` at its default `false`; the
**only** shadow caster in the game is the garage sun (`garage.gd`, `shadow_enabled =
true`) plus its per-bay omnis. So this buys import time and memory everywhere and
costs a negligible amount in one indoor scene.

## `[rendering]` knobs that interact with assets

- `textures/default_filters/anisotropic_filtering_level = 0` — every 3D material is
  `TEXTURE_FILTER_NEAREST_WITH_MIPMAPS` for the PS1 look; anisotropic sampling on top
  of nearest is pure wasted bandwidth on a tile GPU.
- `mesh_lod/lod_change/threshold_pixels = 4.0` — the car GLBs import with
  `meshes/generate_lods = true`, so the LODs exist; at the default `1.0` they were
  barely used.
- `limits/opengl/max_lights_per_object = 4` — drives the GL-Compatibility shader
  variant's light loop. The stage has no lights, HQ has one sun, the garage one sun
  plus per-bay omnis, so 8 was never needed.

## Dev-only live reload

`serve_web.sh` injects the `/reload-token` poller into `build/web/index.html` **after**
the export. It used to live in the Web preset's `html/head_include`, which shipped it
to itch.io and to every player's phone: a `fetch` per second for the whole session
(battery + radio wake), a 404/second against the host, and a reload hazard on any host
that returns a varying body for an unknown path. The **landscape-lock** script in the
same `head_include` is legitimate and stays in the preset. `build_web.sh` zips before
serving, so the uploaded zip never contains the poller; the injection is marker-guarded
and idempotent.
