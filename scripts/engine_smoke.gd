class_name EngineSmoke
extends MultiMeshInstance3D
# Grey smoke that puffs from the bonnet each time a DAMAGED engine misfires (a fuel
# cut — see features/damage.md). Modelled on WheelParticles: the gl_compatibility
# renderer has no GPU-particle physics, so this is a hand-rolled CPU pool drawn
# through ONE MultiMesh of billboarded quads — one draw call, a fixed instance count,
# a ring buffer that recycles the oldest slot. Its own SMALL pool, separate from the
# wheel dust (a light haze, not a spray).
#
# Unlike the dust, each smoke particle GROWS (scale written into the MultiMesh basis
# diagonal) and FADES (per-instance alpha via MultiMesh instance colours) over its
# life, so it reads as dissipating smoke rather than a hard clod.
#
# Created + wired by world.gd (reused across event regenerations, re-targeted on a
# car swap, exactly like WheelParticles). Emission is driven by EngineSim.misfire_count:
# each new cut since last tick puffs one burst. See features/engine-smoke.md.

# Floats per MultiMesh instance for TRANSFORM_3D + COLOR: a 3x4 matrix (origin at
# 3/7/11) then an RGBA colour at 12..15. We write the basis diagonal (uniform scale
# for growth), the origin, and the alpha (fade) each tick.
const STRIDE := 16
# Dead particles are parked far below the world rather than zero-scaled — billboard
# materials don't reliably honour a zero instance scale under gl_compatibility.
const HIDE_Y := -1.0e7

var _car: Node  # the VehicleBody3D (read for drivetrain.engine + world transform)

# Particle pool (parallel arrays, index == MultiMesh instance == ring slot).
var _pos: PackedVector3Array
var _vel: PackedVector3Array
var _life: PackedFloat32Array   # remaining lifetime (s); <= 0 means the slot is dead
var _max_life: PackedFloat32Array  # lifetime the slot was born with (for grow/fade fraction)
var _buffer: PackedFloat32Array   # the live MultiMesh transform+colour buffer
var _next := -1                 # ring-buffer write cursor
var _alive := 0
var _max := 0
# Last EngineSim.misfire_count we turned into puffs — the delta each tick is the
# number of new cuts to emit for.
var _last_misfire_count := 0
# Synthetic mode (HQ / other out-of-event displays): the car is frozen and its engine
# never runs, so there are no misfire cutouts to key off. Instead we self-time puffs
# from the car's damage severity, so a badly-damaged car still smokes on display. See
# features/engine-smoke.md.
var _synthetic := false
var _puff_timer := 0.0


func setup(car: Node) -> void:
	_car = car
	_synthetic = false
	_last_misfire_count = _engine_misfire_count()
	_build_pool()


# Set up for an out-of-event display (HQ car park / lift): puffs are self-timed from
# the car's damage severity instead of engine misfire cutouts. Parent this to a
# STATIC scene node (not the car), like the event pool, so it keeps running even
# though the display car is frozen / process-disabled.
func setup_synthetic(car: Node) -> void:
	_car = car
	_synthetic = true
	_puff_timer = 0.0
	_build_pool()


# Re-point at a freshly spawned car (a car swap rebuilds the engine, so its
# misfire_count restarts) and clear all live smoke.
func retarget(car: Node) -> void:
	_car = car
	_last_misfire_count = _engine_misfire_count()
	_clear()


# The current car's engine misfire counter, or our last value if the car/engine
# isn't wired yet (so the delta is 0 and nothing spurious puffs).
func _engine_misfire_count() -> int:
	if is_instance_valid(_car) and _car.get("drivetrain") != null and _car.drivetrain.engine != null:
		return _car.drivetrain.engine.misfire_count
	return _last_misfire_count


func _build_pool() -> void:
	var cfg: GameConfig = Config.data
	_max = maxi(1, cfg.engine_smoke_max)
	var quad := QuadMesh.new()
	quad.size = Vector2(cfg.engine_smoke_size_m, cfg.engine_smoke_size_m)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Per-instance colour (the fade) drives albedo; disable depth write so stacked
	# transparent puffs don't fight the depth buffer.
	mat.vertex_color_use_as_albedo = true
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	material_override = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = quad
	mm.instance_count = _max
	multimesh = mm
	_pos = PackedVector3Array(); _pos.resize(_max)
	_vel = PackedVector3Array(); _vel.resize(_max)
	_life = PackedFloat32Array(); _life.resize(_max)
	_max_life = PackedFloat32Array(); _max_life.resize(_max)
	_buffer = PackedFloat32Array()
	_buffer.resize(_max * STRIDE)
	_clear()


# Write a slot's uniform scale (basis diagonal), origin, and alpha into the buffer.
func _write_slot(i: int, p: Vector3, scale: float, alpha: float) -> void:
	var b := i * STRIDE
	_buffer[b + 0] = scale
	_buffer[b + 5] = scale
	_buffer[b + 10] = scale
	_buffer[b + 3] = p.x
	_buffer[b + 7] = p.y
	_buffer[b + 11] = p.z
	var col: Color = Config.data.engine_smoke_color
	_buffer[b + 12] = col.r
	_buffer[b + 13] = col.g
	_buffer[b + 14] = col.b
	_buffer[b + 15] = alpha


# Park a slot off-screen (dead).
func _hide_slot(i: int) -> void:
	var b := i * STRIDE
	_buffer[b + 0] = 1.0
	_buffer[b + 5] = 1.0
	_buffer[b + 10] = 1.0
	_buffer[b + 3] = 0.0
	_buffer[b + 7] = HIDE_Y
	_buffer[b + 11] = 0.0
	_buffer[b + 15] = 0.0


func _clear() -> void:
	_next = -1
	_alive = 0
	if multimesh == null or _buffer.is_empty():
		return
	for i in _max:
		_life[i] = 0.0
		_hide_slot(i)
	multimesh.buffer = _buffer


# Force this pool's shader variant to compile NOW (during track generation, behind
# the loading overlay) instead of on the first engine misfire. Under gl_compatibility
# a material compiles on its first VISIBLE draw, and every slot sits off-screen at
# HIDE_Y until then — so we park one full puff in front of the camera for a rendered
# frame, then clear_warm_up() hides it again. See features/engine-smoke.md.
func warm_up(pos: Vector3) -> void:
	if multimesh == null or _buffer.is_empty():
		return
	_life[0] = 1.0
	_alive = 1
	_write_slot(0, pos, 1.0, 1.0)  # full scale + opaque, so it actually draws
	multimesh.buffer = _buffer


# Undo warm_up(): park the warm-up puff off-screen and reset the pool to empty.
func clear_warm_up() -> void:
	_clear()


func _physics_process(delta: float) -> void:
	if not Config.data.engine_smoke_enabled or multimesh == null:
		return
	# Age the live smoke (rise + grow + fade), then emit new puffs — from misfire
	# cutouts in an event, or self-timed from damage severity on a static display.
	var changed := _advance(delta)
	var emitted := _emit_synthetic(delta) if _synthetic else _emit_for_misfires()
	if emitted:
		changed = true
	if changed:
		multimesh.buffer = _buffer


# Integrate the live pool one step: each puff rises, grows toward its final size, and
# fades to nothing as its life runs out. Returns true if any slot changed. A no-op
# when nothing is alive, so a healthy (never-misfiring) car does zero per-frame work.
func _advance(delta: float) -> bool:
	if delta <= 0.0 or _alive == 0:
		return false  # tests tick with delta 0 to emit without ageing the pool
	var cfg: GameConfig = Config.data
	for i in _max:
		if _life[i] <= 0.0:
			continue
		_life[i] -= delta
		if _life[i] <= 0.0:
			_alive -= 1
			_hide_slot(i)
			continue
		_pos[i] += _vel[i] * delta
		# frac 0 at birth -> 1 at death, driving both growth and the alpha fade.
		var frac := 1.0 - _life[i] / maxf(_max_life[i], 1e-6)
		var scale := lerpf(1.0, cfg.engine_smoke_growth, frac)
		var alpha := cfg.engine_smoke_color.a * (1.0 - frac)
		_write_slot(i, _pos[i], scale, alpha)
	return true


# Puff one burst of smoke for each misfire cut that has happened since last tick
# (capped so a rapid run of cuts can't flood the pool in a single frame). Returns
# true if anything was emitted.
func _emit_for_misfires() -> bool:
	if not (is_instance_valid(_car) and _car.get("drivetrain") != null and _car.drivetrain.engine != null):
		return false
	var count: int = _car.drivetrain.engine.misfire_count
	var new_cuts := count - _last_misfire_count
	_last_misfire_count = count
	if new_cuts <= 0:
		return false
	var cfg: GameConfig = Config.data
	var bursts := mini(new_cuts, cfg.engine_smoke_max_puffs_per_tick)
	for _b in bursts:
		_puff(cfg)
	return true


# Self-timed puffs for a static display car: the interval between bursts shrinks as
# the car's damage severity rises (a healthier car puffs lazily, a wrecked one often),
# and a fully-healthy car (severity 0) never puffs. Returns true if a burst spawned.
func _emit_synthetic(delta: float) -> bool:
	var severity := _car_severity()
	if severity <= 0.0:
		_puff_timer = 0.0
		return false
	var cfg: GameConfig = Config.data
	_puff_timer += delta
	var interval := lerpf(cfg.engine_smoke_synthetic_interval_max,
		cfg.engine_smoke_synthetic_interval_min, severity)
	if _puff_timer < maxf(interval, 1e-3):
		return false
	_puff_timer = 0.0
	_puff(cfg)
	return true


# The display car's damage severity ∈ [0,1] (0 = healthy, no smoke) — the same
# misfire intensity the engine would run with, so smoke onsets at the same health
# threshold as the misfire.
func _car_severity() -> float:
	if not is_instance_valid(_car) or _car.get("damage") == null:
		return 0.0
	return _car.damage.misfire_level(Config.data)


# Emit one burst of smoke particles at the car's bonnet emit point, each rising with
# a little random scatter. Coordinate space matches how this pool is parented:
# - EVENT mode is parented to the world root, so we emit in WORLD space
#   (car.global_transform * offset) as the moving car drives around.
# - SYNTHETIC mode is parented to the (static, level) display CAR, so we emit in the
#   car's LOCAL space — the offset directly — and the MultiMesh renders it relative to
#   the car, placing the puff at the bonnet without any world-transform juggling.
func _puff(cfg: GameConfig) -> void:
	var origin: Vector3 = cfg.engine_smoke_offset
	if not _synthetic:
		origin = _car.global_transform * cfg.engine_smoke_offset
	for _n in maxi(1, cfg.engine_smoke_per_cut):
		var scatter := Vector3(
			randf_range(-1.0, 1.0), randf_range(0.0, 0.5), randf_range(-1.0, 1.0)
		) * cfg.engine_smoke_scatter_mps
		var vel := Vector3.UP * cfg.engine_smoke_rise_mps + scatter
		var ppos := origin + Vector3(
			randf_range(-0.1, 0.1), randf_range(-0.05, 0.05), randf_range(-0.1, 0.1)
		)
		_emit(cfg, ppos, vel)


# Write one particle into the ring buffer, recycling the oldest slot when full.
func _emit(cfg: GameConfig, pos: Vector3, vel: Vector3) -> void:
	_next = (_next + 1) % _max
	if _life[_next] <= 0.0:
		_alive += 1  # reused a dead slot; overwriting a live one keeps the count
	_pos[_next] = pos
	_vel[_next] = vel
	_life[_next] = cfg.engine_smoke_lifetime_s
	_max_life[_next] = cfg.engine_smoke_lifetime_s
	_write_slot(_next, pos, 1.0, cfg.engine_smoke_color.a)


# --- Readouts (tests) --------------------------------------------------------

func live_count() -> int:
	return _alive


func max_particles() -> int:
	return _max
