class_name RoadPoles
extends RefCounted
# Docs: features/free-roam.md — update in the same change as this file.
# Tests: tests/headless/test_free_roam.gd — extend in the same change.
# Wooden electricity poles along every road with sagging wires between them, planned once at boot
# from the whole graph and built chunk by chunk (TerrainStreamer), like RoadBarriers. Now and then
# the line hops to the other side of the road, so its wires cross overhead.

const JUNCTION_CLEAR_M := 12.0
const PAD_CLEAR_M := 2.0
const SALT := 7919
const HEIGHT_M := 7.5
const ARM_HALF_M := 0.8
const ARM_Y := 7.1
const SINK_M := 0.5  # the drawn ground can sit a little below the exact height the pole stands on
const WIRE_SAG := 0.03  # metres of sag per metre of span
const WIRE_STEPS := 8

var poles := PackedVector2Array()
var across := PackedVector2Array()  # unit vector along each pole's cross-arm (across the road)
var wires: Array[Vector2i] = []  # pairs of pole indices
var _poles_by_chunk := {}  # Vector2i -> PackedInt32Array
var _wires_by_chunk := {}  # Vector2i -> Array of wire indices (the chunk holding its second pole)
var _chunk_m := 64.0


func plan(s: FreeRoamSettings, net: RoadNetwork, terrain: RoadTerrain, sites: RoadSites) -> void:
	poles.clear()
	across.clear()
	wires.clear()
	_poles_by_chunk.clear()
	_wires_by_chunk.clear()
	_chunk_m = s.chunk_m
	if s.pole_spacing_m <= 0.0:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = s.world_seed * SALT
	var ends := {}  # node -> the poles that end a road's line there
	for ei in net.edges.size():
		var pts := net.polyline(ei)
		var cum := PackedFloat64Array([0.0])
		for i in pts.size() - 1:
			cum.append(cum[i] + pts[i].distance_to(pts[i + 1]))
		var length := cum[cum.size() - 1]
		var side := 1.0 if rng.randf() < 0.5 else -1.0
		var prev := -1
		var first := -1
		var a := JUNCTION_CLEAR_M
		while a <= length - JUNCTION_CLEAR_M:
			if prev >= 0 and rng.randf() < s.pole_cross_chance:
				side = -side
			var i := clampi(cum.bsearch(a) - 1, 0, pts.size() - 2)
			var t := (pts[i + 1] - pts[i]).normalized()
			var perp := Vector2(-t.y, t.x)
			var q := pts[i].lerp(pts[i + 1], clampf((a - cum[i]) / maxf(cum[i + 1] - cum[i], 1e-6), 0.0, 1.0))
			var off := s.road_half_width_at(q.x, q.y) + s.pole_road_gap_m
			var p := q + perp * side * off
			# Keep off water, pads and the shoulder of any other road (a junction or a tight bend).
			if not (terrain.is_water(p.x, p.y) or not sites.is_clear(p, PAD_CLEAR_M) or net.nearest(p.x, p.y, off - 0.5)):
				var pi := poles.size()
				poles.append(p)
				across.append(perp)
				_append(_poles_by_chunk, _chunk_of(p), pi)
				# A skipped pole is bridged, but a longer run of them (a pad, a lake) breaks the line.
				if prev >= 0 and poles[prev].distance_to(p) <= _max_span(s, off):
					_wire(prev, pi)
				if first < 0:
					first = pi
				prev = pi
			a += s.pole_spacing_m
		if first >= 0:
			_append(ends, Vector2i(net.edges[ei].x, 0), first)
			_append(ends, Vector2i(net.edges[ei].y, 0), prev)
	# Where roads meet, every line ending there is wired to the first one, like a junction pole.
	for node: Vector2i in ends:
		var at: PackedInt32Array = ends[node]
		for k in range(1, at.size()):
			if at[k] != at[0] and poles[at[0]].distance_to(poles[at[k]]) <= s.pole_spacing_m * 2.0:
				_wire(at[0], at[k])


# The longest wire: across one skipped pole, from one side of the road to the other.
static func _max_span(s: FreeRoamSettings, off: float) -> float:
	return s.pole_spacing_m * 2.0 + off * 2.0


func _wire(a: int, b: int) -> void:
	_append(_wires_by_chunk, _chunk_of(poles[b]), wires.size())
	wires.append(Vector2i(a, b))


func _chunk_of(p: Vector2) -> Vector2i:
	return Vector2i(floori(p.x / _chunk_m), floori(p.y / _chunk_m))


static func _append(map: Dictionary, key: Vector2i, i: int) -> void:
	if not map.has(key):
		map[key] = PackedInt32Array()
	map[key].append(i)


# The pole nearest `p` within `max_d`, or -1.
func nearest(p: Vector2, max_d: float) -> int:
	var best := -1
	var best_d := max_d
	var c := _chunk_of(p)
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			for pi in poles_in_chunk(c + Vector2i(dx, dz)):
				var d := poles[pi].distance_to(p)
				if d < best_d:
					best_d = d
					best = pi
	return best


func poles_in_chunk(coord: Vector2i) -> PackedInt32Array:
	return _poles_by_chunk.get(coord, PackedInt32Array())


func wires_in_chunk(coord: Vector2i) -> PackedInt32Array:
	return _wires_by_chunk.get(coord, PackedInt32Array())


# A chunk's poles (solid, in the damage obstacle group) and the wires ending at them, standing on
# `ground` (a Callable(x, z) -> height that must give the same answer from any chunk).
func build(parent: Node3D, coord: Vector2i, ground: Callable) -> void:
	var root := Node3D.new()
	root.name = "Poles"
	parent.add_child(root)
	var body := StaticBody3D.new()
	body.add_to_group(DamageModel.OBSTACLE_GROUP)
	root.add_child(body)
	for pi in poles_in_chunk(coord):
		var at := _foot(pi, ground)
		var basis := Basis(Vector3.UP, atan2(-across[pi].y, across[pi].x))
		root.add_child(pole_instance(Transform3D(basis, at)))
		body.add_child(pole_shape(at))
	var spans: Array[PackedVector3Array] = []
	for wi in wires_in_chunk(coord):
		var a := _foot(wires[wi].x, ground)
		var b := _foot(wires[wi].y, ground)
		for k: float in [-1.0, 1.0]:
			var oa := Vector3(across[wires[wi].x].x, 0.0, across[wires[wi].x].y) * ARM_HALF_M * k
			var ob := Vector3(across[wires[wi].y].x, 0.0, across[wires[wi].y].y) * ARM_HALF_M * k
			spans.append(PackedVector3Array([a + oa + Vector3.UP * ARM_Y, b + ob + Vector3.UP * ARM_Y]))
	if not spans.is_empty():
		var mi := MeshInstance3D.new()
		mi.name = "Wires"
		mi.mesh = wire_mesh(spans)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(mi)


func _foot(pi: int, ground: Callable) -> Vector3:
	var p := poles[pi]
	return Vector3(p.x, float(ground.call(p.x, p.y)) - SINK_M, p.y)


static var _pole_mesh: ArrayMesh
static var _wire_mat: StandardMaterial3D


# One pole: a post with a cross-arm along local x, foot at the origin.
static func pole_instance(xf: Transform3D) -> MeshInstance3D:
	if _pole_mesh == null:
		var wood := StandardMaterial3D.new()
		wood.albedo_color = Color(0.25, 0.17, 0.1)
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var post := BoxMesh.new()
		post.size = Vector3(0.25, HEIGHT_M, 0.25)
		st.append_from(post, 0, Transform3D(Basis(), Vector3(0.0, HEIGHT_M * 0.5, 0.0)))
		var arm := BoxMesh.new()
		arm.size = Vector3(ARM_HALF_M * 2.0 + 0.3, 0.15, 0.15)
		st.append_from(arm, 0, Transform3D(Basis(), Vector3(0.0, ARM_Y - 0.1, 0.0)))
		st.set_material(wood)
		_pole_mesh = st.commit()
	var mi := MeshInstance3D.new()
	mi.mesh = _pole_mesh
	mi.transform = xf
	return mi


static func pole_shape(foot: Vector3) -> CollisionShape3D:
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.3, HEIGHT_M, 0.3)
	shape.shape = box
	shape.position = foot + Vector3(0.0, HEIGHT_M * 0.5, 0.0)
	return shape


# Sagging wires as thin lines, one per [from, to] pair.
static func wire_mesh(spans: Array[PackedVector3Array]) -> ArrayMesh:
	if _wire_mat == null:
		_wire_mat = StandardMaterial3D.new()
		_wire_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_wire_mat.albedo_color = Color(0.08, 0.08, 0.08)
	var verts := PackedVector3Array()
	for span in spans:
		var sag := span[0].distance_to(span[1]) * WIRE_SAG
		var last := span[0]
		for k in range(1, WIRE_STEPS + 1):
			var f := float(k) / WIRE_STEPS
			var p := span[0].lerp(span[1], f) - Vector3.UP * sag * 4.0 * f * (1.0 - f)
			verts.append(last)
			verts.append(p)
			last = p
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	mesh.surface_set_material(0, _wire_mat)
	return mesh
