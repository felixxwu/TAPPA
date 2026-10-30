extends GutTest
# DustPuffs: opaque blocky dust clouds left behind the rear wheels on gravel
# (features/dust-puffs.md). Driven against a stub car + drivetrain + wheels + terrain,
# so the gating / spacing / growth / ring-buffer logic runs without a real vehicle.


class StubWheel:
	extends Node3D
	var _contact := true
	func is_in_contact() -> bool:
		return _contact


# Road within |x| <= road_half (tarmac weight `tarmac`), grass beyond.
class StubTerrain:
	extends RefCounted
	var road_half := 3.0
	var tarmac := 0.0
	func surface_at(x: float, _z: float) -> Vector2:
		return Vector2(1.0 if absf(x) <= road_half else 0.0, tarmac)


class StubDrivetrain:
	extends RefCounted
	var front_wheels: Array = []
	var rear_wheels: Array = []
	var all_wheels: Array = []
	var ground_vel := Vector3.ZERO
	var terrain
	func velocity_at(_point) -> Vector3:
		return ground_vel


class StubCar:
	extends Node3D
	var drivetrain


var _car: StubCar
var _dt: StubDrivetrain
var _terrain: StubTerrain
var _wheels: Array = []


func before_each() -> void:
	Config.reset()
	Config.data.dust_puffs_enabled = true
	_car = StubCar.new()
	_dt = StubDrivetrain.new()
	_terrain = StubTerrain.new()
	_dt.terrain = _terrain
	_car.drivetrain = _dt
	add_child_autofree(_car)
	_wheels = []
	for i in 4:
		var w := StubWheel.new()
		_car.add_child(w)
		w.position = Vector3(-0.8 if i % 2 == 0 else 0.8, 0.3, -1.2 if i < 2 else 1.2)
		_wheels.append(w)
		(_dt.rear_wheels if i >= 2 else _dt.front_wheels).append(w)
		_dt.all_wheels.append(w)


func after_each() -> void:
	Config.reset()


func _make() -> DustPuffs:
	var d := DustPuffs.new()
	add_child_autofree(d)
	d.setup(_car)
	return d


# Drive fast enough to raise dust, for `metres` of travel in one tick.
func _drive(d: DustPuffs, metres: float) -> void:
	var speed := Config.data.dust_puff_min_speed_mps + 10.0
	_dt.ground_vel = Vector3(0, 0, -speed)
	d._physics_process(metres / speed)


func test_driving_on_gravel_leaves_one_puff_per_spacing_per_rear_wheel() -> void:
	var d := _make()
	var spacing := Config.data.dust_puff_spacing_m
	_drive(d, spacing * 3.5)
	assert_eq(d.live_count(), 3 * _dt.rear_wheels.size(),
		"each rear wheel drops floor(distance / spacing) puffs")


func test_no_dust_below_min_speed() -> void:
	var d := _make()
	var slow := Config.data.dust_puff_min_speed_mps * 0.5
	_dt.ground_vel = Vector3(0, 0, -slow)
	for i in 120:
		d._physics_process(1.0 / 60.0)
	assert_eq(d.live_count(), 0, "a crawling car kicks up no dust")


func _slot_color(d: DustPuffs, i: int) -> Color:
	var b := i * DustPuffs.STRIDE
	return Color(d._buffer[b + 12], d._buffer[b + 13], d._buffer[b + 14])


func test_no_dust_on_grass() -> void:
	var d := _make()
	_terrain.road_half = 0.1  # wheels at |x| = 0.8 sit on grass
	_drive(d, Config.data.dust_puff_spacing_m * 5.0)
	assert_eq(d.live_count(), 0, "grass raises no dust")


func test_tarmac_raises_tarmac_coloured_dust() -> void:
	Config.data.dust_puff_color_jitter = 0.0
	Config.data.dust_puff_tarmac_color = Color(0.9, 0.8, 0.7)
	var d := _make()
	_terrain.tarmac = 1.0
	_drive(d, Config.data.dust_puff_spacing_m * 1.01)
	assert_gt(d.live_count(), 0, "tarmac raises dust too")
	assert_true(_slot_color(d, d._next).is_equal_approx(Color(0.9, 0.8, 0.7)), "in the tarmac colour")


func test_gravel_dust_takes_the_gravel_colour() -> void:
	Config.data.dust_puff_color_jitter = 0.0
	var d := _make()
	var c := Color(0.2, 0.4, 0.6)
	d.apply_region_look({"dust_color": c})
	_drive(d, Config.data.dust_puff_spacing_m * 1.01)
	assert_true(_slot_color(d, d._next).is_equal_approx(c), "in the region's gravel colour")


func test_color_for_surface_picks_by_surface() -> void:
	var cfg := Config.data
	var d := _make()
	assert_eq(d.color_for_surface(cfg, Vector2(0.0, 0.0)).a, 0.0, "grass: none")
	assert_eq(d.color_for_surface(cfg, Vector2(1.0, 1.0)), cfg.dust_puff_tarmac_color, "tarmac")
	assert_eq(d.color_for_surface(cfg, Vector2(1.0, 0.0)), d.dust_color(), "gravel")


func test_airborne_wheel_raises_no_dust() -> void:
	var d := _make()
	for w in _dt.rear_wheels:
		w._contact = false
	_drive(d, Config.data.dust_puff_spacing_m * 5.0)
	assert_eq(d.live_count(), 0)


func test_puff_grows_then_disappears() -> void:
	var d := _make()
	_drive(d, Config.data.dust_puff_spacing_m * 1.01)
	assert_gt(d.live_count(), 0)
	_dt.ground_vel = Vector3.ZERO
	var i := d._next
	var b := i * DustPuffs.STRIDE
	var col0 := Vector3(d._buffer[b], d._buffer[b + 4], d._buffer[b + 8])
	var born := col0.length()
	d._physics_process(d._life[i] * 0.5)
	col0 = Vector3(d._buffer[b], d._buffer[b + 4], d._buffer[b + 8])
	assert_gt(col0.length(), born, "a puff grows over its life")
	d._physics_process(Config.data.dust_puff_lifetime_s * 2.0)
	assert_eq(d.live_count(), 0, "a puff past its lifetime is gone")
	assert_eq(d._buffer[b + 7], CpuParticlePool.HIDE_Y, "and parked off-screen")


func test_ring_buffer_caps_live_count() -> void:
	Config.data.dust_puff_max = 10
	var d := _make()
	_drive(d, Config.data.dust_puff_spacing_m * 40.0)
	assert_eq(d.live_count(), 10, "live puffs never exceed the pool cap")


func test_size_at_eases_from_birth_to_grown() -> void:
	var cfg := Config.data
	assert_almost_eq(DustPuffs.size_at(cfg, 0.0), cfg.dust_puff_size_m, 1e-5)
	assert_almost_eq(DustPuffs.size_at(cfg, 1.0), cfg.dust_puff_size_m * cfg.dust_puff_growth, 1e-5)


func test_region_look_overrides_and_clears_colour() -> void:
	var d := _make()
	var c := Color(0.1, 0.2, 0.3)
	d.apply_region_look({"dust_color": c})
	assert_eq(d.dust_color(), c)
	d.apply_region_look({})
	assert_eq(d.dust_color(), Config.data.dust_puff_color, "an empty look falls back to config")


func test_blob_mesh_faces_point_outward() -> void:
	var mesh := DustPuffs.build_blob_mesh()
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	assert_gt(verts.size(), 0)
	assert_eq(verts.size() % 3, 0)
	for f in verts.size() / 3:
		var a := verts[f * 3]
		var b := verts[f * 3 + 1]
		var c := verts[f * 3 + 2]
		var n := normals[f * 3]
		assert_gt(n.dot(a + b + c), 0.0, "face %d normal points outward" % f)
		# Godot front faces wind clockwise from outside: (b-a)x(c-a) points inward.
		assert_lt((b - a).cross(c - a).dot(n), 0.0, "face %d winds clockwise from outside" % f)


func test_disabled_emits_nothing() -> void:
	Config.data.dust_puffs_enabled = false
	var d := _make()
	_drive(d, Config.data.dust_puff_spacing_m * 5.0)
	assert_eq(d.live_count(), 0)
