class_name SceneTestHelpers
extends RefCounted
# Shared setup for scene tests: a cheap booted game world and the frozen physics baseline.
#
# add_level_world() boots level_view.tscn (the real game world: car, HUD, cameras, pause
# menu) on a tiny synthetic level — a straight flat road and no trees — so a scene test
# pays well under a second instead of a full Hafren load. Call it ONCE from before_all and
# free the world plus remove_level_world() in after_all.
#
# use_test_config() installs the frozen physics baseline (TEST_CONFIG below).

const LEVEL_PATH := "user://test_flat_level.json"


# Frozen physics/handling baseline the model tests calibrate against: the fields
# where the test car differs from game_config.gd's defaults. Kept separate so
# gameplay balance changes never break the drivetrain/physics assertions. Only
# update it when the physics MODEL changes.
const TEST_CONFIG := {
	"brake_torque": 1000.0,
	"steer_limit": 0.4,
	"steer_speed": 5.0,
	"counter_steer_speed_fwd": 3.5,
	"counter_steer_speed_rwd": 3.5,
	"counter_steer_speed_awd": 3.5,
	"spin_assist_angle": 0.8726646259971648,
	"level_assist_torque": 5000.0,
	"level_assist_grounded": 0.0,
	"traction_ellipse_ratio": 0.7,
	"wheel_roll_influence": 0.5,
	"com_height": -0.25,
	"wheel_friction_slip_rear": 0.5,
	"tire_load_sensitivity": 0.0,
	"snow_grass_grip": 0.3,
	"snow_deep_drag": 90.0,
	"global_grip_mult": 1.0,
	"brake_bias": 0.5,
	"turbo_boost_response": 1.0,
	"engine_master_volume_db": 0.0,
	"engine_harmonics": 4,
	"engine_limiter_crackle": 0.5,
	"engine_nitrous_hiss_gain": 0.7,
	"impact_ref_hp_loss": 5000.0,
	"impact_max_loss": 800.0,
	"damage_misfire_health_threshold": 0.5,
	"damage_misfire_rate_max": 9.0,
	"damage_wheel_toe_gain": 0.12,
	"damage_wheel_toe_max": 0.14,
	"follow_distance": 5.0,
	"follow_height_ratio": 1.0,
	"chase_height_smoothing": 4.0,
	"fog_density": 0.03,
	"rain_particle_count": 300,
	"sand_particle_count": 250,
	"storm_particle_count": 500,
	"snowfall_particle_count": 900,
	"night_background_color": Color(0.04, 0.05, 0.09, 1),
	"night_sky_color": Color(0.06, 0.07, 0.12, 1),
	"night_sun_energy_mult": 0.12,
	"night_road_darken": 0.7,
	"headlight_color": Color(1, 0.94, 0.78, 1),
	"headlight_range_m": 45.0,
	"render_height": 0,
	"tire_mark_max_segments": 200,
	"tire_mark_ground_offset_m": 0.05,
	"exhaust_offsets": {},
	"exhaust_flame_pop_seconds": 0.09,
	"exhaust_flame_length_m": 0.45,
	"exhaust_flame_wobble": 0.12,
	"lamp_offsets": {},
	"tree_fell_speed_kmh": 45.0,
	"engine_mix_rate_web_touch": 22050.0,
	"shop_tire_gravel_snow": 1.1,
	"shop_tire_road_snow": 0.9,
	"shop_tire_snow_flat": 1.1,
}


# Point the live Config singleton at the frozen test baseline. Physics/behaviour
# tests call this INSTEAD of Config.reset() so their tuned thresholds depend on
# the stable test car, not on whatever the shipped config currently is.
static func use_test_config() -> void:
	Config.data = GameConfig.new()
	for field in TEST_CONFIG:
		Config.data.set(field, TEST_CONFIG[field])
	# The frozen test baseline used engine_type=1 (the old generic i5 preset) for its
	# calibrated launch / drivetrain assertions. The engine_type→preset mechanism is
	# gone (engine data lives in EngineLibrary now), so reproduce that exact i5
	# baseline here: cylinders 5, i5 firing, 264.5 N·m @ 4200 rpm, 7500 redline.
	var cfg: GameConfig = Config.data
	cfg.engine_cylinders = 5
	var i5_firing: Array[float] = []
	for angle in EngineLibrary.FIRING["i5"]:
		i5_firing.append(float(angle))
	cfg.engine_firing_angles = i5_firing
	cfg.redline_rpm = 7500.0
	cfg.peak_torque = 264.5
	cfg.peak_torque_rpm = 4200.0


# Write the flat synthetic level, own the configured car, and boot level_view.tscn on it
# under `parent`, returning the world root once the level has finished loading.
static func add_level_world(parent: Node) -> Node3D:
	var hm: Array = []
	hm.resize(201 * 201)
	hm.fill(0.0)
	var road := [{"x": -100.0, "z": 0.0, "w": 3.0, "m": null, "tension": 1.0},
		{"x": 100.0, "z": 0.0, "w": 3.0, "m": null, "tension": 1.0}]
	var f := FileAccess.open(LEVEL_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify({"road": road, "trees": [], "heightmap": hm}))
	f.close()
	LevelView.forget_progress()
	Save.set_setting(LevelView.CARS_KEY, [Config.data.level_car_id])
	var world: Node3D = (load(Scenes.WORLD) as PackedScene).instantiate()
	var view: LevelView = world.get_node("Level")
	view.level_path = LEVEL_PATH
	parent.add_child(world)
	await view.loaded
	return world


# Undo what add_level_world left behind outside the scene: saved progress and the level file.
static func remove_level_world() -> void:
	LevelView.forget_progress()
	Scenes.last_blocked_path = ""
	DirAccess.remove_absolute(ProjectSettings.globalize_path(LEVEL_PATH))
