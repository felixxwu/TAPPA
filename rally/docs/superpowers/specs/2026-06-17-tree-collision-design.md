# Tree collision hitboxes — design

## Goal

Give each scattered tree a solid collision hitbox so the car collides with
trees instead of driving through them.

## Approach

`TreeField` (the `MultiMeshInstance3D` that renders the trees) gains a child
`StaticBody3D` that holds the hitboxes. Instead of one `CollisionShape3D` node
per tree (thousands of nodes), a **single shared `BoxShape3D` resource is
instanced per tree** via the low-level physics server:

```
PhysicsServer3D.body_add_shape(static_body.get_rid(), box.get_rid(), transform)
```

One shape resource, N per-instance transforms — minimal node/memory overhead,
built once at startup alongside the MultiMesh. The `BoxShape3D` is held as a
member of `TreeField` so its RID outlives `build()` for the body's lifetime;
freeing the field frees the `StaticBody3D` and its shapes with it.

## Components

### `scripts/tree_field.gd` (`class_name TreeField`)

`build()` gains two parameters and now also builds collision:

```
func build(positions: PackedVector2Array, floor: TerrainManager, size: Vector2,
        collision_radius: float, collision_height: float) -> void
```

- Builds the MultiMesh exactly as today (visual unchanged).
- Creates a child `StaticBody3D` (named `Collision`).
- Creates one `BoxShape3D` with
  `size = Vector3(2*collision_radius, collision_height, 2*collision_radius)`,
  stored as a member (`_collision_shape`).
- For each position, adds the shape to the body at
  `Transform3D(Basis.IDENTITY, Vector3(x, floor.height_at(x,z) + collision_height/2, z))`
  so the box rests on the ground.
- If `positions` is empty, the body is still added but holds zero shapes.

### Collision layers

The `StaticBody3D` stays on the default `collision_layer = 1`, matching
`TerrainChunk` (which extends `StaticBody3D` with default layers). The car
already collides with the terrain on that layer, so no car change is needed.

### `scripts/world.gd`

`_generate_track()` passes the two new knobs into `field.build(...)`:

```
field.build(trees, $Floor as TerrainManager, cfg.tree_size_m,
    cfg.tree_collision_radius_m, cfg.tree_collision_height_m)
```

## Configuration — new knobs in the `Trees` group

| Knob | Type | Meaning | Default |
|------|------|---------|---------|
| `tree_collision_radius_m` | float | box half-extent in X/Z (square trunk footprint) | 0.5 |
| `tree_collision_height_m` | float | box height (m) | 4.0 |

## Tests — `tests/headless/test_smoke.gd`

Extend the existing `test_tree_field_builds_one_instance_per_position` (or add a
sibling test):

- After `build` with N positions, the field has a `StaticBody3D` child, and
  `PhysicsServer3D.body_get_shape_count(body.get_rid()) == N`.
- Spot-check one shape: `PhysicsServer3D.body_get_shape_transform(rid, i).origin`
  equals the expected `(x, height_at + collision_height/2, z)` for that index
  (within a small epsilon).

## Docs

Update `features/trees.md`: add a "Collision" subsection describing the shared
`BoxShape3D` instanced via `PhysicsServer3D`, the `Collision` static body, and
the two new knobs.

## Notes / scope

- Hitboxes are static and solid; trees do not move or fall when hit (YAGNI —
  no knock-down behaviour).
- Box count scales with `trees_per_turn × turns` (after rejection); with high
  `trees_per_turn` this can be ~1–2k boxes. Static boxes are cheap in the
  broadphase and the PhysicsServer setup is one-time, so this is acceptable.
