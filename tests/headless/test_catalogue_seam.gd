extends GutTest
# The catalogue seam (CarLibrary/EngineLibrary override_for_test/reset/all) lets
# tests swap in a synthetic catalogue. These cases prove the seam mechanics only.

func after_each() -> void:
	CarLibrary.reset()
	EngineLibrary.reset()
	RegionStageLibrary.reset()
	RegionLibrary.reset()

func _fake_cars() -> Array[Dictionary]:
	return [
		{"id": "seam_a", "name": "Seam A", "engine": "x", "mass": 1000.0},
		{"id": "seam_b", "name": "Seam B", "engine": "x", "mass": 1200.0},
	] as Array[Dictionary]

func test_car_override_replaces_the_active_catalogue() -> void:
	CarLibrary.override_for_test(_fake_cars())
	assert_eq(CarLibrary.all().size(), 2, "all() returns the override")
	assert_eq(CarLibrary.index_of("seam_b"), 1, "index_of resolves against the override")
	assert_eq(CarLibrary.by_id("seam_a")["name"], "Seam A", "by_id resolves against the override")

func test_car_reset_restores_the_real_catalogue() -> void:
	var real_size := CarLibrary.CARS.size()
	CarLibrary.override_for_test(_fake_cars())
	CarLibrary.reset()
	assert_eq(CarLibrary.all().size(), real_size, "reset restores the real CARS")
	assert_eq(CarLibrary.index_of("seam_a"), -1, "override id no longer resolves after reset")

func test_car_empty_override_falls_back_to_real() -> void:
	CarLibrary.override_for_test([] as Array[Dictionary])
	assert_eq(CarLibrary.all().size(), CarLibrary.CARS.size(), "an empty override means no override")

func _fake_engines() -> Array[Dictionary]:
	return [
		{"id": "seam_e", "name": "Seam Engine", "layout": "i4", "mass": 100.0,
		 "redline_rpm": 7000.0, "peak_torque": 200.0, "peak_torque_rpm": 4000.0},
	] as Array[Dictionary]

func test_engine_override_replaces_the_active_catalogue() -> void:
	EngineLibrary.override_for_test(_fake_engines())
	assert_eq(EngineLibrary.all().size(), 1, "all() returns the override")
	assert_eq(EngineLibrary.index_of("seam_e"), 0, "index_of resolves against the override")
	assert_eq(EngineLibrary.by_id("seam_e")["name"], "Seam Engine", "by_id resolves against the override")

func test_engine_reset_restores_the_real_catalogue() -> void:
	var real_size := EngineLibrary.ENGINES.size()
	EngineLibrary.override_for_test(_fake_engines())
	EngineLibrary.reset()
	assert_eq(EngineLibrary.all().size(), real_size, "reset restores the real ENGINES")
	assert_eq(EngineLibrary.index_of("seam_e"), -1, "override id no longer resolves after reset")


# --- RegionStageLibrary / Region seams -----------------------------------------
# RegionStageLibrary's seam is Dictionary-shaped ({region_id: [8 slots of 3
# candidates]}), not the flat Array[Dictionary] Registry.Seam roster the others use —
# see its own "Catalogue seam" comment — so its cases don't share index_of/by_id.

func _fake_region_stages() -> Dictionary:
	var slots: Array = []
	for i in 8:
		slots.append([{"seed": 1, "turn_count": 3}, {"seed": 2, "turn_count": 3},
			{"seed": 3, "turn_count": 3}])
	return {"seam_region": slots}

func test_region_stage_override_replaces_the_active_catalogue() -> void:
	RegionStageLibrary.override_for_test(_fake_region_stages())
	assert_eq(RegionStageLibrary.all().size(), 1, "all() returns the override")
	assert_eq(RegionStageLibrary.region_ids(), ["seam_region"], "region_ids resolves against the override")
	assert_eq(RegionStageLibrary.all_stages_in("seam_region").size(), 24, "8 slots x 3 candidates")

func test_region_stage_reset_restores_the_real_catalogue() -> void:
	var real_size := RegionStageLibrary.all().size()
	RegionStageLibrary.override_for_test(_fake_region_stages())
	RegionStageLibrary.reset()
	assert_eq(RegionStageLibrary.all().size(), real_size, "reset restores the real STAGES")
	assert_true(RegionStageLibrary.slots_in("seam_region").is_empty(), "override region no longer resolves after reset")

func test_region_stage_empty_override_falls_back_to_real() -> void:
	RegionStageLibrary.override_for_test({})
	assert_eq(RegionStageLibrary.all().size(), RegionStageLibrary.STAGES.size(), "an empty override means no override")

# NOTE: three tests covering the UpgradeLibrary registry override lived here. The upgrade
# CATALOGUE is deleted with the persistent parts model (todo/roguelike-pivot.md), so there
# is no upgrade table left to override. The seam itself is unchanged and still covered by
# the car / engine / rally / region cases in this file.


func _fake_regions() -> Array[Dictionary]:
	return [
		{"id": "seam_g", "name": "Seam Region", "spawn_bush_mesh": true},
	] as Array[Dictionary]

func test_region_override_replaces_the_active_catalogue() -> void:
	RegionLibrary.override_for_test(_fake_regions())
	assert_eq(RegionLibrary.all().size(), 1, "all() returns the override")
	assert_eq(RegionLibrary.by_id("seam_g")["name"], "Seam Region", "by_id resolves against the override")

func test_region_reset_restores_the_real_catalogue() -> void:
	var real_size := RegionLibrary.REGIONS.size()
	RegionLibrary.override_for_test(_fake_regions())
	RegionLibrary.reset()
	assert_eq(RegionLibrary.all().size(), real_size, "reset restores the real REGIONS")
	assert_eq(RegionLibrary.index_of("seam_g"), -1, "override id no longer resolves after reset")
