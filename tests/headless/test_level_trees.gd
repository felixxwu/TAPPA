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
	assert_lt(buf[(idx - first) * LevelTrees.STRIDE + 5], standing * 0.2, "still lying down")


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


# Photo mode's camera can be anywhere, so its free view ignores the road-baked visibility and draws
# every tree in reach — and going back to the road view brings the baked set back.
func test_free_view_draws_every_tree_in_reach() -> void:
	_make(_near_trees())
	var rows: Array = []
	for _i in ceili(_bake.sx.size() / 4.0):
		rows.append([])
	_bake.set_visibility(4, rows)  # no tree is visible from any stretch of road
	_trees.update(Vector3(0.0, 0.0, 50.0), Vector3(0.0, 0.0, 50.0))
	_trees.settle()
	assert_eq(_trees.drawn_count(), 0, "precondition: the road view hides them all")
	_trees.update(Vector3(0.0, 0.0, 50.0), Vector3(0.0, 0.0, 50.0), true)
	_trees.settle()
	assert_eq(_trees.drawn_count(), 4, "the free view draws every tree in reach")
	_trees.update(Vector3(0.0, 0.0, 50.0), Vector3(0.0, 0.0, 50.0))
	_trees.settle()
	assert_eq(_trees.drawn_count(), 0, "and the road view hides them again")


# Photo mode's render draws trees further out for a moment: a tree past the normal draw distance is
# drawn while the override is set, and the tiles' draw range goes back when it clears.
func test_a_draw_override_reaches_further_and_clears_back() -> void:
	_make(_near_trees())
	var far_cam := Vector3(-_trees.draw_m() - 3.0 * LevelBake.TREE_TILE_M, 0.0, 0.0)
	_trees.update(far_cam, far_cam, true)
	_trees.settle()
	assert_eq(_trees.drawn_count(), 0, "precondition: the trees are past the draw distance")
	var normal := _trees.draw_m()
	_trees.set_draw_override(normal * 4.0)
	_trees.update(far_cam, far_cam, true)
	_trees.settle()
	assert_gt(_trees.drawn_count(), 0, "the longer draw distance reaches them")
	_trees.set_draw_override(0.0)
	assert_eq(_trees.draw_m(), normal, "clearing it restores the normal distance")
	for mat: ShaderMaterial in _trees._materials.values():
		assert_eq(float(mat.get_shader_parameter("draw_end_m")), normal, "and the cards dither out at the normal edge again")
	for i in _bake.tree_tile_n * _bake.tree_tile_n:
		var t := _trees.tile(i)
		if t != null:
			for mmi in t.mmis:
				assert_eq(mmi.visibility_range_end, normal + LevelBake.TREE_TILE_M, "every built tile draws to the normal range again")


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


# The trees fade themselves out where they stop being drawn, so the fog no longer has to hide it.
func test_tree_cards_fade_out_at_the_tree_draw_distance() -> void:
	_make(_near_trees())
	_trees.update(Vector3(0.0, 0.0, 50.0), Vector3(0.0, 0.0, 50.0))
	var mat := _trees.tile(_bake.tree_tile_at(_idx(0.0, 50.0))).mmis[0].material_override as ShaderMaterial
	assert_eq(mat.get_shader_parameter("draw_end_m"), Config.data.level_tree_draw_m)
	assert_eq(mat.get_shader_parameter("fade_m"), Config.data.level_tree_fade_m)


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


func test_a_tiles_species_share_one_multimesh_each_card_naming_its_texture_slot() -> void:
	_make(_near_trees())
	_trees.update(Vector3(0.0, 0.0, 50.0), Vector3(0.0, 0.0, 50.0))
	_trees.settle()
	var t := _trees.tile(_bake.tree_tile_at(_idx(0.0, 50.0)))
	assert_eq(t.mmis.size(), 1, "two species, one draw")
	var mm := t.mmis[0].multimesh
	var mat := t.mmis[0].material_override as ShaderMaterial
	for k in mm.visible_instance_count:
		var slot := int(mm.buffer[k * LevelTrees.STRIDE + 12])
		var id := t.first + k
		assert_eq(t.slots[0][_bake.tree_kind[id]], slot)
		assert_eq(mat.get_shader_parameter("albedo%d" % slot), LevelBake.tree_texture(_bake.tree_kinds[_bake.tree_kind[id]]),
			"the slot's texture is the tree's own species")


func test_more_species_than_one_draw_holds_split_into_more_multimeshes() -> void:
	var trees: Array = []
	for k in LevelTrees.KINDS_PER_DRAW + 1:
		trees.append(_tree(k * 5.0, 50.0, "kind_%d.png" % k))
	_make(trees)
	_trees.update(Vector3(0.0, 0.0, 50.0), Vector3(0.0, 0.0, 50.0))
	_trees.settle()
	var t := _trees.tile(_bake.tree_tile_at(_idx(0.0, 50.0)))
	assert_eq(t.mmis.size(), 2)
	assert_eq(_trees.drawn_count(), LevelTrees.KINDS_PER_DRAW + 1, "every tree still drawn")


func _buffers() -> Array:
	var out: Array = []
	for i in _bake.tree_tile_first.size() - 1:
		var t := _trees.tile(i)
		if t != null:
			for mmi in t.mmis:
				out.append(mmi.multimesh.buffer)
				out.append(mmi.multimesh.visible_instance_count)
	return out


func _drawn_far_from_car(threaded: bool) -> Array:
	Config.data.threaded_tree_build = threaded
	_make(_near_trees())
	_trees.update(Vector3(0.0, 0.0, 50.0), Vector3(-290.0, 0.0, -290.0))
	var dispatched := _trees._inflight.size()
	_trees.settle()
	assert_eq(_trees._inflight.size(), 0, "settle collects everything")
	var out := _buffers()
	out.append(dispatched)
	_trees.free()
	return out


func test_a_tile_packed_on_a_worker_matches_one_packed_on_the_main_thread() -> void:
	var saved: bool = Config.data.threaded_tree_build
	var main := _drawn_far_from_car(false)
	var wide := _drawn_far_from_car(true)
	Config.data.threaded_tree_build = saved
	assert_eq(main.back(), 0, "toggle off dispatches nothing")
	main.pop_back()
	wide.pop_back()
	assert_gt(main.size(), 0)
	assert_eq(wide, main)


func test_freeing_trees_with_packs_in_flight_is_safe() -> void:
	var saved: bool = Config.data.threaded_tree_build
	Config.data.threaded_tree_build = true
	_make(_near_trees())
	_trees.update(Vector3(0.0, 0.0, 50.0), Vector3(-290.0, 0.0, -290.0))
	_trees.get_parent().remove_child(_trees)
	_trees.free()
	Config.data.threaded_tree_build = saved
	pass_test("freed with tasks pending")
