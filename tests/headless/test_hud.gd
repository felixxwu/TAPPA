extends GutTest
# HUD speed readout: shows the car's airspeed (chassis velocity magnitude)
# in km/h, gated by the hud_enabled config flag.

const SceneHelpers = preload("res://tests/headless/scene_helpers.gd")

var _scene: Node3D


func before_each() -> void:
	# The HUD tests don't care about the track or its foliage — minimal_world()
	# boots main.tscn with a 1-turn track and no trees, ~15s -> <1s per instance.
	SceneHelpers.minimal_world()
	_scene = load("res://main.tscn").instantiate()
	add_child_autofree(_scene)


func after_each() -> void:
	# minimal_world() left Config on a 1-turn / no-foliage track; restore the
	# authored baseline so later files that don't reset Config (e.g.
	# test_loading_screen) still generate the full world they expect.
	Config.reset()


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


func test_hud_has_no_version_label() -> void:
	# The build version now lives on the title screen only (see test_hq.gd); the
	# in-run HUD must not carry it.
	assert_null(_scene.get_node_or_null("HUD/VersionLabel"),
		"driving HUD no longer shows the build version")


func test_elapsed_timer_anchored_top_centre() -> void:
	# The run timer sits at the top middle of the screen (centre anchors), not the
	# old top-right corner.
	var label := _scene.get_node("HUD/ElapsedLabel") as Label
	assert_not_null(label, "HUD has the run timer")
	assert_almost_eq(label.anchor_left, 0.5, 0.001, "timer anchored to horizontal centre")
	assert_almost_eq(label.anchor_right, 0.5, 0.001, "timer anchored to horizontal centre")
	assert_eq(label.horizontal_alignment, HORIZONTAL_ALIGNMENT_CENTER,
		"timer text is centre-aligned")


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
	var label := _scene.get_node("HUD/StageCompletePanel/StageCompleteLabel") as Label
	assert_false(panel.visible, "complete panel hidden until the stage ends")
	hud.show_stage_complete(67.43)
	assert_true(panel.visible, "complete panel shown on stage completion")
	assert_string_contains(label.text, "1:07.43", "panel shows the final time")


# --- "vs P1" pace popup (todo/stage-start-and-end.md) ------------------------

func test_stage_delta_popup_ahead_is_green_and_signed() -> void:
	var hud := _scene.get_node("HUD")
	var label := _scene.get_node("HUD/StageDeltaLabel") as Label
	assert_not_null(label, "HUD builds the pace-popup label")
	assert_false(label.visible, "popup hidden until pulsed")
	Config.data.hud_stage_delta_enabled = true
	hud.show_stage_delta(-1340)  # 1.34 s ahead
	assert_true(label.visible, "popup shown when pulsed")
	assert_string_contains(label.text, "-1.3", "ahead reads with a minus sign")
	assert_eq(label.get_theme_color("font_color"), UITheme.GREEN, "ahead is green")


func test_stage_delta_popup_behind_is_red_and_signed() -> void:
	var hud := _scene.get_node("HUD")
	var label := _scene.get_node("HUD/StageDeltaLabel") as Label
	Config.data.hud_stage_delta_enabled = true
	hud.show_stage_delta(2100)  # 2.1 s behind
	assert_true(label.visible, "popup shown when pulsed")
	assert_string_contains(label.text, "+2.1", "behind reads with a plus sign")
	assert_eq(label.get_theme_color("font_color"), UITheme.RED, "behind is red")


func test_stage_delta_popup_respects_config() -> void:
	var hud := _scene.get_node("HUD")
	var label := _scene.get_node("HUD/StageDeltaLabel") as Label
	label.visible = false
	Config.data.hud_stage_delta_enabled = false
	hud.show_stage_delta(-500)
	assert_false(label.visible, "popup suppressed when hud_stage_delta_enabled is off")
	Config.data.hud_stage_delta_enabled = true


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
