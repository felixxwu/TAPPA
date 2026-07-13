extends GutTest
# SignLayout: a pure planner (no scene) that turns a generated track
# (centerline + pieces) into roadside-sign placements (todo/roadside-signs.md §2).
# Sectors, turn arrows, and start/finish gates — each a pair, one per road edge.


const START_POS := Vector2(0.0, 0.0)
const START_HEADING := Vector2(0.0, 1.0)


func _generate(seed_value: int, turns: int = 10, width: float = 6.0) -> Dictionary:
	return await TrackGenerator.generate(START_POS, START_HEADING, seed_value, turns, width)


func _plan(result: Dictionary) -> Array:
	return SignLayout.plan(result["centerline"], result["pieces"])


func _of_kind(layout: Array, kind: String) -> Array:
	var out: Array = []
	for s in layout:
		if s["kind"] == kind:
			out.append(s)
	return out


func test_only_turn_signs_are_planted() -> void:
	# Start/finish are the inflatable arches and the stage is no longer split into
	# signed sectors, so turn arrows are the ONLY signs planted now.
	var r := await _generate(3)
	var layout := _plan(r)
	assert_gt(layout.size(), 0, "the track plants some turn signs")
	assert_eq(_of_kind(layout, "start").size(), 0, "no start boards")
	assert_eq(_of_kind(layout, "finish").size(), 0, "no finish boards (the arch covers it)")
	assert_eq(_of_kind(layout, "sector").size(), 0, "no sector boards")
	assert_eq(_of_kind(layout, "turn").size(), layout.size(), "every sign is a turn arrow")


func test_turn_signs_only_for_sharp_corners_with_correct_keys() -> void:
	var r := await _generate(7, 12)
	var turns := _of_kind(_plan(r), "turn")
	# Count the sharp turns in the generated track ourselves.
	var sharp := 0
	for piece in r["pieces"]:
		if SignLayout.TURN_CORNERS.has(String(piece["corner"])):
			sharp += 1
	assert_gt(sharp, 0, "the generated track has at least one sharp turn to sign")
	assert_eq(turns.size(), sharp * 2, "a sign pair per sharp turn, none for gentle/straight")
	# Every turn key is a known arrow shape, and left/right matches some piece flip.
	# Numbered gradients carry their grade (arrow_1/arrow_2/...) so each board shows
	# its own number; Square and Hairpin use their named glyph.
	var valid_keys := {
		"arrow_1_left": true, "arrow_1_right": true,
		"arrow_2_left": true, "arrow_2_right": true,
		"arrow_3_left": true, "arrow_3_right": true,
		"arrow_4_left": true, "arrow_4_right": true,
		"arrow_square_left": true, "arrow_square_right": true,
		"arrow_uturn_left": true, "arrow_uturn_right": true,
	}
	for s in turns:
		assert_true(valid_keys.has(String(s["texture_key"])),
			"turn key %s is a known arrow" % s["texture_key"])


func test_arrow_key_maps_shape_and_direction() -> void:
	# The facing panel mirrors the arrow, so the source variant is the OPPOSITE hand
	# of the corner: a right-hand corner (flip=false) uses the "left" art, which then
	# reads as a right turn on the sign (and vice-versa). Keeps the grade digit correct.
	assert_eq(SignLayout._arrow_key("1", false), "arrow_1_left", "right-hand corner uses mirror art")
	assert_eq(SignLayout._arrow_key("2", true), "arrow_2_right", "left-hand corner (flip) uses mirror art")
	assert_eq(SignLayout._arrow_key("3", false), "arrow_3_left", "right-hand corner uses mirror art")
	assert_eq(SignLayout._arrow_key("4", true), "arrow_4_right", "left-hand corner (flip) uses mirror art")
	assert_eq(SignLayout._arrow_key("Square", false), "arrow_square_left", "square, right-hand -> mirror art")
	assert_eq(SignLayout._arrow_key("Hairpin", true), "arrow_uturn_right", "hairpin, left-hand (flip) -> mirror art")


func test_gentle_corners_5_and_6_are_unsigned() -> void:
	# 5s and 6s are too straight to warrant a board.
	assert_false(SignLayout.TURN_CORNERS.has("5"), "gradient 5 is unsigned")
	assert_false(SignLayout.TURN_CORNERS.has("6"), "gradient 6 is unsigned")


func test_tangents_are_unit_length() -> void:
	for s in _plan(await _generate(2)):
		assert_almost_eq(Vector2(s["tangent"]).length(), 1.0, 1e-3,
			"every placement carries a unit tangent")


func test_plan_is_deterministic() -> void:
	var r := await _generate(5)
	var a := _plan(r)
	var b := _plan(r)
	assert_eq(a.size(), b.size(), "same track -> same sign count")
	for i in a.size():
		assert_eq(String(a[i]["texture_key"]), String(b[i]["texture_key"]),
			"placement %d identical" % i)
		assert_eq(int(a[i]["side"]), int(b[i]["side"]), "placement %d side identical" % i)


func test_sector_offsets_helper_matches_boundaries() -> void:
	var r := await _generate(3)
	var curve: Curve2D = r["centerline"]
	var offsets := SignLayout.sector_offsets(curve, 4)
	assert_eq(offsets.size(), 3, "count-1 interior boundaries")
	assert_almost_eq(float(offsets[0]), curve.get_baked_length() / 4.0, 1e-3,
		"first boundary at L/4")
