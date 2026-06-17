extends GutTest
# On-screen touch controls: four bottom buttons (steer left / steer right /
# throttle / brake) drive the existing input actions. Gated to touch devices
# via mobile_controls_force.

var _scene: Node3D
var _controls: CanvasLayer


func before_each() -> void:
	Config.data.mobile_controls_force = true
	_scene = load("res://main.tscn").instantiate()
	add_child_autofree(_scene)
	_controls = _scene.get_node("MobileControls")


func after_each() -> void:
	Config.data.mobile_controls_force = false
	# Clear any actions a test left held so cases don't bleed into each other.
	for a in ["steer_left", "steer_right", "brake_reverse", "accelerate"]:
		Input.action_release(a)


func test_visible_when_forced() -> void:
	assert_true(_controls.visible, "controls shown when mobile_controls_force is set")


func test_hidden_on_desktop() -> void:
	Config.data.mobile_controls_force = false
	var scene: Node3D = load("res://main.tscn").instantiate()
	add_child_autofree(scene)
	# Headless test host is not a touch device, so without the force flag the
	# controls stay hidden.
	assert_false(scene.get_node("MobileControls").visible,
		"controls hidden on a non-touch device")


func test_no_input_when_idle() -> void:
	# Nothing touched -> no actions held (no auto-accelerate).
	_controls._apply_actions()
	assert_false(Input.is_action_pressed("accelerate"), "no throttle when idle")
	assert_false(Input.is_action_pressed("brake_reverse"), "no brake when idle")


func test_throttle_region_accelerates() -> void:
	_controls._pointers[0] = _controls.THROTTLE
	_controls._apply_actions()
	assert_true(Input.is_action_pressed("accelerate"), "throttle button accelerates")
	assert_false(Input.is_action_pressed("brake_reverse"), "throttle does not brake")


func test_brake_region_brakes() -> void:
	_controls._pointers[0] = _controls.BRAKE
	_controls._apply_actions()
	assert_true(Input.is_action_pressed("brake_reverse"), "brake button brakes")
	assert_false(Input.is_action_pressed("accelerate"), "brake does not accelerate")


func test_steer_regions_press_steer_actions() -> void:
	_controls._pointers[0] = _controls.STEER_LEFT
	_controls._apply_actions()
	assert_true(Input.is_action_pressed("steer_left"), "left button steers left")
	assert_false(Input.is_action_pressed("steer_right"), "only left is held")


func test_multitouch_steer_and_throttle_together() -> void:
	# Two pointers: one on steer-left, one on throttle — both must register.
	_controls._pointers[0] = _controls.STEER_LEFT
	_controls._pointers[1] = _controls.THROTTLE
	_controls._apply_actions()
	assert_true(Input.is_action_pressed("steer_left"), "steer holds with throttle")
	assert_true(Input.is_action_pressed("accelerate"), "throttle holds with steer")


func test_release_clears_actions() -> void:
	_controls._pointers[0] = _controls.STEER_LEFT
	_controls._apply_actions()
	_controls._pointers.erase(0)
	_controls._apply_actions()
	assert_false(Input.is_action_pressed("steer_left"),
		"releasing the touch releases the steer action")
