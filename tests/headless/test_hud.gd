extends GutTest
# HUD speed readout: shows the car's airspeed (chassis velocity magnitude)
# in km/h, gated by the hud_enabled config flag.

var _scene: Node3D


func before_all() -> void:
	# Built ONCE for the whole script. The HUD is driven by the car's state + config flags
	# each frame; before_each restores those to a clean baseline so the shared instance is
	# order-safe.
	Config.reset()
	_scene = await SceneTestHelpers.add_level_world(self)


func after_all() -> void:
	_scene.free()
	SceneTestHelpers.remove_level_world()
	Config.reset()



func before_each() -> void:
	# Reset the shared scene to a clean baseline: the HUD reads the car (speed / gear /
	# rpm / HP) and several config flags every frame, and individual tests inject
	# velocity / engine state / damage, toggle the debug readout, and flip HUD config
	# flags — undo all of that so no test leaks state into the next.
	get_tree().paused = false
	var cfg: GameConfig = Config.data
	cfg.hud_enabled = true
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
	await get_tree().process_frame


func test_hud_visible_when_enabled() -> void:
	assert_eq(_scene.get_node("HUD").visible, Config.data.hud_enabled, "the HUD follows hud_enabled")


# A paused page (pause menu, rest stop, map, stats) covers the HUD: its gauges go transparent
# (alpha, not `visible`, so photo mode / hud_enabled stay in charge of visibility) and return
# when the tree resumes.
func test_hud_content_hides_while_the_tree_is_paused() -> void:
	var hud: CanvasLayer = _scene.get_node("HUD")
	var controls: Array = hud.get_children().filter(func(c): return c is Control)
	assert_false(controls.is_empty(), "setup: the HUD has Control children")
	get_tree().paused = true
	await get_tree().process_frame
	await get_tree().process_frame
	for c in controls:
		assert_eq((c as Control).modulate.a, 0.0, "%s is transparent while paused" % c.name)
	assert_true(hud.visible, "the layer's own visibility is untouched")
	get_tree().paused = false
	await get_tree().process_frame
	await get_tree().process_frame
	for c in controls:
		assert_eq((c as Control).modulate.a, 1.0, "%s is back after resume" % c.name)


func test_hud_hidden_when_disabled() -> void:
	var cfg: GameConfig = Config.data
	cfg.hud_enabled = false
	var scene := await SceneTestHelpers.add_level_world(self)
	cfg.hud_enabled = true
	autofree(scene)
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


# --- Grip readout --------------------------------------------------------------

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
	assert_null(_scene.get_node_or_null("HUD/VersionLabel"),
		"driving HUD no longer shows the build version")


# --- Gauge cluster dial (features/hud.md) -------------------------------
# The HUD reads the car each frame and writes the readings onto one HudDial; these set
# the car's state directly, await a frame, then assert the dial's readings.

func _dial() -> HudDial:
	return _scene.get_node("HUD/Dial") as HudDial


func test_dial_sits_in_the_bottom_right_corner() -> void:
	var dial := _dial()
	var screen := dial.get_viewport_rect().size
	var rect := dial.get_global_rect()
	assert_true(rect.end.x <= screen.x and rect.end.x > screen.x * 0.75, "hugs the right edge")
	assert_true(rect.end.y <= screen.y and rect.end.y > screen.y * 0.75, "hugs the bottom edge")
	assert_eq(dial.mouse_filter, Control.MOUSE_FILTER_IGNORE, "never swallows a tap meant for the touch controls")


func test_dial_tracks_rpm_and_gear() -> void:
	var car: VehicleBody3D = _scene.get_node("Car")
	var engine: EngineSim = car.drivetrain.engine
	engine.gear = -1
	await get_tree().process_frame
	assert_eq(_dial().gear_text, "R", "reverse reads R")
	# The engine keeps ticking between the HUD frame and this read, so allow a little drift.
	assert_almost_eq(_dial().rpm, engine.rpm(), maxf(engine.rpm() * 0.05, 50.0), "the needle follows the engine")
	assert_true(_dial().scale_rpm > Config.data.redline_rpm, "the scale runs past the redline")


func test_scale_leaves_room_past_any_redline() -> void:
	for redline in [4000.0, 6500.0, 7000.0, 9300.0]:
		var top := HudDial.scale_for(redline)
		assert_true(top >= redline + 1000.0, "at least 1000 rpm of red zone past %d" % redline)
		assert_eq(fmod(top, 1000.0), 0.0, "ends on a whole thousand")


func test_health_rim_tracks_working_hp() -> void:
	var car: VehicleBody3D = _scene.get_node("Car")
	car.damage.field(1000.0, 1000.0)
	await get_tree().process_frame
	assert_almost_eq(_dial().hp, 1.0, 0.001, "full HP reads full")
	car.damage.hp = 250.0
	await get_tree().process_frame
	assert_almost_eq(_dial().hp, 0.25, 0.001, "the rim reflects working HP / max_hp")


func test_health_rim_hidden_when_disabled() -> void:
	Config.data.hud_hp_enabled = false
	await get_tree().process_frame
	assert_true(_dial().hp < 0.0, "no health rim when hud_hp_enabled is off")


func test_health_grading_recolours_the_rim_only() -> void:
	var car: VehicleBody3D = _scene.get_node("Car")
	await get_tree().process_frame
	var healthy: Color = _dial().hp_color
	car.damage.hp = 50.0
	await get_tree().process_frame
	assert_ne(_dial().hp_color, healthy, "the rim grades with health")
	assert_eq(_dial().modulate, Color.WHITE, "grading spares the rest of the dial")


func test_boost_hidden_on_a_naturally_aspirated_car() -> void:
	await get_tree().process_frame
	assert_true(_dial().boost < 0.0, "an NA car shows no always-empty boost arc")


func test_boost_tracks_turbo_and_blower_boost() -> void:
	var car: VehicleBody3D = _scene.get_node("Car")
	var engine: EngineSim = car.drivetrain.engine
	Config.data.turbo_enabled = true
	engine.boost = 0.5
	await get_tree().process_frame
	assert_almost_eq(_dial().boost, 0.5, 0.001, "the arc tracks turbo boost")
	# A blower shares the turbo's upgrade slot, so it reports through the same arc.
	Config.data.turbo_enabled = false
	Config.data.supercharger_boost_gain = 0.9
	engine.boost = 0.0
	engine.sc_boost = 0.75
	await get_tree().process_frame
	assert_almost_eq(_dial().boost, 0.75, 0.001, "the arc tracks belt boost")


func test_nitrous_hidden_when_no_nitrous_is_fitted() -> void:
	await get_tree().process_frame
	assert_true(_dial().nitrous < 0.0, "an unfitted car shows no nitrous pips")


func test_nitrous_tracks_the_tank_fraction() -> void:
	var car: VehicleBody3D = _scene.get_node("Car")
	var engine: EngineSim = car.drivetrain.engine
	Config.data.nitrous_boost_gain = 0.3
	Config.data.nitrous_tank_seconds = 4.0
	engine.nitrous_charge = 2.0
	await get_tree().process_frame
	assert_almost_eq(_dial().nitrous, 0.5, 0.001, "the pips track the remaining fraction")
	engine.nitrous_charge = 0.0
	await get_tree().process_frame
	assert_almost_eq(_dial().nitrous, 0.0, 0.001, "an empty tank still shows (dark) pips")


func test_nitrous_and_boost_are_visually_distinct() -> void:
	await get_tree().process_frame
	assert_ne(_dial().nitrous_color, _dial().boost_color,
		"turbo and nitrous can show together, so they must not share a colour")


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
