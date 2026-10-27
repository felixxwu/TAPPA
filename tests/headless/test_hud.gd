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
	assert_true(Config.data.hud_enabled, "default config keeps the HUD on")
	assert_true(_scene.get_node("HUD").visible, "HUD visible when hud_enabled")


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
	# The build version now lives on the title screen only (see test_hq.gd); the
	# in-run HUD must not carry it.
	assert_null(_scene.get_node_or_null("HUD/VersionLabel"),
		"driving HUD no longer shows the build version")


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
# Same shape as the health gauge: a strip whose fill IS the reading, with its icon under
# it. Shown only on a car with forced induction fitted.

func test_boost_gauge_hidden_on_a_naturally_aspirated_car() -> void:
	var hud: CanvasLayer = _scene.get_node("HUD")
	var gauge := hud.get_node("BoostGauge") as HudGauge
	# before_each leaves the car naturally aspirated.
	await get_tree().process_frame
	assert_false(gauge.visible, "an NA car shows no always-empty boost gauge")


func test_boost_gauge_is_labelled_by_its_own_icon() -> void:
	var hud: CanvasLayer = _scene.get_node("HUD")
	var gauge := hud.get_node("BoostGauge") as HudGauge
	assert_eq(gauge.icon, GaugeIcons.Kind.BOOST, "the boost gauge draws the boost glyph")
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
# The boost gauge's twin: fill = tank fraction left, own icon, hidden when unfitted.

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
	assert_eq(gauge.icon, GaugeIcons.Kind.NOS, "the nitrous gauge draws the NOS glyph")
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


# The gauges sit in one row, health first, and a part that isn't fitted closes up
# instead of leaving a hole. Ordering and adjacency, not pinned coordinates.
func test_gauges_form_a_gapless_row_with_health_first() -> void:
	var car: VehicleBody3D = _scene.get_node("Car")
	var hud: CanvasLayer = _scene.get_node("HUD")
	var boost := hud.get_node("BoostGauge") as HudGauge
	var health := hud.get_node("HPGauge") as HudGauge
	var nitrous := hud.get_node("NitrousGauge") as HudGauge
	var engine: EngineSim = car.drivetrain.engine
	Config.data.turbo_enabled = true
	Config.data.nitrous_boost_gain = 0.3
	Config.data.nitrous_tank_seconds = 4.0
	engine.nitrous_charge = 4.0
	await get_tree().process_frame
	assert_almost_eq(health.position.x + health.size.x, boost.position.x, 0.01, "boost follows health")
	assert_almost_eq(boost.position.x + boost.size.x, nitrous.position.x, 0.01, "nitrous follows boost")
	Config.data.turbo_enabled = false
	await get_tree().process_frame
	assert_false(boost.visible, "no turbo, no boost gauge")
	assert_almost_eq(health.position.x + health.size.x, nitrous.position.x, 0.01,
		"nitrous closes up against health when boost is gone")


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
