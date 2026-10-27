extends GutTest
# Free-roam biomes (features/free-roam.md → "Biomes"): which region a ring wears, the drifting
# per-ring weather, region handling written as the car crosses rings, the environment cross-fade,
# each ring's ground material, and its road surface (gravel / tarmac). Synthetic regions throughout, never the shipped catalogue.

const ICY := {"id": "icy", "order": 0, "name": "Icy",
	"grass_texture": "res://textures/gravel.jpg",
	"grass_particle_color": Color(0.9, 0.9, 1.0), "grass_particle_square": true,
	"background_color": Color(0.2, 0.4, 0.6),
	"surface_grip": {"gravel": "snow_gravel_grip", "grass": "snow_grass_grip", "tarmac": "snow_tarmac_grip"},
	"frozen_water": {"grip": "ice_grip"}}
const PLAIN := {"id": "plain", "order": 1, "name": "Plain"}


func before_each() -> void:
	var regions: Array[Dictionary] = [ICY, PLAIN]
	RegionLibrary.override_for_test(regions)


func after_each() -> void:
	RegionLibrary.reset()
	WeatherLibrary.reset()
	BiomeDirector.apply_handling(Config.data, "")
	Config.data.weather = WeatherLibrary.DEFAULT_ID


func _settings() -> FreeRoamSettings:
	var s := FreeRoamSettings.new()
	s.world_seed = 7
	s.island_radius_m = 3000.0
	s.mid_radius = 1
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
	WeatherLibrary.override_for_test([{"id": "dry"}, {"id": "murk", "look": {
		"background_color": "mist_background_color", "sky_color": "mist_sky_color",
		"sun_energy_mult": "mist_sun_energy_mult",
		"fog_density_mult": "mist_fog_density_mult",
		"fog_sky_affect": "mist_fog_sky_affect"}}] as Array[Dictionary])
	var murk_look: Dictionary = WeatherLibrary.by_id("murk")["look"]
	var wet := BiomeDirector.target_look(cfg, "icy", "murk", base_env)
	assert_eq(wet["bg"], cfg.get(String(murk_look["background_color"])))
	assert_almost_eq(float(wet["density"]), 0.01 * float(cfg.get(String(murk_look["fog_density_mult"]))), 1e-6)


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
	var mat := cs.mid_mesh.material_override as ShaderMaterial
	assert_eq(st.terrain.ring_index(32.0, 32.0), 0)
	assert_eq((mat.get_shader_parameter("albedo_texture") as Texture2D).resource_path, ICY["grass_texture"])


func _ground_streamer(s: FreeRoamSettings) -> TerrainStreamer:
	var st := TerrainStreamer.new()
	st.settings = s
	var scene: Node = load("res://free_roam.tscn").instantiate()
	st.material = scene.get_node("Terrain").material
	scene.free()
	var focus := Node3D.new()
	add_child_autofree(focus)
	st.focus = focus
	add_child_autofree(st)
	return st


func _built_chunk(st: TerrainStreamer, coord: Vector2i) -> TerrainStreamer.ChunkJob:
	var job := st._new_job(coord, TerrainStreamer.Level.FAR, false)
	st._queue.erase(job)
	st._step(job, Time.get_ticks_usec() + 60_000_000, TerrainStreamer.Stage.UPLOAD)
	return job


# A chunk the border runs through fades from the inner ring's ground to the outer ring's per
# pixel; a chunk clear of it keeps its own ring's plain material.
func test_a_chunk_on_a_border_fades_into_the_outer_rings_ground() -> void:
	var st := _ground_streamer(_settings())
	var inner := st._ring_materials[0] as ShaderMaterial
	var outer := st._ring_materials[1] as ShaderMaterial
	var plain := st._ground_material(_built_chunk(st, Vector2i.ZERO))
	assert_eq(plain, inner, "a chunk inside the first ring wears its plain material")
	var border: ShaderMaterial = null
	for cx in int(st.settings.island_radius_m / st.settings.chunk_m):
		var job := _built_chunk(st, Vector2i(cx, 0))
		if job.ring_lo < 1.0 and job.ring_hi > 1.0:
			border = st._ground_material(job) as ShaderMaterial
			break
	assert_not_null(border, "the border crosses the +x axis")
	assert_true(border.get_shader_parameter("fade_rings"))
	assert_eq(border.get_shader_parameter("ring_border"), 1.0)
	for p in ["albedo_texture", "road_texture", "tarmac_color", "road_marking_color"]:
		assert_eq(border.get_shader_parameter(p), inner.get_shader_parameter(p), "slot A is the inner ring's " + p)
		assert_eq(border.get_shader_parameter(p + "_b"), outer.get_shader_parameter(p), "slot B is the outer ring's " + p)
	assert_true(border in st.ring_materials(), "the weather tints border materials too")


# The vertex tint follows the same fade: each ring's own tint either side of the border, and no
# hard step across it. The tints and the fade width are synthetic.
func test_the_ground_tint_fades_across_a_border() -> void:
	var red := ICY.duplicate()
	red["terrain_tint"] = Color(1.0, 0.0, 0.0)
	var blue := PLAIN.duplicate()
	blue["terrain_tint"] = Color(0.0, 0.0, 1.0)
	var regions: Array[Dictionary] = [red, blue]
	RegionLibrary.override_for_test(regions)
	var s := _settings()
	s.biome_fade_m = 40.0
	var st := _ground_streamer(s)
	assert_eq(st.ring_tint_at(Vector2.ZERO), red["terrain_tint"])
	var prev := st.ring_tint_at(Vector2.ZERO)
	var saw_mid := false
	var worst_step := 0.0
	for i in range(1, 2400):
		var tint := st.ring_tint_at(Vector2(i * 1.0, 0.0))
		worst_step = maxf(worst_step, absf(tint.r - prev.r))
		saw_mid = saw_mid or (tint.r > 0.1 and tint.r < 0.9)
		prev = tint
	assert_lt(worst_step, 0.2, "no hard step metre to metre")
	assert_eq(prev, blue["terrain_tint"], "the outer ring wears its own tint")
	assert_true(saw_mid, "the border fades rather than switching")


func test_every_ring_material_is_drawn_once_at_boot_and_cleaned_up() -> void:
	var s := _settings()
	var st := TerrainStreamer.new()
	st.settings = s
	var scene: Node = load("res://free_roam.tscn").instantiate()
	st.material = scene.get_node("Terrain").material
	scene.free()
	add_child_autofree(st)
	var cam := Camera3D.new()
	add_child_autofree(cam)
	st.warm_up_materials(cam, 2)
	var drawn := []
	for c in cam.get_children():
		drawn.append((c as MeshInstance3D).material_override)
	assert_eq(drawn.size(), st.ring_materials().size(), "each ring's and each border's material")
	for m in st.ring_materials():
		assert_true(m in drawn)
	for i in 4:
		await get_tree().process_frame
	assert_eq(cam.get_child_count(), 0, "the specks are gone after the warm-up")


func test_each_ring_seats_its_regions_off_road_particle() -> void:
	var s := _settings()
	var st := TerrainStreamer.new()
	st.settings = s
	var d := BiomeDirector.new()
	d.streamer = st
	var wp := WheelParticles.new()
	add_child_autofree(wp)
	d.wheel_particles = wp
	var cfg: GameConfig = Config.data
	d.ring = 0  # icy
	d._seat_particle_look()
	var look: WheelParticles.Look = wp._grass_look(cfg)
	assert_eq(look.color, ICY["grass_particle_color"], "the icy ring throws its own colour")
	assert_eq(look.half_w, look.half_h, "...as clods")
	d.ring = 1  # plain authors none
	d._seat_particle_look()
	look = wp._grass_look(cfg)
	assert_eq(look.color, cfg.wheel_particle_grass_color, "a ring with no override throws the default")
	assert_ne(look.half_w, look.half_h, "...blades")
	d.free()
	st.free()


func test_a_forced_weather_overrides_every_rings_draw_until_cleared() -> void:
	var st := TerrainStreamer.new()
	st.settings = _settings()
	var d := BiomeDirector.new()
	d.streamer = st
	d.forced_weather = "snow"
	for r in 2:
		assert_eq(d.weather_at(r), "snow")
	d.forced_weather = ""
	assert_eq(d.weather_at(1), BiomeDirector.weather_for(st.settings, 1, d.drive_time),
		"Auto goes back to the ring's own draw")
	d.free()
	st.free()


func _terrain(s: FreeRoamSettings) -> RoadTerrain:
	var t := RoadTerrain.new()
	t.setup(s, RoadNetwork.new())
	return t


func test_roads_are_gravel_where_no_region_asks_for_tarmac() -> void:
	var t := _terrain(_settings())
	for r in [0.0, 1200.0, 2400.0]:
		assert_eq(t.tarmac_weight(r, 0.0), 0.0)


func test_a_tarmac_ring_blends_in_smoothly_across_its_border() -> void:
	var paved := PLAIN.duplicate()
	paved["road_surface"] = "tarmac"
	var regions: Array[Dictionary] = [ICY, paved]
	RegionLibrary.override_for_test(regions)
	var s := _settings()
	var t := _terrain(s)
	var prev := t.tarmac_weight(0.0, 0.0)
	assert_eq(prev, 0.0, "the gravel ring's roads are gravel")
	var saw_mid := false
	for i in range(1, 600):
		var x := i * 5.0
		var w := t.tarmac_weight(x, 0.0)
		assert_lt(absf(w - prev), 0.2, "no hard step at %.0f m" % x)
		saw_mid = saw_mid or (w > 0.1 and w < 0.9)
		prev = w
	assert_eq(prev, 1.0, "the tarmac ring's roads are tarmac")
	assert_true(saw_mid, "the border blends rather than switching")


func test_one_of_every_plant_rock_and_marker_is_drawn_at_boot_and_cleaned_up() -> void:
	var st := TerrainStreamer.new()
	st.settings = _settings()
	add_child_autofree(st)
	var cam := Camera3D.new()
	add_child_autofree(cam)
	st.warm_up_spawns(cam, 2)
	var root := st.get_node_or_null("SpawnWarmUp") as Node3D
	assert_not_null(root, "the warm-up set is out")
	var meshes := root.find_children("*", "GeometryInstance3D", true, false)
	assert_gt(meshes.size(), Foliage.ROCK_SCENES.size(), "trees, a bush, every rock and the markers")
	for i in 4:
		await get_tree().process_frame
	assert_false(is_instance_valid(root) and root.is_inside_tree(), "and it is gone after the warm-up")


func test_the_region_banner_names_the_rings_region() -> void:
	var s := _settings()
	assert_eq(RegionBanner.name_for(s, 0), "Icy")
	assert_eq(RegionBanner.name_for(s, 1), "Plain")


func test_the_region_banner_waits_for_the_checkpoint_band_then_shows() -> void:
	var cp := CheckpointBanner.new()
	add_child_autofree(cp)
	var banner := RegionBanner.new()
	banner.checkpoint_banner = cp
	add_child_autofree(banner)
	cp.show_reached(0)
	banner.announce("Plain")
	assert_false(banner.is_showing_banner(), "never stacked on the checkpoint band")
	cp._banner_done()
	await wait_process_frames(1)
	assert_true(banner.is_showing_banner(), "shows once the checkpoint band is gone")
	var label := banner._band.get_child(0) as Label
	assert_eq(label.text, UITheme.caps("Plain"))
	banner._banner_done()
	assert_false(banner.is_showing_banner())
