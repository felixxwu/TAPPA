extends GutTest
# RivalPace: the rival ghost's pace model (features/rival-ghost.md). Pure logic, no
# scene — it turns "this rival drove the stage in T ms" into "where were they at
# elapsed t", by re-solving LapTimeModel with a degraded driver-skill envelope until
# the profile's total lands on T.
#
# Every input here is synthetic (TrackFixtures + a literal car meta). Nothing reaches
# into CarLibrary/RallyLibrary, and nothing asserts an authored or tuned value: the
# config knobs the solve reads are SET by the tests that care about them, per CLAUDE.md.

const RivalPace = preload("res://scripts/rival_pace.gd")

# A reference car with plain SI stats — the fields LapTimeModel actually reads.
const CAR := {
	"mass": 1200.0, "peak_torque": 300.0, "redline": 7000.0,
	"tire_compound": 1.1, "drag": 0.2,
}


func before_each() -> void:
	Config.reset()
	# Pin the deficit split for the solve tests below. Without this they inherit the SHIPPED
	# exponents, so retuning the look of the ghost would break unrelated tests — and with
	# the default grip exponent of 0 a pure arc cannot be slowed at all (no straight to give
	# away), which is a real property of the model, not a solve bug. Tests that are ABOUT
	# the split set their own values.
	Config.data.rival_ghost_grip_exponent = 1.0
	Config.data.rival_ghost_power_exponent = 0.3


func after_each() -> void:
	Config.reset()


# The ungraded reference time for a track: what the car would do at full skill.
func _optimum_ms(track: Dictionary) -> int:
	return LapTimeModel.optimum_ms(track, CAR, {})


# --- Hitting the number -----------------------------------------------------------

func test_solve_lands_on_the_target_time() -> void:
	# The whole point of the feature: the ghost crosses the line when the standings say
	# it did. Swept across a range of paces so this isn't one lucky bracket.
	var track := TrackFixtures.arc(60.0, PI)
	var optimum := _optimum_ms(track)
	for factor in [1.05, 1.2, 1.5, 1.8]:
		var target := int(round(float(optimum) * factor))
		var pace: RivalPace = RivalPace.solve(track, CAR, {}, target)
		assert_almost_eq(pace.total_ms(), target, 2,
				"factor %s: total must land on the target" % factor)

func test_a_normal_target_uses_the_bisection_not_a_clamp() -> void:
	# If the ordinary case silently fell through to the uniform-scale fallback, the
	# whole degraded-envelope design would be decorative.
	var track := TrackFixtures.arc(60.0, PI)
	var pace: RivalPace = RivalPace.solve(track, CAR, {}, int(round(float(_optimum_ms(track)) * 1.25)))
	assert_false(pace.used_fallback(), "a mid-band target must be solved by bisection")
	assert_lt(pace.residual_ms(), Config.data.rival_ghost_max_time_residual_ms,
			"and its residual must be inside the cap")

func test_an_impossibly_fast_target_clamps_but_still_matches_the_time() -> void:
	# Reachable in practice: rival times are baked over the CACHED track while the ghost
	# re-solves over the LIVE one, so the target can sit beyond the ungraded optimum.
	var track := TrackFixtures.arc(60.0, PI)
	var target := int(round(float(_optimum_ms(track)) * 0.5))   # far faster than possible
	var pace: RivalPace = RivalPace.solve(track, CAR, {}, target)
	assert_true(pace.used_fallback(), "an unreachable target must report the fallback")
	assert_almost_eq(pace.total_ms(), target, 2,
			"time fidelity survives the clamp — that is the invariant that matters")

func test_an_impossibly_slow_target_clamps_but_still_matches_the_time() -> void:
	# The other end of the bracket, which an earlier draft of the design left undefined.
	var track := TrackFixtures.arc(60.0, PI)
	var target := int(round(float(_optimum_ms(track)) * 12.0))
	var pace: RivalPace = RivalPace.solve(track, CAR, {}, target)
	assert_true(pace.used_fallback(), "a target slower than k_min must report the fallback")
	assert_almost_eq(pace.total_ms(), target, 2, "and still land on the time")

func test_a_degenerate_target_does_not_crash() -> void:
	var track := TrackFixtures.arc(60.0, PI)
	var pace: RivalPace = RivalPace.solve(track, CAR, {}, 0)
	assert_not_null(pace, "a zero target returns a pace object rather than erroring")
	assert_true(pace.is_degenerate(), "and reports itself unusable")


# --- The queries the ghost and the HUD actually call -------------------------------

func test_offset_at_runs_from_zero_to_the_span_length() -> void:
	var track := TrackFixtures.arc(60.0, PI)
	var span: float = (track["centerline"] as Curve2D).get_baked_length()
	var target := int(round(float(_optimum_ms(track)) * 1.3))
	var pace: RivalPace = RivalPace.solve(track, CAR, {}, target)
	assert_almost_eq(pace.offset_at(0.0), 0.0, 0.01, "starts at the timing origin")
	# Tolerance, not float equality: this is a micro-scaled interpolation over a
	# resampled table, and the profile's own sample step is the natural bound.
	assert_almost_eq(pace.offset_at(float(target) / 1000.0), span, LapTimeModel.SAMPLE_STEP_M,
			"reaches the far end of the span exactly as the target time elapses")

func test_offset_at_is_monotonic_and_clamps_at_both_ends() -> void:
	var track := TrackFixtures.arc(60.0, PI)
	var target := int(round(float(_optimum_ms(track)) * 1.3))
	var pace: RivalPace = RivalPace.solve(track, CAR, {}, target)
	var span: float = (track["centerline"] as Curve2D).get_baked_length()
	var prev := -1.0
	for i in 60:
		var t := float(target) / 1000.0 * float(i) / 59.0
		var off := pace.offset_at(t)
		assert_true(off >= prev - 0.001, "offset never goes backwards (sample %d)" % i)
		prev = off
	assert_almost_eq(pace.offset_at(-5.0), 0.0, 0.01, "clamps below t=0")
	assert_almost_eq(pace.offset_at(float(target) / 1000.0 + 60.0), span,
			LapTimeModel.SAMPLE_STEP_M, "clamps past the finish — it must not run on")

func test_time_at_offset_inverts_offset_at() -> void:
	# The HUD's "vs P1" popup asks the time at a turn boundary; the ghost asks the
	# offset at a time. They must be the same curve read from either end.
	var track := TrackFixtures.arc(60.0, PI)
	var target := int(round(float(_optimum_ms(track)) * 1.3))
	var pace: RivalPace = RivalPace.solve(track, CAR, {}, target)
	for frac in [0.2, 0.5, 0.8]:
		var t: float = float(target) / 1000.0 * float(frac)
		var off := pace.offset_at(t)
		assert_almost_eq(pace.time_at_offset(off), t, 0.15,
				"time_at_offset(offset_at(t)) == t at frac %s" % frac)

func test_speed_at_is_positive_while_moving() -> void:
	var track := TrackFixtures.straight(400.0)
	var target := int(round(float(_optimum_ms(track)) * 1.2))
	var pace: RivalPace = RivalPace.solve(track, CAR, {}, target)
	assert_gt(pace.speed_at(float(target) / 1000.0 * 0.5), 0.0,
			"mid-run speed is positive")


# --- The shape, which is the reason for the whole design ---------------------------

func test_a_degraded_solve_loses_more_time_in_corners_than_on_straights() -> void:
	# The behavioural statement of "degraded envelope, not uniform slowdown": the same
	# skill factor must cost proportionally MORE on a corner-limited track than on a
	# power-limited one. True for any reasonable grip/power numbers.
	var k := 0.7
	var e: float = Config.data.rival_ghost_power_exponent
	var corner := TrackFixtures.arc(40.0, PI)
	var straight := TrackFixtures.straight(400.0)
	var corner_penalty := float(LapTimeModel.optimum_ms(corner, CAR, {}, k, pow(k, e))) \
			/ float(LapTimeModel.optimum_ms(corner, CAR, {}))
	var straight_penalty := float(LapTimeModel.optimum_ms(straight, CAR, {}, k, pow(k, e))) \
			/ float(LapTimeModel.optimum_ms(straight, CAR, {}))
	assert_gt(corner_penalty, straight_penalty,
			"a degraded driver loses proportionally more in the corners")

func test_solved_skill_falls_as_the_target_gets_slower() -> void:
	var track := TrackFixtures.arc(60.0, PI)
	var optimum := _optimum_ms(track)
	var quick: RivalPace = RivalPace.solve(track, CAR, {}, int(round(float(optimum) * 1.1)))
	var slow: RivalPace = RivalPace.solve(track, CAR, {}, int(round(float(optimum) * 1.7)))
	assert_lt(slow.solved_k(), quick.solved_k(),
			"a slower rival is solved with a lower skill factor")


# --- The timed-span sub-curve ------------------------------------------------------

func test_timed_span_track_spans_the_requested_offsets() -> void:
	var source := TrackFixtures.handled_arc(80.0, PI).get("centerline") as Curve2D
	var from := 20.0
	var to := source.get_baked_length() - 20.0
	var sub: Dictionary = RivalPace.timed_span_track(source, from, to)
	var curve := sub["centerline"] as Curve2D
	assert_almost_eq(curve.get_baked_length(), to - from, 2.0,
			"the sub-curve covers exactly the requested span")
	assert_false(sub.has("pieces") and not (sub["pieces"] as Array).is_empty(),
			"carries no raw pieces — those are in the source curve's coordinate system")

func test_resampling_preserves_the_pace_of_a_handled_curve() -> void:
	# The assumption the whole pace SHAPE rests on: re-solving over a resampled
	# sub-curve must give substantially the same answer as the source curve. Asserted
	# against a curve with real Bezier handles, because a handle-free one is lossless by
	# construction and would let a broken resample through.
	var source_track := TrackFixtures.handled_arc(80.0, PI)
	var source := source_track["centerline"] as Curve2D
	var whole: Dictionary = RivalPace.timed_span_track(source, 0.0, source.get_baked_length())
	var direct := _optimum_ms(source_track)
	var resampled := _optimum_ms(whole)
	assert_almost_eq(float(resampled), float(direct), float(direct) * 0.1,
			"resampled pace tracks the source curve within 10%")


# --- Cached skill factor (baked into the opponent cache) ---------------------------

func test_a_cached_skill_factor_reproduces_the_uncached_pace() -> void:
	var track := TrackFixtures.arc(60.0, PI)
	var target := int(round(float(_optimum_ms(track)) * 1.35))
	var fresh: RivalPace = RivalPace.solve(track, CAR, {}, target)
	var seeded: RivalPace = RivalPace.solve(track, CAR, {}, target, fresh.solved_k())
	assert_almost_eq(seeded.total_ms(), target, 2, "seeded solve still lands on the target")
	assert_almost_eq(seeded.solved_k(), fresh.solved_k(), 0.02,
			"and uses substantially the cached factor")
	assert_false(seeded.used_fallback(), "a good seed is accepted, not rejected")

func test_a_wrong_cached_factor_is_rejected_and_resolved() -> void:
	# The divergence detector: a seed baked against a different track must not be
	# trusted just because it is present.
	var track := TrackFixtures.arc(60.0, PI)
	var target := int(round(float(_optimum_ms(track)) * 1.35))
	var seeded: RivalPace = RivalPace.solve(track, CAR, {}, target, 0.05)
	assert_almost_eq(seeded.total_ms(), target, 2, "still lands on the target")
	assert_gt(seeded.solved_k(), 0.05, "the bad seed was discarded, not used")

func test_a_missing_cached_factor_solves_from_scratch() -> void:
	# Forward compatibility: a cache entry written before this field existed.
	var track := TrackFixtures.arc(60.0, PI)
	var target := int(round(float(_optimum_ms(track)) * 1.35))
	var pace: RivalPace = RivalPace.solve(track, CAR, {}, target, -1.0)
	assert_almost_eq(pace.total_ms(), target, 2, "solves without a seed")
	assert_false(pace.used_fallback(), "and does so by bisection")


# --- Splitting the deficit between corners and straights ---------------------------

func test_a_zero_grip_exponent_leaves_cornering_speed_at_the_limit() -> void:
	# The shipped default: corners cost nothing, so the ghost brakes where the player
	# should brake and carries the true apex speed, losing time only on the straights.
	# pow(k, 0) == 1, so the grip arm must be exactly neutral no matter what k the solve
	# lands on.
	Config.data.rival_ghost_grip_exponent = 0.0
	Config.data.rival_ghost_power_exponent = 1.0
	# A P1-like pace on a stage with a long straight. P1 is the only rival the ghost is ever
	# built for, and P1 sits close to the optimum — a backmarker pace with corners free is
	# a different question, and one the career audit tool answers per stage.
	var track := TrackFixtures.straight_then_arc(400.0, 45.0, PI)
	var full := LapTimeModel.optimum_profile(track, CAR, {})
	var optimum := int(full["total_ms"])
	var pace: RivalPace = RivalPace.solve(track, CAR, {}, int(round(float(optimum) * 1.10)))

	assert_false(pace.used_fallback(),
			"a P1-like target on a stage with a real straight is reachable on power alone")
	assert_lt(pace.solved_k(), 1.0, "the solve did reduce the envelope")

	# Cornering speed is the MINIMUM of the profile (the tightest point sets it). With the
	# grip arm neutral it must match the full-skill profile.
	var full_v: PackedFloat32Array = full["v"]
	var full_min := full_v[0]
	for i in full_v.size():
		full_min = minf(full_min, full_v[i]) if i > 0 else full_v[i]
	var probe := LapTimeModel.optimum_profile(track, CAR, {},
			pow(pace.solved_k(), 0.0), pow(pace.solved_k(), 1.0))
	var probe_v: PackedFloat32Array = probe["v"]
	var probe_min := probe_v[0]
	for i in probe_v.size():
		probe_min = minf(probe_min, probe_v[i]) if i > 0 else probe_v[i]
	assert_almost_eq(probe_min, full_min, maxf(full_min * 0.02, 0.05),
			"minimum (cornering) speed is unchanged when the grip exponent is 0")
	assert_gt(int(probe["total_ms"]), optimum,
			"yet the stage total is slower, so the time came out of the straights")

func test_a_zero_power_exponent_leaves_straight_line_pace_alone() -> void:
	# The mirror case, so the two arms are demonstrably independent rather than one knob
	# with a rename.
	Config.data.rival_ghost_grip_exponent = 1.0
	Config.data.rival_ghost_power_exponent = 0.0
	var track := TrackFixtures.straight(500.0)
	var optimum := LapTimeModel.optimum_ms(track, CAR, {})
	# On a pure straight, leaving power alone means there is almost nothing to give away.
	var slowed := LapTimeModel.optimum_ms(track, CAR, {}, 0.5, pow(0.5, 0.0))
	assert_almost_eq(float(slowed), float(optimum), float(optimum) * 0.35,
			"with the power arm neutral, a straight is only mildly affected by grip")
