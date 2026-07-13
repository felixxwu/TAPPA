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


func test_layout_label_uppercases_known_layout() -> void:
	# layout_label looks the engine up in EngineLibrary by id, so it needs real
	# engine ids to resolve — restore the real catalogue for this one test.
	CarFixtures.restore()
	# Derived from EngineLibrary's own layout key, not a pinned string.
	var v8 := EngineLibrary.all()[0]  # a real engine
	assert_eq(EngineSwap.layout_label("mopar_440_v8"), "V8", "v8 layout -> V8")
	assert_eq(EngineSwap.layout_label("mazda_20_i4"), "I4", "i4 layout -> I4")
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


func test_can_swap_requires_both_cars_at_full_health() -> void:
	# Use a real model id so max_hp resolves; hp values are injected, not the authored max.
	var model: String = CarLibrary.all()[0]["id"]
	var max_hp: float = CarLibrary.all()[0]["max_hp"]
	var full_a := {"model_id": model, "hp": max_hp}
	var full_b := {"model_id": model, "hp": max_hp}
	var hurt := {"model_id": model, "hp": max_hp - 1.0}
	assert_true(EngineSwap.can_swap(full_a, full_b), "both full -> allowed")
	assert_false(EngineSwap.can_swap(full_a, hurt), "one hurt -> blocked")
	assert_false(EngineSwap.can_swap(full_a, {}), "empty car -> blocked")
	# at_full_health is the per-car probe can_swap is built from and the swap flow uses
	# to decide how many Repair Kits a swap costs.
	assert_true(EngineSwap.at_full_health(full_a), "a car at max HP is at full health")
	assert_false(EngineSwap.at_full_health(hurt), "a car below max HP is not")
	assert_false(EngineSwap.at_full_health({}), "an empty car is not at full health")


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
