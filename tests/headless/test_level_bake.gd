extends GutTest
# LevelBake (scripts/level_bake.gd): the baked heights, road frame and road samples agree with LevelData, and a bake goes stale when its save changes.
# Every level here is synthetic; nothing reads the shipped Hafren save.

const SIZE := 120
const SAVE := "user://test_level_bake_save.json"

var _data: LevelData
var _bake: LevelBake


func before_all() -> void:
	var grid_n := 24
	var hm: Array = []
	for r in grid_n + 1:
		for c in grid_n + 1:
			hm.append(3.0 * sin(c / 3.0) + 2.0 * cos(r / 4.0))
	_data = LevelData.new()
	var paved := _node(50.0, 8.0)
	paved["tarmac"] = true
	_data.load_save({"size": SIZE, "heightmap": hm, "gravelPatches": [[{"x": -40.0, "z": 30.0}, {"x": -25.0, "z": 30.0}, {"x": -30.0, "z": 45.0}],
		[{"x": 38.0, "z": 0.0}, {"x": 52.0, "z": 0.0}, {"x": 52.0, "z": 14.0}, {"x": 38.0, "z": 0.0 + 14.0}]], "roads": [
		[_node(-50.0, -10.0), _node(0.0, 0.0), paved],
		[_node(0.0, 0.3, 2.0), _node(5.0, 40.0, 2.0)]]})
	_bake = LevelBake.bake(_data, "k")


func after_each() -> void:
	for p in [SAVE, LevelBake.bake_path(SAVE)]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


func _node(x: float, z: float, w := 3.0) -> Dictionary:
	return {"x": x, "z": z, "w": w, "m": null, "tension": 1.0}


func test_baked_heights_equal_the_ground_at_grid_points() -> void:
	var cell := _bake.cell()
	for r in range(0, _bake.n, 7):
		for c in range(0, _bake.n, 5):
			var x := c * cell - SIZE / 2.0
			var z := r * cell - SIZE / 2.0
			assert_almost_eq(_bake.height(x, z), _data.ground(x, z), 0.011, "at %s, %s" % [x, z])
			assert_almost_eq(_bake.grid_height(c, r), _data.ground(x, z), 0.011)


func test_outside_the_square_the_edge_heights_repeat_outwards() -> void:
	assert_eq(_bake.height(-SIZE * 3.0, 10.0), _bake.height(-SIZE / 2.0, 10.0))
	assert_eq(_bake.height(10.0, SIZE * 3.0), _bake.height(10.0, SIZE / 2.0))
	assert_eq(_bake.grid_height(-5, -5), _bake.grid_height(0, 0), "indices clamp")


func test_the_road_frame_texels_agree_with_the_road_frame() -> void:
	var fcell := float(SIZE) / (_bake.frame_n - 1)
	for r in range(0, _bake.frame_n, 2):
		for c in range(0, _bake.frame_n, 2):
			var x := c * fcell - SIZE / 2.0
			var z := r * fcell - SIZE / 2.0
			var want := _data.road_frame(x, z)
			var on_road := want.x != INF and absf(want.x) <= want.y
			if not on_road and _data.patch_at(x, z).x < (absf(want.x) - want.y if want.x != INF else INF):
				continue  # a gravel patch's pad, checked on its own
			var got := _bake.frame_texel(c, r)
			var across := clampf(want.x if want.x != INF else LevelBake.FRAME_RANGE, -LevelBake.FRAME_RANGE, LevelBake.FRAME_RANGE)
			assert_almost_eq(got.x, across, 0.07, "across at %s, %s" % [x, z])
			assert_almost_eq(got.y, clampf(want.y, 0.0, LevelBake.FRAME_RANGE), 0.04, "half-width")
			var along_gap := absf(fposmod(got.z - want.z + LevelBake.ALONG_PERIOD / 2, LevelBake.ALONG_PERIOD) - LevelBake.ALONG_PERIOD / 2)
			assert_lt(along_gap, 0.14, "along")
			assert_almost_eq(got.w, want.w, 0.5 / 15.0 + 1e-4, "junction weight")
			assert_almost_eq(_bake.frame_tarmac(c, r), _data.nearest(x, z).w, 0.5 / 15.0 + 1e-4, "tarmac at %s, %s" % [x, z])


func test_the_frame_junction_channel_is_one_at_a_junction_and_zero_away() -> void:
	var fcell := float(SIZE) / (_bake.frame_n - 1)
	var at := func(x: float, z: float) -> Vector4:
		return _bake.frame_texel(roundi((x + SIZE / 2.0) / fcell), roundi((z + SIZE / 2.0) / fcell))
	assert_almost_eq(at.call(0.0, 0.0).w, 1.0, 0.05, "junction centre")
	assert_eq(at.call(-50.0, -10.0).w, 0.0, "away from any junction")


func test_a_gravel_patch_is_an_even_gravel_pad_in_the_frame() -> void:
	var fcell := float(SIZE) / (_bake.frame_n - 1)
	var c := roundi((-32.0 + SIZE / 2.0) / fcell)
	var r := roundi((36.0 + SIZE / 2.0) / fcell)
	var t := _bake.frame_texel(c, r)
	assert_lt(t.x, t.y, "inside the road edge the shader draws")
	assert_almost_eq(t.w, 1.0, 0.01, "junction weight 1: no ruts, no direction")
	assert_eq(_bake.frame_tarmac(c, r), 0.0)
	assert_lt(_bake.patch_distance(-32.0, 36.0), 0.0)
	assert_eq(_bake.patch_distance(-32.0, 36.0), _data.patch_at(-32.0, 36.0).x)
	assert_gt(_bake.surface_at(-32.0, 36.0).x, 0.99)


func test_a_road_across_a_gravel_patch_keeps_its_own_surface() -> void:
	var fcell := float(SIZE) / (_bake.frame_n - 1)
	var c := roundi((45.0 + SIZE / 2.0) / fcell)
	var r := roundi((7.0 + SIZE / 2.0) / fcell)
	assert_lt(_bake.patch_distance(45.0, 7.0), 0.0, "the paved end runs through a patch")
	assert_lt(absf(_bake.frame_texel(c, r).w - _data.road_frame(c * fcell - SIZE / 2.0, r * fcell - SIZE / 2.0).w), 0.1, "drawn as the road, not the pad")
	assert_gt(_bake.frame_tarmac(c, r), 0.5, "still tarmac")
	assert_gt(_bake.surface_at(45.0, 7.0).y, 0.5, "and drives as tarmac")


func test_surface_and_poses_agree_with_the_level_data() -> void:
	assert_gt(_bake.surface_at(45.0, 7.0).y, 0.5, "the paved end is tarmac")
	for p in [Vector2(0.0, 0.0), Vector2(0.0, 30.0), Vector2(30.0, -40.0), Vector2(-40.0, 5.0), Vector2(45.0, 7.0)]:
		assert_eq(_bake.surface_at(p.x, p.y), _data.surface_at(p.x, p.y))
		var want := _data.road_pose(p, Vector3(1.0, 0.0, 0.2))
		var got := _bake.road_pose(p, Vector3(1.0, 0.0, 0.2))
		assert_almost_eq(got.origin.x, want.origin.x, 0.001)
		assert_almost_eq(got.origin.z, want.origin.z, 0.001)
		assert_almost_eq(got.origin.y, want.origin.y, 0.2)
		assert_almost_eq(got.basis.z.dot(want.basis.z), 1.0, 0.001)
	var spawn := _bake.spawn_pose()
	var spawn_want := _data.spawn_pose()
	assert_almost_eq(spawn.origin.x, spawn_want.origin.x, 0.001)
	assert_almost_eq(spawn.origin.y, spawn_want.origin.y, 0.2)
	assert_almost_eq(spawn.basis.z.dot(spawn_want.basis.z), 1.0, 0.001)


func test_a_bake_survives_saving_and_loading() -> void:
	var path := "user://test_level_bake.res"
	assert_eq(ResourceSaver.save(_bake, path), OK)
	var back := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as LevelBake
	assert_eq(back.heights, _bake.heights)
	assert_eq(back.frame, _bake.frame)
	assert_eq(back.sx, _bake.sx)
	assert_eq(back.sc, _bake.sc)
	assert_eq(back.st, _bake.st)
	assert_eq(back.patches, _bake.patches)
	assert_eq(back.source_key, "k")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_an_edited_save_makes_the_bake_stale_and_an_unedited_one_does_not() -> void:
	var write := func(text: String) -> void:
		var f := FileAccess.open(SAVE, FileAccess.WRITE)
		f.store_string(text)
		f.close()
	write.call('{"size": 120, "roads": []}')
	var before := LevelBake.baked_in_process
	var first := LevelBake.load_or_bake(SAVE, _data)
	assert_eq(LevelBake.baked_in_process, before + 1, "no bake yet, so one is made")
	assert_eq(first.source_key, LevelBake.key_of(SAVE))
	var again := LevelBake.load_or_bake(SAVE, _data)
	assert_eq(LevelBake.baked_in_process, before + 1, "an unedited save reuses the saved bake")
	assert_eq(again.source_key, first.source_key)
	write.call('{"size": 120, "roads": [], "edited": true}')
	var rebuilt := LevelBake.load_or_bake(SAVE, _data)
	assert_eq(LevelBake.baked_in_process, before + 2, "an edited save is baked again")
	assert_ne(rebuilt.source_key, first.source_key)
	write.call('{"size": 120, "roads": [], "edited": true, "coverKinds": {"1": [[{"base": "#123456"}, 1.0]]}}')
	LevelBake.load_or_bake(SAVE, _data)
	assert_eq(LevelBake.baked_in_process, before + 2, "retuning ground cover recipes keeps the bake")


func test_a_bake_on_another_thread_reports_progress_and_returns_the_bake() -> void:
	LevelBake.progress = 0.0
	var worker := Thread.new()
	worker.start(LevelBake.load_or_bake.bind("", _data))
	var b: LevelBake = worker.wait_to_finish()
	assert_not_null(b)
	assert_gt(LevelBake.progress, 0.5, "the progress walked through both grids")


func test_an_empty_path_bakes_in_memory() -> void:
	var before := LevelBake.baked_in_process
	assert_not_null(LevelBake.load_or_bake("", _data))
	assert_eq(LevelBake.baked_in_process, before + 1)


func _tree_bake() -> LevelBake:
	var data := LevelData.new()
	data.load_save({"size": SIZE, "roads": [[_node(-50.0, 0.0), _node(50.0, 0.0)]], "trees": [
		{"x": 50.0, "z": 50.0, "rot": 0.0, "sx": 1.0, "sy": 1.0, "kind": "tree.png"},
		{"x": -50.0, "z": -50.0, "rot": 0.0, "sx": 1.0, "sy": 1.0, "kind": "tree-greece.webp"},
		{"x": 51.0, "z": 50.0, "rot": 0.0, "sx": 1.0, "sy": 2.0, "kind": "tree.png"}]})
	return LevelBake.bake(data)


func test_trees_are_numbered_tile_by_tile_and_every_tree_is_in_its_tile() -> void:
	var b := _tree_bake()
	assert_eq(b.tree_count(), 3)
	assert_eq(b.tree_tile_first[b.tree_tile_first.size() - 1], 3)
	for i in b.tree_count():
		var t := b.tree_tile_at(i)
		assert_eq(b.tree_tile_of(b.tree_xf[i * 12 + 3], b.tree_xf[i * 12 + 11]), t)
		assert_true(i >= b.tree_tile_first[t] and i < b.tree_tile_first[t + 1])


func test_visibility_rows_answer_per_tile_ranges_in_order() -> void:
	var b := _tree_bake()
	assert_false(b.has_visibility())
	b.set_visibility(4, [[2, 0], [1], []])
	assert_true(b.has_visibility())
	assert_eq(b.vis_row_count(), 3)
	assert_eq(b.visible_in(0, 0, 3), PackedInt32Array([0, 2]))
	assert_eq(b.visible_in(0, 1, 3), PackedInt32Array([2]))
	assert_eq(b.visible_in(1, 0, 1), PackedInt32Array())
	assert_eq(b.visible_in(9, 0, 3), PackedInt32Array(), "past the last row nothing is seen")


func test_trees_and_visibility_survive_saving_and_loading() -> void:
	var b := _tree_bake()
	b.set_visibility(4, [[0, 1]])
	var path := "user://test_level_bake_trees.res"
	assert_eq(ResourceSaver.save(b, path), OK)
	var back := ResourceLoader.load(path) as LevelBake
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	assert_eq(back.tree_xf, b.tree_xf)
	assert_eq(back.tree_kind, b.tree_kind)
	assert_eq(back.tree_tile_first, b.tree_tile_first)
	assert_eq(back.visible_in(0, 0, 3), PackedInt32Array([0, 1]))


func test_heights_with_big_jumps_survive_the_stored_form() -> void:
	var b := LevelBake.new()
	b.heights.resize(8)
	for i in 4:
		b.heights.encode_u16(i * 2, [0, 65535, 3, 40000][i])
	var back := LevelBake.new()
	back._unzip_heights(b._zip_heights())
	assert_eq(back.heights, b.heights)


func test_visibility_rows_decode_in_any_order_across_keyframes() -> void:
	var rows := []
	for r in LevelBake.VIS_KEY * 2 + 5:
		rows.append([r % 7, 10 + r % 3, 20 + r])
	var b := _tree_bake()
	b.set_visibility(4, rows)
	var path := "user://test_level_bake_vis.res"
	assert_eq(ResourceSaver.save(b, path), OK)
	var back := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as LevelBake
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var order := [LevelBake.VIS_KEY + 3, 2, LevelBake.VIS_KEY - 1, LevelBake.VIS_KEY, rows.size() - 1, LevelBake.VIS_KEY + 2]
	order.append_array([5, 6, 5, 6, 7, 1, 5])  # neighbouring rows asked in turn, as the trees do per tile
	for r: int in order:
		var want := PackedInt32Array(rows[r])
		want.sort()
		assert_eq(b.visible_in(r, 0, 1 << 30), want, "row %d" % r)
		assert_eq(back.visible_in(r, 0, 1 << 30), want, "row %d after reload" % r)
		assert_eq(b.visible_in(r, 10, 20), PackedInt32Array(Array(want).filter(func(v: int) -> bool: return v >= 10 and v < 20)), "row %d in [10, 20)" % r)


func test_a_bake_with_trees_but_no_visibility_is_incomplete() -> void:
	var b := _tree_bake()
	assert_true(b.is_incomplete())
	b.set_visibility(4, [[0]])
	assert_false(b.is_incomplete())
	assert_false(_bake.is_incomplete(), "no trees, nothing to cull")


func test_visibility_gate_rejects_unknown_trees_and_far_ones_but_passes_local_rows() -> void:
	var b := _tree_bake()
	b.sx = PackedFloat32Array([50.0])
	b.sz = PackedFloat32Array([50.0])
	b.set_visibility(4, [[0, 2]])
	assert_eq(b.visibility_problem(100.0), "", "both trees are within reach of the viewpoint")
	b.sx = PackedFloat32Array([1000.0])
	b.sz = PackedFloat32Array([1000.0])
	b.set_visibility(4, [[0, 1, 2]])
	assert_ne(b.visibility_problem(100.0), "", "a row of trees beyond reach is refused")
	b.set_visibility(4, [[0, 2]])
	assert_eq(b.visibility_problem(100.0), "", "a stray pair of far trees is tolerated")
	b.sx = PackedFloat32Array([50.0])
	b.sz = PackedFloat32Array([50.0])
	b.set_visibility(4, [[0, 99]])
	assert_ne(b.visibility_problem(1000.0), "", "an id past the last tree is refused")
	b.set_visibility(4, [[-1, 0]])
	assert_ne(b.visibility_problem(1000.0), "", "a negative id is refused")
	assert_eq(_tree_bake().visibility_problem(1.0), "", "no visibility baked means nothing to check")


func test_spectators_see_a_gravel_pad_as_ground_not_road() -> void:
	assert_gt(_bake.surface_at(-32.0, 36.0).x, 0.99)
	assert_lt(LevelSpectators.road_only(-32.0, 36.0, _bake).x, 0.5)
	var road := _bake.spawn_nodes[0]
	assert_gt(LevelSpectators.road_only(road.x, road.y, _bake).x, 0.99, "the road itself still counts")


func test_shops_not_in_bake_key() -> void:
	var path := "user://shop_key_test.json"
	var write := func(shops: Array) -> void:
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(JSON.stringify({"roads": [], "shops": shops}))
		f.close()
	write.call([])
	var a := LevelBake.key_of(path)
	write.call([{"x": 1, "z": 2, "name": "A shop", "stock": [{"part": "turbo", "price": 100}]}])
	assert_eq(LevelBake.key_of(path), a)


func test_decoding_a_row_off_the_shared_cache_matches_the_cached_answer() -> void:
	var rows := []
	for r in LevelBake.VIS_KEY * 2 + 5:
		rows.append([r % 7, 10 + r % 3, 20 + r])
	var b := _tree_bake()
	b.set_visibility(4, rows)
	for r in rows.size():
		var fresh := b.decoded_row(r)
		assert_eq(fresh, b.visible_in(r, 0, 1 << 30), "row %d from its keyframe" % r)
		if r + 1 < rows.size():
			assert_eq(b.decoded_row(r + 1, r, fresh), b.visible_in(r + 1, 0, 1 << 30), "row %d stepped on from %d" % [r + 1, r])
