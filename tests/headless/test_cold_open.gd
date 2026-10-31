extends GutTest
# The cold open (features/free-roam.md → "Cold open", todo/2026-10-30-cold-open.md): a first-time
# player starts at night in a dying car on the road to the nearest roadside rest stop, drives to that
# cabin (the road carries on past it) with money up front for another starter car, and gets the camera and control options there. The free-roam scene is built ONCE, as a
# first-time player's world, on a small synthetic island with the fixture car roster.

const TEST_PATH := "user://test_cold_open_profile.json"

var _save: Node
var _scene: Node3D
var _co: ColdOpen
var _car: VehicleBody3D
var _streamer: TerrainStreamer
var _rest: RestStops
var _options := [0]


func _settings() -> FreeRoamSettings:
	var s := FreeRoamSettings.new()
	s.world_seed = 7
	s.island_radius_m = 3000.0
	s.mid_radius = 1
	s.far_radius = 3
	return s


func before_all() -> void:
	_save = get_node("/root/Save")
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.profile = _save._default_profile()
	CarFixtures.install()
	var s := _settings()
	ColdOpen.new_world(s.world_seed, s)
	_scene = load("res://free_roam.tscn").instantiate()
	(_scene.get_node("Terrain") as TerrainStreamer).settings = s
	add_child(_scene)
	await get_tree().physics_frame
	_co = _scene.get("cold_open")
	_car = _scene.get_node("Car")
	_streamer = _scene.get_node("Terrain")
	_rest = _scene.get_node("RestStops")
	if _co != null:
		_co.show_options = func() -> void: _options[0] += 1


func after_all() -> void:
	get_tree().paused = false
	Input.action_release("accelerate")
	_scene.free()
	CarFixtures.restore()
	WorldSession.fresh = false
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


# --- the drive, in order (the tests share one scene and run top to bottom) ----------------------

func test_1_a_first_time_world_starts_down_the_road_at_night_in_a_dying_car() -> void:
	assert_not_null(_co, "a first-time player's world gets the cold open")
	if _co == null:
		return
	assert_true(_co.running, "it has started with the hand-over")
	var goal := _co.goal()
	assert_ne(goal, 0, "the goal is a roadside cabin, not spawn's road-end one")
	assert_false(_rest.is_lit(goal), "the cabin is still to be reached")
	var biome: BiomeDirector = _scene.get_node("BiomeDirector")
	assert_eq(biome.forced_weather, "night")
	assert_eq((_scene.get_node("CameraManager") as CameraManager).current_mode(), CameraManager.Mode.CHASE)
	var p := Vector2(_car.global_position.x, _car.global_position.z)
	var cabin := _streamer.sites.anchor[goal]
	var s := _streamer.settings
	assert_gt(p.distance_to(cabin), s.cold_open_min_distance_m * 0.5, "it starts a drive away from the cabin")
	assert_true(_streamer.network.nearest(p.x, p.y, s.road_half_width_m + 1.0), "on the road")
	var fwd := -_car.global_transform.basis.z
	assert_gt(Vector2(fwd.x, fwd.z).dot(cabin - p), 0.0, "facing the cabin")
	var dmg: DamageModel = _car.damage
	assert_true(dmg.cooling_broken, "the cooling has already gone")
	assert_false(dmg.is_overheating(Config.data), "but the engine starts below overheating")
	assert_lt(dmg.hp, dmg.max_hp)
	assert_gt(dmg.min_hp, 0.0, "the health floor is up")
	assert_false(_scene.has_node("TitleLayer"), "no title menu")


func test_2_the_car_limps_but_cannot_give_up_on_the_way() -> void:
	if _co == null:
		return
	var dmg: DamageModel = _car.damage
	watch_signals(dmg)
	dmg.apply_loss(dmg.max_hp * 10.0)
	assert_almost_eq(dmg.hp, dmg.min_hp, 0.001, "it stops at the floor")
	assert_signal_not_emitted(dmg, "gave_up")


func test_3_the_throttle_hint_shows_until_the_throttle_is_pressed() -> void:
	if _co == null:
		return
	var minimap: MiniMap = _scene.get_node("MiniMapLayer/MiniMap")
	assert_ne(minimap.hint, "", "the throttle button is shown")
	assert_eq(minimap.hint, ColdOpen.throttle_hint())
	Input.action_press("accelerate")
	_co.step()
	Input.action_release("accelerate")
	assert_eq(minimap.hint, "", "gone once pressed")
	Input.action_press("accelerate")
	Input.action_release("accelerate")
	_co.step()
	assert_eq(minimap.hint, "", "and it doesn't come back")


func test_4_the_world_starts_with_money_for_another_starter_car() -> void:
	if _co == null:
		return
	assert_eq(WorldSession.money(), _streamer.settings.cold_open_start_money,
		"a first-time world starts with the swap money")
	assert_eq(_co.get_children().filter(func(n: Node) -> bool: return n is MeshInstance3D).size(), 0,
		"no coins laid on the road")


func test_5_reaching_the_cabin_ends_the_cold_open_and_opens_the_options() -> void:
	if _co == null:
		return
	_rest.light(_co.goal())
	assert_true(_co.done)
	assert_false(_co.running)
	var dmg: DamageModel = _car.damage
	assert_eq(dmg.min_hp, 0.0, "the floor is only for the cold open")
	var biome: BiomeDirector = _scene.get_node("BiomeDirector")
	assert_eq(biome.forced_weather, "dry", "the night clears")
	assert_false(WorldSession.cold_open_pending(), "a later boot is a normal one")
	assert_false(ColdOpen.due())
	assert_false(WorldSession.fresh)
	var banner: CheckpointBanner = _co.checkpoint_banner
	assert_true(banner.is_showing_banner(), "\"Checkpoint reached\" first")
	_co._process(10.0)
	assert_eq(_options[0], 0, "the options wait for the band")
	_co.checkpoint_banner = null  # the band has gone
	_co._process(10.0)
	_co.checkpoint_banner = banner
	assert_eq(_options[0], 1, "then the camera and control options open")
	_co._process(10.0)
	assert_eq(_options[0], 1, "once")
	biome.drive_time += _streamer.settings.weather_hold_s
	_co._process(0.1)
	assert_eq(biome.forced_weather, "", "the rings' weather takes over at its next slot")


# --- the logic on its own ------------------------------------------------------------------------

func test_the_floor_is_off_unless_set() -> void:
	var d := DamageModel.new()
	d.thermal = true
	d.field(1000.0, 1000.0)
	watch_signals(d)
	d.apply_loss(5000.0)
	assert_eq(d.hp, 0.0)
	assert_signal_emit_count(d, "gave_up", 1)
	var f := DamageModel.new()
	f.thermal = true
	f.field(1000.0, 1000.0)
	f.min_hp = 100.0
	watch_signals(f)
	f.apply_loss(5000.0)
	assert_eq(f.hp, 100.0)
	assert_signal_not_emitted(f, "gave_up")
	f.min_hp = 0.0
	f.apply_loss(5000.0)
	assert_signal_emit_count(f, "gave_up", 1, "lifting the floor lets the car give up again")


func test_the_cold_open_car_is_the_configured_one_or_the_first_starter() -> void:
	var s := FreeRoamSettings.new()
	var starters := LootRules.starter_cars()
	s.cold_open_car_id = starters[starters.size() - 1]
	assert_eq(ColdOpen.car_id(s), s.cold_open_car_id)
	s.cold_open_car_id = "no_such_car"
	assert_eq(ColdOpen.car_id(s), starters[0])


func test_the_story_lines_name_the_car() -> void:
	var s := FreeRoamSettings.new()
	s.cold_open_story = PackedStringArray(["A %s here", "no name"])
	var name := String(CarLibrary.by_id(String(WorldSession.active_car()["model_id"]))["name"])
	assert_eq(ColdOpen.story_lines(s), PackedStringArray(["A %s here" % name, "no name"]))


func test_the_start_is_on_the_road_to_a_roadside_rest_stop() -> void:
	var st := TerrainStreamer.new()
	st.settings = _settings()
	var focus := Node3D.new()
	add_child_autofree(focus)
	st.focus = focus
	add_child_autofree(st)
	var t := st.terrain
	var spot := ColdOpen.pick_start(st.network, st.sites,
		func(x: float, z: float) -> float: return t.height(x, z, PackedInt32Array(), false),
		st.lantern_position, st.settings)
	assert_false(spot.is_empty(), "the island has a roadside rest stop")
	if spot.is_empty():
		return
	var g := int(spot["site"])
	assert_ne(g, 0, "not spawn's cabin")
	assert_eq(st.sites.kind[g], RoadSites.Kind.REST)
	assert_ne(st.sites.anchor[g], st.sites.pos[g], "a roadside cabin, off its road")
	var p: Vector2 = spot["pos"]
	var path: PackedVector2Array = spot["path"]
	var back := path.duplicate()
	back.reverse()
	assert_lte(ColdOpen.first_coin(back, st.sites, st.sites.edge[g]) + st.settings.cold_open_coin_lead_m,
		float(spot["dist"]) + 0.01, "a road coin lies on the way, with a lead-in before it")
	assert_almost_eq(path[path.size() - 1].distance_to(st.sites.anchor[g]), 0.0, 0.01, "the path ends at the cabin's road point")
	assert_eq(path[0], p)
	assert_true(st.network.nearest(p.x, p.y, 0.5), "on the road")


func test_only_a_pending_world_is_due() -> void:
	var was: bool = WorldSession.cold_open_pending()
	WorldSession.set_cold_open_pending(false)
	assert_false(ColdOpen.due())
	WorldSession.set_cold_open_pending(true)
	assert_true(ColdOpen.due())
	Benchmark.active = true
	assert_false(ColdOpen.due(), "never under the benchmark")
	Benchmark.active = false
	WorldSession.set_cold_open_pending(was)
