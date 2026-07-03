extends GutTest
# CarFixtures builds a synthetic catalogue tests can install instead of the real
# one. These cases prove the fixtures are valid, self-consistent, and installable.

func after_each() -> void:
	CarFixtures.restore()

func test_fixtures_install_swaps_both_catalogues() -> void:
	CarFixtures.install()
	assert_eq(CarLibrary.all().size(), 4, "four fixture cars are active")
	assert_eq(EngineLibrary.all().size(), 2, "two fixture engines are active")
	assert_eq(CarLibrary.by_id("fx_light_rwd")["name"], "Fixture Roadster", "car id resolves")

func test_fixture_cars_reference_fixture_engines() -> void:
	CarFixtures.install()
	for car in CarLibrary.all():
		assert_false(EngineLibrary.by_id(car["engine"]).is_empty(),
			"%s references a resolvable fixture engine" % car["id"])

func test_fixtures_cover_all_drive_modes() -> void:
	CarFixtures.install()
	var modes := {}
	for car in CarLibrary.all():
		modes[car["drive_mode"]] = true
	assert_true(modes.has(CarLibrary.RWD) and modes.has(CarLibrary.FWD) and modes.has(CarLibrary.AWD),
		"fixtures include RWD, FWD and AWD cars")

func test_restore_is_idempotent_without_install() -> void:
	CarFixtures.restore()  # never installed
	assert_eq(CarLibrary.all().size(), CarLibrary.CARS.size(), "restore with no install is a no-op")

func test_each_call_returns_a_fresh_copy() -> void:
	var a := CarFixtures.cars()
	a[0]["mass"] = -999.0
	assert_ne(CarFixtures.cars()[0]["mass"], -999.0, "mutating a returned copy can't corrupt the fixture")
