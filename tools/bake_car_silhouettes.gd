extends SceneTree
# CAR SILHOUETTE BAKER — turns each authored car body model into a 2D side-profile outline
# that the overworld map's CAR pin can draw, so a prize-car pin shows THAT car rather than
# one generic hatchback.
#
# RUN IT (no scene, no tests, a couple of seconds):
#
#   /Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot --headless \
#       --path . -s tools/bake_car_silhouettes.gd
#
# Switches, appended after the script path as `++name=value` (Godot eats bare `--`):
#   ++res=72         mask resolution along the car's LONG axis, in cells (default 72)
#   ++epsilon=0.9    contour simplification, in mask cells (default 0.9)
#   ++dry            print the ASCII previews and the point counts, write nothing
#
# It OVERWRITES res://scripts/car_silhouettes.gd, which is committed as source — the game
# never runs this baker. Rerun it after adding a car, changing a body .glb, or re-seating a
# body in car.tscn. See features/overworld.md -> "Car pin silhouettes".
#
# ------------------------------------------------------------------------------------------
# WHY AN OUTLINE, AND WHY THE SIDE VIEW
#
# The pin glyphs are code-drawn polygons in a unit box (see overworld_map.gd's "PIN GLYPHS"
# header) because the web export has no system fonts and icons must be shapes we draw
# ourselves. Baking a PNG per car would add nine binary files, lose recolouring (pins are
# tinted by STATE) and need a real GPU to capture; a polygon drops straight into the existing
# `draw_colored_polygon` path, scales from the ~14 px minimap glyph to the full map's, and can
# be produced headless because mesh vertex data is CPU-side.
#
# The projection is the SIDE view (car's -Z forward to screen +x, up to screen -y). It is the
# only one of the three where cars differ readably at icon size: the roofline, the bonnet
# slope and the wheel arches are the whole difference between a kei van, a fastback coupe and
# a muscle car. Top-down collapses all nine to the same rounded rectangle and front-on to the
# same trapezoid.
#
# A CONVEX HULL IS NOT ENOUGH — it flattens the roofline into a single wedge, which is exactly
# the information that tells the cars apart. So the triangles are projected into a small
# coverage mask and the mask's boundary is traced (BitMap.opaque_to_polygons, the same tracer
# tree_silhouette.gd uses), then simplified to a few dozen points.
#
# WHEELS are not in the body .glb (they are procedural in car.tscn), so they are stamped into
# the mask as discs from the spec's `wheelbase` / `wheel_radius` at the scene's wheel mount
# height. Without them a body outline reads as a bar of soap.
#
# TYPING NOTE. `-s` compiles this before the SceneTree and the autoloads exist, so CarLibrary
# is reached through `load()` and kept untyped — the same reason tools/analyse_road_grades.gd
# does.

const OUT_PATH := "res://scripts/car_silhouettes.gd"
const CAR_SCENE := "res://car.tscn"  # duplicated from Scenes.CAR (scripts/scenes.gd): this
# tool runs via `-s`, compiled before the SceneTree/autoloads exist (see the TYPING NOTE
# above), and Scenes.gd itself references the Config autoload, so importing it here fails
# compilation the same way CarLibrary does — hence the untyped load() there and the literal
# here instead of a Scenes reference.
const WHEEL_MOUNT_Y := -0.1   # car.tscn's VehicleWheel3D mount height; car.gd preserves it
const PAD_CELLS := 1          # empty border so a contour never runs along the mask edge

var _res := 72
var _epsilon := 0.9
var _dry := false


func _initialize() -> void:
	# One frame so the autoloads have registered before anything is loaded.
	await process_frame
	_run()
	# ALWAYS quit: an un-quit SceneTree idles forever and the run has to be killed.
	quit()


func _run() -> void:
	_parse_args()
	var lib = load("res://scripts/car_library.gd")
	var bodies := _body_scene_paths()
	var baked: Array = []          # [id, PackedVector2Array]
	for spec: Dictionary in lib.CARS:
		var id := String(spec.get("id", ""))
		if not bool(spec.get("use_model", false)):
			print("skip %s: procedural body (no model), pin keeps the generic glyph" % id)
			continue
		var node_name := String(spec.get("model_node", ""))
		if not bodies.has(node_name):
			printerr("skip %s: %s is not instanced in %s" % [id, node_name, CAR_SCENE])
			continue
		var shape := _outline_for(spec, bodies[node_name])
		var outline: PackedVector2Array = shape.get("outline", PackedVector2Array())
		if outline.size() < 3:
			printerr("skip %s: traced no usable contour" % id)
			continue
		var defect := _defects(outline)
		if defect != "":
			printerr("%s: traced outline is not a simple loop (%s) — try ++res / ++epsilon"
					% [id, defect])
		baked.append([id, shape])
		print("%-12s %3d points  %s  wheel r %.3f%s" % [
			id, outline.size(), _extent_note(outline), shape["wheel_r"],
			"" if defect == "" else "  DEFECT: " + defect])
		_print_preview(id, outline)
	if _dry:
		print("\n++dry — nothing written")
		return
	_write(baked)


# ==========================================================================================
# Projection and tracing
# ==========================================================================================

# The car's side profile in the pin glyph's unit box: x in -1..1 nose to the RIGHT, y DOWN,
# the LONGER axis spanning the full -1..1 and the shorter one centred inside it (so the
# aspect ratio is the real car's, and a long low coupe does not get stretched to a van).
#
# Returns {"outline": PackedVector2Array, "wheels": PackedVector2Array, "wheel_r": float} —
# the wheels ride in the outline (so the traced loop is the WHOLE car and PolygonIcon can
# rasterise it from the outline alone) AND come back as centres + a radius, so the pin painter
# can lay crisp circles over them the way the generic glyph already does. Both are needed: a
# body-only outline reads as a bar of soap, but at 14 px a traced arch is four jagged cells
# whereas draw_circle is a clean wheel.
func _outline_for(spec: Dictionary, scene_path: String) -> Dictionary:
	var empty := {"outline": PackedVector2Array(), "wheels": PackedVector2Array(), "wheel_r": 0.0}
	var pts := _side_points(spec, scene_path)
	if pts.is_empty():
		return empty
	var wheels := _wheel_discs(spec)
	var lo := pts[0]
	var hi := pts[0]
	for i in range(0, pts.size()):
		lo = Vector2(minf(lo.x, pts[i].x), minf(lo.y, pts[i].y))
		hi = Vector2(maxf(hi.x, pts[i].x), maxf(hi.y, pts[i].y))
	for disc: Array in wheels:
		var c: Vector2 = disc[0]
		var r: float = disc[1]
		lo = Vector2(minf(lo.x, c.x - r), minf(lo.y, c.y - r))
		hi = Vector2(maxf(hi.x, c.x + r), maxf(hi.y, c.y + r))
	var span := hi - lo
	var long_axis := maxf(span.x, span.y)
	if long_axis <= 0.0:
		return empty
	var cells := float(_res) / long_axis          # mask cells per metre
	var w := int(ceil(span.x * cells)) + PAD_CELLS * 2
	var h := int(ceil(span.y * cells)) + PAD_CELLS * 2
	if w < 3 or h < 3:
		return empty
	var mask := _blank(w, h)
	# Body triangles first, then the wheel discs unioned on top, so the trace is one loop
	# around body-plus-wheels rather than three disjoint shapes.
	for t in range(0, pts.size() - 2, 3):
		_fill_triangle(mask, w, h,
				(pts[t] - lo) * cells, (pts[t + 1] - lo) * cells, (pts[t + 2] - lo) * cells)
	for disc: Array in wheels:
		_fill_disc(mask, w, h, (disc[0] - lo) * cells, disc[1] * cells)

	var bm := BitMap.new()
	bm.create(Vector2i(w, h))
	for y in h:
		for x in w:
			if mask[y * w + x]:
				bm.set_bitv(Vector2i(x, y), true)
	var polys := bm.opaque_to_polygons(Rect2i(0, 0, w, h), _epsilon)
	# Largest traced contour = the car. Any others are stray shards (a mirror, a spoiler tip
	# that the mask resolution disconnected) and would draw as detached blobs at 14 px.
	var best := PackedVector2Array()
	var best_area := 0.0
	for poly: PackedVector2Array in polys:
		if poly.size() < 3:
			continue
		var area := absf(_signed_area(poly))
		if area > best_area:
			best_area = area
			best = poly
	if best.size() < 3:
		return empty
	if _signed_area(best) < 0.0:
		best.reverse()
	# Wheel centres go through the SAME mask->unit-box mapping as the outline, so the circles
	# land exactly on the arches they were stamped into.
	var hubs := PackedVector2Array()
	for disc: Array in wheels:
		hubs.append(_px_to_unit((disc[0] - lo) * cells + Vector2(PAD_CELLS, PAD_CELLS), w, h))
	return {
		"outline": _to_unit_box(best, w, h),
		"wheels": hubs,
		"wheel_r": snappedf(wheels[0][1] * cells * 2.0 / float(maxi(w, h)), 0.001),
	}


# Every body triangle as flat (x = forward, y = down) points, in CAR space — the body's
# car.tscn transform is applied, which is where the per-model 90 deg yaw and ride-height
# offset live, so all nine end up nose-forward on the same ground plane.
func _side_points(spec: Dictionary, scene_path: String) -> PackedVector2Array:
	var packed := load(scene_path) as PackedScene
	if packed == null:
		return PackedVector2Array()
	var root := packed.instantiate()
	var body_xform: Transform3D = _body_transform(String(spec.get("model_node", "")))
	var out := PackedVector2Array()
	_gather(root, body_xform, out)
	root.free()
	return out


func _gather(node: Node, xform: Transform3D, out: PackedVector2Array) -> void:
	var here := xform
	if node is Node3D:
		here = xform * (node as Node3D).transform
	var mi := node as MeshInstance3D
	if mi != null and mi.mesh != null:
		for v in mi.mesh.get_faces():
			var p: Vector3 = here * v
			# Car forward is -Z, so -z becomes screen +x (nose right); up becomes -y (down).
			out.append(Vector2(-p.z, -p.y))
	for child in node.get_children():
		_gather(child, here, out)


# The two wheels as (centre, radius) discs in the same flat space. Axles sit at
# +/- wheelbase/2 along Z about the body origin (car.gd `_layout_wheels`), at the scene's
# mount height, so this matches what the game actually draws.
func _wheel_discs(spec: Dictionary) -> Array:
	var half_base: float = float(spec.get("wheelbase", 2.4)) * 0.5
	var r: float = float(spec.get("wheel_radius", 0.3))
	var y := -WHEEL_MOUNT_Y
	return [[Vector2(half_base, y), r], [Vector2(-half_base, y), r]]


# The body node's transform as authored in car.tscn, parsed out of the scene text rather than
# hardcoded: the yaw differs per model (some .glb face +Z, some -Z) and re-seating a body in
# the editor must not silently rotate its icon.
func _body_transform(node_name: String) -> Transform3D:
	var scene := load(CAR_SCENE) as PackedScene
	if scene == null:
		return Transform3D.IDENTITY
	var state := scene.get_state()
	for i in state.get_node_count():
		if String(state.get_node_name(i)) != node_name:
			continue
		for p in state.get_node_property_count(i):
			if String(state.get_node_property_name(i, p)) == "transform":
				return state.get_node_property_value(i, p) as Transform3D
	return Transform3D.IDENTITY


# node name -> .glb path for every body instanced into car.tscn.
func _body_scene_paths() -> Dictionary:
	var scene := load(CAR_SCENE) as PackedScene
	var out: Dictionary = {}
	if scene == null:
		return out
	var state := scene.get_state()
	for i in state.get_node_count():
		var inst := state.get_node_instance(i)
		if inst == null:
			continue
		out[String(state.get_node_name(i))] = inst.resource_path
	return out


# ==========================================================================================
# Mask helpers
# ==========================================================================================

func _blank(w: int, h: int) -> Array:
	var a: Array = []
	a.resize(w * h)
	a.fill(false)
	return a


func _fill_triangle(mask: Array, w: int, h: int, a: Vector2, b: Vector2, c: Vector2) -> void:
	var x0 := clampi(int(floor(minf(a.x, minf(b.x, c.x)))) + PAD_CELLS, 0, w - 1)
	var x1 := clampi(int(ceil(maxf(a.x, maxf(b.x, c.x)))) + PAD_CELLS, 0, w - 1)
	var y0 := clampi(int(floor(minf(a.y, minf(b.y, c.y)))) + PAD_CELLS, 0, h - 1)
	var y1 := clampi(int(ceil(maxf(a.y, maxf(b.y, c.y)))) + PAD_CELLS, 0, h - 1)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			if mask[y * w + x]:
				continue
			var p := Vector2(x - PAD_CELLS + 0.5, y - PAD_CELLS + 0.5)
			if _in_triangle(p, a, b, c):
				mask[y * w + x] = true


func _in_triangle(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> bool:
	var d1 := (b - a).cross(p - a)
	var d2 := (c - b).cross(p - b)
	var d3 := (a - c).cross(p - c)
	var neg := d1 < 0.0 or d2 < 0.0 or d3 < 0.0
	var pos := d1 > 0.0 or d2 > 0.0 or d3 > 0.0
	return not (neg and pos)


func _fill_disc(mask: Array, w: int, h: int, centre: Vector2, r: float) -> void:
	var x0 := clampi(int(floor(centre.x - r)) + PAD_CELLS, 0, w - 1)
	var x1 := clampi(int(ceil(centre.x + r)) + PAD_CELLS, 0, w - 1)
	var y0 := clampi(int(floor(centre.y - r)) + PAD_CELLS, 0, h - 1)
	var y1 := clampi(int(ceil(centre.y + r)) + PAD_CELLS, 0, h - 1)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var p := Vector2(x - PAD_CELLS + 0.5, y - PAD_CELLS + 0.5)
			if p.distance_to(centre) <= r:
				mask[y * w + x] = true


func _signed_area(poly: PackedVector2Array) -> float:
	var a := 0.0
	for i in poly.size():
		var p := poly[i]
		var q := poly[(i + 1) % poly.size()]
		a += p.x * q.y - q.x * p.y
	return a * 0.5


# Mask pixels -> the glyph unit box: longer axis spans -1..1, shorter axis centred.
func _to_unit_box(poly: PackedVector2Array, w: int, h: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in poly:
		out.append(_px_to_unit(p, w, h))
	return out


func _px_to_unit(p: Vector2, w: int, h: int) -> Vector2:
	var long_px := float(maxi(w, h))
	return Vector2(
		snappedf((p.x - w * 0.5) * 2.0 / long_px, 0.001),
		snappedf((p.y - h * 0.5) * 2.0 / long_px, 0.001))


# ==========================================================================================
# Reporting and output
# ==========================================================================================

# Self-intersection / degeneracy check on a traced loop. `decompose_polygon_in_convex` and
# `is_point_in_polygon` both assume a simple (non-self-crossing) polygon, and the mask tracer
# CAN produce a pinch where a wheel meets the body across a single diagonal cell — so the baker
# says so out loud rather than shipping a shape that draws as a mess. Returns "" when clean.
func _defects(poly: PackedVector2Array) -> String:
	var n := poly.size()
	if n < 3:
		return "fewer than 3 points"
	for i in n:
		if poly[i].is_equal_approx(poly[(i + 1) % n]):
			return "duplicate consecutive point at %d" % i
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		for j in range(i + 1, n):
			# Skip the neighbours that legitimately share an endpoint.
			if j == i or (j + 1) % n == i or j == (i + 1) % n:
				continue
			var c := poly[j]
			var d := poly[(j + 1) % n]
			if Geometry2D.segment_intersects_segment(a, b, c, d) != null:
				return "segments %d and %d cross" % [i, j]
	return ""


func _extent_note(poly: PackedVector2Array) -> String:
	var lo := poly[0]
	var hi := poly[0]
	for p in poly:
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
	return "extent %.2f x %.2f" % [hi.x - lo.x, hi.y - lo.y]


# An ASCII rendering of the FINAL polygon (not the mask), which is what catches a body that
# came out mirrored, upside down or shredded by simplification.
func _print_preview(id: String, poly: PackedVector2Array) -> void:
	var lo := poly[0]
	var hi := poly[0]
	for q in poly:
		lo = Vector2(minf(lo.x, q.x), minf(lo.y, q.y))
		hi = Vector2(maxf(hi.x, q.x), maxf(hi.y, q.y))
	var span := hi - lo
	var cols := 76
	# Halve the row count for the ~2:1 aspect of a terminal cell, so the preview is not
	# vertically stretched — a squashed preview hides exactly the roofline detail it is for.
	var rows: int = maxi(4, int(round(cols * span.y / maxf(span.x, 0.001) * 0.5)))
	var lines: Array[String] = []
	for r in rows:
		var line := ""
		for c in cols:
			var p := lo + Vector2(
				(c + 0.5) / cols * span.x,
				(r + 0.5) / rows * span.y)
			line += "#" if Geometry2D.is_point_in_polygon(p, poly) else "."
		lines.append(line)
	print("  --- %s ---" % id)
	for line in lines:
		print("  " + line)


func _write(baked: Array) -> void:
	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if f == null:
		printerr("cannot write %s" % OUT_PATH)
		return
	f.store_string(_header())
	for row: Array in baked:
		var shape: Dictionary = row[1]
		f.store_string("\t\"%s\": {\n" % row[0])
		f.store_string("\t\t\"outline\": PackedVector2Array([\n")
		f.store_string(_points_block(shape["outline"], "\t\t\t"))
		f.store_string("\t\t]),\n")
		f.store_string("\t\t\"wheels\": PackedVector2Array([\n")
		f.store_string(_points_block(shape["wheels"], "\t\t\t"))
		f.store_string("\t\t]),\n")
		f.store_string("\t\t\"wheel_r\": %s,\n" % String.num(shape["wheel_r"], 3).pad_decimals(3))
		f.store_string("\t},\n")
	f.store_string(_footer())
	f.close()
	print("\nwrote %s (%d cars)" % [OUT_PATH, baked.size()])
	_verify()


# Load the file we just wrote and exercise its accessors — this is what catches an output
# that parses in principle but not in GDScript (a `const` that is not a constant expression
# bit exactly here once), and a convex decomposition that comes back empty.
func _verify() -> void:
	var baked = load(OUT_PATH)
	if baked == null:
		printerr("VERIFY FAILED: %s does not load" % OUT_PATH)
		return
	for id: String in baked.SILHOUETTES.keys():
		var pieces: int = baked.convex_pieces(id).size()
		if pieces == 0:
			printerr("VERIFY FAILED: %s decomposes into no convex pieces" % id)
		else:
			print("verify %-12s %d convex pieces, %d wheels" % [
				id, pieces, baked.wheels(id).size()])
	if not baked.convex_pieces("__no_such_model__").is_empty():
		printerr("VERIFY FAILED: an unknown model must yield no pieces (the fallback cue)")


# One wrapped, indented block of `Vector2(x, y),` literals.
func _points_block(poly: PackedVector2Array, indent: String) -> String:
	var out := ""
	var line := indent
	for i in poly.size():
		var piece := "Vector2(%s, %s)," % [
			String.num(poly[i].x, 3).pad_decimals(3), String.num(poly[i].y, 3).pad_decimals(3)]
		if line.length() + piece.length() > 96:
			out += line.rstrip(" ") + "\n"
			line = indent
		line += piece + " "
	if line.strip_edges() != "":
		out += line.rstrip(" ") + "\n"
	return out


func _header() -> String:
	return """class_name CarSilhouettes
extends RefCounted
# GENERATED — DO NOT EDIT BY HAND. Regenerate with:
#
#   /Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot --headless \\
#       --path . -s tools/bake_car_silhouettes.gd
#
# Side-profile silhouettes traced from each car BODY model plus that car's own wheels, in the
# overworld pin glyph's unit box (x -1..1 nose to the RIGHT, y DOWN, longer axis spanning the
# full box, true side-on aspect ratio). Keyed by CarLibrary model id. Baked as source so the
# game never runs the tracer at load; see tools/bake_car_silhouettes.gd for the projection and
# features/overworld.md for the wiring.
#
# Per car: "outline" is the whole car as ONE closed loop (body and wheels already unioned, so
# a rasteriser like PolygonIcon needs nothing else); "wheels" + "wheel_r" are the same two
# wheels as centres and a radius, for a painter that would rather lay crisp circles over the
# traced arches at 14 px.
#
# REBAKE WHEN: a body .glb changes, a body is re-seated in car.tscn, a car is added, or a
# car's `wheelbase` / `wheel_radius` is retuned — the wheels here come from those authored
# values, so an icon can otherwise go quietly stale.
#
# A model with no entry here (a car added since the last bake, or a procedural-body car) is
# NOT an error — the caller falls back to the generic car glyph.

# NOTE static var, not const: a `const` initialiser must be a constant expression and a
# PackedVector2Array constructor is not one, so this mirrors overworld_map.gd's own glyph
# arrays, which are `static var` for the same reason. Treat it as read-only.
static var SILHOUETTES: Dictionary = {
"""


func _footer() -> String:
	return """}

# Cache of convex decompositions, built on first use per model. `draw_colored_polygon` is
# happiest with convex input (see overworld_map.gd's glyph header), and a traced car outline is
# concave at the wheel gap and under the windscreen, so each outline is split once into convex
# pieces and the pieces are reused for every subsequent draw — the pins repaint every frame.
static var _convex: Dictionary = {}


## Whether anything is baked for this model id. The caller's cue to use its own generic glyph.
static func has(model_id: String) -> bool:
	return SILHOUETTES.has(model_id)


## The traced outline for a model id, or an EMPTY array when nothing is baked for it — the
## caller must fall back to its own generic shape rather than drawing nothing.
static func outline(model_id: String) -> PackedVector2Array:
	var shape: Dictionary = SILHOUETTES.get(model_id, {})
	return shape.get("outline", PackedVector2Array())


## The two wheel CENTRES, in the same unit box as the outline. Empty for an unknown model.
static func wheels(model_id: String) -> PackedVector2Array:
	var shape: Dictionary = SILHOUETTES.get(model_id, {})
	return shape.get("wheels", PackedVector2Array())


## The wheel radius, in the same unit box as the outline. 0.0 for an unknown model.
static func wheel_radius(model_id: String) -> float:
	var shape: Dictionary = SILHOUETTES.get(model_id, {})
	return float(shape.get("wheel_r", 0.0))


## The silhouette as convex pieces, ready to hand to `draw_colored_polygon` one at a time.
## Empty for an unknown model, and empty (not partial) if the decomposition fails.
static func convex_pieces(model_id: String) -> Array:
	if _convex.has(model_id):
		return _convex[model_id]
	var poly := outline(model_id)
	var pieces: Array = []
	if poly.size() >= 3:
		for piece: PackedVector2Array in Geometry2D.decompose_polygon_in_convex(poly):
			if piece.size() >= 3:
				pieces.append(piece)
	_convex[model_id] = pieces
	return pieces
"""


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if not arg.begins_with("++"):
			continue
		var body := arg.substr(2)
		var key := body.get_slice("=", 0)
		var value := body.substr(key.length() + 1)
		match key:
			"res":
				_res = maxi(8, int(value))
			"epsilon":
				_epsilon = maxf(0.0, float(value))
			"dry":
				_dry = true
