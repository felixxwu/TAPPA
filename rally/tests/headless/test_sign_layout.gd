extends GutTest
# SignLayout: a pure planner (no scene) that turns a generated track
# (centerline + pieces) into roadside-sign placements (todo/roadside-signs.md §2).
# Sectors, turn arrows, and start/finish gates — each a pair, one per road edge.

const TrackGenerator = preload("res://scripts/track_generator.gd")
const SignLayout = preload("res://scripts/sign_layout.gd")

const START_POS := Vector2(0.0, 0.0)
const START_HEADING := Vector2(0.0, 1.0)


func _generate(seed_value: int, turns: int = 10, width: float = 6.0) -> Dictionary:
	return TrackGenerator.generate(START_POS, START_HEADING, seed_value, turns, width)


func _plan(result: Dictionary, sector_count: int = 4) -> Array:
	return SignLayout.plan(result["centerline"], result["pieces"], {"sector_count": sector_count})


func _of_kind(layout: Array, kind: String) -> Array:
	var out: Array = []
	for s in layout:
		if s["kind"] == kind:
			out.append(s)
	return out


func test_finish_is_one_pair_and_no_start_boards() -> void:
	var r := _generate(3)
	var layout := _plan(r)
	# The start is now marked by the inflatable start arch, not A-frame boards.
	assert_eq(_of_kind(layout, "start").size(), 0, "no A-frame start boards planted")
	var finishes := _of_kind(layout, "finish")
	assert_eq(finishes.size(), 2, "finish gate is a pair (both sides)")
	# One per side.
	assert_eq(finishes[0]["side"] + finishes[1]["side"], 0, "finish signs are on opposite sides")
	assert_eq(String(finishes[0]["texture_key"]), "finish", "finish texture key")
	# Finish sits at the far end of the curve.
	var curve: Curve2D = r["centerline"]
	assert_almost_eq(finishes[0]["pos"], curve.sample_baked(curve.get_baked_length()),
		Vector2(1e-3, 1e-3), "finish gate at offset L")


func test_sector_signs_mark_entries_2_to_n() -> void:
	var r := _generate(3)
	var curve: Curve2D = r["centerline"]
	var length := curve.get_baked_length()
	var count := 4
	var sectors := _of_kind(_plan(r, count), "sector")
	# count-1 boundaries, a pair each.
	assert_eq(sectors.size(), (count - 1) * 2, "%d boundaries, two signs each" % (count - 1))
	# Labels sector_2..sector_count, each appearing twice, at the expected offsets.
	for k in range(1, count):
		var expected_offset := k * length / float(count)
		var key := "sector_%d" % (k + 1)
		var matching: Array = []
		for s in sectors:
			if String(s["texture_key"]) == key:
				matching.append(s)
		assert_eq(matching.size(), 2, "%s is a pair" % key)
		var off := curve.get_closest_offset(matching[0]["pos"])
		assert_almost_eq(off, expected_offset, length * 0.02,
			"%s sits at ~k*L/count" % key)
	# Sector 1 is never signed (the start gate covers it).
	for s in sectors:
		assert_ne(String(s["texture_key"]), "sector_1", "sector 1 is not signed")


func test_turn_signs_only_for_sharp_corners_with_correct_keys() -> void:
	var r := _generate(7, 12)
	var turns := _of_kind(_plan(r), "turn")
	# Count the sharp turns in the generated track ourselves.
	var sharp := 0
	for piece in r["pieces"]:
		if SignLayout.TURN_CORNERS.has(String(piece["corner"])):
			sharp += 1
	assert_gt(sharp, 0, "the generated track has at least one sharp turn to sign")
	assert_eq(turns.size(), sharp * 2, "a sign pair per sharp turn, none for gentle/straight")
	# Every turn key is a known arrow shape, and left/right matches some piece flip.
	var valid_keys := {
		"arrow_curve_left": true, "arrow_curve_right": true,
		"arrow_square_left": true, "arrow_square_right": true,
		"arrow_uturn_left": true, "arrow_uturn_right": true,
	}
	for s in turns:
		assert_true(valid_keys.has(String(s["texture_key"])),
			"turn key %s is a known arrow" % s["texture_key"])


func test_arrow_key_maps_shape_and_direction() -> void:
	assert_eq(SignLayout._arrow_key("1", false), "arrow_curve_right", "gradient 1, right")
	assert_eq(SignLayout._arrow_key("2", true), "arrow_curve_left", "gradient 2, left (flip)")
	assert_eq(SignLayout._arrow_key("Square", false), "arrow_square_right", "square, right")
	assert_eq(SignLayout._arrow_key("Hairpin", true), "arrow_uturn_left", "hairpin, left (flip)")


func test_tangents_are_unit_length() -> void:
	for s in _plan(_generate(2)):
		assert_almost_eq(Vector2(s["tangent"]).length(), 1.0, 1e-3,
			"every placement carries a unit tangent")


func test_plan_is_deterministic() -> void:
	var r := _generate(5)
	var a := _plan(r)
	var b := _plan(r)
	assert_eq(a.size(), b.size(), "same track -> same sign count")
	for i in a.size():
		assert_eq(String(a[i]["texture_key"]), String(b[i]["texture_key"]),
			"placement %d identical" % i)
		assert_eq(int(a[i]["side"]), int(b[i]["side"]), "placement %d side identical" % i)


func test_sector_offsets_helper_matches_boundaries() -> void:
	var r := _generate(3)
	var curve: Curve2D = r["centerline"]
	var offsets := SignLayout.sector_offsets(curve, 4)
	assert_eq(offsets.size(), 3, "count-1 interior boundaries")
	assert_almost_eq(float(offsets[0]), curve.get_baked_length() / 4.0, 1e-3,
		"first boundary at L/4")
