# Track Generation + Rendering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate a 15-corner rally track from the car's spawn by chaining the `CornerLibrary` shapes (corner → random straight → corner) with hard overlap-avoidance via DFS backtracking, and render it by vertex-coloring the 0.5 m terrain cells the track covers.

**Architecture:** A pure-2D `TrackGenerator` (RefCounted) runs the search and outputs a centerline `Curve2D` plus an occupied-cell set (`Vector2i` global cell coords). `TerrainManager` builds de-indexed chunk meshes with per-cell vertex colors; `set_track()` recolors loaded chunks in place (no geometry/noise rebuild). The `ps1_models` shader multiplies albedo by vertex `COLOR`. `world.gd` generates the track at startup and applies it.

**Tech Stack:** Godot 4.6 GDScript, GUT headless tests.

> **Project rules:** NOT under git — do NOT run git commands; each task ends with a **Checkpoint** (confirm tests pass), not a commit. Run tests with `./run_tests.sh` (or `./run_tests.sh --fast <name>`) ALWAYS via `run_in_background: true`; wait for the completion notification; never run two at once; check none is running first. Save the full `./run_tests.sh` for the END (final verification). Godot binary: `/Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot`.

> **Conventions:** Cells use a global 0.5 m grid: `cell = Vector2i(floori(world_x / 0.5), floori(world_z / 0.5))`. Terrain works in world XZ; the track's 2D plane maps `Curve2D` x→world x, y→world z. `TerrainManager.CELL_M == 0.5`, `CHUNK_M == 50`, `SAMPLES == 101`, so `SAMPLES - 1 == 100 == CHUNK_M / CELL_M`.

---

## File Structure

- Create: `scripts/track_generator.gd` — `TrackGenerator`: the 2D search + geometry helpers. One responsibility: turn a start frame + seed into a centerline + cell set.
- Create: `tests/headless/test_track_generator.gd` — generator tests.
- Modify: `shaders/ps1_models.gdshader` — multiply albedo by vertex `COLOR`.
- Modify: `scripts/game_config.gd` — add `track_width`, `track_color`, `track_seed`, `track_turn_count`.
- Modify: `config/game_config.tres` — set track defaults.
- Modify: `scripts/terrain_manager.gd` — de-indexed colored mesh, `track_cells`/colors state, `_cell_colors`, `set_track`.
- Modify: `scripts/terrain_chunk.gd` — drop normals in mesh assembly, add `apply_colors`.
- Modify: `scripts/world.gd` — generate + apply the track at startup.
- Modify: `tests/headless/test_terrain.gd` — update mesh tests for the de-indexed/colored layout.
- Modify: `tests/headless/test_render_smoke.gd` — assert shader references `COLOR`.
- Modify: `tests/headless/test_smoke.gd` — assert a track is generated in `main.tscn`.
- Modify: `features/track.md`, `features/terrain.md`, `features/rendering.md` — docs.

---

## Task 1: Shader vertex-color support

**Files:**
- Modify: `shaders/ps1_models.gdshader`
- Test: `tests/headless/test_render_smoke.gd`

- [ ] **Step 1: Write the failing test**

Append to `tests/headless/test_render_smoke.gd` (a GutTest file — match its existing `extends GutTest` style):

```gdscript
func test_models_shader_uses_vertex_color() -> void:
	var src := FileAccess.get_file_as_string("res://shaders/ps1_models.gdshader")
	assert_true(src.contains("COLOR"), "ps1_models multiplies albedo by vertex COLOR")
```

- [ ] **Step 2: Run the test to verify it fails**

Run (background): `./run_tests.sh --fast render_smoke`
Expected: FAIL — the shader source has no `COLOR`.

- [ ] **Step 3: Edit the shader**

In `shaders/ps1_models.gdshader`, change the fragment body so albedo is also multiplied by the interpolated vertex color. Replace this line:

```glsl
	ALBEDO = texture(albedo_texture, UV * texture_tile).rgb * albedo_color.rgb;
```

with:

```glsl
	ALBEDO = texture(albedo_texture, UV * texture_tile).rgb * albedo_color.rgb * COLOR.rgb;
```

Meshes without a vertex-color array default `COLOR` to white `(1,1,1,1)`, so the car and all other meshes are visually unchanged.

- [ ] **Step 4: Run the test to verify it passes**

Run (background): `./run_tests.sh --fast render_smoke`
Expected: PASS, no `SCRIPT ERROR` / `Parse Error`.

- [ ] **Step 5: Checkpoint** — render smoke green. No git.

---

## Task 2: Track config knobs

**Files:**
- Modify: `scripts/game_config.gd`
- Modify: `config/game_config.tres`
- Test: `tests/headless/test_config_applied.gd`

- [ ] **Step 1: Write the failing test**

Append to `tests/headless/test_config_applied.gd` (match its existing style; it uses the `Config` autoload):

```gdscript
func test_track_config_defaults_present() -> void:
	var cfg := GameConfig.new()
	assert_almost_eq(cfg.track_width, 6.0, 0.001, "default track width is 6 m")
	assert_eq(cfg.track_turn_count, 15, "default track is 15 corners")
	assert_true(cfg.track_color is Color, "track_color is a Color")
	assert_true(cfg.track_seed is int, "track_seed is an int")
```

- [ ] **Step 2: Run to verify it fails**

Run (background): `./run_tests.sh --fast config`
Expected: FAIL — `track_width` etc. do not exist.

- [ ] **Step 3: Add the config properties**

In `scripts/game_config.gd`, add a new export group at the end of the file (after the last existing property):

```gdscript
@export_group("Track")
## Total width of the generated track, in metres; cells within half this
## distance of the centerline are coloured as track.
@export var track_width := 6.0
## Colour applied to on-track terrain cells.
@export var track_color := Color(0.15, 0.15, 0.17)
## Seed for the deterministic track search.
@export var track_seed := 1
## Number of corners chained into the track.
@export var track_turn_count := 15
```

- [ ] **Step 4: Add defaults to the resource**

In `config/game_config.tres`, add these lines to the `[resource]` block (anywhere after the `script = ExtResource("1")` line):

```
track_width = 6.0
track_color = Color(0.15, 0.15, 0.17, 1)
track_seed = 1
track_turn_count = 15
```

- [ ] **Step 5: Run to verify it passes**

Run (background): `./run_tests.sh --fast config`
Expected: PASS.

- [ ] **Step 6: Checkpoint** — config knobs present and green.

---

## Task 3: TrackGenerator geometry helpers

Build and individually test the pure helpers the search relies on, before the search driver itself.

**Files:**
- Create: `scripts/track_generator.gd`
- Test: `tests/headless/test_track_generator.gd`

- [ ] **Step 1: Write the failing helper tests**

Create `tests/headless/test_track_generator.gd`:

```gdscript
extends GutTest
# TrackGenerator: a pure-2D search that chains CornerLibrary corners (corner ->
# straight -> corner) from a start frame, avoiding cell overlaps, and returns a
# centerline Curve2D plus an occupied-cell set. These tests cover the geometry
# helpers first, then the full search in the next task.

const TrackGenerator = preload("res://scripts/track_generator.gd")


func test_frame_transform_maps_local_axes_to_world() -> void:
	# Local +Y is "forward" (the heading); local +X is "right" of it.
	var xf := TrackGenerator.frame_transform(Vector2(10.0, 5.0), Vector2(0.0, 1.0))
	assert_almost_eq(xf * Vector2(0.0, 0.0), Vector2(10.0, 5.0), Vector2(1e-4, 1e-4),
		"origin maps to the frame position")
	assert_almost_eq(xf * Vector2(0.0, 1.0), Vector2(10.0, 6.0), Vector2(1e-4, 1e-4),
		"local +Y (forward) follows the heading")
	# A vector (no translation) only rotates.
	assert_almost_eq(xf.basis_xform(Vector2(0.0, 2.0)), Vector2(0.0, 2.0), Vector2(1e-4, 1e-4),
		"basis_xform ignores translation")


func test_mirror_points_negates_x_when_flipped() -> void:
	var pts := [
		[Vector2(0.0, 0.0), Vector2(0.0, 0.0), Vector2(0.0, 3.0)],
		[Vector2(2.0, 4.0), Vector2(-1.0, -0.5), Vector2(0.0, 0.0)],
	]
	var same := TrackGenerator.mirror_points(pts, false)
	assert_almost_eq(same[1][0], Vector2(2.0, 4.0), Vector2(1e-4, 1e-4), "no flip keeps x")
	var flipped := TrackGenerator.mirror_points(pts, true)
	assert_almost_eq(flipped[1][0], Vector2(-2.0, 4.0), Vector2(1e-4, 1e-4), "flip negates pos.x")
	assert_almost_eq(flipped[1][1], Vector2(1.0, -0.5), Vector2(1e-4, 1e-4), "flip negates in_control.x")


func test_rasterize_cells_covers_width_around_a_straight() -> void:
	# A 10 m straight along +X at the origin, width 2 m -> cells within 1 m of it.
	var line := PackedVector2Array([Vector2(0.0, 0.0), Vector2(10.0, 0.0)])
	var cells := TrackGenerator.rasterize_cells(line, 2.0)
	# The cell at the centre of the line is included.
	assert_true(cells.has(Vector2i(5, 0)), "centre cell on the line is covered")
	# A cell well outside half-width (>1 m away in z) is not.
	assert_false(cells.has(Vector2i(5, 8)), "cell 4 m off the line is not covered")
	# Coverage is symmetric about the line (z just above and below).
	assert_true(cells.has(Vector2i(5, -1)), "cell just below the line is covered")


func test_exit_heading_is_unit_direction_of_last_segment() -> void:
	var poly := PackedVector2Array([Vector2(0.0, 0.0), Vector2(1.0, 0.0), Vector2(1.0, 3.0)])
	var h := TrackGenerator.exit_heading(poly)
	assert_almost_eq(h, Vector2(0.0, 1.0), Vector2(1e-4, 1e-4), "heading follows the last segment, normalised")
```

- [ ] **Step 2: Run to verify it fails**

Run (background): `./run_tests.sh --fast track_generator`
Expected: FAIL — `res://scripts/track_generator.gd` does not exist.

- [ ] **Step 3: Create the helpers**

Create `scripts/track_generator.gd`:

```gdscript
class_name TrackGenerator
extends RefCounted
# Pure-2D rally track search. Chains CornerLibrary corners with connecting
# straights (corner -> straight -> corner) from a start frame, hard-avoiding
# cell overlaps via DFS backtracking (see generate()). Works in a 2D plane that
# maps directly to world XZ: x -> world x, y -> world z. No scene nodes, no
# terrain. This file holds the geometry helpers; generate() drives the search.

const CornerLibrary = preload("res://scripts/corner_library.gd")

const CELL_M := 0.5                                  # global cell grid size
const STRAIGHT_OPTIONS_M := [0.0, 5.0, 10.0, 20.0]   # connecting straight lengths
const RASTER_STEP_M := 0.25                          # centerline sampling for cells
const MAX_STEPS := 4000                              # placement+backtrack cap per attempt
const MAX_RESTARTS := 8                              # random restarts before giving up


# Transform2D mapping local corner space (x = right, y = forward/heading) to
# world, anchored at `pos` with the +Y axis along the unit `heading`.
static func frame_transform(pos: Vector2, heading: Vector2) -> Transform2D:
	var fwd := heading.normalized()
	var right := Vector2(fwd.y, -fwd.x)
	return Transform2D(right, fwd, pos)


# Copy a corner's [pos, in_control, out_control] points, negating every x when
# `flip` (turning a right-hand corner into a left-hand one).
static func mirror_points(points: Array, flip: bool) -> Array:
	if not flip:
		return points.duplicate(true)
	var out: Array = []
	for p in points:
		out.append([
			Vector2(-p[0].x, p[0].y),
			Vector2(-p[1].x, p[1].y),
			Vector2(-p[2].x, p[2].y),
		])
	return out


# Every global cell (Vector2i) within half `width` of the polyline.
static func rasterize_cells(polyline: PackedVector2Array, width: float) -> Dictionary:
	var cells: Dictionary = {}
	var half := width / 2.0
	var reach := int(ceil(half / CELL_M)) + 1
	for i in range(1, polyline.size()):
		var a := polyline[i - 1]
		var b := polyline[i]
		var seg_len := a.distance_to(b)
		var steps := int(ceil(seg_len / RASTER_STEP_M)) + 1
		for s in steps + 1:
			var t := float(s) / float(steps) if steps > 0 else 0.0
			var p := a.lerp(b, t)
			var cx := floori(p.x / CELL_M)
			var cz := floori(p.y / CELL_M)
			for dz in range(-reach, reach + 1):
				for dx in range(-reach, reach + 1):
					var cell := Vector2i(cx + dx, cz + dz)
					# Cell centre in world space.
					var centre := Vector2((cell.x + 0.5) * CELL_M, (cell.y + 0.5) * CELL_M)
					if centre.distance_to(p) <= half:
						cells[cell] = true
	return cells


# Unit heading of the final segment of a world-space polyline.
static func exit_heading(polyline: PackedVector2Array) -> Vector2:
	var n := polyline.size()
	if n < 2:
		return Vector2(0.0, 1.0)
	return (polyline[n - 1] - polyline[n - 2]).normalized()
```

- [ ] **Step 4: Run to verify it passes**

Run (background): `./run_tests.sh --fast track_generator`
Expected: PASS for the four helper tests, no `SCRIPT ERROR`.

- [ ] **Step 5: Checkpoint** — helpers green.

---

## Task 4: TrackGenerator search (DFS backtracking)

**Files:**
- Modify: `scripts/track_generator.gd`
- Test: `tests/headless/test_track_generator.gd`

- [ ] **Step 1: Write the failing search tests**

Append to `tests/headless/test_track_generator.gd`:

```gdscript
const START_POS := Vector2(0.0, 0.0)
const START_HEADING := Vector2(0.0, 1.0)


func _generate(seed_value: int, turns: int = 6, width: float = 6.0) -> Dictionary:
	return TrackGenerator.generate(START_POS, START_HEADING, seed_value, turns, width)


func test_generate_is_deterministic_per_seed() -> void:
	var a := _generate(7)
	var b := _generate(7)
	assert_eq(a["cells"].size(), b["cells"].size(), "same seed -> same number of cells")
	assert_eq(a["pieces"].size(), b["pieces"].size(), "same seed -> same number of pieces")


func test_generate_places_requested_corner_count() -> void:
	var r := _generate(3, 6)
	assert_eq(r["pieces"].size(), 6, "exactly the requested number of corners are placed")
	assert_true(r["complete"], "the search completed within the cap")


func test_generate_starts_at_the_spawn_frame() -> void:
	var r := _generate(5)
	var curve: Curve2D = r["centerline"]
	assert_gt(curve.point_count, 1, "centerline has multiple points")
	assert_almost_eq(curve.get_point_position(0), START_POS, Vector2(1e-3, 1e-3),
		"centerline starts at the spawn position")


func test_generate_avoids_cell_overlap_between_pieces() -> void:
	# Each piece records the cells it added; those sets must be disjoint (the
	# search adds a cell to the occupied set only once, on the piece that claims
	# it), proving no later piece re-covers an earlier piece's cells.
	var r := _generate(11, 8)
	var seen: Dictionary = {}
	for piece in r["pieces"]:
		for cell in piece["cells"]:
			assert_false(seen.has(cell), "cell %s claimed by exactly one piece" % cell)
			seen[cell] = true


func test_generate_is_g1_continuous_at_joins() -> void:
	# Consecutive tessellated centerline segments never reverse direction: the
	# angle between successive segment directions stays well under 90 degrees,
	# i.e. the track has no kinks/cusps at piece joins.
	var r := _generate(2, 8)
	var pts: PackedVector2Array = (r["centerline"] as Curve2D).tessellate()
	for i in range(2, pts.size()):
		var d0 := (pts[i - 1] - pts[i - 2])
		var d1 := (pts[i] - pts[i - 1])
		if d0.length() < 1e-4 or d1.length() < 1e-4:
			continue
		assert_gt(d0.normalized().dot(d1.normalized()), 0.0,
			"no reversal between successive segments at index %d" % i)


func test_generate_uses_both_left_and_right_flips() -> void:
	var lefts := false
	var rights := false
	for seed_value in [1, 2, 3, 4, 5]:
		for piece in _generate(seed_value)["pieces"]:
			if piece["flip"]:
				lefts = true
			else:
				rights = true
	assert_true(lefts and rights, "both left and right corners appear across seeds")
```

- [ ] **Step 2: Run to verify it fails**

Run (background): `./run_tests.sh --fast track_generator`
Expected: FAIL — `generate` is not defined.

- [ ] **Step 3: Implement the search**

Append to `scripts/track_generator.gd`:

```gdscript
# Run the search. Returns:
#   { "centerline": Curve2D, "cells": Dictionary (Vector2i -> true),
#     "pieces": Array (each { "corner": String, "flip": bool,
#                             "straight": float, "cells": Array[Vector2i] }),
#     "complete": bool }
# Deterministic for a given (start_pos, start_heading, seed, turn_count, width).
static func generate(start_pos: Vector2, start_heading: Vector2, seed_value: int,
		turn_count: int, width: float) -> Dictionary:
	var corners := _turn_corners()
	for restart in MAX_RESTARTS:
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_value + restart
		var result := _search(start_pos, start_heading, turn_count, width, corners, rng)
		if result["complete"]:
			return result
	# Last attempt's partial result (never hangs); caller can still render it.
	var rng_final := RandomNumberGenerator.new()
	rng_final.seed = seed_value + MAX_RESTARTS
	var partial := _search(start_pos, start_heading, turn_count, width, corners, rng_final)
	push_warning("TrackGenerator: only placed %d/%d corners" % [partial["pieces"].size(), turn_count])
	return partial


# The library corners eligible as "turns" (everything except the plain Straight).
static func _turn_corners() -> Array:
	var out: Array = []
	for spec in CornerLibrary.CORNERS:
		if spec["name"] != "Straight":
			out.append(spec)
	return out


# All candidate pieces for one step, shuffled deterministically.
static func _candidates(corners: Array, rng: RandomNumberGenerator) -> Array:
	var list: Array = []
	for ci in corners.size():
		for flip in [false, true]:
			for sl in STRAIGHT_OPTIONS_M:
				list.append({ "corner_index": ci, "flip": flip, "straight": sl })
	# Fisher-Yates with the seeded rng for determinism.
	for i in range(list.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = list[i]; list[i] = list[j]; list[j] = tmp
	return list


# Build the world points + cells a candidate would add, given the current frame.
# Returns { "points": Array of [pos,in,out], "cells": Dictionary,
#           "exit_pos": Vector2, "exit_heading": Vector2, "merge_out": Vector2 }.
# `points` are the NEW control points to append after the current last point;
# `merge_out` is the out-handle to set on the current last point (the join).
static func _build_candidate(cand: Dictionary, corners: Array, frame_pos: Vector2,
		frame_heading: Vector2, width: float) -> Dictionary:
	# 1. Connecting straight.
	var straight_end := frame_pos + frame_heading * cand["straight"]
	# 2. Corner control points transformed into world space at the straight end.
	var spec: Dictionary = corners[cand["corner_index"]]
	var local := mirror_points(spec["points"], cand["flip"])
	var xf := frame_transform(straight_end, frame_heading)
	var world_pts: Array = []
	for p in local:
		world_pts.append([xf * p[0], xf.basis_xform(p[1]), xf.basis_xform(p[2])])
	# The corner's first point sits at straight_end; its out-handle becomes the
	# join's out-handle, and its remaining points are what we append.
	var merge_out: Vector2 = world_pts[0][2]
	var appended: Array = []
	if cand["straight"] > 0.0:
		# Insert the straight end as its own point (linear from the previous
		# point), then the corner points after it.
		appended.append([straight_end, Vector2.ZERO, merge_out])
		for i in range(1, world_pts.size()):
			appended.append(world_pts[i])
		merge_out = Vector2.ZERO  # previous point leaves straight (no handle)
	else:
		for i in range(1, world_pts.size()):
			appended.append(world_pts[i])
	# 3. Tessellate the new portion for cells + exit heading. Build a temp curve
	# from the join point (with merge_out) through the appended points.
	var temp := Curve2D.new()
	temp.add_point(frame_pos, Vector2.ZERO, merge_out)
	for ap in appended:
		temp.add_point(ap[0], ap[1], ap[2])
	var poly := temp.tessellate()
	var cells := rasterize_cells(poly, width)
	return {
		"points": appended,
		"cells": cells,
		"exit_pos": appended[appended.size() - 1][0],
		"exit_heading": exit_heading(poly),
		"merge_out": merge_out,
	}


# DFS backtracking. Builds the world polybezier point-by-point.
static func _search(start_pos: Vector2, start_heading: Vector2, turn_count: int,
		width: float, corners: Array, rng: RandomNumberGenerator) -> Dictionary:
	# world_points: Array of [pos, in, out]; starts with the spawn point.
	var world_points: Array = [[start_pos, Vector2.ZERO, Vector2.ZERO]]
	var occupied: Dictionary = {}
	var pieces: Array = []
	var frame_pos := start_pos
	var frame_heading := start_heading.normalized()
	var stack: Array = []  # one entry per placed corner
	var steps := 0

	while pieces.size() < turn_count:
		steps += 1
		if steps > MAX_STEPS:
			break
		# Get or create the candidate list for the current depth.
		if stack.size() == pieces.size():
			stack.append({ "cands": _candidates(corners, rng), "idx": 0 })
		var top: Dictionary = stack[stack.size() - 1]
		var placed := false
		while top["idx"] < top["cands"].size():
			var cand: Dictionary = top["cands"][top["idx"]]
			top["idx"] += 1
			var built := _build_candidate(cand, corners, frame_pos, frame_heading, width)
			# Overlap test, ignoring cells within a join buffer of the entry.
			var collides := false
			for cell in built["cells"]:
				if not occupied.has(cell):
					continue
				var centre := Vector2((cell.x + 0.5) * CELL_M, (cell.y + 0.5) * CELL_M)
				if centre.distance_to(frame_pos) > width:
					collides = true
					break
			if collides:
				continue
			# Commit.
			var prev_out: Vector2 = world_points[world_points.size() - 1][2]
			world_points[world_points.size() - 1][2] = built["merge_out"]
			var added_cells: Array = []
			for cell in built["cells"]:
				if not occupied.has(cell):
					occupied[cell] = true
					added_cells.append(cell)
			for ap in built["points"]:
				world_points.append(ap)
			top["restore"] = {
				"prev_out": prev_out,
				"points_added": built["points"].size(),
				"cells_added": added_cells,
				"frame_pos": frame_pos,
				"frame_heading": frame_heading,
			}
			pieces.append({
				"corner": corners[cand["corner_index"]]["name"],
				"flip": cand["flip"],
				"straight": cand["straight"],
				"cells": added_cells,
			})
			frame_pos = built["exit_pos"]
			frame_heading = built["exit_heading"]
			placed = true
			break
		if placed:
			continue
		# Dead end: discard this depth's exhausted candidate iterator, then undo
		# the last PLACED corner so we can retry its next candidate.
		stack.pop_back()
		if pieces.is_empty():
			break  # nothing placed and no candidate worked -> unsolvable
		# The placed corner's entry is now the top; keep it on the stack so its
		# iterator (already advanced) resumes next loop, and undo its placement.
		var entry: Dictionary = stack[stack.size() - 1]
		var restore: Dictionary = entry["restore"]
		for _i in restore["points_added"]:
			world_points.pop_back()
		world_points[world_points.size() - 1][2] = restore["prev_out"]
		for cell in restore["cells_added"]:
			occupied.erase(cell)
		frame_pos = restore["frame_pos"]
		frame_heading = restore["frame_heading"]
		pieces.pop_back()
		# stack.size() == pieces.size() + 1 now, so the loop does NOT append a new
		# iterator — it resumes `entry` at its next untried candidate.

	var centerline := Curve2D.new()
	for wp in world_points:
		centerline.add_point(wp[0], wp[1], wp[2])
	return {
		"centerline": centerline,
		"cells": occupied,
		"pieces": pieces,
		"complete": pieces.size() == turn_count,
	}
```

- [ ] **Step 4: Run to verify it passes**

Run (background): `./run_tests.sh --fast track_generator`
Expected: PASS for all generator tests (helpers + search), no `SCRIPT ERROR`.

- [ ] **Step 5: Checkpoint** — generator complete and green.

---

## Task 5: De-indexed, vertex-colored terrain mesh

Switch chunk meshes to de-indexed per-cell vertices with per-cell colors. Heights (collision) are unchanged. Normals are dropped (the shader is `unshaded`, so they were already unused).

**Files:**
- Modify: `scripts/terrain_manager.gd`
- Modify: `scripts/terrain_chunk.gd`
- Test: `tests/headless/test_terrain.gd`

- [ ] **Step 1: Update the failing tests**

In `tests/headless/test_terrain.gd`, make these edits (the new layout is the agreed behavior change, so the tests change with it):

(a) In `test_chunk_builds_mesh_and_collision`, replace the vertex-count assertion and delete the normals block. Replace:

```gdscript
	assert_eq(mesh.surface_get_array_len(0), samples * samples, "one vertex per sample")
```
with:
```gdscript
	var cells := (samples - 1) * (samples - 1)
	assert_eq(mesh.surface_get_array_len(0), cells * 4, "four de-indexed vertices per cell")
```
and delete these three lines:
```gdscript
	# Front faces must wind so normals point up, else culling hides the terrain.
	var normals: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_NORMAL]
	for i in [0, (samples * samples) / 2, samples * samples - 1]:
		assert_gt(normals[i].y, 0.0, "vertex normal %d points up" % i)
```

(b) Replace the whole `test_compute_chunk_data_shapes_and_heights` function with:

```gdscript
func test_compute_chunk_data_shapes_and_heights() -> void:
	var m := _make_manager([_make_layer(60.0, 1.5), _make_layer(15.0, 0.4)] as Array[TerrainLayer], 21)
	var samples: int = ManagerScript.SAMPLES
	var cells := (samples - 1) * (samples - 1)
	var data: Dictionary = m.compute_chunk_data(Vector2i(0, 0))

	var verts: PackedVector3Array = data["vertices"]
	var uvs: PackedVector2Array = data["uvs"]
	var colors: PackedColorArray = data["colors"]
	var indices: PackedInt32Array = data["indices"]
	var heights: PackedFloat32Array = data["heights"]
	assert_eq(verts.size(), cells * 4, "four de-indexed vertices per cell")
	assert_eq(uvs.size(), cells * 4, "one uv per de-indexed vertex")
	assert_eq(colors.size(), cells * 4, "one colour per de-indexed vertex")
	assert_eq(indices.size(), cells * 6, "two triangles per cell")
	assert_eq(heights.size(), samples * samples, "height array still one per sample (collision)")

	var center: Vector3 = data["center"]
	var bh: PackedFloat32Array = m.build_heights(center)
	for i in [0, samples * samples / 2, samples * samples - 1]:
		assert_almost_eq(heights[i], bh[i], 1e-5, "compute_chunk_data height %d matches build_heights" % i)
```

(c) Replace the whole `test_compute_chunk_data_normals_point_up` function with a coloring test:

```gdscript
func test_compute_chunk_data_colors_track_cells() -> void:
	var m := _make_manager([_make_layer(60.0, 1.5)] as Array[TerrainLayer], 21)
	# Colour the single global cell at chunk (0,0)'s local cell (0,0).
	var track_cell := Vector2i(0 * (ManagerScript.SAMPLES - 1) + 0, 0 * (ManagerScript.SAMPLES - 1) + 0)
	m.track_color = Color(1, 0, 0)
	m.default_cell_color = Color(1, 1, 1)
	m.track_cells = { track_cell: true }
	var data: Dictionary = m.compute_chunk_data(Vector2i(0, 0))
	var colors: PackedColorArray = data["colors"]
	# Cell 0 occupies the first 4 de-indexed vertices.
	assert_eq(colors[0], Color(1, 0, 0), "on-track cell uses track_color")
	# Cell 1 (next cell) is off-track -> default colour.
	assert_eq(colors[4], Color(1, 1, 1), "off-track cell uses default_cell_color")
```

- [ ] **Step 2: Run to verify it fails**

Run (background): `./run_tests.sh --fast terrain`
Expected: FAIL — `data["colors"]` missing, vertex counts wrong, `track_cells`/`default_cell_color`/`track_color` missing.

- [ ] **Step 3: Add manager state + cell-color helper**

In `scripts/terrain_manager.gd`, add these properties just after the existing `@export var chunk_material: Material` line:

```gdscript
# Track overlay: global cell coords (Vector2i) painted as track, and the colours
# used. Setting these does NOT regenerate terrain — see set_track().
var track_cells: Dictionary = {}
var track_color: Color = Color(0.15, 0.15, 0.17)
var default_cell_color: Color = Color(1, 1, 1)
```

Add this helper method (anywhere at the end of the file):

```gdscript
# Per-cell colours for one chunk's de-indexed mesh: track_color where the global
# cell is in track_cells, else default_cell_color. Four identical entries per
# cell (the cell's four de-indexed vertices), in the same cell order as the mesh.
func cell_colors(coord: Vector2i) -> PackedColorArray:
	var per_edge := SAMPLES - 1
	var colors := PackedColorArray()
	colors.resize(per_edge * per_edge * 4)
	var ci := 0
	for zi in per_edge:
		for xi in per_edge:
			var cell := Vector2i(coord.x * per_edge + xi, coord.y * per_edge + zi)
			var c: Color = track_color if track_cells.has(cell) else default_cell_color
			for k in 4:
				colors[ci * 4 + k] = c
			ci += 1
	return colors
```

- [ ] **Step 4: Rewrite the mesh portion of `compute_chunk_data`**

In `scripts/terrain_manager.gd`, inside `compute_chunk_data`, replace everything from the `var vertices := PackedVector3Array()` declaration down to the `return { ... }` block with the de-indexed build below. Keep the `heights` array exactly as-is (it feeds collision). The new code first samples heights into a `SAMPLES x SAMPLES` grid, then emits 4 unique vertices per cell:

```gdscript
	var count := SAMPLES * SAMPLES
	var heights := PackedFloat32Array()
	heights.resize(count)
	var grid := PackedVector3Array()  # one position per sample (for cell corners)
	grid.resize(count)
	for zi in SAMPLES:
		var lz := -half + zi * CELL_M
		var wz := center.z + lz
		for xi in SAMPLES:
			var lx := -half + xi * CELL_M
			var wx := center.x + lx
			var h := 0.0
			for i in noises.size():
				h += noises[i].get_noise_2d(wx, wz) * amplitudes[i]
			var idx := zi * SAMPLES + xi
			heights[idx] = h
			grid[idx] = Vector3(lx, h, lz)

	# De-indexed mesh: each cell gets its own 4 vertices so per-cell vertex
	# colour produces crisp squares. UVs use world coords (continuous checker).
	var per_edge := SAMPLES - 1
	var cells := per_edge * per_edge
	var vertices := PackedVector3Array(); vertices.resize(cells * 4)
	var uvs := PackedVector2Array(); uvs.resize(cells * 4)
	var indices := PackedInt32Array(); indices.resize(cells * 6)
	var ci := 0
	for zi in per_edge:
		for xi in per_edge:
			var a := zi * SAMPLES + xi
			var b := a + 1
			var c := a + SAMPLES
			var d := c + 1
			var base := ci * 4
			vertices[base + 0] = grid[a]
			vertices[base + 1] = grid[b]
			vertices[base + 2] = grid[c]
			vertices[base + 3] = grid[d]
			uvs[base + 0] = Vector2(center.x + grid[a].x, center.z + grid[a].z) * tile
			uvs[base + 1] = Vector2(center.x + grid[b].x, center.z + grid[b].z) * tile
			uvs[base + 2] = Vector2(center.x + grid[c].x, center.z + grid[c].z) * tile
			uvs[base + 3] = Vector2(center.x + grid[d].x, center.z + grid[d].z) * tile
			# Clockwise winding a,b,c / b,d,c (matches the previous mesh).
			var ii := ci * 6
			indices[ii + 0] = base + 0; indices[ii + 1] = base + 1; indices[ii + 2] = base + 2
			indices[ii + 3] = base + 1; indices[ii + 4] = base + 3; indices[ii + 5] = base + 2
			ci += 1

	var colors := cell_colors(coord)

	return {
		"center": center,
		"heights": heights,
		"vertices": vertices,
		"uvs": uvs,
		"colors": colors,
		"indices": indices,
	}
```

Also delete the now-unused `var vertices`/`var uvs`/`var normals` declarations and the old index + normals loops that preceded this region (the entire old vertex/uv/normal/index construction is replaced by the block above). The `noises`/`amplitudes`/`half`/`tile`/`center` setup at the top of `compute_chunk_data` stays.

- [ ] **Step 5: Update `apply_data` for colors + no normals**

In `scripts/terrain_chunk.gd`, in `apply_data`, replace the array-assembly block:

```gdscript
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = data["vertices"]
	arrays[Mesh.ARRAY_NORMAL] = data["normals"]
	arrays[Mesh.ARRAY_TEX_UV] = data["uvs"]
	arrays[Mesh.ARRAY_INDEX] = data["indices"]
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mesh_instance.mesh = mesh
```

with:

```gdscript
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = data["vertices"]
	arrays[Mesh.ARRAY_TEX_UV] = data["uvs"]
	arrays[Mesh.ARRAY_COLOR] = data["colors"]
	arrays[Mesh.ARRAY_INDEX] = data["indices"]
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mesh_instance.mesh = mesh
```

- [ ] **Step 6: Run to verify it passes**

Run (background): `./run_tests.sh --fast terrain`
Expected: PASS — all terrain tests green with the de-indexed/colored layout, no `SCRIPT ERROR`.

- [ ] **Step 7: Checkpoint** — de-indexed colored terrain green.

---

## Task 6: Apply the track without regenerating (`set_track` + recolor)

**Files:**
- Modify: `scripts/terrain_manager.gd`
- Modify: `scripts/terrain_chunk.gd`
- Test: `tests/headless/test_terrain.gd`

- [ ] **Step 1: Write the failing test**

Append to `tests/headless/test_terrain.gd`:

```gdscript
func test_set_track_recolors_without_changing_geometry() -> void:
	var m := _make_manager([_make_layer(60.0, 1.5)] as Array[TerrainLayer], 21)
	add_child_autofree(m)
	var chunk = m._chunks[Vector2i(0, 0)]
	var mesh_before := chunk.get_node("MeshInstance3D").mesh as ArrayMesh
	var verts_before: PackedVector3Array = mesh_before.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]

	# Paint cell (0,0) of chunk (0,0) and apply.
	var per_edge := ManagerScript.SAMPLES - 1
	m.set_track({ Vector2i(0, 0): true }, Color(1, 0, 0))

	var mesh_after := chunk.get_node("MeshInstance3D").mesh as ArrayMesh
	var arrays_after := mesh_after.surface_get_arrays(0)
	var verts_after: PackedVector3Array = arrays_after[Mesh.ARRAY_VERTEX]
	var colors_after: PackedColorArray = arrays_after[Mesh.ARRAY_COLOR]
	assert_eq(verts_after.size(), verts_before.size(), "vertex count unchanged by recolor")
	for i in [0, verts_before.size() / 2, verts_before.size() - 1]:
		assert_almost_eq(verts_after[i], verts_before[i], Vector3(1e-5, 1e-5, 1e-5),
			"vertex %d position unchanged by recolor" % i)
	assert_eq(colors_after[0], Color(1, 0, 0), "painted cell now uses track colour")
	assert_eq(m.track_cells.size(), 1, "track cells stored on the manager")
```

- [ ] **Step 2: Run to verify it fails**

Run (background): `./run_tests.sh --fast terrain`
Expected: FAIL — `set_track` and `TerrainChunk.apply_colors` are not defined.

- [ ] **Step 3: Add `set_track` to the manager**

In `scripts/terrain_manager.gd`, add:

```gdscript
# Apply a track overlay: store the painted cells/colour and recolour every
# loaded chunk in place. This does NOT rebuild geometry or re-run noise — it only
# swaps each chunk's vertex-colour array. New chunks loaded later read
# track_cells in compute_chunk_data and bake colours at build time.
func set_track(cells: Dictionary, color: Color) -> void:
	track_cells = cells
	track_color = color
	for coord in _chunks:
		_chunks[coord].apply_colors(cell_colors(coord))
```

- [ ] **Step 4: Add `apply_colors` to the chunk**

In `scripts/terrain_chunk.gd`, add:

```gdscript
# Swap just the vertex-colour array on the existing mesh, reusing its vertices,
# UVs and indices (no height sampling, no regeneration).
func apply_colors(colors: PackedColorArray) -> void:
	var mesh := _mesh_instance.mesh as ArrayMesh
	if mesh == null:
		return
	var arrays := mesh.surface_get_arrays(0)
	arrays[Mesh.ARRAY_COLOR] = colors
	var rebuilt := ArrayMesh.new()
	rebuilt.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mesh_instance.mesh = rebuilt
	_mesh_instance.material_override = _mesh_instance.material_override
```

- [ ] **Step 5: Run to verify it passes**

Run (background): `./run_tests.sh --fast terrain`
Expected: PASS.

- [ ] **Step 6: Checkpoint** — recolor path green.

---

## Task 7: Generate the track at startup + scene smoke

**Files:**
- Modify: `scripts/world.gd`
- Test: `tests/headless/test_smoke.gd`

- [ ] **Step 1: Write the failing test**

Append to `tests/headless/test_smoke.gd` (match its existing pattern — it loads `main.tscn`; reset `Config` like the other gameplay tests):

```gdscript
func test_main_scene_generates_a_track() -> void:
	Config.reset()
	var scene := load("res://main.tscn").instantiate()
	add_child_autofree(scene)
	await get_tree().physics_frame  # let world._ready() generate + apply the track
	var floor_node = scene.get_node("Floor")
	assert_gt(floor_node.track_cells.size(), 0, "world generated a non-empty track")
	Config.reset()
```

- [ ] **Step 2: Run to verify it fails**

Run (background): `./run_tests.sh --fast smoke`
Expected: FAIL — `track_cells` is empty (nothing generates it yet).

- [ ] **Step 3: Wire generation into `world.gd`**

In `scripts/world.gd`, at the end of `_ready()` (after `$Car.apply_car(0)`), add:

```gdscript
	_generate_track(cfg)
```

Then add the method:

```gdscript
# Build the track from the car's spawn pose and paint it onto the terrain.
func _generate_track(cfg: GameConfig) -> void:
	var xform: Transform3D = $Car.global_transform
	var start_pos := Vector2(xform.origin.x, xform.origin.z)
	# A Node3D's forward is -Z; project it onto the XZ plane.
	var fwd := -xform.basis.z
	var start_heading := Vector2(fwd.x, fwd.z).normalized()
	var result := TrackGenerator.generate(
		start_pos, start_heading, cfg.track_seed, cfg.track_turn_count, cfg.track_width)
	$Floor.set_track(result["cells"], cfg.track_color)
```

- [ ] **Step 4: Run to verify it passes**

Run (background): `./run_tests.sh --fast smoke`
Expected: PASS.

- [ ] **Step 5: Visually confirm**

Run: `/Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot res://main.tscn`
Expected: the car spawns and a contiguous painted track (track-colored 0.5 m cells) winds away from it across the terrain, ~15 corners, no self-overlap. (Manual check; close the window when done.)

- [ ] **Step 6: Checkpoint** — track renders in the running game.

---

## Task 8: Documentation + final full test run

**Files:**
- Modify: `features/track.md`, `features/terrain.md`, `features/rendering.md`

- [ ] **Step 1: Update `features/track.md`**

Add a `## Track generation` section documenting: `scripts/track_generator.gd` (`TrackGenerator`), the corner→straight→corner chain, the piece/candidate space (corners excluding `Straight` × L/R flip × `STRAIGHT_OPTIONS_M`), the frame transform + X-mirror for left turns, cell rasterization (`width/2` on the 0.5 grid), DFS backtracking with a join buffer, and the `MAX_STEPS`/`MAX_RESTARTS` safety cap. Add a `## Rendering` note that the track is drawn by `TerrainManager.set_track()` recoloring de-indexed per-cell vertex colors (no regeneration), and that `world.gd` generates it from the car's spawn pose using the `track_*` config knobs.

- [ ] **Step 2: Update `features/terrain.md`**

Update the mesh description: chunk meshes are now **de-indexed** (4 vertices per 0.5 m cell, 6 indices), carry per-cell `ARRAY_COLOR`, and **drop normals** (the unshaded shader ignores them). Document `track_cells`/`track_color`/`default_cell_color`, `cell_colors(coord)`, and `set_track(cells, color)` (recolor-in-place, no regeneration). Note collision is unchanged (still the `SAMPLES²` height array → `HeightMapShape3D`).

- [ ] **Step 3: Update `features/rendering.md`**

Note that `ps1_models.gdshader` now multiplies albedo by vertex `COLOR` (`ALBEDO = texture × albedo_color × COLOR`), used by the terrain to tint on-track cells; meshes without vertex colors are unaffected (COLOR defaults to white).

- [ ] **Step 4: Final full test run**

Confirm no background `run_tests.sh` is running, then run the FULL suite (background): `./run_tests.sh`
Expected: ends with `ALL TESTS PASSED`, no `SCRIPT ERROR` / `Parse Error` / `Failed to load script`.

- [ ] **Step 5: Checkpoint** — feature complete: generator, rendering, wiring, tests, and docs in sync.

---

## Self-Review notes

- **Spec coverage:** TrackGenerator + DFS backtracking + safety cap (Tasks 3–4); piece=corner+straight, L/R mirror, overlap with join buffer (Task 4); de-indexed vertex-colored chunks + shader (Tasks 1, 5); `set_track` recolor without regen (Task 6); config knobs (Task 2); world wiring from spawn pose (Task 7); all tests incl. updated terrain seam/normals handling (Tasks 5–7); docs (Task 8). The spec's seam test is unaffected (it uses `build_heights`, untouched); the normals-point-up tests are replaced (normals dropped) — called out in Task 5.
- **Type consistency:** `TrackGenerator.generate(start_pos, start_heading, seed, turn_count, width) -> Dictionary` with keys `centerline`/`cells`/`pieces`/`complete`; piece keys `corner`/`flip`/`straight`/`cells`. `compute_chunk_data` returns `center`/`heights`/`vertices`/`uvs`/`colors`/`indices` (no `normals`). Manager: `track_cells`/`track_color`/`default_cell_color`, `cell_colors(coord)`, `set_track(cells, color)`. Chunk: `apply_colors(colors)`. Names used identically across tasks and tests.
- **No git:** commits replaced by Checkpoints per the project rule.
