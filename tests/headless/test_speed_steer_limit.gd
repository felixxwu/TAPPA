extends GutTest
# Speed-dependent steering: Car.speed_steer_authority(cfg, speed) (the shared
# factor scaling BOTH the wheel-angle limit and the steer-assist torque) and
# Car.speed_scaled_steer_limit(cfg, speed) (steer_limit * that factor).
# Pure logic — no scene, no catalogue. A synthetic GameConfig fixes the falloff
# window so the assertions test the RAMP SHAPE, not any tuned value.

const Car := preload("res://scripts/car.gd")

var _cfg: GameConfig


func before_each() -> void:
	_cfg = GameConfig.new()
	_cfg.steer_limit = 0.5
	# Thresholds are authored in km/h; the helper takes physics m/s speeds.
	# 36 km/h = 10 m/s, 180 km/h = 50 m/s.
	_cfg.steer_limit_falloff_start_kph = 36.0
	_cfg.steer_limit_falloff_end_kph = 180.0
	_cfg.steer_limit_min_fraction = 0.4


func test_full_limit_at_and_below_start() -> void:
	assert_almost_eq(Car.speed_scaled_steer_limit(_cfg, 0.0), 0.5, 1e-5,
		"full steer_limit at standstill")
	assert_almost_eq(Car.speed_scaled_steer_limit(_cfg, 10.0), 0.5, 1e-5,
		"still full steer_limit at the falloff start speed")


func test_floor_at_and_above_end() -> void:
	var floor_limit := _cfg.steer_limit * _cfg.steer_limit_min_fraction
	assert_almost_eq(Car.speed_scaled_steer_limit(_cfg, 50.0), floor_limit, 1e-5,
		"reaches min_fraction of steer_limit at the falloff end speed")
	assert_almost_eq(Car.speed_scaled_steer_limit(_cfg, 200.0), floor_limit, 1e-5,
		"holds the floor above the falloff end speed")


func test_monotonically_non_increasing_across_ramp() -> void:
	var prev := INF
	for i in range(0, 61, 5):
		var limit: float = Car.speed_scaled_steer_limit(_cfg, float(i))
		assert_true(limit <= prev + 1e-6,
			"limit never rises as speed increases (speed=%d -> %f)" % [i, limit])
		prev = limit


func test_min_fraction_one_disables_falloff() -> void:
	_cfg.steer_limit_min_fraction = 1.0
	for speed in [0.0, 25.0, 100.0]:
		assert_almost_eq(Car.speed_scaled_steer_limit(_cfg, speed), _cfg.steer_limit, 1e-5,
			"min_fraction=1.0 keeps steer_limit constant at speed %f" % speed)


func test_end_not_after_start_disables_falloff() -> void:
	_cfg.steer_limit_falloff_end_kph = _cfg.steer_limit_falloff_start_kph
	for speed in [0.0, 25.0, 100.0]:
		assert_almost_eq(Car.speed_scaled_steer_limit(_cfg, speed), _cfg.steer_limit, 1e-5,
			"end <= start keeps steer_limit constant at speed %f" % speed)


func test_authority_factor_endpoints() -> void:
	# The shared factor is 1.0 at/below start and min_fraction at/above end — this
	# is what scales the steer-assist torque as well as the wheel-angle limit, so
	# the speed-dependent cap is actually felt (the assist otherwise masks it).
	assert_almost_eq(Car.speed_steer_authority(_cfg, 5.0), 1.0, 1e-5,
		"full authority at/below the falloff start")
	assert_almost_eq(Car.speed_steer_authority(_cfg, 50.0), _cfg.steer_limit_min_fraction, 1e-5,
		"authority drops to min_fraction at/above the falloff end")


func test_scaled_limit_is_limit_times_authority() -> void:
	# The wheel-angle limit is exactly steer_limit * the shared authority factor,
	# so both aids taper by the identical amount at any speed.
	for speed in [0.0, 20.0, 35.0, 80.0]:
		assert_almost_eq(Car.speed_scaled_steer_limit(_cfg, speed),
			_cfg.steer_limit * Car.speed_steer_authority(_cfg, speed), 1e-5,
			"scaled limit == steer_limit * authority at speed %f" % speed)
