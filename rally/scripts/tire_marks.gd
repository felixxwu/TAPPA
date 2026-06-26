class_name TireMarks
extends Node3D
# Lays gravel ruts behind the car's wheels while it drives ON the road. The
# gl_compatibility renderer has no Decals, so each wheel gets a persistent ribbon
# mesh (an ArrayMesh rebuilt as segments are appended), coloured a solid shade
# close to the gravel. See todo/tire-marks.md.
#
# Created + wired by world.gd._generate_track once the centerline exists; re-targeted
# on a car swap (world.gd.cycle_car). Marks are gated to the road footprint (only
# the gravel), capped per wheel (a ring buffer), and only laid while moving.

# Windowed nearest-offset search of the centerline (around the car's last offset),
# mirroring TrackProgress — local, so it never snaps to a far part of a winding road.
const SEARCH_BACK_M := 30.0
const SEARCH_FWD_M := 60.0
const SEARCH_STEP_M := 1.0

var _centerline: Curve2D
var _baked_length := 0.0
var _terrain: Node          # TerrainManager (height_at), or null on flat fixtures
var _car: Node              # the VehicleBody3D (read for linear_velocity)
var _half_width := 3.0      # road half-width (track_width * 0.5)
var _offset := 0.0          # cached windowed nearest-offset for the car centre
var _material: StandardMaterial3D

# Parallel per-wheel arrays (index == wheel).
var _wheels: Array = []     # nodes exposing is_in_contact() + global_position
var _ribbons: Array = []    # MeshInstance3D, one ribbon per wheel
var _pairs: Array = []      # per wheel: Array of [left:Vector3, right:Vector3] (ring buffer)
var _last_pos: Array = []   # per wheel: Vector2 last emit XZ, or null = ribbon broken


# Wire to a freshly generated track + the current car. half_width is the road
# half-width (track_width * 0.5) the marks are gated to.
func setup(centerline: Curve2D, car: Node, terrain: Node, half_width: float) -> void:
	_centerline = centerline
	_baked_length = centerline.get_baked_length()
	_terrain = terrain
	_half_width = half_width
	_offset = 0.0
	_ensure_material()
	_retarget_internal(car)


# Re-point at a freshly spawned car (a car swap) and clear all marks.
func retarget(car: Node) -> void:
	_offset = 0.0
	_retarget_internal(car)


func _retarget_internal(car: Node) -> void:
	_car = car
	for r in _ribbons:
		if is_instance_valid(r):
			r.queue_free()
	_wheels = _collect_wheels(car)
	_ribbons = []
	_pairs = []
	_last_pos = []
	for i in _wheels.size():
		var mi := MeshInstance3D.new()
		mi.mesh = ArrayMesh.new()
		add_child(mi)
		_ribbons.append(mi)
		_pairs.append([])
		_last_pos.append(null)


# A car's wheels — duck-typed on is_in_contact() so VehicleWheel3D (real play) and
# test stubs are both found, without depending on the concrete class here.
func _collect_wheels(car: Node) -> Array:
	var out: Array = []
	if car == null:
		return out
	for n in car.find_children("*", "Node3D", true, false):
		if n.has_method("is_in_contact"):
			out.append(n)
	return out


func _physics_process(_delta: float) -> void:
	if not Config.data.tire_marks_enabled or _centerline == null or not is_instance_valid(_car):
		return
	# Below the speed floor (parked / countdown): break every ribbon so a later
	# segment doesn't draw a line across the stop.
	if _car.linear_velocity.length() < Config.data.tire_mark_min_speed_mps:
		for i in _last_pos.size():
			_last_pos[i] = null
		return
	var car_xz := Vector2(_car.global_position.x, _car.global_position.z)
	var frame := _road_frame(car_xz)       # [road_point: Vector2, road_normal: Vector2]
	var road_pt: Vector2 = frame[0]
	var road_n: Vector2 = frame[1]
	var gate := _half_width + Config.data.tire_mark_gravel_margin_m
	var step := Config.data.tire_mark_segment_step_m
	for i in _wheels.size():
		var wheel: Node = _wheels[i]
		if not wheel.is_in_contact():
			_last_pos[i] = null
			continue
		var wpos: Vector3 = wheel.global_position
		var wxz := Vector2(wpos.x, wpos.z)
		# Lateral distance from the road centerline (local frame): off the gravel
		# (incl. the verge margin) breaks the ribbon.
		if absf((wxz - road_pt).dot(road_n)) > gate:
			_last_pos[i] = null
			continue
		if _last_pos[i] == null or wxz.distance_to(_last_pos[i]) >= step:
			_emit_segment(i, wpos, road_n)
			_last_pos[i] = wxz


# Append one ribbon point for a wheel (left/right of its ground contact, across the
# road normal), cap the ring buffer, and rebuild that wheel's surface. The contact
# height comes from the WHEEL (hub Y − wheel radius), not terrain.height_at — near
# the road the terrain mesh is flattened to the baked road height the car sits on,
# so the raw noise height would sink the ribbon under the road in cuts/dips.
func _emit_segment(i: int, wheel_pos: Vector3, road_n: Vector2) -> void:
	var y := wheel_pos.y - Config.data.wheel_radius + Config.data.tire_mark_ground_offset_m
	var center := Vector3(wheel_pos.x, y, wheel_pos.z)
	var across := Vector3(road_n.x, 0.0, road_n.y) * (Config.data.tire_mark_width_m * 0.5)
	var pairs: Array = _pairs[i]
	pairs.append([center + across, center - across])
	var cap: int = maxi(2, Config.data.tire_mark_max_segments)
	while pairs.size() > cap:
		pairs.pop_front()
	_rebuild(i)


# Rebuild a wheel's ribbon ArrayMesh from its segment pairs: a triangle strip of
# quads (cull disabled, so winding doesn't matter for the flat-on-ground ribbon).
func _rebuild(i: int) -> void:
	var mesh := _ribbons[i].mesh as ArrayMesh
	mesh.clear_surfaces()
	var pairs: Array = _pairs[i]
	if pairs.size() < 2:
		return
	var verts := PackedVector3Array()
	for k in pairs.size() - 1:
		var l0: Vector3 = pairs[k][0]
		var r0: Vector3 = pairs[k][1]
		var l1: Vector3 = pairs[k + 1][0]
		var r1: Vector3 = pairs[k + 1][1]
		verts.append(l0); verts.append(l1); verts.append(r0)
		verts.append(r0); verts.append(l1); verts.append(r1)
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	mesh.surface_set_material(0, _material)


# Local road point + left normal at the car's windowed nearest offset. Wheels are
# within a couple of metres, so this one frame gates all four.
func _road_frame(here: Vector2) -> Array:
	_offset = _windowed_offset(here)
	var p := _centerline.sample_baked(_offset)
	var ahead := _centerline.sample_baked(minf(_offset + 1.0, _baked_length))
	var tangent := ahead - p
	if tangent.length() < 0.001:
		tangent = p - _centerline.sample_baked(maxf(_offset - 1.0, 0.0))
	if tangent.length() < 0.001:
		tangent = Vector2(0.0, 1.0)
	tangent = tangent.normalized()
	return [p, Vector2(-tangent.y, tangent.x)]


func _windowed_offset(here: Vector2) -> float:
	var lo := maxf(0.0, _offset - SEARCH_BACK_M)
	var hi := minf(_baked_length, _offset + SEARCH_FWD_M)
	var best_o := lo
	var best_d := INF
	var o := lo
	while o <= hi:
		var d := here.distance_squared_to(_centerline.sample_baked(o))
		if d < best_d:
			best_d = d
			best_o = o
		o += SEARCH_STEP_M
	return best_o


func _ensure_material() -> void:
	if _material != null:
		return
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.albedo_color = Config.data.tire_mark_color


# --- Readouts (tests) --------------------------------------------------------

func wheel_count() -> int:
	return _wheels.size()


func segment_count(wheel: int) -> int:
	return (_pairs[wheel] as Array).size() if wheel >= 0 and wheel < _pairs.size() else 0
