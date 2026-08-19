# Terrain chunk modifiers — the shared `_chunk_view` preamble

**Source:** `scripts/terrain_manager.gd` (`TerrainManager._chunk_view`, `_apply_road_carve`,
`_apply_pad_flatten`, `_apply_region_blend`, `_apply_edge_taper`, `_apply_height_quantum`,
`bake_track`, `_bake_vertex_block`, `_emit_cliff_offsets`).

**Tests:** `tests/headless/test_terrain_chunk_view.gd`

Split out of [terrain.md](terrain.md) (which stayed on the oversized-doc baseline in
`tests/headless/test_features_docs.gd`) because the five chunk-modifier passes and the
carve-bake split are a self-contained topic: how `compute_chunk_data`'s post-passes agree on
what a chunk needs, and how `bake_track` divides its per-vertex work.

## The chunk modifiers and their shared preamble (`_chunk_view`)

`compute_chunk_data` runs five grid post-passes over the arrays `TerrainChunkBuilder.build()`
just produced, in this order (each ordering rule is argued at the code):

| pass | writes | arrays it needs | coarse (`stride > 1`) grids |
| --- | --- | --- | --- |
| `_apply_road_carve` | `heights`+`vertices`, `COLOR.a`, `UV2.x` | heights, vertices, colors, uv2s | skipped |
| `_apply_pad_flatten` | `heights`+`vertices` | heights, vertices | skipped |
| `_apply_region_blend` | `UV2.y` | uv2s, vertices (**never a height**) | skipped |
| `_apply_edge_taper` | `heights`+`vertices` | heights, vertices | **applied** |
| `_apply_height_quantum` | `heights`+`vertices` | heights, vertices | **applied** |

All five open with the same preamble — unpack the arrays out of the chunk dict, early-out on a
size mismatch, and re-derive the chunk's world rect from `center` and `CHUNK_M`. That preamble
lives once, in `TerrainManager._chunk_view(data, needs) -> bool`, which fills the reused
`_cvw_*` scratch fields (`_cvw_heights` / `_cvw_verts` / `_cvw_colors` / `_cvw_uv2s` /
`_cvw_center` / `_cvw_half` / `_cvw_rect`) and returns `false` when the chunk should be skipped.
Scratch fields rather than a returned Dictionary: on web these passes run per chunk through the
frame-budgeted main-thread build queue, so a per-chunk allocation here would be chunk-rate
garbage on the phones this project targets.

The `needs` bitmask (`VIEW_HEIGHTS` / `VIEW_COLORS` / `VIEW_UV2S` / `VIEW_FULL_RES`) is what
keeps the table's last two columns honest — the five are **not** interchangeable:

- Only the three passes with the "full-res grids only" LOD note pass `VIEW_FULL_RES`. The taper
  and the quantum must keep running on a coarse grid.
- `_apply_region_blend` passes `VIEW_UV2S` *without* `VIEW_HEIGHTS`, so `uv2s` (not `heights`)
  is the array every length is checked against — it reads no height and must not be gated on
  one being present.
- Only `_apply_road_carve` additionally requires `colors` and `uv2s` to match `heights`.

Each pass still owns its own **source** guard at the call site (`pad_source == null`,
`height_quantum <= 0.0`, the `has_method` duck-type checks) — those are about whether the pass
is configured at all, not about whether the chunk is usable. Skip/accept and the world rect are
pinned directly by `tests/headless/test_terrain_chunk_view.gd`.

## How the carve bake is split up

`bake_track` itself now does only the *setup* (segment arrays, camber LUT, spatial hash,
candidate cells, band radii) plus the two outer sweep loops, the progress report and the frame
yield. The per-vertex work of one spatial-hash cell lives in **`_bake_vertex_block(cgx, cgz)`**
(the `Gc × Gc` block of terrain vertices in that cell: nearest-segment search →
`road_heights`/`road_blend` → cliff offset), and the cliff post-pass (morphological open +
emitting the sparse `cliff_offsets`) lives in **`_emit_cliff_offsets()`**. The `await` stays in
`bake_track` on purpose — an `await` inside `_bake_vertex_block` would make it a coroutine per
block. Both read their inputs from the `_cv_*` bake scratch (band radii
`_cv_f_inner`/`_cv_f_outer`/`_cv_outer_sq`, cliff params, vertex-grid geometry
`_cv_vx0`/`_cv_vz0`/`_cv_vw`/`_cv_vh`/`_cv_Gc`, the flat offset field `_cv_off` and its written
bbox `_cv_tv*`), which is valid only during a bake — same lifetime rule as `_nearest_seg`'s
scratch. `_cv_off` is a **member, not a parameter**, because `PackedFloat32Array` is
copy-on-write: passing it in would duplicate the whole field on the first write of every block.

`tests/headless/test_terrain_chunk_view.gd` covers `_chunk_view`, the shared preamble of the
five `_apply_*` chunk modifiers: which chunks are skipped (missing/empty arrays, a size
mismatch in whichever arrays the pass actually needs, `stride != 1` only when `VIEW_FULL_RES`
is asked for) and the derived world rect (a `CHUNK_M` square centred on the chunk's `center`,
in the XZ plane). Bare logic on synthetic chunk dicts — no scene, no generation, sub-second.
