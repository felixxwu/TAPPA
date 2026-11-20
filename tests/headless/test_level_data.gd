extends GutTest
# LevelData (scripts/level_data.gd): the level save's unpacking and road/terrain queries, with no scene.
# Every level here is synthetic; nothing reads the shipped Hafren save.


func _node(x: float, z: float, w := 3.0) -> Dictionary:
	return {"x": x, "z": z, "w": w, "m": null, "tension": 1.0}


# A straight road along x through the middle of a flat 600 m square.
func _level(ground := 0.0) -> Dictionary:
	var hm: Array = []
	hm.resize(201 * 201)
	hm.fill(ground)
	return {"road": [_node(-100.0, 0.0), _node(100.0, 0.0)], "heightmap": hm}


# A through road along x and a side road that ends on its middle node (a T), plus a far-off road.
func _network() -> Dictionary:
	return {"roads": [[_node(-100.0, 0.0), _node(0.0, 0.0), _node(100.0, 0.0)],
		[_node(0.0, 0.4, 2.0), _node(0.0, 60.0, 2.0)],
		[_node(-100.0, 200.0), _node(100.0, 200.0)]]}


func _built(level: Dictionary) -> LevelData:
	var data := LevelData.new()
	data.load_save(level)
	return data


func test_unpack_restores_trees_and_the_height_grid() -> void:
	var raw := PackedByteArray()
	raw.resize(4)
	raw.encode_s16(0, 15)
	raw.encode_s16(2, -20)
	var packed := {"kinds": ["a.png", "b.png"], "trees": [[1.5, -2.0, 30, 1.2, 0.8, 1]],
		"heightmap": Marshalls.raw_to_base64(raw)}
	var out := LevelData.unpack(packed)
	assert_eq(out["trees"][0]["kind"], "b.png")
	assert_almost_eq(float(out["trees"][0]["x"]), 1.5, 1e-6)
	assert_false(out.has("kinds"))
	assert_almost_eq(out["heightmap"][0], 1.5, 1e-6, "decimetres become metres")
	assert_almost_eq(out["heightmap"][1], -2.0, 1e-6)


# 3x3 lossless WebP encoded by PIL (R = high byte, G = low byte of decimetres + 32768).
const HEIGHT_WEBP := "UklGRkYAAABXRUJQVlA4TDoAAAAvAoAAAEdgJgAZLkron0YNBRZgNRS1kQLt+ccyhrFAzH8A/3EJDKE7HSsoaNuGjfXtIBqARfQ/frhX"


func test_unpack_reads_a_lossless_webp_height_grid() -> void:
	var decimetres := [0, 15, -20, 32767, -32768, 1234, -4321, 7, 300]
	var out := LevelData.unpack({"heightWebp": HEIGHT_WEBP})
	assert_eq(out["heightmap"].size(), decimetres.size())
	for i in decimetres.size():
		assert_almost_eq(out["heightmap"][i], decimetres[i] / 10.0, 1e-4)
	assert_false(out.has("heightWebp"))


func test_unpack_reads_binary_trees() -> void:
	var raw := PackedByteArray()
	raw.resize(14)
	raw.encode_u16(0, 0)
	raw.encode_u16(2, 5000)
	raw[4] = 64
	raw[5] = 150
	raw[6] = 1
	raw.encode_u16(7, 30000)
	raw.encode_u16(9, 25500)
	raw[11] = 0
	raw[12] = 35
	raw[13] = 0
	var out := LevelData.unpack({"size": 5000, "kinds": ["a.png", "b.png"], "treesBin": Marshalls.raw_to_base64(raw)})
	assert_eq(out["trees"].size(), 2)
	var t0: Dictionary = out["trees"][0]
	assert_almost_eq(t0["x"], -2500.0, 1e-3)
	assert_almost_eq(t0["z"], -2000.0, 1e-3)
	assert_almost_eq(t0["rot"], 90.0, 1e-3)
	assert_almost_eq(t0["sx"], 1.5, 1e-3)
	assert_almost_eq(t0["sy"], 1.5, 1e-3)
	assert_eq(t0["kind"], "b.png")
	var t1: Dictionary = out["trees"][1]
	assert_almost_eq(t1["x"], 500.0, 1e-3)
	assert_almost_eq(t1["z"], 50.0, 1e-3)
	assert_almost_eq(t1["sx"], 0.35, 1e-3)
	assert_eq(t1["kind"], "a.png")
	assert_false(out.has("treesBin"))
	assert_false(out.has("kinds"))


func test_a_non_default_size_reads_its_own_grid() -> void:
	var n := 10
	var hm: Array = []
	for r in n + 1:
		for c in n + 1:
			hm.append(float(c))  # height equals the column
	var data := _built({"size": 1000, "heightmap": hm})
	assert_eq(data.size, 1000.0)
	assert_eq(data.grid_n, n)
	assert_almost_eq(data.natural(-500.0, 0.0), 0.0, 1e-4, "west edge is column 0")
	assert_almost_eq(data.natural(0.0, 0.0), 5.0, 1e-4, "the middle is halfway across the grid")
	assert_almost_eq(data.natural(250.0, -300.0), 7.5, 1e-4, "100 m cells, so 250 m east of centre is 7.5 columns")
	assert_eq(_built({"size": 1000}).natural(10.0, 10.0), 0.0, "no grid is flat")


func test_the_road_is_road_and_the_field_beside_it_is_not() -> void:
	var data := _built(_level())
	assert_gt(data.surface_at(0.0, 0.0).x, 0.9, "on the centreline")
	assert_lt(data.surface_at(0.0, 40.0).x, 0.01, "well off it")


func test_ground_is_pulled_to_the_road_level_and_left_alone_far_from_it() -> void:
	var data := _built(_level(10.0))
	assert_almost_eq(data.ground(0.0, 0.0), 10.0, 0.2, "the road sits on the saved ground")
	assert_almost_eq(data.ground(0.0, 200.0), 10.0, 0.01, "far ground is the saved grid")


func test_the_flat_margin_setting_moves_where_the_ground_rises_beside_the_road() -> void:
	var level := _level()
	level["road"] = [_node(-100.0, 0.0, 8.0), _node(100.0, 0.0, 8.0)]
	var hm: Array = level["heightmap"]
	for r in 201:
		for c in 201:
			hm[r * 201 + c] = absf(r * 3.0 - 300.0) * 0.5  # a valley along the road
	var data := _built(level)
	data.flat_margin = 3.0
	var wide := data.ground(0.0, 10.0)  # 2 m past the road's edge
	data.flat_margin = 0.0
	var none := data.ground(0.0, 10.0)
	assert_lt(wide, 0.5, "inside the margin the ground stays at road height")
	assert_gt(none, 2.0, "with no margin it is back on the valley side")


func test_road_frame_gives_signed_distance_half_width_and_distance_along() -> void:
	var data := _built(_level())
	var left := data.road_frame(0.0, -10.0)
	var right := data.road_frame(0.0, 10.0)
	var ahead := data.road_frame(50.0, 10.0)
	assert_almost_eq(absf(left.x), 10.0, 0.01)
	assert_almost_eq(left.x, -right.x, 0.01, "the two sides have opposite signs")
	assert_almost_eq(right.y, 3.0, 0.01)
	assert_almost_eq(ahead.z - right.z, 50.0, 0.5, "metres along grow with the road")
	assert_eq(data.road_frame(0.0, 500.0).x, INF, "no road in reach")


func test_the_car_starts_on_the_first_node_facing_the_second() -> void:
	var pose := _built(_level()).spawn_pose()
	assert_almost_eq(pose.origin.x, -100.0, 0.01)
	assert_gt(-pose.basis.z.x, 0.99, "forward (-Z) points along the road")


func test_recovery_puts_the_car_on_the_nearest_road_facing_along_it() -> void:
	var pose := _built(_level()).road_pose(Vector2(30.0, 40.0), Vector3(-1.0, 0.0, 0.2))
	assert_almost_eq(pose.origin.x, 30.0, 0.5)
	assert_almost_eq(pose.origin.z, 0.0, 0.5, "on the road, not where the car was")
	assert_lt(-pose.basis.z.x, -0.99, "the road direction nearest the car's own facing")


func test_a_tarmac_node_paves_the_road_and_blends_to_gravel_between_nodes() -> void:
	var paved := _node(-100.0, 0.0)
	paved["tarmac"] = true
	var data := _built({"road": [paved, _node(0.0, 0.0), _node(100.0, 0.0)], "heightmap": _level()["heightmap"]})
	assert_almost_eq(data.surface_at(-99.0, 0.0).y, 1.0, 0.03, "tarmac at the paved node")
	var mid := data.surface_at(-50.0, 0.0).y
	assert_true(mid > 0.1 and mid < 0.9, "partly paved between the paved and gravel nodes: %s" % mid)
	assert_eq(data.surface_at(50.0, 0.0).y, 0.0, "gravel past it")
	assert_lt(data.surface_at(-99.0, 40.0).y, 0.01, "no tarmac off the road")


func _square(x: float, z: float, half: float) -> Array:
	return [{"x": x - half, "z": z - half}, {"x": x + half, "z": z - half}, {"x": x + half, "z": z + half}, {"x": x - half, "z": z + half}]


# A road climbing along x, so a patch on it has to pick one level.
func _slope_with_patches() -> Dictionary:
	var hm: Array = []
	for r in 201:
		for c in 201:
			hm.append(c * 0.3)
	return {"road": [_node(-100.0, 0.0), _node(100.0, 0.0)], "heightmap": hm,
		"gravelPatches": [_square(0.0, 0.0, 8.0), _square(-150.0, 150.0, 6.0)]}


func test_a_gravel_patch_is_level_and_meets_its_road() -> void:
	var data := _built(_slope_with_patches())
	var h := data.ground(0.0, 0.0)
	for p in [Vector2(-7.0, -7.0), Vector2(7.0, 5.0), Vector2(3.0, 6.5), Vector2(-6.0, 7.0)]:
		assert_almost_eq(data.ground(p.x, p.y), h, 0.001, "level across the patch at %s" % p)
	var i := data.nearest_sample(0.0, 0.0)
	assert_almost_eq(data.sh[i] - 0.05, h, 0.001, "the road inside the patch is at the patch's level")
	assert_almost_eq(data.ground(0.0, 40.0), data.natural(0.0, 40.0), 0.001, "the ground well away is untouched")


func test_two_patches_on_one_road_climb_no_steeper_between_them_than_the_road_did() -> void:
	var lv := _slope_with_patches()
	lv["gravelPatches"] = [_square(-30.0, 0.0, 8.0), _square(30.0, 0.0, 8.0)]
	var data := _built(lv)
	var a := data.nearest_sample(-22.5, 0.0)
	var b := data.nearest_sample(22.5, 0.0)
	var road_climb := absf(data.natural(22.0, 0.0) - data.natural(-22.0, 0.0))
	assert_lt(absf(data.sh[b] - data.sh[a]), road_climb + 0.1, "the pads meet the road's own climb, not their full height apart")
	assert_almost_eq(data.ground(-36.0, 5.0), data.ground(-24.0, -5.0), 0.001, "each pad stays level")


func test_a_patch_pulls_every_road_at_a_nearby_junction_alike() -> void:
	var lv := _slope_with_patches()
	lv.erase("road")
	lv["roads"] = [[_node(-100.0, 0.0), _node(0.0, 0.0)], [_node(0.0, 0.0), _node(60.0, 0.0)], [_node(0.0, 0.0), _node(0.0, 80.0)]]
	lv["gravelPatches"] = [_square(20.0, 0.0, 8.0)]
	var data := _built(lv)
	var hs: Array[float] = []
	for c in 3:
		var best := INF
		var h := 0.0
		for i in data.sx.size():
			var d := Vector2(data.sx[i], data.sz[i]).length()
			if data.sc[i] == c and d < best:
				best = d
				h = data.sh[i]
		hs.append(h)
	assert_almost_eq(hs[0], hs[1], 0.05, "the road into the patch and the one carrying on meet level")
	assert_almost_eq(hs[2], hs[1], 0.05, "the side road meets them level too")


func test_a_patch_away_from_roads_is_level_and_counts_as_road() -> void:
	var data := _built(_slope_with_patches())
	assert_almost_eq(data.ground(-155.0, 145.0), data.ground(-145.0, 155.0), 0.001, "level although the hill climbs across it")
	assert_gt(data.surface_at(-150.0, 150.0).x, 0.99, "drives as road")
	assert_eq(data.surface_at(-150.0, 150.0).y, 0.0, "gravel, not tarmac")
	assert_lt(data.surface_at(-150.0, 170.0).x, 0.01, "grass past its edge")


func test_polygon_distance_is_negative_inside_and_metres_to_the_edge() -> void:
	var sq := LevelData.parse_patches([_square(0.0, 0.0, 5.0)])[0]
	assert_almost_eq(LevelData.polygon_distance(sq, 0.0, 0.0), -5.0, 1e-4)
	assert_almost_eq(LevelData.polygon_distance(sq, 8.0, 0.0), 3.0, 1e-4)
	assert_almost_eq(LevelData.polygon_distance(sq, 8.0, 9.0), 5.0, 1e-4, "to the corner")


func test_a_legacy_single_road_still_loads_as_one_chain() -> void:
	var data := _built(_level())
	assert_gt(data.surface_at(0.0, 0.0).x, 0.9)
	assert_eq(data.junctions.size(), 0)
	assert_eq(Array(data.sc).max(), 0)


func test_several_chains_load_and_no_segment_spans_two() -> void:
	var data := _built(_network())
	assert_eq(Array(data.sc).max(), 2, "three chains")
	for key in data.buckets:
		for i: int in data.buckets[key]:
			assert_eq(data.sc[i], data.sc[i + 1], "segment %d stays inside one chain" % i)
	assert_gt(data.surface_at(0.0, 30.0).x, 0.9, "on the side road")
	assert_gt(data.surface_at(50.0, 200.0).x, 0.9, "on the far road")
	assert_lt(data.surface_at(50.0, 100.0).x, 0.01, "between roads")


func test_a_chain_end_touching_a_node_or_another_end_is_a_junction() -> void:
	var t := _built(_network())
	assert_eq(t.junctions.size(), 1, "the T")
	assert_almost_eq(t.junctions[0].z, 3.0, 1e-4, "half-width is the widest clustered node")
	assert_lt(Vector2(t.junctions[0].x, t.junctions[0].y).length(), 0.75)
	var y := _built({"roads": [[_node(0.0, 0.0), _node(50.0, 0.0)], [_node(0.5, 0.0), _node(0.0, 50.0)],
		[_node(-0.2, 0.3), _node(-50.0, 0.0)]]})
	assert_eq(y.junctions.size(), 1, "three ends meeting make one junction")
	var apart := _built({"roads": [[_node(0.0, 0.0), _node(50.0, 0.0)], [_node(0.0, 2.0), _node(0.0, 50.0)]]})
	assert_eq(apart.junctions.size(), 0, "2 m apart is no junction")


func test_the_junction_weight_is_one_at_the_centre_and_zero_away() -> void:
	var data := _built(_network())
	assert_almost_eq(data.road_frame(0.0, 0.0).w, 1.0, 0.01)
	assert_eq(data.road_frame(60.0, 0.0).w, 0.0)


func test_the_nearest_point_picks_the_chain_it_is_closest_to() -> void:
	var data := _built(_network())
	assert_eq(data.sc[data.nearest_sample(1.0, 40.0)], 1)
	assert_eq(data.sc[data.nearest_sample(0.0, 190.0)], 2)
	var pose := data.road_pose(Vector2(20.0, 45.0), Vector3(0.0, 0.0, 1.0))
	assert_almost_eq(pose.origin.x, 0.0, 0.5, "recovery lands on the side road")
	assert_gt(-pose.basis.z.z, 0.9, "facing the way asked, along that road")


func test_the_spawn_is_the_first_chains_first_node() -> void:
	var pose := _built(_network()).spawn_pose()
	assert_almost_eq(pose.origin.x, -100.0, 0.01)
	assert_gt(-pose.basis.z.x, 0.99)


func test_a_junction_sits_between_its_roads_levels_not_on_the_bare_ground() -> void:
	var hm: Array = []
	for r in 201:
		for c in 201:
			hm.append(float(r) * 0.5)  # the ground climbs along +z, so the branch ending at the T climbs away from it
	var level := _network()
	level["heightmap"] = hm
	var data := _built(level)
	var main_road := data.ground(-60.0, 0.0)
	var at_junction := data.ground(0.0, 0.0)
	assert_gt(at_junction, data.natural(0.0, 0.0) + 0.5, "lifted towards the climbing branch's level")
	assert_gt(at_junction, main_road + 0.5)


# Shared with the lab's own check (tests/headless/lab_parity.js): the same save must give the same road and ground.
func test_the_road_and_ground_match_the_lab_fixture() -> void:
	var fx: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/headless/fixtures/level_parity.json"))
	var data := LevelData.new()
	data.load_save(fx["save"])
	data.flat_margin = fx["flat_margin"]
	var want: Dictionary = fx["expected"]
	assert_eq(data.sx.size(), int(want["sample_count"]), "same number of road samples")
	for row: Array in want["samples"]:
		var i := int(row[0])
		assert_almost_eq(data.sx[i], float(row[1]), 0.01, "sample %d x" % i)
		assert_almost_eq(data.sz[i], float(row[2]), 0.01, "sample %d z" % i)
		assert_almost_eq(data.sw[i], float(row[3]), 0.01, "sample %d half-width" % i)
		assert_almost_eq(data.sh[i], float(row[4]), 0.01, "sample %d height" % i)
		assert_almost_eq(data.st[i], float(row[5]), 0.01, "sample %d tarmac" % i)
	assert_eq(data.junctions.size(), want["junctions"].size())
	for k in data.junctions.size():
		var j: Array = want["junctions"][k]
		assert_almost_eq(data.junctions[k].x, float(j[0]), 0.01)
		assert_almost_eq(data.junctions[k].y, float(j[1]), 0.01)
		assert_almost_eq(data.junctions[k].z, float(j[2]), 0.01)
	for row: Array in want["heights"]:
		assert_almost_eq(data.ground(float(row[0]), float(row[1])), float(row[2]), 0.01, "ground at %s, %s" % [row[0], row[1]])


func test_a_side_road_into_a_dead_end_faces_back_toward_its_junction() -> void:
	var data := _built(_network())
	var f := data.away_from_dead_end(Vector2(1.0, 30.0), Vector3(0.0, 0.0, 1.0))
	assert_lt(f.normalized().z, -0.99, "turned away from the dead end at z = 60")
	assert_lt(data.away_from_dead_end(Vector2(1.0, 30.0), Vector3(0.0, 0.0, -1.0)).normalized().z, -0.99, "already facing out stays so")
	assert_eq(data.away_from_dead_end(Vector2(0.0, 201.0), Vector3(1.0, 0.0, 0.0)), Vector3(1.0, 0.0, 0.0), "a road dead at both ends keeps the facing")
