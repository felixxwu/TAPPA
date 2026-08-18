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


# main.tscn._ready() generates the full terrain + track, which is expensive, so
# build it ONCE for the whole script instead of per-test. Every test here is a
# read-only structural check except the two camera tests, which reset the car's
# position/velocity themselves — so a single shared instance is safe.
func before_all() -> void:
	# The challenge tests below grant cars and start runs through the LIVE Save
	# autoload, so point it at a throwaway profile before anything here can write.
	SaveTestHelpers.redirect(TEST_PATH)
	RallyFixtures.install()
	_scene = load("res://main.tscn").instantiate()
	add_child(_scene)
	await get_tree().physics_frame  # let world._ready() generate + apply + build


func after_all() -> void:
	_scene.free()
	RallyFixtures.restore()
	SaveTestHelpers.cleanup(TEST_PATH)


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
	assert_true(cloud.has_method("sign_in_email"), "Cloud exposes sign_in_email()")
	assert_false(cloud.is_signed_in(), "a fresh test run is signed out")


func test_music_director_autoload_is_registered() -> void:
	# The autoload SINGLETON is named "Music" (it can't be "MusicDirector" — that
	# would collide with the class_name). Its type is MusicDirector.
	var md := get_node_or_null("/root/Music")
	assert_not_null(md, "Music autoload exists")
	assert_true(md is MusicDirector, "autoload is a MusicDirector")


func test_entering_a_rally_event_generates_its_track() -> void:
	# Entering a rally event = writing its (seed, turn_count, width) into
	# Config.data, then generating — the same Config mutation pattern apply_car
	# uses. Assert that flow builds a track without error (rally-roster.md).
	var event: Dictionary = RallyLibrary.by_id("fx_open")["events"][0]
	Config.data.track_seed = int(event["seed"])
	Config.data.track_turn_count = int(event["turn_count"])
	Config.data.track_width = RallyLibrary.event_width(event)
	_scene._generate_track(Config.data)
	# The flow completes and the scene is still valid (no crash building the
	# rally's track from its seed).
	assert_not_null(_scene.get_node("Floor"), "Floor present after generating the rally track")
	assert_eq(Config.data.track_seed, int(event["seed"]), "rally event seed applied to Config")
	Config.reset()  # don't leak the rally seed into other tests


# Teardown for the challenge tests below. pause_run() is the non-terminal way out —
# nothing DNFs a challenge any more (todo/challenge-career-reuse-drift.md item 12) — so it
# records no period outcome and a sibling test can start the same Daily afterwards. It
# DOES leave the run persisted, so drop that too rather than leaking it into other files.
func _leave_challenge_run() -> void:
	ChallengeSession.pause_run()
	Save.profile["challenge_run"] = {}


func test_entering_a_challenge_stage_generates_its_track() -> void:
	# Reproduces a Daily/Weekly/Monthly challenge stage's real track-gen path — unlike
	# the rally test above (which pokes Config.data.track_* directly, actually
	# exercising the free-roam/no-session TrackGenParams.for_config fallback, NOT
	# TrackGenParams.for_event), this drives it the way world.gd._generate_track
	# actually resolves a challenge stage: ChallengeSession.is_active() ->
	# ChallengeSession.current_stage_params() -> TrackGenParams.for_event(event, cfg).
	#
	# Uses its OWN scene instance (not the file's shared _scene) — regenerating a
	# challenge stage's track leaves the car/track in a different pose than the
	# shared scene's other read-only tests (camera, arch position, ...) assume; a
	# fresh instance keeps this test from corrupting them.
	CarFixtures.install()
	var owned: Dictionary = Save.grant_car("fx_light_rwd")
	var t := int(Time.get_unix_time_from_system())
	ChallengeSession.auto_load_scenes = false
	# A period with a recorded outcome is spent (one attempt per period) and start()
	# refuses it. Leaving a run no longer records one (item 12), but Save.profile is a
	# live autoload shared with earlier test scripts that DO finish the same
	# Daily, so clear the map to guarantee this test gets a fresh period.
	Save.profile["challenge_results"] = {}
	assert_true(ChallengeSession.start(ChallengeLibrary.DAILY, owned, t), "setup: run starts")
	assert_false(ChallengeSession.current_stage_params().is_empty(),
		"setup: the active run has a real stage 0 to generate")

	var scene: Node3D = load("res://main.tscn").instantiate()
	add_child(scene)
	await get_tree().physics_frame  # let world._ready() generate + apply + build

	assert_not_null(scene.get_node("Floor"), "Floor present after generating the challenge stage")
	var track_progress: Node = scene.get("_track_progress") if "_track_progress" in scene else null
	assert_not_null(track_progress, "TrackProgress built for the challenge stage")
	assert_gt(track_progress.baked_length(), 0.0,
		"the generated track has real, non-empty length (not a degenerate/empty terrain)")

	scene.free()
	_leave_challenge_run()
	CarFixtures.restore()
	Config.reset()  # don't leak the challenge seed into other tests


func test_a_challenge_stage_stages_the_start_line_like_a_rally_event() -> void:
	# The pre-countdown start line — the briefing screen that hosts the Upgrades /
	# Tune Car menus, and the staged lead-in it drives — is not career-only: a
	# challenge stage stages exactly the same way, gated on the same shared
	# start_line_enabled toggle (features/rally-challenge.md).
	CarFixtures.install()
	var owned: Dictionary = Save.grant_car("fx_light_rwd")
	ChallengeSession.auto_load_scenes = false
	# A period with a recorded outcome is spent (one attempt per period) and start()
	# refuses it. Leaving a run no longer records one (item 12), but Save.profile is a
	# live autoload shared with earlier test scripts that DO finish the same
	# Daily, so clear the map to guarantee this test gets a fresh period.
	Save.profile["challenge_results"] = {}
	assert_true(ChallengeSession.start(ChallengeLibrary.DAILY, owned,
		int(Time.get_unix_time_from_system())), "setup: the challenge run starts")
	var was_enabled: bool = Config.data.start_line_enabled

	Config.data.start_line_enabled = true
	assert_true(_scene._should_stage(), "a challenge stage opens with the start line")
	Config.data.start_line_enabled = false
	assert_false(_scene._should_stage(), "the shared start_line_enabled toggle still governs it")

	# The arch/start-line banner reads real framing for a challenge instead of blank
	# career fields — and no time to beat, since a challenge has no rival field.
	var info: Dictionary = _scene._arch_event_info()
	assert_ne(String(info["rally_name"]), "", "the banner names the challenge")
	assert_eq(int(info["stage_count"]), ChallengeSession.stage_count(), "…over the run's own stage count")
	assert_eq(int(info["stage_index"]), ChallengeSession.events_completed(), "…at the run's current stage")
	assert_lt(int(info["target_ms"]), 0, "no rival time to beat is displayed for a challenge")

	Config.data.start_line_enabled = was_enabled
	_leave_challenge_run()
	CarFixtures.restore()


func test_spectator_groups_spawn_and_are_not_obstacles() -> void:
	# The world places roadside spectator crowds (todo/roadside-spectators.md).
	# At least one group should exist with standing members, and spectators must
	# NOT be damage-dealing obstacles (people aren't trees).
	var groups: Array = []
	for child in _scene.get_children():
		if child is SpectatorGroup:
			groups.append(child)
	assert_gt(groups.size(), 0, "world spawns spectator group(s)")
	var total_upright := 0
	for g in groups:
		total_upright += g.upright_count()
		assert_false(g.is_in_group(DamageModel.OBSTACLE_GROUP),
			"a spectator group is not an obstacle")
	assert_gt(total_upright, 0, "groups have standing spectators")


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
	car.global_position = Vector3.ZERO
	# Travel along +X; the camera should orbit to the -X side, but gradually.
	car.linear_velocity = Vector3(10.0, 0.0, 0.0)
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
	# depends on the terrain under the car (track seed). So we assert the orbit is
	# clearly BEHIND the car (well past centre) rather than pinning an exact reach.
	for _i in range(120):
		cam._physics_process(0.016)
	assert_lt(cam.global_position.x, -_distance() * 0.6, "orbit converges behind direction of travel")
	to_aim = (_expected_aim_point(cam, car) - cam.global_position).normalized()
	assert_gt((-cam.global_transform.basis.z).dot(to_aim), 0.999, "still looks at the (look-ahead) aim point")
	to_car = (car.global_position - cam.global_position).normalized()
	assert_gt((-cam.global_transform.basis.z).dot(to_car), 0.9, "still roughly faces the car despite look-ahead")


# Mirrors chase_camera.gd's private _aim_point(): the world point the camera aims
# at, offset ahead of the car's origin along its own facing by the configured
# chase_look_ahead_ratio × the car's half length. Recomputed here (rather than
# reaching into the camera's private state) so the test tracks the real formula
# without pinning the ratio's authored value.
func _expected_aim_point(cam: Camera3D, car: VehicleBody3D) -> Vector3:
	var ratio: float = (Config.data as GameConfig).chase_look_ahead_ratio
	var origin: Vector3 = car.global_position
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


func test_hud_speed_label_present() -> void:
	var label := _scene.get_node("HUD/SpeedLabel") as Label
	assert_not_null(label, "HUD has a speed label")
	assert_string_contains(label.text, "km/h", "speed label reads in km/h")


func test_stage_flow_wired() -> void:
	# The per-stage flow (todo/stage-start-and-end.md): a StageManager node plus
	# the HUD widgets it drives (countdown, run timer, complete panel).
	assert_not_null(_scene.get_node_or_null("StageManager") as StageManager,
		"world wires a StageManager into the scene")
	assert_not_null(_scene.get_node_or_null("HUD/CountdownLabel") as Label,
		"HUD has the big countdown label")
	assert_not_null(_scene.get_node_or_null("HUD/ElapsedLabel") as Label,
		"HUD has the run-timer label")
	assert_not_null(_scene.get_node_or_null("HUD/StageCompletePanel") as Control,
		"HUD has the stage-complete panel")


func test_environment_has_fog_and_no_lights() -> void:
	var env := (_scene.get_node("WorldEnvironment") as WorldEnvironment).environment
	assert_true(env.fog_enabled, "fog enabled")
	assert_eq(_scene.find_children("*", "Light3D", true).size(), 0, "no lights in scene")


func test_floor_is_terrain_manager() -> void:
	var floor_node := _scene.get_node("Floor")
	assert_not_null(floor_node as Node3D, "Floor is the TerrainManager node")
	assert_true(floor_node.has_method("height_at"), "manager exposes height_at")
	assert_gt(floor_node.loaded_coords().size(), 0, "chunks loaded around the car at boot")


func test_overworld_scene_loads_with_its_structure() -> void:
	# The overworld hub (features/terrain.md -> "Open-world mode") is the second hub scene,
	# so it gets the same structural check main.tscn does. CHEAP mode is mandatory here:
	# the full path generates a life-size world and would blow the suite's time budget.
	var prev_mode: int = Overworld.load_mode
	Overworld.load_mode = Overworld.LoadMode.CHEAP
	var ow: Node3D = load("res://overworld.tscn").instantiate()
	add_child_autofree(ow)
	for node_name in ["Floor", "Car", "WorldEnvironment", "CameraManager", "PauseMenu"]:
		assert_not_null(ow.get_node_or_null(node_name),
			"overworld.tscn carries its %s node" % node_name)
	assert_true(ow.get_node("Floor").has_method("height_at"),
		"the overworld Floor is a TerrainManager")
	assert_eq(ow.get_node("Car").scene_file_path, "res://car.tscn",
		"the overworld instances the shared car scene")
	Overworld.load_mode = prev_mode


func test_shaders_load_with_code() -> void:
	for path in ["res://shaders/ps1_models.gdshader", "res://shaders/ps1_post_process.gdshader", "res://shaders/billboard_opaque.gdshader"]:
		var shader := load(path) as Shader
		assert_not_null(shader, path + " loads")
		assert_true(shader.code.length() > 0, path + " has code")


func test_car_is_instance_of_car_scene() -> void:
	# The car lives in car.tscn and is instanced into main.tscn and the flat
	# test fixture — both must use the same packed scene so the fixture tests
	# exercise the real car.
	assert_eq(_scene.get_node("Car").scene_file_path, "res://car.tscn",
		"main.tscn instances the shared car scene")


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


func test_billboard_field_builds_instances_and_collision() -> void:
	var floor_node := _scene.get_node("Floor") as TerrainManager
	var tex := load("res://textures/tree.png") as Texture2D
	var field := BillboardField.new()
	add_child_autofree(field)
	var positions := PackedVector2Array([Vector2(10, 10), Vector2(20, 12), Vector2(-5, 8)])
	field.build(positions, floor_node, Vector2(4, 6), tex, 0.5, 4.0, true, 80.0, 15.0,
		0.0, _silhouette_stand_in())
	assert_gt(field.bin_count, 0, "field builds per-bin MultiMeshes")
	assert_eq(field.instance_positions.size(), positions.size(),
		"one instance per scattered position")
	# Collision: one box shape per tree on a StaticBody3D child.
	var body := field.get_node_or_null("Collision") as StaticBody3D
	assert_not_null(body, "with_collision builds a Collision StaticBody3D child")
	var rid := body.get_rid()
	assert_eq(PhysicsServer3D.body_get_shape_count(rid), positions.size(),
		"one box shape per tree")
	assert_eq(body.collision_layer, 1, "tree body on layer 1 like terrain")
	var p := positions[0]
	var expected_y := floor_node.height_at(p.x, p.y) + 4.0 / 2.0
	var origin := PhysicsServer3D.body_get_shape_transform(rid, 0).origin
	assert_almost_eq(origin, Vector3(p.x, expected_y, p.y), Vector3(1e-3, 1e-3, 1e-3),
		"box rests on the ground at the tree position")
	# Render distance is wired into the billboard material as shader params.
	var smat := field.render_mesh.surface_get_material(0) as ShaderMaterial
	assert_not_null(smat, "billboard surface has a ShaderMaterial")
	assert_eq(smat.get_shader_parameter("render_distance"), 80.0, "render_distance param set")
	assert_eq(smat.get_shader_parameter("fade_band"), 15.0, "fade_band param set")


func test_billboard_field_opaque_mesh_path_uses_silhouette_and_opaque_shader() -> void:
	var floor_node := _scene.get_node("Floor") as TerrainManager
	var tex := load("res://textures/tree.png") as Texture2D
	# A trivial 2-triangle silhouette stand-in (a unit quad) is enough to prove
	# the field instances the SUPPLIED mesh with the opaque shader.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for uv in [Vector2(0,1), Vector2(1,1), Vector2(1,0), Vector2(0,1), Vector2(1,0), Vector2(0,0)]:
		st.set_uv(uv)
		st.add_vertex(Vector3(uv.x - 0.5, 1.0 - uv.y, 0.0))
	var silhouette := st.commit()

	var field := BillboardField.new()
	add_child_autofree(field)
	var positions := PackedVector2Array([Vector2(10, 10), Vector2(20, 12)])
	field.build(positions, floor_node, Vector2(4, 6), tex, 0.5, 4.0, true, 80.0, 15.0,
		0.0, silhouette)

	assert_eq(field.render_mesh, silhouette, "field instances the supplied silhouette mesh")
	assert_eq(field.instance_positions.size(), positions.size(), "one instance per position")
	var smat := field.render_mesh.surface_get_material(0) as ShaderMaterial
	assert_not_null(smat, "silhouette surface has a ShaderMaterial")
	assert_eq(smat.shader, load("res://shaders/billboard_opaque.gdshader"),
		"opaque path uses the discard-free billboard shader")
	assert_eq(smat.get_shader_parameter("render_distance"), 80.0, "render_distance wired")
	# size is carried as instance scale so the shader reads it from MODEL_MATRIX.
	# (MultiMesh.get_instance_transform is a no-op stub under --headless, so we
	# read the field's own mirror of the scale it baked into every transform.)
	assert_almost_eq(field.instance_scale.x, 4.0, 1e-3, "instance scaled by size.x")
	assert_almost_eq(field.instance_scale.y, 6.0, 1e-3, "instance scaled by size.y")
	# Collision still built for trees.
	assert_not_null(field.get_node_or_null("Collision"), "opaque path still builds collision")


# A trivial normalized silhouette stand-in (unit quad, x in [-0.5,0.5], y in [0,1])
# — BillboardField requires a supplied mesh, and its geometry is irrelevant to the
# placement / collision / material logic these tests assert on.
func _silhouette_stand_in() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for uv in [Vector2(0,1), Vector2(1,1), Vector2(1,0), Vector2(0,1), Vector2(1,0), Vector2(0,0)]:
		st.set_uv(uv)
		st.add_vertex(Vector3(uv.x - 0.5, 1.0 - uv.y, 0.0))
	return st.commit()


func _opaque_billboard_field(positions: PackedVector2Array) -> BillboardField:
	var floor_node := _scene.get_node("Floor") as TerrainManager
	var tex := load("res://textures/tree.png") as Texture2D
	var field := BillboardField.new()
	add_child_autofree(field)
	field.build(positions, floor_node, Vector2(4, 6), tex, 0.5, 4.0, true, 80.0, 15.0,
		0.0, _silhouette_stand_in())
	return field


func test_billboard_field_knock_down_fells_once_and_keeps_shapes() -> void:
	# Felling on the opaque billboard path (the shipped tree renderer): a struck
	# instance is marked fallen, its box disabled in place (shape count unchanged so
	# no reindex), and a second hit is an idempotent no-op. Tunable-agnostic.
	var positions := PackedVector2Array([Vector2(10, 10), Vector2(20, 12), Vector2(-5, 8)])
	var field := _opaque_billboard_field(positions)
	var rid := (field.get_node("Collision") as StaticBody3D).get_rid()

	assert_false(field.is_fallen(1), "instance starts standing")
	field.knock_down(1, Vector3(1, 0, 0), 0.6)
	assert_true(field.is_fallen(1), "instance felled after knock_down")
	assert_false(field.is_fallen(0), "neighbour still standing")
	assert_eq(PhysicsServer3D.body_get_shape_count(rid), positions.size(),
		"disabling a felled box keeps all shapes (no reindex)")

	field.knock_down(1, Vector3(1, 0, 0), 0.6)
	assert_eq(field._falling.size(), 1, "second knock_down on same instance is a no-op")

	field._process(1.0)  # > duration
	assert_eq(field._falling.size(), 0, "fall record retired when flat")
	assert_false(field.is_processing(), "field stops ticking once nothing is falling")


func test_billboard_field_reset_fallen_stands_trees_back_up() -> void:
	# reset_fallen (used to reset the stage before a replay): every felled instance is
	# unmarked and its box re-enabled in place, with the shape count unchanged (no
	# reindex). There's no public is-shape-disabled getter, so the shape count + is_fallen
	# state are the observable contract. Tunable-agnostic.
	var positions := PackedVector2Array([Vector2(10, 10), Vector2(20, 12), Vector2(-5, 8)])
	var field := _opaque_billboard_field(positions)
	var rid := (field.get_node("Collision") as StaticBody3D).get_rid()
	field.knock_down(0, Vector3(1, 0, 0), 0.6)
	field.knock_down(2, Vector3(1, 0, 0), 0.6)
	assert_true(field.is_fallen(0) and field.is_fallen(2), "sanity: two trees felled")

	field.reset_fallen()

	assert_false(field.is_fallen(0), "reset stands the felled tree back up")
	assert_false(field.is_fallen(2), "reset stands every felled tree back up")
	assert_eq(PhysicsServer3D.body_get_shape_count(rid), positions.size(),
		"reset keeps all shapes (no reindex)")
	assert_eq(field._falling.size(), 0, "no lingering fall animation after reset")
	assert_false(field.is_processing(), "field stops ticking after reset")
	# A reset tree can be felled again on the next run.
	field.knock_down(0, Vector3(1, 0, 0), 0.6)
	assert_true(field.is_fallen(0), "a reset tree can be knocked over again")


func test_billboard_field_knock_down_safe_without_collision_or_bad_index() -> void:
	# Felling disables a hitbox, so a field built without collision (bushes) isn't
	# fellable; out-of-range indices must also be safe no-ops.
	var floor_node := _scene.get_node("Floor") as TerrainManager
	var tex := load("res://textures/tree.png") as Texture2D
	var bodyless := BillboardField.new()
	add_child_autofree(bodyless)
	bodyless.build(PackedVector2Array([Vector2(1, 1)]), floor_node, Vector2(4, 6), tex,
		0.5, 4.0, false, 80.0, 15.0, 0.0, _silhouette_stand_in())
	bodyless.knock_down(0, Vector3(1, 0, 0), 0.6)
	assert_false(bodyless.is_fallen(0), "a field without collision is not fellable")

	var opaque_field := _opaque_billboard_field(PackedVector2Array([Vector2(2, 2)]))
	opaque_field.knock_down(99, Vector3(1, 0, 0), 0.6)
	assert_false(opaque_field.is_fallen(99), "out-of-range index is a safe no-op")


func test_opaque_billboard_size_jitter_scales_within_range_deterministically() -> void:
	# A jitter floor < 1.0 (region trees, e.g. Greece) gives each opaque tree a
	# deterministic per-position size multiplier in [floor, 1.0] — a stand varies in
	# height, but a given position always resolves to the same size so build and
	# felling-restore agree. Passing the floor explicitly keeps this test independent
	# of the config value. Floor 1.0 (home trees) disables the jitter entirely.
	var floor_node := _scene.get_node("Floor") as TerrainManager
	var tex := load("res://textures/tree.png") as Texture2D
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for uv in [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0)]:
		st.set_uv(uv)
		st.add_vertex(Vector3(uv.x - 0.5, 1.0 - uv.y, 0.0))
	var mesh := st.commit()

	var jittered := BillboardField.new()
	add_child_autofree(jittered)
	jittered.build(PackedVector2Array([Vector2(3, 4), Vector2(-8, 9), Vector2(15, -6)]),
		floor_node, Vector2(4, 6), tex, 0.5, 4.0, false, 80.0, 15.0, 0.0, mesh, 0.5)
	for pos in jittered.instance_positions:
		var f := jittered._size_factor(pos)
		assert_between(f, 0.5, 1.0, "jittered size factor stays within [floor, 1.0]")
		assert_almost_eq(jittered._size_factor(pos), f, 1e-9, "same position -> same factor")

	var plain := BillboardField.new()
	add_child_autofree(plain)
	plain.build(PackedVector2Array([Vector2(3, 4)]), floor_node,
		Vector2(4, 6), tex, 0.5, 4.0, false, 80.0, 15.0, 0.0, mesh, 1.0)
	assert_eq(plain._size_factor(plain.instance_positions[0]), 1.0, "floor 1.0 disables jitter")


func test_opaque_billboard_aspect_jitter_stretches_x_and_y_independently() -> void:
	# Aspect jitter (the "how drastic" shape dial) scales width (x/z) and height (y) by
	# independent random factors in [1-k, 1+k] on top of the uniform size — so some
	# trees read taller-and-narrower and others shorter-and-wider. Passing k explicitly
	# keeps this independent of the config value. k=0 collapses to pure size jitter (a
	# square-aspect scale). Deterministic per position so felling-restore agrees.
	var floor_node := _scene.get_node("Floor") as TerrainManager
	var tex := load("res://textures/tree.png") as Texture2D
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for uv in [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0)]:
		st.set_uv(uv)
		st.add_vertex(Vector3(uv.x - 0.5, 1.0 - uv.y, 0.0))
	var mesh := st.commit()
	var size := Vector2(4.0, 6.0)
	var k := 0.3

	# size_jitter floor 1.0 so the uniform factor is exactly 1 — isolates the aspect
	# stretch. base scale is (size.x, size.y, size.x) for the opaque cross.
	var field := BillboardField.new()
	add_child_autofree(field)
	field.build(PackedVector2Array([Vector2(3, 4), Vector2(-8, 9), Vector2(15, -6)]),
		floor_node, size, tex, 0.5, 4.0, false, 80.0, 15.0, 0.0, mesh, 1.0, k)
	var saw_non_square := false
	for pos in field.instance_positions:
		var s := field._instance_scale(pos)
		var fx := s.x / size.x
		var fy := s.y / size.y
		assert_between(fx, 1.0 - k, 1.0 + k, "width factor within [1-k, 1+k]")
		assert_between(fy, 1.0 - k, 1.0 + k, "height factor within [1-k, 1+k]")
		assert_almost_eq(s.z / size.x, fx, 1e-6, "cross depth (z) tracks width (x)")
		assert_almost_eq((field._instance_scale(pos) - s).length(), 0.0, 1e-9,
			"same position -> same scale (felling-restore agrees)")
		if absf(fx - fy) > 1e-6:
			saw_non_square = true
	assert_true(saw_non_square, "x and y jitter independently (aspect varies across the stand)")

	# k = 0 disables the aspect stretch: width and height share the uniform factor, so
	# the aspect ratio matches the authored size exactly.
	var plain := BillboardField.new()
	add_child_autofree(plain)
	plain.build(PackedVector2Array([Vector2(3, 4)]), floor_node,
		size, tex, 0.5, 4.0, false, 80.0, 15.0, 0.0, mesh, 1.0, 0.0)
	var ps := plain._instance_scale(plain.instance_positions[0])
	assert_almost_eq(ps.x / size.x, ps.y / size.y, 1e-6, "k=0 keeps the authored aspect")


func test_world_uses_tree_mesh_field_for_trees_and_bushes() -> void:
	# Trees + bushes render as one colliding foliage field (trees, opaque
	# BillboardField) and one non-colliding field (bushes, 3D-mesh TreeMeshField).
	# The invariant: at least one colliding + one non-colliding field exists.
	# (The shared scene may be re-generated by an earlier test, so don't assume an
	# exact field count.)
	var with_collision := 0
	var without_collision := 0
	for c in _scene.get_children():
		if c is TreeMeshField:
			var f := c as TreeMeshField
			assert_gt(f.bin_count, 0, "each foliage field has at least one bin")
			if f.get_node_or_null("Collision") != null:
				with_collision += 1
			else:
				without_collision += 1
		elif c is BillboardField:
			var bf := c as BillboardField
			assert_gt(bf.instance_positions.size(), 0, "each billboard field has instances")
			if bf.get_node_or_null("Collision") != null:
				with_collision += 1
			else:
				without_collision += 1
	assert_gt(with_collision, 0, "world builds a colliding foliage field for trees")
	assert_gt(without_collision, 0, "world builds a non-colliding foliage field for bushes")


func test_billboard_field_without_collision_has_no_body() -> void:
	var floor_node := _scene.get_node("Floor") as TerrainManager
	var tex := load("res://textures/tree-greece.webp") as Texture2D
	var field := BillboardField.new()
	add_child_autofree(field)
	var positions := PackedVector2Array([Vector2(3, 4), Vector2(6, 9)])
	field.build(positions, floor_node, Vector2(1, 1.5), tex, 0.5, 4.0, false, 80.0, 15.0,
		-0.5, _silhouette_stand_in())
	assert_eq(field.instance_positions.size(), positions.size(),
		"bush field still renders one instance per position")
	assert_null(field.get_node_or_null("Collision"),
		"with_collision == false builds no Collision body")
	# y_offset sinks the sprite: instance Y is ground height minus the sink. Read
	# the renderer-independent instance_positions mirror — the MultiMesh transform
	# buffer lives in the RenderingServer, which is a no-op stub under --headless.
	var p := positions[0]
	var origin := field.instance_positions[0]
	assert_almost_eq(origin, Vector3(p.x, floor_node.height_at(p.x, p.y) - 0.5, p.y),
		Vector3(1e-3, 1e-3, 1e-3), "bush sunk into ground by the y_offset")


func test_spawn_trees_billboard_texture_selects_region_billboard() -> void:
	# A region tree texture (Foliage.spawn_trees billboard_texture arg) selects that
	# texture's star-shaped billboard cutout — that's how a region (e.g. Greece)
	# swaps in its own tree. Trees are always a BillboardField.
	var floor_node := _scene.get_node("Floor") as TerrainManager
	var tex := load("res://textures/tree-greece.webp") as Texture2D
	var parent := Node3D.new()
	add_child_autofree(parent)
	var field := Foliage.spawn_trees(parent, PackedVector2Array([Vector2(2, 2)]),
		floor_node, false, 80.0, 15.0, tex)
	assert_true(field is BillboardField,
		"spawn_trees produces a BillboardField")


func test_tree_silhouette_mesh_caches_per_texture() -> void:
	# The silhouette cutout is traced per source texture and cached by path, so each
	# distinct tree texture yields its own (reused) mesh — the home tree and a region
	# tree don't collide, and asking twice returns the same instance.
	var home := Foliage.tree_silhouette_mesh()
	var greece_tex := load("res://textures/tree-greece.webp") as Texture2D
	var region := Foliage.tree_silhouette_mesh(greece_tex)
	assert_not_null(region, "a region texture traces a real silhouette mesh")
	assert_true(region.get_surface_count() > 0, "the region silhouette has geometry")
	assert_ne(home, region, "distinct textures produce distinct cached silhouettes")
	assert_eq(region, Foliage.tree_silhouette_mesh(greece_tex),
		"the same texture returns the cached silhouette instance")


func test_tree_mesh_field_for_bushes_skips_collision_and_bakes_light() -> void:
	# Bushes use the SAME TreeMeshField as trees, but with_collision = false and
	# bake_terrain_light = true (ground cover that matches the ground tint).
	var floor_node := _scene.get_node("Floor") as TerrainManager
	var mesh := BoxMesh.new()
	var field := TreeMeshField.new()
	add_child_autofree(field)
	var positions := PackedVector2Array([Vector2(7, 5), Vector2(-3, 11), Vector2(40, 41)])
	field.build(positions, floor_node, mesh, 0.6, 0.0, 0.0, 80.0, 15.0, 25.0, false, true)
	assert_eq(field.instance_positions.size(), positions.size(), "one placed position per bush")
	assert_gt(field.bin_count, 0, "bushes binned into per-cell MultiMeshes")
	assert_null(field.get_node_or_null("Collision"),
		"with_collision == false builds no Collision body for bushes")
	# Per-instance baked light → MultiMesh use_colors enabled on every bin.
	for c in field.get_children():
		if c is MultiMeshInstance3D:
			assert_true((c as MultiMeshInstance3D).multimesh.use_colors,
				"bake_terrain_light enables per-instance MultiMesh colour")
	# Instances rest on the terrain (no sink/offset for the mesh ground cover).
	var p := positions[0]
	assert_almost_eq(field.instance_positions[0], Vector3(p.x, floor_node.height_at(p.x, p.y), p.y),
		Vector3(1e-3, 1e-3, 1e-3), "bush instance rests on the ground")


func test_tree_mesh_field_xz_radius_scales_with_height() -> void:
	# xz_radius (used to keep wide bushes off the road) = half the larger horizontal
	# AABB extent, scaled by the same uniform scale build() applies for the height.
	var box := BoxMesh.new()
	box.size = Vector3(2.0, 1.0, 3.0)  # AABB 2 x 1 x 3
	assert_almost_eq(TreeMeshField.uniform_scale_for(box, 2.0), 2.0, 1e-4,
		"uniform scale = target_height / mesh height")
	# uscale 2.0, larger horizontal extent 3.0 -> radius = 3.0/2 * 2.0 = 3.0
	assert_almost_eq(TreeMeshField.xz_radius(box, 2.0), 3.0, 1e-4,
		"xz radius is half the larger horizontal extent, scaled to height")
	# Degenerate (flat) mesh height -> scale 1.0, no divide-by-zero.
	var flat := BoxMesh.new(); flat.size = Vector3(2.0, 0.0, 2.0)
	assert_almost_eq(TreeMeshField.uniform_scale_for(flat, 5.0), 1.0, 1e-4,
		"zero-height mesh falls back to scale 1.0")


# --- Corner barriers (features/barriers.md) -----------------------------------
# Only the WIRING lives here (it needs the real scene + baked terrain). The builder's
# own contracts — poses, slope pitching, batching, collision — are scene-free unit
# tests in test_barrier_field.gd, and the planning rules in test_barrier_layout.gd.
func test_world_plans_and_builds_barriers_on_a_sharp_corner() -> void:
	# The wiring: world._build_barriers reads the live config, plans off the track's
	# pieces, samples the baked surface, and drops a BarrierField into the scene.
	# Driven with a synthetic bend so it does not depend on the fixture seed throwing
	# a sharp corner.
	var curve := Curve2D.new()
	for z in range(0, 41, 4):
		curve.add_point(Vector2(60.0, float(z)))
	var centre := Vector2(76.0, 40.0)
	for i in range(1, 10):
		var a: float = PI - (i / 9.0) * (PI * 0.5)
		curve.add_point(centre + Vector2(cos(a), sin(a)) * 16.0)
	var pieces := [{"corner": "Hairpin", "flip": false, "straight": 40.0,
		"entry_pos": Vector2(60.0, 0.0), "entry_heading": Vector2(0.0, 1.0)}]
	# A barrier only goes up where the land falls away, and whether this synthetic bend
	# happens to sit beside a drop is an accident of the fixture's terrain — so switch the
	# terrain rule off for this test (accept any drop, never veto a rise). The rule itself
	# is covered against known ground in test_barrier_layout.gd; what is under test here
	# is the wiring.
	var saved_drop: float = Config.data.barrier_drop_min_m
	var saved_hill: float = Config.data.barrier_hill_tolerance_m
	Config.data.barrier_drop_min_m = -1000.0
	Config.data.barrier_hill_tolerance_m = 1000.0
	_scene._build_barriers(Config.data, {"centerline": curve, "pieces": pieces})
	Config.data.barrier_drop_min_m = saved_drop
	Config.data.barrier_hill_tolerance_m = saved_hill
	var fields := _scene.get_children().filter(func(c): return c is BarrierField)
	# Exactly one, whether or not the fixture's own track threw a sharp corner: the
	# build replaces any existing field rather than stacking a second one.
	assert_eq(fields.size(), 1, "the world holds one barrier field")
	var field: BarrierField = fields[0]
	assert_gt(field.barrier_count, 1, "the sharp corner got a run of modules")
	field.queue_free()


func test_sign_field_builds_knockable_signs_at_road_height() -> void:
	var floor_node := _scene.get_node("Floor") as TerrainManager
	var field := SignField.new()
	add_child_autofree(field)
	# A hand-made layout (no full track needed): one of each kind, both sides.
	var layout := [
		{"kind": "start", "texture_key": "start", "pos": Vector2(4, 6), "tangent": Vector2(0, 1), "side": 1},
		{"kind": "sector", "texture_key": "sector_2", "pos": Vector2(12, 8), "tangent": Vector2(1, 0), "side": -1},
		{"kind": "turn", "texture_key": "arrow_square_left", "pos": Vector2(-5, 9), "tangent": Vector2(0, 1), "side": 1},
	]
	field.build(layout, floor_node, Config.data.sign_render_params())
	assert_eq(field.sign_count, layout.size(), "one sign built per layout entry")
	# Children: one RigidBody3D per sign, plus the shared MultiMeshInstance3Ds
	# that render all resting panels (one per distinct face material).
	var bodies := field.get_children().filter(func(c): return c is RigidBody3D)
	assert_eq(bodies.size(), layout.size(), "one body per sign")
	var mms := field.get_children().filter(func(c): return c is MultiMeshInstance3D)
	assert_gt(mms.size(), 0, "resting panels render via shared MultiMeshes")
	# Each sign is a light, knockable RigidBody3D (the wet-floor-board feel).
	var sign0 := field.get_child(0) as RigidBody3D
	assert_not_null(sign0, "each sign is a RigidBody3D")
	assert_gt(sign0.mass, 0.0, "sign body has a mass")
	assert_lt(sign0.mass, 50.0, "sign is light enough for the car to scatter")
	# Like a spectator ragdoll, the sign never runs real collision physics against the
	# car: it sits on its own layer (off the car's default mask=1) and masks only the
	# world layer (terrain/trees), so the car drives straight through it.
	assert_eq(sign0.collision_layer, 1 << 4, "sign is on its own layer, off the car's mask")
	assert_eq(sign0.collision_mask, 1, "sign masks only the world layer (terrain/trees)")
	# Spawned FROZEN so it rests exactly where placed even where terrain collision
	# isn't streamed yet (TerrainManager only loads a ring around the car) — a live
	# body would free-fall into the void before the player reached it. The car wakes
	# it on contact (test_sign_wakes_only_on_dynamic_non_self_contact).
	assert_true(sign0.freeze, "sign spawns frozen so it never free-falls off-terrain")
	# A collision shape + an Area3D waker are children of the body so the whole
	# sign tumbles together. Panels are NOT nodes while the sign rests — they live
	# in the shared MultiMeshes and only materialize on the body when knocked
	# (see test_sign_field.gd for that swap contract).
	var panels := 0
	var has_shape := false
	var has_waker := false
	for child in sign0.get_children():
		if child is MeshInstance3D:
			panels += 1
		elif child is CollisionShape3D:
			has_shape = true
		elif child is Area3D:
			has_waker = true
	assert_eq(panels, 0, "a resting sign carries no per-node panel meshes")
	assert_true(has_shape, "sign body carries a collision shape")
	assert_true(has_waker, "sign carries an Area3D waker to unfreeze it on car contact")
	# Knockable cosmetic clutter: deals NO HP damage, so it is NOT a damage obstacle.
	assert_false(sign0.is_in_group(DamageModel.OBSTACLE_GROUP),
		"signs are not in the damage OBSTACLE_GROUP (no HP penalty)")
	# The sign starts at the centerline road-surface height for its position.
	var p: Vector2 = layout[0]["pos"]
	assert_almost_eq(sign0.position.y, floor_node.height_at(p.x, p.y), 1e-3,
		"sign sits on the road surface height")


# The frozen sign must wake (tumble) only when the dynamic car hits it — never from
# its OWN body overlapping the waker Area, nor from streamed terrain / tree hitboxes
# (StaticBody3D), or every sign would unfreeze and free-fall the instant it spawned.
func test_sign_wakes_only_on_dynamic_non_self_contact() -> void:
	var floor_node := _scene.get_node("Floor") as TerrainManager
	var field := SignField.new()
	add_child_autofree(field)
	field.build([{"kind": "turn", "texture_key": "arrow_2_right",
		"pos": Vector2(20, 20), "tangent": Vector2(0, 1), "side": 1}],
		floor_node, Config.data.sign_render_params())
	var sign0 := field.get_child(0) as RigidBody3D
	assert_true(sign0.freeze, "sign starts frozen")
	# Its own body entering the waker must NOT wake it.
	field._wake_sign(sign0, sign0)
	assert_true(sign0.freeze, "a sign ignores its own body in the waker")
	# A static body (terrain chunk / tree hitbox) must NOT wake it.
	var stat := StaticBody3D.new()
	add_child_autofree(stat)
	field._wake_sign(stat, sign0)
	assert_true(sign0.freeze, "a sign ignores static bodies (terrain, trees)")
	# A dynamic body (the car) knocks it over: the sign unfreezes, is flung along the
	# car's velocity (a fake collision — never a real one), and gains a collision
	# exception so it can never touch the car afterwards either.
	var dyn := RigidBody3D.new()
	add_child_autofree(dyn)
	dyn.linear_velocity = Vector3(0.0, 0.0, -12.0)
	field._wake_sign(dyn, sign0)
	assert_false(sign0.freeze, "a dynamic body (the car) unfreezes the sign")
	assert_gt(sign0.linear_velocity.length(), 0.0,
		"the struck sign is launched, not left to collide with the car")
	assert_true(sign0.get_collision_exceptions().has(dyn),
		"the sign adds a collision exception so it never collides with the car")


func test_main_scene_generates_a_track() -> void:
	await get_tree().physics_frame  # let world._ready() generate + apply + build
	var floor_node = _scene.get_node("Floor")
	assert_gt(floor_node.track_weights.size(), 0, "world applied a track (colour weights baked)")
	assert_gt(floor_node.road_heights.size(), 0, "world baked road heights for flattening")
	var ring: int = 2 * TerrainManager.RADIUS + 1
	assert_eq(floor_node.loaded_coords().size(), ring * ring, "deferred ring is built once the track is applied")


func _await_node(name: String) -> Node3D:
	var n: Node3D = null
	for _i in range(240):
		n = _scene.get_node_or_null(name) as Node3D
		if n != null:
			return n
		await get_tree().process_frame
	return n


func _assert_spans_road_upright(arch: Node3D, who: String) -> void:
	var cfg: GameConfig = Config.data
	# The opening is the road width plus a margin each side (world.gd), so removing
	# the two margins must still leave a positive road gap between the legs. (We
	# check it this way rather than against cfg.track_width: other tests in this
	# shared scene mutate/reset Config.data.track_width, but the arch's span was
	# baked from the width in force when it was generated.)
	var road_gap: float = arch.span - 2.0 * cfg.finish_arch_road_margin_m
	assert_gt(road_gap, 0.0, who + " opening leaves road clearance inside the leg margins")
	assert_gt(arch.span * 0.5, road_gap * 0.5, who + " leg inner faces sit outside the road")
	assert_gt(arch.global_transform.origin.y, -50.0, who + " sits on the terrain, not far below")
	# Local X (leg-to-leg) runs across the road and stays horizontal (gate upright).
	assert_almost_eq(arch.global_transform.basis.x.normalized().y, 0.0, 0.05,
		who + " leg-to-leg axis stays horizontal")


func test_finish_arch_straddles_the_road_at_the_stage_end() -> void:
	# world.gd places one FinishArch at the FINISH offset — i.e. exactly 100%
	# track progress — so crossing it ends the stage immediately. The rendered road
	# continues past it (the post-finish runoff), so this is NOT the centerline end.
	var arch := await _await_node("FinishArch")
	assert_not_null(arch, "world built a FinishArch at the stage end")
	if arch == null:
		return
	_assert_spans_road_upright(arch, "finish arch")
	assert_false(arch.is_start, "finish arch wears the FINISH wording")
	# It must sit at the end of the progress centerline (100%). Compare its XZ to the
	# centerline's far end, read off the live TrackProgress.
	var tp = _scene.get_node_or_null("TrackProgress")
	assert_not_null(tp, "TrackProgress present")
	if tp != null:
		var end2: Vector2 = tp._centerline.sample_baked(tp.finish_offset())
		var here2 := Vector2(arch.global_transform.origin.x, arch.global_transform.origin.z)
		assert_lt(here2.distance_to(end2), 1.0, "finish arch sits at the finish offset (100% progress)")


func test_start_arch_straddles_the_road_at_the_start_line() -> void:
	# world.gd places a matching StartArch at the car's spawn (the start line).
	var arch := await _await_node("StartArch")
	assert_not_null(arch, "world built a StartArch at the start line")
	if arch == null:
		return
	_assert_spans_road_upright(arch, "start arch")
	assert_true(arch.is_start, "start arch wears the START wording")
	# It straddles the start line — the car's spawn, which on a dev boot is the
	# start of the progress centerline (offset 0). Compare to that rather than the
	# live car, which earlier camera tests reposition.
	var tp = _scene.get_node_or_null("TrackProgress")
	if tp != null:
		var start2: Vector2 = tp._centerline.sample_baked(0.0)
		var here2 := Vector2(arch.global_transform.origin.x, arch.global_transform.origin.z)
		assert_lt(here2.distance_to(start2), 1.0, "start arch sits at the start line (centerline offset 0)")


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


# --- Per-species baseline proportions (tree_mix size_scale) ---------------------
# The billboard card both sizing profiles describe is SQUARE, so a tall narrow cutout is
# stretched to 1:1 and drawn far too wide. A species may state its own proportions.
# See features/trees.md.

func test_a_species_without_size_scale_keeps_the_profile_size_exactly() -> void:
	# Every species that does not state proportions must be byte-identical to the
	# profile, or adding this feature would silently resize every tree in the game.
	var cfg: GameConfig = Config.data
	var floor_node := _scene.get_node("Floor") as TerrainManager
	var parent := Node3D.new()
	add_child_autofree(parent)
	var field := Foliage.spawn_trees(parent, PackedVector2Array([Vector2(2, 2)]),
		floor_node, false, 80.0, 15.0, load("res://textures/tree.png"))
	assert_eq(field.instance_scale.x, cfg.tree_size_m.x, "width is the profile's")
	assert_eq(field.instance_scale.y, cfg.tree_size_m.y, "height is the profile's")


func test_size_scale_narrows_and_heightens_a_species_independently() -> void:
	# The relation, not the numbers: the two axes must move independently, which a
	# single uniform scale could not express.
	var cfg: GameConfig = Config.data
	var floor_node := _scene.get_node("Floor") as TerrainManager
	var parent := Node3D.new()
	add_child_autofree(parent)
	var field := Foliage.spawn_trees(parent, PackedVector2Array([Vector2(2, 2)]),
		floor_node, false, 80.0, 15.0, load("res://textures/tree.png"), false,
		Vector2(0.5, 1.2))
	assert_lt(field.instance_scale.x, cfg.tree_size_m.x, "x scale narrows the card")
	assert_gt(field.instance_scale.y, cfg.tree_size_m.y, "y scale heightens it")
