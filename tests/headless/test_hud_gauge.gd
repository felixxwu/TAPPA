extends GutTest
# The vertical-strip gauge widget (HudGauge) and its glyphs (GaugeIcons) — see
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


# --- Glyphs ------------------------------------------------------------------

func test_every_gauge_kind_has_a_glyph() -> void:
	for kind: int in GaugeIcons.Kind.values():
		assert_not_null(GaugeIcons.texture(kind), "kind %d has a glyph" % kind)


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
