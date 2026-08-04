extends GutTest
# The EngineSwap pure module: engine resolution, name/label formatting, the
# mass + weight-distribution math, and the swap eligibility guard. All pure —
# no scene, no save file. Values are INJECTED (not read from the authored
# tables) so no tunable number is pinned. See features/engine-swap.md.

const CarFixtures = preload("res://tests/headless/car_fixtures.gd")


func before_each() -> void:
	CarFixtures.install()


func after_each() -> void:
	CarFixtures.restore()


func test_current_engine_id_prefers_swap_then_stock() -> void:
	assert_eq(EngineSwap.current_engine_id({}, "stock_i4"), "stock_i4", "no swap -> stock")
	assert_eq(EngineSwap.current_engine_id({"swapped_engine": ""}, "stock_i4"), "stock_i4", "empty swap -> stock")
	assert_eq(EngineSwap.current_engine_id({"swapped_engine": "ford_50_v8"}, "stock_i4"), "ford_50_v8", "swap wins")


func test_layout_label_from_uppercases_and_strips_qualifier() -> void:
	# The RULE, exercised on layout strings supplied here — no catalogue lookup.
	assert_eq(EngineSwap.layout_label_from("v8"), "V8", "plain layout -> uppercased")
	assert_eq(EngineSwap.layout_label_from("v12_uneven"), "V12",
		"qualifier suffix after the first _ is dropped")
	assert_eq(EngineSwap.layout_label_from("w16_quad_turbo"), "W16",
		"only the leading token survives, however many qualifiers follow")
	assert_eq(EngineSwap.layout_label_from(""), "", "empty layout -> empty label")


func test_every_firing_layout_yields_a_clean_label() -> void:
	# Contract of the formatter over the whole FIRING table as opaque input: a
	# displayed label never leaks an internal key's underscore or lowercasing.
	for layout: String in EngineLibrary.FIRING:
		var label := EngineSwap.layout_label_from(layout)
		assert_false(label.is_empty(), "%s -> non-empty label" % layout)
		assert_false(label.contains("_"), "%s -> label has no underscore (got %s)" % [layout, label])
		assert_eq(label, label.to_upper(), "%s -> label is upper-case (got %s)" % [layout, label])


func test_layout_label_resolves_the_engine_then_formats() -> void:
	# layout_label reads the layout off whatever EngineLibrary returns for the id;
	# the fixture roster supplies the entries so no shipped engine is pinned.
	for engine: Dictionary in EngineLibrary.all():
		assert_eq(EngineSwap.layout_label(String(engine.get("id", ""))),
			EngineSwap.layout_label_from(String(engine.get("layout", ""))),
			"label matches the formatter applied to the entry's own layout")
	assert_eq(EngineSwap.layout_label("does_not_exist"), "", "unknown -> empty")


func test_display_name_prefixes_layout_only_when_swapped() -> void:
	# display_name resolves the swapped engine's layout via EngineLibrary by id,
	# so it needs a real engine id to resolve — restore the real catalogue for this test.
	CarFixtures.restore()
	var entry := {"name": "Twingo", "engine": "renault_12_i4"}
	assert_eq(EngineSwap.display_name(entry, {}), "Twingo", "stock -> plain name")
	var swapped := {"swapped_engine": "mopar_440_v8"}
	assert_eq(EngineSwap.display_name(entry, swapped), "V8 Twingo", "swapped -> layout prefix")


func test_recompute_mass_swaps_the_engine_component() -> void:
	# M' = M - m0 + m1
	assert_almost_eq(EngineSwap.recompute_mass(1000.0, 120.0, 220.0), 1100.0, 0.0001, "heavier engine adds mass")
	assert_almost_eq(EngineSwap.recompute_mass(1000.0, 120.0, 120.0), 1000.0, 0.0001, "same mass -> unchanged")
	assert_almost_eq(EngineSwap.recompute_mass(1000.0, 200.0, 100.0), 900.0, 0.0001, "lighter engine drops mass")


func test_recompute_weight_front_moves_cog_by_engine_position() -> void:
	# Rear-engine car (EF below WF): a LIGHTER engine pulls WF up toward the middle.
	# M=1000, WF=0.40, stock engine 200kg at EF=0.10, new engine 100kg.
	var wf_lighter := EngineSwap.recompute_weight_front(1000.0, 0.40, 200.0, 100.0, 0.10)
	assert_gt(wf_lighter, 0.40, "lighter rear engine raises front fraction toward the middle")
	# A HEAVIER rear engine pushes WF further back (down).
	var wf_heavier := EngineSwap.recompute_weight_front(1000.0, 0.40, 200.0, 300.0, 0.10)
	assert_lt(wf_heavier, 0.40, "heavier rear engine lowers front fraction")
	# When the engine sits exactly at the car's weight_front, only mass changes.
	var wf_neutral := EngineSwap.recompute_weight_front(1000.0, 0.40, 200.0, 100.0, 0.40)
	assert_almost_eq(wf_neutral, 0.40, 0.0001, "engine_pos == weight_front -> distribution unchanged")


func test_can_swap_requires_two_real_cars_regardless_of_health() -> void:
	# Health is no longer a factor — swapping costs a token (Save spends it), so
	# can_swap only checks that both cars actually exist. hp values are injected.
	var full := {"model_id": "fx_light_rwd", "hp": 800.0}
	var hurt := {"model_id": "fx_light_rwd", "hp": 1.0}
	assert_true(EngineSwap.can_swap(full, hurt), "a damaged car no longer blocks a swap")
	assert_true(EngineSwap.can_swap(full, full), "two real cars -> allowed")
	assert_false(EngineSwap.can_swap(full, {}), "an empty car -> blocked")
	assert_false(EngineSwap.can_swap({}, full), "an empty car -> blocked (either side)")


func test_pw_after_swap_stronger_donor_raises_pw() -> void:
	var entry := CarLibrary.by_id("fx_light_rwd")
	var owned := {"model_id": "fx_light_rwd"}
	var current := CarLibrary.power_to_weight(entry)          # running stock fx_i4
	var swapped_v8 := EngineSwap.pw_after_swap(owned, entry, "fx_v8")
	assert_gt(swapped_v8, current, "receiving the stronger V8 raises p/w")


func test_pw_after_swap_weaker_donor_lowers_pw() -> void:
	var entry := CarLibrary.by_id("fx_rwd_coupe")            # runs fx_v8 stock (heavy/strong)
	var owned := {"model_id": "fx_rwd_coupe"}
	var current := CarLibrary.power_to_weight(entry)
	var swapped_i4 := EngineSwap.pw_after_swap(owned, entry, "fx_i4")
	assert_lt(swapped_i4, current, "receiving the weaker i4 lowers p/w")


func test_pw_after_swap_same_engine_is_noop() -> void:
	var entry := CarLibrary.by_id("fx_light_rwd")            # stock fx_i4
	var owned := {"model_id": "fx_light_rwd"}
	var current := CarLibrary.power_to_weight(entry)
	var same := EngineSwap.pw_after_swap(owned, entry, "fx_i4")
	assert_almost_eq(same, current, 0.0001, "receiving your own engine leaves p/w unchanged")
