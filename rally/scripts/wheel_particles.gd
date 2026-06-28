class_name WheelParticles
extends MultiMeshInstance3D
# Cheap gravel/dirt spray flung backwards from the driven wheels whenever they
# spin faster than the ground — a burnout, a wheelspin launch, or a spinning
# slide. The gl_compatibility renderer (desktop + mobile) has no Decals and no
# GPU-particle physics to lean on, so this is the cheapest particle that still
# reads as a clod of dirt: a hand-rolled CPU pool drawn through ONE MultiMesh of
# small billboarded quads. One draw call, one shared 2-triangle mesh, a fixed
# instance count, and no per-particle scene nodes.
#
# Created + wired by world.gd._generate_track (reused across event regenerations,
# re-targeted on a car swap, exactly like TireMarks). The pool is a fixed-size
# ring buffer: new particles overwrite the oldest slot, so memory and draw cost
# are hard-capped no matter how long the wheels spin. See features/wheel-dust.md.

# Windowed nearest-offset search of the centerline (mirrors TireMarks), so the
# road gate stays local on a winding stage instead of snapping to a far section.
const SEARCH_BACK_M := 30.0
const SEARCH_FWD_M := 60.0
const SEARCH_STEP_M := 1.0
const WHEEL_WINDOW_M := 20.0

# Dead particles are parked far below the world rather than zero-scaled — billboard
# materials don't reliably honour a zero instance scale under gl_compatibility, but
# a quad this far down is always off-screen, so it costs nothing visible.
const HIDE_TRANSFORM := Transform3D(Basis(), Vector3(0.0, -1.0e7, 0.0))

var _car: Node                 # the VehicleBody3D (read for drivetrain + position)
var _centerline: Curve2D
var _baked_length := 0.0
var _half_width := 3.0         # road half-width (track_width * 0.5)
var _offset := 0.0             # cached windowed nearest-offset for the car centre

# Particle pool (parallel arrays, index == MultiMesh instance == ring slot).
var _pos: PackedVector3Array
var _vel: PackedVector3Array
var _life: PackedFloat32Array  # remaining lifetime (s); <= 0 means the slot is dead
var _next := -1                # ring-buffer write cursor (advances, wraps, recycles oldest)
var _alive := 0
var _max := 0


# Wire to a freshly generated track + the current car. half_width is the road
# half-width (track_width * 0.5) the spray is gated to (off it = grass/verge).
func setup(centerline: Curve2D, car: Node, half_width: float) -> void:
	_centerline = centerline
	_baked_length = centerline.get_baked_length() if centerline != null else 0.0
	_half_width = half_width
	_offset = 0.0
	_car = car
	_build_pool()


# Re-point at a freshly spawned car (a car swap) and clear all live particles.
func retarget(car: Node) -> void:
	_offset = 0.0
	_car = car
	_clear()


# Build (or rebuild) the MultiMesh + particle pool to the configured cap. The
# mesh is a single small quad shared by every instance; the material is unshaded,
# billboarded and cull-disabled (same style as the debug/tire-mark overlays).
func _build_pool() -> void:
	var cfg: GameConfig = Config.data
	_max = maxi(1, cfg.wheel_particle_max)
	var quad := QuadMesh.new()
	quad.size = Vector2(cfg.wheel_particle_size_m, cfg.wheel_particle_size_m)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.albedo_color = cfg.wheel_particle_color
	material_override = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = quad
	mm.instance_count = _max
	multimesh = mm
	_pos = PackedVector3Array(); _pos.resize(_max)
	_vel = PackedVector3Array(); _vel.resize(_max)
	_life = PackedFloat32Array(); _life.resize(_max)
	_clear()


# Kill every particle and park its instance off-screen.
func _clear() -> void:
	_next = -1
	_alive = 0
	if multimesh == null:
		return
	for i in _max:
		_life[i] = 0.0
		multimesh.set_instance_transform(i, HIDE_TRANSFORM)


func _physics_process(delta: float) -> void:
	if not Config.data.wheel_particles_enabled or multimesh == null:
		return
	# Always advance the existing spray (gravity + drag + lifetime) so airborne
	# clods finish their arc even when the wheels have stopped spinning.
	_advance(delta)
	if not is_instance_valid(_car) or _car.get("drivetrain") == null:
		return
	_emit_from_wheels()


# Integrate the live pool one step: gravity pulls each clod down, a slight linear
# air drag bleeds speed off to sell its weight, and lifetime recycles it. Dead
# slots are parked off-screen so the MultiMesh draws nothing for them.
func _advance(delta: float) -> void:
	if delta <= 0.0:
		return  # tests tick with delta 0 to emit without ageing the pool
	var cfg: GameConfig = Config.data
	var g := cfg.wheel_particle_gravity_mps2
	var drag := maxf(0.0, 1.0 - cfg.wheel_particle_air_resistance * delta)
	for i in _max:
		if _life[i] <= 0.0:
			continue
		_life[i] -= delta
		if _life[i] <= 0.0:
			_alive -= 1
			multimesh.set_instance_transform(i, HIDE_TRANSFORM)
			continue
		var v := _vel[i]
		v.y -= g * delta
		v *= drag
		_vel[i] = v
		_pos[i] += v * delta
		multimesh.set_instance_transform(i, Transform3D(Basis(), _pos[i]))


# Spawn dirt from every driven wheel that is in contact, spinning faster than the
# ground, and sitting on the gravel road. Reads the live drivetrain each tick, so
# a car swap (which rebuilds the drivetrain) needs no extra wiring here.
func _emit_from_wheels() -> void:
	var cfg: GameConfig = Config.data
	var dt = _car.drivetrain
	var r: float = cfg.wheel_radius
	var min_slip: float = cfg.wheel_particle_min_slip_mps
	# Refresh the car's road offset only when something is actually spinning, so the
	# centerline search is skipped entirely on a clean drive.
	var offset_ready := false
	for wheel in dt.front_wheels + dt.rear_wheels:
		# Undriven wheels free-roll — they never fling dirt however fast they turn.
		if not dt.is_wheel_driven(wheel):
			continue
		if not wheel.is_in_contact():
			continue
		var wpos: Vector3 = wheel.global_position
		var cp := Vector3(wpos.x, wpos.y - r, wpos.z)  # contact patch (hub minus radius)
		var fwd: Vector3 = dt.wheel_forward(wheel)
		var vel: Vector3 = dt.velocity_at(cp)
		var surface_speed: float = dt.wheel_omega(wheel) * r
		# Wheelspin is the wheel surface OUTRUNNING the ground along the rolling
		# direction (v_long), NOT the car's total speed — so a car that is sliding
		# sideways at speed still counts as spinning as long as the tread is turning
		# faster than it is rolling forward.
		var v_long: float = fwd.dot(vel)
		var long_slip: float = surface_speed - v_long
		if long_slip < min_slip:
			continue
		# Gate to the gravel: off the road footprint (the verge / grass) flings
		# nothing. TODO(tarmac): once a paved surface type exists, also skip wheels
		# spinning on tarmac here — tarmac throws no dirt. (features/wheel-dust.md)
		if not _on_gravel(Vector2(wpos.x, wpos.z), offset_ready):
			continue
		offset_ready = true
		_spray(cfg, cp, fwd, vel, surface_speed)


# Fling a burst of clods from one wheel's contact patch. The throw direction is
# where the tread is actually scrubbing the ground (vel − tread surface velocity):
# in a standing burnout that is straight backwards along the wheel's heading, and
# in a spinning slide it tilts sideways too — dirt sprays the way it's really
# dragged. Speed tracks the wheel's spin (surface_speed), tipped slightly upward.
func _spray(cfg: GameConfig, cp: Vector3, fwd: Vector3, vel: Vector3, surface_speed: float) -> void:
	# Tread surface velocity relative to the ground at the contact patch. The tread
	# at the bottom runs backwards (−fwd) at the spin speed; subtract it from the
	# chassis velocity to get how the patch is sliding over the ground.
	var scrub := vel - fwd * surface_speed
	var dir := scrub.normalized() if scrub.length() > 0.01 else -fwd
	var throw_speed := surface_speed * cfg.wheel_particle_speed_scale
	var base := dir * throw_speed + Vector3.UP * cfg.wheel_particle_up_speed_mps
	var spread := cfg.wheel_particle_spread * throw_speed
	for _n in maxi(1, cfg.wheel_particle_spawn_count):
		# Random cone around the base throw (upward-biased y so clods arc up, not
		# down into the ground) plus a small spawn scatter across the contact patch.
		var jitter := Vector3(
			randf_range(-1.0, 1.0), randf_range(0.0, 1.0), randf_range(-1.0, 1.0)
		) * spread
		var ppos := cp + Vector3(
			randf_range(-0.1, 0.1), randf_range(0.0, 0.05), randf_range(-0.1, 0.1)
		)
		_emit(cfg, ppos, base + jitter)


# Write one particle into the ring buffer, recycling the oldest slot when full.
func _emit(cfg: GameConfig, pos: Vector3, vel: Vector3) -> void:
	_next = (_next + 1) % _max
	if _life[_next] <= 0.0:
		_alive += 1  # reused a dead slot; overwriting a live one keeps the count
	_pos[_next] = pos
	_vel[_next] = vel
	_life[_next] = cfg.wheel_particle_lifetime_s
	multimesh.set_instance_transform(_next, Transform3D(Basis(), pos))


# True when a wheel position is on the gravel road footprint (half-width plus a
# verge margin). `seeded` says the per-car offset cache is already fresh this tick.
func _on_gravel(xz: Vector2, seeded: bool) -> bool:
	if _centerline == null:
		return false
	if not seeded:
		_offset = _search_offset(
			Vector2(_car.global_position.x, _car.global_position.z),
			_offset - SEARCH_BACK_M, _offset + SEARCH_FWD_M
		)
	var gate: float = _half_width + Config.data.wheel_particle_gravel_margin_m
	var w_off := _search_offset(xz, _offset - WHEEL_WINDOW_M, _offset + WHEEL_WINDOW_M)
	return xz.distance_to(_centerline.sample_baked(w_off)) <= gate


func _search_offset(here: Vector2, from_m: float, to_m: float) -> float:
	var lo := maxf(0.0, from_m)
	var hi := minf(_baked_length, to_m)
	var best_o := lo
	var best_d := INF
	var o := lo
	while o <= hi:
		var d := here.distance_squared_to(_centerline.sample_baked(o))
		if d < best_d:
			best_d = d
			best_o = o
		o += SEARCH_STEP_M
	return best_o


# --- Readouts (tests) --------------------------------------------------------

func live_count() -> int:
	return _alive


func max_particles() -> int:
	return _max
