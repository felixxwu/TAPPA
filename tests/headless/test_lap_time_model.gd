extends GutTest

const LapTimeModel = preload("res://scripts/lap_time_model.gd")

# A reference car with known SI stats (mirrors CarLibrary fields used by the model).
const CAR := {
	"mass": 1200.0, "peak_torque": 300.0, "redline": 7000.0,
	"tire_compound": 1.1, "drag": 0.2,
}

func _straight_track(length: float) -> Dictionary:
	var c := Curve2D.new()
	c.add_point(Vector2(0, 0))
	c.add_point(Vector2(0, -length))   # heading +... straight line
	return {"centerline": c, "pieces": []}

func _arc_track(radius: float, sweep_rad: float) -> Dictionary:
	# A circular arc of the given radius, approximated by sampled points.
	var c := Curve2D.new()
	var steps := 64
	for i in steps + 1:
		var a := sweep_rad * float(i) / float(steps)
		c.add_point(Vector2(radius * sin(a), -radius * (1.0 - cos(a))))
	return {"centerline": c, "pieces": []}

func test_straight_only_matches_analytic_accel():
	# On a long straight from rest, the car accelerates; final v should approach the
	# power/drag-limited regime and time should be finite and positive.
	var prof: Dictionary = LapTimeModel.optimum_profile(_straight_track(400.0), CAR, {})
	assert_gt(prof["total_ms"], 0, "straight has positive time")
	var v: PackedFloat32Array = prof["v"]
	assert_gt(v[v.size() - 1], v[0], "speed increases along a straight from rest")

func test_more_power_is_faster():
	var slow := CAR.duplicate(); slow["peak_torque"] = 150.0
	var fast := CAR.duplicate(); fast["peak_torque"] = 600.0
	var t_slow := LapTimeModel.optimum_ms(_straight_track(400.0), slow, {})
	var t_fast := LapTimeModel.optimum_ms(_straight_track(400.0), fast, {})
	assert_lt(t_fast, t_slow, "more power => lower time")

func test_more_grip_is_faster_in_corners():
	var low := CAR.duplicate(); low["tire_compound"] = 0.7
	var high := CAR.duplicate(); high["tire_compound"] = 1.4
	var track := _arc_track(40.0, PI)   # a sustained 40 m radius corner
	assert_lt(LapTimeModel.optimum_ms(track, high, {}),
			LapTimeModel.optimum_ms(track, low, {}), "more grip => lower time in a corner")

func test_tighter_corner_is_slower():
	var wide := _arc_track(80.0, PI)
	var tight := _arc_track(20.0, PI)
	# Same arc sweep; tighter radius forces lower cornering speed => more time per metre.
	assert_gt(_ms_per_m(tight, CAR), _ms_per_m(wide, CAR), "tighter corner => more ms per metre")

func _ms_per_m(track: Dictionary, car: Dictionary) -> float:
	var len: float = (track["centerline"] as Curve2D).get_baked_length()
	return float(LapTimeModel.optimum_ms(track, car, {})) / maxf(len, 1.0)

func test_profile_total_matches_scalar():
	var prof: Dictionary = LapTimeModel.optimum_profile(_arc_track(40.0, PI), CAR, {})
	assert_eq(LapTimeModel.optimum_ms(_arc_track(40.0, PI), CAR, {}), int(prof["total_ms"]))

func test_corner_speed_near_friction_limit():
	# Mid-corner speed on a steady arc should sit near sqrt(mu*g / kappa).
	var radius := 50.0
	var prof: Dictionary = LapTimeModel.optimum_profile(_arc_track(radius, PI), CAR, {})
	var v: PackedFloat32Array = prof["v"]
	var mid := v[int(v.size() / 2)]
	var mu := 1.1   # avg grip, gravel default (gravel_grip 1.0)
	var v_limit := sqrt(mu * 9.81 * radius)
	assert_almost_eq(mid, v_limit, v_limit * 0.25, "mid-corner speed near friction limit")
