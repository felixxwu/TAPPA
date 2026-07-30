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
| ~~after orphan-texture exclusion~~ (reverted 2026-07-30 — see below, this broke HQ boot) | 455 | 12,369,260 B |
| after car-body import hygiene | 455 | **7,612,460 B** |

**−9.74 MB, −56%, measured at the time** — the "orphan-texture exclusion" row's
saving is **no longer present**: those files turned out to be load-bearing (needed
by `PackedScene.instantiate()`, not actually orphaned) and excluding them shipped a
boot-hang/crash bug, so the exclusion was reverted. The "car-body import hygiene"
saving is unaffected. The wasm (~37.7 MB uncompressed) is unaffected either way and
remains the larger download.

## Car body textures — NOT an orphan, corrected 2026-07-30

> **This section previously claimed the second per-car PNG was a safely-strippable
> orphan and excluded it from every export preset. That was wrong and shipped a live
> bug** — see the incident below. The exclusion has been **reverted**
> (`export_presets.cfg` no longer names any of these files in `exclude_filter`); do
> not re-add it without re-reading this section.

`CarLibrary.CARS[*].model_texture` names **one** PNG per car, and `car.gd`
(`_apply_model_material`) loads it by path and assigns it to every non-aero
`MeshInstance3D` of the car's GLB body **after** the model loads — this is the
"live" skin players actually see.

But the claim that "the GLB scenes reference no textures" was false: each `.glb` is
a self-contained binary glTF with its **own baked material image embedded inside
it** (`materials[].pbrMetallicRoughness.baseColorTexture` → `images[].bufferView`,
confirmed by dumping `mx5.glb`'s JSON chunk with `strings` — the embedded image's
`bufferView.byteLength` matches the extracted PNG's file size exactly, byte for
byte). Godot's glTF importer extracts that embedded image to a **separate PNG file
on disk** next to the `.glb` (named after the glTF image's internal `name` field —
that's why mx5's extracted file is `mx5_Untitled.png`, not `mx5_texture.png`), and
the **compiled, imported scene's material references the extracted file by UID**.
That extracted file is what `scene.instantiate()` (`car_prop.gd::spawn`) needs
at the moment `car.tscn` (which embeds all nine cars' bodies, see below) is
instantiated — **before** `_apply_model_material` ever runs and overrides it.
Strip the extracted file from the export and `PackedScene.instantiate()` doesn't
substitute a blank texture and carry on — it can fail outright and return **null**.

So there are two real, legitimately-different textures per car: the model's own
extracted/baked material image (load-bearing for instantiation) and the
hand-authored `model_texture` skin (what the car actually looks like once
built). They're byte-identical only for `charger` and `acty` (one file serves
both roles); for the other seven they're genuinely different images and BOTH are
needed at runtime, for different moments in the same car's construction.

| car | model_texture (applied after load) | glb-embedded/extracted (needed to instantiate) |
|---|---|---|
| 911 | `blender/911/texture.png` | `blender/911/911_texture.png` |
| viper | `blender/viper/texture.png` | `blender/viper/viper_texture.png` |
| xjs | `blender/xjs/texture.png` | `blender/xjs/xjs_texture.png` |
| focus | `blender/focus/focus_texture.png` | `blender/focus/texture.png` |
| twingo | `blender/twingo/twingo_texture.png` | `blender/twingo/texture.png` |
| thebeast | `blender/thebeast/mrbeast_texture.png` | `blender/thebeast/texture.png` |
| mx5 | `blender/mx5/mx5_texture.png` | `blender/mx5/mx5_Untitled.png` |
| charger | `blender/charger/charger_texture.png` | *(same file)* |
| acty | `blender/acty/acty_texture.png` | *(same file)* |

### The incident this caused

Excluding the right-hand column shipped in a real Android release and crashed HQ's
boot for players (device bugreport: `SIGSEGV`/`SEGV_MAPERR` on the GL render
thread ~3s after launch, deep in a recursive `Object::callp` ↔
`GDScriptFunction::call` ↔ `Variant::callp` cycle — symbolized against Godot
4.6.3's official debug-symbols release asset, Build ID
`e3254c34ee1b6c5b6d2bf697520e8089b4ebe5bc`, matching the shipped `.so` exactly).
A local debug-signed reproduction (JDK 17 + `android-commandlinetools` +
NDK r23c installed via `sdkmanager`, debug APK sideloaded onto a Pixel 8) surfaced
the missing-texture errors directly in `adb logcat` and traced them to a related,
separately-fixed bug: a null car returned by a failed spawn permanently hung
`hq.gd::_spawn_lineup_progressive` instead of crashing outright (see
`menus.md` → *"A car that fails to spawn must never hang boot forever"*). Both the
export-config regression (this section) and the missing null-guard (`menus.md`)
needed fixing; neither alone was sufficient.

The `.gltf`/`.bin` sidecars next to each `.glb` genuinely are unreferenced (Godot
imports them a second time only because they sit next to the `.glb`, producing
duplicate, never-loaded `.scn` resources) and **remain excluded** — only the
per-car texture entries were reverted:

```
blender/*/*.gltf, blender/*/*.bin, ref/*
```

If this size cost needs recovering again, do it in a way that can't hard-fail
`instantiate()` — e.g. re-export each `.glb` from Blender with its material
stripped (so there's nothing for the importer to extract), not by excluding an
already-referenced file from the PCK.

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

**Every `blender/*/wheel.*` also now has `detect_3d/compress_to = 0`** (again, mx5
was the one already-correct file). This matters more for wheels than for any other
texture family: the cosmetic wheel swap
([wheel-customization.md](wheel-customization.md)) means *every* car's wheel texture
can be sampled in 3D on *any* body, so every one of them is exposed to the silent
re-import above — and `blender/xjs/wheel.png` is **127×127**, which ETC2/ASTC (4×4
blocks) cannot represent cleanly, so a drift to mode 2 would break it on Android
while a desktop D3D12/Vulkan build looked fine. `tests/headless/test_wheel_texture_imports.gd`
guards both halves of the rule (opted out of the 3D re-import; and any wheel texture
that *is* mode 2 has block-aligned imported dimensions) without pinning which
textures exist or what any of them chose.

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
