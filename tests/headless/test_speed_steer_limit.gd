extends GutTest
# Physical steer limit: Car.optimum_steer_limit(cfg, speed, slip_peak) bounds the
# input steering offset so the front tire sits on its peak-grip slip angle rather
# than scrubbing past it. Pure logic — no scene, no catalogue. Synthetic cfg +
# synthetic slip_peak so the assertions test the RELATIONSHIPS the model must
# hold, not any tuned value.

const Car := preload("res://scripts/car.gd")

var _cfg: GameConfig


func before_each() -> void:
	_cfg = GameConfig.new()
	_cfg.steer_limit = 0.8
	_cfg.tire_norm_floor = 2.5


func test_full_lock_at_standstill() -> void:
	# At standstill the blend gives the full mechanical steer_limit regardless of
	# surface — tight parking-speed turning is preserved.
	assert_almost_eq(Car.optimum_steer_limit(_cfg, 0.0, 0.14), _cfg.steer_limit, 1e-5,
		"full lock at standstill (tarmac)")
	assert_almost_eq(Car.optimum_steer_limit(_cfg, 0.0, 0.31), _cfg.steer_limit, 1e-5,
		"full lock at standstill (gravel)")


func test_pins_to_optimum_angle_above_blend_end() -> void:
	# Above the blend-end speed the cap is purely slip-based: asin(slip_peak) — the
	# tire's optimum slip angle — and speed-independent (the point of normalizing).
	var slip_peak := 0.14
	var expected := asin(slip_peak)
	# 15 m/s (54 km/h) is above the 50 km/h blend end; higher speeds must match too.
	for speed in [15.0, 30.0, 80.0]:
		assert_almost_eq(Car.optimum_steer_limit(_cfg, speed, slip_peak), expected, 1e-5,
			"pinned to asin(slip_peak) at speed %f" % speed)


func test_blends_between_full_lock_and_slip_cap() -> void:
	# Between standstill and the blend-end speed the cap sits strictly between the
	# slip-based cap and the full mechanical lock — a linear fade, so low-speed
	# steering keeps real bite instead of snapping to the small optimum angle.
	var slip_peak := 0.14
	var mid := Car.STEER_LOCK_BLEND_END_SPEED * 0.5
	var slip_cap := asin(slip_peak)
	var limit := Car.optimum_steer_limit(_cfg, mid, slip_peak)
	assert_gt(limit, slip_cap + 1e-4, "mid-blend cap is above the bare slip cap")
	assert_lt(limit, _cfg.steer_limit - 1e-4, "mid-blend cap is below full lock")
	# Exactly the linear midpoint (slip-based cap is already pinned at this speed).
	assert_almost_eq(limit, lerpf(_cfg.steer_limit, slip_cap, 0.5), 1e-5,
		"cap is the linear blend of full lock and the slip cap")


func test_looser_surface_allows_bigger_angle() -> void:
	# A looser surface (bigger slip_peak) peaks at a bigger slip angle, so its
	# steer cap at speed is larger. Relationship test — anchor values not asserted.
	var tarmac := Car.optimum_steer_limit(_cfg, 30.0, 0.14)
	var gravel := Car.optimum_steer_limit(_cfg, 30.0, 0.31)
	assert_gt(gravel, tarmac + 0.05,
		"gravel (bigger slip_peak) allows a bigger steer angle than tarmac (%f vs %f)" % [tarmac, gravel])


func test_never_exceeds_mechanical_limit() -> void:
	# Even a huge slip_peak can't steer past the mechanical steer_limit.
	for speed in [0.0, 5.0, 50.0]:
		assert_true(Car.optimum_steer_limit(_cfg, speed, 0.9) <= _cfg.steer_limit + 1e-6,
			"capped by steer_limit at speed %f" % speed)


func test_monotonically_non_increasing_with_speed() -> void:
	var prev := INF
	var speed := 0.0
	while speed <= 60.0:
		var limit: float = Car.optimum_steer_limit(_cfg, speed, 0.14)
		assert_true(limit <= prev + 1e-6,
			"limit never rises as speed increases (speed=%f -> %f)" % [speed, limit])
		prev = limit
		speed += 2.5


func test_authority_tracks_the_limit() -> void:
	# The steer-assist authority is exactly the limit as a fraction of full lock,
	# so the assist torque tapers by the same amount the wheel angle does.
	for speed in [0.0, 5.0, 30.0]:
		assert_almost_eq(Car.steer_authority(_cfg, speed, 0.14),
			Car.optimum_steer_limit(_cfg, speed, 0.14) / _cfg.steer_limit, 1e-5,
			"authority == limit / steer_limit at speed %f" % speed)


func test_optimum_slip_angle_is_asin() -> void:
	assert_almost_eq(Car.optimum_slip_angle(0.14), asin(0.14), 1e-6, "tarmac-ish")
	assert_almost_eq(Car.optimum_slip_angle(0.31), asin(0.31), 1e-6, "gravel-ish")
	assert_almost_eq(Car.optimum_slip_angle(2.0), asin(1.0), 1e-6, "clamps out-of-range slip_peak")
