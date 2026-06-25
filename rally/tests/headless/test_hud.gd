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


func test_version_label_shows_project_version() -> void:
	# build_web.sh stamps application/config/version (0.<commits> + SHA) into the
	# export; the HUD mirrors it with a "v" prefix. In editor/test runs it reads
	# the project default ("0.0-dev").
	var label := _scene.get_node("HUD/VersionLabel") as Label
	assert_not_null(label, "HUD has a version label")
	var ver := str(ProjectSettings.get_setting("application/config/version", ""))
	assert_ne(ver, "", "project.godot defines application/config/version")
	assert_eq(label.text, "v" + ver, "version label mirrors application/config/version")


func test_mode_button_toggles_gearbox() -> void:
	var car: VehicleBody3D = _scene.get_node("Car")
	var engine: EngineSim = car.drivetrain.engine
	var button := _scene.get_node("HUD/ModeButton") as Button
	assert_eq(button.focus_mode, Control.FOCUS_NONE,
		"mode button must not grab keyboard focus (would steal the handbrake key)")
	var was := engine.auto
	button.pressed.emit()
	await get_tree().process_frame
	assert_ne(engine.auto, was, "clicking the mode button toggles auto/manual")
	assert_eq(button.text, "AUTO" if engine.auto else "MANUAL", "button text reflects the mode")


func test_drive_button_cycles_layout() -> void:
	var car: VehicleBody3D = _scene.get_node("Car")
	var dt: Drivetrain = car.drivetrain
	var button := _scene.get_node("HUD/DriveButton") as Button
	assert_eq(button.focus_mode, Control.FOCUS_NONE,
		"drive button must not grab keyboard focus")
	dt.drive_mode = Drivetrain.DriveMode.RWD
	await get_tree().process_frame
	assert_eq(button.text, "RWD", "button shows the current layout")
	button.pressed.emit()
	await get_tree().process_frame
	assert_eq(dt.drive_mode, Drivetrain.DriveMode.AWD, "clicking cycles RWD -> AWD")
	assert_eq(button.text, "AWD", "button text follows the layout")


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
