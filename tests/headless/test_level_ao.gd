extends GutTest
# LevelAO and the bush ground shade: darkening lands where objects are and nowhere else. Inputs are synthetic.


func _xf(x: float, z: float, width: float) -> PackedFloat32Array:
	return PackedFloat32Array([width, 0, 0, x, 0, 1, 0, 0, 0, 0, width, z])


func test_empty_map_is_white() -> void:
	var ao := LevelAO.new(100.0, 51)
	assert_eq(ao.at(0.0, 0.0), 1.0)
	ao.stamp_trees(PackedFloat32Array(), 0.3)
	assert_eq(ao.at(10.0, -10.0), 1.0)


func test_tree_position_round_trips() -> void:
	var ao := LevelAO.new(100.0, 51)
	ao.stamp_trees(_xf(10.3, -7.7, 4.0), 0.3)
	var c := roundi((10.3 + 50.0) / ao.cell())
	var r := roundi((-7.7 + 50.0) / ao.cell())
	var tree := ao.tree_at(c, r)
	assert_false(tree.is_empty())
	assert_lt((tree.pos as Vector2).distance_to(Vector2(10.3, -7.7)), ao.cell() / 16.0)
	assert_gt(tree.radius, 0.0)


func test_texel_without_tree_is_empty() -> void:
	var ao := LevelAO.new(100.0, 51)
	assert_true(ao.tree_at(3, 3).is_empty())
	ao.stamp_trees(_xf(10.0, 10.0, 4.0), 0.3)
	assert_true(ao.tree_at(3, 3).is_empty())


func test_wider_tree_wins_shared_texel() -> void:
	var ao := LevelAO.new(100.0, 51)
	var both := _xf(10.0, 10.0, 1.0)
	both.append_array(_xf(10.2, 10.1, 6.0))
	ao.stamp_trees(both, 0.3)
	var c := roundi(60.0 / ao.cell())
	assert_lt((ao.tree_at(c, c).pos as Vector2).distance_to(Vector2(10.2, 10.1)), ao.cell() / 16.0 + 0.01)


func test_box_dark_inside_fading_outside() -> void:
	var ao := LevelAO.new(100.0, 101)
	ao.stamp_box(Vector2(0, 0), Vector2.RIGHT, Vector2(4, 2), 4.0, 0.6)
	var inside := ao.at(0.0, 0.0)
	var near := ao.at(5.0, 0.0)
	var far := ao.at(30.0, 0.0)
	assert_lt(inside, near)
	assert_lt(near, far)
	assert_eq(far, 1.0)


func test_box_follows_its_axis() -> void:
	var ao := LevelAO.new(100.0, 101)
	ao.stamp_box(Vector2(0, 0), Vector2.DOWN, Vector2(6, 1), 1.0, 0.6)
	assert_lt(ao.at(0.0, 5.0), 1.0)
	assert_eq(ao.at(5.0, 0.0), 1.0)


func test_box_at_map_edge_does_not_crash() -> void:
	var ao := LevelAO.new(100.0, 51)
	ao.stamp_box(Vector2(60, 60), Vector2.RIGHT, Vector2(8, 8), 10.0, 0.5)
	assert_eq(ao.at(0.0, 0.0), 1.0)


func test_bush_cover_darkens_ground() -> void:
	var grid := 8
	var cov := PackedByteArray()
	cov.resize(grid * grid)
	cov.fill(1)
	var kinds := {"1": [[{"bushRadius": 1.0}, 1.0]], "2": [[{"base": "#000000"}, 1.0]]}
	var ids := GroundCover.bush_ids(kinds)
	assert_true(ids.has(1))
	assert_false(ids.has(2))
	assert_lt(GroundCover.bush_shade(cov, grid, ids, 0.0, 0.0, 0.3), 1.0)
	cov.fill(2)
	assert_eq(GroundCover.bush_shade(cov, grid, ids, 0.0, 0.0, 0.3), 1.0)
	assert_eq(GroundCover.bush_shade(PackedByteArray(), grid, ids, 0.0, 0.0, 0.3), 1.0)


func test_spectator_feet_darker_than_head() -> void:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 5, 0)])
	arrays[Mesh.ARRAY_COLOR] = PackedColorArray([Color.WHITE, Color.WHITE, Color.WHITE])
	var src := ArrayMesh.new()
	src.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var cols: PackedColorArray = Crowd._with_base_shade(src, null).surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	assert_lt(cols[0].r, 1.0)
	assert_eq(cols[2], Color.WHITE)
