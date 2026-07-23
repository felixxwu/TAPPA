extends GutTest
# The catalogue seam (CarLibrary/EngineLibrary override_for_test/reset/all) lets
# tests swap in a synthetic catalogue. These cases prove the seam mechanics only.

func after_each() -> void:
	CarLibrary.reset()
	EngineLibrary.reset()
	RallyLibrary.reset()
	UpgradeLibrary.reset()
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


# --- Rally / Upgrade / Region seams (same Registry.Seam mechanics) ------------

func _fake_rallies() -> Array[Dictionary]:
	return [
		{"id": "seam_r", "name": "Seam Rally", "region": "home", "showdown": false,
		 "restriction": {}, "events": [{"seed": 1, "turn_count": 3}]},
	] as Array[Dictionary]

func test_rally_override_replaces_the_active_catalogue() -> void:
	RallyLibrary.override_for_test(_fake_rallies())
	assert_eq(RallyLibrary.all().size(), 1, "all() returns the override")
	assert_eq(RallyLibrary.index_of("seam_r"), 0, "index_of resolves against the override")
	assert_eq(RallyLibrary.by_id("seam_r")["name"], "Seam Rally", "by_id resolves against the override")

func test_rally_reset_restores_the_real_catalogue() -> void:
	var real_size := RallyLibrary.RALLIES.size()
	RallyLibrary.override_for_test(_fake_rallies())
	RallyLibrary.reset()
	assert_eq(RallyLibrary.all().size(), real_size, "reset restores the real RALLIES")
	assert_eq(RallyLibrary.index_of("seam_r"), -1, "override id no longer resolves after reset")

func test_rally_empty_override_falls_back_to_real() -> void:
	RallyLibrary.override_for_test([] as Array[Dictionary])
	assert_eq(RallyLibrary.all().size(), RallyLibrary.RALLIES.size(), "an empty override means no override")

func _fake_upgrades() -> Array[Dictionary]:
	return [
		{"id": "seam_u", "name": "Seam Upgrade", "slot": "turbo", "tier": 1,
		 "consumable": false, "effect": {"mass_mult": 0.9}},
	] as Array[Dictionary]

func test_upgrade_override_replaces_the_active_catalogue() -> void:
	UpgradeLibrary.override_for_test(_fake_upgrades())
	assert_eq(UpgradeLibrary.all().size(), 1, "all() returns the override")
	assert_eq(UpgradeLibrary.by_id("seam_u")["name"], "Seam Upgrade", "by_id resolves against the override")

func test_upgrade_reset_restores_the_real_catalogue() -> void:
	var real_size := UpgradeLibrary.UPGRADES.size()
	UpgradeLibrary.override_for_test(_fake_upgrades())
	UpgradeLibrary.reset()
	assert_eq(UpgradeLibrary.all().size(), real_size, "reset restores the real UPGRADES")
	assert_eq(UpgradeLibrary.by_id("seam_u"), {}, "override id no longer resolves after reset")

func test_upgrade_empty_override_falls_back_to_real() -> void:
	UpgradeLibrary.override_for_test([] as Array[Dictionary])
	assert_eq(UpgradeLibrary.all().size(), UpgradeLibrary.UPGRADES.size(), "an empty override means no override")

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
