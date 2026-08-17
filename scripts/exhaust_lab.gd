class_name ExhaustLab
extends Node3D
# Standalone dev scene for positioning each car's exhaust pipes by eye. Run this scene
# directly from the editor (it is not the project's main scene and nothing in the game
# links to it), exactly like corner_catalog.tscn.
#
# It shows ONE car, frozen, on a plain apron, with its ExhaustFlames rig in forced mode
# (scripts/exhaust_flames.gd::setup_forced) so the flame is lit continuously — you are
# aiming at a steady target, not waiting for the car to bounce off the limiter. Orbit the camera with the mouse to inspect the pipes from
# any angle, cycle cars to check the whole roster, then edit
# GameConfig.exhaust_offsets in config/game_config.tres and press F8 to see the change
# WITHOUT restarting: that hot-reload loop is the entire reason the offsets live in the
# config resource rather than in CarLibrary. See features/exhaust-flames.md and
# features/debug-tools.md.
#
#   Drag (left mouse) .... orbit          Wheel ............... zoom
#   [ / ] or Left/Right .. previous / next car
#   F8 ................... re-read config/game_config.tres and rebuild the flames
#
# Being a dev scene reachable only from the editor, this is outside the "every menu is
# keyboard + gamepad navigable" rule in CLAUDE.md — but car cycling is wired to
# ui_left/ui_right anyway (so a pad works) since it cost nothing.

const CAR_SCENE := preload("res://car.tscn")

const GROUND_SIZE_M := 40.0
const MIN_DISTANCE_M := 2.0
const MAX_DISTANCE_M := 14.0
const ZOOM_STEP_M := 0.6
const ORBIT_SENSITIVITY := 0.006  # radians per pixel of mouse motion
const MIN_PITCH := -0.2           # radians; slightly below the horizon
const MAX_PITCH := 1.3            # nearly overhead

var _car: Node3D
var _flames: ExhaustFlames
var _camera: Camera3D
var _label: Label

var _index := 0
var _yaw := 2.4
var _pitch := 0.35
var _distance := 6.0
var _focus_y := 0.6  # height the camera orbits about; re-derived per car in _show_car
var _dragging := false


func _ready() -> void:
	_build_environment()
	_build_camera()
	_build_label()
	_show_car(0)


# A plain lit apron + sky so the car reads in 3D. Deliberately neutral: this is a
# measuring rig, not a showroom, and a dark or tinted ground would make it harder to
# judge where a flame actually sits relative to the bodywork.
func _build_environment() -> void:
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(GROUND_SIZE_M, GROUND_SIZE_M)
	ground.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.32, 0.34, 0.38)
	ground.material_override = mat
	add_child(ground)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.09, 0.10, 0.13)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.58, 0.65)
	env.ambient_light_energy = 0.7
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, -35.0, 0.0)
	sun.light_energy = 1.1
	add_child(sun)


func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.current = true
	add_child(_camera)
	_pose_camera()


func _build_label() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_label = Label.new()
	_label.position = Vector2(20.0, 16.0)
	layer.add_child(_label)


# Swap in car `index` (wrapping), rebuild its forced flame rig, and re-frame the camera
# for the new body. Frees the previous car outright rather than pooling it — a dev scene
# swaps cars a handful of times a session, and a fresh instance is the surest way to
# avoid carrying stale spec state between two cars.
func _show_car(index: int) -> void:
	var roster := CarLibrary.all()
	if roster.is_empty():
		return
	_index = wrapi(index, 0, roster.size())
	if is_instance_valid(_car):
		_car.queue_free()
	_car = CAR_SCENE.instantiate() as Node3D
	add_child(_car)
	# Frozen: this is a static display, and an un-frozen VehicleBody3D would settle,
	# roll and drift off the apron while you are trying to aim at a fixed point on it.
	_car.set("freeze", true)
	_car.call("apply_car", _index)
	_car.position = Vector3(0.0, _ride_height(_car), 0.0)

	# Parented to the CAR (not to the lab root) so the rig sits in the car's LOCAL space —
	# the offsets you are tuning are car-local, so this shows them directly with no
	# world-transform in the way. PROCESS_MODE_ALWAYS keeps it ticking even though the car
	# itself is frozen.
	_flames = ExhaustFlames.new()
	_car.add_child(_flames)
	_flames.process_mode = Node.PROCESS_MODE_ALWAYS
	_flames.setup_forced(_car)

	# Frame the car by its own length, so a long saloon and a city car both fill the view.
	var spec: Dictionary = roster[_index]
	_distance = clampf(float(spec.get("wheelbase", 2.5)) * 2.4, MIN_DISTANCE_M, MAX_DISTANCE_M)
	_focus_y = _car.position.y + 0.4
	_pose_camera()
	_update_label()


# Apply a just-reloaded config to the live car: re-resolve its pipes from the new
# exhaust_offsets, then REBUILD the flame rig. The rebuild is what makes the look knobs
# hot-reloadable at all — the quad size, the pipe yaw and the generated frame textures are
# all baked in when the rig is built, so re-reading the config without rebuilding would
# silently ignore every one of them.
func _reapply_pipes() -> void:
	if not is_instance_valid(_car):
		return
	var roster := CarLibrary.all()
	if _index < roster.size():
		_car.set("exhaust_locals", Config.data.exhaust_locals_for(roster[_index]))
	if is_instance_valid(_flames):
		_flames.setup_forced(_car)
	_update_label()


# How far to lift the car so its wheels rest ON the apron rather than sinking into it.
# A frozen VehicleBody3D never settles its suspension, so each wheel sits at its authored
# mount height and the contact point is mount.y − wheel_radius; the lowest of those is how
# far below the car origin the car actually reaches. Measured per car, since ride height
# and wheel radius both vary across the roster.
func _ride_height(car: Node3D) -> float:
	var lowest := INF
	for wheel in car.find_children("*", "VehicleWheel3D", false):
		lowest = minf(lowest, wheel.position.y - float(wheel.wheel_radius))
	if not is_finite(lowest):
		return 0.0  # no wheels found (a stub body): leave it where it is
	return -lowest


func _pose_camera() -> void:
	if _camera == null:
		return
	# Look at roughly mid-body height rather than the ground, so orbiting keeps the car
	# centred instead of sliding it up the screen as the pitch rises. Tracks the car's
	# lifted position, so it stays centred on a tall car and a low one alike.
	var focus := Vector3(0.0, _focus_y, 0.0)
	var offset := Vector3(
		_distance * cos(_pitch) * sin(_yaw),
		_distance * sin(_pitch),
		_distance * cos(_pitch) * cos(_yaw))
	_camera.position = focus + offset
	_camera.look_at(focus, Vector3.UP)


func _update_label() -> void:
	if _label == null:
		return
	var roster := CarLibrary.all()
	if _index >= roster.size():
		return
	var spec: Dictionary = roster[_index]
	var pipes: PackedVector4Array = Config.data.exhaust_locals_for(spec)
	var authored: bool = Config.data.exhaust_offsets.has(String(spec.get("id", "")))
	var lines := PackedStringArray([
		"%s  (%s)  [%d/%d]" % [String(spec.get("name", "?")), String(spec.get("id", "?")),
			_index + 1, roster.size()],
		"exhaust_offsets: %s" % ("authored" if authored else "FALLBACK (add an entry to pin it)"),
	])
	# Printed in the exact form the config takes, so a dialled-in pipe can be pasted
	# straight back into exhaust_offsets. Always the Vector4 form (position + yaw), even
	# at yaw 0, since that is the form you want as soon as you start angling a pipe.
	for i in pipes.size():
		var p := pipes[i]
		lines.append("  pipe %d: Vector4(%.3f, %.3f, %.3f, %.1f)" % [i, p.x, p.y, p.z, p.w])
	lines.append("")
	lines.append("Vector4 w = yaw degrees: 0 = straight back, + = toward the car's right")
	lines.append("drag = orbit   wheel = zoom   [ / ] = car   F8 = reload config")
	_label.text = "\n".join(lines)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_LEFT:
				_dragging = mb.pressed
			MOUSE_BUTTON_WHEEL_UP:
				if mb.pressed:
					_zoom(-ZOOM_STEP_M)
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					_zoom(ZOOM_STEP_M)
		return
	if event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		_orbit(mm.relative)
		return
	if event is InputEventKey and event.is_pressed() and not event.is_echo():
		match (event as InputEventKey).keycode:
			KEY_BRACKETLEFT:
				_show_car(_index - 1)
				return
			KEY_BRACKETRIGHT:
				_show_car(_index + 1)
				return
	# Gamepad / arrow keys cycle the roster too, and F8 hot-reloads exactly as it does
	# in the HQ (hq.gd::hot_reload_config) — the whole point of the offsets living in
	# the config resource.
	if event.is_action_pressed("ui_left"):
		_show_car(_index - 1)
	elif event.is_action_pressed("ui_right"):
		_show_car(_index + 1)
	elif event.is_action_pressed("reload_config"):
		if Config.reload_from_disk():
			_reapply_pipes()


# Orbit by a mouse delta, clamping the pitch so the camera can never flip over the pole.
# Pure/static so the clamping is testable without a scene.
static func orbit_from(yaw: float, pitch: float, delta: Vector2) -> Vector2:
	return Vector2(
		yaw - delta.x * ORBIT_SENSITIVITY,
		clampf(pitch + delta.y * ORBIT_SENSITIVITY, MIN_PITCH, MAX_PITCH))


func _orbit(delta: Vector2) -> void:
	var next := orbit_from(_yaw, _pitch, delta)
	_yaw = next.x
	_pitch = next.y
	_pose_camera()


func _zoom(step: float) -> void:
	_distance = clampf(_distance + step, MIN_DISTANCE_M, MAX_DISTANCE_M)
	_pose_camera()
