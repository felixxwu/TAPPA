class_name Drivetrain
extends RefCounted
# Custom drivetrain + tire model. Godot's wheel friction is disabled
# (wheel_friction_slip = 0); VehicleBody3D only provides suspension and the
# wheel raycasts. This object owns the wheel spin states, integrates torques,
# computes combined-slip tire forces and applies them at the contact patches.
#
# Spin states: one omega for the rear axle (a locked spool), one per front
# wheel. A DRIVEN axle is a locked spool, so the front entries are kept equal
# whenever the front axle is powered: FWD locks the two fronts together, and
# AWD locks the front spool to the rear into one rigid driveline (no centre
# diff). Only undriven front wheels (RWD) free-roll independently. Per tick:
# tire forces are computed from the slip between wheel surface speed and ground
# speed; their longitudinal component reacts back on the spin state; drive/brake
# torques integrate on top.
#
# The spin states are SUBSTEPPED within each physics tick: the axle inertia is
# small enough that a single explicit force/reaction exchange overshoots, the
# longitudinal slip flips sign every tick, and the tire force oscillates (the
# chassis only feels the average, but the debug arrows whip around). Substeps
# hold the chassis velocity fixed, converge omega against the grip curve, and
# the chassis receives the time-averaged force.

const SPIN_SUBSTEPS := 8

enum DriveMode { RWD, AWD, FWD }

var car: VehicleBody3D
var engine: EngineSim
var drive_mode := DriveMode.RWD  # which axle(s) the engine drives
# Terrain that resolves the surface under each wheel (a TerrainManager exposing
# surface_at(x, z) -> (road_weight, tarmac_weight)). Set by car.gd from its Floor
# sibling; null on the flat test fixtures, where every wheel keeps the base μ.
var terrain: Object = null
var rear_wheels: Array = []
var front_wheels: Array = []
# Replay override: VehicleWheel3D -> omega (rad/s). Non-empty only during
# replay playback, where the body is frozen and the true spin is zero; the
# effect systems (wheel_particles, tire_marks) read wheel_omega, so feeding
# the recorded spin here reproduces gravel spray + skid marks. Empty = normal.
var replay_omega: Dictionary = {}
var hardpoints: Dictionary = {}  # wheel -> rest-pose local position
var rear_omega := 0.0  # rad/s, locked axle (both rear wheels)
var front_omega: Dictionary = {}  # front wheel -> rad/s
var spin_angle: Dictionary = {}  # wheel -> accumulated visual angle (rad)
var visuals: Dictionary = {}  # wheel -> Node3D spun about the axle
# wheel -> {normal: float, demand: Vector3, applied: Vector3} for debug arrows.
# Only populated while `publish_readouts` is on (the WheelForceDebug overlay sets
# it to its own visibility) — building these per-wheel dicts every physics tick is
# pure waste in a normal run where nothing reads them.
var readouts: Dictionary = {}
var publish_readouts := false


func _init(p_car: VehicleBody3D) -> void:
	car = p_car
	# EngineSim + this drivetrain read the CAR's own config (Config.data for the active
	# car, an isolated copy for prop/display cars) so a second car instance's apply_car
	# can't clobber this car's engine/gearbox. See car.gd `config`.
	engine = EngineSim.new(car.config)
	drive_mode = car.config.drive_mode as DriveMode
	for wheel in car.find_children("*", "VehicleWheel3D", false):
		hardpoints[wheel] = wheel.position
		spin_angle[wheel] = 0.0
		visuals[wheel] = wheel.get_node_or_null("Visual")
		if wheel.use_as_traction:
			rear_wheels.append(wheel)
		else:
			front_wheels.append(wheel)
			front_omega[wheel] = 0.0


# throttle: 0..1 drive request (reverse comes from the engine's gear).
# brake: 0..1 foot brake. handbrake: bool (rear brake torque + AWD centre-diff open).
# declutch: open the engine clutch (normally = handbrake, so a held handbrake lets the
# engine rev free; the finish stop passes it false so the engine stays coupled and
# winds down with the braking wheels instead of free-revving — see car.gd).
func step(delta: float, throttle: float, brake: float, handbrake: bool, declutch: bool) -> void:
	var cfg: GameConfig = car.config
	readouts.clear()
	var r := cfg.wheel_radius

	# Per-wheel contact context, fixed for the whole tick (chassis state is
	# held constant across substeps; only the spin states evolve).
	var contacts: Array = []
	for wheel in hardpoints:
		if not wheel.is_in_contact():
			continue
		var n_force := wheel_normal_force(wheel)
		if n_force <= 0.0:
			continue
		var cp: Vector3 = wheel.get_contact_point()
		var fwd := wheel_forward(wheel)
		var side := wheel_side(wheel)
		var vel := velocity_at(cp)
		# One terrain query for all three surface-dependent tire params (μ mult,
		# optimum-slip location, sliding plateau) at this contact.
		var surf := surface_tire_params(cfg, cp)
		contacts.append({
			wheel = wheel, cp = cp, fwd = fwd, side = side,
			v_long = fwd.dot(vel), s_lat = -side.dot(vel),
			n_force = n_force,
			slip_peak = surf.slip_peak,
			slide_ratio = surf.slide_ratio,
			mu = (
				cfg.wheel_friction_slip_front if wheel.use_as_steering
				else cfg.wheel_friction_slip_rear
			) * surf.mu_mult * cfg.tire_load_factor(
				n_force,
				cfg.wheel_width_front if wheel.use_as_steering else cfg.wheel_width_rear
			),
			impulse_long = 0.0, impulse_lat = 0.0,
		})

	var h := delta / float(SPIN_SUBSTEPS)
	# Foot-brake torque split front/rear by cfg.brake_bias (the brake_bias tuning
	# knob, features/tuning.md). The * 2.0 normalises so brake_bias = 0.5 reproduces the
	# old equal split exactly (front = rear = brake * brake_torque).
	var total_brake := brake * cfg.brake_torque * 2.0
	var front_brake := total_brake * cfg.brake_bias  # per front wheel
	var rear_brake := total_brake * (1.0 - cfg.brake_bias) + (cfg.handbrake_torque if handbrake else 0.0)
	var front_inertia := cfg.axle_inertia * 0.5  # per front wheel
	# A driven axle is a locked spool. front_spool_inertia/brake fold the two
	# front wheels into one unit for FWD/AWD.
	var front_n := float(front_wheels.size())
	var front_spool_inertia := front_inertia * front_n
	var front_spool_brake := front_brake * front_n
	# Per front wheel (open RWD). Hoisted out of the substep loop and cleared each
	# pass so it isn't reallocated on every substep (only read in the RWD branch).
	var front_reaction_each: Dictionary = {}
	for k in SPIN_SUBSTEPS:
		# Tire forces at the current spin state; accumulate their impulse and
		# collect the reaction torques on the spin states.
		var rear_reaction := 0.0  # N·m slowing the rear axle
		var front_reaction := 0.0  # summed over front contacts (spool)
		front_reaction_each.clear()
		for c in contacts:
			var f := _tire_force(cfg, c, _omega_of(c.wheel) * r, h)
			c.impulse_long += f.x * h
			c.impulse_lat += f.y * h
			if c.wheel.use_as_traction:
				rear_reaction += f.x * r
			else:
				front_reaction += f.x * r
				front_reaction_each[c.wheel] = f.x * r

		# The engine is geared to the driven axle(s); its total wheel torque
		# (drive, engine braking and shift cuts all live in EngineSim — including the
		# damage misfire, a stochastic fuel cut that drops crank torque as HP falls).
		# Brakes move omega toward zero but never reverse it (no sign flip-flop).
		var drive_torque := engine.step(h, throttle, driveline_omega(), declutch)
		match drive_mode:
			DriveMode.AWD:
				if handbrake:
					# Handbrake exception: open the centre diff so ONLY the rear
					# axle locks. Both axles run as undriven braked spools for the
					# pull (engine torque is cut); the rear takes the handbrake
					# torque and locks, while the front spool free-rolls and stays
					# steerable.
					rear_omega += -rear_reaction / cfg.axle_inertia * h
					rear_omega = move_toward(
						rear_omega, 0.0, rear_brake / cfg.axle_inertia * h
					)
					var spool := _front_avg_omega()
					spool += -front_reaction / front_spool_inertia * h
					spool = move_toward(
						spool, 0.0, front_spool_brake / front_spool_inertia * h
					)
					for wheel in front_wheels:
						front_omega[wheel] = spool
				else:
					# One rigid driveline: rear spool + front spool, all locked.
					var inertia: float = cfg.axle_inertia + front_spool_inertia
					rear_omega += (
						(drive_torque - rear_reaction - front_reaction) / inertia * h
					)
					rear_omega = move_toward(
						rear_omega, 0.0, (rear_brake + front_spool_brake) / inertia * h
					)
					for wheel in front_wheels:
						front_omega[wheel] = rear_omega
			DriveMode.FWD:
				# Front driven spool; rear axle free-rolls (reaction + brake only).
				rear_omega += -rear_reaction / cfg.axle_inertia * h
				rear_omega = move_toward(rear_omega, 0.0, rear_brake / cfg.axle_inertia * h)
				var spool := _front_avg_omega()
				spool += (drive_torque - front_reaction) / front_spool_inertia * h
				spool = move_toward(spool, 0.0, front_spool_brake / front_spool_inertia * h)
				for wheel in front_wheels:
					front_omega[wheel] = spool
			_:  # RWD: rear driven spool; fronts free-roll independently (open).
				rear_omega += (drive_torque - rear_reaction) / cfg.axle_inertia * h
				rear_omega = move_toward(rear_omega, 0.0, rear_brake / cfg.axle_inertia * h)
				for wheel in front_wheels:
					var omega: float = front_omega[wheel]
					omega += -front_reaction_each.get(wheel, 0.0) / front_inertia * h
					omega = move_toward(omega, 0.0, front_brake / front_inertia * h)
					front_omega[wheel] = omega

	# Apply the time-averaged tire force to the chassis and publish readouts.
	# Both the longitudinal and lateral forces have their roll/pitch lever (the
	# height of the application point above the centre of mass) scaled by
	# wheel_roll_influence: 0 applies them at CoM height (no body roll from
	# cornering, no pitch dive/squat from braking/throttle, rollover-proof) and 1
	# at the contact patch (full physical roll and pitch). The horizontal lever is
	# kept intact either way so the lateral force still yaws the car into the turn
	# and the longitudinal force still acts along the contact patch.
	var share := car.mass / float(hardpoints.size())
	var up := car.global_transform.basis.y
	for c in contacts:
		var long_force: Vector3 = c.fwd * c.impulse_long / delta
		var lat_force: Vector3 = c.side * c.impulse_lat / delta
		var offset: Vector3 = c.cp - car.global_position
		var vertical: Vector3 = up * up.dot(offset)
		var rolled_offset: Vector3 = (offset - vertical) + vertical * cfg.wheel_roll_influence
		car.apply_force(long_force, rolled_offset)
		car.apply_force(lat_force, rolled_offset)
		if publish_readouts:
			readouts[c.wheel] = {
				normal = c.n_force,
				demand = (
					c.fwd * (_omega_of(c.wheel) * r - c.v_long) + c.side * c.s_lat
				) * share / delta,
				applied = long_force + lat_force,
			}

	for wheel in hardpoints:
		spin_angle[wheel] = fmod(spin_angle[wheel] + _omega_of(wheel) * delta, TAU)
	_update_visuals()


# Wheel meshes spin from the SIMULATED omega, not Godot's ground-speed
# estimate, so wheelspin and lockup are visible. The Visual node's basis is
# rebuilt in wheel-local space: the VehicleWheel3D node auto-rotates about
# its own axle for display, so we counter it by overwriting the child's
# global basis from the car + steering + our spin angle. The wheel nodes are
# rotated 180° about Y in the scene, hence the PI. The Y flip also mirrors
# the local X (axle) axis, so positive omega rolling the wheel forward
# (car -Z) needs a POSITIVE rotation about the flipped axle.
# Replay playback: step() doesn't run, so advance the wheel visual spin from the
# recorded per-wheel omega (in replay_omega) and rebuild the visuals. Called by
# car.gd._process during a replay, after the car's transform is applied.
func replay_spin(delta: float) -> void:
	for wheel in visuals:
		var om: float = float(replay_omega.get(wheel, 0.0))
		spin_angle[wheel] = fmod(float(spin_angle.get(wheel, 0.0)) + om * delta, TAU)
	_update_visuals()


func _update_visuals() -> void:
	for wheel in visuals:
		var visual: Node3D = visuals[wheel]
		if visual == null:
			continue
		visual.global_basis = (
			car.global_basis
			* Basis(Vector3.UP, wheel.steering + PI)
			* Basis(Vector3.RIGHT, spin_angle[wheel])
		)


func _omega_of(wheel: VehicleWheel3D) -> float:
	return rear_omega if wheel.use_as_traction else front_omega[wheel]


# Public read of a wheel's simulated spin (rad/s). Lets other systems (the wheel
# dust particles) detect wheelspin from the real spin state without poking the
# private per-wheel/axle dictionaries directly.
func wheel_omega(wheel: VehicleWheel3D) -> float:
	if not replay_omega.is_empty() and replay_omega.has(wheel):
		return float(replay_omega[wheel])
	return _omega_of(wheel)


# Whether the engine currently powers this wheel, per the drive mode. Undriven
# wheels free-roll, so they never fling dirt no matter how fast they turn — the
# wheel-dust system uses this to gate emission to the driven axle(s).
func is_wheel_driven(wheel: VehicleWheel3D) -> bool:
	match drive_mode:
		DriveMode.AWD:
			return true
		DriveMode.FWD:
			return not wheel.use_as_traction
		_:  # RWD
			return wheel.use_as_traction


# Advance RWD -> AWD -> FWD -> RWD (the UI / keyboard toggle).
func cycle_drive_mode() -> void:
	drive_mode = ((drive_mode + 1) % 3) as DriveMode


# The wheel speed the engine is geared to: the driven axle(s)' representative
# spin. FWD reads the front spool; RWD and AWD read the rear — in AWD the
# locked centre diff makes the front spool equal to the rear, so rear_omega
# already is the single driveline speed.
func driveline_omega() -> float:
	return _front_avg_omega() if drive_mode == DriveMode.FWD else rear_omega


func _front_avg_omega() -> float:
	if front_omega.is_empty():
		return rear_omega
	var total := 0.0
	for w in front_omega:
		total += front_omega[w]
	return total / front_omega.size()


# Tire force for one contact at the given wheel surface speed, as
# (longitudinal, lateral) newtons. h is the substep duration for the
# stability caps; the contact context c is fixed for the tick. cfg is passed in
# (rather than re-fetched) — this runs once per contact per substep.
func _tire_force(cfg: GameConfig, c: Dictionary, surface_vel: float, h: float) -> Vector2:
	# Slip velocity of the contact patch vs the ground (m/s). Positive s_long_v =
	# wheel surface running ahead of the ground (wheelspin) -> force forward.
	var s_long_v: float = surface_vel - c.v_long
	var s_lat_v: float = c.s_lat
	# Normalize slip velocities into dimensionless slip before the grip curve, so
	# grip peaks at a constant slip *angle* (lateral) / slip *ratio* (long) rather
	# than a constant slip *speed*. Reference is the patch's planar ground speed
	# (sqrt of the two ground-velocity components — s_lat_v IS the lateral ground
	# velocity, c.v_long the longitudinal one), floored so we never divide by ~0
	# at creep. s_lat / v_ref is then sin(slip angle), s_long / v_ref the slip
	# ratio; both stay bounded when the car is barely moving.
	var v_ref: float = maxf(sqrt(c.v_long * c.v_long + s_lat_v * s_lat_v), cfg.tire_norm_floor)
	var s_long := s_long_v / v_ref
	var s_lat := s_lat_v / v_ref
	# Traction ellipse via scaled slip space: weight longitudinal slip by the
	# ratio, take the grip curve on the combined magnitude, then unscale the
	# longitudinal force component (max long force = μN / ratio).
	var er: float = cfg.traction_ellipse_ratio
	var scaled := Vector2(s_long * er, s_lat)
	var s := scaled.length()
	if s < 0.0001:
		return Vector2.ZERO
	var f_scaled: Vector2 = scaled / s * c.mu * c.n_force * _grip_curve(c.slip_peak, c.slide_ratio, s)
	var f_long: float = f_scaled.x / er
	var f_lat: float = f_scaled.y
	# Stability caps: never push harder than would zero a slip component
	# within one substep. These use the RAW slip velocities (m/s), so the
	# standstill divide-by-zero guarantee is preserved regardless of v_ref.
	# Longitudinal uses the smaller of the chassis share and the axle's effective
	# contact mass (I / r²) — the wheel side reacts much faster than the chassis;
	# lateral has no spin state, chassis only.
	var share := car.mass / float(hardpoints.size())
	var spin_mass: float = cfg.axle_inertia * 0.5 / (cfg.wheel_radius * cfg.wheel_radius)
	var long_cap: float = absf(s_long_v) * minf(share, spin_mass) / h
	f_long = clampf(f_long, -long_cap, long_cap)
	f_lat = clampf(f_lat, -absf(s_lat_v) * share / h, absf(s_lat_v) * share / h)
	return Vector2(f_long, f_lat)


# Per-wheel surface grip multiplier on the base μ at a contact point. Asks the
# terrain for the (road, tarmac) weights there and blends the configured
# grass / gravel / tarmac scales across the same feathered bands the road colour
# uses: road weight fades grass→road, tarmac weight fades gravel→tarmac. With no
# terrain (flat fixtures) the multiplier is 1.0, so the base μ is unchanged.
func surface_grip(cfg: GameConfig, cp: Vector3) -> float:
	return surface_tire_params(cfg, cp).mu_mult


# All three surface-dependent tire params at a contact point, from ONE terrain
# query: μ multiplier, the normalized optimum-slip location, and the sliding
# plateau. Each is blended across the same feathered grass↔road / gravel↔tarmac
# bands the road colour uses. Off terrain (flat fixtures) μ is unscaled (1.0) and
# the shape falls back to the global tire_slip_peak / sliding_grip_ratio.
func surface_tire_params(cfg: GameConfig, cp: Vector3) -> Dictionary:
	if terrain == null or not terrain.has_method("surface_at"):
		return {
			mu_mult = 1.0,
			slip_peak = cfg.tire_slip_peak,
			slide_ratio = cfg.sliding_grip_ratio,
		}
	var s: Vector2 = terrain.surface_at(cp.x, cp.z)
	return {
		mu_mult = _surface_blend(cfg.grass_grip, cfg.gravel_grip, cfg.tarmac_grip, s),
		slip_peak = _surface_blend(cfg.grass_slip_peak, cfg.gravel_slip_peak, cfg.tarmac_slip_peak, s),
		slide_ratio = _surface_blend(cfg.grass_slide_ratio, cfg.gravel_slide_ratio, cfg.tarmac_slide_ratio, s),
	}


# Blend a per-surface value across the terrain's (road, tarmac) weights: tarmac
# weight fades gravel→tarmac, road weight fades grass→road.
func _surface_blend(grass: float, gravel: float, tarmac: float, s: Vector2) -> float:
	var road := lerpf(gravel, tarmac, s.y)
	return lerpf(grass, road, s.x)


# The normalized optimum slip (slip_peak) the STEERING axle is currently on,
# averaged over the front wheels in ground contact. This is what the steering
# aids key off to bound the front tires to their peak-grip slip angle
# (asin(slip_peak)) for the surface underneath them. Falls back to the global
# tire_slip_peak when no front wheel is grounded (airborne) or off terrain.
func steering_axle_slip_peak(cfg: GameConfig) -> float:
	var total := 0.0
	var n := 0
	for wheel in front_wheels:
		if wheel.is_in_contact():
			total += surface_tire_params(cfg, wheel.get_contact_point()).slip_peak
			n += 1
	return (total / n) if n > 0 else cfg.tire_slip_peak


# Grip fraction (0..1 of μN) for a combined NORMALIZED slip s (dimensionless,
# from _tire_force), given this contact's surface-resolved shape: linear up to
# slip_peak, then falling off to slide_ratio over three more peaks.
func _grip_curve(slip_peak: float, slide_ratio: float, s: float) -> float:
	if s <= slip_peak:
		return s / slip_peak
	var t := clampf((s - slip_peak) / (3.0 * slip_peak), 0.0, 1.0)
	return lerpf(1.0, slide_ratio, t)


# Normal force the suspension presses this wheel into the ground with,
# mirroring the engine's spring + damper model. Zero when airborne.
func wheel_normal_force(wheel: VehicleWheel3D) -> float:
	if not wheel.is_in_contact():
		return 0.0
	var cp: Vector3 = wheel.get_contact_point()
	var down := -car.global_transform.basis.y
	var hardpoint: Vector3 = car.global_transform * hardpoints[wheel]
	var length: float = (cp - hardpoint).dot(down) - wheel.wheel_radius
	var compression: float = wheel.wheel_rest_length - length
	var proj_vel := wheel.get_contact_normal().dot(velocity_at(cp))
	var damping: float = (
		wheel.damping_compression if proj_vel < 0.0 else wheel.damping_relaxation
	)
	return maxf(
		car.mass * (wheel.suspension_stiffness * compression - damping * proj_vel), 0.0
	)


# The wheel's rolling direction projected onto the contact plane. Built from
# the car's forward plus the steering angle — the wheel node's own basis
# spins about its axle as it rolls, so it can't be used directly.
func wheel_forward(wheel: VehicleWheel3D) -> Vector3:
	var n: Vector3 = wheel.get_contact_normal()
	var fwd := (-car.global_transform.basis.z).rotated(
		car.global_transform.basis.y, wheel.steering
	)
	return (fwd - n * n.dot(fwd)).normalized()


func wheel_side(wheel: VehicleWheel3D) -> Vector3:
	return wheel_forward(wheel).cross(wheel.get_contact_normal()).normalized()


func velocity_at(point: Vector3) -> Vector3:
	return car.linear_velocity + car.angular_velocity.cross(point - car.global_position)
