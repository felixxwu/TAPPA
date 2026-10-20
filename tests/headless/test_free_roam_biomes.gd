extends GutTest
# Free-roam biomes (features/free-roam.md → "Biomes"): which region a ring wears, the drifting
# per-ring weather, region handling written as the car crosses rings, the environment cross-fade,
# and each ring's ground material. Synthetic regions throughout, never the shipped catalogue.

const ICY := {"id": "icy", "order": 0, "name": "Icy",
	"grass_texture": "res://textures/gravel.jpg",
	"background_color": Color(0.2, 0.4, 0.6),
	"surface_grip": {"gravel": "snow_gravel_grip", "grass": "snow_grass_grip", "tarmac": "snow_tarmac_grip"},
	"frozen_water": {"grip": "ice_grip"}}
const PLAIN := {"id": "plain", "order": 1, "name": "Plain"}


func before_each() -> void:
	var regions: Array[Dictionary] = [ICY, PLAIN]
	RegionLibrary.override_for_test(regions)


func after_each() -> void:
	RegionLibrary.reset()
	BiomeDirector.apply_handling(Config.data, "")
	Config.data.weather = WeatherLibrary.DEFAULT_ID


func _settings() -> FreeRoamSettings:
	var s := FreeRoamSettings.new()
	s.world_seed = 7
	s.island_radius_m = 3000.0
	s.near_radius = 1
	s.far_radius = 3
	s.ring_count = 2
	s.ring_regions = PackedStringArray(["icy", "plain"])
	s.ring_weather = PackedStringArray(["dry:1,rain:1", "fog:1"])
	return s


func test_rings_wear_their_listed_regions_and_wrap() -> void:
	var s := _settings()
	assert_eq(BiomeDirector.region_of(s, 0), "icy")
	assert_eq(BiomeDirector.region_of(s, 1), "plain")
	assert_eq(BiomeDirector.region_of(s, 2), "icy", "more rings than regions wraps round")


func test_weather_comes_from_the_rings_pool_and_holds_for_a_slot() -> void:
	var s := _settings()
	s.weather_hold_s = 100.0
	for t in [0.0, 150.0, 333.0, 1234.0]:
		assert_true(BiomeDirector.weather_for(s, 0, t) in ["dry", "rain"])
		assert_eq(BiomeDirector.weather_for(s, 1, t), "fog")
	assert_eq(BiomeDirector.weather_for(s, 0, 210.0), BiomeDirector.weather_for(s, 0, 299.0), "fixed within a slot")
	var seen := {}
	for slot in 40:
		seen[BiomeDirector.weather_for(s, 0, slot * 100.0)] = true
	assert_eq(seen.size(), 2, "over many slots the weather drifts between the pool's conditions")


func test_a_pool_drops_unknown_conditions_and_empty_weights() -> void:
	var pool := BiomeDirector.parse_pool("dry:2, nonsense:5, rain:0, fog")
	assert_eq(pool, [["dry", 2.0], ["fog", 1.0]])


func test_entering_a_region_writes_its_handling_and_leaving_restores_the_authored_values() -> void:
	var cfg: GameConfig = Config.data
	var base: GameConfig = load(Config.CONFIG_PATH)
	BiomeDirector.apply_handling(cfg, "icy")
	assert_eq(cfg.gravel_grip, base.snow_gravel_grip)
	assert_eq(cfg.grass_grip, base.snow_grass_grip)
	assert_eq(cfg.frozen_water_grip, base.ice_grip)
	BiomeDirector.apply_handling(cfg, "plain")
	assert_eq(cfg.gravel_grip, base.gravel_grip)
	assert_eq(cfg.grass_grip, base.grass_grip)
	assert_eq(cfg.frozen_water_grip, 0.0)


func test_the_target_look_takes_the_regions_colour_and_the_weathers_overcast() -> void:
	var cfg: GameConfig = Config.data
	var base_env := {"bg": Color.BLACK, "fog": Color.BLACK, "density": 0.01, "sky_affect": 0.1}
	var dry := BiomeDirector.target_look(cfg, "icy", "dry", base_env)
	assert_eq(dry["bg"], ICY["background_color"])
	assert_eq(BiomeDirector.target_look(cfg, "plain", "dry", base_env)["bg"], Color.BLACK, "no colour of its own keeps the scene's")
	var rain_look: Dictionary = WeatherLibrary.by_id("rain")["look"]
	var wet := BiomeDirector.target_look(cfg, "icy", "rain", base_env)
	assert_eq(wet["bg"], cfg.get(String(rain_look["background_color"])))
	assert_almost_eq(float(wet["density"]), 0.01 * float(cfg.get(String(rain_look["fog_density_mult"]))), 1e-6)


func test_the_environment_blends_to_the_target_over_the_crossfade() -> void:
	var s := _settings()
	var env_node := WorldEnvironment.new()
	env_node.environment = Environment.new()
	env_node.environment.background_color = Color.BLACK
	add_child_autofree(env_node)
	var st := TerrainStreamer.new()
	st.settings = s
	var d := BiomeDirector.new()
	d.streamer = st
	d.environment = env_node
	add_child_autofree(d)
	d._start_fade({"bg": Color.WHITE, "fog": Color.WHITE, "density": 0.02, "sky_affect": 0.3, "panorama": "", "sun_mult": 1.0})
	d._step_fade(s.look_crossfade_s * 0.5)
	var mid := env_node.environment.background_color
	assert_true(mid.r > 0.0 and mid.r < 1.0, "halfway through, between the two")
	d._step_fade(s.look_crossfade_s)
	assert_eq(env_node.environment.background_color, Color.WHITE)
	assert_almost_eq(env_node.environment.fog_density, 0.02, 1e-6)
	assert_false(d.is_fading())
	st.free()


func test_a_chunk_is_drawn_with_its_rings_ground_material() -> void:
	var s := _settings()
	var st := TerrainStreamer.new()
	st.settings = s
	var scene: Node = load("res://free_roam.tscn").instantiate()
	st.material = scene.get_node("Terrain").material
	scene.free()
	var focus := Node3D.new()
	add_child_autofree(focus)
	st.focus = focus
	add_child_autofree(st)
	st.prefill()
	var cs: TerrainStreamer.ChunkState = st._chunks[Vector2i.ZERO]
	var mat := cs.near_mesh.material_override as ShaderMaterial
	assert_eq(st.terrain.ring_index(32.0, 32.0), 0)
	assert_eq((mat.get_shader_parameter("albedo_texture") as Texture2D).resource_path, ICY["grass_texture"])
