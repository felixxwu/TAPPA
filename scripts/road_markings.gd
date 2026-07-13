class_name RoadMarkings
extends Node3D
# Static road paint along the TARMAC sections of a generated track — two solid
# edge lines just inside the shoulders plus a dashed centre line — so a tarmac
# stretch reads unmistakably as tarmac (gravel sections stay bare). Built ONCE at
# track generation from the road centerline (like the signs / arches); it never
# updates per frame. The paint is a single unshaded ArrayMesh laid a few cm above
# the road surface, its vertex colours carrying the same baked terrain light as the
# floor so the lines shade with the hills instead of glowing flat white.
#
# Created + wired by world.gd._generate_track once the centerline + surface split
# exist; rebuilt on a regeneration (entering a new event). See features/track.md.
#
# `terrain` is duck-typed (so flat test fixtures can pass null or a stub):
#   surface_at(x, z) -> Vector2(road_weight, tarmac_weight)  — paint only where tarmac
#   height_at(x, z)  -> float                                — road surface height
#   light_at(x, z)   -> Color                                — baked terrain light
# Each is optional; a null terrain reads as ground height 0, full tarmac, unlit white.

var _mesh_instance: MeshInstance3D
var _material: StandardMaterial3D


func _init() -> void:
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "MeshInstance3D"
	add_child(_mesh_instance)
	# Per-vertex colour = paint colour × baked terrain light (see _emit_line), so the
	# lines shade with the floor. Unshaded otherwise, like the tyre-mark ribbons.
	_material = PS1Material.unshaded(null, true)
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED


# (Re)build the paint mesh from a freshly generated centerline + surface split.
# `params` is GameConfig.road_marking_params(); see the header for `terrain`.
func build(centerline: Curve2D, terrain: Node, params: Dictionary) -> void:
	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	if centerline != null and params.get("enabled", true):
		var side: float = params["half_width"] - params["edge_inset_m"]
		var lw: float = params["width_m"]
		# Two solid edge lines (dash 0 = continuous) + a dashed centre line.
		_emit_line(verts, cols, centerline, terrain, params, side, lw, 0.0, 0.0)
		_emit_line(verts, cols, centerline, terrain, params, -side, lw, 0.0, 0.0)
		_emit_line(verts, cols, centerline, terrain, params, 0.0, lw,
			params["center_dash_m"], params["center_gap_m"])
	_apply(verts, cols)


func _apply(verts: PackedVector3Array, cols: PackedColorArray) -> void:
	var mesh := ArrayMesh.new()
	if not verts.is_empty():
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = verts
		arr[Mesh.ARRAY_COLOR] = cols
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		mesh.surface_set_material(0, _material)
	_mesh_instance.mesh = mesh


# Lay one painted stripe at signed lateral offset `lat` (+ = left of travel) and
# width `width`, walking the centerline by arc length. `dash_m <= 0` is a solid
# line; otherwise it draws `dash_m` on / `gap_m` off. A quad bridges each pair of
# consecutive painted samples; an unpainted sample (off the tarmac, or in a dash
# gap) breaks the strip so it leaves a real gap rather than a stretched quad.
func _emit_line(verts: PackedVector3Array, cols: PackedColorArray, centerline: Curve2D,
		terrain: Node, params: Dictionary, lat: float, width: float,
		dash_m: float, gap_m: float) -> void:
	var length := centerline.get_baked_length()
	if length <= 0.0:
		return
	var step: float = params["sample_step_m"]
	var threshold: float = params["tarmac_threshold"]
	var y_off: float = params["height_m"]
	var color: Color = params["color"]
	var solid := dash_m <= 0.0
	var period := dash_m + gap_m
	var half_w := width * 0.5
	var prev_l = null
	var prev_r = null
	var prev_cl := Color.WHITE
	var prev_cr := Color.WHITE
	var o := 0.0
	while o <= length:
		var p := centerline.sample_baked(o)
		var painted := _tarmac_at(terrain, p) > threshold
		if painted and not solid:
			painted = fposmod(o, period) < dash_m
		if painted:
			var n := _left_normal(centerline, o, length)
			var base_y := _height_at(terrain, p) + y_off
			var c := Vector3(p.x + n.x * lat, base_y, p.y + n.y * lat)
			var across := Vector3(n.x, 0.0, n.y) * half_w
			var l := c + across
			var r := c - across
			var cl := color * _light_at(terrain, l.x, l.z)
			var cr := color * _light_at(terrain, r.x, r.z)
			if prev_l != null:
				verts.append(prev_l); verts.append(l); verts.append(prev_r)
				verts.append(prev_r); verts.append(l); verts.append(r)
				cols.append(prev_cl); cols.append(cl); cols.append(prev_cr)
				cols.append(prev_cr); cols.append(cl); cols.append(cr)
			prev_l = l; prev_r = r; prev_cl = cl; prev_cr = cr
		else:
			prev_l = null
			prev_r = null
		o += step


# Unit left normal of the centerline at arc length `o` (perpendicular to travel).
func _left_normal(centerline: Curve2D, o: float, length: float) -> Vector2:
	var p := centerline.sample_baked(o)
	var tangent := centerline.sample_baked(minf(o + 1.0, length)) - p
	if tangent.length() < 0.001:
		tangent = p - centerline.sample_baked(maxf(o - 1.0, 0.0))
	if tangent.length() < 0.001:
		tangent = Vector2(0.0, 1.0)
	tangent = tangent.normalized()
	return Vector2(-tangent.y, tangent.x)


func _tarmac_at(terrain: Node, p: Vector2) -> float:
	if terrain != null and terrain.has_method("surface_at"):
		return terrain.surface_at(p.x, p.y).y
	return 1.0


func _height_at(terrain: Node, p: Vector2) -> float:
	if terrain != null and terrain.has_method("height_at"):
		return terrain.height_at(p.x, p.y)
	return 0.0


func _light_at(terrain: Node, x: float, z: float) -> Color:
	if terrain != null and terrain.has_method("light_at"):
		return terrain.light_at(x, z)
	return Color.WHITE


# --- Readouts (tests) --------------------------------------------------------

func triangle_count() -> int:
	var mesh := _mesh_instance.mesh as ArrayMesh
	if mesh == null or mesh.get_surface_count() == 0:
		return 0
	# The mesh is built from triangles, so the vertex count is always a multiple
	# of 3 — the division is exact and intentionally integer.
	@warning_ignore("integer_division")
	return mesh.surface_get_array_len(0) / 3


func aabb() -> AABB:
	var mesh := _mesh_instance.mesh as ArrayMesh
	if mesh == null or mesh.get_surface_count() == 0:
		return AABB()
	return mesh.get_aabb()
