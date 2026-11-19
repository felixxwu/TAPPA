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


func test_build_places_every_tuft_once_in_tiles_drawn_only_near_the_camera() -> void:
	var cells: Array = []
	for x in GRID:
		for z in GRID:
			cells.append(Vector2i(x, z))
	var kinds := {"1": [[BLADES, 2.0]]}
	var gc := GroundCover.new()
	add_child_autofree(gc)
	gc.setup({"cover": Marshalls.raw_to_base64(_cover(cells)), "coverKinds": kinds}, _flat, GRID)
	gc.build()
	var expected: int = GroundCover.placements(_cover(cells), GRID, kinds, Vector2.ZERO, GRID, _flat)["1:0"].size() / 12
	var total := 0
	var tiles := {}
	for c in gc.get_children():
		var mmi := c as MultiMeshInstance3D
		total += mmi.multimesh.instance_count
		tiles[mmi.custom_aabb.position] = true
		assert_gt(mmi.visibility_range_end, 0.0, "a tile stops drawing past its reach")
	assert_eq(total, expected, "every tuft, none twice")
	assert_eq(tiles.size(), gc.get_child_count(), "one MultiMesh per tile")
	assert_gt(tiles.size(), 1, "the square is split into tiles")
