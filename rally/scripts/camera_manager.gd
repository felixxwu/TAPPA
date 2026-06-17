extends Node
# Owns the ordered list of camera modes and the C-key cycling between them.
# Exactly one camera is `current` at a time. The bonnet camera is parented to
# the active car (rigid to the car's heading); the chase camera follows from the
# scene root. See features/camera.md.

enum Mode { CHASE, BONNET }

# Cycle order. Appending a future Camera3D + Mode entry extends the cycle.
const ORDER := [Mode.CHASE, Mode.BONNET]

@export var chase_camera: Camera3D
@export var bonnet_camera: Camera3D

var _index := 0


func _ready() -> void:
	var cfg: GameConfig = Config.data
	bonnet_camera.transform.origin = cfg.bonnet_offset
	bonnet_camera.fov = cfg.bonnet_fov
	_apply()


func _process(_delta: float) -> void:
	if Input.is_action_just_pressed("cycle_camera"):
		cycle()


# Advance to the next camera in ORDER (wrapping) and make it current.
func cycle() -> void:
	_index = (_index + 1) % ORDER.size()
	_apply()


func active_index() -> int:
	return _index


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
