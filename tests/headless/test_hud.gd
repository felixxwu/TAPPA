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
	cfg.hud_stage_delta_enabled = true
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
	var engine: EngineSim = car.drivetrain.engine
	engine.auto = true
	engine.gear = 1
	engine.boost = 0.0
	engine.sc_boost = 0.0
	car.damage.field(1000.0, 1000.0)  # a healthy, mortal car
	# Force the diagnostic readout + stage widgets back to hidden (tests show them).
	var hud = _scene.get_node("HUD")
	hud.hide_countdown()
	for w in ["StageCompletePanel", "StageDeltaLabel", "CutFlashLabel"]:
		var node := hud.get_node_or_null(w)
		if node != null:
			node.visible = false
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


func test_speed_gear_rpm_hidden_until_h_toggle() -> void:
	# The speed / gear / rpm readout is a dev diagnostic: hidden on startup, shown
	# and hidden again by the H toggle (same gate as the debug force arrows).
	var speed := _scene.get_node("HUD/SpeedLabel") as Label
	var gear := _scene.get_node("HUD/GearLabel") as Label
	var rpm := _scene.get_node("HUD/RPMLabel") as Label
	var boost := _scene.get_node("HUD/BoostLabel") as Label
	var seed_label := _scene.get_node("HUD/SeedLabel") as Label
	await get_tree().process_frame
	assert_false(speed.visible, "speed hidden on startup")
	assert_false(gear.visible, "gear hidden on startup")
	assert_false(rpm.visible, "rpm hidden on startup")
	assert_false(boost.visible, "boost hidden on startup")
	assert_false(seed_label.visible, "seed hidden on startup")
	Input.action_press("toggle_debug_arrows")
	await get_tree().process_frame
	await get_tree().process_frame
	Input.action_release("toggle_debug_arrows")
	assert_true(speed.visible, "H shows the speed readout")
	assert_true(gear.visible, "H shows the gear readout")
	assert_true(rpm.visible, "H shows the rpm readout")
	assert_true(boost.visible, "H shows the boost readout")
	assert_true(seed_label.visible, "H shows the seed readout")
	assert_eq(seed_label.text, "Seed %d" % Config.data.track_seed,
		"seed readout shows the current track seed")
	Input.action_press("toggle_debug_arrows")
	await get_tree().process_frame
	await get_tree().process_frame
	Input.action_release("toggle_debug_arrows")
	assert_false(speed.visible, "H again hides the readout")
	assert_false(boost.visible, "H again hides the boost readout")
	assert_false(seed_label.visible, "H again hides the seed readout")


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


# --- "vs P1" pace popup (todo/stage-start-and-end.md) ------------------------

func test_stage_delta_popup_ahead_is_green_and_labelled() -> void:
	var hud := _scene.get_node("HUD")
	var label := _scene.get_node("HUD/StageDeltaLabel") as Label
	assert_not_null(label, "HUD builds the pace-popup label")
	assert_false(label.visible, "popup hidden until pulsed")
	Config.data.hud_stage_delta_enabled = true
	hud.show_stage_delta(-1340)  # 1.34 s ahead
	assert_true(label.visible, "popup shown when pulsed")
	assert_string_contains(label.text, "1.34", "ahead reads the gap magnitude")
	assert_string_contains(label.text, "ahead of P1", "ahead spells out the relation")
	assert_eq(label.get_theme_color("font_color"), UITheme.GREEN, "ahead is green")


func test_stage_delta_popup_behind_is_red_and_labelled() -> void:
	var hud := _scene.get_node("HUD")
	var label := _scene.get_node("HUD/StageDeltaLabel") as Label
	Config.data.hud_stage_delta_enabled = true
	hud.show_stage_delta(2100)  # 2.1 s behind
	assert_true(label.visible, "popup shown when pulsed")
	assert_string_contains(label.text, "2.10", "behind reads the gap magnitude")
	assert_string_contains(label.text, "behind P1", "behind spells out the relation")
	assert_eq(label.get_theme_color("font_color"), UITheme.RED, "behind is red")


func test_stage_delta_popup_respects_config() -> void:
	var hud := _scene.get_node("HUD")
	var label := _scene.get_node("HUD/StageDeltaLabel") as Label
	label.visible = false
	Config.data.hud_stage_delta_enabled = false
	hud.show_stage_delta(-500)
	assert_false(label.visible, "popup suppressed when hud_stage_delta_enabled is off")
	Config.data.hud_stage_delta_enabled = true


func test_cut_flash_takes_precedence_over_stage_delta() -> void:
	var hud := _scene.get_node("HUD")
	var delta_label := _scene.get_node("HUD/StageDeltaLabel") as Label
	var cut_label := _scene.get_node("HUD/CutFlashLabel") as Label
	Config.data.hud_stage_delta_enabled = true
	Config.data.cut_penalty_enabled = true
	# A live cut flash hides any showing pace popup...
	hud.show_stage_delta(-1340)
	assert_true(delta_label.visible, "pace popup shown before the cut")
	hud.show_cut_flash(1.0, 2.0)
	assert_true(cut_label.visible, "cut flash shown")
	assert_false(delta_label.visible, "cut flash hides the pace popup")
	# ...and a pace pulse while the cut flash is up is suppressed.
	hud.show_stage_delta(-1340)
	assert_false(delta_label.visible, "pace popup suppressed while cut flash is on screen")


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


# --- HP gauge (features/damage.md) --------------------------------------
# The HUD reads the car's DamageModel each frame; these set it directly and await
# a frame, then assert the bar (the same pattern as the speed/gear labels above).

func test_hp_gauge_tracks_working_hp() -> void:
	var car: VehicleBody3D = _scene.get_node("Car")
	var bar := _scene.get_node("HUD/HPBar") as ProgressBar
	car.damage.field(1000.0, 1000.0)
	await get_tree().process_frame
	assert_true(bar.visible, "gauge shown for a mortal car")
	assert_almost_eq(bar.value, 1.0, 0.001, "full HP reads full")
	car.damage.hp = 250.0
	await get_tree().process_frame
	assert_almost_eq(bar.value, 0.25, 0.001, "gauge reflects working HP / max_hp")


func test_hp_gauge_hidden_when_disabled() -> void:
	var car: VehicleBody3D = _scene.get_node("Car")
	var bar := _scene.get_node("HUD/HPBar") as ProgressBar
	Config.data.hud_hp_enabled = false
	car.damage.field(1000.0, 1000.0)
	await get_tree().process_frame
	assert_false(bar.visible, "gauge suppressed when hud_hp_enabled is off")
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


# The caption lives INSIDE the bar and carries no number — the fill is the reading.
# Regression guard for the label drifting back out of the bar or regrowing a value.
func test_health_caption_sits_inside_the_bar_and_carries_no_number() -> void:
	var car: VehicleBody3D = _scene.get_node("Car")
	var hud: CanvasLayer = _scene.get_node("HUD")
	var bar := hud.get_node("HPBar") as ProgressBar
	var label := hud.get_node("HPBar/HPLabel") as Label
	assert_eq(label.get_parent(), bar, "the caption is a child of the bar, not a sibling above it")
	var dmg: DamageModel = car.damage
	dmg.field(1000.0, 1000.0)
	await get_tree().process_frame
	var full_text := label.text
	dmg.hp = 0.4  # a sliver of HP: the caption must not react to the value at all
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(label.text, full_text, "the caption is static — it holds no HP number")
	assert_false(label.text.strip_edges().is_empty(), "but it still names the gauge")


# The bar is tinted with self_modulate, NOT modulate, so grading the fill toward red
# at low HP can't drag the caption's colour along with it and hurt legibility.
func test_health_grading_does_not_tint_the_caption() -> void:
	var car: VehicleBody3D = _scene.get_node("Car")
	var hud: CanvasLayer = _scene.get_node("HUD")
	var bar := hud.get_node("HPBar") as ProgressBar
	var dmg: DamageModel = car.damage
	dmg.field(1000.0, 1000.0)
	await get_tree().process_frame
	var healthy: Color = bar.self_modulate
	dmg.hp = 50.0
	await get_tree().process_frame
	assert_ne(bar.self_modulate, healthy, "the fill grades with health")
	assert_eq(bar.modulate, Color.WHITE, "grading goes through self_modulate, sparing the child caption")


# --- Boost gauge (features/forced-induction.md) --------------------------------
# Same shape as the HP gauge: a bar whose fill IS the reading, with a static caption
# inside it. Shown only on a car with forced induction fitted.

func test_boost_gauge_hidden_on_a_naturally_aspirated_car() -> void:
	var hud: CanvasLayer = _scene.get_node("HUD")
	var bar := hud.get_node("BoostBar") as ProgressBar
	# before_each leaves the car naturally aspirated.
	await get_tree().process_frame
	assert_false(bar.visible, "an NA car shows no always-empty boost bar")


func test_boost_gauge_caption_sits_inside_the_bar() -> void:
	var hud: CanvasLayer = _scene.get_node("HUD")
	var bar := hud.get_node("BoostBar") as ProgressBar
	var label := hud.get_node("BoostBar/BoostLabel") as Label
	assert_eq(label.get_parent(), bar, "the caption is a child of the bar")
	assert_false(label.text.strip_edges().is_empty(), "and it names the gauge")


func test_boost_gauge_tracks_turbo_and_blower_boost() -> void:
	var car: VehicleBody3D = _scene.get_node("Car")
	var hud: CanvasLayer = _scene.get_node("HUD")
	var bar := hud.get_node("BoostBar") as ProgressBar
	var engine: EngineSim = car.drivetrain.engine
	# Turbo fitted: the bar appears and its fill follows the shaft's boost fraction.
	Config.data.turbo_enabled = true
	Config.data.supercharger_boost_gain = 0.0
	engine.boost = 0.5
	engine.sc_boost = 0.0
	await get_tree().process_frame
	assert_true(bar.visible, "a fitted turbo reveals the boost bar")
	assert_almost_eq(bar.value, 0.5, 0.001, "the fill tracks turbo boost")
	# Blower fitted instead: the SAME bar reports belt boost (they share a slot).
	Config.data.turbo_enabled = false
	Config.data.supercharger_boost_gain = 0.9
	engine.boost = 0.0
	engine.sc_boost = 0.75
	await get_tree().process_frame
	assert_true(bar.visible, "a fitted supercharger reveals the same bar")
	assert_almost_eq(bar.value, 0.75, 0.001, "the fill tracks belt boost")


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


# The captions sit ON the coloured fill, so they opt OUT of the house drop shadow (the
# one documented exception — features/ui-design-system.md). The shadow comes from the
# PROJECT-WIDE theme, not a per-label property, so overriding font_color alone leaves it
# in place; this guards the override that actually switches it off.
func test_gauge_captions_have_no_drop_shadow() -> void:
	var hud: CanvasLayer = _scene.get_node("HUD")
	for path in ["HPBar/HPLabel", "BoostBar/BoostLabel"]:
		var cap := hud.get_node(path) as Label
		assert_eq(cap.get_theme_color("font_shadow_color").a, 0.0,
			"%s draws no drop shadow" % path)


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
