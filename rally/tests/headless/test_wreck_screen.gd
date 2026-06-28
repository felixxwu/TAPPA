extends GutTest
# WreckScreen: the mid-event wreck sequence (scripts/wreck_screen.gd) — let the
# crash play out, then an orbit camera + "car wrecked" menu offers Return to HQ.
# Driven directly with a stub car, advancing _process by hand so the phase
# transitions are deterministic. The node is NOT added to the SceneTree (so the
# engine's own _process never races the manual ticks); autofree frees it and its
# owned camera/overlay at the end.

# A minimal stand-in for the player Car: a physics body that exposes the
# controls_locked contract WreckScreen toggles, with no engine/drivetrain cost.
class _CarStub:
	extends VehicleBody3D
	var controls_locked := false


func before_each() -> void:
	Config.reset()


func after_each() -> void:
	Config.reset()


func test_crashes_then_orbits_and_requests_return() -> void:
	var car := _CarStub.new()
	autofree(car)
	var ws := WreckScreen.new()
	autofree(ws)
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
