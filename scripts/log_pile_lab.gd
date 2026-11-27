extends Node3D
# Docs: features/debug-tools.md — update in the same change as this file.
# Tests: tests/headless/test_log_pile.gd — extend in the same change.
# Dev scene for previewing LogPile variants: run log_pile_lab.tscn from the editor, tweak
# the parameters live, and copy the printed LogPile.build(...) call into the game.

var _params := {"seed": 1, "style": LogPile.Style.TAPERED, "rows": 6, "base_count": 9,
		"length_m": 4.0, "radius_m": 0.16, "sections": 1}
var _pile: MeshInstance3D
var _camera: Camera3D
var _label: Label
var _yaw := 0.7
var _pitch := 0.3
var _distance := 9.0
var _dragging := false


func _ready() -> void:
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(40.0, 40.0)
	ground.mesh = plane
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.30, 0.42, 0.20)
	ground.material_override = gm
	add_child(ground)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.55, 0.62, 0.70)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.63, 0.7)
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45.0, -30.0, 0.0)
	sun.shadow_enabled = true
	add_child(sun)
	_camera = Camera3D.new()
	add_child(_camera)
	var layer := CanvasLayer.new()
	add_child(layer)
	_label = Label.new()
	_label.position = Vector2(18.0, 18.0)
	layer.add_child(_label)
	_rebuild()


func _rebuild() -> void:
	if is_instance_valid(_pile):
		_pile.queue_free()
	var p := _params
	_pile = LogPile.build(p.seed, p.style, p.rows, p.base_count, p.length_m, p.radius_m, p.sections)
	add_child(_pile)
	_pose_camera()
	_label.text = "\n".join([
		"LogPile.build(%d, LogPile.Style.%s, %d, %d, %.1f, %.2f, %d)" % [p.seed,
			String(LogPile.STYLE_NAMES[p.style]).to_upper(), p.rows, p.base_count, p.length_m,
			p.radius_m, p.sections],
		"",
		"space / enter = new seed     tab = style",
		"up/down = rows   left/right = width",
		"L / K = length +/-   R / E = radius +/-   S = sections",
		"drag = orbit   wheel = zoom",
	])


func _pose_camera() -> void:
	var focus := Vector3(0.0, 0.8, 0.0)
	_camera.position = focus + _distance * Vector3(
			cos(_pitch) * sin(_yaw), sin(_pitch), cos(_pitch) * cos(_yaw))
	_camera.look_at(focus, Vector3.UP)


func _adjust(key: String, step: float, lo: float, hi: float) -> void:
	if _params[key] is float:
		_params[key] = clampf(_params[key] + step, lo, hi)
	else:
		_params[key] = clampi(_params[key] + int(step), int(lo), int(hi))
	_rebuild()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
		elif mb.pressed and mb.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			_distance = clampf(_distance + (-0.8 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 0.8), 2.0, 30.0)
			_pose_camera()
		return
	if event is InputEventMouseMotion and _dragging:
		var rel := (event as InputEventMouseMotion).relative
		_yaw -= rel.x * 0.006
		_pitch = clampf(_pitch + rel.y * 0.006, -0.2, 1.3)
		_pose_camera()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match (event as InputEventKey).keycode:
			KEY_TAB: _params.style = (_params.style + 1) % LogPile.STYLE_NAMES.size(); _rebuild()
			KEY_L: _adjust("length_m", 0.5, 1.0, 12.0)
			KEY_K: _adjust("length_m", -0.5, 1.0, 12.0)
			KEY_R: _adjust("radius_m", 0.02, 0.06, 0.5)
			KEY_E: _adjust("radius_m", -0.02, 0.06, 0.5)
			KEY_S: _params.sections = _params.sections % 4 + 1; _rebuild()
	if event.is_action_pressed("ui_accept"):
		_params.seed += 1
		_rebuild()
	elif event.is_action_pressed("ui_up"):
		_adjust("rows", 1, 1, 14)
	elif event.is_action_pressed("ui_down"):
		_adjust("rows", -1, 1, 14)
	elif event.is_action_pressed("ui_right"):
		_adjust("base_count", 1, 1, 30)
	elif event.is_action_pressed("ui_left"):
		_adjust("base_count", -1, 1, 30)
