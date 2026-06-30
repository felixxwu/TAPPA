extends GutTest
# The corner shape library (CornerLibrary): every pacenote turn type is a set of
# hand-authored Curve2D control points (meters; entry at origin heading +Y).
# build_curve() must turn each entry into a usable Curve2D, names must be unique,
# and the full standard set (1-6, Square, Hairpin, Straight, one compound) present.


const EXPECTED := [
	"1", "2", "3", "4", "5", "6",
	"Square", "Hairpin", "Straight", "Right 4 tightens 2",
]


func test_library_has_the_expected_corners() -> void:
	var names := {}
	for spec in CornerLibrary.CORNERS:
		names[spec["name"]] = true
	assert_eq(names.size(), CornerLibrary.CORNERS.size(), "corner names are unique")
	for want in EXPECTED:
		assert_true(names.has(want), "library contains '%s'" % want)


func test_build_curve_produces_a_usable_curve_for_every_corner() -> void:
	for spec in CornerLibrary.CORNERS:
		var who: String = spec["name"]
		var curve := CornerLibrary.build_curve(spec)
		assert_true(curve is Curve2D, who + " builds a Curve2D")
		assert_gte(curve.point_count, 2, who + " has at least 2 points")
		# A non-degenerate shape: tessellated polyline has measurable length.
		var pts := curve.tessellate()
		var length := 0.0
		for i in range(1, pts.size()):
			length += pts[i].distance_to(pts[i - 1])
		assert_gt(length, 0.0, who + " has positive length")


func test_first_point_is_at_origin() -> void:
	# Every corner enters at the origin so they share a common anchor for layout.
	for spec in CornerLibrary.CORNERS:
		var curve := CornerLibrary.build_curve(spec)
		assert_almost_eq(curve.get_point_position(0), Vector2.ZERO, Vector2(0.001, 0.001),
			spec["name"] + " starts at the origin")


# Heading change (radians) from the tessellated polyline: angle between the
# initial tangent (first segment) and the final tangent (last segment).
func _heading_change(pts: PackedVector2Array) -> float:
	var start_dir := (pts[1] - pts[0]).normalized()
	var end_dir := (pts[pts.size() - 1] - pts[pts.size() - 2]).normalized()
	return abs(start_dir.angle_to(end_dir))


func _spec_by_name(want: String) -> Dictionary:
	for spec in CornerLibrary.CORNERS:
		if spec["name"] == want:
			return spec
	return {}


func test_documented_shape_semantics() -> void:
	# Lock in the *intended* shapes, not just well-formedness.
	# 1) All corners are right-hand turns: the curve ends at X >= 0 (turning
	#    toward +X; Straight ends at X == 0, which still satisfies >= 0).
	for spec in CornerLibrary.CORNERS:
		var who: String = spec["name"]
		var curve := CornerLibrary.build_curve(spec)
		var pts := curve.tessellate()
		var endpoint := pts[pts.size() - 1]
		assert_gte(endpoint.x, 0.0, who + " is a right-hand turn (ends at X >= 0)")

	# 2) Sharpness gradient: "1" is sharpest, "6" gentlest. Heading change from
	#    start to end must strictly decrease as the corner number increases.
	var prev_change := INF
	var prev_name := ""
	for n in ["1", "2", "3", "4", "5", "6"]:
		var spec := _spec_by_name(n)
		assert_false(spec.is_empty(), "gradient corner '%s' exists" % n)
		var pts := CornerLibrary.build_curve(spec).tessellate()
		var change := _heading_change(pts)
		if prev_name != "":
			assert_gt(prev_change, change,
				"corner '%s' (%.3f rad) turns more sharply than '%s' (%.3f rad)"
					% [prev_name, prev_change, n, change])
		prev_change = change
		prev_name = n


func test_catalog_scene_makes_one_label_per_corner() -> void:
	var scene: CornerCatalog = load("res://corner_catalog.tscn").instantiate()
	add_child_autofree(scene)
	await get_tree().process_frame  # let _ready() build the layout
	var labels := 0
	for child in scene.get_children():
		if child is Label:
			labels += 1
	assert_eq(labels, CornerLibrary.CORNERS.size(),
		"one name label per corner in the catalog")
	# Layout spreads corners across positive X (left-to-right row).
	assert_gt(scene.layout_width, 0.0, "catalog reports a positive laid-out width")
