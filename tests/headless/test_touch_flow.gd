extends GutTest
# TouchFlow plays recorded touches and tilts through the touch-control overlay and logs the actions it holds per tick,
# which is what the touch golden (benchmark/touch_flow.tscn) records.

var _controls: MobileControls


func before_all() -> void:
	Config.reset()
	Config.data.mobile_controls_force = true
	Config.data.tilt_invert = false
	_controls = MobileControls.new()
	add_child(_controls)


func after_all() -> void:
	_controls.free()
	TickInput.release_all()
	Config.reset()


func _at(region: String) -> Array:
	var c := (_controls._rects[region] as Rect2).get_center() / TouchFlow.SCREEN
	return [c.x, c.y]


func test_a_touch_in_a_button_rect_presses_its_action_and_a_release_lets_it_go() -> void:
	_controls.set_scheme(MobileControls.SCHEME_BUTTONS_GAS_BRAKE)
	_controls._compute_rects(TouchFlow.SCREEN)
	var gas := _at("gas")
	var rows: Array[Dictionary] = await TouchFlow.play(_controls, MobileControls.SCHEME_BUTTONS_GAS_BRAKE, [
		{"tick": 1, "touch": 0, "down": true, "at": gas},
		{"tick": 3, "touch": 0, "down": false, "at": gas},
	], 5)
	assert_eq(rows.size(), 5, "one row per tick")
	assert_eq(float(rows[0].strengths[&"accelerate"]), 0.0, "nothing held before the touch")
	assert_gt(float(rows[1].strengths[&"accelerate"]), 0.0, "the touch presses gas")
	assert_true(rows[1].just_pressed.has(&"accelerate"), "on the tick it lands")
	assert_false(rows[2].just_pressed.has(&"accelerate"), "and only that tick")
	assert_eq(float(rows[1].strengths[&"brake_reverse"]), 0.0, "and not the brake")
	assert_eq(float(rows[3].strengths[&"accelerate"]), 0.0, "the release lets it go")


func test_a_tilt_roll_steers_towards_the_lowered_edge() -> void:
	var rows: Array[Dictionary] = await TouchFlow.play(_controls, MobileControls.SCHEME_TILT_GAS_BRAKE, [
		{"tick": 1, "tilt": "4.0:0.0:-8.9"},
		{"tick": 3, "tilt": "-4.0:0.0:-8.9"},
	], 5)
	assert_gt(float(rows[1].strengths[&"steer_right"]), 0.0, "right edge down steers right")
	assert_eq(float(rows[1].strengths[&"steer_left"]), 0.0)
	assert_gt(float(rows[3].strengths[&"steer_left"]), 0.0, "left edge down steers left")
	assert_eq(float(rows[3].strengths[&"steer_right"]), 0.0)


func test_play_leaves_nothing_held_for_the_next_scheme() -> void:
	await TouchFlow.play(_controls, MobileControls.SCHEME_SLIDER_BRAKE_AUTO, [], 2)
	for a in TickInput.ACTIONS:
		assert_false(Input.is_action_pressed(a), "%s released after the run" % a)
