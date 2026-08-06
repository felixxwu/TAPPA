extends GutTest
# GhostCar's DISPLAY car — the parts that need a real car.tscn instance.
#
# Split out from test_ghost_car.gd (which is pure geometry and needs no scene) so the
# cheap assertions aren't paying for a car build. See features/testing.md on cost.

const CAR_SCENE := "res://car.tscn"
const RivalPace = preload("res://scripts/rival_pace.gd")

const CAR := {
	"mass": 1200.0, "peak_torque": 300.0, "redline": 7000.0,
	"tire_compound": 1.1, "drag": 0.2,
}


# Stands in for TerrainManager: the only thing GhostCar wants is height_at(x, z).
# Substituting this is what makes the pose path testable at all — the bug this guards
# against shipped because a hard TerrainManager type meant no test could reach it.
class StubTerrain:
	extends Node
	var height := 3.0
	var slope := 0.0      # metres of rise per metre of +Z, for the incline tests
	func height_at(_x: float, z: float) -> float:
		return height + slope * z


class StubCar:
	extends Node3D
	var linear_velocity := Vector3.ZERO
	var throttling := false
	func reset_to(_xform: Transform3D) -> void: pass
	func is_throttling() -> bool: return throttling


var _stub: StubCar


func before_each() -> void:
	Config.reset()
	_stub = StubCar.new()
	add_child_autofree(_stub)


func after_each() -> void:
	CarFixtures.restore()
	Config.reset()


func _progress_on_straight(length := 300.0) -> TrackProgress:
	var curve := Curve2D.new()
	curve.add_point(Vector2(0, 0))
	curve.add_point(Vector2(0, length))
	var tp := TrackProgress.new()
	add_child_autofree(tp)
	tp.setup(curve, _stub, null)
	return tp


# --- The display car ---------------------------------------------------------------

func test_the_ghost_car_is_intangible_and_kinematic() -> void:
	# A ghost on the player's collision layer would physically block him: car.tscn sets no
	# layer/mask of its own, and FREEZE_MODE_STATIC deliberately KEEPS a collider (that is
	# how an opponent wreck stays solid), so this has to be explicit.
	CarFixtures.install()
	var tp := _progress_on_straight()
	tp.mark_start()
	var ghost := GhostCar.new()
	add_child_autofree(ghost)
	var row := {"car_id": "fx_light_rwd", "engine_id": "", "time_ms": 60000}
	ghost.setup(null, tp, null, row, load(CAR_SCENE), {})
	assert_not_null(ghost.car, "a resolvable car_id builds a ghost car")
	if ghost.car != null:
		assert_eq(ghost.car.collision_layer, 0, "ghost is on no collision layer")
		assert_eq(ghost.car.collision_mask, 0, "and collides with nothing")
		assert_true(ghost.car.kinematic_pose, "and is in kinematic posing mode")
		assert_false(ghost.car.replay_playback,
				"without claiming replay_playback, which TrackProgress reads")

func test_an_unresolved_car_id_builds_no_car_and_does_not_crash() -> void:
	var tp := _progress_on_straight()
	var ghost := GhostCar.new()
	add_child_autofree(ghost)
	ghost.setup(null, tp, null, {"car_id": "no_such_car"}, load(CAR_SCENE), {})
	assert_null(ghost.car, "an unknown car id yields no ghost car rather than car 0")

func test_building_a_ghost_leaves_the_players_tuning_alone() -> void:
	# CarProp.spawn's use_isolated_config() is what prevents this; asserted because
	# skipping it corrupts the player's live car mid-stage.
	CarFixtures.install()
	var tp := _progress_on_straight()
	var before: float = Config.data.wheel_radius
	var ghost := GhostCar.new()
	add_child_autofree(ghost)
	ghost.setup(null, tp, null, {"car_id": "fx_light_rwd", "engine_id": ""},
			load(CAR_SCENE), {})
	assert_almost_eq(Config.data.wheel_radius, before, 0.0001,
			"the shared Config.data is untouched by a ghost spawn")


# --- Regression: posing with a real car AND terrain -------------------------------

func test_posing_the_ghost_over_terrain_does_not_error() -> void:
	# The countdown-hits-zero crash. car.settle_wheels_to_ground() calls its callback with
	# ONE Vector3 (wheel.global_position), not two floats; the wrong arity parses fine and
	# then fails the first time the ghost is posed. Nothing caught it because the other
	# ghost tests pass terrain = null, which skips the settle entirely.
	CarFixtures.install()
	var tp := _progress_on_straight()
	tp.mark_start()
	var terrain := StubTerrain.new()
	add_child_autofree(terrain)
	var pace := RivalPace.solve(TrackFixtures.straight_then_arc(80.0, 45.0, PI), CAR, {},
			int(round(float(LapTimeModel.optimum_ms(TrackFixtures.straight_then_arc(80.0, 45.0, PI), CAR, {})) * 1.3)))
	var ghost := GhostCar.new()
	add_child_autofree(ghost)
	ghost.setup(pace, tp, terrain, {"car_id": "fx_light_rwd", "engine_id": ""},
			load(CAR_SCENE), {})
	assert_not_null(ghost.car, "ghost car built")
	# Pose across the whole run, including the clamped tail past the target time.
	for i in 12:
		ghost.pose_at(float(pace.total_ms()) / 1000.0 * float(i) / 8.0, 0.016)
	assert_gt(ghost.car.global_position.y, terrain.height,
			"the ghost is seated ABOVE the terrain, not buried in it")

func test_the_ghost_is_seated_on_the_terrain_it_is_given() -> void:
	# Ties the body seat to height_at, so a ghost can't float or sink when the ground moves.
	CarFixtures.install()
	var tp := _progress_on_straight()
	tp.mark_start()
	var low := StubTerrain.new()
	low.height = 0.0
	add_child_autofree(low)
	var track := TrackFixtures.straight_then_arc(80.0, 45.0, PI)
	var pace := RivalPace.solve(track, CAR, {},
			int(round(float(LapTimeModel.optimum_ms(track, CAR, {})) * 1.3)))
	var ghost := GhostCar.new()
	add_child_autofree(ghost)
	ghost.setup(pace, tp, low, {"car_id": "fx_light_rwd", "engine_id": ""},
			load(CAR_SCENE), {})
	ghost.pose_at(1.0, 0.016)
	var y_low: float = ghost.car.global_position.y
	low.height = 25.0
	ghost.pose_at(1.0, 0.016)
	assert_almost_eq(ghost.car.global_position.y - y_low, 25.0, 0.5,
			"raising the ground raises the ghost by the same amount")


# --- Regression: the two things that were visibly wrong in play ---------------------

func test_the_ghost_faces_the_way_it_is_travelling() -> void:
	# It drove the stage BACKWARDS: a hand-rolled atan2 yaw was 180 degrees out. The car's
	# forward is -Z, which is what Basis.looking_at produces (and what track_progress.gd
	# uses to place the player), so assert against actual travel direction.
	CarFixtures.install()
	var tp := _progress_on_straight()
	tp.mark_start()
	var terrain := StubTerrain.new()
	add_child_autofree(terrain)
	var track := TrackFixtures.straight_then_arc(80.0, 45.0, PI)
	var pace := RivalPace.solve(track, CAR, {},
			int(round(float(LapTimeModel.optimum_ms(track, CAR, {})) * 1.3)))
	var ghost := GhostCar.new()
	add_child_autofree(ghost)
	ghost.setup(pace, tp, terrain, {"car_id": "fx_light_rwd", "engine_id": ""},
			load(CAR_SCENE), {})
	ghost.pose_at(1.0, 0.016)
	var first: Vector3 = ghost.car.global_position
	ghost.pose_at(2.5, 0.016)
	var second: Vector3 = ghost.car.global_position
	var travel := (second - first)
	travel.y = 0.0
	assert_gt(travel.length(), 0.1, "the ghost actually moved between the two samples")
	# -Z of the basis is the car's nose.
	var nose: Vector3 = -ghost.car.global_transform.basis.z
	nose.y = 0.0
	assert_gt(nose.normalized().dot(travel.normalized()), 0.7,
			"the nose points along the direction of travel, not backwards")

func test_the_ghost_car_is_actually_translucent() -> void:
	# GeometryInstance3D.transparency was a no-op here: the car's shader is opaque
	# (render_mode unshaded, no ALPHA write), so the ghost rendered fully solid. Assert the
	# thing that actually makes it see-through — a material with alpha below 1.
	CarFixtures.install()
	Config.data.rival_ghost_opacity = 0.5
	var tp := _progress_on_straight()
	var ghost := GhostCar.new()
	add_child_autofree(ghost)
	ghost.setup(null, tp, null, {"car_id": "fx_light_rwd", "engine_id": ""},
			load(CAR_SCENE), {})
	assert_not_null(ghost.car, "ghost car built")
	var checked := 0
	for mesh in ghost._mesh_instances(ghost.car):
		var mat: Material = mesh.material_override
		if mat == null:
			continue
		checked += 1
		assert_true(mat is BaseMaterial3D, "the override is a real material")
		var bm := mat as BaseMaterial3D
		assert_lt(bm.albedo_color.a, 1.0, "its alpha is below opaque")
		assert_eq(bm.transparency, BaseMaterial3D.TRANSPARENCY_ALPHA,
				"and it is in the alpha-blended pass")
		# Writes depth so the body self-occludes: without this the ghost is an x-ray shell
		# (you see its far side through its near side) and never reads as solid however high
		# the opacity is set.
		assert_eq(bm.depth_draw_mode, BaseMaterial3D.DEPTH_DRAW_ALWAYS,
				"and writes depth, so the car self-occludes instead of looking x-ray")
	assert_gt(checked, 0, "at least one mesh got a translucent override")


# --- Regression: sitting ON the road, not level above it ---------------------------

# A CURVED road for the ghost to be posed along.
#
# _progress_on_straight has no curvature at all, so lateral offset and slip angle are
# identically zero on it — which silently made every cosmetics/jitter assertion vacuous.
# Real Bezier handles (as track_generator emits) so the baked polyline genuinely curves.
func _progress_on_curve(radius := 120.0, sweep := PI) -> TrackProgress:
	var curve := (TrackFixtures.handled_arc(radius, sweep, 8)["centerline"]) as Curve2D
	var tp := TrackProgress.new()
	add_child_autofree(tp)
	tp.setup(curve, _stub, null)
	return tp


func _ghost_on(terrain: StubTerrain) -> GhostCar:
	CarFixtures.install()
	var tp := _progress_on_curve()
	tp.mark_start()
	add_child_autofree(terrain)
	var track := TrackFixtures.straight_then_arc(80.0, 45.0, PI)
	var pace := RivalPace.solve(track, CAR, {},
			int(round(float(LapTimeModel.optimum_ms(track, CAR, {})) * 1.15)))
	var ghost := GhostCar.new()
	add_child_autofree(ghost)
	ghost.setup(pace, tp, terrain, {"car_id": "fx_light_rwd", "engine_id": ""},
			load(CAR_SCENE), {})
	return ghost

func test_the_ghost_lies_flat_on_level_ground() -> void:
	var flat := StubTerrain.new()
	flat.slope = 0.0
	var ghost := _ghost_on(flat)
	ghost.pose_at(1.5, 0.016)
	var up: Vector3 = ghost.car.global_transform.basis.y
	assert_almost_eq(up.dot(Vector3.UP), 1.0, 0.02,
			"on flat ground the ghost's up is world up")

func test_the_ghost_tilts_onto_a_sloped_road() -> void:
	# It used to stand perfectly level on every slope, so on a climb it visibly floated at
	# the nose and dug in at the tail instead of looking like it was driving on the road.
	var hill := StubTerrain.new()
	hill.slope = 0.25          # a 25% climb along +Z
	var ghost := _ghost_on(hill)
	ghost.pose_at(1.5, 0.016)
	var up: Vector3 = ghost.car.global_transform.basis.y
	assert_lt(up.dot(Vector3.UP), 0.995,
			"on a slope the ghost's up leaves world up")
	# The surface normal of a plane rising 0.25 per metre in +Z tips by atan(0.25).
	var expected := atan(0.25)
	var actual := acos(clampf(up.dot(Vector3.UP), -1.0, 1.0))
	assert_almost_eq(actual, expected, 0.12,
			"and it tilts by the slope angle, not some arbitrary amount")
	# Still orthonormal, or the car renders sheared.
	var b: Basis = ghost.car.global_transform.basis
	assert_almost_eq(b.x.dot(b.y), 0.0, 0.01, "basis stays orthogonal (x.y)")
	assert_almost_eq(b.y.dot(b.z), 0.0, 0.01, "basis stays orthogonal (y.z)")


# --- Regression: fading out as the player closes in --------------------------------

func test_the_ghost_fades_out_as_the_player_gets_close() -> void:
	Config.data.rival_ghost_opacity = 0.6
	Config.data.rival_ghost_fade_near_m = 12.0
	var flat := StubTerrain.new()
	var ghost := _ghost_on(flat)
	var player := Node3D.new()
	add_child_autofree(player)
	ghost.player = player

	# Far away: full configured opacity.
	ghost.pose_at(1.5, 0.016)
	var far_pos: Vector3 = ghost.car.global_position
	player.global_position = far_pos + Vector3(0.0, 0.0, 40.0)
	ghost.pose_at(1.5, 0.016)
	var alpha_far := _first_alpha(ghost)

	# Right on top of it: transparent.
	player.global_position = far_pos
	ghost.pose_at(1.5, 0.016)
	var alpha_near := _first_alpha(ghost)

	assert_almost_eq(alpha_far, 0.6, 0.05, "at range it holds the configured opacity")
	assert_lt(alpha_near, 0.1, "overlapping the player it is essentially invisible")
	assert_lt(alpha_near, alpha_far, "and closing in strictly reduces alpha")

func _first_alpha(ghost: GhostCar) -> float:
	for mesh in ghost._mesh_instances(ghost.car):
		var mat: Material = mesh.material_override
		if mat is BaseMaterial3D:
			return (mat as BaseMaterial3D).albedo_color.a
	return -1.0


# --- Ghost dust: its own particle system, not a free ride on the player's ------------

func test_the_ghost_gets_its_own_wheel_particle_system() -> void:
	# WheelParticles tracks ONE car, and world.gd wires its only instance to the player, so
	# without a second instance the ghost throws no gravel at all — the replay_omega
	# override alone is necessary but not sufficient.
	Config.data.rival_ghost_dust_enabled = true
	var flat := StubTerrain.new()
	var ghost := _ghost_on(flat)
	assert_not_null(ghost._dust, "the ghost owns a WheelParticles instance")
	assert_true(ghost._dust is WheelParticles, "of the right type")

func test_ghost_dust_can_be_switched_off() -> void:
	Config.data.rival_ghost_dust_enabled = false
	var flat := StubTerrain.new()
	var ghost := _ghost_on(flat)
	assert_null(ghost._dust, "no second particle system when dust is disabled")

func test_the_ghosts_wheel_omega_is_fed_from_its_pace() -> void:
	# What the dust (and the wheel spin) actually read. Fed from speed / wheel_radius over
	# drivetrain.visuals — the same set replay_spin iterates.
	var flat := StubTerrain.new()
	var ghost := _ghost_on(flat)
	ghost.pose_at(2.0, 0.016)
	var omega: Dictionary = ghost.car.drivetrain.replay_omega
	assert_gt(omega.size(), 0, "every visual wheel got an omega")
	for w in ghost.car.drivetrain.visuals:
		assert_true(omega.has(w), "including the wheel replay_spin will look up")
	for v in omega.values():
		assert_gt(float(v), 0.0, "and it is turning, not dead still")


# --- Regression: smoothness (it slid side to side and snapped its rotation) ----------

func test_the_ghost_pose_does_not_jitter_frame_to_frame() -> void:
	# The road curve is baked every ~5 m and lerped, so the geometry the ghost reads steps at
	# each chord vertex. With probes shorter than a chord the curvature SIGN flipped between
	# frames, which flipped the lateral line offset (visible sliding) and snapped the facing.
	# Long probes plus smoothing must keep per-frame motion continuous.
	# Smoothing OFF on purpose. With it on, the filter absorbs the jitter whatever the probe
	# spans are, so the test would pass against the broken geometry reading and guard nothing
	# (verified: it did). Off, this measures the raw reading and fails if the probes go back
	# inside a chord.
	Config.data.rival_ghost_position_smoothing_s = 0.0
	Config.data.rival_ghost_rotation_smoothing_s = 0.0
	Config.data.rival_ghost_slip_lag_s = 0.0
	var flat := StubTerrain.new()
	var ghost := _ghost_on(flat)
	var dt := 1.0 / 60.0
	var prev_pos := Vector3.ZERO
	var prev_fwd := Vector3.ZERO
	var worst_yaw := 0.0
	var worst_lateral := 0.0
	var started := false
	# Walk a real slice of the run at 60 fps.
	for i in 240:
		ghost.pose_at(float(i) * dt, dt)
		var pos: Vector3 = ghost.car.global_position
		var fwd: Vector3 = -ghost.car.global_transform.basis.z
		if started:
			var step := pos - prev_pos
			step.y = 0.0
			# Lateral component of this frame's movement, i.e. sideways slide.
			var along := prev_fwd
			along.y = 0.0
			if along.length() > 0.001:
				along = along.normalized()
				var side := absf(step.dot(Vector3(along.z, 0.0, -along.x)))
				worst_lateral = maxf(worst_lateral, side)
			worst_yaw = maxf(worst_yaw, absf(prev_fwd.signed_angle_to(fwd, Vector3.UP)))
		prev_pos = pos
		prev_fwd = fwd
		started = true
	# A ghost travelling at rally speed turns a few degrees per frame at most; the old
	# behaviour snapped by tens of degrees as probes crossed chord vertices.
	assert_lt(rad_to_deg(worst_yaw), 8.0,
			"no single frame rotates the ghost more than a few degrees")
	assert_lt(worst_lateral, 0.6,
			"and no single frame slides it sideways more than a fraction of a metre")

func test_smoothing_never_touches_the_clock() -> void:
	# The load-bearing separation: orientation and lateral offset are filtered, along-track
	# position is NOT — it is the ghost's clock, and lerping it would make the ghost miss the
	# time the standings report.
	var flat := StubTerrain.new()
	var ghost := _ghost_on(flat)
	var offsets: Array = []
	for i in 30:
		var t := float(i) * 0.2
		ghost.pose_at(t, 1.0 / 60.0)
		offsets.append(ghost.rendered_offset_at(t))
	# Re-walk with smoothing effectively off; the arc offsets must be identical.
	Config.data.rival_ghost_position_smoothing_s = 0.0
	Config.data.rival_ghost_rotation_smoothing_s = 0.0
	var ghost2 := _ghost_on(StubTerrain.new())
	for i in 30:
		var t := float(i) * 0.2
		ghost2.pose_at(t, 1.0 / 60.0)
		assert_almost_eq(ghost2.rendered_offset_at(t), float(offsets[i]), 0.0001,
				"arc offset at t=%.1f is unaffected by smoothing" % t)

func test_smoothing_further_damps_the_pose() -> void:
	# The second line of defence, tested separately from the geometry fix above so each is
	# guarded on its own: with the filter on, per-frame rotation is no worse than with it off.
	var dt := 1.0 / 60.0
	var worst := {}
	for smoothing in [0.0, 0.3]:
		Config.data.rival_ghost_rotation_smoothing_s = smoothing
		Config.data.rival_ghost_position_smoothing_s = smoothing
		var ghost := _ghost_on(StubTerrain.new())
		var prev_fwd := Vector3.ZERO
		var started := false
		var peak := 0.0
		for i in 200:
			ghost.pose_at(float(i) * dt, dt)
			var fwd: Vector3 = -ghost.car.global_transform.basis.z
			if started:
				peak = maxf(peak, absf(prev_fwd.signed_angle_to(fwd, Vector3.UP)))
			prev_fwd = fwd
			started = true
		worst[smoothing] = peak
	assert_true(float(worst[0.3]) <= float(worst[0.0]) + 0.001,
			"smoothing does not make per-frame rotation worse")


# --- P1's name floating above the ghost ---------------------------------------------

func test_the_ghost_carries_p1s_name_above_it() -> void:
	Config.data.rival_ghost_nametag_enabled = true
	CarFixtures.install()
	var tp := _progress_on_straight()
	var ghost := GhostCar.new()
	add_child_autofree(ghost)
	ghost.setup(null, tp, null,
			{"car_id": "fx_light_rwd", "engine_id": "", "name": "Ari Vatanen"},
			load(CAR_SCENE), {})
	assert_not_null(ghost._nametag, "a nametag was created")
	assert_eq(ghost._nametag.text, "Ari Vatanen", "showing the rival's name")
	assert_eq(ghost._nametag.billboard, BaseMaterial3D.BILLBOARD_ENABLED,
			"billboarded so it always faces the player")
	assert_gt(ghost._nametag.position.y, 0.5, "and floats above the car")

func test_the_nametag_can_be_switched_off() -> void:
	Config.data.rival_ghost_nametag_enabled = false
	CarFixtures.install()
	var tp := _progress_on_straight()
	var ghost := GhostCar.new()
	add_child_autofree(ghost)
	ghost.setup(null, tp, null,
			{"car_id": "fx_light_rwd", "engine_id": "", "name": "Ari Vatanen"},
			load(CAR_SCENE), {})
	assert_null(ghost._nametag, "no nametag when disabled")

func test_an_unnamed_rival_gets_no_nametag() -> void:
	CarFixtures.install()
	var tp := _progress_on_straight()
	var ghost := GhostCar.new()
	add_child_autofree(ghost)
	ghost.setup(null, tp, null, {"car_id": "fx_light_rwd", "engine_id": "", "name": ""},
			load(CAR_SCENE), {})
	assert_null(ghost._nametag, "an empty name yields no floating blank tag")

func test_the_nametag_fades_with_the_ghost() -> void:
	# Left opaque it would hang in the air over an invisible car as the player overlaps it.
	Config.data.rival_ghost_nametag_enabled = true
	Config.data.rival_ghost_fade_near_m = 12.0
	var flat := StubTerrain.new()
	var ghost := _ghost_on(flat)
	# _ghost_on builds with an empty name, so attach one for this assertion.
	if ghost._nametag == null:
		ghost._add_nametag("Ari Vatanen")
	var player := Node3D.new()
	add_child_autofree(player)
	ghost.player = player
	ghost.pose_at(1.5, 0.016)
	player.global_position = ghost.car.global_position + Vector3(0, 0, 40)
	ghost.pose_at(1.5, 0.016)
	var far_a := ghost._nametag.modulate.a
	player.global_position = ghost.car.global_position
	ghost.pose_at(1.5, 0.016)
	assert_lt(ghost._nametag.modulate.a, far_a,
			"the tag fades as the player closes in, like the car does")


# --- Live tuning, and the two rotational filters ------------------------------------

func test_config_changes_take_effect_without_rebuilding_the_ghost() -> void:
	# These knobs exist to be tuned by eye. Caching them at setup() meant a change did
	# nothing until the next stage spawned a fresh ghost, which makes that loop useless.
	var ghost := _ghost_on(StubTerrain.new())
	Config.data.rival_ghost_position_smoothing_s = 0.0   # so changes apply immediately
	Config.data.rival_ghost_line_offset_m = 0.0
	ghost.pose_at(3.0, 0.016)
	var centred: Vector3 = ghost.car.global_position
	Config.data.rival_ghost_line_offset_m = 3.0
	ghost.pose_at(3.0, 0.016)
	var offset: Vector3 = ghost.car.global_position
	assert_gt(centred.distance_to(offset), 0.2,
			"raising the line offset moves the LIVE ghost, with no respawn")

func test_rotation_is_only_unfiltered_when_both_constants_are_zero() -> void:
	# The trap that prompted this: rival_ghost_rotation_smoothing_s is not the only
	# rotational filter, because slip angle is a yaw folded into the same basis.
	Config.data.rival_ghost_rotation_smoothing_s = 0.0
	Config.data.gravel_slip_peak = 0.35
	Config.data.tarmac_slip_peak = 0.35
	Config.data.rival_ghost_slip_scale = 1.0

	# Slip lag ON: re-posing at the SAME time still moves the yaw, because slip is mid-lerp.
	Config.data.rival_ghost_slip_lag_s = 0.6
	var lagged := _yaw_settle_error(_ghost_on(StubTerrain.new()))

	# Both zero: the pose fully settles in one frame.
	Config.data.rival_ghost_slip_lag_s = 0.0
	var unfiltered := _yaw_settle_error(_ghost_on(StubTerrain.new()))

	assert_almost_eq(unfiltered, 0.0, 0.0005,
			"with BOTH constants zero the pose settles in a single frame")
	assert_gt(lagged, unfiltered + 0.0005,
			"slip lag alone still filters rotation after the rotation constant is zeroed")

# How much the yaw still moves when the SAME timestamp is posed twice — zero once every
# filter has settled, non-zero while any of them is still converging.
func _yaw_settle_error(ghost: GhostCar) -> float:
	ghost.pose_at(4.0, 0.016)
	var a: Vector3 = -ghost.car.global_transform.basis.z
	ghost.pose_at(4.0, 0.016)
	var b: Vector3 = -ghost.car.global_transform.basis.z
	return absf(a.signed_angle_to(b, Vector3.UP))


# --- Slip DIRECTION: the nose must point into the corner -----------------------------

# Signed angle from the path tangent to the car's nose, about world up. Positive and
# negative here just mean "yawed one way or the other" — the test compares it against the
# turn's own sign rather than asserting an absolute direction.
func _nose_offset_from_tangent(ghost: GhostCar, t: float) -> float:
	# Local tangent, measured in ARC LENGTH either side of the car. An earlier version used
	# +/-1 SECOND of travel, which at rally speed is +/-30 m — a chord across the whole
	# corner, not the direction the car is pointing along, and it disagreed with the turn
	# measurement near curvature transitions.
	var here := ghost.rendered_offset_at(t)
	var p0: Vector2 = ghost.progress.sample_at(here - 2.0)
	var p1: Vector2 = ghost.progress.sample_at(here + 2.0)
	var tangent := Vector3(p1.x - p0.x, 0.0, p1.y - p0.y)
	if tangent.length() < 0.001:
		return 0.0
	var nose: Vector3 = -ghost.car.global_transform.basis.z
	nose.y = 0.0
	return tangent.normalized().signed_angle_to(nose.normalized(), Vector3.UP)

# Which way the road itself turns at t, in the same signed-angle convention.
func _turn_direction(ghost: GhostCar, t: float) -> float:
	var here := ghost.rendered_offset_at(t)
	var a: Vector2 = ghost.progress.sample_at(here - 20.0)
	var b: Vector2 = ghost.progress.sample_at(here)
	var c: Vector2 = ghost.progress.sample_at(here + 20.0)
	var v1 := Vector3(b.x - a.x, 0.0, b.y - a.y)
	var v2 := Vector3(c.x - b.x, 0.0, c.y - b.y)
	if v1.length() < 0.001 or v2.length() < 0.001:
		return 0.0
	return v1.normalized().signed_angle_to(v2.normalized(), Vector3.UP)

func test_the_ghost_yaws_INTO_the_corner_not_out_of_it() -> void:
	# A rally car slides with its nose pointed INSIDE the bend. Getting this backwards makes
	# the ghost look like it is counter-steering out of every corner.
	#
	# The 2D curve space is Vector2(world_x, world_z), so its angles are atan2(z, x) — and
	# Basis(Vector3.UP, +angle) rotates +Z toward +X, which DECREASES that 2D angle. A yaw
	# taken straight from the 2D curvature sign therefore turns the car the wrong way.
	Config.data.rival_ghost_rotation_smoothing_s = 0.0
	Config.data.rival_ghost_slip_lag_s = 0.0
	Config.data.gravel_slip_peak = 0.35
	Config.data.tarmac_slip_peak = 0.35
	Config.data.rival_ghost_slip_scale = 1.0
	Config.data.rival_ghost_line_offset_m = 0.0     # isolate rotation from lateral placement
	var ghost := _ghost_on(StubTerrain.new())
	var checked := 0
	for i in 12:
		var t := 2.0 + float(i) * 1.5
		var turn := _turn_direction(ghost, t)
		if absf(turn) < 0.02:
			continue                                 # too straight to have a meaningful side
		ghost.pose_at(t, 0.016)
		var nose := _nose_offset_from_tangent(ghost, t)
		if absf(nose) < 0.005:
			continue                                 # no slip developed here
		checked += 1
		assert_eq(signf(nose), signf(turn),
				"at t=%.1f the nose yaws the same way the road turns (into the corner)" % t)
	assert_gt(checked, 0, "the sweep found corners with slip to check")
