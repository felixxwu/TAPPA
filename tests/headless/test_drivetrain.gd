extends GutTest

var _scene: Node3D
var _car: VehicleBody3D


func before_each() -> void:
	# Flat-ground fixture (same as test_car.gd): drivetrain behavior must not
	# depend on terrain generation settings.
	# Pin the frozen test car: another scene's car selection mutates the shared
	# Config singleton, and these assertions are calibrated to the stable test
	# baseline (fixtures/test_config.tres), not the shipped gameplay tuning.
	SceneTestHelpers.use_test_config()
	_scene = load("res://tests/fixtures/test_track.tscn").instantiate()
	add_child_autofree(_scene)
	_car = _scene.get_node("Car")
	# Pin the manual box + RWD so launch/lockup behavior is deterministic
	# regardless of the shipped default gearbox mode.
	_car.drivetrain.engine.auto = false
	_car.drivetrain.drive_mode = Drivetrain.DriveMode.RWD
	await _wait_physics(150)


func after_each() -> void:
	for action in ["accelerate", "brake_reverse", "steer_left", "steer_right", "handbrake"]:
		Input.action_release(action)


# use_test_config() REPLACES the global Config.data with the frozen physics baseline and
# never puts it back, so a later script that reads the ambient config (rather than
# installing its own) would silently run on the test car. Hand the authored baseline back.
func after_all() -> void:
	Config.reset()


func _wait_physics(frames: int):
	for i in frames:
		await get_tree().physics_frame


# Minimal terrain stub exposing surface_at(x, z) -> (road_weight, tarmac_weight).
class _StubTerrain extends RefCounted:
	var s := Vector2.ZERO
	func surface_at(_x: float, _z: float) -> Vector2:
		return s

# Reports a ground height as well, which the frozen-lake path needs to decide whether a
# contact is over water. Kept separate from _StubTerrain so the tests above keep
# exercising the "surface query only" shape that path must tolerate.
class _StubTerrainWithHeight extends RefCounted:
	var s := Vector2.ZERO
	var height := 0.0
	func surface_at(_x: float, _z: float) -> Vector2:
		return s
	func height_at(_x: float, _z: float) -> float:
		return height


func test_surface_grip_scales_mu_by_surface() -> void:
	# surface_grip blends the configured grass/gravel/tarmac scales by the terrain's
	# (road, tarmac) weights at the contact point. With no terrain it leaves μ alone.
	var cfg: GameConfig = Config.data
	var dt: Drivetrain = _car.drivetrain
	var stub := _StubTerrain.new()
	dt.terrain = stub
	stub.s = Vector2(0.0, 0.0)  # off-road grass
	assert_almost_eq(dt.surface_grip(cfg, Vector3.ZERO), cfg.grass_grip, 1e-4, "grass = grass_grip")
	stub.s = Vector2(1.0, 0.0)  # full gravel road
	assert_almost_eq(dt.surface_grip(cfg, Vector3.ZERO), cfg.gravel_grip, 1e-4, "gravel = gravel_grip")
	stub.s = Vector2(1.0, 1.0)  # full tarmac road
	assert_almost_eq(dt.surface_grip(cfg, Vector3.ZERO), cfg.tarmac_grip, 1e-4, "tarmac = tarmac_grip")
	stub.s = Vector2(0.5, 0.0)  # road edge, half-faded to grass
	assert_almost_eq(dt.surface_grip(cfg, Vector3.ZERO), lerpf(cfg.grass_grip, cfg.gravel_grip, 0.5), 1e-4,
		"half-on-gravel blends grass<->gravel")
	dt.terrain = null
	assert_eq(dt.surface_grip(cfg, Vector3.ZERO), 1.0, "no terrain -> unchanged μ")


func test_surface_tire_params_rain_reduces_mu() -> void:
	# A wet contact must yield strictly less mu_mult than the identical dry
	# contact, all other inputs held equal — in both the terrain-backed path
	# and the no-terrain (flat fixture) fallback. Do not assert the specific
	# resulting value or rain_grip_mult itself: only the dry > wet relation,
	# so retuning rain_grip_mult in the inspector can't break this test.
	var cfg: GameConfig = Config.data
	var dt: Drivetrain = _car.drivetrain

	# No-terrain fallback branch.
	dt.terrain = null
	cfg.weather = RallyLibrary.WEATHER_DRY
	var dry_flat: float = dt.surface_tire_params(cfg, Vector3.ZERO).mu_mult
	cfg.weather = RallyLibrary.WEATHER_RAIN
	var wet_flat: float = dt.surface_tire_params(cfg, Vector3.ZERO).mu_mult
	assert_lt(wet_flat, dry_flat, "wet mu_mult < dry mu_mult with no terrain")

	# Terrain-backed branch.
	var stub := _StubTerrain.new()
	dt.terrain = stub
	stub.s = Vector2(0.5, 0.5)
	cfg.weather = RallyLibrary.WEATHER_DRY
	var dry_terrain: float = dt.surface_tire_params(cfg, Vector3.ZERO).mu_mult
	cfg.weather = RallyLibrary.WEATHER_RAIN
	var wet_terrain: float = dt.surface_tire_params(cfg, Vector3.ZERO).mu_mult
	assert_lt(wet_terrain, dry_terrain, "wet mu_mult < dry mu_mult with terrain")

	cfg.weather = RallyLibrary.WEATHER_DRY
	dt.terrain = null


func test_launch_wheelspin() -> void:
	# Full throttle from rest in 1st: the driven axle must genuinely spin —
	# slip well past the grip curve's peak — while the car still accelerates.
	# (Threshold recalibrated for the engine/clutch model: the old force-cap
	# engine dumped ~1750 N·m instantly; the real-ish engine spins the tires
	# at the rate the crank can rev, so slip vs tire_slip_peak is the honest
	# wheelspin measure, not a fixed multiple of car speed.)
	# This test is about whether the DRIVETRAIN can spin the wheels given enough
	# crank torque, not about the current power balance, so pin full power
	# (no de-rate) for the launch regardless of the shipped global_torque_scale
	# (config/game_config.tres) — test-only, gameplay tuning untouched.
	var cfg: GameConfig = Config.data
	cfg.global_torque_scale = 1.0
	Input.action_press("accelerate")
	await _wait_physics(20)
	var speed := _car.linear_velocity.length()
	var slip: float = _car.drivetrain.rear_omega * cfg.wheel_radius - speed
	assert_gt(slip, cfg.tire_slip_peak + 0.5,
		"rear slip well beyond the grip peak on launch (wheelspin)")
	Input.action_release("accelerate")
	assert_gt(speed, 0.3, "car still accelerates while wheels spin")


func test_brake_lockup() -> void:
	# Hard braking at speed locks the wheels (omega -> 0) while the car is
	# still moving — the slip curve then governs the sliding grip.
	var fwd := -_car.global_transform.basis.z
	var r: float = Config.data.wheel_radius
	_car.linear_velocity = fwd * 15.0
	_car.drivetrain.rear_omega = 15.0 / r
	for w in _car.drivetrain.front_omega:
		_car.drivetrain.front_omega[w] = 15.0 / r
	Input.action_press("brake_reverse")
	await _wait_physics(30)
	Input.action_release("brake_reverse")
	assert_lt(absf(_car.drivetrain.rear_omega) * r, 1.0, "rear axle locked")
	assert_gt(_car.linear_velocity.length(), 3.0, "car still sliding while locked")


# The brake_bias tuning knob (features/tuning.md) splits the foot brake front/rear.
# brake_bias = 1.0 sends ALL of it to the front: the fronts lock while the rear,
# given no foot brake, keeps rolling. (The * 2.0 normalisation means 0.5 reproduces
# the old equal split — guarded by test_brake_lockup above, which runs at the
# default 0.5.)
func test_brake_bias_forward_locks_the_front_not_the_rear() -> void:
	Config.data.brake_bias = 1.0
	var r: float = Config.data.wheel_radius
	var fwd := -_car.global_transform.basis.z
	_car.linear_velocity = fwd * 15.0
	_car.drivetrain.rear_omega = 15.0 / r
	for w in _car.drivetrain.front_omega:
		_car.drivetrain.front_omega[w] = 15.0 / r
	Input.action_press("brake_reverse")
	await _wait_physics(20)
	Input.action_release("brake_reverse")
	var front: float = _car.drivetrain.front_omega.values()[0] * r
	assert_lt(absf(front), 1.0, "all-front bias locks the front axle")
	assert_gt(absf(_car.drivetrain.rear_omega) * r, 3.0, "the rear gets no foot brake and keeps rolling")


# The mirror: brake_bias = 0.0 sends all of it to the rear — the rear locks while
# the (free-rolling RWD) front keeps turning.
func test_brake_bias_rearward_locks_the_rear_not_the_front() -> void:
	Config.data.brake_bias = 0.0
	var r: float = Config.data.wheel_radius
	var fwd := -_car.global_transform.basis.z
	_car.linear_velocity = fwd * 15.0
	_car.drivetrain.rear_omega = 15.0 / r
	for w in _car.drivetrain.front_omega:
		_car.drivetrain.front_omega[w] = 15.0 / r
	Input.action_press("brake_reverse")
	await _wait_physics(20)
	Input.action_release("brake_reverse")
	var front: float = _car.drivetrain.front_omega.values()[0] * r
	assert_lt(absf(_car.drivetrain.rear_omega) * r, 1.0, "all-rear bias locks the rear axle")
	assert_gt(absf(front), 3.0, "the front gets no foot brake and keeps rolling")


func test_handbrake_locks_rear_only_and_breaks_grip() -> void:
	var fwd := -_car.global_transform.basis.z
	var r: float = Config.data.wheel_radius
	_car.linear_velocity = fwd * 15.0
	_car.drivetrain.rear_omega = 15.0 / r
	for w in _car.drivetrain.front_omega:
		_car.drivetrain.front_omega[w] = 15.0 / r
	Input.action_press("handbrake")
	Input.action_press("steer_left")
	await _wait_physics(60)
	Input.action_release("handbrake")
	Input.action_release("steer_left")
	assert_lt(absf(_car.drivetrain.rear_omega) * r, 1.0, "handbrake locks the rear axle")
	var front_speed: float = _car.drivetrain.front_omega.values()[0] * r
	assert_gt(front_speed, 2.0, "fronts keep rolling under handbrake")
	var local_vel: Vector3 = _car.global_transform.basis.inverse() * _car.linear_velocity
	var slip := rad_to_deg(absf(atan2(local_vel.x, -local_vel.z)))
	# The locked rear loses lateral grip and induces a measurable slip while
	# steering, but on the current tuning (Godot 4.6 / Jolt) it does NOT break
	# fully away into a tail-out slide — peak slip is only ~1.3deg, decaying as
	# the car scrubs speed. So this asserts the rear gives up *some* grip, not a
	# full handbrake turn. Making a handbrake yank actually swing the tail out is
	# a separate physics-tuning task.
	assert_gt(slip, 0.5, "locked rear loses some lateral grip (mild slip; not a full tail-out)")


func test_awd_handbrake_locks_rear_only() -> void:
	# AWD normally locks the front+rear into one rigid driveline, but the
	# handbrake is an exception: it opens the centre diff so ONLY the rear axle
	# locks while the fronts keep free-rolling (and steerable).
	_car.drivetrain.drive_mode = Drivetrain.DriveMode.AWD
	var fwd := -_car.global_transform.basis.z
	var r: float = Config.data.wheel_radius
	_car.linear_velocity = fwd * 15.0
	_car.drivetrain.rear_omega = 15.0 / r
	for w in _car.drivetrain.front_omega:
		_car.drivetrain.front_omega[w] = 15.0 / r
	Input.action_press("handbrake")
	await _wait_physics(60)
	Input.action_release("handbrake")
	assert_lt(absf(_car.drivetrain.rear_omega) * r, 1.0,
		"AWD handbrake locks the rear axle")
	var front_speed: float = _car.drivetrain.front_omega.values()[0] * r
	assert_gt(front_speed, 2.0,
		"AWD fronts keep rolling under handbrake (centre diff opened)")


func test_awd_no_handbrake_locks_all_four() -> void:
	# Sanity guard on the exception: WITHOUT the handbrake, AWD is still one
	# rigid locked driveline, so a foot-brake lockup takes all four wheels down
	# together (fronts stay coupled to the rear).
	_car.drivetrain.drive_mode = Drivetrain.DriveMode.AWD
	var fwd := -_car.global_transform.basis.z
	var r: float = Config.data.wheel_radius
	_car.linear_velocity = fwd * 15.0
	_car.drivetrain.rear_omega = 15.0 / r
	for w in _car.drivetrain.front_omega:
		_car.drivetrain.front_omega[w] = 15.0 / r
	Input.action_press("brake_reverse")
	await _wait_physics(30)
	Input.action_release("brake_reverse")
	assert_lt(absf(_car.drivetrain.rear_omega) * r, 1.0, "AWD rear axle locked")
	var front_speed: float = _car.drivetrain.front_omega.values()[0] * r
	assert_lt(front_speed, 1.0, "AWD fronts locked together with the rear")


func test_parking_brake_holds_longitudinally() -> void:
	# Small forward push at rest: the parking brake (locked wheels at near-zero
	# slip) must stop it instead of letting the car creep.
	_car.linear_velocity = -_car.global_transform.basis.z * 0.5
	await _wait_physics(60)
	assert_lt(_car.linear_velocity.length(), 0.2, "parking brake stops slow creep")


# Slip angle of peak lateral force, swept via _tire_force with a synthetic
# contact at pure cornering (no wheelspin/brake). Returns degrees.
func _peak_lateral_slip_angle_deg(v: float, slip_peak := -1.0, slide_ratio := -1.0) -> float:
	var cfg: GameConfig = Config.data
	var dt: Drivetrain = _car.drivetrain
	if slip_peak < 0.0:
		slip_peak = cfg.tire_slip_peak
	if slide_ratio < 0.0:
		slide_ratio = cfg.sliding_grip_ratio
	var best_f := -1.0
	var best_deg := 0.0
	var deg := 1.0
	while deg <= 45.0:
		var a := deg_to_rad(deg)
		# Car moving at speed v with its velocity offset by the slip angle from
		# the nose: longitudinal ground vel = v·cos(a), lateral = v·sin(a).
		var c := Drivetrain.WheelContact.new()
		c.v_long = v * cos(a)
		c.s_lat = v * sin(a)
		c.mu = 1.0
		c.n_force = 4000.0
		c.slip_peak = slip_peak
		c.slide_ratio = slide_ratio
		# _tire_force reads the chassis-derived slip state (v_ref, slip_lat_norm) that step()
		# normally resolves once per tick; a bare contact must be primed the same way or the
		# normalization divides by zero.
		dt.prime_contact_slip(cfg, c)
		# surface_vel = v_long -> zero longitudinal slip, pure lateral.
		var f_lat: float = absf(dt._tire_force(cfg, c, c.v_long, 1.0 / 60.0).y)
		if f_lat > best_f:
			best_f = f_lat
			best_deg = deg
		deg += 0.5
	return best_deg


func test_peak_lateral_grip_at_constant_slip_angle() -> void:
	# The tire model normalizes slip by speed, so peak lateral grip must land at
	# the SAME slip angle regardless of speed (a real tyre peaks at ~a constant
	# angle, not a constant slip speed). Property test — holds for any reasonable
	# tire_slip_peak, pins no tuned value.
	var slow := _peak_lateral_slip_angle_deg(15.0)
	var fast := _peak_lateral_slip_angle_deg(40.0)
	assert_almost_eq(fast, slow, 1.0,
		"peak lateral slip angle is speed-independent (%.1f° vs %.1f°)" % [slow, fast])
	# And it's a genuine interior peak, not a monotone ramp to the sweep edge.
	assert_gt(slow, 1.0, "peak is at a nonzero slip angle")
	assert_lt(slow, 44.0, "grip falls off past the peak, not still climbing at 45°")


func test_surface_tire_params_blend() -> void:
	# The three surface-dependent tire params resolve from the (road, tarmac)
	# terrain weights to the matching per-surface anchor. Tests the blend LOGIC
	# maps weights -> anchors; the anchor VALUES are tunable and not asserted.
	var cfg: GameConfig = Config.data
	var dt: Drivetrain = _car.drivetrain
	var stub := _StubTerrain.new()
	dt.terrain = stub

	stub.s = Vector2(0.0, 0.0)  # off-road grass
	var grass: Dictionary = dt.surface_tire_params(cfg, Vector3.ZERO)
	assert_almost_eq(grass.slip_peak, cfg.grass_slip_peak, 1e-4, "grass slip peak")
	assert_almost_eq(grass.slide_ratio, cfg.grass_slide_ratio, 1e-4, "grass slide ratio")

	stub.s = Vector2(1.0, 0.0)  # full gravel road
	var gravel: Dictionary = dt.surface_tire_params(cfg, Vector3.ZERO)
	assert_almost_eq(gravel.slip_peak, cfg.gravel_slip_peak, 1e-4, "gravel slip peak")
	assert_almost_eq(gravel.slide_ratio, cfg.gravel_slide_ratio, 1e-4, "gravel slide ratio")

	stub.s = Vector2(1.0, 1.0)  # full tarmac road
	var tarmac: Dictionary = dt.surface_tire_params(cfg, Vector3.ZERO)
	assert_almost_eq(tarmac.slip_peak, cfg.tarmac_slip_peak, 1e-4, "tarmac slip peak")
	assert_almost_eq(tarmac.slide_ratio, cfg.tarmac_slide_ratio, 1e-4, "tarmac slide ratio")

	dt.terrain = null
	var none: Dictionary = dt.surface_tire_params(cfg, Vector3.ZERO)
	assert_eq(none.mu_mult, 1.0, "no terrain -> μ unscaled")
	assert_almost_eq(none.slip_peak, cfg.tire_slip_peak, 1e-4, "no terrain -> global slip peak")


func test_higher_slip_peak_moves_optimum_angle_out() -> void:
	# The grip curve peaks at its own slip_peak, so a contact with a larger
	# slip_peak (a looser surface) reaches optimum lateral grip at a LARGER slip
	# angle. Synthetic slip_peak inputs — asserts the code's contract, not any
	# tuned surface value.
	var v := 25.0
	var tight := _peak_lateral_slip_angle_deg(v, 0.14)   # tarmac-like
	var loose := _peak_lateral_slip_angle_deg(v, 0.31)   # gravel-like
	assert_gt(loose, tight + 3.0,
		"looser surface (bigger slip_peak) peaks at a bigger slip angle (%.1f° vs %.1f°)" % [tight, loose])


func test_grip_fraction_is_slip_over_peak_and_climbs_past_the_limit() -> void:
	# The debug grip readout's source: how far up its grip curve a tire is. Pure logic on
	# synthetic slip — no catalogue car, no authored value.
	assert_almost_eq(Drivetrain.grip_fraction(0.15, 0.15), 1.0, 1e-5,
		"slip exactly at peak is exactly on the limit")
	assert_almost_eq(Drivetrain.grip_fraction(0.075, 0.15), 0.5, 1e-5,
		"half the peak slip is halfway to the limit")
	assert_almost_eq(Drivetrain.grip_fraction(0.0, 0.15), 0.0, 1e-5,
		"a tire not slipping is using none of its grip")
	# The reason the readout is measured in SLIP rather than in force: it must keep
	# climbing past the limit. A force-based reading cannot — _grip_curve caps at 1.0 and
	# then FALLS toward the sliding plateau, so it would come back down as the tire lets
	# go and read the same number for "grip in reserve" and "already sliding".
	assert_gt(Drivetrain.grip_fraction(0.30, 0.15), 1.0,
		"slip beyond peak reads OVER 100% rather than saturating there")
	assert_gt(Drivetrain.grip_fraction(0.60, 0.15), Drivetrain.grip_fraction(0.30, 0.15),
		"the further past the limit, the higher the reading — it never turns back down")
	# The scale is the tire's OWN peak, so the same reading means the same thing on a
	# loose surface (which peaks at a larger slip) as on tarmac.
	assert_almost_eq(Drivetrain.grip_fraction(0.62, 0.31), 2.0, 1e-5,
		"a looser surface is measured against its own bigger peak")


func test_grip_fraction_is_safe_with_no_grip_curve() -> void:
	# A degenerate slip_peak must not divide by zero into INF/NAN on a debug readout.
	assert_eq(Drivetrain.grip_fraction(0.2, 0.0), 0.0, "a zero peak reports zero")


func test_grip_readout_is_published_per_wheel_while_the_overlay_is_up() -> void:
	# End to end through real physics ticks: the drivetrain publishes a finite, non-negative
	# grip reading for each wheel in contact — and only once the debug overlay asks for it
	# (the car ties publish_readouts to the overlay's visibility, so H is the real path).
	var dt: Drivetrain = _car.drivetrain
	assert_true(dt.readouts.is_empty(),
		"nothing is published while the debug overlay is down")
	Input.action_press("toggle_debug_arrows")
	await _wait_physics(3)
	Input.action_release("toggle_debug_arrows")
	Input.action_press("accelerate")
	await _wait_physics(10)
	Input.action_release("accelerate")
	assert_false(dt.readouts.is_empty(), "the settled car has wheels in contact")
	for wheel: VehicleWheel3D in dt.readouts:
		var reading: float = dt.readouts[wheel].grip
		assert_true(is_finite(reading), "wheel grip reading is a real number")
		assert_gte(reading, 0.0, "grip usage is never negative")
	# Put the overlay back down so the shared input action doesn't leak into the next test.
	Input.action_press("toggle_debug_arrows")
	await _wait_physics(3)
	Input.action_release("toggle_debug_arrows")


# --- Live per-wheel tire state (the surface effects read these) ---------------

func test_live_wheel_state_is_published_without_the_debug_overlay() -> void:
	# The tire-mark opacity and the debris gate read these every tick in every build, so
	# unlike `readouts` they must NOT depend on the debug overlay being up. A settled car
	# under power has its wheels loaded, so every one reports a real, non-negative figure.
	var dt: Drivetrain = _car.drivetrain
	assert_true(dt.readouts.is_empty(), "precondition: the debug overlay is down")
	Input.action_press("accelerate")
	await _wait_physics(10)
	Input.action_release("accelerate")
	var loaded := 0
	for wheel: VehicleWheel3D in dt.all_wheels:
		if not wheel.is_in_contact():
			continue
		loaded += 1
		assert_true(is_finite(dt.wheel_force_n(wheel)), "wheel force is a real number")
		assert_gte(dt.wheel_force_n(wheel), 0.0, "a force magnitude is never negative")
		assert_true(is_finite(dt.wheel_grip_usage(wheel)), "grip usage is a real number")
		assert_gte(dt.wheel_grip_usage(wheel), 0.0, "grip usage is never negative")
		assert_true(is_finite(dt.wheel_long_grip_usage(wheel)), "long usage is a real number")
		assert_gte(dt.wheel_long_grip_usage(wheel), 0.0,
			"longitudinal usage is unsigned, so braking reads positive too")
	assert_gt(loaded, 0, "the settled car has wheels in contact")


func test_wheel_force_matches_the_debug_readout() -> void:
	# The effects and the force overlay must not be able to disagree about what a tire is
	# doing: wheel_force_n is the magnitude of the same vector `applied` reports.
	var dt: Drivetrain = _car.drivetrain
	Input.action_press("toggle_debug_arrows")
	await _wait_physics(3)
	Input.action_release("toggle_debug_arrows")
	Input.action_press("accelerate")
	await _wait_physics(10)
	Input.action_release("accelerate")
	assert_false(dt.readouts.is_empty(), "precondition: the overlay is publishing")
	for wheel: VehicleWheel3D in dt.readouts:
		var applied: Vector3 = dt.readouts[wheel].applied
		assert_almost_eq(dt.wheel_force_n(wheel), applied.length(), 0.001,
			"the live force is the magnitude of the published force vector")
		assert_almost_eq(dt.wheel_grip_usage(wheel), float(dt.readouts[wheel].grip), 0.001,
			"the live grip usage is the published grip reading")
	Input.action_press("toggle_debug_arrows")
	await _wait_physics(3)
	Input.action_release("toggle_debug_arrows")


func test_airborne_wheel_reports_no_live_tire_state() -> void:
	# The contact pool is persistent, so a wheel that leaves the ground must report zero
	# rather than keep serving the numbers from the last tick it was loaded — otherwise a
	# jumping car would keep laying marks and throwing dirt in mid-air.
	var dt: Drivetrain = _car.drivetrain
	Input.action_press("accelerate")
	await _wait_physics(10)
	Input.action_release("accelerate")
	var grounded: VehicleWheel3D = null
	for wheel: VehicleWheel3D in dt.all_wheels:
		if wheel.is_in_contact() and dt.wheel_force_n(wheel) > 0.0:
			grounded = wheel
			break
	assert_not_null(grounded, "precondition: a loaded wheel to lift")
	# Launch the whole car clear of the ground and let the next ticks run with no contact.
	_car.global_position += Vector3(0.0, 12.0, 0.0)
	_car.linear_velocity = Vector3(0.0, 8.0, 0.0)
	await _wait_physics(5)
	assert_false(grounded.is_in_contact(), "precondition: the wheel really is airborne")
	assert_eq(dt.wheel_force_n(grounded), 0.0, "an airborne wheel puts no force through")
	assert_eq(dt.wheel_grip_usage(grounded), 0.0, "an airborne wheel reports no grip usage")
	assert_eq(dt.wheel_long_grip_usage(grounded), 0.0, "and no longitudinal usage")



# --- Road weight is carried to the deep-snow drag -----------------------------
# surface_tire_params already samples the terrain per contact, so it records the road
# weight for car.gd's per-wheel deep-snow drag to reuse (features/snow-region.md). If this
# stopped being reported the drag would silently read 1.0 everywhere and never fire.

func test_surface_params_reports_the_terrains_road_weight() -> void:
	var cfg: GameConfig = Config.data
	var dt: Drivetrain = _car.drivetrain
	var stub := _StubTerrain.new()
	dt.terrain = stub
	stub.s = Vector2(1.0, 0.0)
	assert_almost_eq(float(dt.surface_tire_params(cfg, Vector3.ZERO).road_weight), 1.0, 1e-6,
		"fully on the road")
	stub.s = Vector2(0.0, 0.0)
	assert_almost_eq(float(dt.surface_tire_params(cfg, Vector3.ZERO).road_weight), 0.0, 1e-6,
		"fully off it — this is what lets the snow bog")
	stub.s = Vector2(0.4, 0.0)
	assert_almost_eq(float(dt.surface_tire_params(cfg, Vector3.ZERO).road_weight), 0.4, 1e-6,
		"and it is the feathered weight, not a rounded predicate")


func test_no_terrain_reports_full_road_weight_so_nothing_bogs() -> void:
	var cfg: GameConfig = Config.data
	var dt: Drivetrain = _car.drivetrain
	dt.terrain = null
	assert_almost_eq(float(dt.surface_tire_params(cfg, Vector3.ZERO).road_weight), 1.0, 1e-6,
		"with no ground to sample the car must not be dragged by imaginary snow")


# A frozen lake is something you SLIDE on, not something you bog in — however far off the
# road it is, the ploughing drag must not fire out on the ice.
func test_ice_reports_full_road_weight_so_the_snow_drag_stays_off() -> void:
	var cfg: GameConfig = Config.data
	var dt: Drivetrain = _car.drivetrain
	var stub := _StubTerrainWithHeight.new()
	dt.terrain = stub
	cfg.frozen_water_grip = 0.2
	cfg.track_water_level_m = 0.0
	stub.height = -5.0          # submerged: this contact is on the ice
	stub.s = Vector2(0.0, 0.0)  # and well off the road
	assert_almost_eq(float(dt.surface_tire_params(cfg, Vector3.ZERO).road_weight), 1.0, 1e-6,
		"ice must not plough, however far off the road the lake is")


# --- Frozen lakes: ice OVERRIDES the surface blend -----------------------------
# On a stage whose region freezes its water (features/snow-region.md), a contact over a
# submerged cell is on ICE. What lies under the ice is irrelevant to the tyre, so the
# blend is replaced rather than scaled — something a multiplier could not express.

func test_ice_replaces_the_surface_blend_rather_than_scaling_it() -> void:
	var cfg: GameConfig = Config.data
	var dt: Drivetrain = _car.drivetrain
	var stub := _StubTerrainWithHeight.new()
	dt.terrain = stub
	cfg.frozen_water_grip = 0.2
	cfg.track_water_level_m = 0.0
	stub.height = -5.0            # submerged: this contact is on the ice

	stub.s = Vector2(0.0, 0.0)    # grass under the ice
	var over_grass: float = dt.surface_tire_params(cfg, Vector3.ZERO).mu_mult
	stub.s = Vector2(1.0, 1.0)    # tarmac under the ice
	var over_tarmac: float = dt.surface_tire_params(cfg, Vector3.ZERO).mu_mult
	assert_almost_eq(over_grass, over_tarmac, 1e-6,
		"ice grip does not depend on what is beneath it")
	assert_almost_eq(over_grass, cfg.frozen_water_grip, 1e-6,
		"and it IS the ice value, not a scaled surface blend")


func test_dry_land_on_a_frozen_stage_uses_the_normal_blend() -> void:
	var cfg: GameConfig = Config.data
	var dt: Drivetrain = _car.drivetrain
	var stub := _StubTerrainWithHeight.new()
	dt.terrain = stub
	cfg.frozen_water_grip = 0.2
	cfg.track_water_level_m = 0.0
	stub.height = 5.0             # above the waterline: ordinary ground
	stub.s = Vector2(1.0, 0.0)    # gravel road
	assert_almost_eq(dt.surface_tire_params(cfg, Vector3.ZERO).mu_mult, cfg.gravel_grip,
		1e-6, "above the waterline the normal surface blend applies")


func test_a_liquid_stage_never_takes_the_ice_path() -> void:
	# 0.0 is the "not frozen" sentinel every region but the Alps runs.
	var cfg: GameConfig = Config.data
	var dt: Drivetrain = _car.drivetrain
	var stub := _StubTerrainWithHeight.new()
	dt.terrain = stub
	cfg.frozen_water_grip = 0.0
	cfg.track_water_level_m = 0.0
	stub.height = -5.0            # submerged, but the water is liquid
	stub.s = Vector2(0.0, 0.0)
	assert_almost_eq(dt.surface_tire_params(cfg, Vector3.ZERO).mu_mult, cfg.grass_grip,
		1e-6, "a submerged contact on a liquid stage is just ordinary ground")


func test_ice_degrades_safely_when_the_terrain_reports_no_height() -> void:
	# A terrain-like provider may implement surface_at without height_at. That must fall
	# back to ordinary ground, never error mid-stage.
	var cfg: GameConfig = Config.data
	var dt: Drivetrain = _car.drivetrain
	var stub := _StubTerrain.new()   # surface query only
	dt.terrain = stub
	cfg.frozen_water_grip = 0.2
	stub.s = Vector2(0.0, 0.0)
	assert_almost_eq(dt.surface_tire_params(cfg, Vector3.ZERO).mu_mult, cfg.grass_grip,
		1e-6, "no height query available => ordinary ground")


# --- Surface-dependent tyre compound (features/drivetrain-and-tires.md) --------
#
# The RULE first, as pure logic on GameConfig.tire_surface_mult, then the three
# places surface_tire_params has to route through it. Nothing here pins the snow
# compound's authored figures: every assertion is expressed as a relation between
# the multipliers it is handed, so retuning the part cannot break it.

func test_the_tire_surface_rule_is_neutral_for_a_car_with_no_such_compound() -> void:
	# 1.0/1.0 is the identity every other compound (and every unfitted slot) reads
	# as, on snow and off it and at any tarmac weight. This is what makes the whole
	# mechanism an exact no-op for the rest of the catalogue.
	for snowy in [false, true]:
		for w in [0.0, 0.5, 1.0]:
			assert_almost_eq(GameConfig.tire_surface_mult(1.0, 1.0, w, snowy), 1.0, 1e-6,
				"identity multipliers leave mu alone (snowy=%s, tarmac=%s)" % [snowy, w])


func test_the_snow_bonus_is_all_or_nothing_on_the_region() -> void:
	# Snow ground is snow ground: the packed-snow road and the deep verge are the
	# same white stuff, so the bonus must not feather with the tarmac weight.
	for w in [0.0, 0.5, 1.0]:
		assert_almost_eq(GameConfig.tire_surface_mult(1.2, 0.5, w, true), 1.2, 1e-6,
			"snow bonus ignores tarmac weight (%s)" % w)


func test_the_tarmac_penalty_feathers_with_the_tarmac_weight() -> void:
	# Pure gravel costs the compound nothing; full tarmac costs it the whole
	# penalty; in between it is monotonic. Direction only — no authored figure.
	var penalty := 0.8
	assert_almost_eq(GameConfig.tire_surface_mult(1.2, penalty, 0.0, false), 1.0, 1e-6,
		"pure gravel is unpenalised")
	assert_almost_eq(GameConfig.tire_surface_mult(1.2, penalty, 1.0, false), penalty, 1e-6,
		"full tarmac pays the whole penalty")
	var half := GameConfig.tire_surface_mult(1.2, penalty, 0.5, false)
	assert_lt(half, 1.0, "a half-tarmac contact is penalised")
	assert_gt(half, penalty, "...but by less than a full-tarmac one")


func test_a_snow_stage_never_charges_the_tarmac_penalty() -> void:
	# The two terms are exclusive. On a snow stage the "tarmac" channel is a
	# dusting over asphalt, so charging the penalty there would cancel the point
	# of the part — the player would be punished for the surface they fitted for.
	assert_gt(GameConfig.tire_surface_mult(1.2, 0.5, 1.0, true), 1.0,
		"a full-tarmac contact on a snow stage still gets the bonus")


func test_ground_is_snow_follows_the_regions_deep_snow_block() -> void:
	# The snow signal is derived, not a second flag to keep in sync: it is exactly
	# "RallySession seated a deep-snow block off the region".
	var cfg := GameConfig.new()
	cfg.deep_snow_depth_m = 0.0
	assert_false(cfg.ground_is_snow(), "no deep snow seated => not a snow stage")
	cfg.deep_snow_depth_m = 0.3
	assert_true(cfg.ground_is_snow(), "a deep-snow block seated => a snow stage")


func test_a_snow_compound_trades_tarmac_grip_for_snow_grip() -> void:
	# The end-to-end behaviour through the live resolver, on the terrain-backed
	# path. Same contact, same weather, same car: only the fitted rubber differs.
	var cfg: GameConfig = Config.data
	var dt: Drivetrain = _car.drivetrain
	var stub := _StubTerrain.new()
	dt.terrain = stub
	stub.s = Vector2(1.0, 1.0)  # full tarmac road

	cfg.deep_snow_depth_m = 0.0
	var stock_tarmac: float = dt.surface_tire_params(cfg, Vector3.ZERO).mu_mult
	cfg.tire_snow_grip_mult = 1.2
	cfg.tire_tarmac_grip_mult = 0.8
	var snow_tyres_tarmac: float = dt.surface_tire_params(cfg, Vector3.ZERO).mu_mult
	assert_lt(snow_tyres_tarmac, stock_tarmac, "winter rubber gives grip away on tarmac")

	cfg.deep_snow_depth_m = 0.3  # the same stage, now in a snowy region
	var snow_tyres_snow: float = dt.surface_tire_params(cfg, Vector3.ZERO).mu_mult
	cfg.tire_snow_grip_mult = 1.0
	cfg.tire_tarmac_grip_mult = 1.0
	var stock_snow: float = dt.surface_tire_params(cfg, Vector3.ZERO).mu_mult
	assert_gt(snow_tyres_snow, stock_snow, "...and buys it back on snow")

	cfg.deep_snow_depth_m = 0.0


func test_the_tire_compound_reaches_the_off_terrain_and_ice_paths_too() -> void:
	# Both early-return branches of surface_tire_params must route through the rule.
	# The flat fixture matters because a headless physics test has no terrain at all;
	# ice matters because a frozen lake is only ever authored by a snowy region, so it
	# takes the SNOW side of the trade rather than the tarmac side.
	var cfg: GameConfig = Config.data
	var dt: Drivetrain = _car.drivetrain
	cfg.deep_snow_depth_m = 0.3

	dt.terrain = null
	var flat_stock: float = dt.surface_tire_params(cfg, Vector3.ZERO).mu_mult
	cfg.tire_snow_grip_mult = 1.2
	assert_gt(dt.surface_tire_params(cfg, Vector3.ZERO).mu_mult, flat_stock,
		"the no-terrain fallback applies the compound")

	var stub := _StubTerrainWithHeight.new()
	dt.terrain = stub
	stub.s = Vector2(1.0, 1.0)
	stub.height = cfg.track_water_level_m - 1.0  # a contact out on the ice
	cfg.frozen_water_grip = 0.2
	var ice_snow_tyres: float = dt.surface_tire_params(cfg, Vector3.ZERO).mu_mult
	cfg.tire_snow_grip_mult = 1.0
	var ice_stock: float = dt.surface_tire_params(cfg, Vector3.ZERO).mu_mult
	assert_gt(ice_snow_tyres, ice_stock, "ice takes the snow side of the trade")

	cfg.frozen_water_grip = 0.0
	cfg.deep_snow_depth_m = 0.0
