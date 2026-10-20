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


# Free roam has no free-fly photo camera host, so the Photo Mode card is left out, and the
# keyboard/gamepad cursor walks straight from Reset to road to Map.
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
