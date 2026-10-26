# Terrain — how `bake_track` splits its per-vertex work

**Source:** `scripts/terrain_manager.gd` (`TerrainManager.bake_track`, `_bake_vertex_block`, `_emit_cliff_offsets`).

**Tests:** `tests/headless/test_terrain_digest.gd`, `tests/headless/test_terrain_cliffs.gd`

Split out of [terrain.md](terrain.md) as a self-contained topic. `compute_chunk_data` has no
post-passes: it is just `TerrainChunkBuilder.build()`.

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
