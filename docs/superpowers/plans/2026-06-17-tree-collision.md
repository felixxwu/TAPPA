# Tree Collision Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give each scattered tree a solid box collision hitbox so the car collides with trees.

**Architecture:** `TreeField` gains a child `StaticBody3D` whose hitboxes are a single shared `BoxShape3D` resource instanced once per tree via `PhysicsServer3D.body_add_shape(body_rid, shape_rid, transform)` — one shape, N transforms, built at startup with the MultiMesh. Two new `GameConfig` knobs size the box.

**Tech Stack:** Godot 4 / GDScript, GUT tests. Existing: `TreeField` (`scripts/tree_field.gd`), `TerrainManager.height_at(x,z)`, `GameConfig`/`config/game_config.tres`, `scripts/world.gd._generate_track()`.

## Global Constraints

- This project is NOT under git — do NOT run git commands. "Commit" steps are no-ops; skip them.
- Godot binary: `/Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot` (override `$GODOT`).
- Run tests with `./run_tests.sh --fast <name>` (subset) or `./run_tests.sh` (full), ALWAYS `run_in_background: true`; never block. Full suite only as the final check. Never start a run while another `gut_cmdln` run is active.
- All tunables live in `config/game_config.tres` — never hardcode them in scripts.
- Terrain bodies (`TerrainChunk`) use Godot's default `collision_layer = 1`; the tree static body must stay on layer 1 so the car (which already collides with terrain) collides with trees too.
- Update `features/trees.md` in the same work.

---

### Task 1: Box hitboxes in `TreeField` + config knobs + wiring

**Files:**
- Modify: `scripts/tree_field.gd` (extend `build()` with collision)
- Modify: `scripts/game_config.gd` (two knobs in the `Trees` group, ~after `tree_size_m`)
- Modify: `config/game_config.tres` (set the two knobs)
- Modify: `scripts/world.gd` (`_generate_track`, pass the knobs to `field.build`)
- Modify: `tests/headless/test_smoke.gd` (extend the TreeField test)

**Interfaces:**
- Consumes: `TerrainManager.height_at(x,z) -> float`; `GameConfig` knobs.
- Produces: `TreeField.build(positions: PackedVector2Array, floor: TerrainManager, size: Vector2, collision_radius: float, collision_height: float) -> void` — builds the MultiMesh (unchanged) plus a child `StaticBody3D` named `Collision` holding one box shape per position. `GameConfig.tree_collision_radius_m: float`, `GameConfig.tree_collision_height_m: float`.

- [ ] **Step 1: Update the failing smoke test**

Replace the existing `test_tree_field_builds_one_instance_per_position` in `tests/headless/test_smoke.gd` with the version below (adds the new `build` args, asserts shape count, and spot-checks one shape transform):

```gdscript
func test_tree_field_builds_one_instance_per_position() -> void:
	var floor := _scene.get_node("Floor") as TerrainManager
	var field := TreeField.new()
	add_child_autofree(field)
	var positions := PackedVector2Array([Vector2(10, 10), Vector2(20, 12), Vector2(-5, 8)])
	field.build(positions, floor, Vector2(4, 6), 0.5, 4.0)
	assert_not_null(field.multimesh, "field has a MultiMesh")
	assert_eq(field.multimesh.instance_count, positions.size(),
		"one instance per scattered position")
	# Collision: one box shape per tree on a StaticBody3D child.
	var body := field.get_node_or_null("Collision") as StaticBody3D
	assert_not_null(body, "field has a Collision StaticBody3D child")
	var rid := body.get_rid()
	assert_eq(PhysicsServer3D.body_get_shape_count(rid), positions.size(),
		"one box shape per tree")
	assert_eq(body.collision_layer, 1, "tree body on layer 1 like terrain")
	# Spot-check the first shape: box centred at (x, ground + height/2, z).
	var p := positions[0]
	var expected_y := floor.height_at(p.x, p.y) + 4.0 / 2.0
	var origin := PhysicsServer3D.body_get_shape_transform(rid, 0).origin
	assert_almost_eq(origin, Vector3(p.x, expected_y, p.y), Vector3(1e-3, 1e-3, 1e-3),
		"box rests on the ground at the tree position")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `./run_tests.sh --fast smoke` (background). Expected: FAIL — `build()` takes 3 args, not 5 / no `Collision` child.

- [ ] **Step 3: Add collision to `TreeField.build`**

In `scripts/tree_field.gd`, add a member to hold the shared shape alive and extend `build`. Full new file body:

```gdscript
class_name TreeField
extends MultiMeshInstance3D
# Renders scattered tree positions as cylindrical billboards in a single
# MultiMesh (one draw call). Each instance is lifted onto the terrain via
# TerrainManager.height_at; the quad pivot is its bottom edge so trunks sit on
# the ground. A child StaticBody3D carries one box hitbox per tree, all sharing
# a single BoxShape3D resource instanced via the physics server.

const BILLBOARD_SHADER := preload("res://shaders/billboard.gdshader")
const TREE_TEXTURE := preload("res://textures/tree.png")

# Held so the shape RID added to the body via PhysicsServer3D stays alive for
# the body's lifetime.
var _collision_shape: BoxShape3D


func build(positions: PackedVector2Array, floor: TerrainManager, size: Vector2,
		collision_radius: float, collision_height: float) -> void:
	var quad := QuadMesh.new()
	quad.size = size
	# Shift the quad up by half its height so its pivot is the bottom edge.
	quad.center_offset = Vector3(0.0, size.y * 0.5, 0.0)

	var mat := ShaderMaterial.new()
	mat.shader = BILLBOARD_SHADER
	mat.set_shader_parameter("albedo", TREE_TEXTURE)
	quad.surface_set_material(0, mat)

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = quad
	mm.instance_count = positions.size()

	# One StaticBody3D holds every tree hitbox; all share one BoxShape3D resource
	# instanced per tree with its own transform (cheap: one shape, N transforms).
	var body := StaticBody3D.new()
	body.name = "Collision"
	add_child(body)
	_collision_shape = BoxShape3D.new()
	_collision_shape.size = Vector3(collision_radius * 2.0, collision_height, collision_radius * 2.0)

	for i in positions.size():
		var p := positions[i]
		var y := floor.height_at(p.x, p.y)
		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, Vector3(p.x, y, p.y)))
		# Box centred half its height above the ground so it rests on the surface.
		var box_xform := Transform3D(Basis.IDENTITY, Vector3(p.x, y + collision_height * 0.5, p.y))
		PhysicsServer3D.body_add_shape(body.get_rid(), _collision_shape.get_rid(), box_xform)

	multimesh = mm
```

- [ ] **Step 4: Add the config knobs**

In `scripts/game_config.gd`, immediately after the `tree_size_m` export in the `Trees` group, add:

```gdscript
## Half-extent (m) in X/Z of each tree's box hitbox — a square trunk footprint.
@export_range(0.05, 5.0) var tree_collision_radius_m := 0.5
## Height (m) of each tree's box hitbox.
@export_range(0.5, 20.0) var tree_collision_height_m := 4.0
```

- [ ] **Step 5: Set the knobs in the resource**

In `config/game_config.tres`, add inside the `[resource]` block (alongside the other `tree_*` lines):

```
tree_collision_radius_m = 0.5
tree_collision_height_m = 4.0
```

- [ ] **Step 6: Pass the knobs from `world.gd`**

In `scripts/world.gd._generate_track`, update the `field.build(...)` call:

```gdscript
	field.build(trees, $Floor as TerrainManager, cfg.tree_size_m,
		cfg.tree_collision_radius_m, cfg.tree_collision_height_m)
```

- [ ] **Step 7: Run the smoke subset to verify it passes**

Run: `./run_tests.sh --fast smoke` (background). Expected: PASS, no SCRIPT ERROR / Parse Error.

- [ ] **Step 8: Commit** — skip (project not under git).

---

### Task 2: Documentation

**Files:**
- Modify: `features/trees.md` (add a Collision subsection + the two knobs)

- [ ] **Step 1: Add a Collision subsection**

In `features/trees.md`, after the "Rendering (`TreeField`)" section, add:

```markdown
## Collision (`TreeField`)

`TreeField` also builds a child `StaticBody3D` named `Collision` holding one box
hitbox per tree. All boxes share a single `BoxShape3D` resource (held on the
field as `_collision_shape`) instanced via
`PhysicsServer3D.body_add_shape(body_rid, shape_rid, transform)` — one shape, N
transforms, so thousands of trees add negligible node/memory overhead. Each box
is `2*tree_collision_radius_m` wide (square footprint), `tree_collision_height_m`
tall, and centred half its height above the ground so it rests on the surface.
The body stays on `collision_layer = 1` like `TerrainChunk`, so the car collides
with trees the same way it collides with the ground.
```

- [ ] **Step 2: Add the knobs to the Configuration section**

In `features/trees.md`, extend the `Trees` group knob list to include
`tree_collision_radius_m` (box half-extent in X/Z) and `tree_collision_height_m`
(box height).

- [ ] **Step 3: Commit** — skip.

---

### Task 3: Final verification

- [ ] **Step 1: Run the full suite**

Run: `./run_tests.sh` (background, `run_in_background: true`). Wait for the completion notification.
Expected: ALL tests pass, no `SCRIPT ERROR` / `Parse Error` / `Failed to load script`. If anything fails, treat the new code as the prime suspect (per CLAUDE.md) and fix it — do not weaken assertions.
