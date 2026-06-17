# Bushes — design

## Goal

Scatter bush billboards around track turns that behave exactly like trees —
same scatter logic, same render-distance dissolve, same per-turn placement —
but using `textures/bush.webp` and with **no collision hitbox**.

## Approach

`TreeField` is generalised into a texture-agnostic, optionally-collidable
`BillboardField` and reused for both trees and bushes. `TreeScatter` is already
generic (it just returns positions around turns) and is reused unchanged with a
different seed for bushes. Bushes reuse every `tree_*` config value — they
differ only by texture, the absence of collision, and the scatter seed.

## Components

### `scripts/billboard_field.gd` (`class_name BillboardField`, renamed from `TreeField`)

Rename `scripts/tree_field.gd` → `scripts/billboard_field.gd`, class
`TreeField` → `BillboardField`. The hardcoded `TREE_TEXTURE` preload is removed;
the texture is passed in. `build` gains a `texture` parameter and a
`with_collision: bool` flag:

```
func build(positions: PackedVector2Array, floor: TerrainManager, size: Vector2,
        texture: Texture2D, collision_radius: float, collision_height: float,
        with_collision: bool, render_distance: float, render_fade: float) -> void
```

- Material `albedo` is set to `texture`.
- When `with_collision` is true: build the `Collision` `StaticBody3D` + shared
  `BoxShape3D` exactly as today.
- When `with_collision` is false: skip the body entirely (no `Collision` child,
  `_collision_shape` stays null).

`BILLBOARD_SHADER` preload stays; `TREE_TEXTURE` preload is deleted.

### `scripts/world.gd`

`_generate_track` builds two fields from `TreeScatter`, both with the same
`tree_*` knobs:

```gdscript
var road_cells := TrackGenerator.rasterize_cells(
    (result["centerline"] as Curve2D).tessellate(),
    cfg.track_width + 2.0 * cfg.tree_road_margin_m)

# Trees: collision, tree.png, seed track_seed.
var trees := TreeScatter.scatter(result["pieces"], road_cells, cfg.tree_params(), cfg.track_seed)
var tree_field := BillboardField.new()
add_child(tree_field)
tree_field.build(trees, $Floor, cfg.tree_size_m, TREE_TEXTURE,
    cfg.tree_collision_radius_m, cfg.tree_collision_height_m, true,
    cfg.tree_render_distance_m, cfg.tree_render_fade_m)

# Bushes: no collision, bush.webp, different seed so positions differ.
var bushes := TreeScatter.scatter(result["pieces"], road_cells, cfg.tree_params(), cfg.track_seed + BUSH_SEED_OFFSET)
var bush_field := BillboardField.new()
add_child(bush_field)
bush_field.build(bushes, $Floor, cfg.tree_size_m, BUSH_TEXTURE,
    cfg.tree_collision_radius_m, cfg.tree_collision_height_m, false,
    cfg.tree_render_distance_m, cfg.tree_render_fade_m)
```

`world.gd` gains preloads `TREE_TEXTURE := preload("res://textures/tree.png")`,
`BUSH_TEXTURE := preload("res://textures/bush.webp")`, and a constant
`BUSH_SEED_OFFSET := 1013` (any fixed non-zero offset; keeps bushes deterministic
but offset from the trees).

### Configuration

No new knobs. Bushes reuse all `tree_*` values (count, spawn radius, road
margin, min spacing, retries, size, render distance/fade). The collision knobs
are still passed to the bush field but ignored because `with_collision` is false.

(Bushes are therefore the same billboard size as trees. A separate `bush_size_m`
is intentionally out of scope; easy to add later.)

## Tests — `tests/headless/test_smoke.gd`

- Rename the existing `TreeField` test to use `BillboardField`; update the
  `build` call to the new signature with `TREE_TEXTURE`/`true`. Keep the
  shape-count, layer, transform, and render-distance-param assertions.
- Add a test: a `BillboardField` built with `with_collision = false` has
  `multimesh.instance_count == positions.size()` and **no** `Collision` child
  (`get_node_or_null("Collision") == null`).
- `test_shaders_load_with_code` already covers the shared shader.

## Docs

- `features/trees.md`: rename the renderer references to `BillboardField`, add a
  "Bushes" subsection (same scatter + render-distance as trees, `bush.webp`, no
  hitbox, offset seed), and note the rename.
- `features/README.md`: update the file-map rows that referenced
  `scripts/tree_field.gd` to `scripts/billboard_field.gd`.
