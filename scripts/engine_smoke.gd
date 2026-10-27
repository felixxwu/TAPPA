class_name EngineSmoke
extends CpuParticlePool
# Docs: features/engine-smoke.md — update in the same change as this file.
# Tests: tests/headless/test_engine_smoke.gd — extend in the same change.
# Grey smoke that puffs from the bonnet each time a DAMAGED engine misfires (a fuel
# cut — see features/damage.md). A hand-rolled CPU pool drawn through ONE MultiMesh of
# billboarded quads (the shared ring-buffer machinery lives in CpuParticlePool). Its own
# SMALL pool, separate from the wheel dust (a light haze, not a spray).
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

var _car: Node  # the VehicleBody3D (read for drivetrain.engine + world transform)

# Extra per-slot array: the lifetime the slot was born with (for grow/fade fraction).
var _max_life: PackedFloat32Array
# Last EngineSim.misfire_count we turned into puffs — the delta each tick is the
# number of new cuts to emit for.
var _last_misfire_count := 0


func _stride() -> int:
	return STRIDE


func setup(car: Node) -> void:
	_car = car
	_last_misfire_count = _engine_misfire_count()
	_build_pool()


# The current car's engine misfire counter, or our last value if the car/engine
# isn't wired yet (so the delta is 0 and nothing spurious puffs).
func _engine_misfire_count() -> int:
	if is_instance_valid(_car) and _car.get("drivetrain") != null and _car.drivetrain.engine != null:
		return _car.drivetrain.engine.misfire_count
	return _last_misfire_count


func _build_pool() -> void:
	var cfg: GameConfig = Config.data
	var quad := QuadMesh.new()
	quad.size = Vector2(cfg.engine_smoke_size_m, cfg.engine_smoke_size_m)
	# Per-instance colour (the fade) drives albedo; disable depth write so stacked
	# transparent puffs don't fight the depth buffer.
	var mat := PS1Material.unshaded(null, true)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	material_override = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = quad
	mm.instance_count = maxi(1, cfg.engine_smoke_max)
	multimesh = mm
	_alloc_pool(mm.instance_count)
	_max_life = PackedFloat32Array(); _max_life.resize(_max)
	_clear()


# Write a slot's uniform scale (basis diagonal), origin, and alpha into the buffer.
func _write_slot(i: int, p: Vector3, slot_scale: float, alpha: float) -> void:
	var b := i * STRIDE
	_buffer[b + 0] = slot_scale
	_buffer[b + 5] = slot_scale
	_buffer[b + 10] = slot_scale
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


# A warmed-up slot draws full-scale + opaque, so the shader compiles.
func _build_slot(i: int, p: Vector3) -> void:
	_write_slot(i, p, 1.0, 1.0)


func _physics_process(delta: float) -> void:
	var __t := Time.get_ticks_usec()
	_timed_physics_process(delta)
	PerfLog.track(&"engine_smoke", Time.get_ticks_usec() - __t)


func _timed_physics_process(delta: float) -> void:
	if not Config.data.engine_smoke_enabled or multimesh == null:
		return
	# Age the live smoke (rise + grow + fade), then emit a puff per new misfire cutout.
	var changed := _advance(delta)
	if _emit_for_misfires():
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
		var slot_scale := lerpf(1.0, cfg.engine_smoke_growth, frac)
		var alpha := cfg.engine_smoke_color.a * (1.0 - frac)
		_write_slot(i, _pos[i], slot_scale, alpha)
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


# Emit one burst of smoke particles at the car's engine emit point, each rising with
# a little random scatter. The local emit point is the CAR's per-car engine_smoke_local
# (its longitudinal position tracks where the engine actually sits — a rear-engine 911
# smokes from the tail), falling back to the global GameConfig.engine_smoke_offset when
# the car doesn't expose one (e.g. a bare stub). The pool is parented to the world root,
# so the puff is emitted in WORLD space.
func _puff(cfg: GameConfig) -> void:
	var local: Vector3 = cfg.engine_smoke_offset
	if is_instance_valid(_car) and _car.get("engine_smoke_local") != null:
		local = _car.engine_smoke_local
	var origin: Vector3 = _car.global_transform * local
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
	_emit_slot(pos, vel, cfg.engine_smoke_lifetime_s)
	_max_life[_next] = cfg.engine_smoke_lifetime_s
	_write_slot(_next, pos, 1.0, cfg.engine_smoke_color.a)
