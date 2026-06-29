extends GutTest

const ACTIONS := [
	"accelerate", "brake_reverse", "steer_left", "steer_right", "reset_car",
	"shift_up", "shift_down", "toggle_gearbox", "cycle_drive_mode", "cycle_camera",
]

var _scene: Node3D


# main.tscn._ready() generates the full terrain + track, which is expensive, so
# build it ONCE for the whole script instead of per-test. Every test here is a
# read-only structural check except the two camera tests, which reset the car's
# position/velocity themselves — so a single shared instance is safe.
func before_all() -> void:
	_scene = load("res://main.tscn").instantiate()
	add_child(_scene)
	await get_tree().physics_frame  # let world._ready() generate + apply + build


func after_all() -> void:
	_scene.free()


func test_scene_instantiates() -> void:
	assert_not_null(_scene)


func test_save_autoload_registered() -> void:
	# The Save autoload (player profile / persistence) must be wired in
	# project.godot alongside Config.
	var save := get_node_or_null("/root/Save")
	assert_not_null(save, "Save autoload registered")
	assert_true(save.has_method("load_or_new"), "Save exposes load_or_new()")
	assert_true(save.has_method("grant_car"), "Save exposes grant_car()")


func test_entering_a_rally_event_generates_its_track() -> void:
	# Entering a rally event = writing its (seed, turn_count, width) into
	# Config.data, then generating — the same Config mutation pattern apply_car
	# uses. Assert that flow builds a track without error (rally-roster.md).
	var RallyLibrary = load("res://scripts/rally_library.gd")
	var event: Dictionary = RallyLibrary.by_id("coastal_sprint")["events"][0]
	Config.data.track_seed = int(event["seed"])
	Config.data.track_turn_count = int(event["turn_count"])
	Config.data.track_width = RallyLibrary.event_width(event)
	_scene._generate_track(Config.data)
	# The flow completes and the scene is still valid (no crash building the
	# rally's track from its seed).
	assert_not_null(_scene.get_node("Floor"), "Floor present after generating the rally track")
	assert_eq(Config.data.track_seed, int(event["seed"]), "rally event seed applied to Config")
	Config.reset()  # don't leak the rally seed into other tests


func test_spectator_groups_spawn_and_are_not_obstacles() -> void:
	# The world places roadside spectator crowds (todo/roadside-spectators.md).
	# At least one group should exist with standing members, and spectators must
	# NOT be damage-dealing obstacles (people aren't trees).
	var DamageModel = load("res://scripts/damage_model.gd")
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
	# Look-at is exact every frame: camera points straight at the car immediately.
	var to_car: Vector3 = (car.global_position - cam.global_position).normalized()
	assert_gt((-cam.global_transform.basis.z).dot(to_car), 0.999, "look-at is exact, not smoothed")
	# Orbital position eases: after one step it has not fully reached the -X side.
	assert_gt(cam.global_position.x, -_distance() * 0.9, "orbit eases, does not snap in one step")
	# After many steps the orbital position converges behind the travel direction.
	for _i in range(120):
		cam._physics_process(0.016)
	assert_lt(cam.global_position.x, -_distance() * 0.9, "orbit converges behind direction of travel")
	assert_gt((-cam.global_transform.basis.z).dot(
		(car.global_position - cam.global_position).normalized()), 0.999, "still looks at car")


func _distance() -> float:
	return (Config.data as GameConfig).follow_distance


func test_post_process_present() -> void:
	var rect := _scene.get_node("PostProcess/ColorRect") as ColorRect
	assert_not_null(rect)
	assert_not_null(rect.material as ShaderMaterial, "post-process ShaderMaterial assigned")


func test_hud_speed_label_present() -> void:
	var label := _scene.get_node("HUD/SpeedLabel") as Label
	assert_not_null(label, "HUD has a speed label")
	assert_string_contains(label.text, "km/h", "speed label reads in km/h")


func test_hud_car_button_present() -> void:
	# The car-selector button cycles between the CarLibrary entries.
	var button := _scene.get_node_or_null("HUD/CarButton") as Button
	assert_not_null(button, "HUD has a car-selector button")


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


func test_shaders_load_with_code() -> void:
	for path in ["res://shaders/ps1_models.gdshader", "res://shaders/ps1_post_process.gdshader", "res://shaders/billboard.gdshader"]:
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
	for action in ACTIONS:
		assert_true(InputMap.has_action(action), "action exists: " + action)


# Every gameplay action must be reachable from a controller (standard racing
# layout: triggers throttle/brake, left stick steer, bumpers shift, face buttons
# for the rest). Debug-only actions stay keyboard-only and are excluded here.
func test_gameplay_actions_have_joypad_bindings() -> void:
	var controller_actions := ACTIONS + ["handbrake"]
	for action in controller_actions:
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
	var floor := _scene.get_node("Floor") as TerrainManager
	var tex := load("res://textures/tree.png") as Texture2D
	var field := BillboardField.new()
	add_child_autofree(field)
	var positions := PackedVector2Array([Vector2(10, 10), Vector2(20, 12), Vector2(-5, 8)])
	field.build(positions, floor, Vector2(4, 6), tex, 0.5, 4.0, true, 80.0, 15.0)
	assert_not_null(field.multimesh, "field has a MultiMesh")
	assert_eq(field.multimesh.instance_count, positions.size(),
		"one instance per scattered position")
	# Collision: one box shape per tree on a StaticBody3D child.
	var body := field.get_node_or_null("Collision") as StaticBody3D
	assert_not_null(body, "with_collision builds a Collision StaticBody3D child")
	var rid := body.get_rid()
	assert_eq(PhysicsServer3D.body_get_shape_count(rid), positions.size(),
		"one box shape per tree")
	assert_eq(body.collision_layer, 1, "tree body on layer 1 like terrain")
	var p := positions[0]
	var expected_y := floor.height_at(p.x, p.y) + 4.0 / 2.0
	var origin := PhysicsServer3D.body_get_shape_transform(rid, 0).origin
	assert_almost_eq(origin, Vector3(p.x, expected_y, p.y), Vector3(1e-3, 1e-3, 1e-3),
		"box rests on the ground at the tree position")
	# Render distance is wired into the billboard material as shader params.
	var smat := field.multimesh.mesh.surface_get_material(0) as ShaderMaterial
	assert_not_null(smat, "quad has a ShaderMaterial")
	assert_eq(smat.get_shader_parameter("render_distance"), 80.0, "render_distance param set")
	assert_eq(smat.get_shader_parameter("fade_band"), 15.0, "fade_band param set")


func test_billboard_field_without_collision_has_no_body() -> void:
	var floor := _scene.get_node("Floor") as TerrainManager
	var tex := load("res://textures/bush.webp") as Texture2D
	var field := BillboardField.new()
	add_child_autofree(field)
	var positions := PackedVector2Array([Vector2(3, 4), Vector2(6, 9)])
	field.build(positions, floor, Vector2(1, 1.5), tex, 0.5, 4.0, false, 80.0, 15.0, -0.5)
	assert_eq(field.multimesh.instance_count, positions.size(),
		"bush field still renders one instance per position")
	assert_null(field.get_node_or_null("Collision"),
		"with_collision == false builds no Collision body")
	# y_offset sinks the sprite: instance Y is ground height minus the sink. Read
	# the renderer-independent instance_positions mirror — the MultiMesh transform
	# buffer lives in the RenderingServer, which is a no-op stub under --headless.
	var p := positions[0]
	var origin := field.instance_positions[0]
	assert_almost_eq(origin, Vector3(p.x, floor.height_at(p.x, p.y) - 0.5, p.y),
		Vector3(1e-3, 1e-3, 1e-3), "bush sunk into ground by the y_offset")


func test_sign_field_builds_knockable_signs_at_road_height() -> void:
	var floor := _scene.get_node("Floor") as TerrainManager
	var field := SignField.new()
	add_child_autofree(field)
	# A hand-made layout (no full track needed): one of each kind, both sides.
	var layout := [
		{"kind": "start", "texture_key": "start", "pos": Vector2(4, 6), "tangent": Vector2(0, 1), "side": 1},
		{"kind": "sector", "texture_key": "sector_2", "pos": Vector2(12, 8), "tangent": Vector2(1, 0), "side": -1},
		{"kind": "turn", "texture_key": "arrow_square_left", "pos": Vector2(-5, 9), "tangent": Vector2(0, 1), "side": 1},
	]
	field.build(layout, floor, Config.data.sign_render_params())
	assert_eq(field.sign_count, layout.size(), "one sign built per layout entry")
	assert_eq(field.get_child_count(), layout.size(), "one node per sign")
	# Each sign is a light, knockable RigidBody3D (the wet-floor-board feel).
	var sign0 := field.get_child(0) as RigidBody3D
	assert_not_null(sign0, "each sign is a RigidBody3D")
	assert_gt(sign0.mass, 0.0, "sign body has a mass")
	assert_lt(sign0.mass, 50.0, "sign is light enough for the car to scatter")
	# Spawned FROZEN so it rests exactly where placed even where terrain collision
	# isn't streamed yet (TerrainManager only loads a ring around the car) — a live
	# body would free-fall into the void before the player reached it. The car wakes
	# it on contact (test_sign_wakes_only_on_dynamic_non_self_contact).
	assert_true(sign0.freeze, "sign spawns frozen so it never free-falls off-terrain")
	# Two splayed panels + a collision shape + an Area3D waker, all children of the
	# body so the whole sign tumbles together (count directly — find_children defaults
	# to owned=true, which excludes programmatically-built nodes).
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
	assert_eq(panels, 2, "each sign has two A-frame panels")
	assert_true(has_shape, "sign body carries a collision shape")
	assert_true(has_waker, "sign carries an Area3D waker to unfreeze it on car contact")
	# Knockable cosmetic clutter: deals NO HP damage, so it is NOT a damage obstacle.
	assert_false(sign0.is_in_group(DamageModel.OBSTACLE_GROUP),
		"signs are not in the damage OBSTACLE_GROUP (no HP penalty)")
	# The sign starts at the centerline road-surface height for its position.
	var p: Vector2 = layout[0]["pos"]
	assert_almost_eq(sign0.position.y, floor.height_at(p.x, p.y), 1e-3,
		"sign sits on the road surface height")


# The frozen sign must wake (tumble) only when the dynamic car hits it — never from
# its OWN body overlapping the waker Area, nor from streamed terrain / tree hitboxes
# (StaticBody3D), or every sign would unfreeze and free-fall the instant it spawned.
func test_sign_wakes_only_on_dynamic_non_self_contact() -> void:
	var floor := _scene.get_node("Floor") as TerrainManager
	var field := SignField.new()
	add_child_autofree(field)
	field.build([{"kind": "turn", "texture_key": "arrow_2_right",
		"pos": Vector2(20, 20), "tangent": Vector2(0, 1), "side": 1}],
		floor, Config.data.sign_render_params())
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
	# A dynamic body (the car) wakes it.
	var dyn := RigidBody3D.new()
	add_child_autofree(dyn)
	field._wake_sign(dyn, sign0)
	assert_false(sign0.freeze, "a dynamic body (the car) unfreezes the sign")


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
	# world.gd places one FinishArch at the centerline END — i.e. exactly 100%
	# track progress — so crossing it ends the stage immediately.
	var arch := await _await_node("FinishArch")
	assert_not_null(arch, "world built a FinishArch at the stage end")
	if arch == null:
		return
	_assert_spans_road_upright(arch, "finish arch")
	assert_eq(arch.top_banner, "top", "finish arch wears the FINISH banner set")
	# It must sit at the end of the progress centerline (100%). Compare its XZ to the
	# centerline's far end, read off the live TrackProgress.
	var tp = _scene.get_node_or_null("TrackProgress")
	assert_not_null(tp, "TrackProgress present")
	if tp != null:
		var end2: Vector2 = tp._centerline.sample_baked(tp.baked_length())
		var here2 := Vector2(arch.global_transform.origin.x, arch.global_transform.origin.z)
		assert_lt(here2.distance_to(end2), 1.0, "finish arch sits at the centerline end (100% progress)")


func test_start_arch_straddles_the_road_at_the_start_line() -> void:
	# world.gd places a matching StartArch at the car's spawn (the start line).
	var arch := await _await_node("StartArch")
	assert_not_null(arch, "world built a StartArch at the start line")
	if arch == null:
		return
	_assert_spans_road_upright(arch, "start arch")
	assert_eq(arch.top_banner, "top_start", "start arch wears the START banner set")
	# It straddles the start line — the car's spawn, which on a dev boot is the
	# start of the progress centerline (offset 0). Compare to that rather than the
	# live car, which earlier camera tests reposition.
	var tp = _scene.get_node_or_null("TrackProgress")
	if tp != null:
		var start2: Vector2 = tp._centerline.sample_baked(0.0)
		var here2 := Vector2(arch.global_transform.origin.x, arch.global_transform.origin.z)
		assert_lt(here2.distance_to(start2), 1.0, "start arch sits at the start line (centerline offset 0)")
