class_name RoadCrowds
extends RefCounted
# Docs: features/free-roam.md — update in the same change as this file.
# Tests: tests/headless/test_free_roam.gd — extend in the same change.
# Now and then a group of spectators stands by the road with a pop-up gazebo or two, planned once
# at boot from the whole graph like RoadPoles; TerrainStreamer._roadside_crowd builds each one.

const JUNCTION_CLEAR_M := 20.0
const SALT := 104729
const GRID_M := 32.0
const GAZEBO_HALF_M := 1.75
const GAZEBO_LEG_M := 2.3
const GAZEBO_COLOURS: Array[Color] = [Color(0.85, 0.85, 0.82), Color(0.7, 0.12, 0.1), Color(0.12, 0.25, 0.6), Color(0.15, 0.45, 0.2), Color(0.85, 0.65, 0.1)]

var spots := PackedVector2Array()  # each group's centre
var along := PackedVector2Array()  # unit vector along the road there
var out := PackedVector2Array()  # unit vector from the road towards the group
var _by_chunk := {}  # Vector2i -> PackedInt32Array
var _grid := {}  # Vector2i (GRID_M cells) -> PackedInt32Array of groups whose area touches the cell
var _chunk_m := 64.0
var _radius := 6.0


func plan(s: FreeRoamSettings, net: RoadNetwork, terrain: RoadTerrain, sites: RoadSites) -> void:
	spots.clear()
	along.clear()
	out.clear()
	_by_chunk.clear()
	_grid.clear()
	_chunk_m = s.chunk_m
	_radius = s.crowd_half_len_m
	if s.crowd_interval_m <= 0.0 or s.crowd_chance <= 0.0:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = s.world_seed * SALT
	for ei in net.edges.size():
		var pts := net.polyline(ei)
		var cum := PackedFloat64Array([0.0])
		for i in pts.size() - 1:
			cum.append(cum[i] + pts[i].distance_to(pts[i + 1]))
		var length := cum[cum.size() - 1]
		var a := JUNCTION_CLEAR_M + rng.randf() * s.crowd_interval_m
		while a <= length - JUNCTION_CLEAR_M:
			var i := clampi(cum.bsearch(a) - 1, 0, pts.size() - 2)
			var t := (pts[i + 1] - pts[i]).normalized()
			var q := pts[i].lerp(pts[i + 1], clampf((a - cum[i]) / maxf(cum[i + 1] - cum[i], 1e-6), 0.0, 1.0))
			var off := s.road_half_width_at(q.x, q.y) + s.road_shoulder_m + s.crowd_half_depth_m + 0.5
			for side: float in [-1.0, 1.0]:
				if rng.randf() >= s.crowd_chance:
					continue
				var n := Vector2(-t.y, t.x) * side
				var c := q + n * off
				# Keep off water, pads and any other road (a junction or a tight bend).
				if terrain.is_water(c.x, c.y) or not sites.is_clear(c, _radius) or net.nearest(c.x, c.y, off - 0.5):
					continue
				_add(c, t, n)
			a += s.crowd_interval_m


func _add(c: Vector2, t: Vector2, n: Vector2) -> void:
	var gi := spots.size()
	spots.append(c)
	along.append(t)
	out.append(n)
	RoadPoles._append(_by_chunk, Vector2i(floori(c.x / _chunk_m), floori(c.y / _chunk_m)), gi)
	for gx in range(floori((c.x - _radius) / GRID_M), floori((c.x + _radius) / GRID_M) + 1):
		for gz in range(floori((c.y - _radius) / GRID_M), floori((c.y + _radius) / GRID_M) + 1):
			RoadPoles._append(_grid, Vector2i(gx, gz), gi)


func in_chunk(coord: Vector2i) -> PackedInt32Array:
	return _by_chunk.get(coord, PackedInt32Array())


# Whether `p` is at least `margin` clear of every group's ground (trees and rocks keep off it).
func is_clear(p: Vector2, margin: float) -> bool:
	for gi: int in _grid.get(Vector2i(floori(p.x / GRID_M), floori(p.y / GRID_M)), PackedInt32Array()):
		if p.distance_to(spots[gi]) < _radius + margin:
			return false
	return true


static var _gazebo_mesh: ArrayMesh
static var _canopy_mats: Array[StandardMaterial3D] = []


# A pop-up gazebo: four thin legs and a pyramid canopy in one of GAZEBO_COLOURS, its centre on
# the ground at the origin. The legs reach below it so they still meet a sloping ground.
static func gazebo(xf: Transform3D, colour: int) -> MeshInstance3D:
	if _gazebo_mesh == null:
		var metal := StandardMaterial3D.new()
		metal.albedo_color = Color(0.6, 0.6, 0.62)
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var leg := BoxMesh.new()
		leg.size = Vector3(0.06, GAZEBO_LEG_M + 0.6, 0.06)
		for x: float in [-1.0, 1.0]:
			for z: float in [-1.0, 1.0]:
				st.append_from(leg, 0, Transform3D(Basis(), Vector3(x, 0.0, z) * (GAZEBO_HALF_M - 0.05) + Vector3.UP * (GAZEBO_LEG_M - 0.6) * 0.5))
		st.set_material(metal)
		_gazebo_mesh = st.commit()
		var roof := CylinderMesh.new()
		roof.top_radius = 0.0
		roof.bottom_radius = GAZEBO_HALF_M * sqrt(2.0)
		roof.height = 0.7
		roof.radial_segments = 4
		roof.rings = 1
		st = SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.append_from(roof, 0, Transform3D(Basis(Vector3.UP, PI * 0.25), Vector3.UP * (GAZEBO_LEG_M + 0.35)))
		st.commit(_gazebo_mesh)
		for c in GAZEBO_COLOURS:
			var m := StandardMaterial3D.new()
			m.albedo_color = c
			m.cull_mode = BaseMaterial3D.CULL_DISABLED
			_canopy_mats.append(m)
	var mi := MeshInstance3D.new()
	mi.name = "Gazebo"
	mi.mesh = _gazebo_mesh
	mi.transform = xf
	mi.set_surface_override_material(1, _canopy_mats[colour % _canopy_mats.size()])
	return mi
