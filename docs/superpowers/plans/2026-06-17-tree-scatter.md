# Tree Scatter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After track generation, scatter a configurable number of billboard tree sprites (`tree.png`) in a radius around each turn, rejecting positions too close to the road or to another tree, with bounded retries.

**Architecture:** A pure headless module (`TreeScatter`) picks 2D world-XZ positions from the `TrackGenerator` result (seeded, deterministic). A `MultiMeshInstance3D` subclass (`TreeField`) renders them as cylindrical billboards via a custom shader, lifted onto the terrain. `world.gd` wires scatter → field after the track is baked. Knobs live in `GameConfig`.

**Tech Stack:** Godot 4 / GDScript, GUT for tests. Existing pieces: `TrackGenerator` (cells on a 0.5 m grid, `CELL_M = 0.5`), `TerrainManager.height_at(x,z)`, `GameConfig` + `config/game_config.tres`.

## Global Constraints

- This project is NOT under git — do NOT run git commands. The "Commit" steps below are no-ops; skip them.
- Godot binary: `/Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot` (override `$GODOT`).
- Run tests with `./run_tests.sh` (full) or `./run_tests.sh --fast <name>` (subset), ALWAYS in the background (`run_in_background: true`); never block on them. Use `--fast tree_scatter` during iteration; full suite only as the final check.
- All tuning values live in `config/game_config.tres` — never hardcode tunables in scripts.
- World-XZ plane maps `x → world x`, `y → world z`, same as `TrackGenerator`.
- Track cells are `Vector2i` keys on a 0.5 m grid; cell centre = `Vector2((cell.x + 0.5) * 0.5, (cell.y + 0.5) * 0.5)`. Reference `TrackGenerator.CELL_M`, do not re-define 0.5.
- Update `features/` docs in the same work (new `features/trees.md` + `features/README.md` index entry).

---

### Task 1: `TreeScatter` placement module

**Files:**
- Create: `scripts/tree_scatter.gd`
- Test: `tests/headless/test_tree_scatter.gd`

**Interfaces:**
- Consumes: `TrackGenerator` result — `pieces: Array` (each a Dictionary with `"cells": Array[Vector2i]`) and `cells: Dictionary` (Vector2i → true).
- Produces:
  - `static func scatter(pieces: Array, occupied: Dictionary, params: Dictionary, seed: int) -> PackedVector2Array`
  - `static func turn_anchor(piece: Dictionary) -> Vector2` (centroid of piece cell centres, world XZ)
  - `params` keys: `trees_per_turn:int`, `spawn_radius_m:float`, `min_road_dist_m:float`, `min_tree_dist_m:float`, `max_retries:int`.

- [ ] **Step 1: Write the failing tests**

```gdscript
# tests/headless/test_tree_scatter.gd
extends GutTest
# TreeScatter: picks deterministic 2D world-XZ tree positions around each track
# turn, rejecting candidates too close to the road (occupied cells) or to an
# already-placed tree, with bounded retries.

const TreeScatter = preload("res://scripts/tree_scatter.gd")
const TrackGenerator = preload("res://scripts/track_generator.gd")

const PARAMS := {
	"trees_per_turn": 10,
	"spawn_radius_m": 25.0,
	"min_road_dist_m": 6.0,
	"min_tree_dist_m": 4.0,
	"max_retries": 8,
}

# A small straight track far from the origin gives a known cell set + anchor.
func _track() -> Dictionary:
	return TrackGenerator.generate(Vector2(0, 0), Vector2(0, 1), 3, 6, 6.0, 8.0)

func test_turn_anchor_is_centroid_of_cell_centres() -> void:
	var piece := { "cells": [Vector2i(0, 0), Vector2i(0, 2)] }
	# centres: (0.25,0.25) and (0.25,1.25) -> mean (0.25,0.75)
	assert_almost_eq(TreeScatter.turn_anchor(piece), Vector2(0.25, 0.75),
		Vector2(1e-4, 1e-4), "anchor is mean of cell centres")

func test_deterministic_for_same_seed() -> void:
	var t := _track()
	var a := TreeScatter.scatter(t["pieces"], t["cells"], PARAMS, 42)
	var b := TreeScatter.scatter(t["pieces"], t["cells"], PARAMS, 42)
	assert_eq(a, b, "same seed -> identical positions")

func test_different_seed_differs() -> void:
	var t := _track()
	var a := TreeScatter.scatter(t["pieces"], t["cells"], PARAMS, 1)
	var b := TreeScatter.scatter(t["pieces"], t["cells"], PARAMS, 2)
	assert_ne(a, b, "different seed -> different positions")

func test_respects_road_clearance() -> void:
	var t := _track()
	var trees := TreeScatter.scatter(t["pieces"], t["cells"], PARAMS, 7)
	assert_gt(trees.size(), 0, "should place some trees")
	for pos in trees:
		for cell in t["cells"]:
			var centre := Vector2((cell.x + 0.5) * TrackGenerator.CELL_M, (cell.y + 0.5) * TrackGenerator.CELL_M)
			assert_gte(pos.distance_to(centre), PARAMS["min_road_dist_m"],
				"tree must be >= min_road_dist_m from every track cell")

func test_respects_tree_spacing() -> void:
	var t := _track()
	var trees := TreeScatter.scatter(t["pieces"], t["cells"], PARAMS, 7)
	for i in trees.size():
		for j in range(i + 1, trees.size()):
			assert_gte(trees[i].distance_to(trees[j]), PARAMS["min_tree_dist_m"],
				"trees must be >= min_tree_dist_m apart")

func test_within_spawn_radius_of_some_anchor() -> void:
	var t := _track()
	var trees := TreeScatter.scatter(t["pieces"], t["cells"], PARAMS, 7)
	var anchors: Array[Vector2] = []
	for piece in t["pieces"]:
		anchors.append(TreeScatter.turn_anchor(piece))
	for pos in trees:
		var ok := false
		for anchor in anchors:
			if pos.distance_to(anchor) <= PARAMS["spawn_radius_m"]:
				ok = true
				break
		assert_true(ok, "tree must be within spawn_radius_m of some anchor")

func test_count_bound() -> void:
	var t := _track()
	var trees := TreeScatter.scatter(t["pieces"], t["cells"], PARAMS, 7)
	assert_lte(trees.size(), PARAMS["trees_per_turn"] * t["pieces"].size(),
		"count <= trees_per_turn * turns")

func test_impossible_constraints_return_quickly() -> void:
	var t := _track()
	var hard := PARAMS.duplicate()
	hard["spawn_radius_m"] = 0.5      # tiny disc, all inside the road buffer
	hard["min_road_dist_m"] = 100.0   # nothing can be far enough
	var trees := TreeScatter.scatter(t["pieces"], t["cells"], hard, 7)
	assert_eq(trees.size(), 0, "impossible constraints place nothing, no hang")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./run_tests.sh --fast tree_scatter` (background). Expected: FAIL — `tree_scatter.gd` does not exist / `TreeScatter` not found.

- [ ] **Step 3: Implement `TreeScatter`**

```gdscript
# scripts/tree_scatter.gd
class_name TreeScatter
# Scatters billboard-tree positions around each track turn. Pure + headless +
# seeded (mirrors TrackGenerator). Works in the world-XZ plane (x -> world x,
# y -> world z). Rejects candidates too close to the road (occupied track cells)
# or to an already-placed tree, retrying up to max_retries before skipping.

const CELL_M := TrackGenerator.CELL_M  # 0.5 m track cell grid


# Centroid of a piece's rasterized cells, in world XZ.
static func turn_anchor(piece: Dictionary) -> Vector2:
	var cells: Array = piece["cells"]
	var sum := Vector2.ZERO
	for cell in cells:
		sum += Vector2((cell.x + 0.5) * CELL_M, (cell.y + 0.5) * CELL_M)
	return sum / float(maxi(cells.size(), 1))


# True if `p` is within `min_road_dist` of any occupied cell's centre. Scans
# only the box of cells that could be in range, so cost is independent of track
# length.
static func _near_road(p: Vector2, occupied: Dictionary, min_road_dist: float) -> bool:
	var reach := int(ceil(min_road_dist / CELL_M)) + 1
	var cx := floori(p.x / CELL_M)
	var cz := floori(p.y / CELL_M)
	for dz in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			var cell := Vector2i(cx + dx, cz + dz)
			if occupied.has(cell):
				var centre := Vector2((cell.x + 0.5) * CELL_M, (cell.y + 0.5) * CELL_M)
				if p.distance_to(centre) < min_road_dist:
					return true
	return false


static func scatter(pieces: Array, occupied: Dictionary, params: Dictionary, seed: int) -> PackedVector2Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed + 0x7EE  # offset so trees don't visually track corner choices
	var trees := PackedVector2Array()
	var per_turn: int = params["trees_per_turn"]
	var radius: float = params["spawn_radius_m"]
	var min_road: float = params["min_road_dist_m"]
	var min_tree: float = params["min_tree_dist_m"]
	var max_retries: int = params["max_retries"]
	for piece in pieces:
		var anchor := turn_anchor(piece)
		for _t in per_turn:
			for _attempt in (max_retries + 1):
				# Uniform-in-disc sample.
				var r := radius * sqrt(rng.randf())
				var theta := rng.randf() * TAU
				var cand := anchor + Vector2(cos(theta), sin(theta)) * r
				if _near_road(cand, occupied, min_road):
					continue
				var clash := false
				for placed in trees:
					if cand.distance_to(placed) < min_tree:
						clash = true
						break
				if clash:
					continue
				trees.append(cand)
				break  # placed this tree; move to the next
	return trees
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./run_tests.sh --fast tree_scatter` (background). Expected: all `test_tree_scatter` tests PASS, no SCRIPT ERROR.

- [ ] **Step 5: Commit** — skip (project not under git).

---

### Task 2: Config knobs (`Trees` group)

**Files:**
- Modify: `scripts/game_config.gd` (add `Trees` group after the `Track` group, ~line 249; add `tree_params()` helper near `terrain_layers()`, ~line 300)
- Modify: `config/game_config.tres` (add tree values to `[resource]`)

**Interfaces:**
- Produces: `GameConfig.tree_params() -> Dictionary` with keys `trees_per_turn`, `spawn_radius_m`, `min_road_dist_m`, `min_tree_dist_m`, `max_retries` (the exact keys `TreeScatter.scatter` reads), plus exported `tree_size_m: Vector2`.

- [ ] **Step 1: Add the exported knobs**

In `scripts/game_config.gd`, immediately after the `track_transition_cells` export (line 249), add:

```gdscript


@export_group("Trees")
## Billboard tree sprites scattered around each track turn.
## Placement attempts (and max trees) per turn.
@export_range(0, 100) var trees_per_turn := 12
## Radius, in metres, of the disc around each turn anchor that trees spawn in.
@export_range(1.0, 100.0) var tree_spawn_radius_m := 25.0
## Minimum distance, in metres, a tree must keep from any track cell.
@export_range(0.0, 30.0) var tree_min_road_dist_m := 6.0
## Minimum spacing, in metres, between any two trees.
@export_range(0.0, 30.0) var tree_min_tree_dist_m := 4.0
## Retries per tree before that tree is skipped (placement bounded by this).
@export_range(0, 50) var tree_max_retries := 8
## Billboard size in metres: width (x) by height (y). Pivot is the bottom edge.
@export var tree_size_m := Vector2(4.0, 6.0)
```

- [ ] **Step 2: Add the `tree_params()` helper**

In `scripts/game_config.gd`, after `terrain_layers()` (line 306), add:

```gdscript


# The scalar tree-scatter knobs packed into the Dictionary TreeScatter.scatter
# expects. tree_size_m is rendering-only and passed separately to TreeField.
func tree_params() -> Dictionary:
	return {
		"trees_per_turn": trees_per_turn,
		"spawn_radius_m": tree_spawn_radius_m,
		"min_road_dist_m": tree_min_road_dist_m,
		"min_tree_dist_m": tree_min_tree_dist_m,
		"max_retries": tree_max_retries,
	}
```

- [ ] **Step 3: Set values in the resource**

In `config/game_config.tres`, add these lines inside the `[resource]` block (anywhere after `script = ExtResource("1")`, alongside the other overrides):

```
trees_per_turn = 12
tree_spawn_radius_m = 25.0
tree_min_road_dist_m = 6.0
tree_min_tree_dist_m = 4.0
tree_max_retries = 8
tree_size_m = Vector2(4, 6)
```

- [ ] **Step 4: Verify config loads**

Run: `./run_tests.sh --fast tree_scatter` (background). Expected: still PASS, no SCRIPT ERROR / Parse Error (confirms `game_config.gd` and the `.tres` still parse).

- [ ] **Step 5: Commit** — skip.

---

### Task 3: Billboard shader

**Files:**
- Create: `shaders/billboard.gdshader`

**Interfaces:**
- Produces: a spatial shader with a `uniform sampler2D albedo` (the tree texture). Cylindrical billboard (rotates around world Y; stays upright). Alpha-scissor cutout. Unshaded.

- [ ] **Step 1: Write the shader**

```glsl
// shaders/billboard.gdshader
// Cylindrical billboard: each instanced quad yaws to face the camera but stays
// upright (world Y up). Alpha-scissor cutout for crisp edges, no blend sorting.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform sampler2D albedo : source_color, filter_nearest;
uniform float alpha_scissor : hint_range(0.0, 1.0) = 0.5;

void vertex() {
	// Per-instance world origin (column 3 of the model matrix).
	vec3 origin = MODEL_MATRIX[3].xyz;
	// Direction from the instance to the camera, flattened to the XZ plane.
	vec3 to_cam = (INV_VIEW_MATRIX[3].xyz - origin);
	to_cam.y = 0.0;
	to_cam = normalize(to_cam);
	vec3 up = vec3(0.0, 1.0, 0.0);
	vec3 right = normalize(cross(up, to_cam));
	// Preserve the instance's authored scale (quad is built 1x1, scaled by MODEL).
	float sx = length(MODEL_MATRIX[0].xyz);
	float sy = length(MODEL_MATRIX[1].xyz);
	vec3 world_pos = origin + right * (VERTEX.x * sx) + up * (VERTEX.y * sy);
	// Rewrite to view space; MODELVIEW is bypassed by going straight to VIEW.
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world_pos, 1.0);
}

void fragment() {
	vec4 tex = texture(albedo, UV);
	if (tex.a < alpha_scissor) {
		discard;
	}
	ALBEDO = tex.rgb;
}
```

Note: writing `POSITION` directly in `vertex()` is the supported Godot 4 way to fully control clip-space placement; `MODELVIEW`-based output is bypassed.

- [ ] **Step 2: Verify it compiles**

This is verified indirectly in Task 4 (TreeField loads the shader); no standalone test. Proceed.

- [ ] **Step 3: Commit** — skip.

---

### Task 4: `TreeField` renderer

**Files:**
- Create: `scripts/tree_field.gd`
- Modify: `tests/headless/test_smoke.gd` (add a `TreeField` build check)

**Interfaces:**
- Consumes: `TreeScatter.scatter` output (`PackedVector2Array`); `TerrainManager.height_at(x,z) -> float`; `shaders/billboard.gdshader`; `textures/tree.png`.
- Produces: `class_name TreeField extends MultiMeshInstance3D` with `func build(positions: PackedVector2Array, floor: TerrainManager, size: Vector2) -> void`. After `build`, `multimesh.instance_count == positions.size()`.

- [ ] **Step 1: Write the failing smoke test**

Add to `tests/headless/test_smoke.gd` (after the existing tests, before any trailing helpers):

```gdscript

func test_tree_field_builds_one_instance_per_position() -> void:
	var floor := _scene.get_node("Floor") as TerrainManager
	var field := TreeField.new()
	add_child_autofree(field)
	var positions := PackedVector2Array([Vector2(10, 10), Vector2(20, 12), Vector2(-5, 8)])
	field.build(positions, floor, Vector2(4, 6))
	assert_not_null(field.multimesh, "field has a MultiMesh")
	assert_eq(field.multimesh.instance_count, positions.size(),
		"one instance per scattered position")
```

- [ ] **Step 2: Run to verify it fails**

Run: `./run_tests.sh --fast smoke` (background). Expected: FAIL — `TreeField` not found.

- [ ] **Step 3: Implement `TreeField`**

```gdscript
# scripts/tree_field.gd
class_name TreeField
extends MultiMeshInstance3D
# Renders scattered tree positions as cylindrical billboards in a single
# MultiMesh (one draw call). Each instance is lifted onto the terrain via
# TerrainManager.height_at; the quad pivot is its bottom edge so trunks sit on
# the ground.

const BILLBOARD_SHADER := preload("res://shaders/billboard.gdshader")
const TREE_TEXTURE := preload("res://textures/tree.png")


func build(positions: PackedVector2Array, floor: TerrainManager, size: Vector2) -> void:
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
	for i in positions.size():
		var p := positions[i]
		var y := floor.height_at(p.x, p.y)
		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, Vector3(p.x, y, p.y)))
	multimesh = mm
```

- [ ] **Step 4: Run to verify it passes**

Run: `./run_tests.sh --fast smoke` (background). Expected: PASS, no SCRIPT ERROR (also confirms the shader compiles, since the material loads it).

- [ ] **Step 5: Commit** — skip.

---

### Task 5: Wire scatter + field into `world.gd`

**Files:**
- Modify: `scripts/world.gd` (`_generate_track`, ~lines 47-58)

**Interfaces:**
- Consumes: `TreeScatter.scatter`, `TreeField`, `GameConfig.tree_params()`, `GameConfig.tree_size_m`, the `result` dict already produced in `_generate_track`.

- [ ] **Step 1: Add scatter + field after the terrain build**

In `scripts/world.gd._generate_track`, after the existing `$Floor.build_initial()` line, append:

```gdscript

	# Scatter billboard trees around each turn, then render them in one MultiMesh.
	# height_at needs the terrain noise cache, which build_initial() has warmed.
	var trees := TreeScatter.scatter(result["pieces"], result["cells"], cfg.tree_params(), cfg.track_seed)
	var field := TreeField.new()
	add_child(field)
	field.build(trees, $Floor as TerrainManager, cfg.tree_size_m)
```

- [ ] **Step 2: Run the smoke + scene tests**

Run: `./run_tests.sh --fast smoke` (background). Expected: PASS (the main scene now builds trees at startup without errors).

- [ ] **Step 3: Commit** — skip.

---

### Task 6: Documentation

**Files:**
- Create: `features/trees.md`
- Modify: `features/README.md` (add index entry)

- [ ] **Step 1: Write `features/trees.md`**

```markdown
# Trees (billboard scatter around turns)

**Source:** `scripts/tree_scatter.gd` (`class_name TreeScatter`),
`scripts/tree_field.gd` (`class_name TreeField`), `shaders/billboard.gdshader`,
`textures/tree.png`. Wired in `scripts/world.gd._generate_track()`.

After the track is generated and baked, billboard tree sprites are scattered
around each turn.

## Placement (`TreeScatter`)

Pure, headless, seeded — same world-XZ plane as `TrackGenerator`
(`x → world x`, `y → world z`).

- `turn_anchor(piece)` — centroid of the piece's rasterized `cells` (world XZ),
  i.e. roughly where the turn is.
- `scatter(pieces, occupied, params, seed)` — for each piece, makes
  `trees_per_turn` placement attempts. Each attempt samples a uniform point in
  a disc of `spawn_radius_m` around the anchor, then rejects it if it is within
  `min_road_dist_m` of any occupied track cell (`_near_road`, a bounded box
  scan of the 0.5 m grid) or within `min_tree_dist_m` of an already-placed
  tree. A rejected tree retries up to `max_retries` times, then is skipped.
  The seed is `track_seed` offset, so placement is deterministic but does not
  visually track corner choices. Returns accepted positions; never hangs.

## Rendering (`TreeField`)

A `MultiMeshInstance3D` subclass: one `MultiMesh` of `QuadMesh` instances (one
draw call). Each instance is placed at `(x, Floor.height_at(x,z), z)`; the quad
pivot is its bottom edge (`center_offset`) so trunks sit on the ground.
`shaders/billboard.gdshader` is a cylindrical billboard — each quad yaws to face
the camera but stays upright — with an alpha-scissor cutout (crisp edges, no
blend sorting) and an unshaded PS1-flat look.

## Configuration

`Trees` group in `config/game_config.tres`: `trees_per_turn`,
`tree_spawn_radius_m`, `tree_min_road_dist_m`, `tree_min_tree_dist_m`,
`tree_max_retries`, `tree_size_m` (width × height). `GameConfig.tree_params()`
packs the scalar knobs for `TreeScatter.scatter`.

## Tests

`tests/headless/test_tree_scatter.gd` — anchor centroid, determinism per seed,
road clearance, tree spacing, within-radius, count bound, and impossible
constraints returning quickly. `tests/headless/test_smoke.gd` — a built
`TreeField` has one MultiMesh instance per position.
```

- [ ] **Step 2: Add the index entry**

In `features/README.md`, add a line to the feature list pointing to `trees.md` (match the existing list's format, e.g. alongside `track.md` and `terrain.md`).

- [ ] **Step 3: Commit** — skip.

---

### Task 7: Final verification

- [ ] **Step 1: Run the full suite**

Run: `./run_tests.sh` (background, `run_in_background: true`). Wait for the completion notification.
Expected: ALL tests pass, no `SCRIPT ERROR` / `Parse Error` / `Failed to load script`. If anything fails, treat the new code as the prime suspect (per CLAUDE.md) and fix it — do not weaken assertions.
