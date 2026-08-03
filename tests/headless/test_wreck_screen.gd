extends GutTest
# WreckScreen: the mid-event wreck sequence (scripts/wreck_screen.gd) — let the
# crash play out, then an orbit camera + "car wrecked" menu offers Return to HQ.
# Driven directly with a stub car, advancing _process by hand. The nodes ARE added
# to the tree (the orbit camera reads the car's global_transform, which needs it),
# but the test never awaits a frame, so the engine's own _process never fires and
# the manual ticks stay deterministic.

# A minimal stand-in for the player Car: a physics body that exposes the
# controls_locked contract WreckScreen toggles, with no engine/drivetrain cost.
class _CarStub:
	extends VehicleBody3D
	var controls_locked := false


func before_each() -> void:
	Config.reset()


func after_each() -> void:
	Config.reset()


# A wired-up WreckScreen over a stub car, plus a counter its return_requested increments.
# Mirrors the setup the first test does inline.
func _screen_and_returns() -> Array:
	var car := _CarStub.new()
	add_child_autofree(car)
	var ws := WreckScreen.new()
	add_child_autofree(ws)
	var returned := {"n": 0}
	ws.return_requested.connect(func() -> void: returned["n"] += 1)
	ws.setup(car)
	return [ws, returned]


# Advance past the minimum settle beat so the orbit camera + menu take over.
func _settle(ws) -> void:
	ws._process(WreckScreen.SETTLE_MIN_SECONDS + 0.5)
	ws._process(0.5)


func test_crashes_then_orbits_and_requests_return() -> void:
	var car := _CarStub.new()
	add_child_autofree(car)
	var ws := WreckScreen.new()
	add_child_autofree(ws)
	var returned := {"n": 0}
	ws.return_requested.connect(func() -> void: returned["n"] += 1)

	ws.setup(car)  # no camera/HUD — the phase logic doesn't need them
	assert_eq(ws.sequence_phase(), ws.Seq.CRASHING, "starts in the crash phase")
	assert_false(ws._overlay.visible, "the menu stays hidden while the crash plays out")
	assert_true(car.controls_locked, "the wrecked car is locked so it can't be driven away")

	# Before the minimum settle beat the menu must not appear, even though the stub
	# car (zero velocity) already reads as stopped.
	ws._process(0.5)
	assert_eq(ws.sequence_phase(), ws.Seq.CRASHING, "still crashing before the minimum beat")

	# Past the minimum beat with the car at rest: the orbit camera + menu take over.
	ws._process(0.5)
	assert_eq(ws.sequence_phase(), ws.Seq.ORBIT, "settles into the orbit/menu phase")
	assert_true(ws._overlay.visible, "the wreck menu is shown once settled")
	assert_true(ws._orbit_cam.current, "the orbit camera takes over from the chase camera")

	# Return to HQ reports the wreck (world.gd routes this to RallySession.report_wreck).
	ws._return_button.pressed.emit()
	assert_eq(returned["n"], 1, "Return to HQ emits return_requested")


# The button is FOCUS_NONE and is driven from _unhandled_input rather than through
# MenuNav.attach (see features/menus.md -> "Menu navigation", the single-action pattern), so
# the keyboard/gamepad path is a SEPARATE code path from `pressed`. Drive it for real —
# asserting via pressed.emit() alone leaves it untested.
func test_menu_select_returns_to_hq_without_a_pointer() -> void:
	var made := _screen_and_returns()
	var ws = made[0]
	var returned: Dictionary = made[1]
	# Settle into the orbit/menu phase, the only phase that accepts the input.
	_settle(ws)
	assert_eq(ws.sequence_phase(), ws.Seq.ORBIT, "precondition: the menu is up")

	var press := InputEventAction.new()
	press.action = "menu_select"
	press.pressed = true
	ws._unhandled_input(press)
	assert_eq(returned["n"], 1, "menu_select alone returns to HQ (no pointer needed)")


func test_menu_select_is_ignored_before_the_menu_appears() -> void:
	# While the car is still crashing there is no menu to accept input, so the action must
	# not short-circuit the sequence.
	var made := _screen_and_returns()
	var ws = made[0]
	var returned: Dictionary = made[1]
	assert_ne(ws.sequence_phase(), ws.Seq.ORBIT, "precondition: not settled yet")
	var press := InputEventAction.new()
	press.action = "menu_select"
	press.pressed = true
	ws._unhandled_input(press)
	assert_eq(returned["n"], 0, "menu_select does nothing until the menu is up")
