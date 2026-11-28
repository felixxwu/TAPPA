# Neutral data format (Phase 2)

**Source:** `scripts/neutral_file.gd`, `scripts/level_bake.gd` (`save_neutral`, `manifest`), `tools/neutral_assets.gd`, `tools/neutral_export.gd`
**Tests:** `tests/headless/test_neutral_file.gd`, `tests/headless/test_neutral_assets.gd`, `tests/headless/test_level_bake.gd`

Godot-free copies of the game's data for the Rust reader (`crates/assets`), plus a text parity manifest that proves
the decoded data equals what Godot holds in memory. Plan: `todo/2026-11-28-phase-2-plan.md`.

## Container (every `.tapn` and `.bake.bin`)

```
u32 LE   header length H
H bytes  header: UTF-8 JSON (sorted keys, full float precision)
per entry of header.sections, in order:
u32 LE   raw size
...      one zstd frame of the raw bytes   (sections[i].bytes = 4 + frame size; raw size 0 = no frame)
```

The header always has `format` (1), `kind` and `sections: [{name, bytes, ...}]`. Numbers inside a section are little
endian. No magic, no offsets: read sections in order. Writer: `NeutralFile.write(path, header, sections)`.

## Parity manifest

Lines `<file>\t<field>\t<value>`, sorted. Value is the SHA-256 hex of the field's bytes, a decimal int, or a float as the
hex of its 8 f64 bytes (`NeutralFile.line`). Godot's side is `build/neutral/godot.manifest`; Rust prints the same.
For a `.tapn`, `<file>` is its path under `build/neutral/` and each section's line is its **raw** (decompressed) bytes.

## Files and where they go

- `tools/levels/<name>.bake.bin` (kind `level_bake`): the bake. Header: `bake_version, source_key, neutral_key,
  size, step, n, height_base, frame_n, tree_tile_n, vis_every, tree_kinds, spawn_nodes` (`[x,z,...]`),
  `FRAME_RANGE, FRAME_CELL, PATCH_HALF, ALONG_PERIOD, TREE_TILE_M, VIS_KEY`. One section per `LevelBake.BLOBS`
  name with an `encoding`: `delta_u16_planes` (`z_heights`), `delta_i32_planes` (`z_tree_first`, `z_vis_*`), else `raw`.
  Section bytes are exactly `LevelBake._get(name)`. Manifest: scalars, hashes of the decoded arrays and of
  `row.<r>` (`decoded_row`).
- `build/neutral/index.json`: `{files: [{path, kind, source}]}` of everything below. `build/neutral/shader_globals.json`.
- **Texture** `<res path>.tapn` (kind `texture`, for every `importer="texture"`): header `source, width, height,
  mipmaps` (count after the base), `format` (Godot `Image.Format` name of `pixels`), `stored_format` (what Godot held
  before decompressing), `params` (`compress/mode, compress/lossy_quality, mipmaps/generate` from the `.import`),
  `blocks` (`{s3tc|etc2: {format, width, height, mipmaps}}`, only for VRAM-compressed textures).
  Sections: `pixels` (all mips, base first, tightly packed) and `blocks.s3tc` / `blocks.etc2` (GPU block data as
  imported; Rust never decodes it). Manifest: `width, height, mipmaps` and each section.
- **Scene** `<res path>.tapn` (kind `scene`, every `importer="scene"` GLB and `car.tscn`): header
  `nodes: [{path, transform, mesh, materials, visible}]` (`transform` = 12 floats: basis x, y, z columns' rows as
  `basis.x.x, x.y, x.z, y.x ...` then origin; relative to the root; `materials` is the per-surface index into
  `materials`, -1 none), `meshes: [{surfaces: [{primitive, arrays, lods, aabb, vertex_count, material}]}]` (each mesh
  once; `arrays` names the present sections; `lods` are Godot's `edge_length` per level; `aabb` = position then
  size), `materials: [dump]`. Sections `m<i>.s<j>.<vertex|normal|tangent|color|uv|uv2|index>` (the
  `surface_get_arrays()` data: f32 values, `vertex` xyz, `tangent` xyzw, `color` rgba, `uv` xy; `index` i32) and
  `m<i>.s<j>.lod<k>` (i32 indices). Manifest: each section, `node<k>.transform` (f64), `node<k>.mesh`,
  `m<i>.s<j>.primitive`, `m<i>.s<j>.lod<k>.edge_length` (f64).
- **Resource JSON** `materials/wheel_tire.tres.json`, `theme/ui_theme.tres.json` (kind `resource`, no sections): header-less
  JSON `{kind, source, resource}` where `resource` is `dump()`: `class` plus every stored property; colours and vectors
  are arrays, textures and shaders are `res://` paths, embedded resources are inlined. Manifest: `json` = SHA-256 of the file.
- **Font** `fonts/Jersey10.ttf.tapn` (kind `font`): header `sizes: {"18": {ascent, descent, glyphs, textures}, "36": ...}`;
  `glyphs` rows are `[codepoint, advance.x, advance.y, offset.x, offset.y, size.x, size.y, uv.x, uv.y, uv.w, uv.h,
  texture_index]` for U+0020-U+00FF (px, UV in atlas pixels); `textures` is `{width, height, format}` per atlas.
  Sections `ttf`, `atlas.<size>.<i>`. Manifest: `glyphs.<size>` (the rows as f64), `ascent.<size>`, `descent.<size>`, sections.
  `asset_check --font-scale <dir>` (run by `tools/neutral_check.sh`, report only) lists glyphs whose 36 px bitmap or advance isn't the 18 px one scaled 2x (`Font::scale_check`).
- **Camera path** `camera_path.tapn` (kind `camera_path`, `tools/neutral_camera.gd`, `crates/assets/src/camera.rs`): the
  Hafren replay's camera and car pose entering each physics tick. Header `hz, ticks, car, logical_size` (window 1920x1080
  through `DisplayStretch.logical_size`), `horizontal_stretch`, `config` (the `GameConfig` fields the renderer reads:
  `virtual_resolution`, `horizontal_stretch`; add names to `NeutralCamera.CONFIG_FIELDS`). Sections `camera` (f32 x 15 per
  tick: 12-float transform as in scenes, then `fov, near, far`) and `car` (f32 x 12). Written by
  `benchmark/level_replay.gd --golden --full --camera-out=<file>`; `neutral_export -- --camera=<dir>` runs that in a child
  Godot (with a temporary `override.cfg`, as `run_level_replay.sh` does) and merges its manifest lines. Manifest: both sections, `ticks`, `hz`.
- **Level geometry** `level_geometry.tapn` (kind `level_geometry`, `tools/neutral_geometry.gd`): header `samples:
  [{pos, chunks, cover}]` per 50 m of the replay path, indices into the file's own `chunks` / `cover` lists (the live chunk
  variants, one per `(level, coord, stitch mask)`, and the cover layers of the live tiles; only variants some sample names
  are kept). Manifest: sections, plus `samples.pos` (f32 x 3 each) and `samples.live` (i32 `[n, chunk ids..., m, cover ids...]` each).
- **Music** `music/*.ogg`: copied as is, `kind: "ogg"`; manifest `ogg` = SHA-256.
- **Shader globals** `shader_globals.json`: `{kind, globals: [{name, type, value}]}` from `[shader_globals]`.
- Level JSON (`json.trees`, `json.height`, `json.cover`) and buildings (`buildings.floats`) lines come from `tools/neutral_export.gd`.

## Running the export

`godot --headless --path . res://tools/neutral_export.tscn -- --assets=build/neutral` (it needs the project's
autoloads, so run it as the scene, not with `-s`). `NeutralAssets.export_all(dir)` returns the manifest lines.

## Headless finding (Godot 4.6.3, `--headless`)

Everything the export reads is available under `--headless` with the dummy renderer, so **no `xvfb` is needed**:
`Texture2D.get_image()` returns the real pixels (also for the VRAM-compressed ones), `CompressedTexture2D.load(path.s3tc)`
returns the block image, `Mesh.surface_get_arrays()` returns arrays, `RenderingServer.mesh_get_surface()` returns
`vertex_data`, `index_data` and `lods` with `edge_length`, and `TextServer.font_get_texture_image()` returns the glyph atlas.
Draw-call counts are the thing that needs a window, not data.
