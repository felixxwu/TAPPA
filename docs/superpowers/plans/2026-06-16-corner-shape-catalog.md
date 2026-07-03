# Corner Shape Catalog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Define each rally pacenote turn type as a 2D bezier (`Curve2D`) in a GDScript library, and add a standalone 2D catalog scene that draws every turn type side by side for visual confirmation.

**Architecture:** A `CornerLibrary` script (`class_name … extends RefCounted`, mirroring the existing `CarLibrary`) holds a `const CORNERS: Array[Dictionary]` of hand-authored control points and a `build_curve()` helper that turns one entry into a `Curve2D`. A `Node2D` catalog scene (`corner_catalog.tscn` + `scripts/corner_catalog.gd`) loads the library, lays the curves out left-to-right, and draws each one's centerline, control points, tangent handles, entry marker, and a text label.

**Tech Stack:** Godot 4.6 (GL Compatibility), GDScript, GUT for headless tests. Coordinates are in meters (1 unit = 1 m); entry at the origin heading +Y; right turns.

> **NOTE — this project is intentionally NOT under git.** Ignore the usual "commit" steps. Each task ends with a **Checkpoint** (run tests / confirm state) instead of a `git commit`. Do not run any `git` commands.

> **Testing rules (from CLAUDE.md):** Always run `./run_tests.sh` (or `./run_tests.sh --fast corner` for iteration) with `run_in_background: true` and wait for the completion notification — never in the foreground. Before starting a run, check no background `run_tests.sh` is already running. The Godot binary is `/Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot` (override with `$GODOT`).

---

## File Structure

- Create: `scripts/corner_library.gd` — `CornerLibrary`: the `const CORNERS` data + `build_curve()`. One responsibility: the corner shape data.
- Create: `tests/headless/test_corner_library.gd` — GUT tests for the library and `build_curve()`.
- Create: `scripts/corner_catalog.gd` — `CornerCatalog`: the catalog scene's draw/layout logic.
- Create: `corner_catalog.tscn` — the runnable catalog scene (root `Node2D` with the script attached), at the project root alongside `main.tscn` / `car.tscn`.
- Create: `features/track.md` — feature doc for the track-generation area (starts with this catalog).
- Modify: `features/README.md` — add the `track.md` row to the feature index and the file-to-feature quick map.

---

## Task 1: Corner library data + `build_curve()`

**Files:**
- Create: `scripts/corner_library.gd`
- Test: `tests/headless/test_corner_library.gd`

- [ ] **Step 1: Write the failing test**

Create `tests/headless/test_corner_library.gd`:

```gdscript
extends GutTest
# The corner shape library (CornerLibrary): every pacenote turn type is a set of
# hand-authored Curve2D control points (meters; entry at origin heading +Y).
# build_curve() must turn each entry into a usable Curve2D, names must be unique,
# and the full standard set (1-6, Square, Hairpin, Straight, one compound) present.

const CornerLibrary = preload("res://scripts/corner_library.gd")

const EXPECTED := [
	"1", "2", "3", "4", "5", "6",
	"Square", "Hairpin", "Straight", "Right 4 tightens 2",
]


func test_library_has_the_expected_corners() -> void:
	var names := {}
	for spec in CornerLibrary.CORNERS:
		names[spec["name"]] = true
	assert_eq(names.size(), CornerLibrary.CORNERS.size(), "corner names are unique")
	for want in EXPECTED:
		assert_true(names.has(want), "library contains '%s'" % want)


func test_build_curve_produces_a_usable_curve_for_every_corner() -> void:
	for spec in CornerLibrary.CORNERS:
		var who: String = spec["name"]
		var curve := CornerLibrary.build_curve(spec)
		assert_true(curve is Curve2D, who + " builds a Curve2D")
		assert_gte(curve.point_count, 2, who + " has at least 2 points")
		# A non-degenerate shape: tessellated polyline has measurable length.
		var pts := curve.tessellate()
		var length := 0.0
		for i in range(1, pts.size()):
			length += pts[i].distance_to(pts[i - 1])
		assert_gt(length, 0.0, who + " has positive length")


func test_first_point_is_at_origin() -> void:
	# Every corner enters at the origin so they share a common anchor for layout.
	for spec in CornerLibrary.CORNERS:
		var curve := CornerLibrary.build_curve(spec)
		assert_almost_eq(curve.get_point_position(0), Vector2.ZERO, Vector2(0.001, 0.001),
			spec["name"] + " starts at the origin")
```

- [ ] **Step 2: Run the test to verify it fails**

Run (background): `./run_tests.sh --fast corner`
Expected: FAIL / script error — `res://scripts/corner_library.gd` does not exist yet.

- [ ] **Step 3: Write the minimal implementation**

Create `scripts/corner_library.gd`. Each entry's `points` is an ordered list of
control points; each control point is `[position, in_control, out_control]` as
`Vector2` in meters, where `in_control`/`out_control` are **relative to the
position** (the form `Curve2D.add_point` expects). All values below are baked
(pre-computed) cubic-bezier arc handles — there is no runtime generator.

```gdscript
class_name CornerLibrary
extends RefCounted
# The rally pacenote turn-type shapes. Each corner is a 2D bezier (Curve2D),
# hand-authored as control points in meters, entry at the origin heading +Y,
# right-hand turns. The number gradient 1-6 goes from sharpest/tightest (1, ~85
# deg, ~15 m radius) to gentlest (6, ~12 deg, ~90 m radius); Square is a sharp
# ~90 deg, Hairpin ~180 deg, Straight a plain 50 m line. "Right 4 tightens 2" is
# a compound example proving authored multi-point curves work. The 2D curve is
# the source of truth; it will later be imprinted onto the 3D terrain surface.
#
# points entries: [position, in_control, out_control] (Vector2, meters); the
# in/out controls are relative to position, as Curve2D.add_point expects.

const CORNERS: Array[Dictionary] = [
	{ "name": "1", "points": [[Vector2(0.000, 0.000), Vector2(0.000, 0.000), Vector2(0.000, 7.778)], [Vector2(13.693, 14.943), Vector2(-7.748, -0.678), Vector2(0.000, 0.000)]] },
	{ "name": "2", "points": [[Vector2(0.000, 0.000), Vector2(0.000, 0.000), Vector2(0.000, 9.249)], [Vector2(14.476, 20.673), Vector2(-8.691, -3.163), Vector2(0.000, 0.000)]] },
	{ "name": "3", "points": [[Vector2(0.000, 0.000), Vector2(0.000, 0.000), Vector2(0.000, 10.440)], [Vector2(13.646, 26.213), Vector2(-8.552, -5.988), Vector2(0.000, 0.000)]] },
	{ "name": "4", "points": [[Vector2(0.000, 0.000), Vector2(0.000, 0.000), Vector2(0.000, 10.580)], [Vector2(10.528, 28.925), Vector2(-6.800, -8.104), Vector2(0.000, 0.000)]] },
	{ "name": "5", "points": [[Vector2(0.000, 0.000), Vector2(0.000, 0.000), Vector2(0.000, 9.492)], [Vector2(6.090, 27.470), Vector2(-4.011, -8.602), Vector2(0.000, 0.000)]] },
	{ "name": "6", "points": [[Vector2(0.000, 0.000), Vector2(0.000, 0.000), Vector2(0.000, 6.289)], [Vector2(1.967, 18.712), Vector2(-1.308, -6.152), Vector2(0.000, 0.000)]] },
	{ "name": "Square", "points": [[Vector2(0.000, 0.000), Vector2(0.000, 0.000), Vector2(0.000, 4.418)], [Vector2(8.000, 8.000), Vector2(-4.418, 0.000), Vector2(0.000, 0.000)]] },
	{ "name": "Hairpin", "points": [[Vector2(0.000, 0.000), Vector2(0.000, 0.000), Vector2(0.000, 4.971)], [Vector2(9.000, 9.000), Vector2(-4.971, 0.000), Vector2(4.971, 0.000)], [Vector2(18.000, 0.000), Vector2(0.000, 4.971), Vector2(0.000, 0.000)]] },
	{ "name": "Straight", "points": [[Vector2(0.000, 0.000), Vector2(0.000, 0.000), Vector2(0.000, 0.000)], [Vector2(0.000, 50.000), Vector2(0.000, 0.000), Vector2(0.000, 0.000)]] },
	{ "name": "Right 4 tightens 2", "points": [[Vector2(0.000, 0.000), Vector2(0.000, 0.000), Vector2(0.000, 10.580)], [Vector2(10.528, 28.925), Vector2(-6.800, -8.104), Vector2(2.482, 2.958)], [Vector2(19.857, 35.457), Vector2(-3.629, -1.321), Vector2(0.000, 0.000)]] },
]


# Assemble a Curve2D from one CORNERS entry. The single place point data becomes
# a curve, reused by the catalog scene and the tests.
static func build_curve(spec: Dictionary) -> Curve2D:
	var curve := Curve2D.new()
	for p in spec["points"]:
		curve.add_point(p[0], p[1], p[2])
	return curve
```

- [ ] **Step 4: Run the test to verify it passes**

Run (background): `./run_tests.sh --fast corner`
Expected: PASS — `test_corner_library.gd` green, no SCRIPT ERROR lines.

- [ ] **Step 5: Checkpoint**

Library and its tests are green. No git. Proceed to the scene.

---

## Task 2: Catalog scene

**Files:**
- Create: `scripts/corner_catalog.gd`
- Create: `corner_catalog.tscn`
- Test: add to `tests/headless/test_corner_library.gd`

- [ ] **Step 1: Write the failing test**

Append to `tests/headless/test_corner_library.gd`:

```gdscript
func test_catalog_scene_makes_one_label_per_corner() -> void:
	var scene := load("res://corner_catalog.tscn").instantiate()
	add_child_autofree(scene)
	await get_tree().process_frame  # let _ready() build the layout
	var labels := 0
	for child in scene.get_children():
		if child is Label:
			labels += 1
	assert_eq(labels, CornerLibrary.CORNERS.size(),
		"one name label per corner in the catalog")
	# Layout spreads corners across positive X (left-to-right row).
	assert_gt(scene.layout_width, 0.0, "catalog reports a positive laid-out width")
```

- [ ] **Step 2: Run the test to verify it fails**

Run (background): `./run_tests.sh --fast corner`
Expected: FAIL — `res://corner_catalog.tscn` does not exist.

- [ ] **Step 3: Write the scene script**

Create `scripts/corner_catalog.gd`:

```gdscript
class_name CornerCatalog
extends Node2D
# Standalone debug viewer: draws every CornerLibrary turn type side by side so
# the bezier shapes can be eyeballed. Centerline + control-point markers +
# tangent handles + an entry dot + a name label per corner. Pure 2D, no game
# nodes. Run this scene directly (it is not the project's main scene).

const CornerLibrary = preload("res://scripts/corner_library.gd")

const PX_PER_M := 6.0          # meters -> pixels
const GUTTER_PX := 48.0        # horizontal space between corners
const MARGIN_PX := 60.0        # left/top margin
const BASELINE_Y := 520.0      # screen Y of each corner's entry (origin) row
const CENTERLINE_COLOR := Color(0.36, 0.55, 1.0)
const HANDLE_COLOR := Color(0.9, 0.45, 0.45)
const POINT_COLOR := Color(0.95, 0.95, 0.95)
const ENTRY_COLOR := Color(0.49, 0.99, 0.0)

# One laid-out corner ready to draw, in screen space.
var _items: Array[Dictionary] = []
# Total horizontal extent used by the row (read by tests / for framing).
var layout_width := 0.0


func _ready() -> void:
	var cursor_x := MARGIN_PX
	for spec in CornerLibrary.CORNERS:
		var curve := CornerLibrary.build_curve(spec)
		var poly := curve.tessellate()  # PackedVector2Array, meters
		# Bounding box in meters to place this corner without overlap.
		var min_x := INF
		var max_x := -INF
		for p in poly:
			min_x = minf(min_x, p.x)
			max_x = maxf(max_x, p.x)
		var origin := Vector2(cursor_x - min_x * PX_PER_M, BASELINE_Y)
		_items.append({ "spec": spec, "curve": curve, "poly": poly, "origin": origin })
		_add_label(spec["name"], origin, poly)
		cursor_x += (max_x - min_x) * PX_PER_M + GUTTER_PX
	layout_width = cursor_x - MARGIN_PX
	queue_redraw()


# Convert a meters point (curve space, +Y up) to screen space (+Y down) for a
# corner anchored at `origin`.
func _to_screen(origin: Vector2, p: Vector2) -> Vector2:
	return origin + Vector2(p.x * PX_PER_M, -p.y * PX_PER_M)


func _add_label(text: String, origin: Vector2, poly: PackedVector2Array) -> void:
	# Place the label above the highest point of the curve.
	var top_y := origin.y
	for p in poly:
		top_y = minf(top_y, _to_screen(origin, p).y)
	var label := Label.new()
	label.text = text
	label.position = Vector2(origin.x - 10.0, top_y - 28.0)
	add_child(label)


func _draw() -> void:
	# Faint baseline so the common entry row is visible.
	draw_line(Vector2(0.0, BASELINE_Y), Vector2(layout_width + MARGIN_PX, BASELINE_Y),
		Color(1, 1, 1, 0.12), 1.0)
	for item in _items:
		var origin: Vector2 = item["origin"]
		var poly: PackedVector2Array = item["poly"]
		# Centerline.
		for i in range(1, poly.size()):
			draw_line(_to_screen(origin, poly[i - 1]), _to_screen(origin, poly[i]),
				CENTERLINE_COLOR, 3.0)
		# Control points + tangent handles.
		var curve: Curve2D = item["curve"]
		for i in range(curve.point_count):
			var pos := curve.get_point_position(i)
			var screen_pos := _to_screen(origin, pos)
			var in_ctrl := curve.get_point_in(i)
			var out_ctrl := curve.get_point_out(i)
			if in_ctrl != Vector2.ZERO:
				draw_line(screen_pos, _to_screen(origin, pos + in_ctrl), HANDLE_COLOR, 1.0)
				draw_circle(_to_screen(origin, pos + in_ctrl), 3.0, HANDLE_COLOR)
			if out_ctrl != Vector2.ZERO:
				draw_line(screen_pos, _to_screen(origin, pos + out_ctrl), HANDLE_COLOR, 1.0)
				draw_circle(_to_screen(origin, pos + out_ctrl), 3.0, HANDLE_COLOR)
			draw_circle(screen_pos, 4.0, POINT_COLOR)
		# Entry marker (first point).
		draw_circle(_to_screen(origin, curve.get_point_position(0)), 5.0, ENTRY_COLOR)
```

- [ ] **Step 4: Create the scene file**

Create `corner_catalog.tscn` (a root `Node2D` with the script and a dark
background `ColorRect` so the light strokes read). Write exactly:

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/corner_catalog.gd" id="1"]

[node name="CornerCatalog" type="Node2D"]
script = ExtResource("1")

[node name="Background" type="ColorRect" parent="."]
offset_right = 1280.0
offset_bottom = 960.0
color = Color(0.06, 0.07, 0.1, 1)
z_index = -1
```

- [ ] **Step 5: Run the test to verify it passes**

Run (background): `./run_tests.sh --fast corner`
Expected: PASS — the label-count and `layout_width` assertions are green, no SCRIPT ERROR lines.

- [ ] **Step 6: Visually confirm the scene**

Open and run the scene directly so the user can see all turn types laid out:

Run: `/Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot res://corner_catalog.tscn`
Expected: a window showing 10 corners in a left-to-right row — gradient 1–6 widening, Square, Hairpin, Straight, and the compound "Right 4 tightens 2" — each with a blue centerline, white control points, red tangent handles, a green entry dot, and a name label. (This is a manual visual check; close the window when done.)

- [ ] **Step 7: Checkpoint**

Library + scene complete and green.

---

## Task 3: Documentation

**Files:**
- Create: `features/track.md`
- Modify: `features/README.md`

- [ ] **Step 1: Write `features/track.md`**

Create `features/track.md`:

```markdown
# Track (corner shapes)

**Source:** `scripts/corner_library.gd` (`class_name CornerLibrary`),
`scripts/corner_catalog.gd` (`class_name CornerCatalog`), `corner_catalog.tscn`.

The start of the track-generation feature area. Right now it defines the
**shape vocabulary** for rally corners; sequencing corners into a course and
imprinting them onto terrain are future work.

## Corner shapes (`CornerLibrary`)

Each pacenote turn type is a 2D bezier curve (`Curve2D`), hand-authored as
control points in **meters**, with the entry at the origin heading **+Y** and
right-hand turns. The 2D curve is the source of truth; lifting it onto the 3D
terrain surface is a separate, future step.

- `CORNERS: Array[Dictionary]` — one entry per turn type: `name` plus `points`,
  an ordered list of `[position, in_control, out_control]` (Vector2, meters;
  in/out relative to position, as `Curve2D.add_point` expects). Values are baked
  (pre-computed) cubic-bezier arc handles — there is no runtime generator.
- `build_curve(spec)` — the single helper that turns one entry into a `Curve2D`.

The shipped set: the **gradient 1–6** (1 ≈ 85°/~15 m radius sharpest … 6 ≈
12°/~90 m radius gentlest — both angle and radius grow with the number),
**Square** (sharp ~90°), **Hairpin** (~180°), **Straight** (50 m line), and a
compound **"Right 4 tightens 2"** demonstrating authored multi-point corners.

## Catalog scene (`corner_catalog.tscn`)

A standalone 2D debug viewer (not the project main scene — run it directly). It
loads `CornerLibrary`, lays every corner out in a left-to-right row, and draws
each one's centerline, control-point markers, tangent handles, a green entry
dot, and a name label. Used to eyeball and tune the shapes.

## Tests

`tests/headless/test_corner_library.gd` — the library has the expected unique
corners, `build_curve` yields a non-degenerate `Curve2D` (≥ 2 points, positive
length, starts at origin) for each, and the catalog scene builds one label per
corner.
```

- [ ] **Step 2: Update `features/README.md`**

In the **Feature index** table, add this row after the `terrain.md` row:

```markdown
| [track.md](track.md) | Rally corner shape library (Curve2D pacenotes) + catalog scene |
```

In the **File-to-feature quick map** table, add this row after the `Terrain` row:

```markdown
| Corner shapes | `scripts/corner_library.gd`, `scripts/corner_catalog.gd`, `corner_catalog.tscn` |
```

- [ ] **Step 3: Final full test run**

Confirm no background `run_tests.sh` is already running, then run the FULL suite
(background): `./run_tests.sh`
Expected: ends with `ALL TESTS PASSED`, no SCRIPT ERROR / Parse Error lines.

- [ ] **Step 4: Checkpoint**

Feature complete: library, scene, tests, and docs all in sync.

---

## Self-Review notes

- **Spec coverage:** data model (Task 1), catalog set incl. compound (Task 1 data + Task 2 render), catalog scene as a `Node2D` with Line/`_draw` + labels (Task 2), testing (Tasks 1–3), docs `features/track.md` + README (Task 3). All spec sections covered.
- **Type consistency:** `CornerLibrary.CORNERS` and `build_curve(spec)` referenced identically across tasks and tests; `corner_catalog.gd` exposes `layout_width` used by the Task 2 test; scene path `res://corner_catalog.tscn` consistent.
- **No git:** every "commit" replaced by a Checkpoint per the project's no-git rule.
```
