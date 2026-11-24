class_name RouteArrow
extends MeshInstance3D
# Docs: features/level-editor.md — update in the same change as this file.
# The sat nav's turn arrow: while a delivery is on, it floats over the next junction on the route ahead, pointing down the road to take.

const SHOW_M := 70.0  # a junction this far ahead along the route gets the arrow
const EXIT_M := 10.0  # the arrow points at the route this far past the junction
const REROUTE_M := 40.0  # the route is worked out again once the car has driven or strayed this far
const HEIGHT := 2.0
const BOB_M := 0.2

var view: LevelView
var _pts := PackedVector2Array()
var _junction: Array[bool] = []
var _to := ""
var _from := Vector2.INF
var _t := 0.0


func _ready() -> void:
	mesh = arrow_mesh()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = LevelMap.ROUTE
	material_override = mat
	visible = false


func _process(dt: float) -> void:
	_t += dt
	var car := view._car as Node3D
	var to := LevelView.nav_target()
	if car == null or to.is_empty():
		visible = false
		_to = ""
		return
	var p := Vector2(car.global_position.x, car.global_position.z)
	var at := nearest_point(_pts, p)
	if to != _to or p.distance_to(_from) > REROUTE_M or at < 0 or p.distance_to(_pts[at]) > REROUTE_M * 0.5:
		_reroute(p, to)
		at = nearest_point(_pts, p)
	var j := next_junction(_pts, _junction, at, SHOW_M)
	visible = j >= 0
	if not visible:
		return
	var exit := _pts[_ahead(j, EXIT_M)] - _pts[j]
	var x := Vector3(exit.x, 0.0, exit.y).normalized()
	var pos := Vector3(_pts[j].x, view.height_at(_pts[j].x, _pts[j].y) + HEIGHT + sin(_t * TAU * 0.5) * BOB_M, _pts[j].y)
	var cam := get_viewport().get_camera_3d()
	var n := Vector3.UP
	if cam != null:  # turned about its own length to face the camera, so it never shows edge-on from the side
		var c := (cam.global_position - pos).normalized()
		var side := c - x * c.dot(x)
		if side.length() > 0.2:
			n = side.normalized()
	global_transform = Transform3D(Basis(x, n.cross(x), n), pos)


func _reroute(p: Vector2, to: String) -> void:
	_to = to
	_from = p
	_pts = PackedVector2Array()
	_junction.clear()
	var roads := view._bake._roads()
	for t: Dictionary in view.level.get("teleports", []):
		if t.get("name", "") == to:
			for id in roads.route_ids(p, Vector2(float(t["x"]), float(t["z"]))):
				_pts.append(Vector2(roads.sx[id], roads.sz[id]))
				_junction.append(roads.is_junction(id))


# The route point `metres` along the route past point `i` (or the route's last point).
func _ahead(i: int, metres: float) -> int:
	var d := 0.0
	while i < _pts.size() - 1 and d < metres:
		d += _pts[i].distance_to(_pts[i + 1])
		i += 1
	return i


static func nearest_point(pts: PackedVector2Array, p: Vector2) -> int:
	var best := -1
	for i in pts.size():
		if best < 0 or pts[i].distance_squared_to(p) < pts[best].distance_squared_to(p):
			best = i
	return best


# The first junction on the route after point `at` and within `reach` metres along it; -1 if none.
static func next_junction(pts: PackedVector2Array, junction: Array[bool], at: int, reach: float) -> int:
	if at < 0:
		return -1
	var d := 0.0
	for i in range(at + 1, pts.size()):
		d += pts[i - 1].distance_to(pts[i])
		if d > reach:
			return -1
		if junction[i]:
			return i
	return -1


# A flat arrow 4 m long pointing along +X, lying in the XY plane.
static func arrow_mesh() -> ArrayMesh:
	var v := PackedVector3Array([
		Vector3(-2.0, -0.35, 0), Vector3(0.5, -0.35, 0), Vector3(0.5, 0.35, 0),
		Vector3(-2.0, -0.35, 0), Vector3(0.5, 0.35, 0), Vector3(-2.0, 0.35, 0),
		Vector3(0.5, -1.1, 0), Vector3(2.0, 0, 0), Vector3(0.5, 1.1, 0)])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m
