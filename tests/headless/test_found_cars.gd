extends GutTest
# Found cars (features/loot.md): every car but the starter is parked
# at the end of its own side road, found by driving onto its pad. Synthetic cars throughout.

const TEST_PATH := "user://test_found_cars_profile.json"
const CARS := [{"id": "a", "ring": 0}, {"id": "b", "ring": 0}, {"id": "c", "ring": 1},
	{"id": "d", "ring": 2}, {"id": "e", "ring": 9}]

var _save: Node


func before_each() -> void:
	_save = get_node("/root/Save")
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.profile = _save._default_profile()
	CarFixtures.install()


func after_each() -> void:
	get_tree().paused = false
	CarFixtures.restore()
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


func _settings(seed_value := 7) -> FreeRoamSettings:
	var s := FreeRoamSettings.new()
	s.world_seed = seed_value
	s.island_radius_m = 3000.0
	s.mid_radius = 1
	s.far_radius = 3
	return s


func _world(s: FreeRoamSettings, cars: Array) -> Array:
	var net := RoadNetwork.new()
	var terrain := RoadTerrain.new()
	terrain.setup(s, net)
	net.build(s, terrain)
	terrain.fill_cut_lakes()
	var sites := RoadSites.new()
	sites.build(s, net, terrain)
	net.add_side_roads(cars, ColdOpen.roads_to_keep_clear(net, sites, s))
	sites = RoadSites.new()
	sites.build(s, net, terrain)
	return [net, terrain, sites]


# --- the side roads --------------------------------------------------------------------------------

func test_every_car_gets_exactly_one_side_road_ending_in_a_dead_end_off_a_new_junction() -> void:
	for seed_value in [3, 7, 11]:
		var net: RoadNetwork = _world(_settings(seed_value), CARS)[0]
		var ids := net.side_road_car.values()
		ids.sort()
		assert_eq(ids, ["a", "b", "c", "d", "e"], "seed %d: one side road per car" % seed_value)
		var side := 0
		for ei in net.edges.size():
			if not net.is_side_road(ei):
				continue
			side += 1
			var e := net.edges[ei]
			assert_eq(net.node_degree[e.y], 1, "a side road ends in a dead end")
			assert_true(net.side_road_car.has(e.y), "where its car is parked")
			assert_eq(net.node_degree[e.x], 3, "and leaves a main road at a junction")
		assert_eq(side, CARS.size())


func test_a_side_roads_branch_is_not_a_fork_but_real_junctions_are() -> void:
	var net: RoadNetwork = _world(_settings(), CARS)[0]
	var forks := {}
	for n in net.fork_nodes:
		forks[n] = true
	for ei in net.edges.size():
		if net.is_side_road(ei):
			assert_false(forks.has(net.edges[ei].x), "a parked car's branch offers no map")
	var main_degree := PackedInt32Array()
	main_degree.resize(net.node_x.size())
	for ei in net.edges.size():
		if not net.is_side_road(ei):
			main_degree[net.edges[ei].x] += 1
			main_degree[net.edges[ei].y] += 1
	for n in main_degree.size():
		assert_eq(forks.has(n), main_degree[n] >= 3, "node %d is a fork iff 3+ main roads meet there" % n)


func test_side_roads_leave_the_main_roads_as_they_were() -> void:
	var s := _settings()
	var bare: RoadNetwork = _world(s, [])[0]
	var net: RoadNetwork = _world(s, CARS)[0]
	var main := 0.0
	for ei in net.edges.size():
		if not net.is_side_road(ei):
			main += net.edge_len[ei]
	assert_almost_eq(main, bare.total_length_m, 0.01, "splitting a road for a branch adds no road to it")


func test_side_roads_stay_on_dry_land_and_off_other_roads() -> void:
	var s := _settings()
	var w := _world(s, CARS)
	var net: RoadNetwork = w[0]
	var terrain: RoadTerrain = w[1]
	for ei in net.edges.size():
		if not net.is_side_road(ei):
			continue
		var pl := net.polyline(ei)
		for k in range(1, pl.size()):
			var p := pl[k]
			assert_false(terrain.is_water(p.x, p.y), "side road %d on dry land" % ei)
			assert_true(net.nearest(p.x, p.y, 500.0), "a road is found")
			assert_eq(net.hit_edge, ei, "no other road is nearer than the side road itself, so it crosses none")


func test_no_side_road_leaves_the_cold_opens_road() -> void:
	var crowd := []
	for k in 12:
		crowd.append({"id": "car%d" % k, "ring": 0})
	for seed_value in [3, 7, 11]:
		var s := _settings(seed_value)
		var w := _world(s, crowd)
		var net: RoadNetwork = w[0]
		var pick := ColdOpen.pick_start(net, w[2], func(_x: float, _z: float) -> float: return 0.0,
			func(_g: int) -> Vector3: return Vector3.ZERO, s)
		assert_false(pick.is_empty(), "seed %d has a cold open" % seed_value)
		var path: PackedVector2Array = pick["path"]
		for ei in net.edges.size():
			if not net.is_side_road(ei):
				continue
			var b := net.node(net.edges[ei].x)
			for k in path.size() - 1:
				var gap := b.distance_to(Geometry2D.get_closest_point_to_segment(b, path[k], path[k + 1]))
				assert_gt(gap, 1.0, "seed %d: side road %d branches off the cold open's drive" % [seed_value, ei])


func test_no_cars_means_no_side_roads() -> void:
	var net: RoadNetwork = _world(_settings(), [])[0]
	assert_true(net.side_road_car.is_empty())


func test_the_end_of_a_side_road_holds_its_car_and_no_checkpoint_or_coin() -> void:
	var w := _world(_settings(), CARS)
	var net: RoadNetwork = w[0]
	var sites: RoadSites = w[2]
	var found := []
	for i in sites.count():
		if sites.edge[i] >= 0 and net.is_side_road(sites.edge[i]):
			assert_eq(sites.kind[i], RoadSites.Kind.CAR, "a side road carries only its car")
			found.append(sites.car_id[i])
	found.sort()
	assert_eq(found, ["a", "b", "c", "d", "e"])
	assert_eq(sites.of_kind(RoadSites.Kind.CAR).size(), CARS.size())


func test_the_cars_to_find_are_every_car_but_the_one_a_new_world_starts_with() -> void:
	var s := FreeRoamSettings.new()
	var all := CarLibrary.all().map(func(c: Dictionary) -> String: return String(c["id"]))
	s.cold_open_car_id = all[1]
	var ids := LootRules.cars_to_find(s).map(func(c: Dictionary) -> String: return String(c["id"]))
	all.erase(ColdOpen.car_id(s))
	assert_eq(ids, all)


# --- finding a car in the world --------------------------------------------------------------------

func _boot() -> Node3D:
	WorldSession.new_world(7, String(CarLibrary.all()[0]["id"]))
	var scene: Node3D = load("res://free_roam.tscn").instantiate()
	(scene.get_node("Terrain") as TerrainStreamer).settings = _settings()
	add_child_autofree(scene)
	await get_tree().physics_frame
	return scene


func _car_site(scene: Node3D) -> int:
	var parked: ParkedCars = scene.get_node("ParkedCars")
	for i in parked.streamer.sites.of_kind(RoadSites.Kind.CAR):
		if parked.waiting(i):
			return i
	return -1


func _drive_onto(scene: Node3D, site: int) -> void:
	var parked: ParkedCars = scene.get_node("ParkedCars")
	var p := parked.streamer.sites.pos[site]
	(scene.get_node("Car") as Node3D).global_position = Vector3(p.x, parked.streamer.sites.pad_h[site] + 1.0, p.y)
	parked._last_p = p + Vector2(30.0, 0.0)
	parked._physics_process(0.0)


func _press_select(parked: ParkedCars) -> void:
	var e := InputEventAction.new()
	e.action = "menu_select"
	e.pressed = true
	parked._unhandled_input(e)


func test_driving_onto_a_cars_pad_puts_it_in_the_garage_under_a_banner_and_offers_to_drive_it() -> void:
	var scene := await _boot()
	var site := _car_site(scene)
	assert_gt(site, -1, "the test island parks the fixture cars")
	var parked: ParkedCars = scene.get_node("ParkedCars")
	var id := String(parked.streamer.sites.car_id[site])
	var cars := (_save.profile[_save.KEY_CARS] as Array).size()
	_drive_onto(scene, site)
	assert_eq((_save.profile[_save.KEY_CARS] as Array).size(), cars + 1, "it joins the garage")
	assert_true(ParkedCars.model_owned(id))
	assert_false(parked.waiting(site), "and isn't there to be found again")
	assert_true(parked.parked(site), "but it stays on its pad, in front of the player")
	assert_true((scene.get_node("CheckpointBanner") as CheckpointBanner).is_showing_banner(), "a Car found band")
	assert_false(get_tree().paused, "while the car drives on")
	assert_null(ConfirmPopup.any_open(get_tree()), "no modal")
	var minimap: MiniMap = scene.get_node("MiniMapLayer/MiniMap")
	minimap.update_prompt_label()
	assert_true(minimap.prompt_label.visible and "DRIVE IT" in minimap.prompt_label.text, "the prompt offers to drive it")
	var p := parked.streamer.sites.pos[site] + Vector2(parked.streamer.sites.radius[site] + 5.0, 0.0)
	(scene.get_node("Car") as Node3D).global_position = Vector3(p.x, 0.0, p.y)
	parked._physics_process(0.0)
	assert_true(parked.offer().is_empty(), "leaving the pad withdraws the offer")
	assert_false(parked.switch_here())
	assert_ne(String(WorldSession.active_car()["model_id"]), id, "still in the same car")
	_drive_onto(scene, site)
	assert_eq((_save.profile[_save.KEY_CARS] as Array).size(), cars + 1, "a car is found once")
	assert_eq(String(parked.offer().get("model_id", "")), id, "coming back to the pad offers it again")


func test_enter_on_the_pad_switches_to_the_found_car_and_reloads_the_world() -> void:
	var scene := await _boot()
	var site := _car_site(scene)
	var parked: ParkedCars = scene.get_node("ParkedCars")
	_drive_onto(scene, site)
	_press_select(parked)
	assert_eq(String(WorldSession.active_car()["model_id"]), String(parked.streamer.sites.car_id[site]))
	assert_eq(Scenes.last_blocked_path, Scenes.FREE_ROAM, "the world reloads around the new car")
	var pose: Transform3D = WorldSession.pose_transform()
	var pad := parked.pad_pose(site)
	assert_almost_eq(Vector2(pose.origin.x, pose.origin.z), Vector2(pad.origin.x, pad.origin.z), Vector2.ONE * 0.01,
		"the new car stands where it was parked")
	assert_almost_eq(pose.basis.z, pad.basis.z, Vector3.ONE * 0.01, "facing the way it was parked")


func test_a_wrecked_car_on_the_pad_cant_switch_to_the_found_car() -> void:
	var scene := await _boot()
	var site := _car_site(scene)
	var parked: ParkedCars = scene.get_node("ParkedCars")
	var before := String(WorldSession.active_car()["model_id"])
	_drive_onto(scene, site)
	parked.rest_stops.is_wrecked = true
	assert_true(parked.offer().is_empty(), "no offer while wrecked")
	_press_select(parked)
	assert_eq(String(WorldSession.active_car()["model_id"]), before, "the wreck plays out in the same car")


func test_a_found_car_is_not_parked_again_when_the_world_next_loads() -> void:
	var scene := await _boot()
	var site := _car_site(scene)
	var parked: ParkedCars = scene.get_node("ParkedCars")
	_drive_onto(scene, site)
	var again := ParkedCars.new()
	again.streamer = parked.streamer
	add_child_autofree(again)
	assert_false(again.parked(site), "found already: nothing on its pad next time")


func test_no_car_is_found_during_the_cold_open() -> void:
	var scene := await _boot()
	WorldSession.set_cold_open_pending(true)
	var site := _car_site(scene)
	_drive_onto(scene, site)
	WorldSession.set_cold_open_pending(false)
	assert_true((scene.get_node("ParkedCars") as ParkedCars).waiting(site), "it waits for the cold open to end")


# --- on the maps -----------------------------------------------------------------------------------

func test_a_car_shows_as_a_key_once_its_side_road_is_seen_and_until_it_is_found() -> void:
	WorldSession.new_world(7, String(CarLibrary.all()[0]["id"]))
	var cars := LootRules.cars_to_find(_settings())
	var sites: RoadSites = _world(_settings(), cars)[2]
	var site := sites.of_kind(RoadSites.Kind.CAR)[0]
	var keys := func() -> Array:
		return MiniMap.site_markers(sites, {}, Vector2.ZERO, INF).filter(
			func(mk: Array) -> bool: return mk[1] == MiniMap.Marker.CAR_KEY).map(func(mk: Array) -> int: return mk[2])
	assert_false(keys.call().has(site), "not before it's seen")
	MiniMap.mark_seen_near(sites, sites.branch[site], 1.0)
	assert_true(keys.call().has(site), "passing where its side road starts is enough")
	Save.grant_car(String(sites.car_id[site]))
	assert_false(keys.call().has(site), "gone once the car is owned")


func test_each_waiting_car_is_parked_on_its_pad_warmed_at_boot_and_gone_once_found() -> void:
	var scene := await _boot()
	var host: ParkedCars = scene.get_node("ParkedCars")
	var parked := ParkedCars.new()
	parked.streamer = host.streamer
	parked.show_props = true
	add_child_autofree(parked)
	var sites := parked.streamer.sites
	var site := _car_site(scene)
	assert_true(parked.is_parked(site), "a waiting car stands on its pad")
	var pivot: Node3D = parked._props[site]
	var pad := Vector3(sites.pos[site].x, sites.pad_h[site], sites.pos[site].y)
	assert_almost_eq(pivot.global_position, pad, Vector3.ONE * 0.01)
	assert_eq(pivot.get_child_count(), 1, "holding the car's model")
	var body: CollisionObject3D = pivot.get_child(0)
	var layer := body.collision_layer
	parked.warm_up(Vector3(0.0, 500.0, 0.0))
	assert_gt(pivot.global_position.distance_to(pad), 1.0, "the warm-up shows it to the camera")
	assert_eq(body.collision_layer, 0, "with nothing solid in the way meanwhile")
	parked.clear_warm_up()
	assert_almost_eq(pivot.global_position, pad, Vector3.ONE * 0.01, "and puts it back")
	assert_eq(body.collision_layer, layer, "solid again")
	await get_tree().physics_frame
	var at := pad + Vector3.UP * 0.5
	var ray := PhysicsRayQueryParameters3D.create(at + Vector3.RIGHT * 10.0, at)
	assert_eq(parked.get_world_3d().direct_space_state.intersect_ray(ray).get("collider"), body, "a car driving into it hits it")
	var rest := body.global_position
	await get_tree().physics_frame
	assert_eq(body.global_position, rest, "and it doesn't move")
	parked.take(site)
	assert_true(parked.is_parked(site), "found, its model stays on the pad")


func test_the_garage_shows_each_car_not_found_yet_with_its_region() -> void:
	var scene := await _boot()
	var page: RestStopPage = scene.get_node("RestStopPage")
	var sites := page.loot.streamer.sites
	var site := _car_site(scene)
	var card: Dictionary = page.unfound_cards().filter(func(c: Dictionary) -> bool:
		return c["title"] == String(CarLibrary.by_id(String(sites.car_id[site]))["name"]))[0]
	assert_eq(card["desc"], "%s region" % RegionBanner.name_for(page.loot.streamer.settings, sites.ring[site]))
	assert_eq(card["subtitle"], "Not found yet")
	assert_true(card["disabled"])
	_drive_onto(scene, site)
	assert_false(page.unfound_cards().any(func(c: Dictionary) -> bool: return c["title"] == card["title"]), "found, it's an owned car")
