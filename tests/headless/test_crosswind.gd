extends GutTest
# The storm crosswind profile (scripts/crosswind.gd).
#
# Relations, determinism and structure only — never a tuned value. A designer must be
# free to retune strength/gust/wavelength in game_config.tres without breaking any
# assertion here, so nothing pins a newton figure, a gust frequency or a strength.
# The DETERMINISM tests are the load-bearing ones: they guard leaderboard parity for
# every storm stage (two runs of a stage must meet the identical wind in the same
# place — see features/car-physics.md → "Crosswind").

const SEED_A := 12345
const SEED_B := 67890


func after_each() -> void:
	WeatherLibrary.reset()


# --- Determinism -------------------------------------------------------------

func test_force_is_identical_across_repeated_evaluations() -> void:
	# The property the global leaderboards depend on.
	for d in [0.0, 37.5, 400.0, 1234.5, 9000.0]:
		var first := Crosswind.force_at(d, SEED_A, 12.0, 8.0, 30.0)
		for i in 5:
			assert_eq(Crosswind.force_at(d, SEED_A, 12.0, 8.0, 30.0), first,
				"same distance + seed + params must give the identical force every time")


func test_evaluation_order_does_not_matter() -> void:
	# Rules out any carried RNG stream state: sampling backwards must match forwards.
	var forward: Array[Vector3] = []
	for i in 20:
		forward.append(Crosswind.force_at(float(i) * 50.0, SEED_A, 10.0, 6.0, 0.0))
	for i in range(19, -1, -1):
		assert_eq(Crosswind.force_at(float(i) * 50.0, SEED_A, 10.0, 6.0, 0.0), forward[i],
			"the profile must be a pure function of distance, not of call order")


func test_different_seeds_give_different_profiles() -> void:
	var differed := false
	for i in 40:
		var d := float(i) * 25.0
		if Crosswind.magnitude_at(d, SEED_A, 10.0, 6.0, 400.0) \
				!= Crosswind.magnitude_at(d, SEED_B, 10.0, 6.0, 400.0):
			differed = true
			break
	assert_true(differed, "two event seeds must produce different gust profiles")


# --- Profile shape -----------------------------------------------------------

func test_force_varies_with_distance() -> void:
	# It is a profile, not a constant: somewhere along the stage the wind differs.
	var first := Crosswind.magnitude_at(0.0, SEED_A, 10.0, 6.0, 400.0)
	var varied := false
	for i in 60:
		if not is_equal_approx(Crosswind.magnitude_at(float(i) * 20.0, SEED_A, 10.0, 6.0, 400.0), first):
			varied = true
			break
	assert_true(varied, "the gust profile must change along the stage")


func test_magnitude_scales_monotonically_with_strength() -> void:
	for d in [0.0, 123.0, 777.0]:
		var weak := Crosswind.magnitude_at(d, SEED_A, 5.0, 2.0, 400.0)
		var mid := Crosswind.magnitude_at(d, SEED_A, 10.0, 2.0, 400.0)
		var strong := Crosswind.magnitude_at(d, SEED_A, 20.0, 2.0, 400.0)
		assert_lt(weak, mid, "more strength must mean more force at the same point")
		assert_lt(mid, strong, "more strength must mean more force at the same point")


func test_zero_gust_is_a_steady_wind() -> void:
	# Structural identity, not a tuning choice: with no gust the profile is the
	# steady strength everywhere.
	for d in [0.0, 60.0, 3000.0]:
		assert_almost_eq(Crosswind.magnitude_at(d, SEED_A, 7.0, 0.0, 400.0), 7.0, 0.0001,
			"gust 0 must leave exactly the steady strength")


func test_gust_stays_within_its_authored_band() -> void:
	# The layered sum is normalised, so the wind never exceeds strength +/- gust —
	# that bound is what lets a designer reason about the numbers they author.
	for i in 500:
		var m := Crosswind.magnitude_at(float(i) * 7.3, SEED_A, 10.0, 4.0, 400.0)
		assert_between(m, 10.0 - 4.0 - 0.0001, 10.0 + 4.0 + 0.0001,
			"the gust must stay inside strength +/- gust")


func test_direction_is_a_world_heading() -> void:
	# 0 deg = world +X, 90 deg = world +Z — the same convention the particle wind uses.
	assert_almost_eq(Crosswind.direction(0.0).x, 1.0, 0.0001, "0 deg points along +X")
	assert_almost_eq(Crosswind.direction(90.0).z, 1.0, 0.0001, "90 deg points along +Z")
	assert_almost_eq(Crosswind.direction(45.0).y, 0.0, 0.0001, "wind is horizontal")
	# Direction only rotates the force; it never changes its size.
	var a := Crosswind.force_at(500.0, SEED_A, 10.0, 4.0, 0.0).length()
	var b := Crosswind.force_at(500.0, SEED_A, 10.0, 4.0, 137.0).length()
	assert_almost_eq(a, b, 0.0001, "heading must not change the force magnitude")


# --- Opting in via the weather table -----------------------------------------

func test_no_wind_block_means_no_wind_at_all() -> void:
	# Every non-storm condition: no "wind" key => an empty dict => the car applies
	# nothing and the per-tick cost is zero. Note nothing here names a condition id.
	WeatherLibrary.override_for_test([
		{"id": "dry"},
		{"id": "drizzle", "grip_mult": "rain_grip_mult"},
	])
	var cfg := GameConfig.new()
	for id in ["dry", "drizzle", "not_a_condition"]:
		cfg.weather = id
		assert_true(Crosswind.wind_params(cfg).is_empty(),
			"a condition with no wind block must resolve to no wind (%s)" % id)


func test_wind_block_resolves_its_named_config_fields() -> void:
	# The contract: the block names GameConfig fields; the values come from the config
	# resource, never from the table. Uses existing numeric fields as stand-ins so the
	# test does not depend on any particular condition's authored field names.
	WeatherLibrary.override_for_test([
		{"id": "dry"},
		{
			"id": "gale",
			"wind": {
				"strength": "crosswind_gust_wavelength_m",
				"gust": "crosswind_nose_on_fraction",
				"dir_deg": "crosswind_gust_wavelength_m",
			},
		},
	])
	var cfg := GameConfig.new()
	cfg.weather = "gale"
	cfg.crosswind_gust_wavelength_m = 123.0
	cfg.crosswind_nose_on_fraction = 0.5
	var wind := Crosswind.wind_params(cfg)
	assert_false(wind.is_empty(), "a condition with a wind block must resolve to wind")
	assert_eq(wind[Crosswind.STRENGTH_KEY], 123.0, "strength reads its named config field")
	assert_eq(wind[Crosswind.GUST_KEY], 0.5, "gust reads its named config field")
	assert_eq(wind[Crosswind.DIR_KEY], 123.0, "dir_deg reads its named config field")


func test_missing_field_in_a_wind_block_degrades_to_zero() -> void:
	# A partially authored block must not crash a stage.
	WeatherLibrary.override_for_test([
		{"id": "dry"},
		{"id": "gale", "wind": {"strength": "crosswind_gust_wavelength_m"}},
	])
	var cfg := GameConfig.new()
	cfg.weather = "gale"
	var wind := Crosswind.wind_params(cfg)
	assert_eq(wind[Crosswind.GUST_KEY], 0.0, "an unnamed gust field is simply no gust")
	assert_eq(wind[Crosswind.DIR_KEY], 0.0, "an unnamed direction field is simply 0")
