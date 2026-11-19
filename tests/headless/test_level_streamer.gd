extends GutTest
# LevelStreamer: ground streamed from a baked synthetic level, with collision under the car and a wall at the square's edge.

const SIZE := 200.0

var _streamer: LevelStreamer
var _data: LevelData
var _bake: LevelBake
var _car: RigidBody3D


func before_all() -> void:
	var hm: Array = []
	hm.resize(101 * 101)
	hm.fill(0.0)
	_data = LevelData.new()
	_data.load_save({"size": SIZE, "heightmap": hm, "road": [
		{"x": -80.0, "z": 0.0, "w": 3.0, "m": null, "tension": 1.0}, {"x": 80.0, "z": 0.0, "w": 3.0, "m": null, "tension": 1.0}]})
	_bake = LevelBake.bake(_data)
	_streamer = LevelStreamer.new()
	_streamer.setup(_data, _bake, ShaderMaterial.new())
	add_child(_streamer)
	_car = RigidBody3D.new()
	_car.freeze = true
	add_child(_car)
	_car.global_position = Vector3(0.0, 1.0, 0.0)
	_streamer.focus = _car
	_streamer.prefill()


func after_all() -> void:
	_streamer.free()
	_car.free()


func test_collision_is_built_under_the_spawn() -> void:
	var space := _streamer.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(Vector3(0.0, 20.0, 0.0), Vector3(0.0, -20.0, 0.0))
	await wait_physics_frames(2)
	assert_false(space.intersect_ray(q).is_empty())


func test_height_at_matches_the_bake_at_a_grid_point() -> void:
	for p in [Vector2(0.0, 0.0), Vector2(30.0, 40.5), Vector2(-60.0, -15.0)]:
		assert_almost_eq(_streamer.height_at(p.x, p.y), _bake.height(p.x, p.y), 0.05)


func test_surface_is_road_on_the_road_and_not_in_the_field() -> void:
	assert_gt(_streamer.surface_at(0.0, 0.0).x, 0.5)
	assert_lt(_streamer.surface_at(0.0, 40.0).x, 0.5)


func test_an_edge_wall_surrounds_the_square() -> void:
	var wall := _streamer.get_node("EdgeWall") as StaticBody3D
	assert_not_null(wall)
	var space := _streamer.get_world_3d().direct_space_state
	await wait_physics_frames(2)
	var q := PhysicsRayQueryParameters3D.create(Vector3(SIZE, 5.0, 0.0), Vector3(0.0, 5.0, 0.0))
	assert_false(space.intersect_ray(q).is_empty(), "a ray crossing the edge hits the wall")
