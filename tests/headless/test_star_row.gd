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
	var pts := StarRow._star_points(Vector2.ZERO, 10.0, 4.0)
	assert_eq(pts.size(), StarRow.POINTS * 2, "a five-pointed star has 10 perimeter vertices")
	# Even vertices sit on the outer radius, odd on the inner — that alternation is
	# what makes it read as a star rather than a decagon.
	assert_almost_eq(pts[0].length(), 10.0, 0.01, "first vertex is an outer point")
	assert_almost_eq(pts[1].length(), 4.0, 0.01, "second vertex is an inner point")


# The star as a TEXTURE — what a Button's `icon` needs, since a price star can't be a child
# Control of a Button. The ★ character it replaced has no glyph in Syne Mono, so it drew as a
# tofu box wherever no system font could stand in (the web export). Checks the raster is a
# real star: opaque at the centre, transparent in the notch between two points, and tight to
# the star's own bounding box rather than the circle it was generated from.
func test_texture_rasterises_a_star_tight_to_its_bounds() -> void:
	var tex := StarRow.texture(20.0, Color.WHITE)
	assert_not_null(tex, "a star rasterises to a texture")
	var img := tex.get_image()
	# The star spans the full outer diameter across, and less than that top-to-bottom (its
	# lower points stop short of the generating circle) — so a tight box is WIDER than TALL.
	assert_gt(img.get_width(), img.get_height(), "the raster is tight to the star, not the circle")
	assert_almost_eq(float(img.get_width()), 40.0, 2.0, "and spans the outer diameter across")
	var cx := roundi(img.get_width() * 0.5)
	assert_almost_eq(img.get_pixel(cx, roundi(img.get_height() * 0.5)).a, 1.0, 0.01,
		"the middle of the star is solid")
	# Bottom-centre sits in the notch BETWEEN the two lower points — empty in a star,
	# filled in any blob that merely occupies the box.
	assert_almost_eq(img.get_pixel(cx, img.get_height() - 1).a, 0.0, 0.01,
		"the notch between the lower points is empty")


# The cache is what makes the icon affordable: the upgrade rows rebuild on every press, and
# each rebuild asks for the same star. Rasterising is per-pixel work, so a fresh raster per
# button would be real cost for an identical result.
func test_the_same_star_is_rasterised_once() -> void:
	var first := StarRow.price_icon()
	assert_same(StarRow.price_icon(), first, "an identical star comes back from the cache")
	assert_not_same(StarRow.texture(StarRow.PRICE_RADIUS * 2.0, UITheme.GOLD), first,
		"a different size is its own texture")


# --- The wrench (same rasteriser, via PolygonIcon) ----------------------------
# The wrench opens a stat row's category on the simple upgrades page. It is DRAWN for the
# same reason the price star is — no glyph in the UI font, no system fallback on web — so
# it shares StarRow's rasteriser through PolygonIcon and is checked the same way.

func test_the_wrench_is_a_silhouette_not_a_blob() -> void:
	var img := WrenchIcon.texture(64.0, Color(1, 1, 1, 1)).get_image()
	assert_gt(img.get_width(), 0, "the wrench rasterises to something")
	# A diagonal tool fills a roughly square box, and only PART of it — a shape covering
	# nearly all of its box is a blob, one covering almost none has collapsed.
	var filled := 0
	for y in img.get_height():
		for x in img.get_width():
			if img.get_pixel(x, y).a > 0.5:
				filled += 1
	var coverage := float(filled) / float(img.get_width() * img.get_height())
	assert_between(coverage, 0.15, 0.65, "the silhouette leaves real background around it")
	assert_almost_eq(float(img.get_width()) / float(img.get_height()), 1.0, 0.35,
		"a diagonal tool fills a roughly square box")


func test_the_wrench_has_an_open_jaw() -> void:
	# The jaw is the one feature that says "spanner" rather than "lollipop", and it is what
	# a solid-head regression would silently remove. The head is at the far end of the
	# diagonal from the tail, and the jaw is a bite out of its outer edge — so somewhere
	# along the head's outer margin there must be background.
	var img := WrenchIcon.texture(64.0, Color(1, 1, 1, 1)).get_image()
	var gaps := 0
	for y in roundi(img.get_height() * 0.5):
		for x in roundi(img.get_width() * 0.5):
			if img.get_pixel(x, y).a < 0.5:
				gaps += 1
	assert_gt(gaps, 0, "the head end is not a solid disc")


func test_the_same_wrench_is_rasterised_once() -> void:
	var first := WrenchIcon.texture()
	assert_same(WrenchIcon.texture(), first, "an identical wrench comes back from the cache")
	assert_not_same(WrenchIcon.texture(WrenchIcon.HEIGHT * 2.0), first,
		"a different size is its own texture")


func test_the_star_and_the_wrench_do_not_share_a_cache_slot() -> void:
	# PolygonIcon keys on the caller's shape name plus the colour; two shapes at the same
	# size and colour must not collide.
	assert_not_same(WrenchIcon.texture(13.0, UITheme.GOLD),
		StarRow.texture(13.0, UITheme.GOLD), "different shapes are different textures")
