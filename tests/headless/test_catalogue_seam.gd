extends GutTest
# The catalogue seam (CarLibrary/EngineLibrary override_for_test/reset/all) lets
# tests swap in a synthetic catalogue. These cases prove the seam mechanics only.

func after_each() -> void:
	CarLibrary.reset()
	EngineLibrary.reset()

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
