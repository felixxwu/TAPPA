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

# Contacts the chassis reports per physics tick for the damage model. The car only
# ever touches a few obstacles at once; a small cap keeps contact monitoring cheap.
const MAX_CONTACTS_REPORTED := 8

# Re-emitted from the car's DamageModel when working HP hits 0 (a run DNF). A
# fielded car has already been removed from the save by then; the rally/menu layer
# (features/rally-session.md) listens here. See features/damage.md.
signal wrecked()

var _start_transform: Transform3D
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
var _car_index := -1  # selected CarLibrary entry, or -1 for the untouched baseline
var _wheel_mounts: Dictionary = {}  # wheel -> authored local mount (scene rest pose)
var _debug_overlay: WheelForceDebug  # the wheel-force arrow overlay (toggled by H)

# When true, driver input is ignored and the handbrake is forced on, so the car
# physically holds still (e.g. during the stage countdown). Set by StageManager;
# the rest of the simulation (drag, suspension, camera) keeps running so the car
# settles naturally. See todo/stage-start-and-end.md §2.
var controls_locked := false

# Scripted ("AI") control for non-player cars — the start-line queue (scripts/
# start_line.gd) drives the leader/trailer with full physics so they pull away and
# roll up with real suspension load. When true the car ignores global Input and
# drives from these values instead (same axes/sign as the player inputs). Use axis
# locks on the body to keep such a car straight; see start_line.gd.
var ai_controlled := false
var ai_throttle := 0.0    # -1..1, forward positive (brake_reverse..accelerate axis)
var ai_steer := 0.0       # -1..1, left positive (steer_right..steer_left axis)
var ai_handbrake := false


func _ready() -> void:
	var cfg: GameConfig = Config.data
	# Spawn the car spawn_clearance metres above the ground at its xz, so the
	# wheels never start clipping under the terrain regardless of how high the
	# surface is there. This transform is also what reset / car swaps restore.
	_start_transform = global_transform
	_start_transform.origin.y = _ground_height_at(_start_transform.origin) + cfg.spawn_clearance
	global_transform = _start_transform
	mass = cfg.mass
	linear_damp = 0.0  # aero drag below is the only speed-dependent loss
	for wheel in find_children("*", "VehicleWheel3D", false):
		# All contact friction is handled by the Drivetrain tire model; the
		# built-in solver only does suspension + raycasts.
		wheel.wheel_friction_slip = 0.0
		wheel.suspension_travel = cfg.suspension_travel
		wheel.wheel_rest_length = cfg.suspension_travel
		wheel.suspension_stiffness = cfg.suspension_stiffness
		wheel.damping_compression = cfg.suspension_damping_compression()
		wheel.damping_relaxation = cfg.suspension_damping_relaxation()
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
	damage.field(damage.max_hp, damage.max_hp, false)
	damage.wrecked.connect(_on_wrecked)
	_debug_overlay = WheelForceDebug.new(self)
	_debug_overlay.visible = cfg.debug_wheel_forces
	add_child(_debug_overlay)
	_recompute_axles()


# Terrain surface height at a world position, used to seat the spawn above the
# ground. Looks for a sibling that exposes height_at (the hilly Floor in the
# main scene); on the flat test fixtures (a WorldBoundary at y=0) there is none,
# so it falls back to 0.
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
	var cfg: GameConfig = Config.data
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
	var handbrake := ai_handbrake if ai_controlled else (controls_locked or Input.is_action_pressed("handbrake"))
	# Damage power loss: fade the driven torque as HP falls (1.0 healthy). 0 effect
	# at full HP / for the immortal starter. See features/damage.md.
	drivetrain.power_scale = damage.power_multiplier(cfg)
	drivetrain.step(delta, drive, brake_input, handbrake)

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
	var travel_angle := 0.0
	if Vector2(local_vel.x, local_vel.z).length() > 2.0 and local_vel.z < 0.0:
		# Yaw of the travel direction relative to the car's forward (-Z),
		# positive to the left like VehicleWheel3D steering. Clamped so a deep
		# slide can't spin the wheels to extreme angles. Only applied when
		# moving forwards; when slow or reversing, plain input steering.
		travel_angle = clampf(atan2(-local_vel.x, -local_vel.z), -PI / 3.0, PI / 3.0)
	var steer_input := ai_steer if ai_controlled else (0.0 if controls_locked else Input.get_axis("steer_right", "steer_left"))
	# Ramp the travel alignment in linearly from 0 at standstill to its full
	# configured value at steer_assist_min_speed (≈30 km/h), so it doesn't fight
	# low-speed input steering yet returns smoothly with no sudden jump as speed
	# builds. Shares the threshold with the steer-assist torque ramp below.
	var align_scale := clampf(speed / cfg.steer_assist_min_speed, 0.0, 1.0)
	var steer_target := travel_angle * cfg.steer_travel_alignment * align_scale + steer_input * cfg.steer_limit
	# Damage wheel-alignment pull: a constant bias toward one side that grows as HP
	# falls (0 at full HP / for the immortal starter). See features/damage.md.
	steer_target += damage.steer_bias(cfg)
	steering = move_toward(steering, steer_target, cfg.steer_speed * delta)
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
	var rotated_into_turn := -travel_angle * signf(steer_input)
	var angle_scale := 1.0
	if cfg.steer_assist_max_angle > 0.0:
		angle_scale = clampf(1.0 - rotated_into_turn / cfg.steer_assist_max_angle, 0.0, 1.0)
	apply_torque(global_transform.basis.y * steer_input * cfg.steer_assist_torque * assist_scale * angle_scale)

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
	var cfg: GameConfig = Config.data
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
func reset_to(xform: Transform3D) -> void:
	global_transform = xform
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
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
	old_car.queue_free()
	var fresh := CAR_SCENE.instantiate()
	fresh.name = "Car"
	fresh.transform = spawn_xform
	parent.add_child(fresh)
	fresh.apply_car(index)
	return fresh


# The next car index after this one, wrapping around.
func next_car_index() -> int:
	return (_car_index + 1) % CarLibrary.CARS.size()


func current_car_name() -> String:
	if _car_index < 0:
		return "Base"
	return CarLibrary.CARS[_car_index]["name"]


# Reshape and retune the car to a CarLibrary entry: overlays its dimensions,
# mass, drag, engine character and drive layout onto the live config and scene,
# then rebuilds the drivetrain (fresh hardpoints + shift speeds) and engine
# voice so the new sound and gearing take effect. Returns the car's name.
func apply_car(index: int) -> String:
	var spec: Dictionary = CarLibrary.CARS[index]
	_car_index = index
	var cfg: GameConfig = Config.data

	# Physics/config overlay. engine_type's setter re-applies the sound + power
	# preset; everything else is read live from cfg each physics step.
	cfg.mass = spec["mass"]
	cfg.drag_coefficient = spec["drag"]
	cfg.wheel_radius = spec["wheel_radius"]
	# engine_type's setter overwrites peak_torque + redline from the preset, so
	# apply the car's real published power figures AFTER it. Tyre grip is the
	# front/rear friction.
	cfg.engine_type = spec["engine_type"]
	cfg.peak_torque = spec["peak_torque"]
	cfg.redline_rpm = spec["redline"]
	# Per-car gearbox: real transmission ratios + final drive overlay the shared
	# defaults. Set AFTER the engine preset (which only touches torque/redline/
	# firing) and BEFORE the drivetrain rebuild below, so EngineSim recomputes its
	# shift speeds for the new gearing. Build a typed Array[float] (the dict value
	# is an untyped literal), mirroring GameConfig._apply_engine_preset.
	if spec.has("gear_ratios"):
		var ratios: Array[float] = []
		for gr in spec["gear_ratios"]:
			ratios.append(float(gr))
		cfg.gear_ratios = ratios
	cfg.final_drive = spec.get("final_drive", cfg.final_drive)
	cfg.wheel_friction_slip_front = spec["grip_front"]
	cfg.wheel_friction_slip_rear = spec["grip_rear"]
	cfg.shift_time = spec["shift_time"]
	# Per-car aero downforce (N per (m/s)² at each axle). SET (not added) so a spec of
	# 0 means 0 — no hidden global baseline — and so re-fielding can't accumulate the
	# value. apply_owned applies the aero_kit upgrade ON TOP of this afterwards.
	cfg.downforce_front = spec.get("downforce_front", 0.0)
	cfg.downforce_rear = spec.get("downforce_rear", 0.0)
	# Per-car crank + flywheel rotating inertia (kg·m²): small revs fast, large
	# revs lazily. Cars that omit it keep the config fallback.
	cfg.engine_inertia = spec.get("engine_inertia", cfg.engine_inertia)
	cfg.engine_low_octave_mix = spec.get("low_octave_mix", 0.0)
	cfg.engine_volume_db = spec.get("volume_db", cfg.engine_volume_db)
	# Per-car noise floor authored in dB; convert to the linear amplitude the
	# synth uses. Cars that omit noise_db keep the config's engine_noise_level.
	if spec.has("noise_db"):
		cfg.engine_noise_level = db_to_linear(spec["noise_db"])
	cfg.engine_soft_clip_post_gain = spec.get("soft_clip_post_gain", cfg.engine_soft_clip_post_gain)
	# Per-car suspension: spring travel + rate. Dampers stay derived from
	# stiffness (see GameConfig.suspension_damping_*). Pushed onto the wheels in
	# the relocation loop below; Drivetrain reads stiffness live off the wheel.
	cfg.suspension_travel = spec.get("suspension_travel", cfg.suspension_travel)
	cfg.suspension_stiffness = spec.get("suspension_stiffness", cfg.suspension_stiffness)
	mass = cfg.mass

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
	var width: float = spec["wheel_width"]
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
		# Per-car suspension (mirrors _ready()'s setup): travel doubles as the
		# raycast rest length; dampers are re-derived from the new stiffness.
		wheel.suspension_travel = cfg.suspension_travel
		wheel.wheel_rest_length = cfg.suspension_travel
		wheel.suspension_stiffness = cfg.suspension_stiffness
		wheel.damping_compression = cfg.suspension_damping_compression()
		wheel.damping_relaxation = cfg.suspension_damping_relaxation()
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

	# Rebuild the engine voice for the new cylinder count / firing order.
	var audio := $EngineAudio as Node
	if audio.has_method("reconfigure"):
		audio.reconfigure()

	# Per-car HP pool (CarLibrary metadata, mass-keyed). Free-roam fields it unbound
	# at full HP; a future rally layer re-fields it from the OwnedCar (with the
	# stored HP + instance id) when a car is taken to the Start line.
	var max_hp: float = spec.get("max_hp", damage.max_hp)
	damage.field(max_hp, max_hp, false)

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
	var car_name := apply_car(idx)
	# Step 2: installed upgrades multiply/extend the live config. apply_car already
	# copied the baseline mass onto the RigidBody, so re-sync after a weight-reduction
	# upgrade mutates cfg.mass (other upgraded fields are read live each physics step).
	UpgradeLibrary.apply(owned, Config.data)
	# Step 3: free, reversible per-car tuning re-balances grip / brake / aero on top
	# of the upgraded baseline (features/tuning.md). Gating (brake/aero) reads the same
	# installed upgrades, so it must run after step 2.
	TuningLibrary.apply(owned, Config.data)
	_sync_suspension_to_wheels()
	mass = Config.data.mass
	# Step 4: working HP starts at the saved value; bind to the instance so a wreck
	# removes it from the save (the immortal starter skips depletion).
	var entry := CarLibrary.by_id(model_id)
	var max_hp: float = entry.get("max_hp", damage.max_hp) if not entry.is_empty() else damage.max_hp
	damage.field(max_hp, float(owned.get("hp", max_hp)),
		bool(owned.get("immortal", false)), int(owned.get("instance_id", -1)))
	return car_name


# Re-push the live suspension stiffness + derived dampers onto all four wheels
# (apply_car does this inline while relocating wheels; this is the standalone
# version for when an upgrade changes cfg.suspension_stiffness after apply_car).
func _sync_suspension_to_wheels() -> void:
	var cfg: GameConfig = Config.data
	for wheel in find_children("*", "VehicleWheel3D", false):
		wheel.suspension_stiffness = cfg.suspension_stiffness
		wheel.damping_compression = cfg.suspension_damping_compression()
		wheel.damping_relaxation = cfg.suspension_damping_relaxation()


# Give every MeshInstance3D in the authored body model the lit PS1 material
# (ps1_models_lit.gdshader) carrying the model's baked texture, so the glb stays in
# the same unshaded / quantize / dither / fog pipeline as the rest of the scene
# instead of using its imported Blender material. albedo_color is left white so
# the texture's own colours show through (ALBEDO = texture × albedo_color).
# Idempotent: the material is built once per mesh.
# Names of the authored glb body nodes in car.tscn (hidden unless a spec selects one).
func _model_node_names() -> PackedStringArray:
	return PackedStringArray(["Mx5Body", "FocusBody"])


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
			Config.data.apply_car_light(mat)
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
	mat.set_shader_parameter("albedo_color", Config.data.wheel_color)
	Config.data.apply_car_light(mat)
	_wheel_mats[tex_path] = mat
	return mat


static func _blank_wheel_texture() -> ImageTexture:
	if _blank_wheel_tex == null:
		var img := Image.create(1, 1, false, Image.FORMAT_RGB8)
		img.set_pixel(0, 0, Color(0.10, 0.10, 0.10))
		_blank_wheel_tex = ImageTexture.create_from_image(img)
	return _blank_wheel_tex
