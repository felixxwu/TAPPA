extends VehicleBody3D

const CAR_SCENE := preload("res://car.tscn")

# Wheel-cap material: each car's Visual/Tire shows its own wheel.png on the cylinder
# caps (ps1_wheel_tire.gdshader), or a blank dark disc for cars without an authored
# wheel. Built lazily and cached per texture path so a lineup of cars sharing a
# texture reuses one material.
const WHEEL_SHADER := preload("res://shaders/ps1_wheel_tire.gdshader")
var _wheel_mats: Dictionary = {}
# Shared 1×1 near-black texture for the blank hubcap (built once, reused).
static var _blank_wheel_tex: ImageTexture

# Roll+pitch damping for the self-righting assist, as a fraction of
# level_assist_torque per rad/s of tilt rate. Scales off the same knob so the
# inspector keeps a single strength control while the aid still settles to level
# instead of oscillating.
const LEVEL_ASSIST_DAMPING := 0.35

# Yaw-rate damping for the spin-protection assist, as a fraction of
# spin_assist_torque per rad/s of yaw. Scales off the same knob so the
# inspector keeps a single strength control while the recovery still settles
# to the travel direction instead of oscillating.
const SPIN_ASSIST_DAMPING := 0.35

# Contacts the chassis reports per physics tick for the damage model. The car only
# ever touches a few obstacles at once; a small cap keeps contact monitoring cheap.
const MAX_CONTACTS_REPORTED := 8

# Re-emitted from the car's DamageModel when working HP hits 0 (a run DNF). A
# fielded car has already been removed from the save by then; the rally/menu layer
# (features/rally-session.md) listens here. See features/damage.md.
signal wrecked()

var _start_transform: Transform3D
# The GameConfig this car's physics reads/writes. DEFAULTS to the global Config.data
# (so the single active/player car stays wired to the HUD, tuning lift, audio synth
# and save system, which all read Config.data). Non-simulating PROP/display cars (HQ
# car-park lineup, start-line queue, podium) are handed an ISOLATED duplicate via
# use_isolated_config() BEFORE apply_car, so their reshape mutates their own copy and
# can't clobber the active car's engine/gearbox in the shared global. car.gd,
# Drivetrain and EngineSim all read THIS, not Config.data directly. Set before _ready
# builds the drivetrain (or before apply_car, which rebuilds it) so the physics
# captures the right config object; apply_car only mutates fields on it, never
# reassigns, so captured references stay valid.
var config: GameConfig
var drivetrain: Drivetrain
# Per-car HP / attrition state + the handling/power degradation maths
# (features/damage.md). Built in _ready, (re)configured per car in apply_car.
var damage: DamageModel
# Travel speed (m/s) captured at the top of each _physics_process, BEFORE the
# solver runs. _integrate_forces uses THIS as the impact speed, not the post-solve
# state.linear_velocity (which a head-on hit has already arrested to ~0). See
# _integrate_forces for the full rationale.
var _approach_speed := 0.0
var _front_axle := Vector3.ZERO  # local midpoints, computed from wheel rest positions
var _rear_axle := Vector3.ZERO
var downforce_readouts: Array = []  # [global point, force vector] pairs for the debug overlay
# Combined yaw-assist torque applied this tick (steer assist + spin protection),
# as a signed scalar about the car's up axis (positive = turning the nose left).
# Read by the debug overlay to draw a single left/right assist arrow.
var steer_assist_readout: float = 0.0
var _car_index := -1  # selected CarLibrary entry, or -1 for the untouched baseline
var _wheel_mounts: Dictionary = {}  # wheel -> authored local mount origin (scene rest pose)
var _debug_overlay: WheelForceDebug  # the wheel-force arrow overlay (toggled by H)

# When true, driver input is ignored and the handbrake is forced on, so the car
# physically holds still (e.g. staged at the start line, or after the finish).
# Set by StageManager; the rest of the simulation (drag, suspension, camera) keeps
# running so the car settles naturally. See todo/stage-start-and-end.md §2.
var controls_locked := false

# When true (set by StageManager on crossing the finish, alongside controls_locked),
# the car brakes itself to a stop: full foot brake + the forced handbrake while it's
# still rolling, then the foot brake releases once stopped. The engine clutch stays
# ENGAGED through the stop so the engine winds down with the braking wheels (the
# auto-clutch opens at standstill), instead of free-revving on the handbrake's open
# clutch. Cleared on re-arm (setup / a car swap). See features/stage.md.
var finish_stop := false
# Below this speed the finish stop counts the car as stopped and releases the foot
# brake (the handbrake / parking hold still holds it put).
const FINISH_STOP_SPEED := 0.8  # m/s

# When true, the handbrake is forced on but driver input is otherwise LIVE — the
# player can rev the engine (the held handbrake opens the clutch, so revs climb
# freely) and steer, then launch the instant the brake releases. Used during the
# countdown so the player can pull away at full revs on GO. Set by StageManager.
var handbrake_locked := false

# Scripted ("AI") control for non-player cars — the start-line queue (scripts/
# start_line.gd) drives the leader/trailer with full physics so they pull away and
# roll up with real suspension load. When true the car ignores global Input and
# drives from these values instead (same axes/sign as the player inputs). Use axis
# locks on the body to keep such a car straight; see start_line.gd.
var ai_controlled := false
var ai_throttle := 0.0    # -1..1, forward positive (brake_reverse..accelerate axis)
var ai_steer := 0.0       # -1..1, left positive (steer_right..steer_left axis)
var ai_handbrake := false

# Parking-hold speed gate: below this speed a fully-braked, grounded car gets a
# static-friction hold so it doesn't creep down a slope. See _apply_parking_hold.
const HANDBRAKE_LOCK_SPEED := 0.5  # m/s
# Smoothed steering input. Raw steer_input snaps 0->1 on a keyboard; easing it
# gives one smooth -1..1 source that BOTH the wheel-angle target and the yaw
# assist torque read, so the two stay 1:1 instead of the torque slamming to full
# the instant a key is pressed.
var _steer := 0.0


func _ready() -> void:
	# Default to the shared global config unless a spawner already handed this
	# instance an isolated one (see `config` above / use_isolated_config).
	if config == null:
		config = Config.data
	var cfg: GameConfig = config
	# Spawn the car spawn_clearance metres above the ground at its xz, so the
	# wheels never start clipping under the terrain regardless of how high the
	# surface is there. This transform is also what reset / car swaps restore.
	_start_transform = global_transform
	_start_transform.origin.y = _ground_height_at(_start_transform.origin) + cfg.spawn_clearance
	global_transform = _start_transform
	mass = cfg.mass
	linear_damp = 0.0  # aero drag below is the only speed-dependent loss
	angular_damp = 0.0  # no passive angular decay — the car keeps its spin mid-air
	# (Godot's implicit default is 0.1; force 0 so a launched car isn't slowed in
	# the air). Grounded rotation is governed by the tire model + steer/spin assists.
	for wheel in find_children("*", "VehicleWheel3D", false):
		# All contact friction is handled by the Drivetrain tire model; the
		# built-in solver only does suspension + raycasts.
		wheel.wheel_friction_slip = 0.0
		_apply_suspension(wheel)
		# Godot caps the suspension force at suspension_max_force (default 6000 N),
		# which is far below what a ~1.5 t car needs to arrest a hard landing — the
		# spring would clip and the chassis would bottom out. Lift the cap well
		# above any real spring+damper force so it never limits the suspension.
		wheel.suspension_max_force = 1_000_000.0
		wheel.wheel_radius = cfg.wheel_radius
		# Remember the authored mount BEFORE physics repaints the wheel transform
		# (the body overwrites origin with connection-point + suspension travel),
		# so car swaps relocate from a clean rest pose, not a drifted one.
		_wheel_mounts[wheel] = wheel.position
		# car.tscn shares ONE Spoke mesh across Spoke1 + Spoke2 of a wheel (so
		# resizing one resizes both); duplicate it ONCE per wheel and reassign to
		# both, so the pair stays in sync but no longer shares the resource with
		# any other car.tscn instance (see the Chassis/Cabin note below).
		var spoke_mesh: Mesh = null
		for spoke_name in ["Visual/Spoke1", "Visual/Spoke2"]:
			var spoke := wheel.get_node_or_null(spoke_name) as MeshInstance3D
			if spoke == null or spoke.mesh == null:
				continue
			if spoke_mesh == null:
				spoke_mesh = spoke.mesh.duplicate()
			spoke.mesh = spoke_mesh
		var tire := wheel.get_node_or_null("Visual/Tire") as MeshInstance3D
		if tire != null and tire.mesh != null:
			tire.mesh = tire.mesh.duplicate()
	# Chassis/Cabin boxes and each wheel's Tire/Spoke are authored as shared
	# sub-resources in car.tscn (so apply_car's resize covers, e.g., all four
	# wheels or both spokes on a wheel at once) — but that sharing also spans
	# every INSTANCE of car.tscn by default. In an event, start_line.gd spawns
	# extra car instances (queue props) that call apply_car() too; without the
	# per-instance copies above/below, whichever car resizes last corrupts every
	# other instance's chassis/cabin/wheel visuals (size, radius, width — and the
	# spoke length, which scales off radius) until that instance happens to get
	# its own copy too. Duplicate Chassis/Cabin meshes here as well, once per
	# instance, before anyone can mutate the shared originals.
	var chassis_mesh := $Chassis as MeshInstance3D
	if chassis_mesh.mesh != null:
		chassis_mesh.mesh = chassis_mesh.mesh.duplicate()
	var cabin_mesh := $Cabin as MeshInstance3D
	if cabin_mesh.mesh != null:
		cabin_mesh.mesh = cabin_mesh.mesh.duplicate()
	drivetrain = Drivetrain.new(self)
	drivetrain.terrain = _resolve_terrain()
	# Read per-contact impulses in _integrate_forces (used by the damage model to
	# turn obstacle hits into HP loss). The chassis box is the only solid shape —
	# the wheels are raycasts — so this reports chassis-vs-world contacts only.
	contact_monitor = true
	max_contacts_reported = MAX_CONTACTS_REPORTED
	# Damage state: unbound (free-roam) until a car is applied / fielded. apply_car
	# fills in the per-car max HP; this keeps the baseline car sane on its own.
	damage = DamageModel.new()
	damage.field(damage.max_hp, damage.max_hp)
	damage.wrecked.connect(_on_wrecked)
	_debug_overlay = WheelForceDebug.new(self)
	_debug_overlay.visible = cfg.debug_wheel_forces
	add_child(_debug_overlay)
	_recompute_axles()


# Terrain surface height at a world position, used to seat the spawn above the
# ground. Looks for a sibling that exposes height_at (the hilly Floor in the
# main scene); on the flat test fixtures (a WorldBoundary at y=0) there is none,
# so it falls back to 0.
# Speed-dependent max steering angle. Returns the effective input steer limit
# (radians): full cfg.steer_limit at/below steer_limit_falloff_start, ramping
# linearly down to steer_limit_min_fraction of it at/above steer_limit_falloff_end,
# holding that floor above. end <= start (or min_fraction == 1.0) disables it.
static func speed_scaled_steer_limit(cfg: GameConfig, speed: float) -> float:
	var falloff := 0.0
	if cfg.steer_limit_falloff_end > cfg.steer_limit_falloff_start:
		falloff = clampf((speed - cfg.steer_limit_falloff_start) \
			/ (cfg.steer_limit_falloff_end - cfg.steer_limit_falloff_start), 0.0, 1.0)
	return cfg.steer_limit * lerpf(1.0, cfg.steer_limit_min_fraction, falloff)


func _ground_height_at(pos: Vector3) -> float:
	var parent := get_parent()
	if parent != null:
		for sibling in parent.get_children():
			if sibling != self and sibling.has_method("height_at"):
				return sibling.height_at(pos.x, pos.z)
	return 0.0


# The terrain that resolves per-wheel surface grip (the Floor in the main scene),
# found as the sibling exposing surface_at. Null on the flat test fixtures, where
# the drivetrain then leaves every wheel on the base μ. Mirrors _ground_height_at.
func _resolve_terrain() -> Node:
	var parent := get_parent()
	if parent != null:
		for sibling in parent.get_children():
			if sibling != self and sibling.has_method("surface_at"):
				return sibling
	return null


# Axle midpoints for the downforce application points, classified the same way
# the drivetrain splits the wheels: use_as_traction = rear. Recomputed after a
# car swap moves the wheels.
func _recompute_axles() -> void:
	_front_axle = Vector3.ZERO
	_rear_axle = Vector3.ZERO
	var fronts: Array[Vector3] = []
	var rears: Array[Vector3] = []
	for wheel in find_children("*", "VehicleWheel3D", false):
		(rears if wheel.use_as_traction else fronts).append(wheel.position)
	for p in fronts:
		_front_axle += p / fronts.size()
	for p in rears:
		_rear_axle += p / rears.size()


func _physics_process(delta: float) -> void:
	var cfg: GameConfig = config
	# Capture the pre-solve travel speed for _integrate_forces' damage keying — this
	# runs before the physics solver, so it still holds the true approach speed even
	# on a head-on hit the solver is about to arrest. See _integrate_forces.
	_approach_speed = linear_velocity.length()
	# Decay the damage model's post-hit impact cooldown (groups a sustained crash
	# into one hit; see DamageModel.register_impact).
	if damage != null:
		damage.tick_cooldown(delta)
	var engine := drivetrain.engine
	# Discrete gear/mode actions only respond when controls are unlocked, so the
	# player can't shift or change mode mid-countdown. Scripted cars never read them.
	if not controls_locked and not ai_controlled:
		if Input.is_action_just_pressed("toggle_gearbox"):
			engine.auto = not engine.auto
		if Input.is_action_just_pressed("cycle_drive_mode"):
			drivetrain.cycle_drive_mode()
		if not engine.auto:
			if Input.is_action_just_pressed("shift_up"):
				engine.request_shift(1)
			if Input.is_action_just_pressed("shift_down"):
				engine.request_shift(-1)

	# Neutralise driver input while locked; the forced handbrake below holds the
	# car on a slope without freezing the whole simulation.
	var throttle := ai_throttle if ai_controlled else (0.0 if controls_locked else Input.get_axis("brake_reverse", "accelerate"))
	var fwd_pedal := maxf(throttle, 0.0)  # W
	var rev_pedal := maxf(-throttle, 0.0)  # S
	var moving_forward := linear_velocity.dot(-global_transform.basis.z) > 1.0
	var speed := linear_velocity.length()
	var drive := 0.0
	var brake_input := 0.0
	if engine.auto:
		# Automatic: the box picks forward gears; reverse engages from a stop.
		if rev_pedal > 0.0 and moving_forward:
			brake_input = 1.0  # S brakes while rolling forward, reverses otherwise
		elif rev_pedal > 0.0:
			if engine.select_reverse(drivetrain.rear_omega):
				drive = rev_pedal
			else:
				brake_input = 1.0
		elif fwd_pedal > 0.0:
			if engine.select_forward(drivetrain.rear_omega):
				drive = fwd_pedal
			else:
				brake_input = 1.0
		elif speed < 2.0:
			brake_input = 1.0  # parking brake: hold the car on slopes
		# Shift on actual forward ground speed (wheelspin-immune), not revs.
		engine.update_auto(drive, maxf(linear_velocity.dot(-global_transform.basis.z), 0.0))
	else:
		# Manual: the driver selects R/N/1..N with Q/E. In reverse, S drives
		# back and W brakes; otherwise W drives (neutral just revs the engine).
		if engine.gear < 0:
			drive = rev_pedal
			brake_input = fwd_pedal
		else:
			drive = fwd_pedal
			brake_input = rev_pedal
		if drive < 0.01 and brake_input < 0.01 and speed < 2.0:
			brake_input = 1.0  # parking brake: hold the car on slopes
	var handbrake := ai_handbrake if ai_controlled else (controls_locked or handbrake_locked or Input.is_action_pressed("handbrake"))
	# Declutch normally follows the handbrake (a held handbrake opens the clutch so the
	# engine can rev free — used for launches). The finish stop is the exception.
	var declutch := handbrake
	if finish_stop:
		# Brake to a stop with the foot brake + the forced handbrake, but keep the
		# clutch ENGAGED so the engine engine-brakes down with the wheels (the auto-clutch
		# opens at standstill and the engine settles to idle) rather than free-revving on
		# the open handbrake clutch. Release the foot brake once stopped.
		declutch = false
		brake_input = 1.0 if speed > FINISH_STOP_SPEED else 0.0
	# Stiction hold: a fully-pinned axle (handbrake or the low-speed parking brake)
	# should stop the car creeping down a slope. See _apply_parking_hold.
	_apply_parking_hold(handbrake or brake_input >= 1.0, speed, delta)
	# Damage misfire: feed the engine its misfire intensity so it cuts fuel in
	# stumbling bursts once HP falls below the health threshold (0 = healthy, never
	# cuts; ramps to 1 at 0 HP). See features/damage.md.
	engine.misfire_level = damage.misfire_level(cfg)
	drivetrain.step(delta, drive, brake_input, handbrake, declutch)

	# Quadratic aero drag; with redline-limited gearing, this sets how hard
	# the top of each gear pulls.
	apply_central_force(-linear_velocity * linear_velocity.length() * cfg.drag_coefficient)

	# Speed-squared downforce per axle, pressing the body down so suspension
	# compression raises wheel normal force (and therefore grip).
	var v2 := linear_velocity.length_squared()
	var down := -global_transform.basis.y
	apply_force(down * v2 * cfg.downforce_front, global_transform.basis * _front_axle)
	apply_force(down * v2 * cfg.downforce_rear, global_transform.basis * _rear_axle)
	# Only build the debug-overlay readout array when the overlay is actually
	# visible — it's the sole consumer (WheelForceDebug, toggled at runtime by H),
	# so the shipped game doesn't allocate it every physics tick.
	if _debug_overlay.visible:
		downforce_readouts = [
			[global_position + global_transform.basis * _front_axle, down * v2 * cfg.downforce_front],
			[global_position + global_transform.basis * _rear_axle, down * v2 * cfg.downforce_rear],
		]

	# Front wheels caster toward the direction of travel (blended in by
	# steer_travel_alignment; at 1.0 they fully track it, making countersteer
	# in a slide automatic). The alignment is faded in linearly with speed (0 at
	# standstill up to full at steer_assist_min_speed) so it doesn't snap in at
	# low speed. Steering input offsets them by a fixed steer_limit.
	var local_vel := global_transform.basis.inverse() * linear_velocity
	var slip_angle := 0.0  # unclamped travel-direction yaw; also feeds spin protection below
	var travel_angle := 0.0
	if Vector2(local_vel.x, local_vel.z).length() > 2.0 and local_vel.z < 0.0:
		# Yaw of the travel direction relative to the car's forward (-Z),
		# positive to the left like VehicleWheel3D steering. Clamped so a deep
		# slide can't spin the wheels to extreme angles. Only applied when
		# moving forwards; when slow or reversing, plain input steering.
		slip_angle = atan2(-local_vel.x, -local_vel.z)
		travel_angle = clampf(slip_angle, -PI / 3.0, PI / 3.0)
	var steer_input := ai_steer if ai_controlled else (0.0 if controls_locked else Input.get_axis("steer_right", "steer_left"))
	# Ramp the travel alignment in linearly from 0 at standstill to its full
	# configured value at steer_assist_min_speed (≈30 km/h), so it doesn't fight
	# low-speed input steering yet returns smoothly with no sudden jump as speed
	# builds. Shares the threshold with the steer-assist torque ramp below.
	var align_scale := clampf(speed / cfg.steer_assist_min_speed, 0.0, 1.0)
	# Smooth the raw input once, at the same angular rate the wheels turn
	# (steer_speed rad/s over steer_limit rad of travel), so a keyboard's instant
	# 0->1 eases in. Both the wheel-angle target below and the assist torque read
	# this same _steer, keeping them 1:1.
	var assist_rate := (cfg.steer_speed / cfg.steer_limit) if cfg.steer_limit > 0.0 else cfg.steer_speed
	_steer = move_toward(_steer, steer_input, assist_rate * delta)
	# Speed-dependent max steering angle: taper the input steer_limit down from
	# full (at/below steer_limit_falloff_start) to steer_limit_min_fraction of
	# itself (at/above steer_limit_falloff_end), so the car isn't twitchy/spin-
	# prone at speed. Only the input term is scaled; the travel-alignment
	# countersteer keeps its full authority so slides still catch. See
	# features/car-physics.md.
	var effective_steer_limit := speed_scaled_steer_limit(cfg, speed)
	var steer_target := travel_angle * cfg.steer_travel_alignment * align_scale + _steer * effective_steer_limit
	steering = move_toward(steering, steer_target, cfg.steer_speed * delta)
	# Damage wheel misalignment: bend each wheel physically by its persisted toe on
	# TOP of the base steer. The pull/crab of a damaged car then comes from the
	# physics alone — the drivetrain tire model reads wheel.steering for the force
	# direction (and the wheel visual off it too). No synthetic steer bias. See
	# features/damage.md / DamageModel.nudge_wheels.
	_apply_wheel_toe()
	# Direct yaw torque about the car's up axis while steering, to fight
	# understeer when the front tires alone can't rotate the car. Faded in
	# linearly from 0 at standstill to full at steer_assist_min_speed (rather
	# than switched on abruptly at that threshold), so it ramps back up smoothly
	# with no sudden jump while still staying out of low-speed handling.
	var assist_scale := clampf(speed / cfg.steer_assist_min_speed, 0.0, 1.0)
	# Taper the assist off as the car rotates into the turn. travel_angle is the
	# slip angle (travel direction relative to the car's nose); steering into a
	# slide rotates the car so its nose leads the travel direction, which is the
	# same sign as steer_input. -travel_angle * sign(steer_input) is therefore how
	# far the car has already rotated in the steering direction. Full assist at 0,
	# fading linearly to none at steer_assist_max_angle, so it helps rotate the car
	# in but stops adding torque once it's turned enough — no over-rotation/spin.
	var rotated_into_turn := -travel_angle * signf(_steer)
	var angle_scale := 1.0
	if cfg.steer_assist_max_angle > 0.0:
		angle_scale = clampf(1.0 - rotated_into_turn / cfg.steer_assist_max_angle, 0.0, 1.0)
	var steer_assist_yaw := _steer * cfg.steer_assist_torque * assist_scale * angle_scale
	apply_torque(global_transform.basis.y * steer_assist_yaw)
	# Reset the combined assist readout each tick, then accumulate both aids into it
	# for the debug overlay's single left/right arrow.
	steer_assist_readout = steer_assist_yaw

	# Spin protection: once the car has rotated further than spin_assist_angle
	# away from its direction of travel, a corrective yaw torque pulls the nose
	# back toward the travel direction — the slide-recovery counterpart to the
	# steer assist above (which merely stops adding rotation past its taper).
	# slip_angle's sign points toward the travel direction (positive left), so
	# torquing along sign(slip_angle) always rotates the nose back. The torque
	# ramps in linearly from 0 at the threshold to full at twice it, shares the
	# steer assist's speed fade-in (assist_scale) so it stays out of low-speed
	# manoeuvring, and carries a yaw-rate damping term so the slide settles
	# instead of oscillating nose-side-to-side. Suppressed while the handbrake
	# is held, so deliberate handbrake drifts stay possible. Only active while
	# travelling nose-forward (slip_angle is 0 past 90° / when reversing — the
	# aid prevents reaching a spin, it doesn't unwind a completed one).
	if cfg.spin_assist_torque > 0.0 and cfg.spin_assist_angle > 0.0 and not handbrake:
		var excess := absf(slip_angle) - cfg.spin_assist_angle
		if excess > 0.0:
			var spin_scale := clampf(excess / cfg.spin_assist_angle, 0.0, 1.0) * assist_scale
			var up := global_transform.basis.y
			var yaw_rate := angular_velocity.dot(up)
			var spin_assist_yaw := spin_scale * cfg.spin_assist_torque \
				* (signf(slip_angle) - yaw_rate * SPIN_ASSIST_DAMPING)
			apply_torque(up * spin_assist_yaw)
			steer_assist_readout += spin_assist_yaw

	# Self-righting assist: while any wheel is off the ground, ease the chassis
	# back toward level. up × world_up is the roll+pitch axis that rotates the
	# car's up toward vertical — it lies in the horizontal plane, so it adds no
	# yaw — and its length is sin(tilt), so the correction grows the further the
	# car is from flat (peaking near 90°). A damping term opposing the roll+pitch
	# angular velocity (the yaw component, about the car's own up, is left free)
	# keeps it from overshooting level and wobbling. No effect once all four
	# wheels plant.
	if cfg.level_assist_torque > 0.0 and _any_wheel_airborne():
		var up := global_transform.basis.y
		var roll_pitch_rate := angular_velocity - up * angular_velocity.dot(up)
		apply_torque(
			up.cross(Vector3.UP) * cfg.level_assist_torque
			- roll_pitch_rate * cfg.level_assist_torque * LEVEL_ASSIST_DAMPING
		)

	if not controls_locked and not ai_controlled and Input.is_action_just_pressed("reset_car"):
		_reset()


# Read solid contacts each physics tick and feed obstacle hits to the damage
# model. Only contacts against bodies in the obstacle group count (trees / bushes
# / signs); ground and road contacts are ignored, so normal driving never chips HP.
#
# CRITICAL: damage is keyed to `_approach_speed` — the speed cached at the top of
# _physics_process, BEFORE the solver runs — NOT to state.linear_velocity here.
# Godot only reports a contact in _integrate_forces AFTER the constraint solver has
# already resolved (and, in a head-on hit, arrested) it, so state.linear_velocity
# at this point is near zero on exactly the hardest crashes. Reading it directly
# made head-on collisions deal no damage (the square law floored to 0 below
# impact_min_speed_kmh) while glancing hits, which keep their speed, still chipped
# HP. The cached pre-solve speed is the true approach speed. The post-hit cooldown
# in register_impact still groups the rest of the crash into that one hit.
# contact_monitor + max_contacts_reported are enabled in _ready.
func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if damage == null:
		return
	var cfg: GameConfig = config
	for i in state.get_contact_count():
		var collider := state.get_contact_collider_object(i) as Node
		if collider == null or not collider.is_in_group(DamageModel.OBSTACLE_GROUP):
			continue
		damage.register_impact(_approach_speed, state.get_contact_local_position(i), cfg)


# DamageModel reached 0 HP. Re-emit for the rally/menu layer. In free-roam (an
# UNBOUND model, no OwnedCar) there is no DNF flow yet, so heal to full and drop
# back at the spawn so play continues; a fielded car leaves the consequences to
# its listener (features/rally-session.md).
func _on_wrecked() -> void:
	wrecked.emit()
	if damage.instance_id < 0:
		damage.hp = damage.max_hp
		_reset()


# True when at least one wheel is not touching the ground — the trigger for the
# self-righting assist (drivetrain owns the classified wheel lists).
func _any_wheel_airborne() -> bool:
	for wheel in drivetrain.front_wheels + drivetrain.rear_wheels:
		if not wheel.is_in_contact():
			return true
	return false


# Manual reset (the `R` action): back to the authored spawn pose.
func _reset() -> void:
	reset_to(_start_transform)


# Reset the car to an arbitrary pose with motion zeroed — shared by the manual
# reset and the off-track recovery (TrackProgress). Restores velocities, wheel
# spin and engine state so the car drops in cleanly rather than carrying over
# stale momentum.
# Static-friction hold for a nearly-stopped, fully-braked car so it doesn't slowly
# creep down a slope. The tire model's longitudinal force fades to zero as slip does
# (drivetrain._tire_force caps it at |slip|·m/h), so at creep speed gravity's slope
# component wins and the car dribbles downhill. Rather than freeze the body (which
# takes it out of the sim and snaps on release), we cancel the residual in-plane
# velocity each frame with a counter-force, clamped to a friction limit so it acts
# like real stiction — it holds any sane slope but a wall-steep grade still slides.
func _apply_parking_hold(braked: bool, speed: float, delta: float) -> void:
	# Only hold once the car is actually resting on the ground — a boot-locked car
	# (StageManager forces the handbrake) must be free to drop onto its wheels first.
	if not (braked and speed < HANDBRAKE_LOCK_SPEED and _is_grounded()) or delta <= 0.0:
		return
	# Null the horizontal velocity component (leave vertical to gravity/suspension):
	# F = -m·v_h/dt zeroes it in one step, so per-frame creep never accumulates.
	var v_h := Vector3(linear_velocity.x, 0.0, linear_velocity.z)
	var hold := -v_h * mass / delta
	# Clamp to μ·m·g so it behaves like static friction, not an infinite clamp.
	var cap := config.parking_hold_grip * mass * float(ProjectSettings.get_setting("physics/3d/default_gravity"))
	if hold.length() > cap:
		hold = hold.normalized() * cap
	apply_central_force(hold)


# True once the car is settled on its wheels (a solid majority in ground contact),
# so the handbrake lock never engages while it's still dropping in / airborne.
func _is_grounded() -> bool:
	var n := 0
	for wheel in _wheel_mounts:
		if wheel.is_in_contact():
			n += 1
	return n >= 3


func reset_to(xform: Transform3D) -> void:
	global_transform = xform
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	steering = 0.0
	_steer = 0.0
	drivetrain.rear_omega = 0.0
	for wheel in drivetrain.front_omega:
		drivetrain.front_omega[wheel] = 0.0
	drivetrain.engine.reset()


# Replace `old_car` with a FRESH car instance configured to `index`, spawned at
# `spawn_xform`, and return the new node. Swapping cars by re-instantiating
# (rather than repeatedly reshaping one body in place) is what keeps them
# drivable: a VehicleBody3D accumulates stale wheel/suspension state when its
# wheels are relocated again and again, which left some cars spinning in place
# with no traction. A fresh body is configured exactly once, which is reliable.
# Callers must re-point anything holding the old car (camera target, HUD).
static func respawn(old_car: Node, index: int, spawn_xform: Transform3D) -> Node:
	var parent := old_car.get_parent()
	old_car.name = "CarRetired"
	# Stop the retired car simulating: queue_free() is deferred to frame end, so
	# without this it would run one more _physics_process AFTER the fresh car's
	# apply_car() has reshaped the shared Config.data (the active car keeps
	# config == Config.data). Reading the new car's gearbox with its own stale gear
	# state (e.g. a 7-speed still in gear 6, now indexing a 3-speed ratio table)
	# throws an out-of-bounds. A car being replaced must not step again.
	old_car.set_physics_process(false)
	old_car.queue_free()
	var fresh := CAR_SCENE.instantiate()
	fresh.name = "Car"
	fresh.transform = spawn_xform
	parent.add_child(fresh)
	fresh.apply_car(index)
	return fresh


# The next car index after this one, wrapping around.
func next_car_index() -> int:
	return (_car_index + 1) % CarLibrary.all().size()


func current_car_name() -> String:
	if _car_index < 0:
		return "Base"
	return CarLibrary.all()[_car_index]["name"]


# Per-car bonnet-camera position offset (metres, in the car's local space), added
# on top of the shared GameConfig.bonnet_offset so each body's hood cam can be
# nudged to sit at the right spot. Zero (baseline) for the untouched car and for
# any entry that doesn't author one. Read by CameraManager.retarget().
func bonnet_cam_offset() -> Vector3:
	if _car_index < 0:
		return Vector3.ZERO
	return CarLibrary.all()[_car_index].get("bonnet_cam_offset", Vector3.ZERO)


# Give this car its OWN private GameConfig (a deep copy of the current global
# baseline) so its apply_car / apply_owned reshape mutates that copy instead of the
# shared Config.data. Call on a non-simulating PROP/display car BEFORE apply_car so
# it can't clobber the active car's engine/gearbox in the global config. The active
# player car does NOT call this — it keeps config == Config.data so the HUD, tuning
# lift, audio synth and save system (all of which read Config.data) reflect it.
func use_isolated_config() -> void:
	var base: GameConfig = config if config != null else Config.data
	config = base.duplicate(true) if base != null else GameConfig.new()


# Reshape and retune the car to a CarLibrary entry: overlays its dimensions,
# mass, drag, engine character and drive layout onto the live config and scene,
# then rebuilds the drivetrain (fresh hardpoints + shift speeds) and engine
# voice so the new sound and gearing take effect. Returns the car's name.
func apply_car(index: int, rebuild_audio := true) -> String:
	var spec: Dictionary = CarLibrary.all()[index]
	_car_index = index
	var cfg: GameConfig = config

	# Physics/config overlay; everything is read live from cfg each physics step.
	cfg.mass = spec["mass"]
	cfg.drag_coefficient = spec["drag"]
	cfg.wheel_radius = spec["wheel_radius"]
	# All engine data (sound + performance + voicing + the TRANSMISSION it's bolted to:
	# gear_ratios / final_drive / shift_time) comes from the referenced engine in
	# EngineLibrary — the single source of truth. apply() writes every engine_* and
	# gearbox field onto cfg before the drivetrain/audio rebuild below, so an engine
	# swap carries its whole drivetrain (see _apply_engine_swap). EngineSim recomputes
	# its shift speeds for the new gearing on the rebuild.
	EngineLibrary.apply(EngineLibrary.by_id(spec["engine"]), cfg)
	# One tyre compound per car (same rubber both axles); seed BOTH runtime axle μ
	# from it. The grip_balance tuning slider (TuningLibrary.apply, run after) shifts
	# them apart. Front/rear GRIP balance otherwise emerges physically from the widths
	# below + weight_front via the drivetrain's load-sensitivity term.
	cfg.wheel_friction_slip_front = spec["tire_compound"]
	cfg.wheel_friction_slip_rear = spec["tire_compound"]
	cfg.wheel_width_front = spec["wheel_width_front"]
	cfg.wheel_width_rear = spec["wheel_width_rear"]
	# Per-car aero downforce (N per (m/s)² at each axle). SET (not added) so a spec of
	# 0 means 0 — no hidden global baseline — and so re-fielding can't accumulate the
	# value. apply_owned applies the aero_kit upgrade ON TOP of this afterwards.
	cfg.downforce_front = spec.get("downforce_front", 0.0)
	cfg.downforce_rear = spec.get("downforce_rear", 0.0)
	# Per-car suspension: overall spring rate + per-axle travel. The front/rear
	# spring RATES are not authored — they're derived from weight_front by
	# GameConfig.axle_stiffness so the heavier axle gets a stiffer spring and the car
	# sits level (see _apply_suspension). Travel defaults to the single suspension_travel
	# unless a spec sets a front/rear value. Dampers stay derived from the resolved
	# per-axle rate. Pushed onto the wheels in the relocation loop below.
	cfg.suspension_travel = spec.get("suspension_travel", cfg.suspension_travel)
	# Per-axle travel overrides: 0 = inherit suspension_travel (axle_travel resolves).
	cfg.suspension_travel_front = spec.get("suspension_travel_front", 0.0)
	cfg.suspension_travel_rear = spec.get("suspension_travel_rear", 0.0)
	cfg.suspension_stiffness = spec.get("suspension_stiffness", cfg.suspension_stiffness)
	mass = cfg.mass

	# Per-car centre of mass from the real static front-axle weight fraction. For
	# static balance the CoM sits behind the front axle by wheelbase x rear_fraction,
	# so measured from the wheelbase centre (the body origin, where the axles sit at
	# +/- half_base along Z; forward is -Z) the offset is wheelbase x (rear_frac - 0.5),
	# +Z = rearward. Switching to CUSTOM overrides Godot's AUTO (which derives a centred
	# CoM from the symmetric collision box). Feeds the static load split onto each axle
	# via the settling suspension -> Drivetrain.wheel_normal_force -> tyre grip balance.
	# Also drives the front/rear spring-rate split (GameConfig.axle_stiffness).
	var front_frac: float = spec.get("weight_front", 0.5)
	cfg.weight_front = front_frac
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0.0, 0.0, spec["wheelbase"] * (1.0 - front_frac - 0.5))

	# Chassis + cabin + collision boxes.
	var body: Vector3 = spec["body"]
	var cabin: Vector3 = spec["cabin"]
	(($Chassis as MeshInstance3D).mesh as BoxMesh).size = body
	(($CollisionShape3D as CollisionShape3D).shape as BoxShape3D).size = (
		Vector3(body.x, body.y - 0.3, body.z)
	)
	var cabin_mesh := $Cabin as MeshInstance3D
	(cabin_mesh.mesh as BoxMesh).size = cabin
	cabin_mesh.position = Vector3(0.0, body.y * 0.5 + cabin.y * 0.45, spec["cabin_z"])

	# Authored-model cars hide the procedural chassis/cabin boxes and show ONE glb body
	# (spec["model_node"]); every other body + the boxes are hidden. The collision box
	# above is shared by both paths. Wheels stay procedural either way.
	var use_model: bool = spec.get("use_model", false)
	var active_node := String(spec.get("model_node", ""))
	for node_name in _model_node_names():
		var model_body := get_node_or_null(NodePath(node_name)) as Node3D
		if model_body == null:
			continue
		var is_active := use_model and node_name == active_node
		model_body.visible = is_active
		if is_active:
			_apply_model_material(model_body, load(String(spec.get("model_texture", ""))))
	($Chassis as MeshInstance3D).visible = not use_model
	cabin_mesh.visible = not use_model

	# Tyre + spoke meshes are duplicated per-instance in _ready() (so multiple
	# car.tscn instances, e.g. the start-line queue props, can't stomp each
	# other's wheel visuals); resize each wheel's own copy here. Reposition each
	# wheel to the new track/wheelbase (origin only, preserving the scene's
	# axle-flip basis) and set its physics radius.
	var radius: float = spec["wheel_radius"]
	var width_front: float = spec["wheel_width_front"]
	var width_rear: float = spec["wheel_width_rear"]
	var half_track: float = spec["track"] * 0.5
	var half_base: float = spec["wheelbase"] * 0.5
	var wheels := find_children("*", "VehicleWheel3D", false)
	for wheel in wheels:
		# Relocate from the AUTHORED mount, not the live transform — the body
		# repaints the wheel's origin with suspension travel each step, so reading
		# it back would let the mount drift (and corrupt contact) on each swap.
		var mount: Vector3 = _wheel_mounts.get(wheel, wheel.position)
		wheel.position = Vector3(signf(mount.x) * half_track, mount.y, signf(mount.z) * half_base)
		wheel.wheel_radius = radius
		# Steering wheels are the front axle; staggered cars get fatter rears.
		var width: float = width_front if wheel.use_as_steering else width_rear
		# Per-car, per-axle suspension (mirrors _ready()'s setup): front/rear rate + travel
		# resolved from weight_front / suspension_travel_{front,rear}, dampers derived per axle.
		_apply_suspension(wheel)
		var tire := wheel.get_node_or_null("Visual/Tire") as MeshInstance3D
		if tire != null:
			var cyl := tire.mesh as CylinderMesh
			cyl.top_radius = radius
			cyl.bottom_radius = radius
			cyl.height = width
			# Per-car wheel cap: the car's own wheel.png, or a blank dark disc.
			tire.set_surface_override_material(0, _wheel_material(String(spec.get("wheel_texture", ""))))
		var spoke := wheel.get_node_or_null("Visual/Spoke1") as MeshInstance3D
		if spoke != null:
			(spoke.mesh as BoxMesh).size = Vector3(width * 0.85, radius * 1.76, 0.06)

	# VehicleWheel3D latches its suspension connection point when it enters the
	# tree and repaints the node transform every physics step, so the position
	# writes above are reverted unless the wheel re-enters the tree. Detach ALL
	# wheels first, then re-attach them: re-adding one at a time while the others
	# are still registered mutates the body's wheel list mid-operation and
	# corrupts contact for the relocated wheels (cars end up spinning in place).
	for wheel in wheels:
		wheel.get_parent().remove_child(wheel)
	for wheel in wheels:
		add_child(wheel)
		wheel.owner = self

	# Rebuild the drivetrain so it re-reads the moved hardpoints and recomputes
	# shift speeds for the new redline/gearing, then set the driven axle layout.
	drivetrain = Drivetrain.new(self)
	drivetrain.terrain = _resolve_terrain()
	drivetrain.drive_mode = spec["drive_mode"] as Drivetrain.DriveMode
	_recompute_axles()

	# Rebuild the engine voice for the new cylinder count / firing order. Skipped when
	# rebuild_audio is false — apply_owned defers it to a single rebuild at the end of
	# the fielding pipeline (after engine swap + upgrades, which can also change the
	# voicing), instead of rebuilding here and again per later step.
	if rebuild_audio:
		var audio := $EngineAudio as Node
		if audio.has_method("reconfigure"):
			audio.reconfigure()

	# Per-car HP pool (CarLibrary metadata, mass-keyed). Free-roam fields it unbound
	# at full HP; a future rally layer re-fields it from the OwnedCar (with the
	# stored HP + instance id) when a car is taken to the Start line.
	var max_hp: float = spec.get("max_hp", damage.max_hp)
	damage.field(max_hp, max_hp)

	_reset()
	return spec["name"]


# Field an OwnedCar (features/rally-session.md fielding pipeline): the CarLibrary
# baseline, then the installed upgrades, then the per-car tuning, then the working
# damage state from the saved HP. Used by world.gd when a RallySession is active;
# free-roam uses apply_car directly (no upgrades/tuning).
func apply_owned(owned: Dictionary) -> String:
	var model_id := String(owned.get("model_id", ""))
	var idx := CarLibrary.index_of(model_id)
	if idx < 0:
		idx = 0
	# Defer the audio rebuild: the engine swap and the upgrades below can both change
	# the audio voicing, so the synth is rebuilt ONCE at the end (see below) rather
	# than by apply_car here and again per step.
	var car_name := apply_car(idx, false)
	# Step 1b: engine swap — if this car runs a non-stock engine, overwrite the
	# engine profile + recompute mass / weight distribution BEFORE upgrades (so a
	# weight-reduction kit scales the new total) and before the suspension re-sync
	# at the end of this function (so the spring split re-derives from the new
	# weight_front). See features/engine-swap.md.
	_apply_engine_swap(owned)
	# Step 2: installed upgrades multiply/extend the live config. apply_car already
	# copied the baseline mass onto the RigidBody, so re-sync after a weight-reduction
	# upgrade mutates cfg.mass (other upgraded fields are read live each physics step).
	UpgradeLibrary.apply(owned, config)
	# Step 3: free, reversible per-car tuning re-balances grip / brake / aero on top
	# of the upgraded baseline (features/tuning.md). Gating (brake/aero) reads the same
	# installed upgrades, so it must run after step 2.
	TuningLibrary.apply(owned, config)
	_sync_suspension_to_wheels()
	mass = config.mass
	# The config is now final (baseline → swap → upgrades → tuning). Rebuild the engine
	# voice ONCE here, so any writer that touched audio voicing is covered — including a
	# turbo fitted as an UPGRADE (whistle/BOV gains + turbo_enabled), not just the
	# engine. The synth caches voicing at build time, so without this a turbo on an NA
	# car would be silent even though its physics reads the config live.
	var audio := $EngineAudio as Node
	if audio.has_method("reconfigure"):
		audio.reconfigure()
	# Step 4: working HP starts at the saved value; bind to the instance so a wreck
	# removes it from the save.
	var entry := CarLibrary.by_id(model_id)
	var max_hp: float = entry.get("max_hp", damage.max_hp) if not entry.is_empty() else damage.max_hp
	damage.field(max_hp, float(owned.get("hp", max_hp)), int(owned.get("instance_id", -1)),
		owned.get("wheel_toe", []))
	return car_name


# Re-field this owned car's engine when it differs from the CarLibrary stock: writes
# the swapped engine's full profile (torque/redline/firing/voicing AND its bolted-on
# transmission — gear_ratios/final_drive/shift_time) over the config, rebuilds the
# drivetrain (new redline/gearing/shift speeds) and engine voice, and recomputes total
# mass + static weight distribution treating the engine as a point mass at the car's
# engine_pos. No-op for a stock car. See features/engine-swap.md.
func _apply_engine_swap(owned: Dictionary) -> void:
	var spec: Dictionary = CarLibrary.all()[_car_index]
	var stock := String(spec.get("engine", ""))
	var current := EngineSwap.current_engine_id(owned, stock)
	if current == stock:
		return
	var new_eng := EngineLibrary.by_id(current)
	if new_eng.is_empty():
		return
	var cfg: GameConfig = config
	EngineLibrary.apply(new_eng, cfg)

	# Rebuild drivetrain (new redline/shift speeds; gearbox ratios already in cfg). The
	# engine voice is NOT rebuilt here — this is only ever called from apply_owned, which
	# rebuilds the synth once after all config mutation (swap + upgrades + tuning).
	drivetrain = Drivetrain.new(self)
	drivetrain.terrain = _resolve_terrain()
	drivetrain.drive_mode = spec["drive_mode"] as Drivetrain.DriveMode
	_recompute_axles()

	# Independent engine weight + position -> new total mass and weight distribution.
	var m0 := float(EngineLibrary.by_id(stock).get("mass", 0.0))
	var m1 := float(new_eng.get("mass", 0.0))
	var spec_mass := float(spec["mass"])
	var spec_wf := float(spec.get("weight_front", 0.5))
	var ef := float(spec.get("engine_pos", spec_wf))
	cfg.mass = EngineSwap.recompute_mass(spec_mass, m0, m1)
	cfg.weight_front = EngineSwap.recompute_weight_front(spec_mass, spec_wf, m0, m1, ef)
	mass = cfg.mass
	center_of_mass = Vector3(0.0, 0.0, spec["wheelbase"] * (0.5 - cfg.weight_front))


# Bend each wheel by its persisted damage toe (radians) via the per-wheel
# VehicleWheel3D.steering — a physical steer angle the drivetrain tire model reads
# for the force direction, so a damaged car pulls/crabs from the physics alone.
# Front (steering) wheels carry the live steer PLUS their toe; rear wheels (which
# the body never steers) carry only their toe. Called every physics frame right
# after the base steering is set, so it also re-asserts over the body's per-frame
# overwrite of the front wheels. The wheel visuals read wheel.steering too, so the
# bend is visible. See DamageModel.nudge_wheels / features/damage.md.
func _apply_wheel_toe() -> void:
	if damage == null:
		return
	for wheel in drivetrain.front_wheels:
		wheel.steering = steering + float(damage.wheel_toe.get(wheel.name, 0.0))
	for wheel in drivetrain.rear_wheels:
		wheel.steering = float(damage.wheel_toe.get(wheel.name, 0.0))


# Whether a wheel sits on the front axle. Front wheels are mounted at negative
# local Z (forward = -Z); read the AUTHORED mount when known so this is stable even
# after physics repaints the live transform (the repaint moves the wheel along the
# suspension axis, not in Z, so the sign holds regardless — but the mount is cleaner).
func _wheel_is_front(wheel: VehicleWheel3D) -> bool:
	return float(_wheel_mounts.get(wheel, wheel.position).z) < 0.0


# Push the resolved per-axle spring rate + travel + derived dampers onto one wheel.
# Front and rear differ: the rate is split from the overall suspension_stiffness by
# weight_front (axle_stiffness) so the heavier axle is stiffer and the car sits level;
# travel comes from suspension_travel_{front,rear}; dampers are critically damped for
# the wheel's OWN rate. The single place all three setup sites funnel through.
func _apply_suspension(wheel: VehicleWheel3D) -> void:
	var cfg: GameConfig = config
	var front := _wheel_is_front(wheel)
	var k: float = cfg.axle_stiffness(front)
	var travel: float = cfg.axle_travel(front)
	wheel.suspension_travel = travel
	wheel.wheel_rest_length = travel
	wheel.suspension_stiffness = k
	wheel.damping_compression = cfg.suspension_damping_compression(k)
	wheel.damping_relaxation = cfg.suspension_damping_relaxation(k)


# Re-push the live per-axle suspension onto all four wheels (apply_car does this
# inline while relocating wheels; this is the standalone version for when an upgrade
# changes cfg.suspension_stiffness after apply_car).
func _sync_suspension_to_wheels() -> void:
	for wheel in find_children("*", "VehicleWheel3D", false):
		_apply_suspension(wheel)


# Give every MeshInstance3D in the authored body model the lit PS1 material
# (ps1_models_lit.gdshader) carrying the model's baked texture, so the glb stays in
# the same unshaded / quantize / dither / fog pipeline as the rest of the scene
# instead of using its imported Blender material. albedo_color is left white so
# the texture's own colours show through (ALBEDO = texture × albedo_color).
# Idempotent: the material is built once per mesh.
# Names of the authored glb body nodes in car.tscn (hidden unless a spec selects one).
func _model_node_names() -> PackedStringArray:
	return PackedStringArray(["Mx5Body", "FocusBody", "TwingoBody", "ActyBody", "ChargerBody", "TheBeastBody", "Porsche911Body"])


func _apply_model_material(model: Node3D, texture: Texture2D) -> void:
	var shader: Shader = load("res://shaders/ps1_models_lit.gdshader")
	for mesh in model.find_children("*", "MeshInstance3D", true):
		var mi := mesh as MeshInstance3D
		var mat := mi.get_surface_override_material(0) as ShaderMaterial
		if mat == null or mat.shader != shader:
			mat = ShaderMaterial.new()
			mat.shader = shader
			mat.set_shader_parameter("texture_tile", Vector2(1, 1))
			mat.set_shader_parameter("albedo_color", Color.WHITE)
			mat.set_shader_parameter("albedo_texture", texture)
			# Same fake per-vertex lighting as the procedural car meshes (see
			# world.gd) so the authored body gets shape too, not just flat colour.
			config.apply_car_light(mat)
			mi.set_surface_override_material(0, mat)


# A ShaderMaterial for the tire caps using `tex_path` (a wheel.png), or a blank dark
# disc when empty. albedo_color (the rubber tread) is left at the shader default;
# world.gd repaints it live, same as before.
func _wheel_material(tex_path: String) -> ShaderMaterial:
	if _wheel_mats.has(tex_path):
		return _wheel_mats[tex_path]
	var mat := ShaderMaterial.new()
	mat.shader = WHEEL_SHADER
	mat.set_shader_parameter("albedo_texture", _blank_wheel_texture() if tex_path == "" else load(tex_path))
	# The tread colour + PS1 fake lighting that world.gd used to push onto the shared
	# tire material — now carried by each per-car material (world.gd's push lands on the
	# scene's default .tres, which apply_car replaces with this).
	mat.set_shader_parameter("albedo_color", config.wheel_color)
	config.apply_car_light(mat)
	_wheel_mats[tex_path] = mat
	return mat


static func _blank_wheel_texture() -> ImageTexture:
	if _blank_wheel_tex == null:
		var img := Image.create(1, 1, false, Image.FORMAT_RGB8)
		img.set_pixel(0, 0, Color(0.10, 0.10, 0.10))
		_blank_wheel_tex = ImageTexture.create_from_image(img)
	return _blank_wheel_tex
