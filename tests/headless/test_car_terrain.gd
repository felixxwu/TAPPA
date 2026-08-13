extends GutTest
# Car-meets-terrain integration tests on the real main.tscn. These are the
# canary for terrain generation changes that break gameplay at spawn (car
# underground, launched, or falling forever). They are terrain-relative by
# design — pure car behavior is tested on the flat fixture in test_car.gd.

const SceneHelpers = preload("res://tests/headless/scene_helpers.gd")

var _scene: Node3D
var _car: VehicleBody3D

# Resting transform of the settled car, captured once in before_all and restored
# per test — mirrors the cached-settle pattern in test_car.gd / sim_test.gd.
var _settled_xform := Transform3D()


func before_all() -> void:
	# Real terrain is the whole point here (this is the terrain-regression canary),
	# but the track shape and foliage are irrelevant — trim them so the build is
	# <1 s instead of ~15 s. minimal_world() only zeroes trees + shortens the track;
	# the $Floor heightfield the car settles on is generated identically.
	SceneHelpers.minimal_world()
	_scene = load("res://main.tscn").instantiate()
	add_child(_scene)
	_car = _scene.get_node("Car")
	await _wait_physics(150)  # let the car drop onto its suspension and settle
	_settled_xform = _car.global_transform


func after_all() -> void:
	_scene.free()
	Config.reset()  # undo minimal_world()'s trim so later files see the full baseline


func before_each() -> void:
	# test_world_border_catches_car_beyond_terrain relocates the car far off the
	# terrain; restore every test to the settled baseline pose so none of the 4
	# tests can see another test's leftover position/velocity.
	_car.reset_to(_settled_xform)
	await _wait_physics(10)


func _wait_physics(frames: int):
	for i in frames:
		await get_tree().physics_frame


func test_car_settles_on_terrain() -> void:
	# Terrain-relative: the spawn can sit on a slope (the car may legitimately
	# slide sideways downhill on low grip), so assert it rides on the surface
	# at suspension height and hasn't launched, sunk, or exploded into jitter.
	var floor_node: Node = _scene.get_node("Floor")
	var ground: float = floor_node.height_at(_car.global_position.x, _car.global_position.z)
	assert_between(_car.global_position.y - ground, 0.1, 1.5,
		"car rides on the terrain surface, not sunk/launched")
	assert_lt(_car.linear_velocity.length(), 2.0, "car at most creeping after settling")


func test_world_border_catches_car_beyond_terrain() -> void:
	# The flat border plane under the hills must stop the car falling forever
	# once it drives off the 200x200m hilly patch.
	_car.global_position = Vector3(300.0, 5.0, 300.0)
	_car.linear_velocity = Vector3.ZERO
	await _wait_physics(600)  # fall 17m and damp out on the border plane (the
	# default MX-5's small wheels settle a violent drop slower than the old car)
	# The chaotic landing can leave the car free-rolling horizontally for a
	# long time (only engine braking slows a driverless coast), so assert the
	# border CAUGHT it — on the plane, no longer falling or bouncing — rather
	# than racing the coast-down to a stop.
	assert_gt(_car.global_position.y, -13.0, "car rests on the border, not in the void")
	assert_lt(absf(_car.linear_velocity.y), 0.5, "car no longer falling or bouncing")


func test_initial_ring_is_built_from_the_cache_not_on_demand() -> void:
	# world.gd generates behind a loading screen, then calls build_initial() so the ring
	# is pulled from the precomputed corridor. Nothing may build a ring chunk from raw
	# noise before that: TerrainManager stays out of the loading frames (_initial_pending)
	# precisely so the 7x7 ring is computed once. See features/terrain.md ->
	# "Who builds the initial ring".
	var floor_node: Node = _scene.get_node("Floor")
	assert_eq(floor_node.on_demand_builds, 0,
		"every chunk under the car came from the corridor cache")
	for coord in floor_node.loaded_coords():
		assert_true(floor_node.has_cached(coord), "ring chunk %s is a cache pull" % coord)


func test_car_is_handed_back_to_physics_after_generation() -> void:
	# The car is frozen for the generation window (there is deliberately no terrain under
	# it until build_initial()), and must be unfrozen again by the time _ready returns —
	# otherwise it would hang in the air, immovable, for the whole run.
	assert_false(_car.freeze, "the car is simulating again once the world is built")
