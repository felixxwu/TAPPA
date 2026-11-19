extends GutTest
# LevelTrees (scripts/level_trees.gd): tiles of baked trees, the viewpoint row deciding which are drawn, and collision only near the car.
# Every level here is synthetic and its visibility rows are injected; the real render needs a window.

var _bake: LevelBake
var _trees: LevelTrees
var _full: float


func before_each() -> void:
	_full = Config.data.level_tree_full_height_m


func after_each() -> void:
	Config.data.level_tree_full_height_m = _full


func _tree(x: float, z: float, kind := "tree.png", sy := 1.0) -> Dictionary:
	return {"x": x, "z": z, "rot": 0.0, "sx": 1.0, "sy": sy, "kind": kind}


# A flat 600 m level with a road along x; trees 0 and 1 share a tile, 2 is another species in it, 3 is far away.
func _make(trees: Array) -> void:
	var hm: Array = []
	hm.resize(201 * 201)
	hm.fill(0.0)
	var data := LevelData.new()
	data.load_save({"road": [{"x": -100.0, "z": 0.0, "w": 3.0, "m": null, "tension": 1.0},
			{"x": 100.0, "z": 0.0, "w": 3.0, "m": null, "tension": 1.0}], "trees": trees, "heightmap": hm})
	_bake = LevelBake.bake(data)
	_trees = LevelTrees.new()
	_trees.setup(_bake)
	add_child_autofree(_trees)


func _idx(x: float, z: float) -> int:
	for i in _bake.tree_count():
		if absf(_bake.tree_xf[i * 12 + 3] - x) < 0.01 and absf(_bake.tree_xf[i * 12 + 11] - z) < 0.01:
			return i
	return -1


func _near_trees() -> Array:
	return [_tree(0.0, 50.0), _tree(10.0, 50.0, "tree.png", 2.0), _tree(20.0, 50.0, "tree-greece.webp"), _tree(250.0, 250.0)]


func test_only_tiles_near_the_car_have_collision() -> void:
	_make(_near_trees())
	var near := _bake.tree_tile_at(_idx(0.0, 50.0))
	var far := _bake.tree_tile_at(_idx(250.0, 250.0))
	_trees.update(Vector3(0.0, 0.0, 50.0), Vector3(0.0, 0.0, 50.0))
	assert_not_null(_trees.tile(near).hit)
	assert_true(_trees.tile(far) == null or _trees.tile(far).hit == null)
	var hit := _trees.tile(near).hit
	var body := hit.body
	assert_true(body.is_in_group(DamageModel.OBSTACLE_GROUP))
	assert_eq(PhysicsServer3D.body_get_shape_count(body.get_rid()), 3)
	_trees.update(Vector3(250.0, 0.0, 250.0), Vector3(250.0, 0.0, 250.0))
	assert_not_null(_trees.tile(far).hit)
	assert_false(is_instance_valid(hit), "left behind, the first tile's collision is dropped")
	assert_null(_trees.tile(near).hit)


func test_a_felled_tree_stays_felled_after_its_tile_is_dropped_and_rebuilt() -> void:
	_make(_near_trees())
	var idx := _idx(0.0, 50.0)
	var near := _bake.tree_tile_at(idx)
	var standing := _bake.tree_xf[idx * 12 + 5]
	_trees.update(Vector3(0.0, 0.0, 50.0), Vector3(0.0, 0.0, 50.0))
	_trees.knock_down(idx, Vector3.FORWARD, 0.0)
	_trees.knock_down(idx, Vector3.FORWARD, 0.0)
	_trees._step_falls(0.1)
	_trees.settle()
	assert_true(_trees.is_fallen(idx))
	assert_false(_trees.is_fallen(_idx(10.0, 50.0)))
	_trees.update(Vector3(250.0, 0.0, 250.0), Vector3(250.0, 0.0, 250.0))
	_trees.update(Vector3(0.0, 0.0, 50.0), Vector3(0.0, 0.0, 50.0))
	assert_not_null(_trees.tile(near).hit, "rebuilt")
	assert_true(_trees.is_fallen(idx))
	var first := _trees.tile(near).first
	var buf := _trees.tile(near).mmis[0].multimesh.buffer
	assert_lt(buf[(idx - first) * 12 + 5], standing * 0.2, "still lying down")


func test_a_row_change_shows_exactly_that_rows_trees() -> void:
	_make(_near_trees())
	var a := _idx(0.0, 50.0)
	var c := _idx(20.0, 50.0)
	var rows: Array = []
	for _i in ceili(_bake.sx.size() / 4.0):
		rows.append([])
	rows[0] = [a]
	rows[1] = [c]
	_bake.set_visibility(4, rows)
	_trees.update(Vector3(-100.0, 0.0, 0.0), Vector3(-100.0, 0.0, 0.0))
	_trees.settle()
	assert_eq(_trees.drawn_count(), 2, "rows 0 and 1 are shown together, across both species")
	_trees.update(Vector3(100.0, 0.0, 0.0), Vector3(100.0, 0.0, 0.0))
	_trees.settle()
	assert_eq(_trees.drawn_count(), 0)


func test_without_a_bake_every_tree_in_range_is_drawn() -> void:
	_make(_near_trees())
	_trees.update(Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.0, 0.0))
	_trees.settle()
	assert_eq(_trees.drawn_count(), 4)


func test_a_taller_tree_is_harder_to_fell() -> void:
	Config.data.level_tree_full_height_m = 1000.0
	_make(_near_trees())
	assert_gt(_trees.size_factor(_idx(10.0, 50.0)), _trees.size_factor(_idx(0.0, 50.0)), "the second tree is twice as tall")


func test_tree_cards_use_the_swaying_shader() -> void:
	_make(_near_trees())
	_trees.update(Vector3(0.0, 0.0, 50.0), Vector3(0.0, 0.0, 50.0))
	var mat := _trees.tile(_bake.tree_tile_at(_idx(0.0, 50.0))).mmis[0].material_override as ShaderMaterial
	assert_true(mat.shader.code.contains("wind_sway_offset"))


func test_a_tile_first_made_by_the_collision_scan_is_drawn_at_once() -> void:
	_make(_near_trees())
	var a := _idx(0.0, 50.0)
	var cam := Vector3(5000.0, 0.0, 5000.0)
	var row := _bake.nearest_sample(cam.x, cam.z) / 4
	var rows: Array = []
	for _i in ceili(_bake.sx.size() / 4.0):
		rows.append([])
	rows[row] = [a]
	_bake.set_visibility(4, rows)
	_trees.update(cam, Vector3(0.0, 0.0, 50.0))
	assert_not_null(_trees.tile(_bake.tree_tile_at(a)).hit, "solid")
	assert_eq(_trees.drawn_count(), 1, "and drawn")
