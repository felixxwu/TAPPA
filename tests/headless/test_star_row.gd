extends GutTest
# StarRow: the design-system five-pointed-star readout (scripts/star_row.gd) that
# replaced the 3D sphere "stars" on the HQ map pins. Pure widget logic — sizing and
# the star polygon — so it's checked without rendering.


func test_setup_lights_the_earned_count_and_sizes_to_fit() -> void:
	var row := StarRow.new()
	autofree(row)
	row.setup(2, 3)
	assert_eq(row.earned, 2, "earned reflects the lit count")
	assert_eq(row.total, 3, "total reflects how many stars are drawn")
	# Wide enough for three stars + two gaps, tall enough for one star.
	var expected_w := 3 * row.star_radius * 2.0 + 2 * row.gap
	assert_almost_eq(row.custom_minimum_size.x, expected_w, 0.01, "row sizes to fit all stars + gaps")
	assert_almost_eq(row.custom_minimum_size.y, row.star_radius * 2.0, 0.01, "row is one star tall")


func test_zero_stars_has_no_gap_padding() -> void:
	var row := StarRow.new()
	autofree(row)
	row.setup(0, 1)  # a single star: no inter-star gaps
	assert_almost_eq(row.custom_minimum_size.x, row.star_radius * 2.0, 0.01,
		"a single star adds no gap width")


func test_star_polygon_has_ten_alternating_vertices() -> void:
	var row := StarRow.new()
	autofree(row)
	var pts := row._star_points(Vector2.ZERO, 10.0, 4.0)
	assert_eq(pts.size(), StarRow.POINTS * 2, "a five-pointed star has 10 perimeter vertices")
	# Even vertices sit on the outer radius, odd on the inner — that alternation is
	# what makes it read as a star rather than a decagon.
	assert_almost_eq(pts[0].length(), 10.0, 0.01, "first vertex is an outer point")
	assert_almost_eq(pts[1].length(), 4.0, 0.01, "second vertex is an inner point")
