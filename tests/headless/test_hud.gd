extends GutTest
# HUD speed readout: shows the car's airspeed (chassis velocity magnitude)
# in km/h, gated by the hud_enabled config flag.

const SceneHelpers = preload("res://tests/headless/scene_helpers.gd")

var _scene: Node3D


func before_all() -> void:
	# The HUD tests don't care about the track or its foliage — minimal_world() boots
	# main.tscn with a 1-turn track and no trees (~15s -> <1s), and we build it ONCE for
	# the whole script. The HUD is driven by the car's state + config flags each frame;
	# before_each restores those to a clean baseline so the shared instance is order-safe.
	SceneHelpers.minimal_world()
	_scene = load("res://main.tscn").instantiate()
	add_child(_scene)


func after_all() -> void:
	_scene.free()
	# minimal_world() left Config on a 1-turn / no-foliage track; restore the authored
	# baseline so later files that don't reset Config (e.g. test_loading_screen) still
	# generate the full world they expect.
	Config.reset()


func before_each() -> void:
	# Reset the shared scene to a clean baseline: the HUD reads the car (speed / gear /
	# rpm / HP) and several config flags every frame, and individual tests inject
	# velocity / engine state / damage, toggle the debug readout, and flip HUD config
	# flags — undo all of that so no test leaks state into the next.
	var cfg: GameConfig = Config.data
	cfg.hud_enabled = true
	cfg.hud_elapsed_enabled = true
	cfg.hud_position_enabled = true
	cfg.hud_pacenotes_enabled = true
	cfg.hud_hp_enabled = true
	var car: VehicleBody3D = _scene.get_node("Car")
	car.linear_velocity = Vector3.ZERO
	car.angular_velocity = Vector3.ZERO
	# Forced induction is off by default so the boost bar is hidden unless a test fits a
	# part. Reset here rather than save/restore per test: an early return or a failing
	# await in a test would otherwise leak a fitted turbo into the shared autoload.
	cfg.turbo_enabled = false
	cfg.supercharger_boost_gain = 0.0
	# Nitrous likewise starts unfitted, so its gauge is hidden unless a test fits a tank.
	cfg.nitrous_boost_gain = 0.0
	cfg.nitrous_tank_seconds = 0.0
	var engine: EngineSim = car.drivetrain.engine
	engine.auto = true
	engine.gear = 1
	engine.boost = 0.0
	engine.sc_boost = 0.0
	engine.nitrous_charge = 0.0
	car.damage.field(1000.0, 1000.0)  # a healthy, mortal car
	# Force the diagnostic readout + stage widgets back to hidden (tests show them).
	var hud = _scene.get_node("HUD")
	hud.hide_countdown()
	hud.hide_off_road()  # also clears its change-gate, so the next show_off_road re-formats
	for w in ["StageCompletePanel", "CutFlashLabel"]:
		var node := hud.get_node_or_null(w)
		if node != null:
			node.visible = false
	# The standings readout and the cut flash SHARE the top-centre row, so a test that
	# leaves a flash on the clock would suppress the next test's readout. Clear both.
	hud.hide_position()
	hud._cut_flash_left = 0.0
	await get_tree().process_frame


func test_hud_visible_when_enabled() -> void:
	assert_true(Config.data.hud_enabled, "default config keeps the HUD on")
	assert_true(_scene.get_node("HUD").visible, "HUD visible when hud_enabled")


func test_hud_hidden_when_disabled() -> void:
	var cfg: GameConfig = Config.data
	cfg.hud_enabled = false
	var scene: Node3D = load("res://main.tscn").instantiate()
	add_child_autofree(scene)
	cfg.hud_enabled = true
	assert_false(scene.get_node("HUD").visible, "HUD hidden when hud_enabled is off")


func test_speed_label_tracks_airspeed() -> void:
	# 20 m/s = 72 km/h; tire/drag forces shed a little over the frames the
	# label needs to refresh, hence the loose lower bound.
	var car: VehicleBody3D = _scene.get_node("Car")
	var label: Label = _scene.get_node("HUD/SpeedLabel")
	car.linear_velocity = -car.global_transform.basis.z * 20.0
	await get_tree().process_frame
	await get_tree().process_frame
	assert_between(label.text.to_int(), 50, 80,
		"label shows the chassis speed in km/h (20 m/s ≈ 72 km/h)")


func test_gear_and_rpm_labels_track_engine() -> void:
	var car: VehicleBody3D = _scene.get_node("Car")
	var engine: EngineSim = car.drivetrain.engine
	engine.auto = false  # don't let the auto box shift the gear we inject
	engine.gear = 3
	engine.omega = 3000.0 * TAU / 60.0
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq((_scene.get_node("HUD/GearLabel") as Label).text, "3", "gear label shows the gear")
	# The engine keeps simulating (decaying toward idle) while frames pass, so
	# compare the label against the live value, not the value we injected.
	var rpm := (_scene.get_node("HUD/RPMLabel") as Label).text.to_int()
	assert_almost_eq(float(rpm), engine.rpm(), 300.0, "rpm label tracks engine speed")
	engine.gear = -1
	await get_tree().process_frame
	assert_eq((_scene.get_node("HUD/GearLabel") as Label).text, "R", "reverse shows R")
	engine.gear = 0
	await get_tree().process_frame
	assert_eq((_scene.get_node("HUD/GearLabel") as Label).text, "N", "neutral shows N")


# --- H-key debug readout (features/hud.md, features/debug-tools.md) -------------
#
# MEMBERSHIP IS DATA: hud.gd's `DEBUG_READOUT_NODES` is the single source of truth for
# which HUD elements are part of the H-gated dev overlay, and the generic tests below
# iterate it rather than naming labels. Moving an element in or out of the overlay is a
# one-line edit to that constant.
#
# The per-element tests that follow exist so a change to ONE element's visibility fails
# with a test name that says which element — a generic "every member" failure alone
# doesn't tell you that.

func _press_h() -> void:
	Input.action_press("toggle_debug_arrows")
	await get_tree().process_frame
	await get_tree().process_frame
	Input.action_release("toggle_debug_arrows")


func _debug_elements() -> Array:
	var hud = _scene.get_node("HUD")
	var out := []
	for n in hud.DEBUG_READOUT_NODES:
		var node: CanvasItem = hud.get_node_or_null(NodePath(String(n)))
		assert_not_null(node, "DEBUG_READOUT_NODES names a real HUD node: %s" % n)
		if node != null:
			out.append(node)
	return out


func test_every_debug_readout_member_is_hidden_on_startup() -> void:
	await get_tree().process_frame
	var elements := _debug_elements()
	assert_gt(elements.size(), 0, "the debug readout has members")
	for element in elements:
		assert_false(element.visible,
			"%s is part of the H debug readout, so it is hidden on startup" % element.name)


func test_h_toggles_every_debug_readout_member_on_and_off() -> void:
	await get_tree().process_frame
	var elements := _debug_elements()
	await _press_h()
	for element in elements:
		assert_true(element.visible, "H reveals %s" % element.name)
	await _press_h()
	for element in elements:
		assert_false(element.visible, "H again hides %s" % element.name)


# --- Why there is no per-element membership test here --------------------------
# There used to be one named test per gated label (gear, speed, rpm), each asserting
# "this element IS in DEBUG_READOUT_NODES". They were deleted in round 008, deliberately:
#
#   * They pinned a PRODUCT CHOICE, not a contract. Which labels sit behind the dev
#     toggle is a decision a designer may reverse at any time — CLAUDE.md's "never test
#     a value someone may reasonably change" applies to membership just as much as to a
#     tunable number.
#   * They made the constant's own promise false. The comment above DEBUG_READOUT_NODES
#     says moving an element in or out is a ONE-LINE edit; with a hand-named test per
#     element it was a one-line edit plus a rewrite inside a 550-line test file, and two
#     separate eval probes duly did the first and skipped the second.
#
# The real contract — every member is hidden at startup, and H toggles every member,
# whatever the membership happens to be — is covered by the two membership-driven tests
# above, which iterate DEBUG_READOUT_NODES and need no edit when it changes.
#
# What the docs say about membership is guarded separately, by test_hud_docs.gd.


func test_seed_readout_shows_the_current_track_seed_when_revealed() -> void:
	var seed_label := _scene.get_node("HUD/SeedLabel") as Label
	await get_tree().process_frame
	await _press_h()
	assert_true(seed_label.visible, "H shows the seed readout")
	assert_eq(seed_label.text, "Seed %d" % Config.data.track_seed,
		"seed readout shows the current track seed")
	await _press_h()


func test_boost_text_formatting() -> void:
	# Pure formatter for the debug boost readout: N/A on an NA engine, else a
	# percentage of full boost. (Logic, not tuned values — the percentages are
	# derived from the boost fraction passed in.) The flag means "forced induction
	# fitted", so it covers a supercharger's belt boost as well as a turbo's.
	const Hud = preload("res://scripts/hud.gd")
	assert_eq(Hud.boost_text(false, 0.0), "Boost N/A", "no turbo or blower shows N/A")
	assert_eq(Hud.boost_text(false, 0.9), "Boost N/A", "NA ignores any stray boost value")
	assert_eq(Hud.boost_text(true, 0.0), "Boost 0%", "a spooled-down turbo reads 0%")
	assert_eq(Hud.boost_text(true, 0.5), "Boost 50%", "half boost reads 50%")
	assert_eq(Hud.boost_text(true, 1.0), "Boost 100%", "full boost reads 100%")
	assert_eq(Hud.boost_text(true, 2.0), "Boost 100%", "boost is clamped to 100%")


func test_seed_text_formatting() -> void:
	# Pure formatter for the debug seed readout: echoes whatever seed is passed
	# in (logic, not an authored value).
	const Hud = preload("res://scripts/hud.gd")
	assert_eq(Hud.seed_text(42), "Seed 42", "seed readout echoes the seed")
	assert_eq(Hud.seed_text(-7), "Seed -7", "negative seeds print verbatim")


func test_off_road_text_formatting() -> void:
	# Pure formatter for the off-track warning: the label plus the seconds left on the
	# reset clock, to a tenth. Never shows a negative countdown — the clock can tick
	# slightly past zero between the reset firing and the HUD's next frame.
	const Hud = preload("res://scripts/hud.gd")
	assert_eq(Hud.off_road_text(3.0), "OFF TRACK  3.0", "whole seconds keep their tenth")
	assert_eq(Hud.off_road_text(1.25), "OFF TRACK  1.2", "the countdown reads to a tenth")
	assert_eq(Hud.off_road_text(0.0), "OFF TRACK  0.0", "an expired clock reads zero")
	assert_eq(Hud.off_road_text(-0.5), "OFF TRACK  0.0", "a negative countdown is clamped to zero")


func test_off_road_warning_shows_and_hides() -> void:
	# The warning is a live state readout, not a fading popup: show_off_road puts it up
	# and it stays up until hide_off_road takes it down (StageManager owns that call).
	var hud = _scene.get_node("HUD")
	var label := hud.get_node("OffRoadLabel") as Label
	assert_false(label.visible, "the warning starts hidden")
	hud.show_off_road(2.5)
	assert_true(label.visible, "show_off_road reveals the warning")
	assert_eq(label.text, "OFF TRACK  2.5", "and prints the seconds left")
	hud.show_off_road(1.5)
	assert_eq(label.text, "OFF TRACK  1.5", "a later call updates the countdown in place")
	assert_true(label.visible, "and it does not fade out on its own")
	hud.hide_off_road()
	assert_false(label.visible, "hide_off_road takes it down")


func test_grip_text_formatting() -> void:
	# Pure formatter for one grip cell: the corner name plus how far up its grip curve the
	# tire is, as a percentage, and a dash when there's no reading.
	const Hud = preload("res://scripts/hud.gd")
	assert_eq(Hud.grip_text("FL", 0.0), "FL 0%", "a tire not slipping at all reads 0%")
	assert_eq(Hud.grip_text("RR", 0.5), "RR 50%", "halfway to the limit reads 50%")
	assert_eq(Hud.grip_text("FR", 1.0), "FR 100%", "right on the limit reads 100%")
	assert_eq(Hud.grip_text("RL", 1.2), "RL 120%",
		"past the limit is NOT clamped — a sliding tire is what the readout is for")
	assert_eq(Hud.grip_text("FL", -1.0), "FL  --",
		"no reading (wheel airborne) shows a dash, not 0%")


func test_grip_colour_grades_toward_the_limit() -> void:
	# The cell's tint is the readout's legend: neutral with grip in reserve, warm as it
	# approaches the limit, red at or past it.
	const Hud = preload("res://scripts/hud.gd")
	assert_eq(Hud.grip_color(0.2), UITheme.INK, "plenty of grip in reserve reads as neutral ink")
	assert_eq(Hud.grip_color(-1.0), UITheme.INK, "no reading reads as neutral ink")
	assert_eq(Hud.grip_color(1.0), UITheme.RED, "exactly on the limit is red")
	assert_eq(Hud.grip_color(1.5), UITheme.RED, "past the limit stays red")
	assert_ne(Hud.grip_color(0.95), UITheme.INK,
		"approaching the limit is called out, not left neutral")
	assert_ne(Hud.grip_color(0.95), UITheme.RED,
		"approaching the limit is distinct from being at it")


func test_grip_corner_index_maps_the_cars_plan_view() -> void:
	# The 2x2 grid is the car seen from above: front axle on the top row, left wheel in
	# the left column. Godot's basis X is positive to the RIGHT, and the drivetrain's
	# rear flag is the wheel's use_as_traction.
	const Hud = preload("res://scripts/hud.gd")
	assert_eq(Hud.corner_index(false, -0.85), 0, "front left is the top-left cell")
	assert_eq(Hud.corner_index(false, 0.85), 1, "front right is the top-right cell")
	assert_eq(Hud.corner_index(true, -0.85), 2, "rear left is the bottom-left cell")
	assert_eq(Hud.corner_index(true, 0.85), 3, "rear right is the bottom-right cell")


func test_grip_grid_is_a_2x2_of_four_corners_hidden_until_h() -> void:
	# The grid is a dev diagnostic on the same H gate as the rest of the debug readout,
	# and it must lay out as TWO columns — a 1x4 or 4x1 list loses the whole point of
	# reading a corner's grip off the car's plan view.
	var grid := _scene.get_node("HUD/GripGrid") as GridContainer
	await get_tree().process_frame
	assert_eq(grid.columns, 2, "the grip readout is a 2x2 grid")
	assert_eq(grid.get_child_count(), 4, "one cell per wheel")
	assert_false(grid.visible, "grip grid hidden on startup")
	# Both rows must have real height — a container hanging off the CanvasLayer gets no
	# layout from a parent, so a zero-tall rect would stack the rows on top of each other.
	var top_left := grid.get_child(0) as Label
	var bottom_left := grid.get_child(2) as Label
	assert_gt(bottom_left.position.y, top_left.position.y,
		"the rear row sits BELOW the front row")
	assert_gt((grid.get_child(1) as Label).position.x, top_left.position.x,
		"the right column sits right of the left column")
	Input.action_press("toggle_debug_arrows")
	await get_tree().process_frame
	await get_tree().process_frame
	Input.action_release("toggle_debug_arrows")
	assert_true(grid.visible, "H shows the grip grid")
	Input.action_press("toggle_debug_arrows")
	await get_tree().process_frame
	await get_tree().process_frame
	Input.action_release("toggle_debug_arrows")
	assert_false(grid.visible, "H again hides the grip grid")


func test_grip_grid_reads_the_drivetrain_readouts_per_corner() -> void:
	# End to end: a grip figure published for one wheel lands in that wheel's OWN cell.
	var car: VehicleBody3D = _scene.get_node("Car")
	var grid := _scene.get_node("HUD/GripGrid") as GridContainer
	var hud: CanvasLayer = _scene.get_node("HUD")
	var drivetrain: Drivetrain = car.drivetrain
	# Pick a real wheel and work out where its reading is SUPPOSED to land, rather than
	# assuming a scene-tree order.
	var wheel: VehicleWheel3D = drivetrain.all_wheels[0]
	var expected := _corner_of(drivetrain, wheel)
	drivetrain.readouts.clear()
	drivetrain.readouts[wheel] = {"grip": 0.42}
	grid.visible = true
	hud._update_grip_grid()
	assert_eq((grid.get_child(expected) as Label).text,
		"%s 42%%" % ["FL", "FR", "RL", "RR"][expected],
		"the wheel's reading lands in its own cell")
	for i in 4:
		if i == expected:
			continue
		assert_string_ends_with((grid.get_child(i) as Label).text, "--",
			"a wheel with no readout published shows a dash")
	drivetrain.readouts.clear()
	grid.visible = false


# Where a wheel's reading belongs in the grid, derived the same way the HUD does it.
func _corner_of(drivetrain: Drivetrain, wheel: VehicleWheel3D) -> int:
	const Hud = preload("res://scripts/hud.gd")
	return Hud.corner_index(wheel.use_as_traction,
		(drivetrain.hardpoints[wheel] as Vector3).x)


func test_hud_has_no_version_label() -> void:
	# The build version now lives on the title screen only (see test_hq.gd); the
	# in-run HUD must not carry it.
	assert_null(_scene.get_node_or_null("HUD/VersionLabel"),
		"driving HUD no longer shows the build version")


func test_elapsed_timer_anchored_top_left() -> void:
	# The run timer sits in the top-left corner now — the top centre is given over to
	# the pacenote strip (features/hud.md), which frees the vertical space the centred
	# timer used to take.
	var label := _scene.get_node("HUD/ElapsedLabel") as Label
	assert_not_null(label, "HUD has the run timer")
	assert_almost_eq(label.anchor_left, 0.0, 0.001, "timer anchored to the left edge")
	assert_almost_eq(label.anchor_right, 0.0, 0.001, "timer anchored to the left edge")
	assert_eq(label.horizontal_alignment, HORIZONTAL_ALIGNMENT_LEFT,
		"timer text is left-aligned")


# --- Stage flow widgets (todo/stage-start-and-end.md) ------------------------
# These call the HUD methods directly (synchronously, so the scene's StageManager
# doesn't tick and overwrite the state) and assert the labels/panel.

func test_countdown_label_formats_ticks_and_go() -> void:
	var hud := _scene.get_node("HUD")
	var label := _scene.get_node("HUD/CountdownLabel") as Label
	hud.show_countdown(2.5)
	assert_true(label.visible, "countdown label shown while counting")
	assert_eq(label.text, "3", "ceili(2.5) shows 3 (the first second counts as 3)")
	hud.show_countdown(1.6)
	assert_eq(label.text, "2", "ceili(1.6) shows 2")
	hud.show_countdown(0.6)
	assert_eq(label.text, "1", "ceili(0.6) shows 1")
	hud.show_countdown(0.0)
	assert_eq(label.text, "GO", "zero shows GO")
	hud.hide_countdown()
	assert_false(label.visible, "hide_countdown hides the label")


func test_elapsed_label_formats_and_respects_config() -> void:
	var hud := _scene.get_node("HUD")
	var label := _scene.get_node("HUD/ElapsedLabel") as Label
	label.visible = false
	Config.data.hud_elapsed_enabled = true
	hud.show_elapsed(67.43)
	assert_true(label.visible, "elapsed label shown when hud_elapsed_enabled")
	assert_eq(label.text, "1:07.43", "elapsed formats as m:ss.cc")
	# Disabled: the label is left untouched (stays hidden).
	label.visible = false
	Config.data.hud_elapsed_enabled = false
	hud.show_elapsed(99.9)
	assert_false(label.visible, "elapsed label suppressed when hud_elapsed_enabled is off")
	Config.data.hud_elapsed_enabled = true


func test_stage_complete_panel_shows_final_time() -> void:
	var hud := _scene.get_node("HUD")
	var panel := _scene.get_node("HUD/StageCompletePanel") as Control
	var label := _scene.get_node("HUD/StageCompletePanel/Box/StageCompleteLabel") as Label
	assert_false(panel.visible, "complete panel hidden until the stage ends")
	hud.show_stage_complete(67.43)
	assert_true(panel.visible, "complete panel shown on stage completion")
	assert_string_contains(label.text, "1:07.43", "panel shows the final time")


# --- Live standings readout (features/hud.md) --------------------------------

# The readout keeps its own "last shown" state so a per-frame drive doesn't rebuild
# strings; hide_position() clears it, which is also what makes each test start from a
# stage that has just been armed rather than mid-run.
func _standings_labels() -> Array:
	var hud := _scene.get_node("HUD")
	hud.hide_position()
	return [hud, _scene.get_node("HUD/PositionLabel") as Label,
		_scene.get_node("HUD/PositionGapLabel") as Label]


func test_standings_readout_is_hidden_until_the_stage_drives_it() -> void:
	var parts := _standings_labels()
	assert_not_null(parts[1], "HUD builds the position label")
	assert_not_null(parts[2], "HUD builds the gap label")
	assert_false((parts[1] as Label).visible, "no position shown before the stage drives it")
	assert_false((parts[2] as Label).visible, "no gap shown either")


func test_chasing_reads_the_position_and_the_time_to_find() -> void:
	var parts := _standings_labels()
	parts[0].show_position(3, 12, 1420, false)
	var pos := parts[1] as Label
	var gap := parts[2] as Label
	assert_true(pos.visible, "the readout shows once driven")
	assert_string_contains(pos.text, "P3", "the position is named")
	assert_string_contains(pos.text, "12", "the field size is named")
	assert_true(gap.visible, "the gap line shows alongside it")
	assert_string_contains(gap.text, "1.42", "the gap reads to the centisecond")
	assert_string_contains(gap.text, "behind P2", "and names the position being chased")


func test_leading_words_the_gap_as_a_cushion_and_reads_positive() -> void:
	var parts := _standings_labels()
	parts[0].show_position(1, 12, 900, true)
	var gap := parts[2] as Label
	assert_string_contains(gap.text, "0.90", "the cushion reads to the centisecond")
	assert_string_contains(gap.text, "ahead of P2",
		"leading is worded as holding a gap, not chasing one")
	assert_eq(gap.get_theme_color("font_color"), UITheme.GREEN, "leading tints the gap green")


func test_the_gap_line_is_worded_not_signed() -> void:
	const Hud = preload("res://scripts/hud.gd")
	# Pure helpers, so the wording is pinned without the scene. A bare ± in the corner of
	# the screen at speed doesn't say WHICH WAY; these do.
	assert_string_contains(Hud.gap_text(1500, false, 4), "behind P3",
		"chasing points at the place above")
	assert_string_contains(Hud.gap_text(1500, true, 1), "ahead of P2",
		"leading points at the place below")
	assert_eq(Hud.position_text(3, 12), "P3/12", "the position line is place-of-field")


func test_a_field_of_one_quotes_no_gap() -> void:
	var parts := _standings_labels()
	parts[0].show_position(1, 1, 0, true)
	assert_true((parts[1] as Label).visible, "the position still shows")
	assert_false((parts[2] as Label).visible, "but there is nobody to be a gap to")


func test_standings_readout_respects_config() -> void:
	var parts := _standings_labels()
	Config.data.hud_position_enabled = false
	parts[0].show_position(3, 12, 1420, false)
	assert_false((parts[1] as Label).visible,
		"readout suppressed when hud_position_enabled is off")
	Config.data.hud_position_enabled = true


func test_gaining_a_position_slides_up_and_flashes_green() -> void:
	var parts := _standings_labels()
	var hud = parts[0]
	var pos := parts[1] as Label
	hud.show_position(3, 12, 1420, false)
	var resting := pos.offset_top
	hud.show_position(2, 12, 800, false)      # overtook someone
	hud._tick_position_anim(0.05)
	assert_true(pos.offset_top > resting, "a gained place slides the label up into its row")
	var col := pos.get_theme_color("font_color")
	assert_true(col.g > col.r, "and flashes green (the design system's positive colour)")


func test_losing_a_position_slides_down_and_flashes_red() -> void:
	var parts := _standings_labels()
	var hud = parts[0]
	var pos := parts[1] as Label
	hud.show_position(3, 12, 1420, false)
	var resting := pos.offset_top
	hud.show_position(4, 12, 300, false)      # passed by someone
	hud._tick_position_anim(0.05)
	assert_true(pos.offset_top < resting, "a lost place slides the label down into its row")
	var col := pos.get_theme_color("font_color")
	assert_true(col.r > col.g, "and flashes red")


func test_the_position_animation_settles_back_to_rest() -> void:
	var parts := _standings_labels()
	var hud = parts[0]
	var pos := parts[1] as Label
	hud.show_position(3, 12, 1420, false)
	var resting := pos.offset_top
	hud.show_position(2, 12, 800, false)
	hud._tick_position_anim(0.05)
	hud._tick_position_anim(5.0)   # well past the animation's length
	assert_almost_eq(pos.offset_top, resting, 0.001, "the label returns to its row")
	assert_eq(pos.get_theme_color("font_color"), UITheme.INK,
		"and to plain ink — the flash is a nudge, not a permanent tint")


func test_the_first_position_of_a_stage_is_not_an_overtake() -> void:
	# Arming a fresh stage and showing a position must not play the gain/lose animation:
	# the readout is appearing, nobody was passed.
	var parts := _standings_labels()
	var hud = parts[0]
	var pos := parts[1] as Label
	var resting := pos.offset_top
	hud.show_position(5, 12, 1000, false)
	hud._tick_position_anim(0.05)
	assert_almost_eq(pos.offset_top, resting, 0.001, "no slide on the first position shown")
	assert_eq(pos.get_theme_color("font_color"), UITheme.INK, "and no flash")


func test_hiding_the_readout_forgets_the_shown_position() -> void:
	# Otherwise the next stage's first position would read as an overtake relative to the
	# last stage's finishing place.
	var parts := _standings_labels()
	var hud = parts[0]
	var pos := parts[1] as Label
	hud.show_position(2, 12, 800, false)
	hud.hide_position()
	assert_false(pos.visible, "hidden on request")
	var resting := pos.offset_top
	hud.show_position(9, 12, 800, false)
	hud._tick_position_anim(0.05)
	assert_almost_eq(pos.offset_top, resting, 0.001,
		"the first position after a hide is an appearance, not a drop of seven places")


func test_the_readout_sits_centre_screen_not_in_a_corner() -> void:
	# It shares the top-centre popup row with the cut flash, under the pacenote strip —
	# the eye-line the player already reads mid-stage. A corner-anchored readout (which is
	# where this started) is the regression being guarded.
	var parts := _standings_labels()
	var pos := parts[1] as Label
	var gap := parts[2] as Label
	var cut := _scene.get_node("HUD/CutFlashLabel") as Label
	assert_eq(pos.anchor_left, 0.5, "the position line is centre-anchored")
	assert_eq(gap.anchor_left, 0.5, "so is the gap line")
	assert_eq(pos.horizontal_alignment, HORIZONTAL_ALIGNMENT_CENTER,
		"and its text is centred within its box")
	assert_eq(pos.offset_top, cut.offset_top,
		"the position line and the cut flash share one row — they take turns on it")
	assert_true(gap.offset_top > pos.offset_top, "the gap line sits below the position line")


func test_a_cut_penalty_takes_over_the_standings_row() -> void:
	var parts := _standings_labels()
	var hud = parts[0]
	Config.data.cut_penalty_enabled = true
	hud.show_position(3, 12, 1420, false)
	assert_true((parts[1] as Label).visible, "the readout is up before the cut")
	hud.show_cut_flash(1.0, 2.5)
	var cut := _scene.get_node("HUD/CutFlashLabel") as Label
	assert_true(cut.visible, "the penalty takes the row")
	assert_string_contains(cut.text, "2.5", "and shows the penalty applied")
	assert_false((parts[1] as Label).visible, "the position line yields to it")
	assert_false((parts[2] as Label).visible, "and so does the gap line")
	# A frame driven while the penalty is up must not put the readout back over the top of it.
	hud.show_position(3, 12, 1420, false)
	assert_false((parts[1] as Label).visible, "the readout stays down while the penalty shows")


func test_the_standings_come_back_once_the_penalty_has_had_its_say() -> void:
	var parts := _standings_labels()
	var hud = parts[0]
	Config.data.cut_penalty_enabled = true
	hud.show_position(2, 12, 800, false)
	hud.show_cut_flash(1.0, 2.5)
	# Run the flash's clock out the way _process does, then drive one more frame.
	hud._cut_flash_left = 0.0
	hud.show_position(2, 12, 800, false)
	assert_true((parts[1] as Label).visible, "the readout returns on its own")
	assert_string_contains((parts[1] as Label).text, "P2",
		"still carrying the current position — nothing had to be restored by hand")


func test_a_position_change_behind_the_penalty_is_not_lost() -> void:
	# The player is passed while the cut flash is up. The readout is down, but the change
	# must still register, so it isn't re-animated as a fresh overtake later.
	var parts := _standings_labels()
	var hud = parts[0]
	Config.data.cut_penalty_enabled = true
	hud.show_position(3, 12, 1420, false)
	hud.show_cut_flash(1.0, 2.5)
	hud.show_position(4, 12, 300, false)   # dropped a place behind the flash
	hud._cut_flash_left = 0.0
	hud.show_position(4, 12, 300, false)
	var pos := parts[1] as Label
	assert_string_contains(pos.text, "P4", "the position caught up behind the flash")
	var resting := pos.offset_top
	hud._tick_position_anim(5.0)
	hud.show_position(4, 12, 300, false)
	hud._tick_position_anim(0.05)
	assert_almost_eq(pos.offset_top, resting, 0.001,
		"and is not replayed as an overtake once the row is handed back")


func test_the_gap_number_eases_toward_a_moving_target() -> void:
	# The projection behind the gap moves every frame, so the raw figure chatters in the
	# hundredths. The displayed number chases it instead of being written raw.
	var parts := _standings_labels()
	var hud = parts[0]
	var gap := parts[2] as Label
	hud.show_position(3, 12, 1000, false)
	assert_string_contains(gap.text, "1.00", "the first update snaps to the real gap")
	hud.show_position(3, 12, 5000, false)   # target jumps four seconds
	assert_string_contains(gap.text, "1.00",
		"the jump does not land on the label in one frame")
	hud._tick_gap_smoothing(0.1)
	assert_false(gap.text.contains("1.00"), "a frame of easing moves the number")
	assert_false(gap.text.contains("5.00"), "but not all the way there at once")
	# Enough frames and it arrives — the easing is a delay, not a permanent offset.
	for _i in 60:
		hud._tick_gap_smoothing(0.05)
	assert_string_contains(gap.text, "5.00", "the number settles on the real gap")


func test_the_first_gap_of_a_stage_does_not_count_up_from_zero() -> void:
	# Easing from a cold start would show seconds that were never true. It snaps instead.
	var parts := _standings_labels()
	var hud = parts[0]
	hud.show_position(5, 12, 3400, false)
	assert_string_contains((parts[2] as Label).text, "3.40",
		"the readout appears already showing the real gap")


func test_changing_position_snaps_the_gap_instead_of_gliding() -> void:
	# The gap is now measured against a DIFFERENT car, so gliding across the old value would
	# quote seconds that were true of neither.
	var parts := _standings_labels()
	var hud = parts[0]
	var gap := parts[2] as Label
	hud.show_position(3, 12, 1000, false)
	hud.show_position(4, 12, 6000, false)   # passed — the car ahead is a different one
	assert_string_contains(gap.text, "6.00", "a position change snaps to the new gap")
	assert_string_contains(gap.text, "behind P3", "and re-names the place above")


func test_taking_the_lead_snaps_the_gap_too() -> void:
	# Same reason: chasing P2 and holding a cushion over P2 are different measurements.
	var parts := _standings_labels()
	var hud = parts[0]
	hud.show_position(1, 12, 4500, true)
	assert_string_contains((parts[2] as Label).text, "4.50 ahead of P2",
		"the cushion is shown as-is the frame it becomes one")


func test_a_settled_gap_costs_nothing_to_tick() -> void:
	# The ease bails out once it has arrived, so the common frame does no float work and
	# builds no string.
	var parts := _standings_labels()
	var hud = parts[0]
	hud.show_position(3, 12, 2000, false)
	var before := (parts[2] as Label).text
	hud._tick_gap_smoothing(0.016)
	assert_eq((parts[2] as Label).text, before, "an arrived number is left alone")


# --- Pacenote strip (features/hud.md) ----------------------------------------

func _pace_notes() -> Array:
	# Two synthetic notes — the HUD only reads corner + flip to pick the arrow art.
	return [{"corner": "3", "flip": false}, {"corner": "Hairpin", "flip": true}]


func test_set_pacenotes_builds_a_board_per_note() -> void:
	var hud := _scene.get_node("HUD")
	hud.set_pacenotes(_pace_notes())
	await get_tree().process_frame
	var rects := 0
	for child in hud.get_children():
		if child is TextureRect and String(child.name).begins_with("Pacenote"):
			rects += 1
	assert_eq(rects, 2, "one TextureRect built per pacenote")
	# The current turn (index 0) is shown at full opacity once the strip settles.
	var first := hud.get_node_or_null("Pacenote0") as TextureRect
	assert_not_null(first, "the current-turn board exists")
	assert_true(first.visible, "the current turn is on screen")


func test_set_pacenotes_builds_nothing_when_disabled() -> void:
	var hud := _scene.get_node("HUD")
	Config.data.hud_pacenotes_enabled = false
	hud.set_pacenotes(_pace_notes())
	await get_tree().process_frame
	for child in hud.get_children():
		assert_false(child is TextureRect and String(child.name).begins_with("Pacenote"),
			"no pacenote boards built when the strip is disabled")
	Config.data.hud_pacenotes_enabled = true


func test_show_pacenotes_advances_the_current_turn() -> void:
	# Advancing the current index eventually slides the passed board off the left
	# (it fades out) while a later board takes the opaque current slot.
	var hud := _scene.get_node("HUD")
	hud.set_pacenotes([{"corner": "1", "flip": false}, {"corner": "2", "flip": false},
		{"corner": "3", "flip": false}])
	await get_tree().process_frame
	var first := hud.get_node("Pacenote0") as TextureRect
	assert_true(first.visible, "first board visible as the current turn")
	hud.show_pacenotes(2)  # jump the current turn to the third note
	# Let the eased slide settle over several frames.
	for _i in range(40):
		await get_tree().process_frame
	assert_false(first.visible, "a passed board slides off the strip")
	var third := hud.get_node("Pacenote2") as TextureRect
	assert_true(third.visible, "the new current turn is on screen")


# --- Health gauge (features/damage.md) ----------------------------------
# The HUD reads the car's DamageModel each frame; these set it directly and await
# a frame, then assert the gauge (the same pattern as the speed/gear labels above).

func test_hp_gauge_tracks_working_hp() -> void:
	var car: VehicleBody3D = _scene.get_node("Car")
	var gauge := _scene.get_node("HUD/HPGauge") as HudGauge
	car.damage.field(1000.0, 1000.0)
	await get_tree().process_frame
	assert_true(gauge.visible, "gauge shown for a mortal car")
	assert_almost_eq(gauge.value, 1.0, 0.001, "full HP reads full")
	car.damage.hp = 250.0
	await get_tree().process_frame
	assert_almost_eq(gauge.value, 0.25, 0.001, "gauge reflects working HP / max_hp")


func test_hp_gauge_hidden_when_disabled() -> void:
	var car: VehicleBody3D = _scene.get_node("Car")
	var gauge := _scene.get_node("HUD/HPGauge") as HudGauge
	Config.data.hud_hp_enabled = false
	car.damage.field(1000.0, 1000.0)
	await get_tree().process_frame
	assert_false(gauge.visible, "gauge suppressed when hud_hp_enabled is off")
	Config.data.hud_hp_enabled = true


func test_finish_panel_next_button_is_keyboard_navigable() -> void:
	var hud: CanvasLayer = _scene.get_node("HUD")
	var next_btn: Button = hud.get_node("StageCompletePanel/Box/NextButton")
	assert_eq(next_btn.focus_mode, Control.FOCUS_ALL, "NEXT is focusable for keyboard/gamepad")
	hud.show_stage_complete(12.3)
	assert_true(hud.get_node("StageCompletePanel").visible, "finish panel is shown")
	await get_tree().process_frame  # deferred focus_grab lands
	assert_eq(hud.get_viewport().gui_get_focus_owner(), next_btn,
		"showing the finish panel focuses NEXT")
	var fired := [0]
	hud.finish_next_pressed.connect(func() -> void: fired[0] += 1)
	next_btn.emit_signal("pressed")
	assert_eq(fired[0], 1, "pressing NEXT emits finish_next_pressed")


# The gauge is labelled by an ICON, not text — the fill is the reading. Regression guard
# for a text caption creeping back in (it used to be a Label child that had to be kept
# from displaying the HP number).
func test_health_gauge_is_labelled_by_an_icon_not_text() -> void:
	var gauge := _scene.get_node("HUD/HPGauge") as HudGauge
	for child in gauge.get_children():
		assert_false(child is Label, "the gauge carries no text caption")
	assert_eq(gauge.icon, GaugeIcons.Kind.HEALTH, "it draws the health glyph")


# Grading the fill toward red at low HP must not drag the ICON's colour with it: the
# glyph is drawn in ink independently of the fill, so `modulate` (which would tint the
# whole node, icon included) has to stay neutral.
func test_health_grading_recolours_the_fill_only() -> void:
	var car: VehicleBody3D = _scene.get_node("Car")
	var gauge := _scene.get_node("HUD/HPGauge") as HudGauge
	var dmg: DamageModel = car.damage
	dmg.field(1000.0, 1000.0)
	await get_tree().process_frame
	var healthy: Color = gauge.fill_color
	dmg.hp = 50.0
	await get_tree().process_frame
	assert_ne(gauge.fill_color, healthy, "the fill grades with health")
	assert_eq(gauge.modulate, Color.WHITE, "grading goes through fill_color, sparing the icon")


# --- Boost gauge (features/forced-induction.md) --------------------------------
# Same shape as the health gauge: a dial whose fill IS the reading, with its icon in the
# middle. Shown only on a car with forced induction fitted.

func test_boost_gauge_hidden_on_a_naturally_aspirated_car() -> void:
	var hud: CanvasLayer = _scene.get_node("HUD")
	var gauge := hud.get_node("BoostGauge") as HudGauge
	# before_each leaves the car naturally aspirated.
	await get_tree().process_frame
	assert_false(gauge.visible, "an NA car shows no always-empty boost gauge")


func test_boost_gauge_is_labelled_by_its_own_icon() -> void:
	var hud: CanvasLayer = _scene.get_node("HUD")
	var gauge := hud.get_node("BoostGauge") as HudGauge
	assert_eq(gauge.icon, GaugeIcons.Kind.BOOST, "the boost dial draws the boost glyph")
	for child in gauge.get_children():
		assert_false(child is Label, "the gauge carries no text caption")


func test_boost_gauge_tracks_turbo_and_blower_boost() -> void:
	var car: VehicleBody3D = _scene.get_node("Car")
	var hud: CanvasLayer = _scene.get_node("HUD")
	var gauge := hud.get_node("BoostGauge") as HudGauge
	var engine: EngineSim = car.drivetrain.engine
	# Turbo fitted: the gauge appears and its fill follows the shaft's boost fraction.
	Config.data.turbo_enabled = true
	Config.data.supercharger_boost_gain = 0.0
	engine.boost = 0.5
	engine.sc_boost = 0.0
	await get_tree().process_frame
	assert_true(gauge.visible, "a fitted turbo reveals the boost gauge")
	assert_almost_eq(gauge.value, 0.5, 0.001, "the fill tracks turbo boost")
	# Blower fitted instead: the SAME gauge reports belt boost (they share a slot).
	Config.data.turbo_enabled = false
	Config.data.supercharger_boost_gain = 0.9
	engine.boost = 0.0
	engine.sc_boost = 0.75
	await get_tree().process_frame
	assert_true(gauge.visible, "a fitted supercharger reveals the same gauge")
	assert_almost_eq(gauge.value, 0.75, 0.001, "the fill tracks belt boost")


# --- Nitrous gauge (features/nitrous.md) ---------------------------------------
# The boost dial's twin: fill = tank fraction left, own icon, hidden when unfitted.

func test_nitrous_gauge_hidden_when_no_nitrous_is_fitted() -> void:
	var hud: CanvasLayer = _scene.get_node("HUD")
	var gauge := hud.get_node("NitrousGauge") as HudGauge
	# before_each leaves the car without a nitrous system.
	await get_tree().process_frame
	assert_false(gauge.visible, "an unfitted car shows no always-empty nitrous gauge")


func test_nitrous_gauge_tracks_the_tank_fraction() -> void:
	var car: VehicleBody3D = _scene.get_node("Car")
	var hud: CanvasLayer = _scene.get_node("HUD")
	var gauge := hud.get_node("NitrousGauge") as HudGauge
	var engine: EngineSim = car.drivetrain.engine
	# Fit a tank (values are this test's own inputs, not the shipped tune).
	Config.data.nitrous_boost_gain = 0.3
	Config.data.nitrous_tank_seconds = 4.0
	engine.nitrous_charge = 4.0
	await get_tree().process_frame
	assert_true(gauge.visible, "a fitted tank reveals the nitrous gauge")
	assert_almost_eq(gauge.value, 1.0, 0.001, "a full tank fills the gauge")
	# Drain half the tank: the fill follows the remaining fraction.
	engine.nitrous_charge = 2.0
	await get_tree().process_frame
	assert_almost_eq(gauge.value, 0.5, 0.001, "the fill tracks the remaining fraction")
	engine.nitrous_charge = 0.0
	await get_tree().process_frame
	assert_true(gauge.visible, "an empty tank still shows the (empty) gauge")
	assert_almost_eq(gauge.value, 0.0, 0.001, "a dry tank empties the gauge")


func test_nitrous_gauge_is_labelled_by_its_own_icon() -> void:
	var hud: CanvasLayer = _scene.get_node("HUD")
	var gauge := hud.get_node("NitrousGauge") as HudGauge
	assert_eq(gauge.icon, GaugeIcons.Kind.NOS, "the nitrous dial draws the NOS glyph")
	for child in gauge.get_children():
		assert_false(child is Label, "the gauge carries no text caption")


func test_nitrous_and_boost_gauges_are_visually_distinct() -> void:
	# Forced induction and nitrous are separate slots, so both gauges can be on screen at
	# once — their tints must not collide. Relationship, not a pinned hue value.
	var car: VehicleBody3D = _scene.get_node("Car")
	var hud: CanvasLayer = _scene.get_node("HUD")
	var boost := hud.get_node("BoostGauge") as HudGauge
	var nitrous := hud.get_node("NitrousGauge") as HudGauge
	var engine: EngineSim = car.drivetrain.engine
	Config.data.turbo_enabled = true
	Config.data.nitrous_boost_gain = 0.3
	Config.data.nitrous_tank_seconds = 4.0
	engine.boost = 0.5
	engine.nitrous_charge = 4.0
	await get_tree().process_frame
	assert_true(boost.visible and nitrous.visible, "a turbo + nitrous car shows both gauges")
	assert_ne(nitrous.fill_color, boost.fill_color, "the two gauges read as different colours")
	assert_ne(nitrous.icon, boost.icon, "and they carry different glyphs")


# Health sits BETWEEN the two flankers, so hiding one on a car that lacks the part
# leaves health where the eye already expects it. Ordering, not pinned coordinates.
func test_health_gauge_sits_between_its_two_flankers() -> void:
	var hud: CanvasLayer = _scene.get_node("HUD")
	var boost := hud.get_node("BoostGauge") as HudGauge
	var health := hud.get_node("HPGauge") as HudGauge
	var nitrous := hud.get_node("NitrousGauge") as HudGauge
	var bx: float = boost.position.x + boost.size.x * 0.5
	var hx: float = health.position.x + health.size.x * 0.5
	var nx: float = nitrous.position.x + nitrous.size.x * 0.5
	assert_lt(bx, hx, "boost sits to the left of health")
	assert_lt(hx, nx, "nitrous sits to the right of health")


func test_has_forced_induction_covers_both_parts() -> void:
	# The predicate lives on GameConfig, next to the fields whose encoding it interprets —
	# EngineSim gates the belt sim on it too, so it must not be a HUD-private rule.
	var cfg := GameConfig.new()
	assert_false(cfg.has_forced_induction(), "a bare config is naturally aspirated")
	cfg.turbo_enabled = true
	assert_true(cfg.has_forced_induction(), "a turbo counts")
	cfg.turbo_enabled = false
	cfg.supercharger_boost_gain = 0.5
	assert_true(cfg.has_forced_induction(), "a blower with real belt boost counts")
	assert_true(cfg.has_supercharger_physics(), "and its belt physics are live")
	cfg.supercharger_boost_gain = 0.0
	cfg.supercharger_enabled = true
	assert_false(cfg.has_forced_induction(),
		"an audio-only stock blower (no gain) does NOT — it makes no boost to show")
	assert_false(cfg.has_supercharger_physics(), "nor does it run the belt sim")


func test_elapsed_label_keeps_updating_as_the_clock_runs() -> void:
	# show_elapsed skips the re-format when the DISPLAYED value hasn't moved, so
	# check the skip can't latch: successive advancing times must each show.
	var hud := _scene.get_node("HUD")
	var label := _scene.get_node("HUD/ElapsedLabel") as Label
	Config.data.hud_elapsed_enabled = true
	hud.show_elapsed(1.0)
	var first := label.text
	hud.show_elapsed(1.0)
	assert_eq(label.text, first, "an unchanged reading shows the same text")
	hud.show_elapsed(2.0)
	assert_ne(label.text, first, "the timer still advances on the next reading")
	hud.show_elapsed(3.0)
	assert_eq(label.text, UITheme.format_time(3000), "and matches the formatted time")


# --- Dev difficulty readout (features/adaptive-difficulty.md) ------------------------
#
# The adaptive offset is silent by design — it moves the MACHINERY the rivals turn up in,
# so a harder field looks exactly like an ordinary field of quicker cars. The dev readout
# is the only way to tell the two apart. Pure text rule; no tuned value is pinned.


func test_a_matched_field_reads_as_matched() -> void:
	const Hud = preload("res://scripts/hud.gd")
	assert_eq(Hud.difficulty_text(0, 0.04, true), "AI matched",
		"zero steps is the no-op state and should say so, not 'x1.00'")


func test_the_readout_states_the_direction_and_the_multiplier() -> void:
	# The step COUNT alone means nothing without the fraction, so the multiplier that
	# actually reaches the matcher is what has to be on screen.
	const Hud = preload("res://scripts/hud.gd")
	var harder: String = Hud.difficulty_text(2, 0.04, true)
	var easier: String = Hud.difficulty_text(-2, 0.04, true)
	assert_string_contains(harder, "+2", "a positive offset is signed so its direction is plain")
	assert_string_contains(easier, "-2", "and so is a negative one")
	assert_ne(harder, easier, "the two directions must not render the same")
	# Harder means a field drawn ABOVE the player's rating, easier below.
	assert_string_contains(harder, "1.08")
	assert_string_contains(easier, "0.92")


func test_the_readout_says_when_adaptation_is_switched_off() -> void:
	# ai_adapt_enabled off restores the pre-adaptive behaviour exactly, so a stale step
	# count must not read as if it were still being applied.
	const Hud = preload("res://scripts/hud.gd")
	assert_eq(Hud.difficulty_text(3, 0.04, false), "AI off",
		"a disabled system reports off, whatever offset the profile still carries")
