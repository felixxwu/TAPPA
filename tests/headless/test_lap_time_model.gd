extends GutTest

const LapTimeModel = preload("res://scripts/lap_time_model.gd")

# A reference car with known SI stats (mirrors CarLibrary fields used by the model).
const CAR := {
	"mass": 1200.0, "peak_torque": 300.0, "redline": 7000.0,
	"tire_compound": 1.1, "drag": 0.2,
}

# These shapes moved to TrackFixtures when test_rival_pace.gd needed the same ones —
# one definition instead of a copy per test file. Kept as thin local names so the
# assertions below read unchanged.
func _straight_track(length: float) -> Dictionary:
	return TrackFixtures.straight(length)

func _arc_track(radius: float, sweep_rad: float) -> Dictionary:
	return TrackFixtures.arc(radius, sweep_rad)

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

# A wet event applies GameConfig.rain_grip_mult on top of the surface-blended grip,
# so its optimum must be strictly slower than the identical dry event — this is the
# lever that scales the whole rival field for weather (see lap_time_model.gd's
# _surface_grip docstring). Relation only, no tunable value asserted: whatever
# rain_grip_mult is authored as (as long as < 1.0), wet must be slower than dry.
func test_wet_event_is_slower_than_dry_in_a_corner():
	var track := _arc_track(40.0, PI)
	var dry_event := {"weather": RallyLibrary.WEATHER_DRY}
	var wet_event := {"weather": RallyLibrary.WEATHER_RAIN}
	var t_dry := LapTimeModel.optimum_ms(track, CAR, dry_event)
	var t_wet := LapTimeModel.optimum_ms(track, CAR, wet_event)
	assert_gt(t_wet, t_dry, "wet event is strictly slower than the identical dry event")

# --- Skill-factor seam (grip_mult / power_mult), for the rival ghost -------------
# The ghost's pace comes from re-solving this model with a degraded envelope
# (features/rival-ghost.md). These are the injection points; the defaults must be
# perfect no-ops so every existing caller — and the baked opponent cache — is
# untouched.

func test_default_multipliers_match_the_no_argument_call():
	# The invariance every existing caller depends on: passing the defaults explicitly
	# must be byte-identical to not passing them. If this breaks, rival times move and
	# data/opponent_cache.json silently diverges from live generation.
	var track := _arc_track(40.0, PI)
	var bare: Dictionary = LapTimeModel.optimum_profile(track, CAR, {})
	var defaulted: Dictionary = LapTimeModel.optimum_profile(track, CAR, {}, 1.0, 1.0)
	assert_eq(int(defaulted["total_ms"]), int(bare["total_ms"]),
			"explicit default multipliers must not change the total")
	var v_bare: PackedFloat32Array = bare["v"]
	var v_def: PackedFloat32Array = defaulted["v"]
	assert_eq(v_def.size(), v_bare.size(), "same sample count")
	for i in v_bare.size():
		assert_almost_eq(v_def[i], v_bare[i], 1e-6, "speed sample %d unchanged" % i)

func test_grip_mult_below_one_is_slower_in_a_corner():
	var track := _arc_track(40.0, PI)
	var full := LapTimeModel.optimum_ms(track, CAR, {}, 1.0, 1.0)
	var degraded := LapTimeModel.optimum_ms(track, CAR, {}, 0.7, 1.0)
	assert_gt(degraded, full, "less grip => slower through a sustained corner")

func test_power_mult_below_one_is_slower_on_a_straight():
	# The reason the skill factor degrades power as well as grip: on a straight the
	# forward pass is engine-limited, so grip alone barely moves the total.
	var track := _straight_track(400.0)
	var full := LapTimeModel.optimum_ms(track, CAR, {}, 1.0, 1.0)
	var degraded := LapTimeModel.optimum_ms(track, CAR, {}, 1.0, 0.7)
	assert_gt(degraded, full, "less power => slower down a straight")

func test_total_time_is_monotonic_in_the_skill_factor():
	# What makes the ghost's bisection well-posed: time must be strictly decreasing in
	# k across the whole bracket, including above 1.0.
	var track := _arc_track(60.0, PI)
	var prev := -1
	for k in [0.5, 0.7, 0.9, 1.0, 1.1]:
		var t := LapTimeModel.optimum_ms(track, CAR, {}, k, pow(k, 0.3))
		if prev >= 0:
			assert_lt(t, prev, "k=%s must be strictly faster than the previous, lower k" % k)
		prev = t

func test_corner_speed_near_friction_limit():
	# Mid-corner speed on a steady arc should sit near sqrt(mu*g / kappa).
	var radius := 50.0
	var prof: Dictionary = LapTimeModel.optimum_profile(_arc_track(radius, PI), CAR, {})
	var v: PackedFloat32Array = prof["v"]
	var mid := v[int(v.size() / 2)]
	var mu := 1.1   # avg grip, gravel default (gravel_grip 1.0)
	# Gravity comes from the model, not a hand-copied literal — LapTimeModel.G reads
	# physics/3d/default_gravity via Platform.gravity(), so retuning the project
	# setting moves the expectation with the code instead of silently diverging.
	var v_limit := sqrt(mu * LapTimeModel.G * radius)
	assert_almost_eq(mid, v_limit, v_limit * 0.25, "mid-corner speed near friction limit")

# --- Downforce and drive mode (2026-08-15 car-performance-rating spec) --------
# These cover the enriched envelope: the friction circle grows with speed when the
# car makes downforce, and drive mode gates how much of it can be put down as drive.

func after_each():
	Config.reset()

func test_defaults_are_an_exact_no_op():
	# The whole safety property of the enrichment: a car with no downforce, at the
	# shipped traction factors, must time EXACTLY as it did before the terms existed.
	# If this fails, every baked rival time silently moved.
	var track := TrackFixtures.arc(60.0, PI)
	var without := LapTimeModel.optimum_ms(track, CAR, {})
	var with_zero_aero := CAR.duplicate()
	with_zero_aero["downforce_front"] = 0.0
	with_zero_aero["downforce_rear"] = 0.0
	assert_eq(LapTimeModel.optimum_ms(track, with_zero_aero, {}), without,
		"explicit zero downforce must be identical to the field being absent")

func test_downforce_makes_a_car_faster_through_a_corner():
	var track := TrackFixtures.arc(60.0, PI)
	var winged := CAR.duplicate()
	winged["downforce_front"] = 3.0
	winged["downforce_rear"] = 3.0
	assert_lt(LapTimeModel.optimum_ms(track, winged, {}), LapTimeModel.optimum_ms(track, CAR, {}),
		"downforce raises the cornering ceiling, so the arc is quicker")

func test_downforce_helps_far_less_on_a_straight_than_in_a_corner():
	# This is what makes the benchmark's straight/sweeper split measure two different
	# things. Downforce is NOT free of effect on a straight — the launch is traction
	# limited, so a wing helps off the line, which is real. But the gain there must be
	# an order of magnitude smaller than the gain through a corner, or the sweeper
	# section is not isolating aero the way the rating design assumes.
	var winged := CAR.duplicate()
	winged["downforce_front"] = 3.0
	winged["downforce_rear"] = 3.0
	var straight := TrackFixtures.straight(400.0)
	var corner := TrackFixtures.arc(60.0, PI)
	var straight_gain := 1.0 - float(LapTimeModel.optimum_ms(straight, winged, {})) \
		/ float(LapTimeModel.optimum_ms(straight, CAR, {}))
	var corner_gain := 1.0 - float(LapTimeModel.optimum_ms(corner, winged, {})) \
		/ float(LapTimeModel.optimum_ms(corner, CAR, {}))
	assert_gt(corner_gain, straight_gain * 5.0,
		"aero must pay off far more through a corner than down a straight")

func test_extreme_downforce_stays_finite():
	# The cornering cap is v^2 = mu_g / (kappa - mu*D/m) — singular once the aero term
	# reaches kappa. A huge wing on a gentle sweeper must clamp, not blow up.
	var track := TrackFixtures.arc(400.0, PI * 0.5)
	var absurd := CAR.duplicate()
	absurd["downforce_rear"] = 1.0e6
	var prof: Dictionary = LapTimeModel.optimum_profile(track, absurd, {})
	var total: int = prof["total_ms"]
	assert_gt(total, 0, "degenerate downforce still produces a positive time")
	var v: PackedFloat32Array = prof["v"]
	for i in v.size():
		assert_true(is_finite(v[i]), "velocity stays finite under degenerate downforce")
		assert_lte(v[i], LapTimeModel.V_CAP_MAX_MS + 1.0, "velocity respects the hard clamp")

func test_all_passes_share_one_envelope_at_the_aero_boosted_cap():
	# The bug this guards: if only the cornering ceiling knew about downforce, a car at
	# that ceiling would have a_lat > mu_g, longitudinal grip would collapse to zero, and
	# it could neither accelerate nor brake at a speed pass 1 just declared legal — so the
	# car would crawl. A winged car must therefore never be SLOWER than an unwinged one.
	var track := TrackFixtures.arc(80.0, PI)
	var winged := CAR.duplicate()
	winged["downforce_front"] = 5.0
	winged["downforce_rear"] = 5.0
	assert_lte(LapTimeModel.optimum_ms(track, winged, {}), LapTimeModel.optimum_ms(track, CAR, {}),
		"downforce must never make a car slower")

func test_traction_factor_gates_corner_exit():
	# Direction only, never the shipped values: a lower factor must cost time.
	var track := TrackFixtures.arc(30.0, PI)
	var car := CAR.duplicate()
	car["drive_mode"] = CarLibrary.FWD
	# Set BOTH ends explicitly rather than leaning on the shipped default, so retuning
	# the factors (they ship at 0.4/0.6/1.0) can never invert this test's premise.
	Config.data.traction_factor_fwd = 0.9
	var loose := LapTimeModel.optimum_ms(track, car, {})
	Config.data.traction_factor_fwd = 0.35
	assert_gt(LapTimeModel.optimum_ms(track, car, {}), loose,
		"a tighter traction ceiling costs time out of a corner")

func test_traction_factor_is_selected_by_drive_mode():
	var track := TrackFixtures.arc(30.0, PI)
	var fwd := CAR.duplicate(); fwd["drive_mode"] = CarLibrary.FWD
	var awd := CAR.duplicate(); awd["drive_mode"] = CarLibrary.AWD
	Config.data.traction_factor_fwd = 0.7
	assert_gt(LapTimeModel.optimum_ms(track, fwd, {}), LapTimeModel.optimum_ms(track, awd, {}),
		"only the FWD factor moved, so only the FWD car slows")

func test_drive_mode_costs_nothing_once_the_car_is_power_limited():
	# The contract behind the traction factors: drivetrain buys TRACTION, not power. It
	# may only cost time where grip is the binding limit — the forward pass takes
	# min(traction * grip_long, a_engine), so a power-limited car must be unaffected.
	#
	# Tested by LENGTHENING the straight rather than by comparing totals: a standing start
	# is genuinely grip-limited whatever the engine, so every drivetrain pays a one-off
	# launch cost and the totals legitimately differ. What must NOT happen is that gap
	# GROWING with distance — that would mean the factor was still biting while rolling.
	var weak := CAR.duplicate()
	weak["peak_torque"] = 60.0    # far too little power to trouble the tyres once rolling
	var fwd := weak.duplicate(); fwd["drive_mode"] = CarLibrary.FWD
	var awd := weak.duplicate(); awd["drive_mode"] = CarLibrary.AWD
	Config.data.traction_factor_fwd = 0.4
	Config.data.traction_factor_awd = 1.0
	var gaps: Array[int] = []
	for length in [500.0, 2000.0, 8000.0]:
		var track := TrackFixtures.straight(length)
		gaps.append(LapTimeModel.optimum_ms(track, fwd, {}, 1.0, 1.0, 1.0)
			- LapTimeModel.optimum_ms(track, awd, {}, 1.0, 1.0, 1.0))
	# Exact equality but for trapezoid rounding: the integrator accumulates ms over
	# thousands of samples, so allow a couple of ms of drift. A real leak would scale
	# with distance (hundreds of ms over 16x), not sit at 1.
	assert_almost_eq(gaps[1], gaps[0], 2, "the drivetrain gap does not grow over a 4x longer straight")
	assert_almost_eq(gaps[2], gaps[0], 2, "nor over a 16x longer one — it is all launch, none of it rolling")


func test_an_absent_drive_mode_is_neutral():
	# Synthetic metas in other tests omit drive_mode entirely; they must not be penalised.
	var track := TrackFixtures.arc(30.0, PI)
	var rwd := CAR.duplicate(); rwd["drive_mode"] = CarLibrary.RWD
	assert_eq(LapTimeModel.optimum_ms(track, CAR, {}), LapTimeModel.optimum_ms(track, rwd, {}),
		"a meta with no drive_mode times as RWD")
