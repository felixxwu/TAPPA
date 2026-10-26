class_name CarLamps
extends Node3D
# Docs: features/car-lamps.md — update in the same change as this file.
# Tests: tests/headless/test_car_lamps.gd — extend in the same change.
# The car's glowing head and tail lamps: one camera-facing flare (shaders/car_lamp.gdshader)
# at each lamp centre the car exposes in `lamp_locals`. Headlights glow whenever the weather
# switches the night headlight cone on; tail lamps run dim with them and glow fully under
# the foot brake, day or night. Created and wired by free_roam.gd and world.gd, like ExhaustFlames.

const SHADER := preload("res://shaders/car_lamp.gdshader")

var _car: Node
var _locals := {}
var _head: Array[MeshInstance3D] = []
var _tail: Array[MeshInstance3D] = []
var _head_mat: ShaderMaterial
var _tail_mat: ShaderMaterial


func setup(car: Node) -> void:
	_car = car
	_rebuild()


func _rebuild() -> void:
	for m in _head + _tail:
		m.queue_free()
	_head.clear()
	_tail.clear()
	var cfg: GameConfig = Config.data
	_locals = lamp_points(_car)
	_head_mat = _build_material(cfg, cfg.lamp_head_color, Vector3.FORWARD)
	_tail_mat = _build_material(cfg, cfg.lamp_tail_color, Vector3.BACK)
	for p in _locals["head"]:
		_head.append(_build_lamp(p, _head_mat, cfg))
	for p in _locals["tail"]:
		_tail.append(_build_lamp(p, _tail_mat, cfg))


static func lamp_points(car: Node) -> Dictionary:
	var locals: Variant = car.get("lamp_locals") if is_instance_valid(car) else null
	if locals is Dictionary and locals.has("head") and locals.has("tail"):
		return locals
	return {"head": PackedVector3Array(), "tail": PackedVector3Array()}


func _build_material(cfg: GameConfig, color: Color, facing: Vector3) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter("lamp_color", color)
	mat.set_shader_parameter("facing", facing)
	mat.set_shader_parameter("size_m", cfg.lamp_size_m)
	mat.set_shader_parameter("core_radius", cfg.lamp_core_radius)
	mat.set_shader_parameter("halo", cfg.lamp_halo)
	mat.set_shader_parameter("streak", cfg.lamp_streak)
	mat.set_shader_parameter("depth_bias_m", cfg.lamp_depth_bias_m)
	return mat


func _build_lamp(pos: Vector3, mat: ShaderMaterial, cfg: GameConfig) -> MeshInstance3D:
	var quad := QuadMesh.new()
	var lamp := MeshInstance3D.new()
	lamp.mesh = quad
	lamp.material_override = mat
	lamp.position = pos
	lamp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The shader moves the quad toward the camera and scales it, which its 1 x 1 bounds know nothing about.
	lamp.extra_cull_margin = cfg.lamp_size_m + cfg.lamp_depth_bias_m
	lamp.visible = false
	add_child(lamp)
	return lamp


# Head and tail brightness, 0..1, for a night-cone strength and a brake lamp level.
static func lamp_levels(cfg: GameConfig, night: float, brake: float) -> Vector2:
	return Vector2(night, maxf(night * cfg.lamp_tail_running, clampf(brake, 0.0, 1.0)))


func _physics_process(_delta: float) -> void:
	if not is_instance_valid(_car):
		return
	# The garage can swap the player's car under us; rebuild when its lamps change.
	if lamp_points(_car) != _locals:
		_rebuild()
	global_transform = _car.global_transform
	var levels := lamp_levels(Config.data, HeadlightCone.amount(Config.data), float(_car.get("brake_lamp")))
	_set_level(_head, _head_mat, levels.x)
	_set_level(_tail, _tail_mat, levels.y)


func _set_level(lamps: Array[MeshInstance3D], mat: ShaderMaterial, level: float) -> void:
	mat.set_shader_parameter("level", level)
	for m in lamps:
		m.visible = level > 0.0


# Compile the lamp shader behind the loading overlay rather than on the first brake.
# Auto-discovered by world.gd's warm-up pass, like the particle pools.
func warm_up(pos: Vector3) -> void:
	global_position = pos
	for m in _head + _tail:
		m.visible = true


func clear_warm_up() -> void:
	for m in _head + _tail:
		m.visible = false


# --- Readouts (tests) --------------------------------------------------------


func head_lit() -> bool:
	return _head.any(func(m: MeshInstance3D) -> bool: return m.visible)


func tail_lit() -> bool:
	return _tail.any(func(m: MeshInstance3D) -> bool: return m.visible)


func lamp_count() -> int:
	return _head.size() + _tail.size()
