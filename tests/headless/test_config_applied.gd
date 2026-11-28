extends GutTest

# The two scene-backed tests below (car + world values applied) are read-only
# checks that config landed on the built scene, so they share ONE cheap flat level.
var _scene: Node3D


func before_all() -> void:
	Config.reset()
	_scene = await SceneTestHelpers.add_level_world(self)


func after_all() -> void:
	_scene.free()
	SceneTestHelpers.remove_level_world()
	Config.reset()


func test_road_tile_per_meter_present() -> void:
	var cfg := GameConfig.new()
	assert_gt(cfg.road_tile_per_meter, 0.0, "road_tile_per_meter is a positive density")


func test_bonnet_camera_config_present() -> void:
	var cfg := GameConfig.new()
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


func test_target_fps_for_passes_through_uncapped() -> void:
	# 0 means uncapped; the selector must not coerce it (the cap is applied only when > 0).
	var cfg := GameConfig.new()
	cfg.target_fps = 0
	cfg.target_fps_mobile = 0
	cfg.target_fps_web = 0
	assert_eq(cfg.target_fps_for(false), 0, "uncapped desktop stays 0")
	assert_eq(cfg.target_fps_for(true, false), 0, "uncapped mobile stays 0")
	assert_eq(cfg.target_fps_for(true, true, true), 0, "uncapped web touch stays 0")
	assert_eq(cfg.target_fps_for(true, true, false), 0, "uncapped web desktop stays 0")


func test_config_defaults_are_sane() -> void:
	var cfg := GameConfig.new()
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


func test_car_values_applied() -> void:
	var cfg: GameConfig = Config.data
	var car: VehicleBody3D = _scene.get_node("Car")
	assert_eq(car.mass, cfg.mass, "car mass from config")
	for wheel in car.find_children("*", "VehicleWheel3D", false):
		# Built-in friction must be OFF — the Drivetrain tire model owns all
		# contact forces (the μ sliders are consumed by drivetrain.gd instead).
		assert_almost_eq(wheel.wheel_friction_slip, 0.0, 0.001, "friction disabled " + str(wheel.name))
		var travel: float = cfg.suspension_travel + car.hidden_travel(wheel)
		assert_almost_eq(wheel.suspension_travel, travel, 0.001, str(wheel.name))
		assert_almost_eq(wheel.wheel_rest_length, travel, 0.001, "rest length matches travel " + str(wheel.name))
		# Wheel properties are stored as 32-bit floats; compare with tolerance.
		# Each axle's spring is the overall stiffness split by the car's weight distribution.
		var k: float = cfg.axle_stiffness(wheel.position.z < 0.0)
		assert_almost_eq(wheel.suspension_stiffness, k, 0.001, "stiffness " + str(wheel.name))
		# Dampers are derived from the wheel's own stiffness: critical damping on compression,
		# 1.5x that on rebound.
		assert_almost_eq(wheel.damping_compression, sqrt(k), 0.001, "compression " + str(wheel.name))
		assert_almost_eq(wheel.damping_relaxation, 1.5 * sqrt(k), 0.001, "relaxation " + str(wheel.name))
		assert_almost_eq(wheel.wheel_radius, cfg.wheel_radius, 0.001, str(wheel.name))



func test_world_values_applied() -> void:
	var cfg: GameConfig = Config.data
	var tire_mat: ShaderMaterial = _scene.get_node("Car/WheelFL/Visual/Tire").get_surface_override_material(0)
	assert_eq(tire_mat.get_shader_parameter("albedo_color"), cfg.wheel_color, "tire color from config")
	# Speed-lines shader params are authored twice — once as scene fallbacks on
	# SpeedLines/ColorRect's material (level_view.tscn), once again from config at boot
	# (speed_lines.gd:32-36) — so the scene values are dead and drift silently if
	# they ever diverge from config. Assert the RELATIONSHIP (scene agrees with
	# config), never the values themselves, so retuning speed_lines_* can't break
	# this. `intensity` is excluded: it is legitimately scene-authored at 0.0 and
	# driven per-frame, not from config.
	var speed_lines_mat: ShaderMaterial = _scene.get_node("SpeedLines/ColorRect").material
	var speed_lines_params := {
		"line_color": cfg.speed_lines_color,
		"density": cfg.speed_lines_density,
		"inner_radius": cfg.speed_lines_inner_radius,
		"outer_radius": cfg.speed_lines_outer_radius,
		"flicker_speed": cfg.speed_lines_flicker_speed,
	}
	for param in speed_lines_params:
		assert_eq(speed_lines_mat.get_shader_parameter(param), speed_lines_params[param],
			"speed lines %s from config" % param)


func test_speed_lines_config_defaults_present() -> void:
	var cfg := GameConfig.new()
	assert_eq(cfg.speed_lines_color, Color(0.0, 0.0, 0.0, 1.0), "speed lines are black by default")
	# The effect must ramp over a real speed band (start below full).
	assert_lt(cfg.speed_lines_start_kmh, cfg.speed_lines_full_kmh,
		"speed lines ramp from start_kmh up to full_kmh")
	assert_between(cfg.speed_lines_max_intensity, 0.0, 1.0, "max intensity is an alpha fraction")
	assert_lt(cfg.speed_lines_inner_radius, cfg.speed_lines_outer_radius,
		"inner radius (clear centre) sits inside the outer (full-strength) radius")


# --- Wiring of the promoted tuning clusters --------------------------------------------------
#
# Clusters of tuning constants moved out of scripts and into GameConfig (the overworld fog
# frontier, the HQ present box, the loading frame caps). The rival pace / field cluster that
# used to be listed here is deleted along with the rival field
# (todo/roguelike-pivot.md decision 5). What needs guarding is the WIRING: the code must read the config field, not the
# literal. Every test below sets a SYNTHETIC value and asserts the behaviour follows it —
# never the authored number, which is a designer's to retune.
#
# Config.data is restored field-by-field rather than with Config.reset(), because the two
# scene-backed tests above compare the built scene against the live Config.data.

const _PROMOTED_FIELDS := [
	"loading_max_fps", "loading_touch_max_fps",
]


# Set `fields` (a name -> value dictionary) on the live config and return the previous values,
# so a test can put them back exactly as they were.
func _override(fields: Dictionary) -> Dictionary:
	var previous := {}
	for name in fields:
		previous[name] = Config.data.get(name)
		Config.data.set(name, fields[name])
	return previous


func _restore(previous: Dictionary) -> void:
	for name in previous:
		Config.data.set(name, previous[name])


func test_promoted_tuning_fields_are_declared() -> void:
	var fresh := GameConfig.new()
	for name in _PROMOTED_FIELDS:
		assert_true(name in fresh, "%s is a declared GameConfig field" % name)


func test_loading_cap_reads_the_config_fields() -> void:
	var previous := _override({"loading_max_fps": 123, "loading_touch_max_fps": 45})
	assert_eq(WorldRuntime.loading_cap(false), 123, "the non-touch cap comes from loading_max_fps")
	assert_eq(WorldRuntime.loading_cap(true), 45, "the touch cap comes from loading_touch_max_fps")
	_restore(previous)


# The rival field's swap_weight / _pace_band / generate_opponent_field config wiring
# used to be covered here. Deleted along with the rival field
# (todo/roguelike-pivot.md decision 5).
