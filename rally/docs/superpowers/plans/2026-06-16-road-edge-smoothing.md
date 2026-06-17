# Road Edge Smoothing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Feather the road edge over a configurable band (default 3 cells) just outside `track_width/2`, blending both terrain height and vertex colour from the flat road to the true terrain (smoothstep), instead of the current hard step.

**Architecture:** A single `TerrainManager.bake_track()` computes per-vertex height-blend weights (`road_blend`) + nearest road heights (`road_heights`) and per-cell colour weights (`track_weights`), all ramping `1→0` across the band. `compute_chunk_data` lerps height by `road_blend` (mesh + collision); `cell_colors` lerps colour by `track_weights`. The binary `track_cells` and `bake_road` are removed.

**Tech Stack:** Godot 4.6 GDScript, GUT headless tests.

> **Project rules:** NOT under git — no git commands; tasks end with a **Checkpoint** (confirm tests pass), not a commit. Run tests with `./run_tests.sh --fast <name>` via `run_in_background: true`; wait for the notification; never two at once; check none running first. Full `./run_tests.sh` only at the END. Godot: `/Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot`.

> **Conventions:** vertex index `Vector2i(coord.x*(SAMPLES-1)+xi, coord.y*(SAMPLES-1)+zi)` == `Vector2i(roundi(world_x/CELL_M), roundi(world_z/CELL_M))`; cell index `Vector2i(coord.x*(SAMPLES-1)+xi, …)` == `Vector2i(floori(world_x/CELL_M), …)` with centre `((cell+0.5)*CELL_M)`. `CELL_M = 0.5`, `SAMPLES = 101`.

---

## File Structure

- Modify: `scripts/game_config.gd` + `config/game_config.tres` — `track_transition_cells`.
- Modify: `scripts/terrain_manager.gd` — weighted fields, `smooth_ramp`, `bake_track`, `cell_colors`, `compute_chunk_data` blend, new `set_track`; remove `track_cells` + `bake_road`.
- Modify: `scripts/world.gd` — new `set_track` call.
- Modify: `tests/headless/test_terrain.gd` — replace the flattening/colour tests with weighted-blend tests.
- Modify: `tests/headless/test_smoke.gd` — assert `track_weights` non-empty.

---

## Task 1: `track_transition_cells` config

**Files:**
- Modify: `scripts/game_config.gd`, `config/game_config.tres`
- Test: `tests/headless/test_config_applied.gd`

- [ ] **Step 1: Write the failing test**

Append to `tests/headless/test_config_applied.gd`:

```gdscript
func test_track_transition_cells_default() -> void:
	var cfg := GameConfig.new()
	assert_eq(cfg.track_transition_cells, 3, "default edge transition is 3 cells")
```

- [ ] **Step 2: Run to verify it fails**

Run (background): `./run_tests.sh --fast config`
Expected: FAIL — `track_transition_cells` doesn't exist.

- [ ] **Step 3: Add the property**

In `scripts/game_config.gd`, in the `Track` group (after `track_turn_count`):

```gdscript
## Width, in 0.5 m cells, of the smooth transition band just outside the road
## edge where height and colour blend from the flat road to the true terrain.
@export var track_transition_cells := 3
```

- [ ] **Step 4: Add the default to the resource**

In `config/game_config.tres`, add under the existing `track_turn_count` line in the `[resource]` block:

```
track_transition_cells = 3
```

- [ ] **Step 5: Run to verify it passes**

Run (background): `./run_tests.sh --fast config`
Expected: PASS.

- [ ] **Step 6: Checkpoint** — config knob present.

---

## Task 2: Weighted edge blending (terrain + world)

This task replaces the binary flatten/colour with weighted blending. It changes
the manager, `world.gd`, and the related tests together (removing `track_cells`
and `bake_road` would otherwise break the main-scene-loading tests).

**Files:**
- Modify: `scripts/terrain_manager.gd`
- Modify: `scripts/world.gd`
- Test: `tests/headless/test_terrain.gd`, `tests/headless/test_smoke.gd`

- [ ] **Step 1: Update the tests (red)**

In `tests/headless/test_terrain.gd`, **replace** the four functions
`test_bake_road_flattens_vertices_to_nearest_centerline_height`,
`test_compute_chunk_data_flattens_on_road_vertices`,
`test_compute_chunk_data_colors_track_cells`, and
`test_set_track_applies_colour_and_flattening_to_loaded_chunks` with these:

```gdscript
func test_smooth_ramp_is_one_inside_zero_outside_half_at_mid() -> void:
	assert_eq(ManagerScript.smooth_ramp(0.5, 3.0, 4.5), 1.0, "fully road at/inside inner")
	assert_eq(ManagerScript.smooth_ramp(5.0, 3.0, 4.5), 0.0, "terrain at/beyond outer")
	# Band midpoint d = 3.75: raw = 0.5 -> smoothstep 0.5*0.5*(3-2*0.5) = 0.5.
	assert_almost_eq(ManagerScript.smooth_ramp(3.75, 3.0, 4.5), 0.5, 0.001, "smoothstep is 0.5 at band mid")


func test_bake_track_weights_inside_band_outside() -> void:
	var m := _make_manager([_make_layer(20.0, 3.0)] as Array[TerrainLayer], 5)
	var curve := Curve2D.new()
	curve.add_point(Vector2(0.0, 0.0))
	curve.add_point(Vector2(20.0, 0.0))
	m.bake_track(curve, 2.0, 1.0)  # inner = width/2 = 1.0, outer = 2.0
	var on := Vector2i(roundi(10.0 / ManagerScript.CELL_M), 0)  # world (10, 0)
	assert_almost_eq(m.road_blend[on], 1.0, 1e-4, "vertex on the road has full weight")
	assert_almost_eq(m.road_heights[on], m.height_at(10.0, 0.0), 0.1, "road height sampled from terrain")
	var band := Vector2i(roundi(10.0 / ManagerScript.CELL_M), roundi(1.5 / ManagerScript.CELL_M))  # (10, 1.5)
	assert_true(m.road_blend.has(band), "band vertex present")
	assert_gt(m.road_blend[band], 0.0, "band weight > 0")
	assert_lt(m.road_blend[band], 1.0, "band weight < 1")
	var far := Vector2i(roundi(10.0 / ManagerScript.CELL_M), roundi(3.0 / ManagerScript.CELL_M))  # (10, 3)
	assert_false(m.road_blend.has(far), "vertex beyond the band is absent")
	assert_gt(m.track_weights.size(), 0, "per-cell colour weights baked too")


func test_compute_chunk_data_blends_road_height() -> void:
	var m := _make_manager([_make_layer(20.0, 3.0)] as Array[TerrainLayer], 5)
	var v_full := Vector2i(10, 0)  # chunk (0,0) local (xi=10, zi=0)
	var v_half := Vector2i(12, 0)  # local (xi=12, zi=0)
	m.road_heights = { v_full: 50.0, v_half: 50.0 }
	m.road_blend = { v_full: 1.0, v_half: 0.5 }
	var data: Dictionary = m.compute_chunk_data(Vector2i(0, 0))
	var heights: PackedFloat32Array = data["heights"]
	var verts: PackedVector3Array = data["vertices"]
	assert_almost_eq(heights[10], 50.0, 1e-4, "full-weight vertex fully flattened (collision)")
	assert_almost_eq(verts[40].y, 50.0, 1e-4, "full-weight vertex fully flattened (mesh)")
	# Sample (xi=12, zi=0) -> world x = 6.0, z = 0; blended halfway to 50.
	var expected := lerpf(m.height_at(6.0, 0.0), 50.0, 0.5)
	assert_almost_eq(heights[12], expected, 1e-3, "band vertex height blended halfway")


func test_cell_colors_blend_by_weight() -> void:
	var m := _make_manager([_make_layer(60.0, 1.5)] as Array[TerrainLayer], 21)
	m.track_color = Color(1, 0, 0)
	m.default_cell_color = Color(0, 0, 1)
	m.track_weights = { Vector2i(0, 0): 1.0, Vector2i(1, 0): 0.5 }
	var colors := m.cell_colors(Vector2i(0, 0))
	assert_eq(colors[0], Color(1, 0, 0), "weight 1 -> track colour")
	assert_eq(colors[4], Color(0, 0, 1).lerp(Color(1, 0, 0), 0.5), "weight 0.5 -> blended colour")
	assert_eq(colors[8], Color(0, 0, 1), "absent cell -> default colour")


func test_set_track_bakes_fields_and_rebuilds_loaded_chunks() -> void:
	var m := _make_manager([_make_layer(20.0, 3.0)] as Array[TerrainLayer], 5)
	add_child_autofree(m)  # ring built in _ready (not deferred in tests)
	var curve := Curve2D.new()  # a straight through chunk (0,0) (world [0,50])
	curve.add_point(Vector2(5.0, 5.0))
	curve.add_point(Vector2(45.0, 5.0))
	m.set_track(curve, 6.0, 1.5, Color(1, 0, 0))
	assert_gt(m.road_blend.size(), 0, "set_track baked road blend weights")
	assert_gt(m.track_weights.size(), 0, "set_track baked colour weights")
	var chunk = m._chunks[Vector2i(0, 0)]
	var colors: PackedColorArray = (chunk.get_node("MeshInstance3D").mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	var has_track := false
	for c in colors:
		if c.is_equal_approx(Color(1, 0, 0)):
			has_track = true
			break
	assert_true(has_track, "rebuilt chunk shows the track colour where fully on-road")
```

In `tests/headless/test_smoke.gd`, in `test_main_scene_generates_a_track`, replace the `track_cells` assertion line:

```gdscript
	assert_gt(floor_node.track_cells.size(), 0, "world generated a non-empty track")
```

with:

```gdscript
	assert_gt(floor_node.track_weights.size(), 0, "world applied a track (colour weights baked)")
```

(Keep the `road_heights` and `loaded_coords` assertions that follow.)

- [ ] **Step 2: Run to verify it fails**

Run (background): `./run_tests.sh --fast terrain`
Expected: FAIL — `smooth_ramp` / `bake_track` / `road_blend` / `track_weights` don't exist; old API gone.

- [ ] **Step 3: Replace the manager state**

In `scripts/terrain_manager.gd`, replace:

```gdscript
var track_cells: Dictionary = {}
var track_color: Color = Color(0.15, 0.15, 0.17)
var default_cell_color: Color = Color(1, 1, 1)
# Global grid-vertex index (Vector2i) -> flattened Y for vertices on the road.
# Built by bake_road(); read by compute_chunk_data(). Empty = no flattening.
var road_heights: Dictionary = {}
```

with:

```gdscript
var track_color: Color = Color(0.15, 0.15, 0.17)
var default_cell_color: Color = Color(1, 1, 1)
# Weighted road fields, built by bake_track(), read by compute_chunk_data() /
# cell_colors(). All weights ramp 1 (on the road) -> 0 (outer edge of the
# transition band); entries with weight 0 are omitted. Empty = no track.
var road_heights: Dictionary = {}   # vertex index (Vector2i) -> nearest road Y
var road_blend: Dictionary = {}     # vertex index -> height blend weight [0,1]
var track_weights: Dictionary = {}  # cell index -> colour blend weight [0,1]
```

- [ ] **Step 4: Add `smooth_ramp` and replace `bake_road` with `bake_track`**

In `scripts/terrain_manager.gd`, replace the entire `bake_road` function:

```gdscript
# Sample the terrain along the 2D centerline (x -> world x, y -> world z) and
# record, per global grid-vertex index within `width`/2 of the line, the height
# of the nearest centerline sample. Densely sub-samples each segment so straight
# spans (which tessellate to just their endpoints) still flatten their interior.
# Stores and returns the road_heights dictionary.
func bake_road(centerline: Curve2D, width: float) -> Dictionary:
	var heights_out: Dictionary = {}
	var best: Dictionary = {}  # vertex index -> best (smallest) distance so far
	var half := width / 2.0
	var reach := int(ceil(half / CELL_M)) + 1
	var poly := centerline.tessellate()
	for i in range(1, poly.size()):
		var a := poly[i - 1]
		var b := poly[i]
		var seg_len := a.distance_to(b)
		var steps := int(ceil(seg_len / ROAD_SAMPLE_STEP_M)) + 1
		for s in steps + 1:
			var t := float(s) / float(steps) if steps > 0 else 0.0
			var p := a.lerp(b, t)
			var y := height_at(p.x, p.y)
			var cx := roundi(p.x / CELL_M)
			var cz := roundi(p.y / CELL_M)
			for dz in range(-reach, reach + 1):
				for dx in range(-reach, reach + 1):
					var v := Vector2i(cx + dx, cz + dz)
					var d := Vector2(v.x * CELL_M, v.y * CELL_M).distance_to(p)
					if d <= half and (not best.has(v) or d < best[v]):
						best[v] = d
						heights_out[v] = y
	road_heights = heights_out
	return heights_out
```

with:

```gdscript
# Blend weight for a feature `d` metres from the road centerline: 1 at/inside
# `inner` (= width/2), 0 at/beyond `outer` (= inner + transition), smoothstep
# between. Pure/static for easy testing.
static func smooth_ramp(d: float, inner: float, outer: float) -> float:
	if d <= inner:
		return 1.0
	if d >= outer:
		return 0.0
	var raw := (outer - d) / (outer - inner)
	return raw * raw * (3.0 - 2.0 * raw)


# Sample the terrain densely along the 2D centerline (x -> world x, y -> world z)
# and build the weighted road fields:
#   road_heights[v]  = nearest centerline sample's terrain height (per grid vertex)
#   road_blend[v]    = height blend weight (1 on road -> 0 at outer band edge)
#   track_weights[c] = colour blend weight per cell (same ramp, by cell centre)
# `transition_m` is the band width OUTSIDE width/2. Straight spans tessellate to
# just their endpoints, so each segment is sub-sampled at ROAD_SAMPLE_STEP_M.
func bake_track(centerline: Curve2D, width: float, transition_m: float) -> void:
	var rh: Dictionary = {}
	var rb: Dictionary = {}
	var tw: Dictionary = {}
	var v_best: Dictionary = {}  # vertex -> nearest distance so far
	var c_best: Dictionary = {}  # cell -> nearest distance so far
	var inner := width / 2.0
	var outer := inner + transition_m
	var reach := int(ceil(outer / CELL_M)) + 1
	var poly := centerline.tessellate()
	for i in range(1, poly.size()):
		var a := poly[i - 1]
		var b := poly[i]
		var seg_len := a.distance_to(b)
		var steps := int(ceil(seg_len / ROAD_SAMPLE_STEP_M)) + 1
		for s in steps + 1:
			var t := float(s) / float(steps) if steps > 0 else 0.0
			var p := a.lerp(b, t)
			var y := height_at(p.x, p.y)
			var vbx := roundi(p.x / CELL_M)
			var vbz := roundi(p.y / CELL_M)
			var cbx := floori(p.x / CELL_M)
			var cbz := floori(p.y / CELL_M)
			for dz in range(-reach, reach + 1):
				for dx in range(-reach, reach + 1):
					# Vertex (grid point) -> height field.
					var v := Vector2i(vbx + dx, vbz + dz)
					var dv := Vector2(v.x * CELL_M, v.y * CELL_M).distance_to(p)
					var wv := smooth_ramp(dv, inner, outer)
					if wv > 0.0 and (not v_best.has(v) or dv < v_best[v]):
						v_best[v] = dv
						rh[v] = y
						rb[v] = wv
					# Cell (centre) -> colour field.
					var c := Vector2i(cbx + dx, cbz + dz)
					var dc := Vector2((c.x + 0.5) * CELL_M, (c.y + 0.5) * CELL_M).distance_to(p)
					var wc := smooth_ramp(dc, inner, outer)
					if wc > 0.0 and (not c_best.has(c) or dc < c_best[c]):
						c_best[c] = dc
						tw[c] = wc
	road_heights = rh
	road_blend = rb
	track_weights = tw
```

- [ ] **Step 5: Blend height in `compute_chunk_data`**

In `scripts/terrain_manager.gd`, replace:

```gdscript
			# Flatten road vertices to the baked road height (mesh + collision).
			var vidx := Vector2i(coord.x * (SAMPLES - 1) + xi, coord.y * (SAMPLES - 1) + zi)
			if road_heights.has(vidx):
				h = road_heights[vidx]
```

with:

```gdscript
			# Blend road vertices toward the baked road height by their weight
			# (mesh + collision): w=1 fully flat, w=0 true terrain, between ramps.
			var vidx := Vector2i(coord.x * (SAMPLES - 1) + xi, coord.y * (SAMPLES - 1) + zi)
			if road_blend.has(vidx):
				h = lerpf(h, road_heights[vidx], road_blend[vidx])
```

- [ ] **Step 6: Blend colour in `cell_colors`**

In `scripts/terrain_manager.gd`, replace `cell_colors`:

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

with:

```gdscript
# Per-cell colours for one chunk's de-indexed mesh: default_cell_color blended
# toward track_color by the cell's colour weight (1 on road -> 0 off the band).
# Four identical entries per cell, in the same cell order as the mesh.
func cell_colors(coord: Vector2i) -> PackedColorArray:
	var per_edge := SAMPLES - 1
	var colors := PackedColorArray()
	colors.resize(per_edge * per_edge * 4)
	var ci := 0
	for zi in per_edge:
		for xi in per_edge:
			var cell := Vector2i(coord.x * per_edge + xi, coord.y * per_edge + zi)
			var w: float = track_weights.get(cell, 0.0)
			var c := default_cell_color.lerp(track_color, w)
			for k in 4:
				colors[ci * 4 + k] = c
			ci += 1
	return colors
```

- [ ] **Step 7: New `set_track` signature**

In `scripts/terrain_manager.gd`, replace `set_track`:

```gdscript
# Apply a track: store the painted cells/colour and baked road heights, then
# rebuild any currently-loaded chunks (mesh + collision) so colouring AND
# flattening take effect. At startup the ring is deferred (see build_initial),
# so _chunks is empty here and nothing rebuilds; chunks loaded later read the
# stored state in compute_chunk_data and bake it in at build time.
func set_track(cells: Dictionary, color: Color, road_height_map: Dictionary) -> void:
	track_cells = cells
	track_color = color
	road_heights = road_height_map
	for coord in _chunks:
		_chunks[coord].setup(self, coord)
```

with:

```gdscript
# Apply a track: bake the weighted height + colour fields from the centerline and
# store the colour, then rebuild any currently-loaded chunks (mesh + collision)
# so blending takes effect. At startup the ring is deferred (see build_initial),
# so _chunks is empty here and nothing rebuilds; chunks loaded later read the
# baked fields in compute_chunk_data / cell_colors at build time.
func set_track(centerline: Curve2D, width: float, transition_m: float, color: Color) -> void:
	track_color = color
	bake_track(centerline, width, transition_m)
	for coord in _chunks:
		_chunks[coord].setup(self, coord)
```

- [ ] **Step 8: Update `world.gd`**

In `scripts/world.gd`, replace the tail of `_generate_track`:

```gdscript
	var road_heights: Dictionary = $Floor.bake_road(result["centerline"], cfg.track_width)
	$Floor.set_track(result["cells"], cfg.track_color, road_heights)
	$Floor.build_initial()
```

with:

```gdscript
	var transition_m := cfg.track_transition_cells * TerrainManager.CELL_M
	$Floor.set_track(result["centerline"], cfg.track_width, transition_m, cfg.track_color)
	$Floor.build_initial()
```

- [ ] **Step 9: Run to verify it passes**

Run (background): `./run_tests.sh --fast terrain`
Expected: PASS. Then run (background): `./run_tests.sh --fast smoke` — expected PASS.

- [ ] **Step 10: Visually confirm**

Run: `/Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot res://main.tscn`
Expected: the road edge now ramps smoothly into the terrain over ~3 cells (no hard vertical step), with the track colour fading to terrain colour across the same band. (Manual check; close the window.)

- [ ] **Step 11: Checkpoint** — weighted edge blending works in tests + game.

---

## Task 3: Documentation + final full test run

**Files:**
- Modify: `features/terrain.md`, `features/track.md`

- [ ] **Step 1: Update `features/terrain.md`**

In the track-overlay section, replace the flattening description: the fields are
now weighted — `road_heights` (vertex → nearest road Y), `road_blend` (vertex →
height blend weight), `track_weights` (cell → colour blend weight); all ramp
`1→0` across a transition band outside `width/2`. Document `smooth_ramp(d, inner,
outer)` (smoothstep), `bake_track(centerline, width, transition_m)` (builds all
three fields), that `compute_chunk_data` lerps height by `road_blend` (mesh +
collision) and `cell_colors` lerps colour by `track_weights`, and the new
`set_track(centerline, width, transition_m, color)`. Note `track_cells` and
`bake_road` were removed.

- [ ] **Step 2: Update `features/track.md`**

In the Rendering section, note the road edge **feathers** over
`track_transition_cells` cells (default 3) just outside `track_width/2` — both
the terrain height (mesh + collision) and the cell colour blend smoothly from the
flat road to the true terrain (smoothstep). Add `track_transition_cells` to the
Configuration list.

- [ ] **Step 3: Final full test run**

Confirm no background `run_tests.sh` is running, then run the FULL suite
(background): `./run_tests.sh`
Expected: ends with `ALL TESTS PASSED`, no `SCRIPT ERROR` / `Parse Error`.

- [ ] **Step 4: Checkpoint** — feature complete: smoothing, tests, docs in sync.

---

## Self-Review notes

- **Spec coverage:** config cells (Task 1); weighted height + colour fields, `smooth_ramp`, `bake_track`, blended `compute_chunk_data`/`cell_colors`, new `set_track`, removal of `track_cells`/`bake_road` (Task 2); world wiring (Task 2 step 8); tests incl. midpoint weight, band membership, height blend, colour blend, set_track rebuild, smoke (Task 2); docs (Task 3).
- **Type consistency:** `smooth_ramp(d, inner, outer) -> float` (static); `bake_track(centerline: Curve2D, width: float, transition_m: float) -> void`; `set_track(centerline: Curve2D, width: float, transition_m: float, color: Color)`; fields `road_heights`/`road_blend`/`track_weights`. `world` computes `transition_m = cfg.track_transition_cells * TerrainManager.CELL_M` and calls the 4-arg `set_track`. No remaining `track_cells` / `bake_road` references (tests updated in Task 2).
- **No git:** Checkpoints replace commits.
