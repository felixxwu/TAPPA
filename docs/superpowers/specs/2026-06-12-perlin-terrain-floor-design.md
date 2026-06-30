# Perlin Noise Terrain Floor — Design

Date: 2026-06-12

## Goal

Replace the flat 200×200m BoxMesh floor in `main.tscn` with a generated terrain mesh whose heights come from stacked Perlin noise layers. Gentle rolling feel: fully drivable with the car's ~0.25m suspension travel.

## Architecture

A new `scripts/terrain.gd` (`@tool`, attached to the existing `Floor` StaticBody3D node) generates everything at `_ready` (and in-editor):

1. **Height field:** 401×401 samples on a 0.5m grid covering 200×200m, centered on the origin. Height at each point = sum over all noise layers of `noise.get_noise_2d(x, z) * amplitude`. Deterministic via an exported `seed`.
2. **Visual mesh:** one `ArrayMesh` surface built with `SurfaceTool` — positions, computed smooth normals, and UVs matching the current checker tiling. Assigned to the child `MeshInstance3D`, keeping the existing `mat_floor` PS1 shader material.
3. **Collision:** `HeightMapShape3D` built from the same height array, assigned to the child `CollisionShape3D`. Visuals and physics match exactly.

## Noise layers

Exported array of layer configs (Resource or Dictionary entries: `FastNoiseLite` + `amplitude`), editable in the Inspector; defaults built in code so adding a layer is one line:

| Layer | Wavelength (~) | Amplitude |
|-------|----------------|-----------|
| Base rolling hills | 60 m | 1.5 m |
| Mid undulation | 15 m | 0.4 m |
| Detail bumps | 3 m | 0.1 m |

All layers use `FastNoiseLite.TYPE_PERLIN`, fractal disabled (each layer is a single frequency; stacking is explicit).

## Scene changes

- Remove `mesh_floor` (BoxMesh) and `shape_floor` (BoxShape3D) sub-resources; remove the Floor node's `-0.5` y-offset.
- Attach `terrain.gd` to the Floor node.
- Car spawn: script (or main scene setup) samples terrain height at the spawn position and places the car at height + clearance so it never spawns inside a hill.

## Out of scope

- Tests (deferred at user request).
- Chunking/LOD — single mesh is fine at this size.
