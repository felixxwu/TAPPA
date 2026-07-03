extends GutTest
# The selectable car roster (CarLibrary) and car.gd's apply_car/cycle_car: each
# entry must be sane, main.tscn must boot as the first car, and applying a car
# must overlay its dimensions, mass, engine character and drive layout.

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
	assert_gt(CarLibrary.CARS.size(), 1, "more than one car — a roster, not a single car")
	var names := {}
	var engines := {}
	for spec in CarLibrary.CARS:
		names[spec["name"]] = true
		engines[spec["engine"]] = true
	assert_eq(names.size(), CarLibrary.CARS.size(), "car names are unique")
	# "Mix up the engine sound": at least a few distinct engine presets in use.
	assert_gte(engines.size(), 4, "a range of engine types / sounds")


func test_each_spec_is_sane() -> void:
	for spec in CarLibrary.CARS:
		var who: String = spec["name"]
		assert_gt(spec["mass"], 0.0, who + " has positive mass")
		# The gearbox (gear_ratios / final_drive / shift_time) now lives on the ENGINE
		# (EngineLibrary), not the car — its sanity is checked in test_engine_library.gd.
		assert_true(spec.has("engine"), who + " names an engine")
		assert_gt(spec["tire_compound"], 0.0, who + " tyre compound is positive")
		assert_false(EngineLibrary.by_id(spec["engine"]).is_empty(), who + " engine id resolves")
		assert_between(spec["drive_mode"], 0, 2, who + " drive_mode is RWD/AWD/FWD")
		# drag is NOT asserted: it's a per-car tuning knob and 0 is valid (slippery
		# bodies whose engine baseline already meets their real top-speed resistance
		# need no top-up drag — see CarLibrary's drag note). Pinning drag > 0 pins a
		# tunable value, which the project's testing rules forbid.
		# Downforce is a tuning knob, not an invariant (0 = no wing is valid).
		assert_gte(spec.get("downforce_rear", 0.0), 0.0, who + " rear downforce is non-negative")
		for axis in ["x", "y", "z"]:
			assert_gt(spec["body"][axis], 0.0, who + " body." + axis + " positive")
			assert_gt(spec["cabin"][axis], 0.0, who + " cabin." + axis + " positive")
		assert_gt(spec["track"], 0.0, who + " track positive")
		assert_gt(spec["wheelbase"], 0.0, who + " wheelbase positive")
		assert_gt(spec["wheel_radius"], 0.0, who + " wheel_radius positive")
		assert_gt(spec["wheel_width_front"], 0.0, who + " front tyre width positive")
		assert_gt(spec["wheel_width_rear"], 0.0, who + " rear tyre width positive")
		# Suspension: travel doubles as the wheel raycast length (must clear the
		# wheel radius so the ray reaches the ground), stiffness in the export range.
		assert_gt(spec["suspension_travel"], spec["wheel_radius"], who + " spring travel clears wheel radius")
		assert_gt(spec["suspension_stiffness"], 0.0, who + " spring stiffness is positive")
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




# A square-tyre, 50/50 car whose per-wheel load sits exactly at the reference pressure
# reads back its compound as-is (load factor = 1.0). Verifies the stat is anchored on
# the compound, not some hidden scale.
func test_max_lateral_g_returns_compound_at_reference_load() -> void:
	var cfg := GameConfig.new()
	# Pick a mass so each of 4 wheels carries exactly ref_pressure × width.
	var width := 0.225
	var per_wheel := cfg.tire_ref_pressure * width          # load that gives factor 1.0
	var mass := per_wheel * 4.0 / (CarLibrary._G)           # 50/50 -> equal on all wheels
	var entry := {"tire_compound": 1.0, "mass": mass, "weight_front": 0.5,
		"wheel_width_front": width, "wheel_width_rear": width}
	assert_almost_eq(CarLibrary.max_lateral_g(entry, cfg), 1.0, 0.0001,
		"at reference pressure the G equals the compound")


func test_max_lateral_g_scales_with_compound() -> void:
	# The stat must be monotonic in the rubber compound, all else equal.
	var cfg := GameConfig.new()
	var base := {"mass": 1200.0, "weight_front": 0.5, "wheel_width_front": 0.225, "wheel_width_rear": 0.225}
	var grippy := base.duplicate(); grippy["tire_compound"] = 1.3
	var hard := base.duplicate(); hard["tire_compound"] = 0.85
	assert_gt(CarLibrary.max_lateral_g(grippy, cfg), CarLibrary.max_lateral_g(hard, cfg),
		"stickier compound -> higher lateral G")


func test_max_lateral_g_drops_with_mass_and_recovers_with_width() -> void:
	# Load sensitivity: adding mass on the same tyres lowers G; widening the tyres
	# raises it back. This is the whole point of the accurate-deep model.
	var cfg := GameConfig.new()
	var light := {"tire_compound": 1.0, "mass": 900.0, "weight_front": 0.5,
		"wheel_width_front": 0.225, "wheel_width_rear": 0.225}
	var heavy := light.duplicate(); heavy["mass"] = 1800.0
	var heavy_wide := heavy.duplicate()
	heavy_wide["wheel_width_front"] = 0.315; heavy_wide["wheel_width_rear"] = 0.315
	assert_lt(CarLibrary.max_lateral_g(heavy, cfg), CarLibrary.max_lateral_g(light, cfg),
		"more mass on the same tyres -> less grip")
	assert_gt(CarLibrary.max_lateral_g(heavy_wide, cfg), CarLibrary.max_lateral_g(heavy, cfg),
		"wider tyres recover grip lost to mass")


func test_tire_load_factor_is_neutral_when_sensitivity_is_zero() -> void:
	# With the effect disabled the factor is exactly 1.0 for any load/width.
	var cfg := GameConfig.new()
	cfg.tire_load_sensitivity = 0.0
	assert_almost_eq(cfg.tire_load_factor(5000.0, 0.2), 1.0, 0.0001, "k=0 -> no load effect")
	# And a degenerate (zero/negative) load or width is safely neutral, never a divide blow-up.
	assert_eq(cfg.tire_load_factor(0.0, 0.2), 1.0, "zero load -> neutral")
	assert_eq(cfg.tire_load_factor(5000.0, 0.0), 1.0, "zero width -> neutral")


func test_main_boots_as_first_car() -> void:
	var first: Dictionary = CarLibrary.CARS[0]
	assert_eq(_car.current_car_name(), first["name"], "main.tscn boots as the first car")
	assert_almost_eq(Config.data.mass, first["mass"], 0.001, "config mass is the first car's")
	var size: Vector3 = (_car.get_node("Chassis").mesh as BoxMesh).size
	assert_eq(size, first["body"], "chassis box sized to the first car")


func test_apply_car_overlays_dimensions_mass_engine_and_drive() -> void:
	# Pick the Charger R/T: a V8, RWD, with distinct dimensions from the MX-5.
	var index := _index_of("Charger R/T")
	var spec: Dictionary = CarLibrary.CARS[index]
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

	# The LFA is the one car that blends the octave-lower voice in.
	_car.apply_car(_index_of("Lexus LFA"))
	await get_tree().physics_frame
	assert_almost_eq(Config.data.engine_low_octave_mix, 0.5, 0.001, "LFA applies a 50/50 low octave")


func test_apply_owned_weight_reduction_relightens_the_rigidbody() -> void:
	# apply_car sets the RigidBody mass from the spec; apply_owned then runs the
	# installed upgrades, so a weight-reduction upgrade must flow through to both
	# the live config AND the physics body (apply_owned re-syncs car.mass after it).
	var spec := CarLibrary.by_id("mx5")
	var base_mass: float = float(spec["mass"])
	_car.apply_owned({"model_id": "mx5", "installed_upgrades": ["weight_reduction"],
		"hp": float(spec.get("max_hp", 100.0)), "instance_id": -1})
	await get_tree().physics_frame
	assert_almost_eq(Config.data.mass, base_mass * 0.90, 0.001, "config mass cut 10% by the kit")
	assert_almost_eq(_car.mass, base_mass * 0.90, 0.001, "rigidbody mass re-synced to the lighter config")


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
	# Feature contract, expressed generically off each spec's own use_model flag
	# rather than a hardcoded list of which ids are model cars: every use_model
	# car names a model_node + model_texture, shows its model and hides the
	# procedural boxes; every non-model car does the reverse.
	var model_spec: Dictionary = {}
	var box_spec: Dictionary = {}
	for spec in CarLibrary.CARS:
		if spec.get("use_model", false):
			assert_ne(String(spec.get("model_node", "")), "", spec["name"] + " names its model_node")
			assert_ne(String(spec.get("model_texture", "")), "", spec["name"] + " names its model_texture")
			if model_spec.is_empty():
				model_spec = spec
		else:
			if box_spec.is_empty():
				box_spec = spec
	assert_false(model_spec.is_empty(), "at least one car in the roster uses an authored model")
	assert_false(box_spec.is_empty(), "at least one car in the roster uses procedural boxes")

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

	# A box car does the reverse: model hidden, boxes shown.
	_car.apply_car(CarLibrary.index_of(box_spec["id"]))
	await get_tree().physics_frame
	assert_false(model.visible, "box car hides the authored model")
	assert_true((_car.get_node("Chassis") as MeshInstance3D).visible, "box car shows the chassis box")
	assert_true((_car.get_node("Cabin") as MeshInstance3D).visible, "box car shows the cabin box")


func _index_of(car_name: String) -> int:
	for i in CarLibrary.CARS.size():
		if CarLibrary.CARS[i]["name"] == car_name:
			return i
	fail_test("car not found: " + car_name)
	return 0


func test_focus_is_a_fwd_model_car() -> void:
	var i := CarLibrary.index_of("focus")
	assert_gte(i, 0, "Focus is in the roster")
	var spec := CarLibrary.CARS[i]
	assert_true(spec.get("use_model", false), "Focus uses an authored body")
	assert_eq(String(spec.get("model_node", "")), "FocusBody")
	assert_true(spec.has("wheel_texture"), "Focus has its own wheel texture")


func test_focus_collision_box_matches_body() -> void:
	_car.apply_car(CarLibrary.index_of("focus"))
	var shape := (_car.get_node("CollisionShape3D") as CollisionShape3D).shape as BoxShape3D
	var body: Vector3 = CarLibrary.CARS[CarLibrary.index_of("focus")]["body"]
	assert_almost_eq(shape.size.z, body.z, 0.01)
	assert_almost_eq(shape.size.y, body.y - 0.3, 0.01)
	assert_true((_car.get_node("FocusBody") as Node3D).visible, "FocusBody shown")
	assert_false((_car.get_node("Mx5Body") as Node3D).visible, "Mx5Body hidden for the Focus")


func test_twingo_is_a_fwd_model_car() -> void:
	var i := CarLibrary.index_of("twingo")
	assert_gte(i, 0, "Twingo is in the roster")
	var spec := CarLibrary.CARS[i]
	assert_true(spec.get("use_model", false), "Twingo uses an authored body")
	assert_eq(String(spec.get("model_node", "")), "TwingoBody")
	assert_true(spec.has("wheel_texture"), "Twingo has its own wheel texture")


func test_twingo_collision_box_matches_body() -> void:
	_car.apply_car(CarLibrary.index_of("twingo"))
	var shape := (_car.get_node("CollisionShape3D") as CollisionShape3D).shape as BoxShape3D
	var body: Vector3 = CarLibrary.CARS[CarLibrary.index_of("twingo")]["body"]
	assert_almost_eq(shape.size.z, body.z, 0.01)
	assert_almost_eq(shape.size.y, body.y - 0.3, 0.01)
	assert_true((_car.get_node("TwingoBody") as Node3D).visible, "TwingoBody shown")
	assert_false((_car.get_node("FocusBody") as Node3D).visible, "FocusBody hidden for the Twingo")
