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


func before_all() -> void:
	# Build the wired scene ONCE for the whole script — these tests exercise only the
	# touch overlay, not the track/foliage, so minimal_world() trims generation to a
	# 1-turn, tree-free build (~15s -> <1s), and a single shared instance avoids paying
	# that per test. Per-test state (scheme, forced-on flag, injected input) is reset in
	# before_each/after_each so the shared instance stays order-safe.
	SceneHelpers.minimal_world()
	Config.data.mobile_controls_force = true
	_scene = load("res://main.tscn").instantiate()
	add_child(_scene)
	_controls = _scene.get_node("MobileControls")


func after_all() -> void:
	_scene.free()
	# Config.reset() restores the authored baseline — both mobile_controls_force AND the
	# minimal track/foliage minimal_world() set — so later files still generate the full
	# world they expect.
	Config.reset()


func before_each() -> void:
	# Hermetic input state: the touch controls only RELEASE actions they pressed
	# themselves, so a press leaked by an earlier test would survive into the
	# idle/region assertions here. Clear all actions up front.
	for a in ["steer_left", "steer_right", "brake_reverse", "accelerate", "nitrous"]:
		Input.action_release(a)
	# No nitrous fitted by default, so the NOS button is absent unless a test fits some.
	Config.data.nitrous_boost_gain = 0.0
	Config.data.nitrous_tank_seconds = 0.0
	# Reset the shared overlay to its default scheme + forced-on state (tests below
	# switch schemes / toggle the force flag), and re-fix the slider rect so the steer
	# maths are deterministic regardless of the headless viewport size: centre x = 100,
	# usable half-travel = 100 - 20 = 80.
	Config.data.mobile_controls_force = true
	_controls.set_scheme(MobileControls.SCHEME_SLIDER_GAS_BRAKE)
	_controls._slider_rect = Rect2(0, 0, 200, 40)
	_controls._thumb_w = 40.0
	# Forget any browser touch snapshot a stuck-touch test adopted — headless has no
	# watchdog, and a leftover live set would reconcile away the other tests' pointers.
	_controls._live_touches = null
	_controls._touch_seq = -1
	_seq = 0
	# Same for the positioned pointer snapshot: while one is live the overlay ignores
	# engine touch events entirely, so a leftover would break every event-driven test.
	_controls._live_pointers = null
	_controls._pointer_seq = -1
	_controls._seen_pointers.clear()
	_pseq = 0


func after_each() -> void:
	for a in ["steer_left", "steer_right", "brake_reverse", "accelerate", "nitrous"]:
		Input.action_release(a)
	Config.data.nitrous_boost_gain = 0.0
	Config.data.nitrous_tank_seconds = 0.0


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


# --- NOS button (only when nitrous is fitted) ---------------------------------
# A small button beside the pedal column, present in every scheme, that presses the
# `nitrous` action. Geometry is a tunable, so these assert RELATIONSHIPS only:
# presence/absence, no overlap with any other region, and hit-test ordering.

# Derived from the production table, not hand-listed: a seventh scheme is then exercised by
# these tests automatically instead of silently escaping them. Scheme ids are the table's
# indices, so iterating the size covers every id.
static var _ALL_SCHEMES: Array = range(MobileControls.SCHEMES.size())

# Fit nitrous (values are arbitrary positives — has_nitrous() only needs both > 0) and
# lay the given scheme out at a realistic phone-ish viewport.
func _fit_nitrous_and_lay_out(scheme: int, size := Vector2(1280, 720)) -> void:
	Config.data.nitrous_boost_gain = 0.25
	Config.data.nitrous_tank_seconds = 5.0
	_controls.set_scheme(scheme)
	_controls._sync_nitrous_button()
	_controls._compute_rects(size)


func test_nitrous_region_exists_in_every_scheme() -> void:
	for scheme in _ALL_SCHEMES:
		_fit_nitrous_and_lay_out(scheme)
		assert_true(_controls._rects.has("nitrous"),
			"scheme %d places a NOS region when nitrous is fitted" % scheme)
		assert_true(_controls._panels.has("nitrous"),
			"scheme %d builds a NOS panel when nitrous is fitted" % scheme)


func test_no_nitrous_region_when_not_fitted() -> void:
	for scheme in _ALL_SCHEMES:
		Config.data.nitrous_boost_gain = 0.0
		Config.data.nitrous_tank_seconds = 0.0
		_controls.set_scheme(scheme)
		_controls._sync_nitrous_button()
		_controls._compute_rects(Vector2(1280, 720))
		assert_false(_controls._rects.has("nitrous"),
			"scheme %d has no NOS region without nitrous fitted" % scheme)
		assert_false(_controls._panels.has("nitrous"),
			"scheme %d builds no NOS panel without nitrous fitted" % scheme)


func test_nitrous_does_not_overlap_other_regions() -> void:
	# The simple scheme's halves deliberately COVER the lower screen (so the NOS button
	# is inside one of them); ordering handles that, see the hit-test test below. Every
	# other region — pedals, steer buttons — and the steering slider must stay clear.
	for scheme in _ALL_SCHEMES:
		_fit_nitrous_and_lay_out(scheme)
		var nos: Rect2 = _controls._rects["nitrous"]
		assert_gt(nos.size.x, 0.0, "scheme %d gives the NOS button a real width" % scheme)
		assert_gt(nos.size.y, 0.0, "scheme %d gives the NOS button a real height" % scheme)
		for region in _controls._rects:
			if region == "nitrous" or region == "simple_left" or region == "simple_right":
				continue
			assert_false(nos.intersects(_controls._rects[region]),
				"scheme %d: NOS does not overlap %s" % [scheme, region])
		if _controls._has_slider():
			assert_false(nos.intersects(_controls._slider_rect),
				"scheme %d: NOS does not overlap the steering slider" % scheme)


func test_nitrous_is_smaller_than_a_pedal() -> void:
	# It's a small button, not a third pedal — relative, so retuning the pedal size or
	# the NOS fraction keeps this honest.
	_fit_nitrous_and_lay_out(MobileControls.SCHEME_SLIDER_GAS_BRAKE)
	var nos: Rect2 = _controls._rects["nitrous"]
	var gas: Rect2 = _controls._rects["gas"]
	assert_lt(nos.get_area(), gas.get_area(), "the NOS button is smaller than the GAS pedal")


func test_nitrous_wins_over_the_simple_steering_halves() -> void:
	# THE trap: in SIMPLE_LR_AUTO the steering halves cover the whole lower screen, so a
	# press on the NOS button lands inside a half too. It must be hit-tested FIRST, or
	# the button would silently steer instead of firing nitrous.
	_fit_nitrous_and_lay_out(MobileControls.SCHEME_SIMPLE_LR_AUTO)
	var nos: Rect2 = _controls._rects["nitrous"]
	assert_eq(_controls._button_region(nos.get_center()), "nitrous",
		"a press on the NOS button reports the NOS region, not a steering half")


func test_nitrous_region_presses_the_nitrous_action() -> void:
	_fit_nitrous_and_lay_out(MobileControls.SCHEME_SLIDER_GAS_BRAKE)
	_controls._pointers[0] = "nitrous"
	_controls._apply_actions()
	assert_true(Input.is_action_pressed("nitrous"), "the NOS button presses the nitrous action")
	_controls._pointers.erase(0)
	_controls._apply_actions()
	assert_false(Input.is_action_pressed("nitrous"), "releasing the touch releases nitrous")


func test_holding_nos_also_holds_the_throttle() -> void:
	# There is no scenario where you want nitrous held WITHOUT throttle — the sim refuses to
	# deliver or drain off-throttle anyway — and on touch the two buttons are adjacent, so
	# demanding both thumbs would just make the boost feel broken.
	_fit_nitrous_and_lay_out(MobileControls.SCHEME_SLIDER_GAS_BRAKE)
	_controls._pointers[0] = "nitrous"
	_controls._apply_actions()
	assert_true(Input.is_action_pressed("nitrous"), "NOS is held")
	assert_true(Input.is_action_pressed("accelerate"), "and it holds the throttle with it")
	_controls._pointers.erase(0)
	_controls._apply_actions()
	assert_false(Input.is_action_pressed("accelerate"), "releasing NOS releases the throttle too")


func test_releasing_nos_leaves_a_separately_held_gas_alone() -> void:
	# The throttle is an OR over the two regions, not a write, so letting go of NOS must not
	# cut the throttle out from under a thumb that is still on GAS.
	_fit_nitrous_and_lay_out(MobileControls.SCHEME_SLIDER_GAS_BRAKE)
	_controls._pointers[0] = "gas"
	_controls._pointers[1] = "nitrous"
	_controls._apply_actions()
	assert_true(Input.is_action_pressed("accelerate"), "both held: throttle on")
	_controls._pointers.erase(1)  # let go of NOS only
	_controls._apply_actions()
	assert_false(Input.is_action_pressed("nitrous"), "NOS released")
	assert_true(Input.is_action_pressed("accelerate"), "but the held GAS still drives the throttle")


func test_nitrous_button_appears_and_vanishes_with_the_car() -> void:
	# Nitrous is fitted per car and a car swap raises no signal, so the overlay polls:
	# the button must appear/disappear without a scheme change.
	assert_false(_controls._panels.has("nitrous"), "no NOS button on a car without nitrous")
	Config.data.nitrous_boost_gain = 0.25
	Config.data.nitrous_tank_seconds = 5.0
	_controls._sync_nitrous_button()
	assert_true(_controls._panels.has("nitrous"), "fitting nitrous adds the NOS button")
	Config.data.nitrous_boost_gain = 0.0
	Config.data.nitrous_tank_seconds = 0.0
	_controls._sync_nitrous_button()
	assert_false(_controls._panels.has("nitrous"), "a car without nitrous drops the button again")


func test_switching_to_a_car_without_nitrous_releases_a_held_boost() -> void:
	_fit_nitrous_and_lay_out(MobileControls.SCHEME_SLIDER_GAS_BRAKE)
	_controls._pointers[0] = "nitrous"
	_controls._apply_actions()
	assert_true(Input.is_action_pressed("nitrous"), "nitrous held before the swap")
	Config.data.nitrous_boost_gain = 0.0
	Config.data.nitrous_tank_seconds = 0.0
	_controls._sync_nitrous_button()
	_controls._apply_actions()
	assert_false(Input.is_action_pressed("nitrous"),
		"losing the button releases the action rather than leaving it held")


func test_release_all_clears_nitrous() -> void:
	_fit_nitrous_and_lay_out(MobileControls.SCHEME_SLIDER_GAS_BRAKE)
	_controls._pointers[0] = "nitrous"
	_controls._apply_actions()
	_controls._release_all()
	assert_false(Input.is_action_pressed("nitrous"), "_release_all drops a held nitrous")


# --- Stuck-touch recovery (web watchdog reconciliation) -----------------------
# Mobile browsers sometimes never deliver the touchend for a finger lifted while
# others are still down. A JS watchdog publishes the browser's authoritative list
# of fingers currently down (pushed via a JavaScriptBridge callback AND pulled once
# a frame) and the overlay reconciles held pointers against it every frame
# (_adopt_live_touches / _reconcile_pointers). These cover the GDScript side of that
# path — the JS itself can't run headless.

# Adopt a snapshot the way both the push and the pull paths do, then reconcile as
# _timed_process would. `seq` must climb, which is what makes the two paths idempotent.
var _seq := 0

func _live(ids: String) -> void:
	_seq += 1
	_controls._adopt_live_touches(_seq, ids)
	_controls._reconcile_pointers()


func test_lost_touch_clears_a_stuck_button() -> void:
	# Two fingers down; the steer button's release event never arrives, so the
	# browser's list is the only thing that knows the finger is up.
	_controls.set_scheme(MobileControls.SCHEME_BUTTONS_GAS_BRAKE)
	_controls._pointers[0] = "gas"
	_controls._pointers[1] = "steer_left"
	_controls._apply_actions()
	assert_gt(Input.get_action_strength("steer_left"), 0.0, "steering held before recovery")
	_live("0")
	_controls._apply_actions()
	assert_almost_eq(Input.get_action_strength("steer_left"), 0.0, 1e-6,
		"a pointer missing from the live touch list stops steering")
	assert_true(Input.is_action_pressed("accelerate"),
		"the OTHER finger keeps its action — only the lost pointer is dropped")


func test_lost_touch_recenters_the_slider() -> void:
	_controls._slider_owner = 1
	_controls._slider_x = 20.0
	_controls._apply_actions()
	assert_gt(Input.get_action_strength("steer_left"), 0.0, "slider steering before recovery")
	_live("")
	_controls._apply_actions()
	assert_almost_eq(Input.get_action_strength("steer_left"), 0.0, 1e-6,
		"losing the slider pointer springs steering back to centre")
	assert_null(_controls._slider_owner, "slider ownership dropped")


func test_live_touches_leave_held_fingers_alone() -> void:
	# Reconciliation must only ever drop pointers the browser says are UP; a finger
	# still listed keeps its region, and ids we don't track are simply ignored.
	_controls._pointers[0] = "gas"
	_live("0,7")
	_controls._apply_actions()
	assert_true(Input.is_action_pressed("accelerate"),
		"a finger still in the live list keeps holding its action")
	assert_eq(_controls._pointers.size(), 1, "an untracked live id adds no pointer")


func test_reconcile_is_a_noop_before_any_snapshot() -> void:
	# Off the web build (and in these tests) there is no browser snapshot at all, so
	# the per-frame reconcile must not touch anything — "no snapshot" is not "no
	# fingers down".
	_controls._live_touches = null
	_controls._pointers[0] = "gas"
	_controls._slider_owner = 1
	_controls._reconcile_pointers()
	assert_eq(_controls._pointers.get(0), "gas", "no snapshot leaves held pointers alone")
	assert_eq(_controls._slider_owner, 1, "no snapshot leaves the slider owner alone")


func test_reconcile_keeps_the_mouse_pointer() -> void:
	# The mouse is index -1 and never appears in a browser touch list, so an empty
	# list must not release it — desktop testing with mobile_controls_force.
	_controls._pointers[-1] = "gas"
	_live("")
	_controls._apply_actions()
	assert_true(Input.is_action_pressed("accelerate"),
		"reconciling touch pointers leaves the mouse pointer held")


func test_stale_drag_is_reconciled_away_not_left_stuck() -> void:
	# THE regression this guards: Godot flushes buffered input a frame late, so a drag
	# queued while the finger was still down can arrive AFTER we learned the finger is
	# up, re-adding the pointer. The old one-shot watchdog had already fired by then
	# and never looked again, so the button stuck until the next touch — which is why
	# the bug only showed when a finger MOVED slightly before being released.
	# The drag is deliberately still ACTED on (gating it swallows real input); what
	# must hold is that the next reconcile undoes it, every time.
	_fixed_button_rects()
	_controls._input(_touch(0, Vector2(550, 550), true))
	_controls._input(_touch(1, Vector2(750, 550), true))
	# Finger 1 lifts, but its touchend never arrives — only the browser knows.
	_live("0")
	assert_false(_controls._pointers.has(1), "the lost pointer is dropped")
	# Its stale drag lands and resurrects it...
	_controls._input(_drag_event(1, Vector2(750, 550)))
	# ...and the very next frame drops it again, before any action is applied.
	_controls._reconcile_pointers()
	_controls._apply_actions()
	assert_false(_controls._pointers.has(1), "a resurrected pointer does not survive a frame")
	assert_false(Input.is_action_pressed("brake_reverse"), "so its action never reaches the car")
	assert_eq(_controls._pointers.get(0), "gas", "the finger still down is untouched")
	# And a finger the browser still lists drags between regions as normal.
	_controls._input(_drag_event(0, Vector2(750, 550)))
	assert_eq(_controls._pointers.get(0), "brake", "a live finger still drags between regions")


func test_reconcile_redrops_a_resurrected_pointer() -> void:
	# Belt to the braces above: however a pointer for a lifted finger gets re-added,
	# the per-frame reconcile drops it again rather than leaving it stuck forever the
	# way the old one-shot watchdog did.
	_live("0")
	_controls._pointers[1] = "gas"
	_controls._reconcile_pointers()
	_controls._apply_actions()
	assert_false(_controls._pointers.has(1), "reconciliation re-drops a resurrected pointer")
	assert_false(Input.is_action_pressed("accelerate"), "and its action never sticks")


# --- Positioned pointer snapshot (the primary web path) -----------------------
# On the web the overlay stops trusting engine touch events altogether and rebuilds
# press / drag / release every frame from the browser's own list of pointers currently
# down, positions included. A dropped `touchend` then can't leave a button held: the
# finger is simply absent from the next snapshot. These cover the GDScript half — the
# JS that produces the snapshot can't run headless.

var _pseq := 0

# Publish a snapshot the way the watchdog's push/pull paths do. The JS normalises
# positions to the canvas rect, so convert from the viewport coords the hit rects are
# laid out in, then run the per-frame apply _timed_process would.
func _live_ptr(pointers: Dictionary) -> void:
	var size: Vector2 = _controls.get_viewport().get_visible_rect().size
	assert_gt(size.x * size.y, 0.0, "viewport has a usable size to normalise against")
	var parts := PackedStringArray()
	for id in pointers:
		var p: Vector2 = pointers[id]
		parts.append("%d:%.8f:%.8f" % [id, p.x / size.x, p.y / size.y])
	_pseq += 1
	_controls._adopt_live_pointers(_pseq, "1|" + ";".join(parts))
	_controls._apply_live_pointers()


func test_pointer_snapshot_presses_a_button() -> void:
	_fixed_button_rects()
	_live_ptr({7: Vector2(550, 550)})
	_controls._apply_actions()
	assert_eq(_controls._pointers.get(7), "gas", "a live pointer over the pedal holds it")
	assert_true(Input.is_action_pressed("accelerate"), "and drives the throttle")


func test_pointer_snapshot_release_clears_the_button() -> void:
	# THE bug this path exists for: the browser never delivers the touchend, so no
	# engine release event ever arrives — the finger just stops being listed.
	_fixed_button_rects()
	_live_ptr({7: Vector2(550, 550)})
	_controls._apply_actions()
	assert_true(Input.is_action_pressed("accelerate"), "throttle held while the finger is down")
	_live_ptr({})
	_controls._apply_actions()
	assert_false(Input.is_action_pressed("accelerate"),
		"a finger the browser no longer lists releases the pedal, with no release event")
	assert_eq(_controls._pointers.size(), 0, "and stops being tracked")


func test_pointer_snapshot_ignores_engine_touch_events() -> void:
	# Once the browser is the source of truth, engine touch events must not also
	# register: they use a different id space, and their release half is the thing we
	# can't trust. A press that only exists as an engine event is dropped on sight.
	_fixed_button_rects()
	_live_ptr({})
	_controls._input(_touch(0, Vector2(550, 550), true))
	assert_eq(_controls._pointers.size(), 0, "engine touch events are ignored while a snapshot is live")
	_controls._input(_mouse(Vector2(550, 550), true, 0))
	assert_false(_controls._pointers.has(-1), "and so is the mouse — pointer events cover it")


func test_pointer_snapshot_multitouch_and_partial_release() -> void:
	_fixed_button_rects()
	_live_ptr({3: Vector2(550, 550), 4: Vector2(750, 550)})
	_controls._apply_actions()
	assert_eq(_controls._pointers.size(), 2, "two live pointers, two held regions")
	assert_true(Input.is_action_pressed("brake_reverse"), "the second finger brakes")
	_live_ptr({3: Vector2(550, 550)})
	_controls._apply_actions()
	assert_false(Input.is_action_pressed("brake_reverse"), "lifting one finger releases only its region")
	assert_true(Input.is_action_pressed("accelerate"), "the finger still down keeps its own")


func test_pointer_snapshot_drags_between_regions() -> void:
	_fixed_button_rects()
	_live_ptr({3: Vector2(550, 550)})
	_live_ptr({3: Vector2(750, 550)})
	_controls._apply_actions()
	assert_eq(_controls._pointers.get(3), "brake", "a live pointer re-tests which region it is over")


func test_pointer_snapshot_captures_and_recenters_the_slider() -> void:
	# _slider_rect is Rect2(0, 0, 200, 40) from before_each: centre x = 100.
	_live_ptr({2: Vector2(20, 20)})
	_controls._apply_actions()
	assert_eq(_controls._slider_owner, 2, "a fresh pointer on the rail captures the slider")
	assert_gt(Input.get_action_strength("steer_left"), 0.0, "and steers left of centre")
	_live_ptr({})
	_controls._apply_actions()
	assert_null(_controls._slider_owner, "losing the finger releases the slider")
	assert_almost_eq(Input.get_action_strength("steer_left"), 0.0, 1e-6,
		"steering springs back to centre with no release event")


func test_pointer_snapshot_does_not_capture_the_slider_mid_drag() -> void:
	# A finger already down that merely slides onto the rail must not grab it — the
	# same rule the event path encodes by only capturing in _press.
	_controls._rects = {"gas": Rect2(500, 500, 100, 100)}
	_live_ptr({5: Vector2(550, 550)})
	_live_ptr({5: Vector2(20, 20)})
	_controls._apply_actions()
	assert_null(_controls._slider_owner, "a mid-drag pointer does not capture the slider")


func test_unmeasurable_page_falls_back_to_the_id_path() -> void:
	# The JS reports ok=0 when it can't measure the canvas, so the coordinates would be
	# meaningless. Hitting-testing them anyway would be worse than the id-only
	# reconciliation we already had, so the primary path stands down.
	_controls._adopt_live_pointers(1, "0|")
	assert_null(_controls._live_pointers, "an unmeasurable page publishes no usable snapshot")
	_fixed_button_rects()
	_controls._input(_touch(0, Vector2(550, 550), true))
	assert_eq(_controls._pointers.get(0), "gas", "so engine touch events stay in charge")


func test_a_fresh_press_clears_a_pointer_whose_release_was_lost() -> void:
	# Event path, no snapshot: a finger can't press twice without lifting, so a press
	# at an index we still track proves its release was dropped. Pressing again must
	# start clean — and in particular reclaim the slider, which _press could otherwise
	# never re-capture once its owner was stuck.
	_controls._slider_owner = 0
	_controls._slider_x = 20.0
	_controls._rects = {"gas": Rect2(500, 500, 100, 100)}
	_controls._input(_touch(0, Vector2(550, 550), true))
	assert_null(_controls._slider_owner, "a re-press by the stuck finger frees the slider")
	assert_eq(_controls._pointers.get(0), "gas", "and lands on the region it actually pressed")
	_controls._apply_actions()
	assert_almost_eq(Input.get_action_strength("steer_left"), 0.0, 1e-6,
		"so the phantom steering stops")


func test_pointer_snapshot_ignores_a_stale_sequence() -> void:
	_fixed_button_rects()
	_live_ptr({7: Vector2(550, 550)})
	# An older snapshot (the push and pull paths race) must not resurrect a lifted
	# finger or re-order the state.
	_controls._adopt_live_pointers(1, "1|9:0.5:0.5")
	assert_true(_controls._live_pointers.has(7), "a stale sequence number is discarded")


# --- Steering edges (the press/release change-guard) --------------------------
# _apply_steer only fires action_release on a TRANSITION back to centre rather
# than every frame, so these walk the value across the centre threshold in both
# directions and check the action state is right on each side — a mis-placed
# guard shows up as steering that never releases (stuck) or never presses.

func test_steer_presses_and_releases_across_repeated_frames() -> void:
	_controls._slider_owner = 0
	# Hold left for several frames: still steering left on every one of them.
	_controls._slider_x = 20.0
	for i in 3:
		_controls._apply_actions()
		assert_gt(Input.get_action_strength("steer_left"), 0.0, "left steer holds while the finger is held")
	# Back to centre: releases, and stays released across further frames.
	_controls._slider_x = 100.0
	for i in 3:
		_controls._apply_actions()
		assert_almost_eq(Input.get_action_strength("steer_left"), 0.0, 1e-6,
			"centring the slider releases left steer and keeps it released")
	# And it can be re-pressed afterwards — the guard must not latch.
	_controls._slider_x = 20.0
	_controls._apply_actions()
	assert_gt(Input.get_action_strength("steer_left"), 0.0, "steering presses again after a release")


func test_steer_swaps_sides_cleanly() -> void:
	_controls._slider_owner = 0
	_controls._slider_x = 20.0
	_controls._apply_actions()
	# Straight across to the other edge: the old side must release as the new one presses.
	_controls._slider_x = 180.0
	_controls._apply_actions()
	assert_gt(Input.get_action_strength("steer_right"), 0.0, "the new side steers")
	assert_almost_eq(Input.get_action_strength("steer_left"), 0.0, 1e-6,
		"the old side releases when steering crosses centre")


func test_release_all_clears_a_held_steer() -> void:
	# _release_all runs on scheme switch / exit; a change-guarded release must still
	# leave nothing held (and must not block a later press).
	_controls._slider_owner = 0
	_controls._slider_x = 20.0
	_controls._apply_actions()
	_controls._release_all()
	assert_almost_eq(Input.get_action_strength("steer_left"), 0.0, 1e-6,
		"releasing everything drops a held steer")
	_controls._slider_owner = 0
	_controls._slider_x = 20.0
	_controls._apply_actions()
	assert_gt(Input.get_action_strength("steer_left"), 0.0, "steering works again after a full release")


# --- Pointer routing: touch vs (emulated) mouse -------------------------------
# The project leaves emulate_mouse_from_touch on, so every finger ALSO arrives as
# a mouse event at index -1. _input ignores the synthesised twin (device ==
# DEVICE_ID_EMULATION) so each finger is processed once — while a real mouse
# (its own device id) still drives the overlay for desktop testing.

# Park two hit rects well away from the slider so presses land on buttons.
func _fixed_button_rects() -> void:
	_controls._rects = {
		"gas": Rect2(500, 500, 100, 100),
		"brake": Rect2(700, 500, 100, 100),
	}
	_controls._slider_rect = Rect2(-1000, -1000, 1, 1)


func _touch(index: int, pos: Vector2, pressed: bool) -> InputEventScreenTouch:
	var e := InputEventScreenTouch.new()
	e.index = index
	e.position = pos
	e.pressed = pressed
	return e


func _drag_event(index: int, pos: Vector2) -> InputEventScreenDrag:
	var e := InputEventScreenDrag.new()
	e.index = index
	e.position = pos
	return e


func _mouse(pos: Vector2, pressed: bool, device: int) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.position = pos
	e.pressed = pressed
	e.device = device
	return e


func test_two_touches_make_two_distinct_pointers() -> void:
	_fixed_button_rects()
	_controls._input(_touch(0, Vector2(550, 550), true))
	_controls._input(_touch(1, Vector2(750, 550), true))
	assert_eq(_controls._pointers.size(), 2, "two fingers down = two tracked pointers")
	assert_eq(_controls._pointers.get(0), "gas", "the first finger holds its own region")
	assert_eq(_controls._pointers.get(1), "brake", "the second finger holds its own region")
	# Lifting one leaves the other exactly as it was.
	_controls._input(_touch(0, Vector2(550, 550), false))
	assert_eq(_controls._pointers.size(), 1, "lifting one finger drops only that pointer")
	assert_eq(_controls._pointers.get(1), "brake", "the finger still down keeps its region")


func test_touch_emulated_mouse_is_ignored() -> void:
	_fixed_button_rects()
	_controls._input(_touch(0, Vector2(550, 550), true))
	# The engine's synthesised twin of that same finger must not register a second
	# pointer (which would then be processed, and released, independently).
	_controls._input(_mouse(Vector2(550, 550), true, InputEvent.DEVICE_ID_EMULATION))
	assert_eq(_controls._pointers.size(), 1, "a finger is tracked once, not twice")
	assert_false(_controls._pointers.has(-1), "no phantom mouse pointer from an emulated event")


func test_real_mouse_still_drives_the_controls() -> void:
	_fixed_button_rects()
	_controls._input(_mouse(Vector2(550, 550), true, 0))
	assert_eq(_controls._pointers.get(-1), "gas",
		"a real mouse press still works (desktop testing with mobile_controls_force)")
	_controls._input(_mouse(Vector2(550, 550), false, 0))
	assert_false(_controls._pointers.has(-1), "and its release still clears the pointer")
