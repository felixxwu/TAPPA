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


# A dead-straight +X road: sample_at(s) = (s, 0), so the pose's along-track
# component is exactly the distance asked for and the lateral component is zero.
class StubTrack:
	extends Node
	func origin_offset() -> float:
		return 0.0
	func sample_at(s: float) -> Vector2:
		return Vector2(s, 0.0)


func test_pose_at_distance_poses_the_raw_track_distance() -> void:
	# The start-line grid slot is a DISTANCE (one gap down the lead-in), not a time
	# on the profile — pose_at_distance takes it directly.
	var ghost := RivalGhost.new()
	add_child_autofree(ghost)
	var track := StubTrack.new()
	add_child_autofree(track)
	ghost.setup(track, null, _constant_speed_profile(), {})
	ghost.pose_at_distance(7.0)
	var car := ghost.car()
	assert_almost_eq(car.global_position.x, 7.0, 0.001, "posed at the raw distance asked")
	assert_almost_eq(car.global_position.y, Config.data.start_spawn_clearance, 0.001,
			"seated on the (absent) terrain at the spawn clearance")
	assert_almost_eq(car.global_position.z, 0.0, 0.001,
			"dead on the centerline, in the player's wheel tracks")


func test_pose_at_distance_without_a_track_is_harmless() -> void:
	var ghost := RivalGhost.new()
	add_child_autofree(ghost)
	ghost.setup(null, null, _constant_speed_profile(), {})
	var before := ghost.car().global_position
	ghost.pose_at_distance(7.0)  # no track_progress to pose against: no-op, no crash
	assert_eq(ghost.car().global_position, before, "the pose call was a no-op")


# --- Rival identity: pick_rival (features/rival-ghost.md) ---------------------
# The real roster + real CarPerformance benchmark solves — the pick's whole point is
# matching the shipped cars' measured pace, so a synthetic roster would test nothing.

func test_pick_rival_without_a_target_is_empty() -> void:
	assert_eq(RivalGhost.pick_rival(0.0, 1), {}, "no target pace, no rival identity")
	assert_eq(RivalGhost.pick_rival(-1.0, 1), {}, "a negative pace is no target either")


func test_pick_rival_names_a_real_roster_car() -> void:
	var rival := RivalGhost.pick_rival(1.0, 0)
	var cars := CarLibrary.all()
	assert_gt(int(rival.get("car_index", -1)), -1, "a real target pace picks a rival")
	var idx := int(rival.get("car_index"))
	assert_true(idx >= 0 and idx < cars.size(), "the picked index is a live roster entry")
	assert_true(String(rival.get("name", "")) in RivalGhost.RIVAL_NAMES,
		"the driver name comes from the authored pool")


func test_pick_rival_takes_the_closest_benchmark_ratio() -> void:
	# The contract the start-line card's believability rests on: no roster car sits
	# closer to the requested pace than the pick. Recomputed here from the same
	# public CarPerformance APIs, so the test pins the argmin rather than an
	# authored index that a roster edit would silently invalidate.
	var pace := 1.35
	var rival := RivalGhost.pick_rival(pace, 3)
	assert_gt(int(rival.get("car_index", -1)), -1, "the pace picked a car")
	var ref_ms := CarPerformance.benchmark_ms(CarPerformance.REFERENCE_CAR)
	var best := INF
	for entry in CarLibrary.all():
		var ms := CarPerformance.benchmark_ms(CarPerformance.merged_meta({}, entry))
		if ms <= 0:
			continue
		best = minf(best, absf(float(ms) / float(ref_ms) - pace))
	var picked := CarLibrary.all()[int(rival.get("car_index"))]
	var picked_ms := CarPerformance.benchmark_ms(CarPerformance.merged_meta({}, picked))
	assert_almost_eq(absf(float(picked_ms) / float(ref_ms) - pace), best, 0.0001,
		"the pick is a nearest neighbour of the target pace")


func test_pick_rival_is_monotonic_across_the_pace_range() -> void:
	# A slower target (bigger pace) must pick a car no FASTER than a quicker
	# target's pick — the roster-shaped reading of "the rival gets quicker as the
	# regions tighten". Nearest-neighbour over fixed points is monotonic by
	# construction; this pins it against accidental tie-break or filter regressions.
	var last_ratio := -INF
	for pace: float in [0.8, 1.0, 1.25, 1.6, 2.0]:
		var rival := RivalGhost.pick_rival(pace, 0)
		assert_gt(int(rival.get("car_index", -1)), -1, "pace %s picked a car" % pace)
		var picked := CarLibrary.all()[int(rival.get("car_index"))]
		var ms := CarPerformance.benchmark_ms(CarPerformance.merged_meta({}, picked))
		var ratio := float(ms) / float(CarPerformance.benchmark_ms(CarPerformance.REFERENCE_CAR))
		assert_true(ratio >= last_ratio - 0.0001,
			"the picked car's pace ratio never decreases as the target slows")
		last_ratio = ratio


func test_pick_rival_name_is_stable_per_seed() -> void:
	assert_eq(RivalGhost.pick_rival(1.0, 7).get("name"),
		RivalGhost.pick_rival(1.3, 7).get("name"),
		"the same seed names the same driver regardless of pace")
	assert_eq(RivalGhost.pick_rival(1.0, -5).get("name"),
		RivalGhost.pick_rival(1.0, posmod(-5, RivalGhost.RIVAL_NAMES.size())).get("name"),
		"negative seeds wrap like their positive equivalents")


# --- Rival identity: the live instance's card data ----------------------------

func test_setup_applies_the_picked_car_to_the_ghosts_body() -> void:
	var ghost := RivalGhost.new()
	add_child_autofree(ghost)
	ghost.setup(null, null, _constant_speed_profile(), {"car_index": 0, "name": "Test Driver"})
	assert_true(ghost.has_car(), "setup built the ghost's car")
	assert_eq(ghost.rival_name(), "Test Driver", "the card reads back the driver name")
	assert_eq(ghost.rival_car_index(), 0, "the picked roster index is remembered")
	assert_eq(ghost.rival_car_name(), String(CarLibrary.all()[0].get("name", "")),
		"the car line resolves the roster entry's display name")
	assert_eq((ghost.car() as Node).get("_car_index"), 0,
		"the body itself was reshaped to the picked entry")
	ghost.free_ghost()


func test_setup_without_a_rival_keeps_the_neutral_baseline() -> void:
	var ghost := RivalGhost.new()
	add_child_autofree(ghost)
	ghost.setup(null, null, _constant_speed_profile())
	assert_eq(ghost.rival_car_index(), -1, "no rival dict, no car applied")
	assert_eq(ghost.rival_car_name(), "", "the baseline body has no car name")
	assert_eq(ghost.rival_name(), "", "and no driver name")


func test_target_ms_is_the_profile_duration_in_whole_ms() -> void:
	var ghost := RivalGhost.new()
	add_child_autofree(ghost)
	ghost._profile = _constant_speed_profile()  # duration 10.0 s
	assert_eq(ghost.target_ms(), 10000, "the card's time to beat is the profile's own total")
	assert_eq(ghost.profile(), ghost._profile, "the profile accessor hands back what was set")


# --- The display layer (transparency, slope, fade — features/rival-ghost.md) ----
# Restored with the pre-pivot ghost_car.gd display stack; these re-pin the three
# properties that made the rewrite's omission visible: not translucent, not on the
# road's slope, and no proximity behaviour.

# A terrain rising `slope` per metre along the road's own +X direction.
class StubTerrain:
	extends Node
	var slope := 0.0
	func height_at(x: float, _z: float) -> float:
		return slope * x


func _display_ghost(terrain: Node = null) -> RivalGhost:
	var ghost := RivalGhost.new()
	add_child_autofree(ghost)
	var track := StubTrack.new()
	add_child_autofree(track)
	ghost.setup(track, terrain, _constant_speed_profile(),
		{"car_index": 0, "name": "Test Driver"})
	return ghost


func test_the_ghost_car_is_actually_translucent() -> void:
	# GeometryInstance3D.transparency was a no-op on the car's opaque shader — assert
	# the thing that actually makes it see-through: a material with alpha below 1.
	# Posed by pose_at (the RUN path); the start-line park is deliberately solid.
	Config.data.rival_ghost_opacity = 0.5
	var ghost := _display_ghost()
	ghost.pose_at(0.3)
	var checked := 0
	for mesh in ghost._mesh_instances(ghost.car()):
		var mat: Material = mesh.material_override
		if mat == null:
			continue
		checked += 1
		assert_true(mat is BaseMaterial3D, "the override is a real material")
		var bm := mat as BaseMaterial3D
		assert_lt(bm.albedo_color.a, 1.0, "its alpha is below opaque")
		assert_eq(bm.transparency, BaseMaterial3D.TRANSPARENCY_ALPHA,
			"and it is in the alpha-blended pass")
	assert_gt(checked, 0, "at least one mesh got a translucent override")
	Config.data.rival_ghost_opacity = 0.4


func test_the_rival_is_solid_at_the_start_line() -> void:
	# The grid park (pose_at_distance) renders the rival OPAQUE: it is the subject
	# of the start-line shot, and translucency there would read as broken.
	var ghost := _display_ghost()
	ghost.pose_at_distance(0.0)
	for mat in ghost._ghost_materials:
		assert_almost_eq(mat.albedo_color.a, 1.0, 0.001,
			"the parked rival wears full opacity")


func test_the_ghost_tilts_onto_a_sloped_road() -> void:
	# It used to stand perfectly level on every slope, so on a climb it visibly
	# floated at the nose and dug in at the tail instead of looking driven on the road.
	var hill := StubTerrain.new()
	hill.slope = 0.25          # a 25% climb along the road's +X
	add_child_autofree(hill)
	var ghost := _display_ghost(hill)
	ghost.pose_at_distance(7.0)
	var up: Vector3 = ghost.car().global_transform.basis.y
	assert_lt(up.dot(Vector3.UP), 0.995, "on a slope the ghost's up leaves world up")
	# The surface normal of a plane rising 0.25 per metre tips by atan(0.25).
	var expected := atan(0.25)
	var actual := acos(clampf(up.dot(Vector3.UP), -1.0, 1.0))
	assert_almost_eq(actual, expected, 0.12,
		"and it tilts by the slope angle, not some arbitrary amount")
	# Still orthonormal, or the car renders sheared.
	var b: Basis = ghost.car().global_transform.basis
	assert_almost_eq(b.x.dot(b.y), 0.0, 0.01, "basis stays orthogonal (x.y)")
	assert_almost_eq(b.y.dot(b.z), 0.0, 0.01, "basis stays orthogonal (y.z)")


func test_the_ghost_fades_out_as_the_player_closes_in() -> void:
	Config.data.rival_ghost_fade_near_m = 14.0
	Config.data.rival_ghost_visible_m = 100.0
	var ghost := _display_ghost()
	var player := Node3D.new()
	add_child_autofree(player)
	ghost.set_player(player)

	# Far away (but inside the cull): visible, full configured opacity.
	player.global_position = Vector3(60.0, 0.0, 0.0)
	ghost.pose_at(2.0)
	assert_true(ghost.car().visible, "inside the cull range the ghost renders")
	assert_almost_eq(ghost._ghost_materials[0].albedo_color.a, 0.4, 0.01,
		"at range it wears the full configured opacity")

	# Overlapping the player: faded to (near) nothing but not culled.
	player.global_position = Vector3(ghost.car().global_position)
	ghost.pose_at(2.0)
	assert_almost_eq(ghost._ghost_materials[0].albedo_color.a, 0.0, 0.01,
		"at zero separation the proximity fade erases it")

	# Past the cull: not rendered at all.
	player.global_position = Vector3(300.0, 0.0, 0.0)
	ghost.pose_at(2.0)
	assert_false(ghost.car().visible, "past rival_ghost_visible_m it is culled")
	Config.data.rival_ghost_fade_near_m = 14.0
	Config.data.rival_ghost_visible_m = 400.0


func test_departure_speed_reads_the_profile_pace() -> void:
	var ghost := _display_ghost()
	# The constant-speed profile runs at exactly _SPEED m/s.
	assert_almost_eq(ghost.departure_speed(7.0), _SPEED, 0.5,
		"the drive-off runs at the profile's own pace")


func test_the_departed_ghost_stays_hidden_until_the_clock_catches_up() -> void:
	# After the start-line drive-off, the ghost must not pop back onto the line the
	# moment StageManager starts posing it at elapsed() — it stays hidden until the
	# profile's own distance passes where the drive-off left it.
	var ghost := _display_ghost()
	ghost.pose_at_distance(29.0)          # mid-departure, visible on the grid
	assert_true(ghost.car().visible, "while posing by distance it shows")
	ghost.mark_departed_at(29.0)
	ghost.pose_at(0.5)                    # 20 m/s * 0.5 s = 10 m: well short of 29
	assert_false(ghost.car().visible, "before the clock catches up it stays hidden")
	ghost.pose_at(2.0)                    # 40 m: past the departure point
	assert_true(ghost.car().visible, "once caught up it re-enters normally")


func test_the_nametag_rides_and_fades_with_the_car() -> void:
	Config.data.rival_ghost_nametag_enabled = true
	var ghost := _display_ghost()
	var tag: Label3D = ghost._nametag
	assert_not_null(tag, "a named rival gets a driver tag")
	assert_eq(tag.text, "Test Driver", "naming the driver the card names")
	assert_eq(tag.get_parent(), ghost.car(), "it rides on the car so the pose carries it")
	ghost._set_alpha(0.25)
	assert_almost_eq(tag.modulate.a, 0.25, 0.01, "the tag fades WITH the car")
	ghost.free_ghost()
	Config.data.rival_ghost_nametag_enabled = true
