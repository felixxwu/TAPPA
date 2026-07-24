extends GutTest

# The two scene-backed tests below (car + world values applied) are read-only
# checks that config landed on the built scene, so share ONE minimal_world()
# instance — that trims main.tscn's expensive terrain/track/foliage generation
# (see scene_helpers.gd) while still wiring the car, world environment and
# materials exactly as the full game does. Config is left at the minimal_world
# baseline for the duration; every assertion compares the scene against the live
# Config.data, so the trimmed track/foliage values don't affect them.
var _scene: Node3D


func before_all() -> void:
	SceneTestHelpers.minimal_world()
	_scene = load("res://main.tscn").instantiate()
	add_child(_scene)
	await get_tree().physics_frame  # let _ready() run


func after_all() -> void:
	_scene.free()
	Config.reset()  # minimal_world() zeroed foliage/track — restore the baseline for later files


func test_road_tile_per_meter_present() -> void:
	var cfg := GameConfig.new()
	assert_gt(cfg.road_tile_per_meter, 0.0, "road_tile_per_meter is a positive density")


func test_bonnet_camera_config_present() -> void:
	var cfg := load("res://config/game_config.tres") as GameConfig
	assert_typeof(cfg.bonnet_offset, TYPE_VECTOR3, "bonnet_offset is a Vector3")
	assert_lt(cfg.bonnet_offset.z, 0.0, "bonnet_offset sits toward the car's front (-Z)")
	assert_gt(cfg.bonnet_fov, 0.0, "bonnet_fov is a positive FOV")


func test_target_fps_for_selects_by_platform() -> void:
	var cfg := GameConfig.new()
	cfg.target_fps = 60
	cfg.target_fps_mobile = 45
	cfg.target_fps_web = 30
	# Desktop: neither mobile/web nor web.
	assert_eq(cfg.target_fps_for(false), 60, "desktop gets the higher cap")
	# Native mobile: mobile/web true, web false.
	assert_eq(cfg.target_fps_for(true, false), 45, "native mobile gets the mobile cap")
	# Web TOUCH device (phone/tablet browser): all true — web cap wins over mobile.
	assert_eq(cfg.target_fps_for(true, true, true), 30, "web touch gets its own cap, not the mobile one")
	# Web DESKTOP browser (web but not a touch device): the 30fps web cap is lifted;
	# a desktop browser runs at the full desktop cap.
	assert_eq(cfg.target_fps_for(true, true, false), 60, "web desktop gets the desktop cap, not the web one")


func test_render_distance_for_selects_by_platform() -> void:
	# Contract, not the shipped numbers: only a web TOUCH device gets the web-touch
	# distance; every other target gets the main one. Sentinel values so retuning
	# the shipped 60/120 in the inspector can't break this.
	var cfg := GameConfig.new()
	cfg.tree_render_distance_m = 999.0
	cfg.tree_render_distance_web_touch_m = 111.0
	assert_eq(cfg.tree_render_distance_for(false, false), 999.0, "desktop gets the main distance")
	assert_eq(cfg.tree_render_distance_for(false, true), 999.0, "native touch (non-web) gets the main distance")
	assert_eq(cfg.tree_render_distance_for(true, false), 999.0, "web desktop (non-touch) gets the main distance")
	assert_eq(cfg.tree_render_distance_for(true, true), 111.0, "web touch gets the shorter web-touch distance")


func test_terrain_lod_bands_for_selects_by_platform() -> void:
	# Same web-touch-only split as the render distance, on the LOD band set.
	var cfg := GameConfig.new()
	var main := PackedFloat32Array([1.0, 2.0])
	var web_touch := PackedFloat32Array([3.0, 4.0])
	cfg.terrain_lod_bands_m = main
	cfg.terrain_lod_bands_web_touch_m = web_touch
	assert_eq(cfg.terrain_lod_bands_for(false, false), main, "desktop gets the main LOD bands")
	assert_eq(cfg.terrain_lod_bands_for(false, true), main, "native touch (non-web) gets the main LOD bands")
	assert_eq(cfg.terrain_lod_bands_for(true, false), main, "web desktop (non-touch) gets the main LOD bands")
	assert_eq(cfg.terrain_lod_bands_for(true, true), web_touch, "web touch gets the tighter LOD bands")


func test_target_fps_for_passes_through_uncapped() -> void:
	# 0 means uncapped; the selector must not coerce it (world.gd gates on > 0).
	var cfg := GameConfig.new()
	cfg.target_fps = 0
	cfg.target_fps_mobile = 0
	cfg.target_fps_web = 0
	assert_eq(cfg.target_fps_for(false), 0, "uncapped desktop stays 0")
	assert_eq(cfg.target_fps_for(true, false), 0, "uncapped mobile stays 0")
	assert_eq(cfg.target_fps_for(true, true, true), 0, "uncapped web touch stays 0")
	assert_eq(cfg.target_fps_for(true, true, false), 0, "uncapped web desktop stays 0")


func test_config_resource_loads() -> void:
	var cfg := load("res://config/game_config.tres") as GameConfig
	assert_not_null(cfg, "game_config.tres loads as a GameConfig")
	assert_gt(cfg.peak_torque, 0.0, "peak_torque sane")
	# peak_torque / redline_rpm / firing etc. are the LIVE engine fields, written by
	# EngineLibrary.apply() when a car is fielded (scripts/engine_library.gd); the
	# resource just carries neutral defaults. There is no engine_type selector.
	assert_gt(cfg.redline_rpm, cfg.idle_rpm, "redline above idle")
	assert_gt(cfg.gear_ratios.size(), 0, "at least one forward gear")
	assert_gt(cfg.final_drive, 0.0, "final_drive sane")
	assert_gt(cfg.clutch_max_torque, 0.0, "clutch_max_torque sane")
	assert_gt(cfg.wheel_radius, 0.0, "wheel_radius sane")
	assert_gt(cfg.brake_torque, 0.0, "brake_torque sane")
	assert_gt(cfg.handbrake_torque, 0.0, "handbrake_torque sane")
	assert_gt(cfg.axle_inertia, 0.0, "axle_inertia sane")
	assert_gt(cfg.tire_slip_peak, 0.0, "tire_slip_peak sane")
	assert_between(cfg.sliding_grip_ratio, 0.0, 1.0, "sliding_grip_ratio sane")
	assert_true(InputMap.has_action("handbrake"), "handbrake action bound")
	assert_true("downforce_front" in cfg, "downforce_front exists on GameConfig")
	assert_true("downforce_rear" in cfg, "downforce_rear exists on GameConfig")
	assert_between(cfg.downforce_front, -2.0, 2.0, "downforce_front sane")
	assert_between(cfg.downforce_rear, -2.0, 2.0, "downforce_rear sane")


# Looks up the export metadata (hint + hint_string) for a property by name.
func _export_hint(prop_name: String, obj: Object) -> Dictionary:
	for p in obj.get_property_list():
		if p.name == prop_name:
			return p
	return {}


func test_car_values_applied() -> void:
	var cfg: GameConfig = Config.data
	var car: VehicleBody3D = _scene.get_node("Car")
	assert_eq(car.mass, cfg.mass, "car mass from config")
	for wheel in car.find_children("*", "VehicleWheel3D", false):
		# Built-in friction must be OFF — the Drivetrain tire model owns all
		# contact forces (the μ sliders are consumed by drivetrain.gd instead).
		assert_almost_eq(wheel.wheel_friction_slip, 0.0, 0.001, "friction disabled " + str(wheel.name))
		assert_almost_eq(wheel.suspension_travel, cfg.suspension_travel, 0.001, str(wheel.name))
		assert_almost_eq(wheel.wheel_rest_length, cfg.suspension_travel, 0.001, "rest length matches travel " + str(wheel.name))
		# Wheel properties are stored as 32-bit floats; compare with tolerance.
		assert_almost_eq(wheel.suspension_stiffness, cfg.suspension_stiffness, 0.001, "stiffness " + str(wheel.name))
		# Dampers are derived from stiffness: critical damping on compression,
		# 1.5x that on rebound.
		assert_almost_eq(wheel.damping_compression, sqrt(cfg.suspension_stiffness), 0.001, "compression " + str(wheel.name))
		assert_almost_eq(wheel.damping_relaxation, 1.5 * sqrt(cfg.suspension_stiffness), 0.001, "relaxation " + str(wheel.name))
		assert_almost_eq(wheel.wheel_radius, cfg.wheel_radius, 0.001, str(wheel.name))



func test_world_values_applied() -> void:
	var cfg: GameConfig = Config.data
	var env: Environment = _scene.get_node("WorldEnvironment").environment
	assert_almost_eq(env.fog_density, cfg.fog_density, 0.0001, "fog density from config")
	assert_eq(env.background_color, cfg.background_color, "background color from config")
	assert_eq(env.fog_light_color, cfg.background_color, "fog color matches background")
	assert_eq(_scene.get_node("Floor").texture_tile_per_meter, cfg.terrain_tile_per_meter, "terrain tiling from config")
	var floor_layers: Array[TerrainLayer] = _scene.get_node("Floor").layers
	var cfg_layers := cfg.terrain_layers()
	assert_eq(floor_layers.size(), cfg_layers.size(), "terrain layer count from config")
	for i in floor_layers.size():
		assert_eq(floor_layers[i].wavelength_m, cfg_layers[i].x, "layer %d wavelength from config" % i)
		assert_eq(floor_layers[i].amplitude_m, cfg_layers[i].y, "layer %d amplitude from config" % i)
	var chassis_mat: ShaderMaterial = _scene.get_node("Car/Chassis").get_surface_override_material(0)
	assert_eq(chassis_mat.get_shader_parameter("albedo_color"), cfg.chassis_color, "chassis color from config")
	var post_mat: ShaderMaterial = _scene.get_node("PostProcess").material
	assert_eq(post_mat.get_shader_parameter("virtual_resolution"), cfg.virtual_resolution, "dither grid from config")
	var tire_mat: ShaderMaterial = _scene.get_node("Car/WheelFL/Visual/Tire").get_surface_override_material(0)
	assert_eq(tire_mat.get_shader_parameter("albedo_color"), cfg.wheel_color, "tire color from config")


func test_speed_lines_config_defaults_present() -> void:
	var cfg := GameConfig.new()
	assert_true(cfg.speed_lines_enabled, "speed lines on by default")
	assert_eq(cfg.speed_lines_color, Color(0.0, 0.0, 0.0, 1.0), "speed lines are black by default")
	# The effect must ramp over a real speed band (start below full).
	assert_lt(cfg.speed_lines_start_kmh, cfg.speed_lines_full_kmh,
		"speed lines ramp from start_kmh up to full_kmh")
	assert_between(cfg.speed_lines_max_intensity, 0.0, 1.0, "max intensity is an alpha fraction")
	assert_lt(cfg.speed_lines_inner_radius, cfg.speed_lines_outer_radius,
		"inner radius (clear centre) sits inside the outer (full-strength) radius")


func test_track_config_defaults_present() -> void:
	var cfg := GameConfig.new()
	# Track-gen knobs are tuned during balancing, so assert they're present and sane,
	# not pinned to a specific value.
	assert_gt(cfg.track_width, 0.0, "track width is positive")
	assert_gt(cfg.track_turn_count, 0, "track has at least one corner")
	assert_true(cfg.track_seed is int, "track_seed is an int")


func test_track_transition_cells_default() -> void:
	var cfg := GameConfig.new()
	assert_gt(cfg.track_transition_cells, 0, "edge transition spans at least one cell")
