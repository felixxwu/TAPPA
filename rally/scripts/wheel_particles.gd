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

# Floats per MultiMesh instance for TRANSFORM_3D with no colour/custom data: a
# 3x4 matrix, with the origin at offsets 3/7/11. We keep every instance's basis
# at identity (the billboard material orients the quad anyway) and only ever
# rewrite the three origin floats — so the whole pool is one PackedFloat32Array
# we push with a SINGLE multimesh.buffer assignment per tick instead of N
# per-instance set_instance_transform() calls (the latter is the classic
# MultiMesh perf trap — N engine round-trips a frame murders mobile/WebGL).
const STRIDE := 12
# Dead particles are parked far below the world (origin Y) rather than zero-scaled —
# billboard materials don't reliably honour a zero instance scale under
# gl_compatibility, but a quad this far down is always off-screen, so it draws
# nothing visible.
const HIDE_Y := -1.0e7

# Surface gate thresholds against TerrainManager.surface_at (road_weight, tarmac_weight).
# The wheel must be at least half onto the road (else it's grass) AND on the gravel
# half (else it's tarmac, which throws no dirt). 0.5 is the midpoint of the same
# feather bands the road colour/grip blend across.
const ROAD_WEIGHT_MIN := 0.5
const TARMAC_WEIGHT_MAX := 0.5

var _car: Node                 # the VehicleBody3D (read for drivetrain + position)

# Particle pool (parallel arrays, index == MultiMesh instance == ring slot).
var _pos: PackedVector3Array
var _vel: PackedVector3Array
var _life: PackedFloat32Array  # remaining lifetime (s); <= 0 means the slot is dead
var _buffer: PackedFloat32Array  # the live MultiMesh transform buffer (STRIDE floats/slot)
var _next := -1                # ring-buffer write cursor (advances, wraps, recycles oldest)
var _alive := 0
var _max := 0


# Wire to the current car. The wheel/surface state is read live off the car's
# drivetrain each tick (spin, driven axle, the terrain that classifies the
# surface), so nothing else needs threading through here.
func setup(car: Node) -> void:
	_car = car
	_build_pool()


# Re-point at a freshly spawned car (a car swap) and clear all live particles.
func retarget(car: Node) -> void:
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
	# Pre-seed every slot's transform with an identity basis (rows on the diagonal)
	# and a hidden origin. From here on only the three origin floats per slot ever
	# change, so the buffer never has to rebuild bases.
	_buffer = PackedFloat32Array()
	_buffer.resize(_max * STRIDE)
	for i in _max:
		var b := i * STRIDE
		_buffer[b + 0] = 1.0   # basis row 0 x
		_buffer[b + 5] = 1.0   # basis row 1 y
		_buffer[b + 10] = 1.0  # basis row 2 z
	_clear()


# Set a slot's instance origin in the buffer (basis stays identity).
func _set_origin(i: int, p: Vector3) -> void:
	var b := i * STRIDE
	_buffer[b + 3] = p.x
	_buffer[b + 7] = p.y
	_buffer[b + 11] = p.z


# Park a slot off-screen (dead).
func _hide_slot(i: int) -> void:
	var b := i * STRIDE
	_buffer[b + 3] = 0.0
	_buffer[b + 7] = HIDE_Y
	_buffer[b + 11] = 0.0


# Kill every particle and park its instance off-screen.
func _clear() -> void:
	_next = -1
	_alive = 0
	if multimesh == null or _buffer.is_empty():
		return
	for i in _max:
		_life[i] = 0.0
		_hide_slot(i)
	multimesh.buffer = _buffer


func _physics_process(delta: float) -> void:
	if not Config.data.wheel_particles_enabled or multimesh == null:
		return
	# Advance the existing spray (gravity + drag + lifetime) so airborne clods
	# finish their arc even after the wheels stop spinning, then emit new dirt.
	# Both write straight into _buffer; the GPU upload is a SINGLE assignment at
	# the end, only when something actually moved or spawned this tick.
	var changed := _advance(delta)
	if is_instance_valid(_car) and _car.get("drivetrain") != null:
		if _emit_from_wheels():
			changed = true
	if changed:
		multimesh.buffer = _buffer


# Integrate the live pool one step into _buffer: gravity pulls each clod down, a
# slight linear air drag bleeds speed off to sell its weight, and lifetime
# recycles it. Returns true if any slot changed (so the caller uploads once). A
# no-op when nothing is alive — an idle car does zero per-frame particle work.
func _advance(delta: float) -> bool:
	if delta <= 0.0 or _alive == 0:
		return false  # tests tick with delta 0 to emit without ageing the pool
	var cfg: GameConfig = Config.data
	var g := cfg.wheel_particle_gravity_mps2
	var drag := maxf(0.0, 1.0 - cfg.wheel_particle_air_resistance * delta)
	for i in _max:
		if _life[i] <= 0.0:
			continue
		_life[i] -= delta
		if _life[i] <= 0.0:
			_alive -= 1
			_hide_slot(i)
			continue
		var v := _vel[i]
		v.y -= g * delta
		v *= drag
		_vel[i] = v
		_pos[i] += v * delta
		_set_origin(i, _pos[i])
	return true


# Spawn dirt from every driven wheel that is in contact, spinning faster than the
# ground, and sitting on the gravel road. Reads the live drivetrain each tick, so
# a car swap (which rebuilds the drivetrain) needs no extra wiring here. Returns
# true if anything was emitted (so the caller uploads the buffer once).
func _emit_from_wheels() -> bool:
	var cfg: GameConfig = Config.data
	var dt = _car.drivetrain
	var terrain = dt.terrain
	# No surface info (flat test fixtures / not yet wired) means we can't tell
	# gravel from grass or tarmac, so spray nothing rather than guess.
	if terrain == null or not terrain.has_method("surface_at"):
		return false
	var r: float = cfg.wheel_radius
	var min_slip: float = cfg.wheel_particle_min_slip_mps
	var emitted := false
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
		# faster than it is rolling forward. Cheapest test, so gate on it first.
		if surface_speed - fwd.dot(vel) < min_slip:
			continue
		# Surface gate (one cheap terrain lookup): spray ONLY on the gravel road —
		# not grass (off the road footprint), not tarmac (paved throws no dirt).
		# surface_at -> (road_weight 0=grass..1=road, tarmac_weight 0=gravel..1=tarmac).
		var surf: Vector2 = terrain.surface_at(wpos.x, wpos.z)
		if surf.x < ROAD_WEIGHT_MIN or surf.y > TARMAC_WEIGHT_MAX:
			continue
		_spray(cfg, cp, fwd, vel, surface_speed)
		emitted = true
	return emitted


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
	_set_origin(_next, pos)  # caller uploads the whole buffer once per tick


# --- Readouts (tests) --------------------------------------------------------

func live_count() -> int:
	return _alive


func max_particles() -> int:
	return _max
