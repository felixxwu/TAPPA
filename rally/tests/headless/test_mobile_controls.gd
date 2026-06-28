extends GutTest
# On-screen touch controls with six selectable schemes (MobileControls.SCHEME_*).
# The default scheme is SLIDER_GAS_BRAKE: GAS + BRAKE digital pedals bottom-right
# and a bottom-left steering SLIDER feeding analog strength into steer_left/right.
# These exercise the default scheme plus the per-scheme action mapping (auto gas,
# steer buttons, the simple both-sides-brake, and the pure tilt maths). Gated to
# touch devices via mobile_controls_force.

const SceneHelpers = preload("res://tests/headless/scene_helpers.gd")

var _scene: Node3D
var _controls  # MobileControls


func before_each() -> void:
	# Hermetic input state: the touch controls only RELEASE actions they pressed
	# themselves, so a press leaked by an earlier test would survive into the
	# idle/region assertions here. Clear all actions up front.
	for a in ["steer_left", "steer_right", "brake_reverse", "accelerate"]:
		Input.action_release(a)
	# These tests only exercise the touch overlay, not the track/foliage, so boot
	# a minimal world (~15s -> <1s per instance), then force the controls on.
	SceneHelpers.minimal_world()
	Config.data.mobile_controls_force = true
	_scene = load("res://main.tscn").instantiate()
	add_child_autofree(_scene)
	_controls = _scene.get_node("MobileControls")
	# A fixed slider rect so the steer maths are deterministic regardless of the
	# headless viewport size: centre x = 100, usable half-travel = 100 - 20 = 80.
	_controls._slider_rect = Rect2(0, 0, 200, 40)
	_controls._thumb_w = 40.0


func after_each() -> void:
	# Config.reset() restores the authored baseline — both mobile_controls_force
	# AND the minimal track/foliage minimal_world() set — so later files that don't
	# reset Config still generate the full world they expect.
	Config.reset()
	for a in ["steer_left", "steer_right", "brake_reverse", "accelerate"]:
		Input.action_release(a)


func test_visible_when_forced() -> void:
	assert_true(_controls.visible, "controls shown when mobile_controls_force is set")


func test_defaults_to_slider_gas_brake() -> void:
	assert_eq(_controls._scheme, MobileControls.SCHEME_SLIDER_GAS_BRAKE,
		"the default scheme is the slider + gas/brake one")


func test_hidden_on_desktop() -> void:
	Config.data.mobile_controls_force = false
	var scene: Node3D = load("res://main.tscn").instantiate()
	add_child_autofree(scene)
	# Headless test host is not a touch device, so without the force flag the
	# controls stay hidden.
	assert_false(scene.get_node("MobileControls").visible,
		"controls hidden on a non-touch device")


# --- Default scheme: gas / brake / slider ------------------------------------

func test_no_input_when_idle() -> void:
	# Nothing touched -> no actions held, steering centred.
	_controls._apply_actions()
	assert_false(Input.is_action_pressed("accelerate"), "no throttle when idle")
	assert_false(Input.is_action_pressed("brake_reverse"), "no brake when idle")
	assert_almost_eq(Input.get_action_strength("steer_left"), 0.0, 1e-6, "no left steer when idle")
	assert_almost_eq(Input.get_action_strength("steer_right"), 0.0, 1e-6, "no right steer when idle")


func test_gas_region_accelerates() -> void:
	_controls._pointers[0] = "gas"
	_controls._apply_actions()
	assert_true(Input.is_action_pressed("accelerate"), "gas button accelerates")
	assert_false(Input.is_action_pressed("brake_reverse"), "gas does not brake")


func test_brake_region_brakes() -> void:
	_controls._pointers[0] = "brake"
	_controls._apply_actions()
	assert_true(Input.is_action_pressed("brake_reverse"), "brake button brakes")
	assert_false(Input.is_action_pressed("accelerate"), "brake does not accelerate")


func test_slider_left_steers_left() -> void:
	# Thumb dragged to the left edge -> full left steer, no right.
	_controls._slider_owner = 0
	_controls._slider_x = 20.0  # centre 100, usable 80 -> -1.0
	_controls._apply_actions()
	assert_almost_eq(Input.get_action_strength("steer_left"), 1.0, 1e-5, "left edge = full left steer")
	assert_almost_eq(Input.get_action_strength("steer_right"), 0.0, 1e-6, "no right steer")


func test_slider_right_steers_right() -> void:
	_controls._slider_owner = 0
	_controls._slider_x = 180.0  # centre 100, usable 80 -> +1.0
	_controls._apply_actions()
	assert_almost_eq(Input.get_action_strength("steer_right"), 1.0, 1e-5, "right edge = full right steer")
	assert_almost_eq(Input.get_action_strength("steer_left"), 0.0, 1e-6, "no left steer")


func test_slider_is_analog() -> void:
	# Partway to the right edge gives partial steer (not full) — exact value depends on
	# the action deadzone, so just assert it's between idle and full.
	_controls._slider_owner = 0
	_controls._slider_x = 140.0  # (140-100)/80 = 0.5 thumb fraction
	_controls._apply_actions()
	var partial := Input.get_action_strength("steer_right")
	assert_gt(partial, 0.0, "a partial slider gives some right steer")
	assert_lt(partial, 1.0, "but less than a full throw")


func test_slider_recenters_when_released() -> void:
	_controls._slider_owner = 0
	_controls._slider_x = 20.0
	_controls._apply_actions()
	assert_gt(Input.get_action_strength("steer_left"), 0.0, "steering held while the finger is down")
	# Lift the finger: the slider springs back to centre and steering clears.
	_controls._release(0)
	_controls._apply_actions()
	assert_eq(_controls._slider_owner, null, "the slider has no owner after release")
	assert_almost_eq(Input.get_action_strength("steer_left"), 0.0, 1e-6, "steering recentres on release")


func test_multitouch_steer_and_gas_together() -> void:
	# One pointer owns the slider, another holds gas — both must register.
	_controls._slider_owner = 1
	_controls._slider_x = 20.0
	_controls._pointers[0] = "gas"
	_controls._apply_actions()
	assert_gt(Input.get_action_strength("steer_left"), 0.0, "steering holds with throttle")
	assert_true(Input.is_action_pressed("accelerate"), "throttle holds with steering")


func test_release_clears_button() -> void:
	_controls._pointers[0] = "gas"
	_controls._apply_actions()
	_controls._pointers.erase(0)
	_controls._apply_actions()
	assert_false(Input.is_action_pressed("accelerate"), "releasing the touch releases the gas action")


# --- Steer-button scheme -----------------------------------------------------

func test_steer_buttons_scheme() -> void:
	_controls.set_scheme(MobileControls.SCHEME_BUTTONS_GAS_BRAKE)
	_controls._pointers[0] = "steer_left"
	_controls._apply_actions()
	assert_almost_eq(Input.get_action_strength("steer_left"), 1.0, 1e-5, "left button = full left steer")
	assert_almost_eq(Input.get_action_strength("steer_right"), 0.0, 1e-6, "no right steer")


# --- Auto-gas schemes: throttle held unless braking --------------------------

func test_auto_gas_holds_throttle_when_idle() -> void:
	_controls.set_scheme(MobileControls.SCHEME_SLIDER_BRAKE_AUTO)
	_controls._apply_actions()
	assert_true(Input.is_action_pressed("accelerate"), "auto-gas holds throttle when not braking")
	assert_false(Input.is_action_pressed("brake_reverse"), "no brake when idle")


func test_auto_gas_releases_throttle_while_braking() -> void:
	_controls.set_scheme(MobileControls.SCHEME_SLIDER_BRAKE_AUTO)
	_controls._pointers[0] = "brake"
	_controls._apply_actions()
	assert_true(Input.is_action_pressed("brake_reverse"), "brake button brakes")
	assert_false(Input.is_action_pressed("accelerate"), "throttle drops while braking (no gas+brake overlap)")


# --- Simple left/right scheme: both sides = brake ----------------------------

func test_simple_one_side_steers_with_auto_gas() -> void:
	_controls.set_scheme(MobileControls.SCHEME_SIMPLE_LR_AUTO)
	_controls._pointers[0] = "simple_right"
	_controls._apply_actions()
	assert_almost_eq(Input.get_action_strength("steer_right"), 1.0, 1e-5, "one side steers that way")
	assert_true(Input.is_action_pressed("accelerate"), "throttle auto-held while steering")
	assert_false(Input.is_action_pressed("brake_reverse"), "one side does not brake")


func test_simple_both_sides_brake() -> void:
	_controls.set_scheme(MobileControls.SCHEME_SIMPLE_LR_AUTO)
	_controls._pointers[0] = "simple_left"
	_controls._pointers[1] = "simple_right"
	_controls._apply_actions()
	assert_true(Input.is_action_pressed("brake_reverse"), "both sides at once = brake")
	assert_false(Input.is_action_pressed("accelerate"), "throttle drops while braking")
	assert_almost_eq(Input.get_action_strength("steer_left"), 0.0, 1e-6, "no steer while braking")
	assert_almost_eq(Input.get_action_strength("steer_right"), 0.0, 1e-6, "no steer while braking")


# --- Tilt steering maths (pure) ----------------------------------------------

func test_tilt_steer_deadzone_and_direction() -> void:
	# Near-level (within the deadzone) -> no steer.
	assert_almost_eq(MobileControls.tilt_steer(Vector3(0.2, 0, 9.8), 2.0, 0.05), 0.0, 1e-6,
		"a roughly level phone does not steer")
	# Rolled right (positive X gravity past the deadzone) -> positive (right) steer.
	var right := MobileControls.tilt_steer(Vector3(4.0, 0, 9.0), 2.0, 0.05)
	assert_gt(right, 0.0, "rolling right steers right")
	# Rolled left -> negative (left) steer, symmetric.
	var left := MobileControls.tilt_steer(Vector3(-4.0, 0, 9.0), 2.0, 0.05)
	assert_almost_eq(left, -right, 1e-6, "left/right tilt is symmetric")
	# A hard tilt clamps to full lock.
	assert_almost_eq(MobileControls.tilt_steer(Vector3(20.0, 0, 0.0), 2.0, 0.05), 1.0, 1e-6,
		"a hard tilt clamps to full lock")


# --- Scheme switching --------------------------------------------------------

func test_set_scheme_releases_old_inputs() -> void:
	# Hold gas in the default scheme, then switch: the old throttle must not linger.
	_controls._pointers[0] = "gas"
	_controls._apply_actions()
	assert_true(Input.is_action_pressed("accelerate"), "gas held before switch")
	_controls.set_scheme(MobileControls.SCHEME_SIMPLE_LR_AUTO)
	assert_false(Input.is_action_pressed("accelerate"),
		"switching schemes releases inputs held under the old one")
