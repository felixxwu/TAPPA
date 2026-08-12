extends "res://tests/headless/sim_test.gd"
# Grip-servo steering (see todo/grip-servo-steering.md).
#
# Steering input is no longer a wheel angle — it is the share of the FRONT TIRES' available
# cornering grip the driver is asking for, and car.gd `_update_steering` servos the wheel
# angle until the tires actually deliver it. These tests assert the behaviour that must hold
# for ANY tuning of steer_limit / steer_speed / the surface slip curve; they never pin a
# tuned number (see CLAUDE.md).
#
# `_scene`, `_car`, `_wait_physics()` and the settle machinery come from sim_test.gd.

# car.gd carries no class_name, so reach the pure statics through the script itself.
const CarScript := preload("res://scripts/car.gd")

# What share of the front axle's available longitudinal grip the simulated climb consumes
# (see _climb_and_read). Below 1.0 so the car can actually climb; high enough that the axle
# is deep into its longitudinal budget before the drive torque saturates it.
const GRADE_FRACTION_OF_GRIP := 0.6


func before_each() -> void:
	await setup_settled_car()
	_car.drivetrain.engine.auto = false
	_car.drivetrain.drive_mode = Drivetrain.DriveMode.RWD


func after_each() -> void:
	# Derived from the production list, not hand-copied: releasing the whole
	# rebindable set can't silently desync when an action is added or renamed.
	for entry in InputRemap.ACTIONS:
		Input.action_release(String(entry["action"]))
	CarFixtures.restore()
	UpgradeLibrary.reset()


# Load-weighted front-axle grip usage: how much of its peak the steering axle is using,
# read the same way the debug grip grid reads it.
func _front_usage() -> float:
	var total := 0.0
	var weight := 0.0
	for c in _car.drivetrain._contacts:
		if c.wheel.use_as_traction or c.n_force <= 0.0:
			continue
		total += c.slip_use * c.n_force
		weight += c.n_force
	return total / weight if weight > 0.0 else 0.0


# Hold `speed` (re-asserted every tick, so drag and scrub can't bleed it off) while holding
# `action` (pass "" for none), then report the settled front-axle grip usage. Tests needing a
# different axle-state field call front_axle_state(Config.data) directly.
func _hold_and_read(action: String, speed: float, frames: int) -> float:
	if action != "":
		Input.action_press(action)
	for i in frames:
		_car.linear_velocity = -_car.global_transform.basis.z * speed
		await get_tree().physics_frame
	var usage := _front_usage()
	if action != "":
		Input.action_release(action)
	return usage


func test_full_input_drives_the_front_tires_to_their_limit() -> void:
	# THE regression test for this work. The system this replaced predicted the grip limit
	# open-loop and left the fronts at ~80% of peak while the player asked for everything,
	# which reads as understeer with grip in reserve. The servo must converge on the real
	# limit, so full lock has to land at ~100% of peak — not short of it.
	var usage := await _hold_and_read("steer_left", 20.0, 45)
	assert_gt(usage, 0.9, "full steering input works the front tires to ~their peak (got %.2f)" % usage)


func test_half_input_uses_less_grip_than_full_input() -> void:
	# Proportionality: the input is a demand on the tires, so a partial ask must settle
	# measurably lower. An ordering assertion, not a pinned pair of numbers — the AI axis
	# gives a clean 0.5 where a key can only be held or released.
	_car.ai_controlled = true
	_car.ai_steer = 0.5
	var half := await _hold_and_read("", 20.0, 45)
	_car.ai_steer = 1.0
	var full := await _hold_and_read("", 20.0, 45)
	_car.ai_steer = 0.0
	_car.ai_controlled = false
	assert_lt(half, full,
		"half the demand uses less of the front grip than full (%.2f vs %.2f)" % [half, full])


func test_zero_input_points_the_fronts_along_their_travel() -> void:
	# The zero point: with no demand the wheels servo to the angle where the front tires do no
	# sideways work, which is what makes countersteer automatic.
	#
	# Asserted as a RELATIONSHIP (released < held), not against an absolute slip figure. An
	# earlier version pinned `< 0.06` and a `steer_speed` retune broke it — exactly the
	# tunable-sensitivity CLAUDE.md warns about, since how far the servo gets in a fixed window
	# depends on the rate limit. Deliberately the LATERAL component, not the combined slip,
	# which a driven axle never zeroes.
	# Steer AWAY from the travel direction for the contrast case. Holding INTO a forward-left
	# slide is not a contrast at all: steering left also points the wheels toward their travel,
	# so it lands in the same place as releasing and the comparison measures nothing.
	var against := await _slide_lateral_slip("steer_right")
	var released := await _slide_lateral_slip("")
	assert_lt(released, against,
		"releasing seeks the null; steering away from travel does not (%.3f vs %.3f)"
			% [released, against])


# Front lateral slip after a fixed 40-tick forward-left slide, optionally holding `action`.
# Resets to the spawn pose first so both runs start identical — comparing two PHASES of one
# run instead would measure the yaw the car accumulated, not what the servo did.
func _slide_lateral_slip(action: String) -> float:
	_car._reset()  # reset is menu-only now (no input action); call the logic directly
	await _wait_physics(120)
	# A SHALLOW slide (~15 deg), deliberately. At 45 deg the zero-lateral-slip angle is outside
	# steer_limit, so the servo pins the wheels at the stop and steering input cannot move them
	# to either side of the null — both runs then read identically and the test proves nothing.
	# Shallow enough that the null is reachable, the input has somewhere to go.
	var slide := (-_car.global_transform.basis.z
		- _car.global_transform.basis.x * 0.27).normalized()
	if action != "":
		Input.action_press(action)
	for i in 40:
		_car.linear_velocity = slide * 18.0
		await get_tree().physics_frame
	if action != "":
		Input.action_release(action)
	return absf(float(_car.drivetrain.front_axle_state(Config.data)["slip_lat_norm"]))


func test_standstill_full_input_reaches_the_mechanical_stop() -> void:
	# Nothing is moving, so the tires generate no slip whatever the wheels do; the servo is
	# permanently under target and integrates out to the mechanical stop. This is what
	# replaces the old low-speed steer-lock blend — parking-speed bite with no exception.
	var cfg: GameConfig = Config.data
	Input.action_press("steer_left")
	await _wait_physics(90)
	Input.action_release("steer_left")
	assert_almost_eq(_car.steering, cfg.steer_limit, cfg.steer_limit * 0.1,
		"at a standstill full input servos out to the mechanical steer limit")


func test_released_wheels_centre_themselves_at_a_standstill() -> void:
	# "Point along the direction of travel" has no answer at rest, and the degenerate one is
	# a fixed point — atan2(0, 0) is 0, so the null equals the current angle and the wheels
	# would stay cocked wherever the player left them. Below tire_norm_floor the null fades
	# toward straight ahead, so releasing the wheel parked returns it to centre.
	Input.action_press("steer_left")
	await _wait_physics(90)
	Input.action_release("steer_left")
	assert_gt(_car.steering, 0.1, "precondition: the wheels are turned before release")
	await _wait_physics(120)
	assert_almost_eq(_car.steering, 0.0, 0.05,
		"released at a standstill, the wheels return to centre (got %.3f)" % _car.steering)


func test_centring_does_not_stop_standstill_input_reaching_lock() -> void:
	# The at-rest centring is confined to the zero-input branch on purpose. If it also pinned
	# the null while a demand was held, the offset would converge on one slip_peak of angle
	# instead of integrating out to the mechanical stop — so guard the two behaviours
	# together, since the fix for one can silently break the other.
	var cfg: GameConfig = Config.data
	Input.action_press("steer_right")
	await _wait_physics(90)
	Input.action_release("steer_right")
	assert_almost_eq(_car.steering, -cfg.steer_limit, cfg.steer_limit * 0.1,
		"held input at a standstill still walks to the stop despite the centring blend")


func test_steering_never_exceeds_the_mechanical_limit() -> void:
	# The clamp is the only hard bound left in the system, so nothing — including the
	# integrating behaviour at standstill — may walk past it.
	var cfg: GameConfig = Config.data
	for action in ["steer_left", "steer_right"]:
		Input.action_press(action)
		await _wait_physics(90)
		Input.action_release(action)
		assert_lte(absf(_car.steering), cfg.steer_limit + 0.001,
			"%s never drives the wheels past steer_limit" % action)
		await _wait_physics(30)


func test_the_car_still_turns_while_braking_hard() -> void:
	# Braking and cornering share one friction budget, and on a keyboard both inputs are
	# all-or-nothing. Without demand sharing a pinned brake spends the whole budget
	# longitudinally, the servo sees no lateral grip available and points the wheels
	# straight, and the car cannot turn in at all. It must still turn.
	_car.drivetrain.engine.gear = 1
	_car.linear_velocity = -_car.global_transform.basis.z * 20.0
	_car.angular_velocity = Vector3.ZERO
	Input.action_press("brake_reverse")  # manual, forward gear: S is the foot brake
	Input.action_press("steer_left")
	await _wait_physics(40)
	var yaw_rate := _car.angular_velocity.dot(_car.global_transform.basis.y)
	Input.action_release("steer_left")
	Input.action_release("brake_reverse")
	assert_gt(yaw_rate, 0.05,
		"full brake + full left still rotates the car left (yaw %.3f rad/s)" % yaw_rate)


func test_braking_to_a_stop_while_steering_still_anchors_the_car() -> void:
	# The grip arbitration scales the brake down when the player also steers, which must NOT
	# cost the stiction hold: it asks "should a stationary car be anchored", and the
	# arbitration only frees CORNERING grip on a MOVING car. Reading the post-scale brake here
	# let a player holding brake + steering at a standstill creep down a slope.
	_car.drivetrain.engine.gear = 1
	Input.action_press("brake_reverse")
	Input.action_press("steer_left")
	await _wait_physics(30)
	var resting := _car.global_position
	await _wait_physics(60)
	var drift := (_car.global_position - resting)
	drift.y = 0.0
	Input.action_release("steer_left")
	Input.action_release("brake_reverse")
	assert_lt(drift.length(), 0.25,
		"brake + steering at a standstill holds position (drifted %.3f m)" % drift.length())


func test_steering_does_not_run_a_driven_front_axle_further_past_peak() -> void:
	# Driving the front axle costs cornering, emergently: lateral_grip_share normalises the
	# lateral ask against the MEASURED longitudinal spend, so a spinning front axle gets less
	# steering than a rolling one.
	#
	# The claim is deliberately RELATIVE — steering must not drive the axle meaningfully
	# further past peak than the drive alone already does. An absolute ceiling looks tighter
	# and is not: in first gear at full throttle this fixture's fronts reach long_used ~1.4
	# with the wheels dead straight, so an absolute bound low enough to be interesting is
	# really asserting that the throttle bled off, and it passes for the wrong reason. What
	# must not happen is a SPIRAL — lateral ask feeding wheelspin feeding more ask.
	var cfg: GameConfig = Config.data
	_car.drivetrain.drive_mode = Drivetrain.DriveMode.FWD
	_car.drivetrain.engine.gear = 1
	# Deliberately NOT speed-pinned: forcing linear_velocity every tick holds the drivetrain at
	# equilibrium, so the driven wheels never develop the longitudinal slip this test is about.
	# Let it accelerate for real.
	_car.linear_velocity = -_car.global_transform.basis.z * 12.0
	Input.action_press("accelerate")
	await _wait_physics(45)
	var straight_usage := _front_usage()
	Input.action_release("accelerate")
	# Same manoeuvre, now steering as well. Re-settle first so both runs start alike.
	await setup_settled_car()
	_car.drivetrain.engine.auto = false
	_car.drivetrain.drive_mode = Drivetrain.DriveMode.FWD
	_car.drivetrain.engine.gear = 1
	_car.linear_velocity = -_car.global_transform.basis.z * 12.0
	Input.action_press("accelerate")
	Input.action_press("steer_left")
	await _wait_physics(45)
	var steered_usage := _front_usage()
	var state: Dictionary = _car.drivetrain.front_axle_state(Config.data)
	var long_slip := absf(float(state["slip_long_norm"]))
	var lat_used := absf(float(state["lat_used"]))
	Input.action_release("steer_left")
	Input.action_release("accelerate")
	# Preconditions: the drive really is spending front grip, and the steering really did get
	# some cornering out of it — otherwise the comparison proves nothing.
	assert_gt(long_slip, 0.001,
		"precondition: a driven front axle shows longitudinal slip (%.4f)" % long_slip)
	assert_gt(lat_used, 0.1,
		"precondition: the servo got real cornering grip out of the driven axle (%.2f)" % lat_used)
	assert_lt(steered_usage, straight_usage * 1.5,
		"steering adds cornering without spiralling the fronts further past peak (%.2f vs %.2f straight)"
			% [steered_usage, straight_usage])
	assert_gt(cfg.traction_ellipse_ratio, 0.0, "the ellipse weighting is live")


func test_steering_gives_a_driven_front_axle_something_to_work_with() -> void:
	# Reported from driving: under hard FWD acceleration the wheels barely turned, because the
	# drive had spent the whole front budget and the servo correctly found no cornering grip
	# left. The throttle now gives way on a DRIVEN steered axle exactly as the brake does, so
	# full power plus full steering must still produce a real wheel angle.
	var cfg: GameConfig = Config.data
	_car.drivetrain.drive_mode = Drivetrain.DriveMode.FWD
	_car.drivetrain.engine.gear = 1
	Input.action_press("accelerate")
	Input.action_press("steer_left")
	for i in 45:
		_car.linear_velocity = -_car.global_transform.basis.z * 12.0
		await get_tree().physics_frame
	var angle := _car.steering
	Input.action_release("steer_left")
	Input.action_release("accelerate")
	assert_gt(angle, cfg.steer_limit * 0.15,
		"full throttle on FWD still leaves a real steering angle (%.3f rad)" % angle)


func test_rwd_throttle_does_not_give_way_to_steering() -> void:
	# The asymmetry is deliberate: on RWD the front tires never drive, so the throttle cannot
	# take cornering grip from them and must keep full authority — power-oversteer behaviour is
	# untouched by the arbitration.
	assert_false(_car.drivetrain.front_axle_driven(), "the fixture is RWD by default here")
	_car.drivetrain.drive_mode = Drivetrain.DriveMode.FWD
	assert_true(_car.drivetrain.front_axle_driven(), "FWD drives the steered axle")
	_car.drivetrain.drive_mode = Drivetrain.DriveMode.AWD
	assert_true(_car.drivetrain.front_axle_driven(), "AWD drives the steered axle too")


func test_braking_alone_is_not_taxed_by_the_arbitration() -> void:
	# Straight-line braking must reach the drivetrain at full strength: the arbitration exists
	# to free cornering grip, so with no steering demand it must be a no-op. Goes through
	# _resolve_drive_inputs rather than the pure static, so it guards the WIRING.
	_car.drivetrain.engine.gear = 1
	_car.linear_velocity = -_car.global_transform.basis.z * 20.0
	Input.action_press("brake_reverse")
	await _wait_physics(2)
	var inputs: Dictionary = _car._resolve_drive_inputs(_car.drivetrain.engine, 20.0, 0.0)
	var brake_alone: float = inputs["brake_input"]
	# Same pedal, now with full steering demand: the brake must give ground.
	var shared: Dictionary = _car._resolve_drive_inputs(_car.drivetrain.engine, 20.0, 1.0)
	var brake_shared: float = shared["brake_input"]
	Input.action_release("brake_reverse")
	assert_almost_eq(brake_alone, 1.0, 1e-5, "brake with no steering reaches full strength")
	assert_lt(brake_shared, brake_alone,
		"the same pedal gives ground once steering competes (%.2f vs %.2f)"
			% [brake_shared, brake_alone])


func test_a_synthesized_hold_is_never_bled_off_by_steering() -> void:
	# The parking brake and the finish stop are holds, not pedal demands — steering must not
	# scale them, or the car creeps down a slope the moment the player turns the wheel. At rest
	# with no pedal input, _resolve_drive_inputs synthesizes the parking brake.
	var inputs: Dictionary = _car._resolve_drive_inputs(_car.drivetrain.engine, 0.0, 1.0)
	assert_almost_eq(float(inputs["brake_input"]), 1.0, 1e-5,
		"the parking hold survives full steering demand intact")
	assert_true(bool(inputs["pinned"]), "and still reports the axle as pinned")


func test_airborne_fronts_fall_back_to_direct_input() -> void:
	# With no front contact there is nothing to servo on. Holding the last angle would
	# freeze the wheels mid-jump, which reads as a bug, so the input maps straight through.
	var cfg: GameConfig = Config.data
	_car.global_position += Vector3.UP * 8.0
	_car.linear_velocity = Vector3.UP * 4.0
	await _wait_physics(2)
	Input.action_press("steer_left")
	await _wait_physics(12)
	Input.action_release("steer_left")
	assert_gt(_car.steering, 0.1, "airborne, steering input still moves the wheels")
	assert_lte(_car.steering, cfg.steer_limit + 0.001, "and still respects the stop")


# --- The step shape, where the loop's stability actually lives -----------------
# Deliberately NOT a driving "does it oscillate" test: that would key off steer_speed, which
# is a tuning value (the test fixture leaves it at the script default while the game sets it
# in game_config.tres), so retuning the rate would break the test. See CLAUDE.md.

func test_the_servo_step_is_proportional_to_the_error() -> void:
	# Proportionality is what stops the loop dithering at the setpoint: as the error shrinks
	# the correction shrinks with it, instead of stepping a fixed amount and ringing.
	var big := CarScript.grip_servo_step(0.4, 0.15)
	var small := CarScript.grip_servo_step(0.1, 0.15)
	assert_gt(big, small, "a larger usage error takes a larger step")
	assert_almost_eq(small * 4.0, big, 1e-6, "and the step scales linearly with the error")


func test_the_servo_step_is_zero_at_the_setpoint() -> void:
	# The fixed point: on target, the wheels stop moving.
	assert_eq(CarScript.grip_servo_step(0.0, 0.15), 0.0, "no error means no correction")


func test_the_servo_step_reverses_when_overshooting() -> void:
	# Past the setpoint the correction must pull back, which is what makes 100% a stable
	# ceiling rather than something the loop blows through.
	assert_lt(CarScript.grip_servo_step(-0.2, 0.15), 0.0,
		"using more grip than asked for steers back toward the null")


func test_the_servo_step_scales_with_the_surface() -> void:
	# The step converts a usage error into radians using the surface's own slip_peak, which is
	# what makes the loop self-tuning: a looser surface peaks at a bigger slip angle, so the
	# same proportional error is a bigger angle there. This is why there is no gain knob.
	var tarmac_like := CarScript.grip_servo_step(0.3, 0.15)
	var gravel_like := CarScript.grip_servo_step(0.3, 0.31)
	assert_gt(gravel_like, tarmac_like,
		"the same usage error is a larger angle on a surface that peaks at more slip")


# --- Reverse and past-90 slip: the null must stay the NEARER solution ----------
# These guard the hole that shipped once: lateral slip is zero whenever the velocity is
# parallel to the wheel, and a plain atan2(s_lat, v_long) only finds the FORWARD solution.

func _primed_contact(v_long: float, s_lat: float) -> Drivetrain.WheelContact:
	var c := Drivetrain.WheelContact.new()
	c.v_long = v_long
	c.s_lat = s_lat
	c.slip_peak = 0.15
	c.slide_ratio = 0.6
	_car.drivetrain.prime_contact_slip(Config.data, c)
	return c


func test_reversing_straight_reports_no_slip_angle() -> void:
	# Backing up in a straight line: the patch runs backward ALONG the wheel, so lateral slip
	# is already zero and the null must be the current angle. A forward-only atan2 reports
	# ~PI here, which would swing the wheels to full lock in a direction set by the sign of a
	# near-zero lateral term.
	var backward := _primed_contact(-10.0, 0.0)
	assert_almost_eq(backward.slip_angle, 0.0, 1e-5,
		"reversing straight needs no steering correction")
	var forward := _primed_contact(10.0, 0.0)
	assert_almost_eq(forward.slip_angle, 0.0, 1e-5, "and neither does going straight forward")


func test_reversing_while_sliding_corrects_the_nearer_way() -> void:
	# Reversing with the patch running back-and-left, the wheel must turn to lie ALONG that
	# line — which is the near side, not most of a half turn away. Sign and magnitude both
	# matter: the forward-only form gives +3PI/4 (hard the wrong way) where the answer is
	# -PI/4.
	var c := _primed_contact(-10.0, 10.0)
	assert_almost_eq(c.slip_angle, -PI / 4.0, 1e-5,
		"reversing back-left corrects a quarter turn the other way, not three quarters")
	# The forward case is the mirror, and must be unchanged by the sign handling.
	var fwd := _primed_contact(10.0, 10.0)
	assert_almost_eq(fwd.slip_angle, PI / 4.0, 1e-5, "going forward is untouched")


func test_the_slip_angle_never_asks_for_more_than_a_quarter_turn() -> void:
	# Whatever the velocity, the null is the NEARER of the two zero-lateral-slip solutions, so
	# the correction can never exceed 90 degrees — which is what keeps it inside any sane
	# steer_limit instead of pinning the stop.
	for v_long in [-20.0, -5.0, -0.5, 0.0, 0.5, 5.0, 20.0]:
		for s_lat in [-20.0, -1.0, 0.0, 1.0, 20.0]:
			var c := _primed_contact(v_long, s_lat)
			assert_lte(absf(c.slip_angle), PI / 2.0 + 1e-6,
				"slip angle for (v_long %.1f, s_lat %.1f) stays within a quarter turn"
					% [v_long, s_lat])


func test_a_purely_sideways_patch_asks_for_no_correction() -> void:
	# No wheel angle can zero the lateral slip of a patch moving straight sideways, so the
	# honest answer is "no correction" rather than a 90-degree lunge at the stop.
	var c := _primed_contact(0.0, 10.0)
	assert_almost_eq(c.slip_angle, 0.0, 1e-5, "sideways-only slip asks for nothing")


func test_reversing_does_not_swing_the_wheels_to_lock() -> void:
	# End to end, the behaviour the unit tests above protect: rolling backwards with no
	# steering input must leave the wheels near centre.
	var cfg: GameConfig = Config.data
	for i in 40:
		_car.linear_velocity = _car.global_transform.basis.z * 6.0  # +Z is backwards
		await get_tree().physics_frame
	assert_lt(absf(_car.steering), cfg.steer_limit * 0.35,
		"reversing with no input keeps the wheels near centre (%.3f rad)" % _car.steering)


# --- The longitudinal/lateral demand split (pure logic, no car needed) ---------

func test_a_single_demand_is_left_untouched() -> void:
	# One input alone is inside the circle, so nothing is scaled — braking or accelerating in
	# a straight line must not be taxed by an arbitration meant for combined inputs.
	assert_eq(CarScript.longitudinal_demand_scale(1.0, 0.0), 1.0, "full pedal, no steering")
	assert_eq(CarScript.longitudinal_demand_scale(0.0, 1.0), 1.0, "full steering, no pedal")
	assert_eq(CarScript.longitudinal_demand_scale(0.0, 0.0), 1.0, "no input at all")
	assert_eq(CarScript.longitudinal_demand_scale(0.5, 0.5), 1.0,
		"a pair inside the circle is left alone")


func test_two_pinned_demands_scale_onto_the_circle() -> void:
	# Both pinned must land ON the friction circle rather than letting the pedal claim the lot,
	# which is what leaves the steering something to work with.
	var scale := CarScript.longitudinal_demand_scale(1.0, 1.0)
	assert_lt(scale, 1.0, "the pedal gives up part of the budget so the car can still turn")
	# The scale is exactly the reciprocal of how far outside the circle the pair sat. Note the
	# (scaled_long, raw_steer) pair is deliberately NOT on the circle: only the longitudinal
	# side is scaled here, because the servo's own lateral_grip_share normalises the lateral
	# side against the MEASURED spend and scaling both would double-count. See
	# Car.longitudinal_demand_scale.
	assert_almost_eq(Vector2(1.0, 1.0).length() * scale, 1.0, 1e-5,
		"the scale is 1 / |(long, steer)|")


func test_the_scale_never_amplifies() -> void:
	# It is a reduction only: a demand pair inside the circle must never be scaled UP into it,
	# or a light touch on the pedal would become a heavier one.
	for long_demand in [0.0, 0.1, 0.5, 0.9, 1.0]:
		for steer in [0.0, 0.1, 0.5, 0.9, 1.0]:
			assert_lte(CarScript.longitudinal_demand_scale(long_demand, steer), 1.0,
				"scale(%.1f, %.1f) never exceeds 1" % [long_demand, steer])


func test_more_steering_takes_more_from_the_pedal() -> void:
	# Monotonic: the harder the player steers, the more longitudinal effort gives way. This is
	# what makes trail braking (and lifting out of a corner on FWD) emerge rather than being
	# scripted as a special case.
	var light := CarScript.longitudinal_demand_scale(1.0, 0.3)
	var heavy := CarScript.longitudinal_demand_scale(1.0, 1.0)
	assert_lt(heavy, light, "more steering demand leaves the pedal less of the budget")


# --- How much of the circle the lateral side may claim -------------------------

func test_the_lateral_share_is_untouched_when_the_circle_has_room() -> void:
	# Nothing is being spent longitudinally, so the driver gets exactly what they asked for —
	# the free-rolling case must not be taxed by machinery meant for a competing spend.
	assert_almost_eq(CarScript.lateral_grip_share(1.0, 0.0), 1.0, 1e-5, "full ask, nothing spent")
	assert_almost_eq(CarScript.lateral_grip_share(0.4, 0.5), 0.4, 1e-5,
		"a pair inside the circle is left alone")
	assert_almost_eq(CarScript.lateral_grip_share(0.0, 1.0), 0.0, 1e-5, "no ask, no share")


func test_the_lateral_share_never_collapses_however_much_grip_is_spent() -> void:
	# THE regression test for the FWD/AWD uphill trap. When the world (a climb, a slick
	# surface) rather than the pedal sets the longitudinal spend, the front axle can be at or
	# past peak longitudinally while the player is still asking to turn. Treating that spend as
	# a reservation zeroed the setpoint, so the servo drove the wheels to the null and the car
	# could not be steered out of a deviation in EITHER direction. The share must stay
	# meaningful at any spend — 1/sqrt(2) of the ask is the circle-splitting floor.
	var floor_share := 1.0 / sqrt(2.0)
	for spent in [0.9, 1.0, 1.5, 5.0]:
		var share := CarScript.lateral_grip_share(1.0, spent)
		assert_gte(share, floor_share - 1e-5,
			"a full ask keeps at least a 1/sqrt(2) share at long_used %.1f (got %.3f)"
				% [spent, share])
	# And it holds for a partial ask too — proportionally, not as a flat floor.
	assert_gte(CarScript.lateral_grip_share(0.5, 3.0), 0.5 * floor_share - 1e-5,
		"a half ask keeps at least half of that floor")


func test_spending_more_grip_leaves_less_for_cornering() -> void:
	# The trade still has to BE a trade: power understeer stays emergent. More longitudinal
	# spend must reduce the share, monotonically, right up to the floor.
	var light := CarScript.lateral_grip_share(1.0, 0.2)
	var heavy := CarScript.lateral_grip_share(1.0, 0.8)
	var saturated := CarScript.lateral_grip_share(1.0, 1.0)
	assert_lt(heavy, light, "more spend leaves less cornering share")
	assert_lt(saturated, heavy, "a saturated axle leaves less again")


func test_the_lateral_share_never_amplifies_the_ask() -> void:
	# A reduction only — the servo may never be told to ask for more grip than the driver did,
	# or a light steering input would become a heavy one.
	for ask in [0.0, 0.25, 0.5, 1.0]:
		for spent in [0.0, 0.3, 1.0, 4.0]:
			assert_lte(CarScript.lateral_grip_share(ask, spent), ask + 1e-6,
				"share(%.2f, %.1f) never exceeds the ask" % [ask, spent])


func test_the_lateral_share_ignores_the_sign_of_the_spend() -> void:
	# long_used is a magnitude of spend: braking and driving compete for the same grip, so a
	# negative reading (however a caller signs it) must cost the same as a positive one.
	assert_almost_eq(CarScript.lateral_grip_share(1.0, -0.9),
		CarScript.lateral_grip_share(1.0, 0.9), 1e-6, "spend competes by magnitude, not sign")


# The longitudinal force the front (steering) axle can currently hold: Σ μN over its
# contacts. Read from the live contacts rather than computed from the config, so it accounts
# for the real normal load — which is the whole point below.
#
# Discriminates the axle by `use_as_steering`, NOT by `use_as_traction` the way `_front_usage`
# does: this test runs in FWD, where the front wheels ARE the traction wheels, so the
# traction flag would select the wrong axle (or none).
func _front_axle_grip_n() -> float:
	var total := 0.0
	for c in _car.drivetrain._contacts:
		if not c.wheel.use_as_steering or c.n_force <= 0.0:
			continue
		total += c.n_force * c.mu
	return total


# One graded-climb run holding `steer`: reports the front axle's longitudinal spend, the
# angle the servo held, the yaw it produced and the speed the car actually reached.
#
# Resets to the cached settled pose first (not `_reset()`, which drops from the spawn
# clearance and needs ~120 frames to settle) so the two mirrored runs below start identical.
func _climb_and_read(steer: String) -> Dictionary:
	_car.reset_to(_settled_xform)
	await _wait_physics(RESTORE_FRAMES)
	_car.drivetrain.drive_mode = Drivetrain.DriveMode.FWD
	_car.drivetrain.engine.gear = 1
	# THE GRADE IS DERIVED FROM THE AXLE'S OWN GRIP, NOT PINNED AT A FRACTION OF g.
	#
	# This used to be `mass * 9.8 * 0.34` — "~20 degrees of climb" — and that is a grade a
	# front-driven car on this surface CANNOT CLIMB. Its front axle holds
	# μ · weight_front · load ≈ 0.5 · 0.5 · mg = 0.25 mg, against 0.34 mg of grade: the tyres
	# lose, so the car spins its wheels and stays put. It only ever passed because the warm
	# restore left the car with ~40% MORE wheel load than its own weight (measured: nf/mg =
	# 1.404 when passing, 1.008 when failing), which lifted available grip to 0.351 mg — a 3%
	# margin over the grade. So the test was riding on an incidental suspension state, and
	# whenever the car settled to its correct static load it could not climb at all. That is
	# the flake: not noise, and not something a harness fix can rescue, because at 0.34 mg the
	# scenario is beyond the traction limit by construction.
	#
	# Taking a FRACTION of the measured grip keeps the climb inside what the tyres can hold
	# for ANY tuning of μ / weight_front / suspension — the relationship the file's header
	# asks for instead of a pinned number — while still spending most of the axle
	# longitudinally, which is the trap being tested. The drive torque then saturates it the
	# rest of the way (`spent` lands well past 1.0 either way).
	var grade_force := _front_axle_grip_n() * GRADE_FRACTION_OF_GRIP
	Input.action_press("accelerate")
	Input.action_press(steer)
	for i in 60:
		_car.constant_force = _car.global_transform.basis.z * grade_force
		await get_tree().physics_frame
	var out := {
		"spent": absf(float(_car.drivetrain.front_axle_state(Config.data)["long_used"])),
		"angle": _car.steering,
		"yaw": _car.angular_velocity.y,
		"speed": _car.linear_velocity.length(),
	}
	Input.action_release(steer)
	Input.action_release("accelerate")
	_car.constant_force = Vector3.ZERO
	return out


func test_a_climbing_front_driven_car_can_still_be_steered() -> void:
	# The same trap end-to-end, through the real servo and tire model. A constant force
	# opposing travel stands in for gravity down a slope (the fixture is flat), which is what
	# makes this specifically a WORLD-imposed longitudinal spend: the pedal arbitration cannot
	# bound it, so the old reservation reading zeroed the steering authority.
	#
	# RUN MIRRORED, and check the car MOVED. This used to be a single left-hand run whose last
	# assertion was a bare `yaw > 0`, and it flaked — because the grade it drove against was
	# steeper than the front tires could hold (see _climb_and_read), so the car was often not
	# climbing at all. A stationary car makes no lateral force — normalized slip is zero at
	# zero ground speed — so the yaw read ~1e-10 and the sign check failed on noise, while the
	# spend and angle assertions passed and said nothing was wrong.
	#
	# Both halves of that are fixed here. The grade is now derived from the axle's own grip so
	# the climb is achievable; the SPEED precondition names a stalled car outright instead of
	# letting it masquerade as a steering bug; and mirroring the run replaces "yaw is positive"
	# with "yaw follows the side the driver asked for", which is the actual claim and cannot be
	# satisfied by a car that merely drifts one way.
	var cfg: GameConfig = Config.data
	var left := await _climb_and_read("steer_left")
	var right := await _climb_and_read("steer_right")
	# Preconditions: the climb really has the front axle spending most of its grip, and the
	# car really is climbing rather than sitting still, or this proves nothing about the trap.
	assert_gt(float(left["spent"]), 0.9,
		"precondition: the graded climb has the driven front axle at/past peak longitudinally (%.2f)"
			% left["spent"])
	assert_gt(float(left["speed"]), 0.05,
		"precondition: the car is actually under way, so its tires can make a lateral force at all (%.3f m/s)"
			% left["speed"])
	assert_gt(float(left["angle"]), cfg.steer_limit * 0.15,
		"a climbing FWD car still holds a real steering angle (%.3f rad)" % left["angle"])
	# And the angle is doing something: the yaw follows the side the driver asked for
	# (+Y is left in Godot), both ways round.
	assert_gt(float(left["yaw"]), 0.0,
		"steering left rotates the car toward the demanded side (%.3f rad/s)" % left["yaw"])
	assert_lt(float(right["yaw"]), 0.0,
		"steering right rotates it the other way (%.3f rad/s)" % right["yaw"])


# --- The front-axle reading the servo closes its loop on -----------------------

func test_front_axle_state_load_weights_the_two_wheels() -> void:
	# The reading must track the tire doing the work: an unloaded inner wheel cannot drag it
	# down, or the servo would turn in further and saturate the loaded outer tire past peak.
	# Mutating the pooled contacts is safe: step() clears _contacts and rewrites every field
	# touched here at the top of each tick, and nothing reads _contacts before step() runs.
	var dt: Drivetrain = _car.drivetrain
	var fronts: Array = dt.front_wheels
	assert_gt(fronts.size(), 1, "the fixture car has two front wheels")
	var loaded: Drivetrain.WheelContact = dt._contact_pool[fronts[0]]
	var light: Drivetrain.WheelContact = dt._contact_pool[fronts[1]]
	loaded.wheel = fronts[0]
	light.wheel = fronts[1]
	loaded.n_force = 4000.0
	light.n_force = 100.0
	loaded.slip_angle = 0.20
	light.slip_angle = 0.0
	for c: Drivetrain.WheelContact in [loaded, light]:
		c.slip_lat_norm = 0.0
		c.slip_long_norm = 0.0
		c.slip_peak = 0.15
	dt._contacts.clear()
	dt._contacts.append(loaded)
	dt._contacts.append(light)
	var state: Dictionary = dt.front_axle_state(Config.data)
	assert_true(bool(state["in_contact"]), "two loaded front wheels report contact")
	assert_gt(float(state["slip_angle"]), 0.20 * 0.9,
		"the heavily loaded wheel dominates the reading")
	# The axle also reports the SPEND the servo normalises against, so the ellipse maths lives
	# with the tire model instead of being re-derived by the steering. Nothing is being spent
	# longitudinally here.
	assert_almost_eq(float(state["long_used"]), 0.0, 1e-5,
		"a free-rolling front axle reports no longitudinal spend")
	assert_almost_eq(float(state["lat_used"]), 0.0, 1e-5, "and none of it is used yet")


func test_front_axle_state_cornering_share_shrinks_as_the_drive_spends_grip() -> void:
	# The ellipse accounting lives with the tire model, not the steering servo, so that the
	# servo cannot drift out of step with what _tire_force actually applies. Its contract:
	# longitudinal spend takes cornering share away. Asserted end-to-end through
	# lateral_grip_share — the reading and the use of it, so neither can drift alone.
	var dt: Drivetrain = _car.drivetrain
	var fronts: Array = dt.front_wheels
	var c: Drivetrain.WheelContact = dt._contact_pool[fronts[0]]
	c.wheel = fronts[0]
	c.n_force = 3000.0
	c.slip_peak = 0.15
	c.slip_lat_norm = 0.0
	c.slip_angle = 0.0
	dt._contacts.clear()
	dt._contacts.append(c)

	c.slip_long_norm = 0.0
	var idle := CarScript.lateral_grip_share(
		1.0, float(dt.front_axle_state(Config.data)["long_used"]))
	c.slip_long_norm = 0.075
	var driving := CarScript.lateral_grip_share(
		1.0, float(dt.front_axle_state(Config.data)["long_used"]))
	c.slip_long_norm = 0.15
	var flat_out := CarScript.lateral_grip_share(
		1.0, float(dt.front_axle_state(Config.data)["long_used"]))

	assert_almost_eq(idle, 1.0, 1e-5, "no longitudinal slip leaves the full ask intact")
	assert_lt(driving, idle, "spending grip longitudinally takes it from cornering")
	assert_lt(flat_out, driving, "and spending more takes more")
	# Never to nothing, however hard the axle is driven — the guarantee that keeps a
	# front-driven car steerable on a climb. See Car.lateral_grip_share.
	assert_gt(flat_out, 0.0, "the share is reduced, never zeroed")


func test_front_axle_state_reports_no_contact_when_airborne() -> void:
	# The caller needs to know to fall back rather than servo on zeros.
	var dt: Drivetrain = _car.drivetrain
	dt._contacts.clear()
	var state: Dictionary = dt.front_axle_state(Config.data)
	assert_false(bool(state["in_contact"]), "no contacts means no reading")
	assert_eq(float(state["slip_angle"]), 0.0, "and the fields are zeroed, not stale")
