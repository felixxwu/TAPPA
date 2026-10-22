extends GutTest
# The vertical-strip gauge widget (HudGauge) and its glyph geometry (GaugeIcons) — see
# features/hud.md. Pure logic, so this file builds NO scene: what each gauge reads and
# when it hides is exercised against main.tscn in test_hud.gd.


# --- Strip geometry --------------------------------------------------------------

func test_the_needle_sits_at_the_bottom_when_empty_and_the_top_when_full() -> void:
	assert_almost_eq(HudGauge.level_y(0.0, 10.0, 40.0), 50.0, 0.0001, "empty = bar bottom")
	assert_almost_eq(HudGauge.level_y(1.0, 10.0, 40.0), 10.0, 0.0001, "full = bar top")
	assert_almost_eq(HudGauge.level_y(0.5, 10.0, 40.0), 30.0, 0.0001, "half = halfway up")


func test_the_needle_never_leaves_the_bar() -> void:
	assert_almost_eq(HudGauge.level_y(-0.5, 10.0, 40.0), 50.0, 0.0001, "below empty clamps")
	assert_almost_eq(HudGauge.level_y(1.7, 10.0, 40.0), 10.0, 0.0001, "above full clamps")


func test_every_gauge_kind_has_its_own_name() -> void:
	var seen := {}
	for kind: int in GaugeIcons.Kind.values():
		var gauge_name: String = HudGauge.NAMES.get(kind, "")
		assert_ne(gauge_name, "", "kind %d has a name to run up its bar" % kind)
		assert_false(seen.has(gauge_name), "kind %d's name is unique" % kind)
		seen[gauge_name] = true


# --- Glyph geometry ------------------------------------------------------------

func test_every_glyph_triangulates_into_whole_triangles() -> void:
	for kind: int in [GaugeIcons.Kind.HEALTH, GaugeIcons.Kind.BOOST, GaugeIcons.Kind.NOS]:
		var tris := GaugeIcons.triangles(kind)
		assert_gt(tris.size(), 0, "glyph %d produced geometry" % kind)
		assert_eq(tris.size() % 3, 0, "glyph %d is whole triangles" % kind)


func test_every_glyph_stays_inside_the_authoring_grid() -> void:
	# The glyphs share one 24-unit square so they can be swapped into any gauge and land
	# at the same optical size. A vertex outside it would overflow the ring's hole.
	for kind: int in [GaugeIcons.Kind.HEALTH, GaugeIcons.Kind.BOOST, GaugeIcons.Kind.NOS]:
		for v: Vector2 in GaugeIcons.triangles(kind):
			assert_between(v.x, -0.001, GaugeIcons.GRID + 0.001, "glyph %d x in grid" % kind)
			assert_between(v.y, -0.001, GaugeIcons.GRID + 0.001, "glyph %d y in grid" % kind)


func test_the_glyphs_are_three_different_shapes() -> void:
	var health := GaugeIcons.triangles(GaugeIcons.Kind.HEALTH)
	var boost := GaugeIcons.triangles(GaugeIcons.Kind.BOOST)
	var nos := GaugeIcons.triangles(GaugeIcons.Kind.NOS)
	assert_ne(health, boost, "health and boost are distinct glyphs")
	assert_ne(boost, nos, "boost and NOS are distinct glyphs")
	assert_ne(health, nos, "health and NOS are distinct glyphs")


func test_the_health_glyph_is_actually_a_heart() -> void:
	# Two lobes up top with a notch between them, one point at the bottom. Assert the shape
	# rather than an area: that silhouette is what reads as a heart at any size.
	var c := GaugeIcons.GRID * 0.5
	assert_true(_covers(GaugeIcons.Kind.HEALTH, Vector2(c, c)), "filled at the centre")
	assert_true(_covers(GaugeIcons.Kind.HEALTH, Vector2(6.5, 3.0)), "the left lobe")
	assert_true(_covers(GaugeIcons.Kind.HEALTH, Vector2(17.5, 3.0)), "the right lobe")
	assert_false(_covers(GaugeIcons.Kind.HEALTH, Vector2(c, 1.0)), "the notch between the lobes")
	assert_true(_covers(GaugeIcons.Kind.HEALTH, Vector2(c, GaugeIcons.GRID - 1.5)), "the point at the bottom")
	for corner: Vector2 in [Vector2(1, 23), Vector2(23, 23), Vector2(1, 1), Vector2(23, 1)]:
		assert_false(_covers(GaugeIcons.Kind.HEALTH, corner), "corner %s stays empty" % corner)


func test_the_boost_glyph_is_a_dial_with_the_needle_cut_out() -> void:
	# The needle is NEGATIVE space, not a drawn line — the defining property of the glyph.
	# A point just off the 45° axis is dial; the same distance ON the axis is the slot.
	var centre := Vector2(GaugeIcons.GRID, GaugeIcons.GRID) * 0.5
	var axis := Vector2(1, -1).normalized()
	assert_true(_covers(GaugeIcons.Kind.BOOST, centre - axis * 6.0),
		"the dial is filled opposite the needle")
	assert_false(_covers(GaugeIcons.Kind.BOOST, centre + axis * 6.0),
		"the needle is cut out of the dial")
	# ...and the cut reaches the rim rather than stopping short inside it.
	assert_false(_covers(GaugeIcons.Kind.BOOST, centre + axis * 10.5),
		"the slot runs all the way out to the rim")


func test_the_boost_glyph_is_round_and_the_others_are_not() -> void:
	# The dial is the one curve in the set; a corner of the grid must be outside it.
	assert_false(_covers(GaugeIcons.Kind.BOOST, Vector2(1.0, 1.0)),
		"the dial does not reach the corners of its grid")


func test_the_nos_glyph_is_a_bottle_with_a_narrow_valve() -> void:
	# Wide body low down, narrow neck up top — that silhouette IS the read.
	assert_true(_covers(GaugeIcons.Kind.NOS, Vector2(12.0, 20.0)), "the body is filled")
	assert_true(_covers(GaugeIcons.Kind.NOS, Vector2(7.0, 20.0)), "the body is wide")
	assert_true(_covers(GaugeIcons.Kind.NOS, Vector2(12.0, 2.0)), "the valve is filled")
	assert_false(_covers(GaugeIcons.Kind.NOS, Vector2(7.0, 2.0)),
		"the valve is narrower than the body")
	assert_false(_covers(GaugeIcons.Kind.NOS, Vector2(1.0, 20.0)),
		"the bottle does not fill the whole grid")


# --- Widget wiring -------------------------------------------------------------

func test_a_gauge_ignores_input() -> void:
	# It's a readout sitting over the driving view: it must never take focus or swallow a
	# tap meant for the mobile controls underneath it.
	var gauge := HudGauge.new()
	assert_eq(gauge.mouse_filter, Control.MOUSE_FILTER_IGNORE, "clicks pass through")
	assert_eq(gauge.focus_mode, Control.FOCUS_NONE, "it never takes focus")
	gauge.free()


func test_value_round_trips_and_out_of_range_input_is_survivable() -> void:
	var gauge := HudGauge.new()
	gauge.value = 0.5
	assert_almost_eq(gauge.value, 0.5, 0.0001, "a set value reads back")
	# Out-of-range values are clamped at draw time, not on assignment, so a caller doing
	# arithmetic on the property doesn't silently lose data.
	gauge.value = 1.7
	assert_almost_eq(gauge.value, 1.7, 0.0001, "the property stores what it was given")
	gauge.free()


# --- helpers -------------------------------------------------------------------

# Is `p` inside the glyph? Walks the triangle soup that gets drawn, so it tests the
# geometry the HUD actually renders rather than the outlines it was built from.
func _covers(kind: int, p: Vector2) -> bool:
	var tris := GaugeIcons.triangles(kind)
	for i in range(0, tris.size() - 2, 3):
		if _in_triangle(p, tris[i], tris[i + 1], tris[i + 2]):
			return true
	return false


func _in_triangle(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> bool:
	var d1 := _cross(p, a, b)
	var d2 := _cross(p, b, c)
	var d3 := _cross(p, c, a)
	var has_neg: bool = d1 < 0.0 or d2 < 0.0 or d3 < 0.0
	var has_pos: bool = d1 > 0.0 or d2 > 0.0 or d3 > 0.0
	return not (has_neg and has_pos)


func _cross(p: Vector2, a: Vector2, b: Vector2) -> float:
	return (p.x - b.x) * (a.y - b.y) - (a.x - b.x) * (p.y - b.y)
