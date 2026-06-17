# Chunked Infinite Terrain — Design

**Date:** 2026-06-16
**Status:** Approved, pending implementation plan

## Goal

Make the terrain infinite in theory but render only the car's immediate
surroundings, by replacing the single fixed 200×200 m terrain tile with a
moving 3×3 grid of terrain chunks that load and unload around the car.

## Key insight

`height_at(x, z)` is already a pure function of absolute world coordinates
(stacked Perlin noise). The terrain is therefore *already* mathematically
infinite — two tiles sampled at the same world position agree on their shared
edge automatically. The only missing piece is that today exactly one fixed tile
around the origin is ever built. The work is to build a moving grid of chunks
instead of one tile.

## Decisions (from brainstorming)

- **Load trigger:** follow the car's position.
- **Chunk grid:** 100 m chunks, 3×3 loaded (radius 1). 0.5 m cells → 201²
  height vertices per chunk (keeps current detail).
- **Border:** removed entirely. With infinite chunks there is always collision
  ground under the car, so the Y=-12 safety wall and the 2000 m visual plane
  become dead weight.

## Components

### 1. `scripts/terrain_manager.gd` (`TerrainManager`, `@tool extends Node3D`)

Replaces the `terrain.gd` script on the scene's `Floor` node. Becomes the single
owner of terrain state and the chunk lifecycle.

- **Constants:** `CHUNK_M = 100.0`, `CELL_M = 0.5`, `SAMPLES = 201`
  (`CHUNK_M / CELL_M + 1`), `RADIUS = 1` (3×3 grid).
- **Exported noise state:** `noise_seed: int`, `layers: Array[TerrainLayer]`,
  `texture_tile_per_meter: float`. Setters trigger a rebuild of currently
  loaded chunks (and reconnect layer `changed` signals), preserving today's
  live-tuning behavior.
- **`height_at(x, z) -> float`:** moved here from `terrain.gd` — the single
  source of terrain height. Chunks call it; tests call it.
- **`_make_noise(layer_index)` / noise caching:** as today, the manager builds
  one `FastNoiseLite` per valid layer for batch sampling.
- **Chunk tracking:** a `Dictionary` keyed by `Vector2i(cx, cz)` → `TerrainChunk`.
- **`_process`:** compute the car's chunk coord
  `Vector2i(floor(car.x / CHUNK_M), floor(car.z / CHUNK_M))`. When it changes
  from the last seen coord, reconcile: instantiate any of the 3×3 target chunks
  not already present, and free loaded chunks outside the radius. Only the new
  row/column is built on a crossing (≤3 chunks), not all 9.
- **Car reference:** resolved from the scene (e.g. an exported `NodePath` or a
  lookup of the `Car` node). Null-safe so headless tests can drive it directly.
- **Editor preview:** when not running (`Engine.is_editor_hint()` and no car),
  build the 3×3 grid centered on origin so designers still get live visual
  feedback when tuning layers/seed/tiling.

### 2. `scripts/terrain_chunk.gd` (`TerrainChunk`, `@tool extends StaticBody3D`)

Created at runtime by the manager — one node per loaded chunk. Not present in
the scene file.

- Constructed with a reference to the manager and a chunk coord `(cx, cz)`.
- Positions itself at world origin `(cx · CHUNK_M, 0, cz · CHUNK_M)`.
- **`build()`:** fills a `SAMPLES²` height array by sampling
  `manager.height_at(worldX, worldZ)` where `worldX = origin.x + xi · CELL_M`,
  then builds the mesh (local coords, lifted from today's `_build_mesh`) and a
  `HeightMapShape3D` collision (lifted from `_build_collision`, same 0.5 m cell
  scale).
- **UVs use world coordinates × `texture_tile_per_meter`** so the checker
  texture stays continuous across chunk seams.
- Uses the existing `ps1_models.gdshader` / floor material.

### 3. `scripts/world.gd`

- Apply `GameConfig` layers and `terrain_tile_per_meter` to the **manager**
  (currently `$Floor`) instead of the old single tile; trigger a rebuild of
  loaded chunks when they change (same `_layers_match` guard).
- **Delete** the `Border` block (visual-plane tiling setup).

### 4. `main.tscn`

- `Floor` node: now the `TerrainManager` (`Node3D` with `terrain_manager.gd`);
  its `MeshInstance3D` / `CollisionShape3D` children are removed since chunks
  are runtime children. The floor material moves to a resource the chunks
  reference.
- **Remove** the `Border` node, its mesh, material, and collision shape.

## Data flow

1. `world.gd` pushes `GameConfig` → `TerrainManager` (seed/layers/tiling).
2. Each frame `TerrainManager._process` reads the car position, computes its
   chunk coord, and reconciles the loaded 3×3 set.
3. Each new `TerrainChunk` samples `manager.height_at` over its 201² grid and
   builds mesh + collision; freed chunks are `queue_free`d.

## Trade-offs

- **Boundary-crossing cost:** a crossing rebuilds only the new row/column
  (≤3 chunks ≈120k verts) synchronously in one frame — a possible brief hiccup.
  Builds stay synchronous (YAGNI); threaded/background generation is the obvious
  future upgrade if it stutters in practice.
- **Fog tuning:** the far chunk edge is 100–200 m out. If chunks visibly pop in,
  `fog_density` in `config/game_config.tres` needs a nudge. Verify visually;
  do not change config unless popping is visible.

## Testing

- `tests/headless/test_terrain.gd`:
  - Update existing `height_at` / seed-determinism checks to target the manager.
  - **Seam test:** adjacent chunk coords sample identical heights along their
    shared edge.
  - **Load/unload test:** focusing on a point yields exactly the 3×3 chunks
    around it; moving the focus frees out-of-radius chunks and loads new ones.
- `tests/headless/test_smoke.gd`: update for the removed `Border` node and the
  new manager/chunk structure.
- `features/terrain.md`: rewrite for the chunked model.
- Run `./run_tests.sh` (background) until all green before declaring done.
