extends GutTest

# CarPerformance — the simulated benchmark rating (higher = faster) and the fixed test
# track it runs on. See docs/superpowers/specs/2026-08-15-car-performance-rating-design.md.
#
# Everything here is behaviour, never a tuned value: no test asserts a particular
# rating, a particular benchmark time, or where a catalogue car lands. A designer
# retuning the benchmark knobs must not break this file.

const BASE := {
	"mass": 1200.0, "peak_torque": 300.0, "redline": 7000.0,
	"tire_compound": 1.0, "drag": 0.05, "drive_mode": CarLibrary.RWD,
}

func before_each():
	CarPerformance.reset()

func after_each():
	Config.reset()
	CarPerformance.reset()

func _with(overrides: Dictionary) -> Dictionary:
	var m := BASE.duplicate()
	m.merge(overrides, true)
	return m

# --- The track ---------------------------------------------------------------

func test_benchmark_track_is_a_usable_centerline():
	var track := BenchmarkTrack.build()
	var curve := track["centerline"] as Curve2D
	assert_not_null(curve, "benchmark track has a centerline")
	assert_gt(curve.get_baked_length(), 0.0, "benchmark track has positive length")
	assert_gt(curve.get_point_count(), 2, "benchmark track is more than a single segment")

func test_benchmark_track_has_no_curvature_spikes_at_joins():
	# The reason this builder exists instead of chaining TrackFixtures helpers. A
	# tangent discontinuity at a segment join reads to LapTimeModel as an enormous
	# kappa, and the nonlinear cornering cap turns that into an arbitrary hard
	# slowdown that would dominate the benchmark.
	#
	# The tightest curvature anywhere on the track should be the hairpin's 1/radius.
	# A kink would blow far past that.
	var hairpin_r := 15.0
	var track := BenchmarkTrack.build_from(200.0, hairpin_r, 90.0, 3)
	var curve := track["centerline"] as Curve2D
	var length := curve.get_baked_length()
	var step := 1.0
	var worst := 0.0
	var prev := curve.sample_baked(0.0)
	var prev_heading := (curve.sample_baked(step) - prev).angle()
	var d := step
	while d + step < length:
		var here := curve.sample_baked(d)
		var nxt := curve.sample_baked(d + step)
		var heading := (nxt - here).angle()
		var dtheta := absf(wrapf(heading - prev_heading, -PI, PI))
		worst = maxf(worst, dtheta / step)
		prev_heading = heading
		d += step
	# Allow generous slack for discretisation; a real kink is orders of magnitude over.
	assert_lt(worst, (1.0 / hairpin_r) * 3.0,
		"no join produces curvature far beyond the tightest authored corner")

func test_a_longer_straight_makes_a_longer_track():
	var short_track := BenchmarkTrack.build_from(100.0, 15.0, 90.0, 3)
	var long_track := BenchmarkTrack.build_from(800.0, 15.0, 90.0, 3)
	assert_gt((long_track["centerline"] as Curve2D).get_baked_length(),
		(short_track["centerline"] as Curve2D).get_baked_length(),
		"the straight knob actually lengthens the track")

func test_sweeper_count_adds_corners():
	var few := BenchmarkTrack.build_from(200.0, 15.0, 90.0, 1)
	var many := BenchmarkTrack.build_from(200.0, 15.0, 90.0, 5)
	assert_gt((many["centerline"] as Curve2D).get_baked_length(),
		(few["centerline"] as Curve2D).get_baked_length(),
		"more sweepers means more track")

# --- The rating --------------------------------------------------------------

func test_rating_is_positive_and_deterministic():
	var first := CarPerformance.rating(BASE)
	assert_gt(first, 0, "a normal car rates above zero")
	assert_eq(CarPerformance.rating(BASE), first, "repeated calls agree")
	CarPerformance.reset()
	assert_eq(CarPerformance.rating(BASE), first, "the value survives a cache drop")

func test_more_power_rates_higher():
	assert_gt(CarPerformance.rating(_with({"peak_torque": 600.0})),
		CarPerformance.rating(_with({"peak_torque": 150.0})),
		"more torque, same everything else, must rate higher")

func test_more_mass_rates_lower():
	assert_lt(CarPerformance.rating(_with({"mass": 1800.0})), CarPerformance.rating(BASE),
		"a heavier car rates lower")

func test_more_grip_rates_higher():
	assert_gt(CarPerformance.rating(_with({"tire_compound": 1.4})), CarPerformance.rating(BASE),
		"stickier tyres rate higher")

func test_an_aero_kit_rates_higher():
	# The headline reason the rating exists: power-to-weight could NEVER see this,
	# because grip parts are deliberately routed away from it.
	assert_gt(CarPerformance.rating(_with({"downforce_front": 3.0, "downforce_rear": 3.0})),
		CarPerformance.rating(BASE), "downforce must raise the rating")

func test_awd_rates_at_least_as_high_as_rwd():
	Config.data.traction_factor_fwd = 0.8
	Config.data.traction_factor_rwd = 0.9
	CarPerformance.reset()
	var awd := CarPerformance.rating(_with({"drive_mode": CarLibrary.AWD}))
	assert_gte(awd, CarPerformance.rating(_with({"drive_mode": CarLibrary.RWD})),
		"AWD is never worse than RWD when its traction ceiling is higher")
	assert_gt(awd, CarPerformance.rating(_with({"drive_mode": CarLibrary.FWD})),
		"AWD out-rates FWD when its traction ceiling is higher")

func test_the_rating_ignores_fields_the_benchmark_cannot_measure():
	# Guards the docs' honesty: brake_bias and suspension are not modelled, so a car
	# differing only in those must rate identically. If this ever fails, the rating
	# gained a term and features/car-performance.md needs updating with it.
	var fussy := _with({"brake_bias": 0.7, "weight_front": 0.62, "wheelbase": 2.9})
	assert_eq(CarPerformance.rating(fussy), CarPerformance.rating(BASE),
		"unmodelled fields must not move the rating")

# --- Scale stability (D6: normalised against a reference car) ----------------

func test_the_reference_car_anchors_the_scale():
	assert_eq(CarPerformance.rating(CarPerformance.REFERENCE_CAR), int(CarPerformance.RATING_SCALE),
		"the reference car rates exactly at the scale constant, by construction")

func test_the_scale_survives_a_geometry_change():
	# Why normalisation was chosen over freezing the knobs: the straight length must
	# stay a live tuning lever WITHOUT silently re-meaning every authored rating.
	var before := CarPerformance.rating(CarPerformance.REFERENCE_CAR)
	Config.data.benchmark_straight_m = Config.data.benchmark_straight_m * 2.0
	CarPerformance.reset()
	assert_eq(CarPerformance.rating(CarPerformance.REFERENCE_CAR), before,
		"the anchor holds when the geometry moves")

func test_the_scale_survives_a_surface_grip_retune():
	# The benchmark runs on frozen conditions (LapTimeModel's mu_override seam), so a
	# gravel/tarmac retune must not re-score the roster.
	var before := CarPerformance.rating(_with({"peak_torque": 450.0}))
	Config.data.gravel_grip = Config.data.gravel_grip * 1.5
	Config.data.tarmac_grip = Config.data.tarmac_grip * 1.5
	CarPerformance.reset()
	assert_eq(CarPerformance.rating(_with({"peak_torque": 450.0})), before,
		"surface config must not move a car's rating")

func test_the_straight_knob_shifts_the_power_corner_balance():
	# Direction only, never a value: this is the lever's contract. A long straight
	# should favour the powerful car relative to the grippy one, and shortening it
	# should swing the balance back.
	var powerful := _with({"peak_torque": 700.0, "tire_compound": 0.9})
	var grippy := _with({"peak_torque": 260.0, "tire_compound": 1.5})

	Config.data.benchmark_straight_m = 1500.0
	CarPerformance.reset()
	var long_gap := CarPerformance.rating(powerful) - CarPerformance.rating(grippy)

	Config.data.benchmark_straight_m = 60.0
	CarPerformance.reset()
	var short_gap := CarPerformance.rating(powerful) - CarPerformance.rating(grippy)

	assert_gt(long_gap, short_gap,
		"a longer straight favours the power car; shortening it favours the grip car")

# --- Meta merging ------------------------------------------------------------

func test_merged_meta_carries_both_power_and_grip_terms():
	# The bug this exists to prevent: effective_meta alone excludes grip/downforce, so
	# a rating built on it would not move when an aero kit is fitted.
	var base := {"mass": 1200.0, "peak_torque": 300.0, "redline": 7000.0,
		"tire_compound": 1.0, "drag": 0.05, "drive_mode": CarLibrary.RWD}
	var merged := CarPerformance.merged_meta({}, base)
	assert_true(merged.has("mass"), "merged meta keeps the power/mass terms")
	assert_true(merged.has("tire_compound"), "merged meta keeps the grip terms")


# --- Mass reaches the rating through GRIP, not only through power -------------

func test_wider_tires_rate_higher_at_the_same_mass() -> void:
	# Load sensitivity is about contact PRESSURE, so rubber is a lever on the rating in
	# its own right. This also guards the cache: the widths had to join _cache_key when
	# the model started reading them, or two different cars would share one lap time.
	assert_gt(CarPerformance.rating(_with({"wheel_width_front": 0.285, "wheel_width_rear": 0.285})),
		CarPerformance.rating(_with({"wheel_width_front": 0.185, "wheel_width_rear": 0.185})),
		"the wider-tired car rates higher on an otherwise identical meta")


func test_shedding_mass_helps_a_car_that_cannot_use_more_power() -> void:
	# The case that started this: a car whose straights are TRACTION-limited rather than
	# power-limited used to see almost nothing from weight reduction, because the only
	# mass term in the model was the engine one it was not using. Modelled here as a very
	# low-powered car, so any rating gain has to have come through grip.
	var slug := _with({"peak_torque": 60.0, "redline": 4000.0})
	var light := slug.duplicate()
	light["mass"] = float(slug["mass"]) * 0.8
	assert_gt(CarPerformance.rating(light), CarPerformance.rating(slug),
		"a lighter car rates higher even when it cannot put more power down")
