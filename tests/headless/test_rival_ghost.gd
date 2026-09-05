extends GutTest
# RivalGhost's pure profile maths (features/rival-ghost.md): the two inversions of a
# {"s","t"} pace-scaled profile that pose the ghost (distance_at_time) and drive the
# HUD delta (time_at_distance). No live Car, Track or session involved — a synthetic
# profile only, per CLAUDE.md's testing rules.

# A profile at constant speed: t = s / SPEED, so both inversions have an exact
# closed form to check against (distance_at_time(t) = SPEED*t, time_at_distance(s) =
# s/SPEED), independent of how finely it's sampled.
const _SPEED := 20.0
const _LENGTH_M := 200.0

func _constant_speed_profile(samples := 11) -> Dictionary:
	var s := PackedFloat32Array()
	var t := PackedFloat32Array()
	for i in samples:
		var dist := _LENGTH_M * float(i) / float(samples - 1)
		s.append(dist)
		t.append(dist / _SPEED)
	return {"s": s, "t": t}


func test_distance_at_time_matches_the_closed_form() -> void:
	var profile := _constant_speed_profile()
	for t: float in [0.0, 1.0, 3.5, 7.25, 10.0]:
		var expected: float = _SPEED * t
		assert_almost_eq(RivalGhost.distance_at_time(profile, t), expected, 0.01,
			"s = speed * t at t=%s" % t)


func test_time_at_distance_matches_the_closed_form() -> void:
	var profile := _constant_speed_profile()
	for s: float in [0.0, 20.0, 71.0, 145.0, 200.0]:
		var expected: float = s / _SPEED
		assert_almost_eq(RivalGhost.time_at_distance(profile, s), expected, 0.01,
			"t = s / speed at s=%s" % s)


func test_distance_at_time_holds_at_the_finish_past_the_duration() -> void:
	var profile := _constant_speed_profile()
	var duration := RivalGhost.profile_duration(profile)
	assert_almost_eq(RivalGhost.distance_at_time(profile, duration + 50.0), _LENGTH_M, 0.01,
		"a race time past the profile's duration holds at the finish, not extrapolated")


func test_time_at_distance_holds_at_the_start_before_zero() -> void:
	var profile := _constant_speed_profile()
	assert_almost_eq(RivalGhost.time_at_distance(profile, -50.0), 0.0, 0.01,
		"a distance before the start clamps to the profile's own first sample")


func test_the_two_inversions_are_round_trip_consistent() -> void:
	# time_at_distance(distance_at_time(t)) should return (approximately) t itself —
	# the same monotonic curve read both ways.
	var profile := _constant_speed_profile(41)  # finer sampling for round-trip accuracy
	for t: float in [1.0, 4.3, 8.0]:
		var s := RivalGhost.distance_at_time(profile, t)
		var back := RivalGhost.time_at_distance(profile, s)
		assert_almost_eq(back, t, 0.05, "round-trip through distance and back to time")


func test_profile_duration_is_the_last_time_sample() -> void:
	var profile := _constant_speed_profile()
	assert_almost_eq(RivalGhost.profile_duration(profile), _LENGTH_M / _SPEED, 0.01,
		"duration is the profile's own last (total) time sample")


func test_empty_profile_yields_zero_everywhere() -> void:
	assert_eq(RivalGhost.distance_at_time({}, 5.0), 0.0, "no profile, no distance")
	assert_eq(RivalGhost.time_at_distance({}, 5.0), 0.0, "no profile, no time")
	assert_eq(RivalGhost.profile_duration({}), 0.0, "no profile, no duration")


# --- Live-instance predicates (no Car needed) --------------------------------

func test_has_profile_false_when_empty_or_zero_duration() -> void:
	var ghost := RivalGhost.new()
	add_child_autofree(ghost)
	assert_false(ghost.has_profile(), "nothing set up yet")
	ghost._profile = {"s": PackedFloat32Array([0.0]), "t": PackedFloat32Array([0.0])}
	assert_false(ghost.has_profile(), "a zero-duration profile has nothing to show either")
	ghost._profile = _constant_speed_profile()
	assert_true(ghost.has_profile(), "a real, positive-duration profile has something to show")


func test_reset_seeds_the_clock_and_looping_flag() -> void:
	var ghost := RivalGhost.new()
	add_child_autofree(ghost)
	ghost.reset(true)
	assert_eq(ghost._t, 0.0, "reset zeroes the ghost's own clock")
	assert_true(ghost._looping, "reset(true) selects the start-line's looping idle")
	ghost.reset(false)
	assert_false(ghost._looping, "reset(false) selects the live run's un-looped clock")
