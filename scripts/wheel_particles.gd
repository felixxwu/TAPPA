class_name WheelParticles
extends CpuParticlePool
# Cheap debris flung backwards from the driven wheels whenever they spin faster
# than the ground — a burnout, a wheelspin launch, or a spinning slide. A
# hand-rolled CPU pool drawn through ONE MultiMesh of billboarded quads (the
# shared ring-buffer machinery lives in CpuParticlePool).
#
# ONE pool serves every surface. Each particle carries its own colour, half-extents
# and roll, chosen at emit time from the surface under the wheel:
#   - gravel road -> a squarish grey-brown clod of dirt,
#   - grass (off the road footprint) -> a slim green blade,
#   - tarmac -> nothing at all (paved throws no debris).
# Sharing one ring buffer means the total particle cost stays hard-capped at
# wheel_particle_max no matter which surface the car is on, and it stays a single
# draw call.
#
# Created + wired by world.gd._generate_track (reused across event regenerations,
# re-targeted on a car swap, exactly like TireMarks). See features/wheel-dust.md.

# Screen-aligned billboard with a per-instance roll/size/colour. BaseMaterial3D's
# BILLBOARD_ENABLED discards the instance basis (keeping only the origin), so a
# per-particle rotation has nowhere to live under the stock material — hence the
# hand-written billboard. See the shader header for the basis layout contract.
const PARTICLE_SHADER := preload("res://shaders/billboard_particle.gdshader")

# Floats per MultiMesh instance for TRANSFORM_3D + per-instance colour: a 3x4
# matrix (row-major; origin at offsets 3/7/11) followed by RGBA. The basis is no
# longer a fixed identity — it encodes each particle's half-extents (column
# lengths) and roll (column 0's direction), written ONCE at emit and left alone
# afterwards, so the per-tick integration still rewrites only the three origin
# floats. The whole pool is one PackedFloat32Array pushed with a SINGLE
# multimesh.buffer assignment per tick instead of N per-instance
# set_instance_transform() calls (the latter is the classic MultiMesh perf trap —
# N engine round-trips a frame murders mobile/WebGL).
const STRIDE := 16

# Surface gate thresholds against TerrainManager.surface_at (road_weight, tarmac_weight).
# Below ROAD_WEIGHT_MIN the wheel is off the road footprint (grass); on the road, above
# TARMAC_WEIGHT_MAX it is paved (no debris). 0.5 is the midpoint of the same feather
# bands the road colour/grip blend across.
const ROAD_WEIGHT_MIN := 0.5
const TARMAC_WEIGHT_MAX := 0.5

var _car: Node                 # the VehicleBody3D (read for drivetrain + position)


func _stride() -> int:
	return STRIDE


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


# Build (or rebuild) the MultiMesh + particle pool to the configured cap. The mesh
# is a single UNIT quad shared by every instance — the real size is per-particle,
# baked into the instance basis, so one mesh covers both the square clods and the
# slim blades.
func _build_pool() -> void:
	var cfg: GameConfig = Config.data
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var mat := ShaderMaterial.new()
	mat.shader = PARTICLE_SHADER
	material_override = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = quad
	mm.instance_count = maxi(1, cfg.wheel_particle_max)
	multimesh = mm
	_alloc_pool(mm.instance_count)
	_clear()


# --- Per-particle appearance -------------------------------------------------

# The look of one particle: half-extents (metres) and colour. Chosen at emit time
# from the surface under the wheel and then frozen for the particle's whole life.
class Look:
	extends RefCounted
	var half_w: float
	var half_h: float
	var color: Color
	func _init(w: float, h: float, c: Color) -> void:
		half_w = w
		half_h = h
		color = c


# The gravel clod: a square of dirt, sized off the shared wheel_particle_size_m.
static func _gravel_look(cfg: GameConfig) -> Look:
	var half := cfg.wheel_particle_size_m * 0.5
	return Look.new(half, half, cfg.wheel_particle_color)


# The grass blade: a slim tall sliver of green.
static func _grass_look(cfg: GameConfig) -> Look:
	return Look.new(
		cfg.wheel_particle_grass_width_m * 0.5,
		cfg.wheel_particle_grass_length_m * 0.5,
		cfg.wheel_particle_grass_color)


# Vary a look's colour brightness a little per particle so a burst reads as many
# separate bits of debris rather than one flat-coloured smear. Free now that each
# instance carries its own colour. Alpha is untouched (the pool is opaque).
static func _jittered(cfg: GameConfig, base: Color) -> Color:
	var j: float = cfg.wheel_particle_color_jitter
	if j <= 0.0:
		return base
	var f := 1.0 + randf_range(-j, j)
	return Color(base.r * f, base.g * f, base.b * f, base.a)


# --- Buffer writes -----------------------------------------------------------

# Write a slot's full appearance: half-extents + roll into the basis, position into
# the origin, colour into the trailing RGBA. Called once per particle at emit; from
# then on only _set_origin runs, so the roll/size/colour stay frozen for its life.
#
# The basis layout is the contract billboard_particle.gdshader reads:
#   column 0 = (cos * half_w, sin * half_w, 0)   -> length = half_w, direction = roll
#   column 1 = (-sin * half_h, cos * half_h, 0)  -> length = half_h
# Stored row-major, so column 0 is floats 0/4/8 and column 1 is floats 1/5/9.
func _write_slot(i: int, p: Vector3, look: Look, roll: float, color: Color) -> void:
	var b := i * STRIDE
	var c := cos(roll)
	var s := sin(roll)
	_buffer[b + 0] = c * look.half_w
	_buffer[b + 4] = s * look.half_w
	_buffer[b + 8] = 0.0
	_buffer[b + 1] = -s * look.half_h
	_buffer[b + 5] = c * look.half_h
	_buffer[b + 9] = 0.0
	_buffer[b + 2] = 0.0
	_buffer[b + 6] = 0.0
	_buffer[b + 10] = 1.0
	_buffer[b + 3] = p.x
	_buffer[b + 7] = p.y
	_buffer[b + 11] = p.z
	_buffer[b + 12] = color.r
	_buffer[b + 13] = color.g
	_buffer[b + 14] = color.b
	_buffer[b + 15] = color.a


# Set a slot's instance origin in the buffer (basis + colour stay as emitted).
func _set_origin(i: int, p: Vector3) -> void:
	var b := i * STRIDE
	_buffer[b + 3] = p.x
	_buffer[b + 7] = p.y
	_buffer[b + 11] = p.z


# Park a slot off-screen (dead). Only the origin needs moving — a quad this far
# below the world never rasterises, whatever basis/colour it still carries.
func _hide_slot(i: int) -> void:
	var b := i * STRIDE
	_buffer[b + 3] = 0.0
	_buffer[b + 7] = HIDE_Y
	_buffer[b + 11] = 0.0


# A warmed-up slot must actually DRAW so the shader variant compiles, so give it a
# full gravel look rather than the zeroed (degenerate) basis a fresh pool carries.
func _build_slot(i: int, p: Vector3) -> void:
	var cfg: GameConfig = Config.data
	var look := _gravel_look(cfg)
	_write_slot(i, p, look, 0.0, look.color)


func _physics_process(delta: float) -> void:
	var __t := Time.get_ticks_usec()
	_timed_physics_process(delta)
	PerfLog.track(&"wheel_particles", Time.get_ticks_usec() - __t)


func _timed_physics_process(delta: float) -> void:
	if not Config.data.wheel_particles_enabled or multimesh == null:
		return
	# Advance the existing debris (gravity + drag + lifetime) so airborne bits
	# finish their arc even after the wheels stop spinning, then emit new ones.
	# Both write straight into _buffer; the GPU upload is a SINGLE assignment at
	# the end, only when something actually moved or spawned this tick.
	var changed := _advance(delta)
	if is_instance_valid(_car) and _car.get("drivetrain") != null:
		if _emit_from_wheels():
			changed = true
	if changed:
		multimesh.buffer = _buffer


# Integrate the live pool one step into _buffer: gravity pulls each particle down,
# a slight linear air drag bleeds speed off to sell its weight, and lifetime
# recycles it. Returns true if any slot changed (so the caller uploads once). A
# no-op when nothing is alive — an idle car does zero per-frame particle work.
# Only the origin is rewritten; the emitted roll/size/colour are left frozen.
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


# Spawn debris from every driven wheel that is in contact and spinning faster than
# the ground, in the flavour the surface under it calls for. Reads the live
# drivetrain each tick, so a car swap (which rebuilds the drivetrain) needs no
# extra wiring here. Returns true if anything was emitted (so the caller uploads
# the buffer once).
func _emit_from_wheels() -> bool:
	var cfg: GameConfig = Config.data
	var dt = _car.drivetrain
	var terrain = dt.terrain
	# No surface info (flat test fixtures / not yet wired) means we can't tell
	# gravel from grass or tarmac, so throw nothing rather than guess.
	if terrain == null or not terrain.has_method("surface_at"):
		return false
	var r: float = cfg.wheel_radius
	var min_slip: float = cfg.wheel_particle_min_slip_mps
	var emitted := false
	for wheel in dt.all_wheels:
		# Undriven wheels free-roll — they never fling debris however fast they turn.
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
		# One cheap terrain lookup picks the flavour.
		# surface_at -> (road_weight 0=grass..1=road, tarmac_weight 0=gravel..1=tarmac).
		var look := _look_for_surface(cfg, terrain.surface_at(wpos.x, wpos.z))
		if look == null:
			continue  # tarmac: paved throws nothing
		_spray(cfg, look, cp, fwd, vel, surface_speed)
		emitted = true
	return emitted


# Pick the particle look for a surface sample, or null when the surface throws
# nothing. Off the road footprint it's grass; on the road it's gravel unless the
# road is paved there.
func _look_for_surface(cfg: GameConfig, surf: Vector2) -> Look:
	if surf.x < ROAD_WEIGHT_MIN:
		return _grass_look(cfg)
	if surf.y > TARMAC_WEIGHT_MAX:
		return null
	return _gravel_look(cfg)


# Fling a burst of particles from one wheel's contact patch. The throw direction is
# where the tread is actually scrubbing the ground (vel − tread surface velocity):
# in a standing burnout that is straight backwards along the wheel's heading, and
# in a spinning slide it tilts sideways too — debris sprays the way it's really
# dragged. Speed tracks the wheel's spin (surface_speed), tipped slightly upward.
func _spray(cfg: GameConfig, look: Look, cp: Vector3, fwd: Vector3, vel: Vector3, surface_speed: float) -> void:
	# Tread surface velocity relative to the ground at the contact patch. The tread
	# at the bottom runs backwards (−fwd) at the spin speed; subtract it from the
	# chassis velocity to get how the patch is sliding over the ground.
	var scrub := vel - fwd * surface_speed
	var dir := scrub.normalized() if scrub.length() > 0.01 else -fwd
	var throw_speed := surface_speed * cfg.wheel_particle_speed_scale
	var base := dir * throw_speed + Vector3.UP * cfg.wheel_particle_up_speed_mps
	var spread := cfg.wheel_particle_spread * throw_speed
	for _n in maxi(1, cfg.wheel_particle_spawn_count):
		# Random cone around the base throw (upward-biased y so debris arcs up, not
		# down into the ground) plus a small spawn scatter across the contact patch.
		var jitter := Vector3(
			randf_range(-1.0, 1.0), randf_range(0.0, 1.0), randf_range(-1.0, 1.0)
		) * spread
		var ppos := cp + Vector3(
			randf_range(-0.1, 0.1), randf_range(0.0, 0.05), randf_range(-0.1, 0.1)
		)
		_emit(cfg, look, ppos, base + jitter)


# Write one particle into the ring buffer, recycling the oldest slot when full.
# Its roll is a frozen random angle picked here (a tumbling blade would mean
# rewriting the basis every tick; a fixed spawn angle costs nothing after emit).
func _emit(cfg: GameConfig, look: Look, pos: Vector3, vel: Vector3) -> void:
	_emit_slot(pos, vel, cfg.wheel_particle_lifetime_s)
	# caller uploads the whole buffer once per tick
	_write_slot(_next, pos, look, randf_range(0.0, TAU), _jittered(cfg, look.color))
