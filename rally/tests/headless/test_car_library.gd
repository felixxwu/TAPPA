extends GutTest
# The selectable car roster (CarLibrary) and car.gd's apply_car/cycle_car: each
# entry must be sane, main.tscn must boot as the first car, and applying a car
# must overlay its dimensions, mass, engine character and drive layout.

const CarLibrary = preload("res://scripts/car_library.gd")
const SceneHelpers = preload("res://tests/headless/scene_helpers.gd")

var _scene: Node3D
var _car: VehicleBody3D


func before_each() -> void:
	# These tests inspect the car roster + apply_car/cycle_car, not the track or
	# its foliage, so boot a minimal world (~15s -> <1s per instance). minimal_world
	# resets Config to baseline first, exactly as the old Config.reset() did.
	SceneHelpers.minimal_world()
	_scene = load("res://main.tscn").instantiate()
	add_child_autofree(_scene)
	_car = _scene.get_node("Car")
	await get_tree().physics_frame  # let _ready() + world.apply_car(0) run


func after_each() -> void:
	Config.reset()  # don't leak a car selection into other test files


func test_library_has_a_range_of_cars() -> void:
	assert_gte(CarLibrary.CARS.size(), 4, "a decent selection of cars")
	var names := {}
	var engines := {}
	for spec in CarLibrary.CARS:
		names[spec["name"]] = true
		engines[spec["engine_type"]] = true
	assert_eq(names.size(), CarLibrary.CARS.size(), "car names are unique")
	# "Mix up the engine sound": at least a few distinct engine presets in use.
	assert_gte(engines.size(), 4, "a range of engine types / sounds")


func test_each_spec_is_sane() -> void:
	for spec in CarLibrary.CARS:
		var who: String = spec["name"]
		assert_gt(spec["mass"], 0.0, who + " has positive mass")
		assert_gt(spec["peak_torque"], 0.0, who + " has positive power (peak_torque)")
		# Redline must sit above where the engine preset peaks torque, or the
		# torque curve inverts. Presets peak by ~6000 rpm, so 6500 is a safe floor.
		assert_gt(spec["redline"], 6500.0, who + " has a sane redline")
		assert_between(spec["grip_front"], 0.1, 2.0, who + " front grip in a sane range")
		assert_between(spec["grip_rear"], 0.1, 2.0, who + " rear grip in a sane range")
		assert_between(spec["engine_type"], 0, GameConfig.ENGINE_PRESETS.size() - 1,
			who + " engine_type indexes a real preset")
		assert_between(spec["drive_mode"], 0, 2, who + " drive_mode is RWD/AWD/FWD")
		assert_gt(spec["drag"], 0.0, who + " has drag")
		assert_gt(spec.get("downforce_rear", 0.0), 0.0, who + " carries some rear downforce")
		assert_between(spec.get("downforce_rear", 0.0), 0.0, 2.0, who + " rear downforce in a sane range")
		for axis in ["x", "y", "z"]:
			assert_gt(spec["body"][axis], 0.0, who + " body." + axis + " positive")
			assert_gt(spec["cabin"][axis], 0.0, who + " cabin." + axis + " positive")
		assert_gt(spec["track"], 0.0, who + " track positive")
		assert_gt(spec["wheelbase"], 0.0, who + " wheelbase positive")
		assert_gt(spec["wheel_radius"], 0.0, who + " wheel_radius positive")
		assert_gt(spec["wheel_width"], 0.0, who + " wheel_width positive")
		# Suspension: travel doubles as the wheel raycast length (must clear the
		# wheel radius so the ray reaches the ground), stiffness in the export range.
		assert_gt(spec["suspension_travel"], spec["wheel_radius"], who + " spring travel clears wheel radius")
		assert_between(spec["suspension_stiffness"], 0.1, 50.0, who + " spring stiffness in a sane range")
		assert_between(spec["low_octave_mix"], 0.0, 1.0, who + " low_octave_mix is a 0..1 blend")
		# Upper bound covers the deliberately loud cars (V8/V10/V12 sit at +7..+10);
		# the per-voice level is tamed downstream by the soft clipper, so a positive
		# dB here is intentional, not a mixing error.
		assert_between(spec["volume_db"], -60.0, 12.0, who + " volume_db in a sane dB range")
		# The track must fit inside the body width or wheels poke out absurdly.
		assert_lte(spec["track"], spec["body"]["x"] + 0.1, who + " track within body width")
		# Persistence + progression metadata (see save-persistence.md).
		assert_true(spec["id"] is String and not spec["id"].is_empty(), who + " has a stable string id")
		assert_true(spec["country"] is String and not spec["country"].is_empty(), who + " has a country tag")
		assert_true(spec["car_type"] is String and not spec["car_type"].is_empty(), who + " has a car_type tag")
		assert_gt(spec["max_hp"], 0.0, who + " has positive max_hp")
		assert_gt(spec["reward_tier"], 0, who + " has a reward_tier")


func test_car_ids_are_unique_and_stable_lookups_work() -> void:
	var ids := {}
	for spec in CarLibrary.CARS:
		assert_false(ids.has(spec["id"]), "id '%s' is unique" % spec["id"])
		ids[spec["id"]] = true
	# index_of / by_id resolve a stable id to the current array position.
	for i in CarLibrary.CARS.size():
		var id: String = CarLibrary.CARS[i]["id"]
		assert_eq(CarLibrary.index_of(id), i, "index_of('%s') resolves to %d" % [id, i])
		assert_eq(CarLibrary.by_id(id)["name"], CarLibrary.CARS[i]["name"], "by_id('%s') returns the entry" % id)
	# Unknown ids degrade safely (the save system drops orphaned entries).
	assert_eq(CarLibrary.index_of("nope"), -1, "unknown id -> -1")
	assert_true(CarLibrary.by_id("nope").is_empty(), "unknown id -> empty dict")


func test_power_to_weight_ranks_cars() -> void:
	# The heuristic is relative-only, but the Aventador must out-rank the MX-5.
	var mx5 := CarLibrary.by_id("mx5")
	var aventador := CarLibrary.by_id("aventador")
	assert_gt(CarLibrary.power_to_weight(aventador), CarLibrary.power_to_weight(mx5),
		"Aventador has a higher power-to-weight than the MX-5")


func test_main_boots_as_first_car() -> void:
	var first: Dictionary = CarLibrary.CARS[0]
	assert_eq(_car.current_car_name(), first["name"], "main.tscn boots as the first car")
	assert_almost_eq(Config.data.mass, first["mass"], 0.001, "config mass is the first car's")
	var size: Vector3 = (_car.get_node("Chassis").mesh as BoxMesh).size
	assert_eq(size, first["body"], "chassis box sized to the first car")
	assert_eq(_scene.get_node("HUD/CarButton").text, first["name"], "car button shows the car name")


func test_apply_car_overlays_dimensions_mass_engine_and_drive() -> void:
	# Pick the Ford Mustang GT: a V8, RWD, with distinct dimensions from the MX-5.
	var index := _index_of("Ford Mustang GT")
	var spec: Dictionary = CarLibrary.CARS[index]
	var returned: String = _car.apply_car(index)
	await get_tree().physics_frame
	assert_eq(returned, spec["name"], "apply_car returns the car name")
	assert_eq(_car.current_car_name(), spec["name"], "current car updated")

	assert_almost_eq(_car.mass, float(spec["mass"]), 0.001, "rigidbody mass overlaid")
	assert_almost_eq(Config.data.mass, float(spec["mass"]), 0.001, "config mass overlaid")
	assert_almost_eq(Config.data.wheel_radius, float(spec["wheel_radius"]), 0.001, "wheel_radius overlaid")
	# engine_type drives the sound + power preset (a V8 = 8 cylinders).
	assert_eq(Config.data.engine_type, spec["engine_type"], "engine_type overlaid")
	assert_eq(Config.data.engine_cylinders, 8, "V8 preset applied (8 cylinders)")
	# Power overrides the engine preset's torque; grip overlays tyre friction.
	assert_almost_eq(Config.data.peak_torque, float(spec["peak_torque"]), 0.001, "power (peak_torque) overlaid")
	assert_almost_eq(Config.data.redline_rpm, float(spec["redline"]), 0.001, "redline overlaid")
	assert_almost_eq(Config.data.wheel_friction_slip_front, float(spec["grip_front"]), 0.001, "front grip overlaid")
	assert_almost_eq(Config.data.wheel_friction_slip_rear, float(spec["grip_rear"]), 0.001, "rear grip overlaid")
	assert_eq(_car.drivetrain.drive_mode, spec["drive_mode"] as int, "drive layout overlaid")
	assert_almost_eq(Config.data.engine_low_octave_mix, float(spec["low_octave_mix"]), 0.001,
		"low_octave_mix overlaid")
	assert_almost_eq(Config.data.engine_volume_db, float(spec["volume_db"]), 0.001,
		"volume_db overlaid")

	# Geometry: chassis box + wheel positions follow the spec.
	assert_eq((_car.get_node("Chassis").mesh as BoxMesh).size, spec["body"], "chassis resized")
	var half_track: float = float(spec["track"]) * 0.5
	var half_base: float = float(spec["wheelbase"]) * 0.5
	var fl: VehicleWheel3D = _car.get_node("WheelFL")
	var rr: VehicleWheel3D = _car.get_node("WheelRR")
	assert_almost_eq(absf(fl.position.x), half_track, 0.001, "front-left at half track")
	assert_almost_eq(absf(fl.position.z), half_base, 0.001, "front-left at half wheelbase")
	assert_almost_eq(absf(rr.position.x), half_track, 0.001, "rear-right at half track")
	assert_almost_eq(fl.wheel_radius, float(spec["wheel_radius"]), 0.001, "wheel physics radius set")
	# Front wheels still steer, rears still drive after the rebuild.
	assert_true(fl.use_as_steering, "front wheel still steers after swap")
	assert_true(rr.use_as_traction, "rear wheel still drives after swap")

	# The LFA is the one car that blends the octave-lower voice in.
	_car.apply_car(_index_of("Lexus LFA"))
	await get_tree().physics_frame
	assert_almost_eq(Config.data.engine_low_octave_mix, 0.5, 0.001, "LFA applies a 50/50 low octave")


func test_cycle_car_advances_and_wraps() -> void:
	# The HUD button drives World.cycle_car(), which re-instantiates the car and
	# re-points the camera/HUD. Boots on car 0; cycling N times returns to car 0.
	var n := CarLibrary.CARS.size()
	for i in range(1, n):
		_scene.cycle_car()
		var car: VehicleBody3D = _scene.get_node("Car")
		assert_eq(car.current_car_name(), CarLibrary.CARS[i]["name"], "cycle advances to car %d" % i)
		assert_eq((_scene.get_node("ChaseCamera") as Camera3D).target, car,
			"camera re-points at the new car")
	_scene.cycle_car()
	assert_eq((_scene.get_node("Car") as VehicleBody3D).current_car_name(),
		CarLibrary.CARS[0]["name"], "cycle wraps back to the first car")


func test_mx5_renders_the_authored_model_others_render_boxes() -> void:
	# Only the MX-5 carries the use_model flag.
	var flagged := 0
	for spec in CarLibrary.CARS:
		if spec.get("use_model", false):
			flagged += 1
			assert_eq(spec["name"], "Mazda MX-5", "use_model is the MX-5's flag")
	assert_eq(flagged, 1, "exactly one car uses the authored model")

	# The model node exists and instances the glb body.
	var model: Node3D = _car.get_node("Mx5Body")
	assert_not_null(model, "Car has the Mx5Body model node")
	assert_gt(model.find_children("*", "MeshInstance3D", true).size(), 0,
		"Mx5Body instances at least one mesh")

	# Booted as the MX-5: model shown, procedural boxes hidden.
	assert_true(model.visible, "MX-5 shows the authored body model")
	assert_false((_car.get_node("Chassis") as MeshInstance3D).visible, "MX-5 hides the chassis box")
	assert_false((_car.get_node("Cabin") as MeshInstance3D).visible, "MX-5 hides the cabin box")
	# The model's mesh wears the PS1 shader material carrying the baked texture
	# (white tint so the texture's own colours show through).
	var mi: MeshInstance3D = model.find_children("*", "MeshInstance3D", true)[0]
	var mat := mi.get_surface_override_material(0) as ShaderMaterial
	assert_not_null(mat, "model mesh has a shader material override")
	assert_eq(mat.shader, load("res://shaders/ps1_models_lit.gdshader"), "model uses the lit PS1 model shader")
	assert_eq(mat.get_shader_parameter("albedo_color"), Color.WHITE, "model texture shown untinted")
	assert_not_null(mat.get_shader_parameter("albedo_texture"), "model carries its baked texture")

	# A box car (Mustang) does the reverse: model hidden, boxes shown.
	_car.apply_car(_index_of("Ford Mustang GT"))
	await get_tree().physics_frame
	assert_false(model.visible, "box car hides the authored model")
	assert_true((_car.get_node("Chassis") as MeshInstance3D).visible, "box car shows the chassis box")
	assert_true((_car.get_node("Cabin") as MeshInstance3D).visible, "box car shows the cabin box")


# A parked (frozen) car bakes its fake per-vertex lighting into the mesh vertex
# colours and switches the live shader calc off, so the shader stops recomputing
# the shading every frame (see car.gd bake_shading / ps1_models_lit.gdshader).
func test_bake_shading_freezes_lighting_into_vertex_colours() -> void:
	_car.apply_car(_index_of("Ford Mustang GT"))  # box car: simple single-surface meshes
	await get_tree().physics_frame
	var lit := load("res://shaders/ps1_models_lit.gdshader")
	var chassis := _car.get_node("Chassis") as MeshInstance3D
	var shared_mat := chassis.get_surface_override_material(0) as ShaderMaterial
	var original_mesh := chassis.mesh
	# Before baking, the chassis box carries no per-vertex colour (the shader lights
	# it live) and the material runs the full effect.
	assert_eq(shared_mat.get_shader_parameter("light_amount"), Config.data.car_light_amount,
		"live car runs the full per-vertex lighting")

	_car.bake_shading()

	# The mesh is now a baked copy whose vertex COLOUR carries the shading.
	assert_ne(chassis.mesh, original_mesh, "baking swaps in a baked mesh copy")
	var colors: PackedColorArray = chassis.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	assert_gt(colors.size(), 0, "baked mesh carries per-vertex colours")
	var any_shaded := false
	for c in colors:
		if c.r < 0.99 or c.g < 0.99 or c.b < 0.99:
			any_shaded = true
	assert_true(any_shaded, "baked colours actually carry shading, not flat white")
	# The live calc is switched off on a PER-INSTANCE material copy...
	var flat := chassis.get_surface_override_material(0) as ShaderMaterial
	assert_eq(flat.shader, lit, "baked mesh keeps the lit shader (now light_amount 0)")
	assert_eq(flat.get_shader_parameter("light_amount"), 0.0, "frozen car skips the live lighting")
	assert_ne(flat, shared_mat, "baking uses a per-instance material copy")
	# ...so the shared sub-resource (and therefore the player's live car) is untouched.
	assert_eq(shared_mat.get_shader_parameter("light_amount"), Config.data.car_light_amount,
		"baking one car must not disturb the shared material's live lighting")


# Baking is reversible: restore_shading puts the original mesh + shared material
# back so the live lighting resumes (e.g. if a parked car ever goes live again).
func test_restore_shading_reverts_the_bake() -> void:
	_car.apply_car(_index_of("Ford Mustang GT"))
	await get_tree().physics_frame
	var chassis := _car.get_node("Chassis") as MeshInstance3D
	var original_mesh := chassis.mesh
	var original_mat := chassis.get_surface_override_material(0)

	_car.bake_shading()
	_car.restore_shading()

	assert_eq(chassis.mesh, original_mesh, "restore puts the original mesh back")
	assert_eq(chassis.get_surface_override_material(0), original_mat,
		"restore puts the shared live material back")


func _index_of(car_name: String) -> int:
	for i in CarLibrary.CARS.size():
		if CarLibrary.CARS[i]["name"] == car_name:
			return i
	fail_test("car not found: " + car_name)
	return 0
