extends GutTest
# Ground cover (features/level-editor.md): tuft meshes, deterministic placement from the cover grid, and the save's cover/coverKinds.
# All presets and grids here are synthetic.

const GRID := 40
const BLADES := {"shape": "blades", "blades": 4, "radius": 0.1, "height": 0.5, "heightJitter": 0.3, "width": 0.05, "segments": 3,
	"lean": 20, "leanJitter": 10, "bend": 30, "colourVar": 0.1, "flowers": 0, "flowerColour": "#f2d01c", "base": "#335522", "tip": "#88aa44"}
const BUSH := {"shape": "bush", "bushRadius": 0.6, "bushHeight": 0.5, "leaves": 10, "leafSize": 0.2, "fuzz": 0.4, "core": 1,
	"flowers": 0, "colourVar": 0.1, "base": "#335522", "tip": "#88aa44"}


func _tris(m: ArrayMesh) -> int:
	return (m.surface_get_arrays(0)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3


func _flat(_x: float, _z: float) -> float:
	return 2.0


func _cover(cells: Array) -> PackedByteArray:
	var c := PackedByteArray()
	c.resize(GRID * GRID)
	for cell: Vector2i in cells:
		c[cell.y * GRID + cell.x] = 1
	return c


func test_blade_triangle_count() -> void:
	assert_eq(_tris(GroundCover.build_tuft(1, BLADES)), 4 * (2 * 3 - 1))


func test_flowers_add_triangles() -> void:
	var s := BLADES.duplicate()
	s["flowers"] = 3.0
	assert_eq(_tris(GroundCover.build_tuft(1, s)), 4 * 5 + 3)


func test_bush_mesh_is_not_empty() -> void:
	assert_gt(_tris(GroundCover.build_tuft(1, BUSH)), 10)


func test_placement_is_deterministic_and_only_on_cover_cells() -> void:
	var kinds := {"1": [[BLADES, 3.0]]}
	var cells := [Vector2i(20, 20), Vector2i(22, 21)]
	var a := GroundCover.placements(_cover(cells), GRID, kinds, Vector2.ZERO, 30.0, _flat)
	var b := GroundCover.placements(_cover(cells), GRID, kinds, Vector2.ZERO, 30.0, _flat)
	assert_eq(a, b)
	var buf: PackedFloat32Array = a["1:0"]
	assert_gt(buf.size(), 0)
	for i in buf.size() / 12:
		var x := buf[i * 12 + 3] + GRID / 2.0
		var z := buf[i * 12 + 11] + GRID / 2.0
		assert_true(Vector2i(floori(x), floori(z)) in cells)
		assert_eq(buf[i * 12 + 7], 2.0)


func test_nothing_placed_beyond_reach() -> void:
	var kinds := {"1": [[BLADES, 3.0]]}
	var far := GroundCover.placements(_cover([Vector2i(20, 20)]), GRID, kinds, Vector2(-15, -15), 5.0, _flat)
	assert_true(far.is_empty())


func test_cover_decodes_from_save() -> void:
	var raw := _cover([Vector2i(3, 4)])
	var back := GroundCover.decode_cover({"cover": Marshalls.raw_to_base64(raw)})
	assert_eq(back, raw)
	assert_true(GroundCover.decode_cover({}).is_empty())


# 6x6 lossless WebP encoded by PIL: cell i = (i * 7) % 5, except cells 0, 1 and 35 = 255, 0 and 200.
const COVER_WEBP := "UklGRkwAAABXRUJQVlA4TEAAAAAvBUABADdAkG2z+pOd6SJk0jaNf2XTtIdM2qbxr2ya9sx/VAEA/tsGCiLZoN6HBgKooIIq+teQIaL/NcjyTr8c"


func test_cover_decodes_lossless_webp() -> void:
	var expected := PackedByteArray()
	expected.resize(36)
	for i in expected.size():
		expected[i] = (i * 7) % 5
	expected[0] = 255
	expected[1] = 0
	expected[35] = 200
	assert_eq(GroundCover.decode_cover({"size": 6, "coverWebp": COVER_WEBP}), expected)


func test_cover_decodes_run_length_encoding() -> void:
	var raw := PackedByteArray()
	raw.resize(16)
	for i in 5:
		raw[i] = 2
	for i in range(9, 16):
		raw[i] = 3
	var rle := PackedByteArray([2, 5, 0, 4, 3, 7])
	var back := GroundCover.decode_cover({"size": 4, "coverRle": Marshalls.raw_to_base64(rle)})
	assert_eq(back, raw)
	var long := GroundCover.decode_cover({"size": 20, "coverRle": Marshalls.raw_to_base64(PackedByteArray([7, 0x90, 0x03]))})
	assert_eq(long.size(), 400)
	assert_eq(long[399], 7)


func test_tint_derives_from_layer_colours() -> void:
	var a := BLADES.duplicate()
	a["base"] = "#000000"
	a["tip"] = "#000000"
	var b := BLADES.duplicate()
	b["base"] = "#ffffff"
	b["tip"] = "#ffffff"
	var t := GroundCover.tints({"1": [[a, 1.0], [b, 1.0]], "2": [[b, 2.0]]})
	assert_almost_eq((t[1] as Color).r, 0.5, 0.01)
	assert_almost_eq((t[2] as Color).g, 1.0, 0.01)


func test_ground_multiplier_is_white_off_cover_and_tinted_on_it() -> void:
	var tint := {1: Color(0.2, 0.3, 0.1)}
	assert_eq(GroundCover.ground_multiplier(_cover([]), GRID, tint, 0.0, 0.0), Color.WHITE)
	var all := PackedByteArray()
	all.resize(GRID * GRID)
	all.fill(1)
	assert_ne(GroundCover.ground_multiplier(all, GRID, tint, 0.0, 0.0), Color.WHITE)


func test_tuft_hidden_past_its_cutoff_and_shown_inside_fade_start() -> void:
	var cut := GroundCover.cutoff(5.0, 7.0, 22.0, 34.0)
	assert_between(cut, 22.0, 34.0)
	assert_eq(GroundCover.shown(cut + 0.1, cut), 0.0)
	assert_eq(GroundCover.shown(21.0, cut), 1.0)


func test_far_placements_only_for_bush_layers() -> void:
	var kinds_d := {"1": [[BUSH, 3.0], [BLADES, 3.0]]}
	var far := {}
	var near := GroundCover.placements(_cover([Vector2i(20, 20)]), GRID, kinds_d, Vector2(0.5, 0.5), 5.0, Callable(self, "_flat"), 15.0, far)
	assert_true(far.has("1:0"))
	assert_false(far.has("1:1"))
	assert_true(near.has("1:1"))
	assert_eq(far["1:0"], near["1:0"])


func test_far_mesh_is_cheaper_than_near_and_shares_nothing_with_grass() -> void:
	var far := GroundCover.build_far_bush(BUSH)
	assert_gt(_tris(far), 0)
	assert_lt(_tris(far), _tris(GroundCover.build_tuft(1, BUSH)))


func test_far_reach_extends_far_list_only() -> void:
	var far := {}
	var near := GroundCover.placements(_cover([Vector2i(35, 20)]), GRID, {"1": [[BUSH, 3.0]]}, Vector2(0.5, 0.5), 5.0, Callable(self, "_flat"), 25.0, far)
	assert_true(near.is_empty())
	assert_true(far.has("1:0"))


func test_each_bush_is_drawn_by_exactly_one_of_near_and_far() -> void:
	var cut := GroundCover.cutoff(5.0, 7.0, 22.0, 34.0)
	var far_cut := GroundCover.cutoff(5.0, 7.0, 70.0, 90.0)
	var d := 0.0
	while d < far_cut - 2.0:
		var near_on := GroundCover.shown(d, cut) > 0.0
		var far_on := GroundCover.far_scale(d, cut, far_cut) > 0.0
		assert_ne(near_on, far_on, "d=%s" % d)
		d += 0.25
	assert_eq(GroundCover.far_scale(far_cut + 0.1, cut, far_cut), 0.0)


func test_bush_spots_are_where_the_bushes_are_drawn_and_skip_grass() -> void:
	var cov := PackedByteArray([1, 2, 2, 1])
	var kinds := {"1": [[{"shape": "bush", "bushRadius": 0.5}, 2.0]], "2": [[{"shape": "blades"}, 5.0]]}
	var spots := GroundCover.bush_spots(cov, 2, kinds)
	assert_eq(spots.size(), 1, "only the bush layer")
	assert_eq(float(spots[0][1]), 0.5)
	var drawn: PackedFloat32Array = GroundCover.placements(cov, 2, kinds, Vector2.ZERO, 100.0,
		func(_x: float, _z: float) -> float: return 0.0)["1:0"]
	var pts: PackedVector2Array = spots[0][0]
	assert_eq(pts.size(), drawn.size() / 12)
	for i in pts.size():
		assert_almost_eq(pts[i], Vector2(drawn[i * 12 + 3], drawn[i * 12 + 11]), Vector2(1e-4, 1e-4))


func _cover_node(kinds: Dictionary) -> GroundCover:
	var cells: Array = []
	for x in GRID:
		for z in GRID:
			cells.append(Vector2i(x, z))
	var gc := GroundCover.new()
	add_child_autofree(gc)
	gc.setup({"cover": Marshalls.raw_to_base64(_cover(cells)), "coverKinds": kinds}, _flat, GRID)
	return gc


func test_tiles_place_every_tuft_once_and_draw_only_near_the_camera() -> void:
	var kinds := {"1": [[BLADES, 2.0]]}
	var gc := _cover_node(kinds)
	gc.stream(Vector2.ZERO, Time.get_ticks_usec() + 60_000_000)
	var cells: Array = []
	for x in GRID:
		for z in GRID:
			cells.append(Vector2i(x, z))
	var expected: int = GroundCover.placements(_cover(cells), GRID, kinds, Vector2.ZERO, GRID, _flat)["1:0"].size() / 12
	var total := 0
	for node: Node3D in gc.tiles.values():
		for mmi: MultiMeshInstance3D in node.get_children():
			total += mmi.multimesh.instance_count
			assert_gt(mmi.visibility_range_end, 0.0, "a tile stops drawing past its reach")
	assert_eq(total, expected, "every tuft, none twice")
	assert_gt(gc.tiles.size(), 1, "the square is split into tiles")


func test_tiles_far_from_the_camera_are_dropped_and_missing_ones_wait_for_budget() -> void:
	var gc := _cover_node({"1": [[BLADES, 2.0]]})
	gc.stream(Vector2.ZERO, Time.get_ticks_usec() + 60_000_000)
	assert_gt(gc.tiles.size(), 0)
	gc.stream(Vector2(1.0e5, 0.0), Time.get_ticks_usec() + 60_000_000)
	assert_eq(gc.tiles.size(), 0, "tiles beyond reach are dropped")


func test_the_tiles_round_the_car_build_even_with_no_budget_left() -> void:
	var gc := _cover_node({"1": [[BLADES, 2.0]]})
	gc.stream(Vector2(1.0, 1.0), 0)
	assert_true(gc.tiles.has(Vector2i.ZERO), "the tile under the camera")
	assert_true(gc.tiles.has(Vector2i(-1, -1)), "and its neighbours")


func test_tiles_outside_the_floor_ring_wait_for_budget() -> void:
	var cov := PackedByteArray()
	cov.resize(200 * 200)
	cov.fill(1)
	var gc := GroundCover.new()
	add_child_autofree(gc)
	gc.setup({"cover": Marshalls.raw_to_base64(cov), "coverKinds": {"1": [[BLADES, 0.1]]}}, _flat, 200)
	gc.stream(Vector2.ZERO, 0)
	assert_eq(gc.tiles.size(), 9, "only the tile under the camera and its eight neighbours")
	assert_false(gc.tiles.has(Vector2i(2, 2)), "a tile past the ring waits")
	assert_gt(gc.missing(Vector2.ZERO).size(), 0)


func test_after_a_full_stream_no_tile_in_reach_is_missing() -> void:
	var gc := _cover_node({"1": [[BLADES, 2.0]]})
	gc.stream(Vector2.ZERO, Time.get_ticks_usec() + 60_000_000)
	assert_true(gc.missing(Vector2.ZERO).is_empty())


func test_a_tile_owns_bush_fields_that_go_with_it() -> void:
	var gc := _cover_node({"1": [[BUSH, 2.0]]})
	var car := Node3D.new()
	add_child_autofree(car)
	gc.stream(Vector2.ZERO, Time.get_ticks_usec() + 60_000_000, car)
	var tile: Node3D = gc.tiles.values()[0]
	assert_gt(tile.find_children("*", "BushField", false, false).size(), 0)
	var first: Vector2i = gc.tiles.keys()[0]
	gc.stream(Vector2(1.0e5, 0.0), Time.get_ticks_usec() + 60_000_000)
	await get_tree().process_frame
	assert_false(is_instance_valid(tile), "the fields leave with their tile")
	assert_false(gc.tiles.has(first))


func test_a_tiles_draw_box_wraps_its_tufts_where_the_ground_is_not_around_the_origin() -> void:
	var buf := PackedFloat32Array()
	for y in [300.0, 310.0]:
		buf.append_array([1, 0, 0, 40.0, 0, 1, 0, y, 0, 0, 1, 50.0])
	var box := GroundCover.tile_aabb(Vector2i(1, 1), buf)
	for y in [300.0, 310.0]:
		assert_true(box.has_point(Vector3(40.0, y, 50.0)), "the tuft is inside the box")
	assert_almost_eq(box.get_center().y, 305.0, 5.0, "the draw range is measured to the box's middle, so it must sit at the tufts")
