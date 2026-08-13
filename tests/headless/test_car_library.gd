extends GutTest
# The selectable car roster (CarLibrary) and car.gd's apply_car: each
# entry must be sane, main.tscn must boot as the first car, and applying a car
# must overlay its dimensions, mass, engine character and drive layout.

const SceneHelpers = preload("res://tests/headless/scene_helpers.gd")

var _scene: Node3D
var _car: VehicleBody3D


func before_each() -> void:
	# These tests inspect the car roster + apply_car, not the track or
	# its foliage, so boot a minimal world (~15s -> <1s per instance). minimal_world
	# resets Config to baseline first, exactly as the old Config.reset() did.
	# NB: a shared before_all instance is NOT safe here — several tests flip the roster
	# to CarFixtures mid-test and rely on world.gd re-applying the freshly-built car,
	# so a per-test build is the clean way.
	CarLibrary.reset()
	EngineLibrary.reset()  # guard against a leaked override from another test file
	UpgradeFixtures.install()
	SceneHelpers.minimal_world()
	_scene = load("res://main.tscn").instantiate()
	add_child_autofree(_scene)
	_car = _scene.get_node("Car")
	await get_tree().physics_frame  # let _ready() + world.apply_car(0) run


func after_each() -> void:
	Config.reset()  # don't leak a car selection into other test files
	CarFixtures.restore()
	UpgradeFixtures.restore()


func test_main_boots_as_first_car() -> void:
	var first: Dictionary = CarLibrary.CARS[0]
	assert_eq(_car.current_car_name(), first["name"], "main.tscn boots as the first car")
	assert_almost_eq(Config.data.mass, first["mass"], 0.001, "config mass is the first car's")
	var size: Vector3 = (_car.get_node("Chassis").mesh as BoxMesh).size
	assert_eq(size, first["body"], "chassis box sized to the first car")


func test_apply_car_overlays_dimensions_mass_engine_and_drive() -> void:
	# Pick the Fixture Coupe: a V8, RWD, with distinct dimensions from the Fixture Roadster.
	CarFixtures.install()
	var index := CarLibrary.index_of("fx_rwd_coupe")
	var spec: Dictionary = CarLibrary.all()[index]
	var returned: String = _car.apply_car(index)
	await get_tree().physics_frame
	assert_eq(returned, spec["name"], "apply_car returns the car name")
	assert_eq(_car.current_car_name(), spec["name"], "current car updated")

	assert_almost_eq(_car.mass, float(spec["mass"]), 0.001, "rigidbody mass overlaid")
	assert_almost_eq(Config.data.mass, float(spec["mass"]), 0.001, "config mass overlaid")
	assert_almost_eq(Config.data.wheel_radius, float(spec["wheel_radius"]), 0.001, "wheel_radius overlaid")
	# The car's referenced engine drives the sound + power (a V8 = 8 cylinders).
	var eng := EngineLibrary.by_id(spec["engine"])
	assert_eq(Config.data.engine_cylinders, EngineLibrary.FIRING[eng["layout"]].size(), "cylinders overlaid")
	assert_almost_eq(Config.data.peak_torque, float(eng["peak_torque"]), 0.001, "peak_torque overlaid")
	assert_almost_eq(Config.data.redline_rpm, float(eng["redline_rpm"]), 0.001, "redline overlaid")
	assert_almost_eq(Config.data.engine_inertia, float(eng["engine_inertia"]), 0.001, "engine_inertia overlaid")
	# The engine's transmission (gear_ratios / final_drive) is overlaid onto the live
	# config via EngineLibrary.apply — so a swapped engine would bring its own box.
	assert_eq(Config.data.gear_ratios.size(), (eng["gear_ratios"] as Array).size(),
		"gear count overlaid from the engine")
	for g in Config.data.gear_ratios.size():
		assert_almost_eq(Config.data.gear_ratios[g], float(eng["gear_ratios"][g]), 0.001,
			"gear %d ratio overlaid from the engine" % (g + 1))
	assert_almost_eq(Config.data.final_drive, float(eng["final_drive"]), 0.001, "final_drive overlaid from the engine")
	# The drivetrain's engine recomputed its shift speeds for the new gearing, so it
	# has one upshift slot per gear (the top gear's is INF).
	assert_eq(_car.drivetrain.engine.shift_up_speeds.size(), (eng["gear_ratios"] as Array).size(),
		"shift speeds recomputed for the new gear count")
	# Both axle μ are seeded from the car's single tyre compound; widths overlaid per axle.
	assert_almost_eq(Config.data.wheel_friction_slip_front, float(spec["tire_compound"]), 0.001, "front grip seeded from compound")
	assert_almost_eq(Config.data.wheel_friction_slip_rear, float(spec["tire_compound"]), 0.001, "rear grip seeded from compound")
	assert_almost_eq(Config.data.wheel_width_front, float(spec["wheel_width_front"]), 0.001, "front tyre width overlaid")
	assert_almost_eq(Config.data.wheel_width_rear, float(spec["wheel_width_rear"]), 0.001, "rear tyre width overlaid")
	assert_eq(_car.drivetrain.drive_mode, spec["drive_mode"] as int, "drive layout overlaid")

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

	# apply_car copies the applied car's engine low_octave_mix onto the live audio config.
	var hatch := CarLibrary.by_id("fx_fwd_hatch")
	var hatch_engine := EngineLibrary.by_id(String(hatch["engine"]))
	_car.apply_car(CarLibrary.index_of("fx_fwd_hatch"))
	await get_tree().physics_frame
	assert_almost_eq(Config.data.engine_low_octave_mix, float(hatch_engine["low_octave_mix"]), 0.001,
		"apply_car copies the car engine's low octave mix onto the config")


func test_apply_owned_weight_reduction_relightens_the_rigidbody() -> void:
	# apply_car sets the RigidBody mass from the spec; apply_owned then runs the
	# installed upgrades, so a weight-reduction upgrade must flow through to both
	# the live config AND the physics body (apply_owned re-syncs car.mass after it).
	CarFixtures.install()
	var spec := CarLibrary.by_id("fx_light_rwd")
	var base_mass: float = float(spec["mass"])
	# Derive the multiplier from the catalogue rather than pinning the tuned value.
	var mult: float = float(UpgradeLibrary.by_id("fx_lightweight")["effect"]["mass_mult"])
	_car.apply_owned({"model_id": "fx_light_rwd", "installed_upgrades": ["fx_lightweight"],
		"hp": float(spec.get("max_hp", 100.0)), "instance_id": -1})
	await get_tree().physics_frame
	assert_almost_eq(Config.data.mass, base_mass * mult, 0.001, "config mass scaled by the kit")
	assert_almost_eq(_car.mass, base_mass * mult, 0.001, "rigidbody mass re-synced to the lighter config")


func test_apply_owned_applies_drivetrain_override() -> void:
	CarFixtures.install()
	_car.apply_owned({"model_id": "fx_light_rwd", "installed_upgrades": ["fx_drivetrain"],
		"disabled_upgrades": [], "drivetrain_override": Drivetrain.DriveMode.AWD})
	assert_eq(_car.drivetrain.drive_mode, Drivetrain.DriveMode.AWD, "override fielded onto the drivetrain")


func test_apply_owned_ignores_override_without_kit() -> void:
	CarFixtures.install()
	_car.apply_owned({"model_id": "fx_light_rwd", "installed_upgrades": [],
		"disabled_upgrades": [], "drivetrain_override": Drivetrain.DriveMode.AWD})
	assert_eq(_car.drivetrain.drive_mode, Drivetrain.DriveMode.RWD, "stays stock RWD without the kit")


func test_mx5_renders_the_authored_model_others_render_boxes() -> void:
	# Feature contract, expressed generically off each spec's own use_model flag
	# rather than a hardcoded list of which ids are model cars: every use_model
	# car names a model_node + model_texture, shows its model and hides the
	# procedural boxes; every non-model car does the reverse.
	var model_spec: Dictionary = {}
	for spec in CarLibrary.CARS:
		if spec.get("use_model", false):
			assert_ne(String(spec.get("model_node", "")), "", spec["name"] + " names its model_node")
			assert_ne(String(spec.get("model_texture", "")), "", spec["name"] + " names its model_texture")
			if model_spec.is_empty():
				model_spec = spec
	assert_false(model_spec.is_empty(), "at least one car in the roster uses an authored model")

	# The model node exists and instances the glb body.
	_car.apply_car(CarLibrary.index_of(model_spec["id"]))
	await get_tree().physics_frame
	var model_node_name: String = model_spec["model_node"]
	var model: Node3D = _car.get_node(model_node_name)
	assert_not_null(model, "Car has the %s model node" % model_node_name)
	assert_gt(model.find_children("*", "MeshInstance3D", true).size(), 0,
		"%s instances at least one mesh" % model_node_name)

	# Booted as the model car: model shown, procedural boxes hidden.
	assert_true(model.visible, "%s shows the authored body model" % model_spec["name"])
	assert_false((_car.get_node("Chassis") as MeshInstance3D).visible, "model car hides the chassis box")
	assert_false((_car.get_node("Cabin") as MeshInstance3D).visible, "model car hides the cabin box")
	# The model's mesh wears the PS1 shader material carrying the baked texture
	# (white tint so the texture's own colours show through).
	var mi: MeshInstance3D = model.find_children("*", "MeshInstance3D", true)[0]
	var mat := mi.get_surface_override_material(0) as ShaderMaterial
	assert_not_null(mat, "model mesh has a shader material override")
	assert_eq(mat.shader, load("res://shaders/ps1_models_lit.gdshader"), "model uses the lit PS1 model shader")
	assert_eq(mat.get_shader_parameter("albedo_color"), Color.WHITE, "model texture shown untinted")
	assert_not_null(mat.get_shader_parameter("albedo_texture"), "model carries its baked texture")

	# The procedural-box fallback does the reverse: model hidden, boxes shown.
	# The shipped roster is all authored-model cars, so drive the fallback path
	# directly with a synthetic no-model spec rather than depending on a box car
	# existing in the catalogue.
	_car._apply_model_visibility({"use_model": false})
	await get_tree().physics_frame
	assert_false(model.visible, "box car hides the authored model")
	assert_true((_car.get_node("Chassis") as MeshInstance3D).visible, "box car shows the chassis box")
	assert_true((_car.get_node("Cabin") as MeshInstance3D).visible, "box car shows the cabin box")


func test_model_car_collision_hull_matches_its_body() -> void:
	# Generic contract for every authored-model car: the chassis collision hull's
	# bounding extents track the spec's own `body` dims (z matches, y sits 0.3 below),
	# and applying a car shows ITS model node and hides every other car's.
	var model_nodes := {}
	for spec in CarLibrary.CARS:
		if spec.get("use_model", false):
			model_nodes[String(spec["model_node"])] = true
	assert_false(model_nodes.is_empty(), "roster has at least one authored-model car")
	for i in CarLibrary.CARS.size():
		var spec: Dictionary = CarLibrary.CARS[i]
		if not spec.get("use_model", false):
			continue
		var who: String = spec["name"]
		_car.apply_car(i)
		# The hull is a chamfered octagon; its bounding extents still track the body.
		var extents := _chassis_hull_extents()
		var body: Vector3 = spec["body"]
		assert_almost_eq(extents.z, body.z, 0.01, who + ": hull depth matches body")
		assert_almost_eq(extents.y, body.y - 0.3, 0.01, who + ": hull height matches body")
		for node_name in model_nodes:
			var node := _car.get_node_or_null(NodePath(node_name)) as Node3D
			assert_not_null(node, "Car has the %s model node" % node_name)
			if node_name == String(spec["model_node"]):
				assert_true(node.visible, "%s: %s shown" % [who, node_name])
			else:
				assert_false(node.visible, "%s: %s hidden" % [who, node_name])


# Bounding extents of the chassis collision hull (a chamfered octagon) — the
# mid-edge points still reach every box face, so the AABB equals the box dims.
func _chassis_hull_extents() -> Vector3:
	var hull := (_car.get_node("CollisionShape3D") as CollisionShape3D).shape as ConvexPolygonShape3D
	var aabb := AABB(hull.points[0], Vector3.ZERO)
	for p in hull.points:
		aabb = aabb.expand(p)
	return aabb.size
