class_name CameraManager
extends Node
# Owns the ordered list of camera modes and the C-key cycling between them.
# Exactly one camera is `current` at a time. The bonnet camera is parented to
# the active car (rigid to the car's heading); the chase camera follows from the
# scene root. The chosen mode is persisted in the save profile under SETTING_KEY,
# so the camera the player last used (whether via the C key or the settings page)
# is restored on the next run. See features/camera.md.

enum Mode { CHASE, BONNET }

# Cycle order. Appending a future Camera3D + Mode entry extends the cycle.
const ORDER := [Mode.CHASE, Mode.BONNET]

# Save-profile key the chosen mode is stored under (Save.get_setting), plus the
# display metadata for the settings page. `mode` is the Mode value; order matches
# ORDER so the settings rows read in cycle order.
const SETTING_KEY := "camera_mode"
const MODES := [
	{"mode": Mode.CHASE, "name": "Chase",
		"desc": "Third-person camera that follows behind the car."},
	{"mode": Mode.BONNET, "name": "Bonnet",
		"desc": "Hood-mounted view looking straight ahead."},
]

@export var chase_camera: Camera3D
@export var bonnet_camera: Camera3D

var _index := 0


func _ready() -> void:
	var cfg: GameConfig = Config.data
	bonnet_camera.transform.origin = cfg.bonnet_offset
	bonnet_camera.fov = cfg.bonnet_fov
	_index = _saved_index()
	_apply()


func _process(_delta: float) -> void:
	if Input.is_action_just_pressed("cycle_camera"):
		cycle()


# Advance to the next camera in ORDER (wrapping), make it current, and persist it.
func cycle() -> void:
	_index = (_index + 1) % ORDER.size()
	_apply()
	_persist()


# Jump straight to a specific mode and persist it (used by the settings page, which
# lets the player pick a camera directly rather than cycling). No-op if unknown.
func set_mode(mode: int) -> void:
	var i := ORDER.find(mode)
	if i == -1:
		return
	_index = i
	_apply()
	_persist()


# Re-assert the player's chosen camera as the active one. Used when another system
# temporarily took over the viewport with its own Camera3D (the start-line reveal's
# orbit camera) and must hand control back to the SELECTED mode — which isn't always
# chase — rather than forcing one specific camera.
func activate_current() -> void:
	_apply()


func active_index() -> int:
	return _index


func current_mode() -> int:
	return ORDER[_index]


# The persisted mode mapped to its ORDER index, or 0 (chase) when unset or when
# Save is absent (bare-logic harness).
func _saved_index() -> int:
	var save := get_node_or_null("/root/Save")
	if save == null:
		return 0
	var i := ORDER.find(int(save.get_setting(SETTING_KEY, ORDER[0])))
	return i if i != -1 else 0


func _persist() -> void:
	var save := get_node_or_null("/root/Save")
	if save != null:
		save.set_setting(SETTING_KEY, ORDER[_index])


# Re-point the chase camera and re-parent the bonnet camera onto a (possibly
# fresh) car. Called by world.gd:cycle_car() after a car swap.
func retarget(car: Node3D) -> void:
	chase_camera.target = car
	var cfg: GameConfig = Config.data
	if bonnet_camera.get_parent() != car:
		bonnet_camera.get_parent().remove_child(bonnet_camera)
		car.add_child(bonnet_camera)
	bonnet_camera.transform.origin = cfg.bonnet_offset
	bonnet_camera.fov = cfg.bonnet_fov


# Make the camera for the current mode active; clear the others.
func _apply() -> void:
	var target_mode: int = ORDER[_index]
	chase_camera.current = (target_mode == Mode.CHASE)
	bonnet_camera.current = (target_mode == Mode.BONNET)
