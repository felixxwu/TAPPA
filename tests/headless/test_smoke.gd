extends GutTest

# The gameplay/menu actions, taken from InputRemap (the single source of truth for
# the rebindable set — see scripts/input_remap.gd) rather than hand-copied here, so
# adding an action there automatically brings it under these checks.
static func _rebindable_actions() -> Array[String]:
	var out: Array[String] = []
	for entry in InputRemap.ACTIONS:
		out.append(str(entry["action"]))
	return out

const SaveTestHelpers = preload("res://tests/headless/save_test_helpers.gd")
const TEST_PATH := "user://test_smoke_profile.json"

var _scene: Node3D


class _FlatGround:
	func height_at(_x: float, _z: float) -> float:
		return 0.0


# The whole script shares ONE cheap flat level. Every test here is a read-only
# structural check except the two camera tests, which reset the car's
# position/velocity themselves — so a single shared instance is safe.
func before_all() -> void:
	# The challenge tests below grant cars and start runs through the LIVE Save
	# autoload, so point it at a throwaway profile before anything here can write.
	SaveTestHelpers.redirect(TEST_PATH)
	Config.reset()
	_scene = await SceneTestHelpers.add_level_world(self)


func after_all() -> void:
	_scene.free()
	SceneTestHelpers.remove_level_world()
	SaveTestHelpers.cleanup(TEST_PATH)
	Config.reset()


func test_save_autoload_registered() -> void:
	# The Save autoload (player profile / persistence) must be wired in
	# project.godot alongside Config.
	var save := get_node_or_null("/root/Save")
	assert_not_null(save, "Save autoload registered")
	assert_true(save.has_method("load_or_new"), "Save exposes load_or_new()")
	assert_true(save.has_method("grant_car"), "Save exposes grant_car()")


func test_cloud_autoload_registered() -> void:
	# Optional cloud save (features/cloud-save.md). Present on every build; inert
	# until the player signs in, so its mere existence must never change anything.
	var cloud := get_node_or_null("/root/Cloud")
	assert_not_null(cloud, "Cloud autoload registered")
	assert_true(cloud.has_method("sync_now"), "Cloud exposes sync_now()")
	assert_false(cloud.is_signed_in(), "a fresh test run is signed out")


func test_music_director_autoload_is_registered() -> void:
	# The autoload SINGLETON is named "Music" (it can't be "MusicDirector" — that
	# would collide with the class_name). Its type is MusicDirector.
	var md := get_node_or_null("/root/Music")
	assert_not_null(md, "Music autoload exists")
	assert_true(md is MusicDirector, "autoload is a MusicDirector")


func test_car_is_vehicle_with_four_wheels() -> void:
	var car := _scene.get_node("Car") as VehicleBody3D
	assert_not_null(car, "Car node must be a VehicleBody3D")
	var wheels := car.find_children("*", "VehicleWheel3D", false)
	assert_eq(wheels.size(), 4, "Car must have 4 wheels")
	for wheel_name in ["WheelFL", "WheelFR"]:
		assert_true((car.get_node(wheel_name) as VehicleWheel3D).use_as_steering, wheel_name + " steers")
	for wheel_name in ["WheelRL", "WheelRR"]:
		assert_true((car.get_node(wheel_name) as VehicleWheel3D).use_as_traction, wheel_name + " drives")


func test_chase_camera_targets_car() -> void:
	var cam := _scene.get_node("ChaseCamera") as Camera3D
	assert_not_null(cam)
	assert_eq(cam.get("target"), _scene.get_node("Car"), "camera target wired to Car")


func test_chase_camera_sits_behind_direction_of_travel() -> void:
	var cam := _scene.get_node("ChaseCamera") as Camera3D
	var car := _scene.get_node("Car") as VehicleBody3D
	# Drive the car along +X, regardless of which way it is facing.
	car.global_position = Vector3.ZERO
	car.linear_velocity = Vector3(10.0, 0.0, 0.0)
	cam._physics_process(0.016)
	# Camera should be offset opposite the travel direction (behind, at -X)...
	assert_lt(cam.global_position.x, car.global_position.x, "camera sits behind direction of travel")
	# ...and raised by the configured height.
	assert_gt(cam.global_position.y, car.global_position.y, "camera is above the car")


func test_chase_camera_orbit_eases_but_always_looks_at_car() -> void:
	var cam := _scene.get_node("ChaseCamera") as Camera3D
	var car := _scene.get_node("Car") as VehicleBody3D
	# Facing and travelling along +X, with the camera starting off to the side (not
	# wherever the spawn pose left it); it should orbit to the -X side, but gradually.
	car.global_transform = Transform3D(Basis(Vector3.UP, -PI / 2.0), Vector3.ZERO)
	car.linear_velocity = Vector3(10.0, 0.0, 0.0)
	cam._travel_dir = Vector3.FORWARD
	cam._look_yaw = 0.0
	cam._physics_process(0.016)
	# Look-at is exact every frame (not smoothed) but is NOT the car's centre: it's
	# offset ahead along the car's facing by chase_look_ahead_ratio × half_length
	# (see chase_camera.gd's _aim_point). Mirror that formula here with the car's
	# own live facing/half_length rather than pinning the ratio, so a retune of
	# chase_look_ahead_ratio can't break this test.
	var to_aim: Vector3 = (_expected_aim_point(cam, car) - cam.global_position).normalized()
	assert_gt((-cam.global_transform.basis.z).dot(to_aim), 0.999, "look-at is exact, not smoothed")
	# The look-ahead offset must stay a genuine "look near the car" behaviour: the
	# aim point should still be close enough that the camera is clearly still
	# facing the car, not pointed somewhere unrelated.
	var to_car: Vector3 = (car.global_position - cam.global_position).normalized()
	assert_gt((-cam.global_transform.basis.z).dot(to_car), 0.9, "still roughly faces the car despite look-ahead")
	# Orbital position eases: after one step it has not fully reached the -X side.
	assert_gt(cam.global_position.x, -_distance() * 0.9, "orbit eases, does not snap in one step")
	# After many steps the orbital position converges behind the travel direction.
	# The threshold is a FRACTION of follow_distance, not the full reach: the camera
	# height solve reads the cached terrain height under it and lifts the camera to
	# clear the ground, which trades horizontal reach for height by an amount that
	# depends on the ground under the car. So we assert the orbit is
	# clearly BEHIND the car (well past centre) rather than pinning an exact reach.
	for _i in range(120):
		cam._physics_process(0.016)
	assert_lt(cam.global_position.x, -_distance() * 0.6, "orbit converges behind direction of travel")
	to_aim = (_expected_aim_point(cam, car) - cam.global_position).normalized()
	assert_gt((-cam.global_transform.basis.z).dot(to_aim), 0.999, "still looks at the (look-ahead) aim point")
	to_car = (car.global_position - cam.global_position).normalized()
	assert_gt((-cam.global_transform.basis.z).dot(to_car), 0.9, "still roughly faces the car despite look-ahead")


# Mirrors chase_camera.gd's private _aim_point(): the world point the camera aims
# at, raised chase_look_height and offset ahead of the car's origin along its own facing by the configured
# chase_look_ahead_ratio × the car's half length. Recomputed here (rather than
# reaching into the camera's private state) so the test tracks the real formula
# without pinning the ratio's authored value.
func _expected_aim_point(cam: Camera3D, car: VehicleBody3D) -> Vector3:
	var ratio: float = (Config.data as GameConfig).chase_look_ahead_ratio
	var origin: Vector3 = car.global_position + Vector3.UP * (Config.data as GameConfig).chase_look_height
	if ratio == 0.0 or not car.has_method("half_length"):
		return origin
	var forward: Vector3 = -car.global_transform.basis.z
	return origin + forward * (car.half_length() * ratio)


func _distance() -> float:
	return (Config.data as GameConfig).follow_distance


func test_post_process_present() -> void:
	var container := _scene.get_node("PostProcess") as SubViewportContainer
	assert_not_null(container)
	assert_not_null(container.material as ShaderMaterial, "post-process ShaderMaterial assigned")
	var view := container.get_node("View") as SubViewport
	assert_not_null(view, "post-process SubViewport present")
	assert_false(view.own_world_3d, "subviewport renders the main World3D, not its own")
	assert_not_null(view.get_node("ViewCamera") as Camera3D, "mirror camera present")
	assert_eq(container.mouse_filter, Control.MOUSE_FILTER_IGNORE, "post-process container ignores input")
	assert_eq(container.scene_file_path, "res://post_process.tscn",
		"the level uses the shared post-process scene")


func test_hud_speed_label_present() -> void:
	var label := _scene.get_node("HUD/SpeedLabel") as Label
	assert_not_null(label, "HUD has a speed label")
	assert_string_contains(label.text, "km/h", "speed label reads in km/h")


func test_environment_has_fog_and_no_lights() -> void:
	var env := (_scene.get_node("WorldEnvironment") as WorldEnvironment).environment
	assert_true(env.fog_enabled, "fog enabled")
	assert_eq(_scene.find_children("*", "Light3D", true).size(), 0, "no lights in scene")


func test_the_main_scene_is_a_known_boot_scene_and_it_loads() -> void:
	# The one thing that broke when the diegetic hub was deleted: project.godot still
	# named `res://hq.tscn`, so the GAME would not boot at all while every test stayed
	# green (nothing instantiates the main scene by its project setting). The setting must
	# name the title or the world scene — and it must actually load.
	var main_scene := String(ProjectSettings.get_setting("application/run/main_scene", ""))
	assert_true(main_scene in [Scenes.TITLE, Scenes.WORLD],
		"project.godot's run/main_scene names an unknown scene: %s" % main_scene)
	assert_not_null(load(main_scene) as PackedScene, "%s loads as a scene" % main_scene)


func test_shaders_load_with_code() -> void:
	for path in ["res://shaders/ps1_post_process.gdshader", "res://shaders/level_tree.gdshader"]:
		var shader := load(path) as Shader
		assert_not_null(shader, path + " loads")
		assert_true(shader.code.length() > 0, path + " has code")


func test_car_is_instance_of_car_scene() -> void:
	# The car lives in car.tscn and is instanced into level_view.tscn and the flat
	# test fixture — both must use the same packed scene so the fixture tests
	# exercise the real car.
	assert_eq(_scene.get_node("Car").scene_file_path, "res://car.tscn",
		"level_view.tscn instances the shared car scene")


func test_flat_fixture_has_car_and_ground() -> void:
	var fixture: Node3D = load("res://tests/fixtures/test_track.tscn").instantiate()
	add_child_autofree(fixture)
	assert_eq(fixture.get_node("Car").scene_file_path, "res://car.tscn",
		"fixture instances the shared car scene")
	assert_not_null(fixture.get_node("Ground") as StaticBody3D, "fixture has a ground body")


func test_input_actions_exist() -> void:
	for action in _rebindable_actions():
		assert_true(InputMap.has_action(action), "action exists: " + action)


# Every gameplay action must be reachable from a controller (standard racing
# layout: triggers throttle/brake, left stick steer, bumpers shift, face buttons
# for the rest). Debug-only actions stay keyboard-only and are excluded here.
func test_gameplay_actions_have_joypad_bindings() -> void:
	for action in _rebindable_actions():
		var has_joypad := false
		for event in InputMap.action_get_events(action):
			if event is InputEventJoypadButton or event is InputEventJoypadMotion:
				has_joypad = true
				break
		assert_true(has_joypad, "action has a controller binding: " + action)


func test_bonnet_camera_parented_to_car_facing_forward() -> void:
	var car := _scene.get_node("Car") as VehicleBody3D
	var bonnet := car.get_node("BonnetCamera") as Camera3D
	assert_not_null(bonnet, "BonnetCamera is a child of Car")
	# Bonnet sits toward the car's front (-Z local) and is raised (+Y).
	assert_lt(bonnet.transform.origin.z, 0.0, "bonnet camera is toward the front (-Z)")
	assert_gt(bonnet.transform.origin.y, 0.0, "bonnet camera is raised")


func test_camera_manager_present_with_both_cameras() -> void:
	var mgr := _scene.get_node("CameraManager")
	assert_not_null(mgr, "CameraManager node exists")
	assert_eq(mgr.chase_camera, _scene.get_node("ChaseCamera"), "chase camera wired")
	assert_eq(mgr.bonnet_camera, _scene.get_node("Car/BonnetCamera"), "bonnet camera wired")


func test_car_has_engine_audio_player() -> void:
	var car := _scene.get_node("Car") as VehicleBody3D
	var audio := car.get_node_or_null("EngineAudio") as AudioStreamPlayer
	assert_not_null(audio, "Car has an EngineAudio AudioStreamPlayer child")
	assert_true(audio.stream is AudioStreamGenerator, "stream is an AudioStreamGenerator")


func test_authored_wing_meshes_are_hidden_mesh_instances() -> void:
	var car: Node = _scene.get_node("Car")
	var wings := car.find_children("*_aero*", "Node", true, false)
	# No-op until a wing is authored into a car glb; once one exists this guards
	# against a botched re-export (wrong type, or effectively visible on the
	# un-upgraded fielded car). Check is_visible_in_tree(), not the own `visible`
	# flag: a wing on a NON-active body is hidden wholesale via its parent body's
	# flag (its own flag is left untouched, so `.visible` reads stale-true), while
	# the active car's wing is hidden by _set_aero_visible. Effective visibility is
	# the invariant that matters — the wing is not rendered until the aero kit is on.
	for w in wings:
		assert_true(w is MeshInstance3D, "wing node '%s' is a MeshInstance3D" % w.name)
		assert_false((w as Node3D).is_visible_in_tree(),
			"wing '%s' not visible on an un-upgraded car (revealed only by the aero kit)" % w.name)
