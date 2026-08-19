extends GutTest
# tools/export_eligibility.gd's compute_source_hash() — the freshness guard for the
# committed data/eligibility.json (mirrors TrackCache.source_hash_of). Guards LOGIC only:
# the hash must move when an eligibility-relevant input changes, and must NOT move when an
# unrelated tunable is retuned. Never pins the hash's actual value (that would just be
# pinning a moving number) and never reaches into the real CarLibrary/RallyLibrary/
# EngineLibrary catalogues — everything here is a synthetic roster this test owns, per
# CLAUDE.md's testing rules.

const ExportEligibility = preload("res://tools/export_eligibility.gd")

func after_each() -> void:
	RallyLibrary.reset()
	CarLibrary.reset()
	EngineLibrary.reset()


func _install(rallies: Array[Dictionary], cars: Array[Dictionary], engines: Array[Dictionary]) -> void:
	RallyLibrary.override_for_test(rallies)
	CarLibrary.override_for_test(cars)
	EngineLibrary.override_for_test(engines)


func _engine(id: String, displacement_l: float, cylinder_layout: String) -> Dictionary:
	return {"id": id, "name": id, "layout": cylinder_layout, "displacement_l": displacement_l,
		"mass": 150.0, "redline_rpm": 6500.0, "peak_torque": 250.0, "peak_torque_rpm": 4000.0,
		"engine_inertia": 0.15, "gear_ratios": [3.0, 2.0, 1.4, 1.0, 0.8], "final_drive": 4.0,
		"shift_time": 0.3}


func _car(id: String, engine_id: String, drive_mode: int, country: String, car_type: String, doors: int, mass: float) -> Dictionary:
	return {"id": id, "name": id, "engine": engine_id, "drive_mode": drive_mode,
		"country": country, "car_type": car_type, "doors": doors, "mass": mass,
		"reward_tier": 1}


func _base_rally(id: String, restriction: Dictionary) -> Dictionary:
	return {"id": id, "restriction": restriction, "events": []}


func test_hash_changes_when_a_restriction_band_changes() -> void:
	var engines: Array[Dictionary] = [_engine("fx_i4", 2.0, "i4")]
	var cars: Array[Dictionary] = [_car("fx_a", "fx_i4", 0, "japan", "hatch", 3, 1100.0)]
	_install([_base_rally("r1", {"country": "japan"})], cars, engines)
	var before := ExportEligibility.compute_source_hash()

	_install([_base_rally("r1", {"country": "germany"})], cars, engines)
	var after := ExportEligibility.compute_source_hash()

	assert_ne(before, after, "changing a rally's restriction band changes the hash")


func test_hash_changes_when_a_rally_is_added() -> void:
	var engines: Array[Dictionary] = [_engine("fx_i4", 2.0, "i4")]
	var cars: Array[Dictionary] = [_car("fx_a", "fx_i4", 0, "japan", "hatch", 3, 1100.0)]
	_install([_base_rally("r1", {})], cars, engines)
	var before := ExportEligibility.compute_source_hash()

	_install([_base_rally("r1", {}), _base_rally("r2", {"car_type": "coupe"})], cars, engines)
	var after := ExportEligibility.compute_source_hash()

	assert_ne(before, after, "adding a rally changes the hash — this is the exact bug that let "
		+ "eligibility.json silently drift to 32 rallies while the roster grew to 38")


func test_hash_changes_when_a_categorical_car_field_changes() -> void:
	var engines: Array[Dictionary] = [_engine("fx_i4", 2.0, "i4")]
	var rallies: Array[Dictionary] = [_base_rally("r1", {"drive_mode": 0})]
	_install(rallies, [_car("fx_a", "fx_i4", 0, "japan", "hatch", 3, 1100.0)], engines)
	var before := ExportEligibility.compute_source_hash()

	# Drivetrain conversion: RWD -> AWD. This is exactly the kind of change that moves
	# which rallies a car can enter, so the hash must move too.
	_install(rallies, [_car("fx_a", "fx_i4", 1, "japan", "hatch", 3, 1100.0)], engines)
	var after := ExportEligibility.compute_source_hash()

	assert_ne(before, after, "changing a car's drivetrain changes the hash")


func test_hash_changes_when_engine_displacement_changes() -> void:
	var rallies: Array[Dictionary] = [_base_rally("r1", {"engine_min_l": 2.0})]
	var cars: Array[Dictionary] = [_car("fx_a", "fx_i4", 0, "japan", "hatch", 3, 1100.0)]
	_install(rallies, cars, [_engine("fx_i4", 2.0, "i4")])
	var before := ExportEligibility.compute_source_hash()

	# An engine swap that changes displacement can move a car across an engine_min_l /
	# cylinders band, so the hash must be sensitive to it.
	_install(rallies, cars, [_engine("fx_i4", 3.0, "i4")])
	var after := ExportEligibility.compute_source_hash()

	assert_ne(before, after, "changing an engine's displacement changes the hash")


func test_hash_stable_when_a_pure_tunable_changes() -> void:
	# Mass is not read by RallyLibrary.ineligibility_reason (entry is purely categorical —
	# see the comment above the performance-gate removal in rally_library.gd), so retuning
	# it must NOT churn the eligibility freshness guard. Per CLAUDE.md this test must not
	# assert on any specific mass value, only that changing it leaves the hash untouched.
	var engines: Array[Dictionary] = [_engine("fx_i4", 2.0, "i4")]
	var rallies: Array[Dictionary] = [_base_rally("r1", {"country": "japan"})]
	_install(rallies, [_car("fx_a", "fx_i4", 0, "japan", "hatch", 3, 1100.0)], engines)
	var before := ExportEligibility.compute_source_hash()

	_install(rallies, [_car("fx_a", "fx_i4", 0, "japan", "hatch", 3, 1500.0)], engines)
	var after := ExportEligibility.compute_source_hash()

	assert_eq(before, after, "retuning a car's mass must not change the eligibility hash")


func test_hash_deterministic_for_identical_inputs() -> void:
	var engines: Array[Dictionary] = [_engine("fx_i4", 2.0, "i4"), _engine("fx_v8", 5.0, "v8")]
	var cars: Array[Dictionary] = [
		_car("fx_a", "fx_i4", 0, "japan", "hatch", 3, 1100.0),
		_car("fx_b", "fx_v8", 1, "germany", "coupe", 2, 1400.0),
	]
	var rallies: Array[Dictionary] = [
		_base_rally("r1", {"country": "japan"}),
		_base_rally("r2", {"drive_mode": 1}),
	]
	_install(rallies, cars, engines)
	var a := ExportEligibility.compute_source_hash()
	var b := ExportEligibility.compute_source_hash()
	assert_eq(a, b, "same catalogue state -> same hash, called twice")
