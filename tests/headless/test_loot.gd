extends GutTest
# Free-roam loot (features/loot.md): the ring tables and their placement, fitting parts through
# the owned-car funnel, and the loot loop in the world: collect, carry, bank, drop at the wreck,
# recover, rumours, and the rest-stop Parts / Garage / Journal pages. A synthetic car roster
# throughout (CarFixtures); the boost catalogue is iterated whole, as opaque input.

const TEST_PATH := "user://test_loot_profile.json"

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


func _settings() -> FreeRoamSettings:
	var s := FreeRoamSettings.new()
	s.world_seed = 7
	s.island_radius_m = 3000.0
	s.near_radius = 1
	s.far_radius = 3
	return s


func _sites(s: FreeRoamSettings) -> RoadSites:
	var net := RoadNetwork.new()
	var terrain := RoadTerrain.new()
	terrain.setup(s, net)
	net.build(s, terrain)
	var sites := RoadSites.new()
	sites.build(s, net, terrain)
	return sites


# --- tables and placement -------------------------------------------------------------------------

func test_every_car_is_in_exactly_one_ring_cheapest_innermost() -> void:
	var tables := LootLibrary.ring_tables(4)
	var ring_of := {}
	for r in tables.size():
		for item: Dictionary in tables[r]:
			if item["kind"] == "car":
				assert_false(ring_of.has(item["id"]), "%s appears once" % item["id"])
				ring_of[item["id"]] = r
	assert_eq(ring_of.size(), CarLibrary.all().size())
	for a: Dictionary in CarLibrary.all():
		for b: Dictionary in CarLibrary.all():
			if int(a.get("cost", 0)) < int(b.get("cost", 0)):
				assert_true(ring_of[a["id"]] <= ring_of[b["id"]], "a cheaper car is never further out")


func test_every_ring_has_each_part_at_its_own_level_and_a_rumour_of_the_next() -> void:
	var tables := LootLibrary.ring_tables(4)
	for r in 4:
		var parts := {}
		var rumours := []
		for item: Dictionary in tables[r]:
			if item["kind"] == "part" and not LootLibrary.is_engine(item) and not LootLibrary.is_drivetrain(item):
				parts[item["id"]] = int(item["level"])
			if item["kind"] == "rumour":
				rumours.append(int(item["ring"]))
		for id in BoostLibrary.CATALOGUE.keys():
			assert_eq(parts.get(id, -1), r, "%s at level %d in ring %d" % [id, r, r])
		assert_eq(rumours, [r + 1] if r < 3 else [], "ring %d's rumour" % r)


func test_placement_is_seeded_and_puts_each_item_on_one_site() -> void:
	var s := _settings()
	var sites := _sites(s)
	var a := LootLibrary.place(sites, s.ring_count, s.world_seed)
	var b := LootLibrary.place(sites, s.ring_count, s.world_seed)
	assert_eq(a, b, "the same world places the same loot")
	assert_gt(a.size(), 0)
	var keys := {}
	for site: int in a.keys():
		assert_ne(sites.kind[site], RoadSites.Kind.REST, "no loot at rest stops")
		var k := LootLibrary.item_key(a[site])
		assert_false(keys.has(k), "%s is placed once" % k)
		keys[k] = true


func test_dead_ends_are_filled_first_with_the_best_items() -> void:
	var s := _settings()
	var sites := _sites(s)
	var placed := LootLibrary.place(sites, s.ring_count, s.world_seed)
	var dead_ends := sites.of_kind(RoadSites.Kind.DEAD_END)
	assert_gt(dead_ends.size(), 0)
	for i in dead_ends:
		assert_true(placed.has(i), "dead end %d has a payoff" % i)
	for site: int in placed.keys():
		if placed[site]["kind"] == "car" and sites.kind[site] == RoadSites.Kind.LOOT:
			# a car on a roadside slot means its ring had more cars than dead ends
			var ring := sites.ring[site]
			for d in dead_ends:
				if sites.ring[d] == ring:
					assert_eq(placed[d]["kind"], "car", "a dead end in ring %d took a car first" % ring)


# --- parts on a car ---------------------------------------------------------------------------------

func test_fitted_parts_reach_the_car_only_through_the_funnel_keys() -> void:
	var owned := {"model_id": String(CarLibrary.all()[0]["id"]), "instance_id": 1, "tuning": {},
		"parts": [{"kind": "part", "id": String(BoostLibrary.CATALOGUE.keys()[0]), "level": 2},
			{"kind": "part", "id": "engine_swap:some_engine"},
			{"kind": "part", "id": "drivetrain:%d" % Drivetrain.DriveMode.AWD}]}
	var f := LootLibrary.fielded(owned)
	assert_eq((f["boosts"] as Array).size(), 1)
	assert_eq(f["boosts"][0]["id"], BoostLibrary.CATALOGUE.keys()[0])
	assert_eq(f["boosts"][0]["effect"], BoostLibrary.magnitude_for(String(BoostLibrary.CATALOGUE.keys()[0]), 2))
	assert_eq(f["swapped_engine"], "some_engine")
	assert_eq(f["drivetrain_override"], Drivetrain.DriveMode.AWD)
	assert_false(owned.has("boosts"), "the saved car is untouched")
	var bare := LootLibrary.fielded({"model_id": "x", "parts": []})
	assert_eq(bare["boosts"], [])
	assert_false(bare.has("swapped_engine") or bare.has("drivetrain_override"))


func test_one_of_each_part_one_engine_and_no_kit_for_the_cars_own_layout() -> void:
	var car: Dictionary = CarLibrary.all()[0]
	var owned := {"model_id": String(car["id"]), "parts": [{"kind": "part", "id": "grip", "level": 0},
		{"kind": "part", "id": "engine_swap:a"}]}
	assert_false(LootLibrary.can_fit(owned, {"kind": "part", "id": "grip", "level": 3}), "one of each")
	assert_eq(LootLibrary.occupant(owned, {"kind": "part", "id": "engine_swap:b"})["id"], "engine_swap:a", "the engine slot is taken")
	var own_mode := int(car.get("drive_mode", CarLibrary.RWD))
	assert_false(LootLibrary.can_fit(owned, {"kind": "part", "id": "drivetrain:%d" % own_mode}))
	assert_false(LootLibrary.can_fit(owned, {"kind": "car", "id": "anything"}), "a car isn't a part")


# --- in the world ----------------------------------------------------------------------------------

func _boot() -> Node3D:
	WorldSession.new_world(7, String(CarLibrary.all()[0]["id"]))
	var scene: Node3D = load("res://free_roam.tscn").instantiate()
	(scene.get_node("Terrain") as TerrainStreamer).settings = _settings()
	add_child_autofree(scene)
	await get_tree().physics_frame
	return scene


func _site_with(loot: LootDirector, pred: Callable) -> int:
	for site: int in loot.placement.keys():
		if pred.call(loot.placement[site]):
			return site
	return -1


func _drive_to(scene: Node3D, p: Vector2) -> void:
	var st: TerrainStreamer = scene.get_node("Terrain")
	st.prefill_at(p)
	(scene.get_node("Car") as VehicleBody3D).reset_to(Transform3D(Basis.IDENTITY, Vector3(p.x, st.height_at(p.x, p.y) + 1.0, p.y)))
	await get_tree().physics_frame


func test_driving_to_loot_carries_it_and_a_rest_stop_banks_it() -> void:
	var scene := await _boot()
	var loot: LootDirector = scene.get_node("LootDirector")
	var st: TerrainStreamer = scene.get_node("Terrain")
	var part_site := _site_with(loot, func(i: Dictionary) -> bool: return i["kind"] == "part")
	await _drive_to(scene, st.sites.pos[part_site])
	loot.step()
	assert_true(loot.is_collected(part_site))
	assert_eq(WorldSession.list("carried").size(), 1, "carried, not yet yours")
	assert_true(loot.loot_at(part_site).is_empty(), "it's gone from the world")
	var page: RestStopPage = scene.get_node("RestStopPage")
	page.open(0)
	assert_eq(page.banked.size(), 1)
	assert_eq(WorldSession.list("carried").size(), 0)
	assert_eq(WorldSession.list("stash").size(), 1, "banked into the stash")
	page.close()


func test_a_banked_car_title_joins_the_garage() -> void:
	var scene := await _boot()
	var loot: LootDirector = scene.get_node("LootDirector")
	var car_site := _site_with(loot, func(i: Dictionary) -> bool: return i["kind"] == "car")
	loot.collect(car_site)
	var before := (_save.profile[_save.KEY_CARS] as Array).size()
	loot.bank()
	assert_eq((_save.profile[_save.KEY_CARS] as Array).size(), before + 1)


func test_a_rumour_reveals_its_ring_on_the_spot() -> void:
	var scene := await _boot()
	var loot: LootDirector = scene.get_node("LootDirector")
	var site := _site_with(loot, func(i: Dictionary) -> bool: return i["kind"] == "rumour")
	var ring := int(loot.placement[site]["ring"])
	assert_false(loot.is_revealed(ring))
	loot.collect(site)
	assert_true(loot.is_revealed(ring))
	assert_eq(WorldSession.list("carried").size(), 0, "a rumour is read, not carried")
	var names := []
	for r: Dictionary in loot.journal():
		names.append(r["ring"])
	assert_true(ring in names, "the journal lists the revealed ring")


func test_giving_up_drops_the_loot_at_the_wreck_and_driving_back_recovers_it() -> void:
	var scene := await _boot()
	var loot: LootDirector = scene.get_node("LootDirector")
	var site := _site_with(loot, func(i: Dictionary) -> bool: return i["kind"] == "part")
	loot.collect(site)
	var wreck := Vector3(30, 5, 40)
	loot.drop_at(wreck)
	assert_eq(WorldSession.list("carried").size(), 0)
	assert_false(WorldSession.dropped().is_empty())
	assert_not_null(loot.get_node_or_null("DroppedLoot"), "a beacon marks the drop")
	await _drive_to(scene, Vector2(wreck.x, wreck.z))
	loot.step()
	assert_eq(WorldSession.list("carried").size(), 1, "picked back up")
	assert_true(WorldSession.dropped().is_empty())


func test_a_second_drop_replaces_the_first() -> void:
	var scene := await _boot()
	var loot: LootDirector = scene.get_node("LootDirector")
	var parts: Array = []
	for site: int in loot.placement.keys():
		if loot.placement[site]["kind"] == "part":
			parts.append(site)
	loot.collect(parts[0])
	loot.drop_at(Vector3(10, 0, 10))
	loot.collect(parts[1])
	loot.drop_at(Vector3(-20, 0, 15))
	var d := WorldSession.dropped()
	assert_eq((d["items"] as Array).size(), 1)
	assert_eq(int(d["items"][0]["site"]), parts[1], "the first drop is lost for good")


func test_the_parts_page_fits_and_removes_parts_and_reloads_the_car_on_close() -> void:
	var scene := await _boot()
	var page: RestStopPage = scene.get_node("RestStopPage")
	WorldSession.set_list("stash", [{"kind": "part", "id": "grip", "level": 1}])
	page.open(0)
	watch_signals(page)
	page._show(RestStopPage.View.PARTS)
	page.row("+").pressed.emit()
	assert_eq(WorldSession.list("stash").size(), 0)
	assert_eq((WorldSession.active_car().get("parts", []) as Array).size(), 1, "fitted, and saved on the car")
	page.row("-").pressed.emit()
	assert_eq(WorldSession.list("stash").size(), 1, "and back in the stash")
	page.close()
	assert_signal_emitted(page, "car_changed")


func test_the_garage_switches_the_active_car() -> void:
	var scene := await _boot()
	var page: RestStopPage = scene.get_node("RestStopPage")
	var second: Dictionary = _save.grant_car(String(CarLibrary.all()[1]["id"]))
	page.open(0)
	page._show(RestStopPage.View.GARAGE)
	var rows := page.rows()
	assert_true(rows[0].disabled, "the car being driven")
	rows[1].pressed.emit()
	assert_eq(int(WorldSession.active_car()["instance_id"]), int(second["instance_id"]))
	page.close()


func test_the_journal_and_parts_pages_are_navigable() -> void:
	var scene := await _boot()
	var page: RestStopPage = scene.get_node("RestStopPage")
	page.open(0)
	page.row("journal").pressed.emit()
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(page.view, RestStopPage.View.JOURNAL)
	assert_eq(page.get_viewport().gui_get_focus_owner(), page.row("< back"))
	var e := InputEventAction.new()
	e.action = "ui_cancel"
	e.pressed = true
	MenuNav.of(page._page)._unhandled_input(e)
	await get_tree().process_frame
	assert_eq(page.view, RestStopPage.View.MAIN)
	page.close()
