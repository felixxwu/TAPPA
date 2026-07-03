extends GutTest
# Speed-dependent max steering angle: Car.speed_scaled_steer_limit(cfg, speed).
# Pure logic — no scene, no catalogue. A synthetic GameConfig fixes the falloff
# window so the assertions test the RAMP SHAPE, not any tuned value.

const Car := preload("res://scripts/car.gd")

var _cfg: GameConfig


func before_each() -> void:
	_cfg = GameConfig.new()
	_cfg.steer_limit = 0.5
	_cfg.steer_limit_falloff_start = 10.0
	_cfg.steer_limit_falloff_end = 50.0
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
	_cfg.steer_limit_falloff_end = _cfg.steer_limit_falloff_start
	for speed in [0.0, 25.0, 100.0]:
		assert_almost_eq(Car.speed_scaled_steer_limit(_cfg, speed), _cfg.steer_limit, 1e-5,
			"end <= start keeps steer_limit constant at speed %f" % speed)
