extends GutTest
# The free-roam playable shell (features/free-roam.md → "The shell"): the stage HUD, touch
# controls and pause menu wired onto the streamed island, plus road recovery. The scene is built
# ONCE on a small synthetic island; every test closes the pause menu so the shared instance is
# order-safe.

const TEST_PATH := "user://test_free_roam_shell_profile.json"

var _scene: Node3D
var _pause: PauseMenu
var _car: VehicleBody3D
var _streamer: TerrainStreamer
var _recovery: RoadRecovery
var _save: Node


func before_all() -> void:
	_save = get_node("/root/Save")
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.load_or_new()
	_scene = load("res://free_roam.tscn").instantiate()
	var s := FreeRoamSettings.new()
	s.world_seed = 7
	s.island_radius_m = 3000.0
	s.near_radius = 1
	s.far_radius = 3
	(_scene.get_node("Terrain") as TerrainStreamer).settings = s
	add_child(_scene)
	await get_tree().physics_frame
	_pause = _scene.get_node("PauseMenu")
	_car = _scene.get_node("Car")
	_streamer = _scene.get_node("Terrain")
	_recovery = _scene.get_node("RoadRecovery")


func after_all() -> void:
	get_tree().paused = false
	_scene.free()
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


func after_each() -> void:
	_pause.resume()


func _press(action: String) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = action
	e.pressed = true
	return e


func _off_road_point() -> Vector2:
	# Walk out from the car until the nearest road is well away, on loaded ground.
	var p := Vector2(_car.global_position.x, _car.global_position.z)
	for r in range(20, 200, 10):
		for a in 8:
			var q := p + Vector2.from_angle(a * PI / 4.0) * r
			if not _streamer.network.nearest(q.x, q.y, 25.0) and _streamer.has_collision_at(q.x, q.y):
				return q
	return p + Vector2(60, 0)


func test_the_shell_wires_the_hud_controls_and_pause_menu() -> void:
	assert_eq(_scene.get_node("HUD").get("car"), _car, "the HUD reads the car")
	assert_true(_scene.get_node("MobileControls") is MobileControls)
	assert_eq(_pause.mobile_controls, _scene.get_node("MobileControls"))
	assert_eq(_pause.camera_manager, _scene.get_node("CameraManager"))
	assert_true(_pause._input_enabled, "the pause menu is armed once the island has loaded")


func test_the_debug_readout_starts_hidden_and_p_toggles_it() -> void:
	var stats: CanvasLayer = _scene.get_node("DebugStats")
	assert_false(stats.visible, "hidden by default")
	var press := InputEventAction.new()
	press.action = "toggle_perf_overlay"
	press.pressed = true
	_scene._unhandled_input(press)
	assert_true(stats.visible, "P shows it, in release builds too")
	_scene._unhandled_input(press)
	assert_false(stats.visible, "P again hides it")


func test_frame_headroom_is_the_share_of_the_budget_the_busier_side_leaves() -> void:
	var fr := preload("res://scripts/free_roam/free_roam.gd")
	assert_almost_eq(fr.frame_headroom(20.0, 5.0, 0.0), 0.75, 0.001, "cpu-bound")
	assert_almost_eq(fr.frame_headroom(20.0, 5.0, 15.0), 0.25, 0.001, "the gpu, when busier, sets it")
	assert_lt(fr.frame_headroom(10.0, 15.0, 0.0), 0.0, "over budget goes negative")
	assert_true(_scene._headroom_line().begins_with("frame"), "the readout carries the line")


# The wheel debris is made for free roam just as world.gd makes it for a stage, and reads the
# same terrain the tyres do (the streamer), so grass and gravel spray where the grip changes.
func test_the_wheel_debris_follows_the_car_and_reads_the_streamers_surface() -> void:
	var wp := _scene.get_node_or_null("WheelParticles") as WheelParticles
	assert_not_null(wp, "free roam has wheel particles")
	assert_eq(wp._car, _car, "wired to the car")
	assert_gt(wp.max_particles(), 0, "its pool is built")
	assert_eq(_car.drivetrain.terrain, _streamer, "the surface it reads is the streamer's")
	assert_eq(_scene.get_node("BiomeDirector").wheel_particles, wp, "the biome director re-seats its look per ring")


# Free roam has no free-fly photo camera host, so the Photo Mode card is left out, and the
# keyboard/gamepad cursor walks straight from Reset to road to Map.
func test_the_title_menu_covers_the_paused_world_and_continue_closes_it() -> void:
	WorldSession.fresh = false
	var title: TitleScreen = _scene.show_title()
	await get_tree().process_frame
	await get_tree().process_frame
	assert_true(get_tree().paused, "the world waits behind the title")
	var orbit: Camera3D = _scene.get_node("TitleOrbitCamera")
	assert_true(orbit.current, "a camera circles the car behind the title")
	var p := orbit.global_position
	assert_gt(p.y, _streamer.height_at(p.x, p.z), "the orbit camera is above the ground")
	assert_true(CardUI.pick(title.cards(), "Continue"))
	await get_tree().process_frame
	assert_false(get_tree().paused, "Continue drops straight into driving")
	assert_null(_scene.get_node_or_null("TitleLayer"), "the menu is gone")
	assert_null(_scene.get_node_or_null("TitleOrbitCamera"), "and its camera")


func test_the_pause_menu_leaves_out_the_photo_card() -> void:
	var cards := _pause.cards()
	assert_eq(CardUI.index_of(cards, "Photo Mode"), -1)
	var nav := MenuNav.of(_pause._overlay)
	await get_tree().process_frame
	nav.forget()
	_pause.open()
	await get_tree().process_frame
	assert_eq(_pause.get_viewport().gui_get_focus_owner(), cards)
	var titles := CardUI.titles(cards)
	cards.select(0, false)
	nav._unhandled_input(_press("menu_right"))
	assert_eq(titles[cards.selected_index()], "Reset to road")
	nav._unhandled_input(_press("menu_right"))
	assert_eq(titles[cards.selected_index()], "Map", "Photo Mode is not offered, on to Map")
	nav._unhandled_input(_press("menu_left"))
	assert_eq(titles[cards.selected_index()], "Reset to road")
	_pause.resume()


func test_reset_to_road_puts_the_car_on_the_nearest_road() -> void:
	var p := _off_road_point()
	_car.reset_to(Transform3D(Basis.IDENTITY, Vector3(p.x, _streamer.height_at(p.x, p.y) + 1.0, p.y)))
	await get_tree().physics_frame
	await get_tree().physics_frame
	_pause.open()
	_pause._on_reset_to_track_pressed()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var c := _car.global_position
	assert_true(_streamer.network.nearest(c.x, c.z, 2.0), "the car is back on a road")
	assert_false(get_tree().paused)


func test_a_flipped_stationary_car_is_recovered_after_the_timeout() -> void:
	var cfg: GameConfig = Config.data
	var pos := _car.global_position
	_car.reset_to(Transform3D(Basis(Vector3.FORWARD, PI), pos + Vector3.UP))  # upside down
	await get_tree().physics_frame
	await get_tree().physics_frame
	_car.linear_velocity = Vector3.ZERO
	_recovery._stuck_time = 0.0
	assert_false(_recovery.is_stuck_step(cfg.recovery_timeout_s * 0.5), "not before the timeout")
	assert_true(_recovery.is_stuck_step(cfg.recovery_timeout_s * 0.6), "stuck once the timeout passes")


func test_a_moving_car_is_never_stuck() -> void:
	var cfg: GameConfig = Config.data
	_recovery._stuck_time = 0.0
	_car.linear_velocity = Vector3(0, 0, -(cfg.recovery_speed_mps + 5.0))
	assert_false(_recovery.is_stuck_step(cfg.recovery_timeout_s * 2.0))


func test_the_engine_smoke_and_exhaust_flames_follow_the_car() -> void:
	var smoke := _scene.get_node_or_null("EngineSmoke")
	var flames := _scene.get_node_or_null("ExhaustFlames")
	assert_true(smoke is EngineSmoke, "smoke from a misfiring (overheating) engine")
	assert_true(flames is ExhaustFlames, "backfire flames from the exhausts")


# Gravel ruts behind the wheels: free roam has no centreline, so the marks run ungated off the
# streamer's own surface answer; and a teleport (travel / respawn / reset) breaks every ribbon
# rather than bridging it from the old spot to the new one.
func test_tyre_marks_run_off_the_streamer_and_a_teleport_breaks_them() -> void:
	var marks := _scene.get_node_or_null("TireMarks") as TireMarks
	assert_not_null(marks, "free roam lays tyre marks")
	assert_true(marks._ungated, "with no centreline, the surface alone decides")
	assert_eq(marks._terrain, _scene.get_node("Terrain"), "the streamer is the surface it reads")
	for i in marks._last_pos.size():
		marks._last_pos[i] = Vector2(1.0, 2.0)
	(_scene.get_node("RoadRecovery") as RoadRecovery).reset_done.emit(Vector2.ZERO)
	for i in marks._last_pos.size():
		assert_null(marks._last_pos[i], "wheel %d's ribbon is broken by the reset" % i)
