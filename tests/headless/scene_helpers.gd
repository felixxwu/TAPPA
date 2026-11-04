class_name SceneTestHelpers
extends RefCounted
# Helpers for tests that need a booted main.tscn but NOT its terrain/track/foliage.
#
# WHY THIS EXISTS — world.gd._ready() generates a full rally track and scatters
# trees + bushes synchronously when main.tscn is instantiated. Under headless
# that is ~15 s of CPU PER INSTANCE (the DFS track search dominates at ~7 s, the
# two foliage scatters another ~7 s). Tests that only inspect the car, HUD or
# cameras don't care about the track's shape or its foliage, so paying that cost
# in every before_each is pure waste.
#
# minimal_world() trims the generation to a 1-turn track with no trees/bushes
# (trees_per_turn = 0 zeroes BOTH fields — bushes reuse the same scatter params),
# cutting the per-instance build to well under a second while still producing a
# fully wired world: car, HUD, cameras and a (short) TrackProgress are all built
# exactly as in the full game. Call it INSTEAD of Config.reset() right before
# instantiating main.tscn.
#
# use_test_config() installs the frozen physics baseline (TEST_CONFIG below).


# Frozen physics/handling baseline the model tests calibrate against: the fields
# where the test car differs from game_config.gd's defaults. Kept separate so
# gameplay balance changes never break the drivetrain/physics assertions. Only
# update it when the physics MODEL changes.
const TEST_CONFIG := {
	"brake_torque": 1000.0,
	"steer_limit": 0.4,
	"steer_speed": 5.0,
	"counter_steer_speed": 3.5,
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
	"glow_enabled": true,
	"glow_intensity": 0.8,
	"glow_strength": 1.0,
	"glow_bloom": 0.0,
	"glow_hdr_threshold": 0.85,
	"fog_density": 0.03,
	"distant_terrain_enabled": true,
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
	"terrain_layer1_wavelength": 200.0,
	"terrain_layer1_amplitude": 10.0,
	"terrain_layer2_amplitude": 1.0,
	"terrain_layer3_amplitude": 1.5,
	"render_height": 0,
	"outlines_enabled": true,
	"track_runoff_m": 20.0,
	"jump_span_m": 60.0,
	"tarmac_color": Color(0.32, 0.32, 0.34, 1),
	"track_progress_max_dist_m": 50.0,
	"water_enabled": false,
	"track_water_level_m": 0.0,
	"cliff_amount": 1.0,
	"tire_mark_max_segments": 200,
	"tire_mark_ground_offset_m": 0.05,
	"exhaust_offsets": {},
	"exhaust_flame_pop_seconds": 0.09,
	"exhaust_flame_length_m": 0.45,
	"exhaust_flame_wobble": 0.12,
	"lamp_offsets": {},
	"tree_cutout_mode": 0,
	"tree_fell_speed_kmh": 45.0,
	"tree_render_distance_web_touch_m": 60.0,
	"bush_height_m": 0.7,
	"engine_mix_rate_web_touch": 22050.0,
	"shop_tire_gravel_snow": 1.1,
	"shop_tire_road_snow": 0.9,
	"shop_tire_snow_flat": 1.1,
	"minimap_view_m": 460.0,
	"minimap_tilt": 1.7,
	"minimap_nearby_road_m": 120.0,
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


# Reset Config to the authored baseline, then strip world generation down to the
# cheapest thing that still boots a complete scene. Mutates the live Config
# singleton, so a later Config.reset() (e.g. in another file's before_each)
# restores the full baseline.
static func minimal_world() -> void:
	Config.reset()
	var cfg: GameConfig = Config.data
	cfg.track_turn_count = 1  # shortest track the search reliably places
	cfg.trees_per_turn = 0    # no trees AND no bushes (shared scatter params)
	# Rocks deliberately do NOT share the tree scatter params (see GameConfig.rock_params),
	# so zeroing trees_per_turn above does not reach them — they need switching off
	# explicitly, or every cheap-world test pays for a rock scatter it never inspects.
	cfg.rocks_enabled = false
