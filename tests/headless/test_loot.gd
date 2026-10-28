extends GutTest
# Free-roam coins and shops (features/loot.md): the ring tables and prices, fitting parts through
# the owned-car funnel, and the economy in the world: picking up coins, dropping the money on a wreck,
# buying at a checkpoint, and the rest-stop Parts / Garage pages. A synthetic car
# roster throughout (CarFixtures); the boost catalogue is iterated whole, as opaque input.

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
	s.mid_radius = 1
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


# --- tables and prices -------------------------------------------------------------------------

func _ring_of(tables: Array) -> Dictionary:
	var out := {}
	for r in tables.size():
		for item: Dictionary in tables[r]:
			var key := LootRules.item_key(item)
			assert_false(out.has(key), "%s appears once" % key)
			out[key] = r
	return out


func test_every_car_engine_kit_and_part_lands_once_in_its_own_ring() -> void:
	var ring_of := _ring_of(LootRules.ring_tables(4))
	for car: Dictionary in CarLibrary.all():
		assert_eq(ring_of.get("car:" + String(car["id"]), -1), int(car["ring"]), "%s in its ring" % car["id"])
	for e: Dictionary in EngineLibrary.all():
		if bool(e.get("swap_tier", false)):
			assert_eq(ring_of.get("part:engine_swap:%s:0" % e["id"], -1), int(e["ring"]), "%s in its ring" % e["id"])
	for mode in LootRules.KITS:
		assert_eq(ring_of.get("part:drivetrain:%d:0" % mode, -1), int(LootRules.KITS[mode]["ring"]), "kit %d in its ring" % mode)
	for id in BoostLibrary.CATALOGUE.keys():
		var r := int(BoostLibrary.CATALOGUE[id]["ring"])
		assert_eq(ring_of.get("part:%s:%d" % [id, r], -1), r, "%s in its ring at level = ring" % id)


func test_rings_past_the_ring_count_fold_into_the_last() -> void:
	var tables := LootRules.ring_tables(2)
	for car: Dictionary in CarLibrary.all():
		var want := mini(int(car["ring"]), 1)
		assert_true(tables[want].any(func(i: Dictionary) -> bool: return i["kind"] == "car" and i["id"] == car["id"]),
			"%s folds into ring %d" % [car["id"], want])


func test_starter_cars_are_the_ring_0_cars() -> void:
	for car: Dictionary in CarLibrary.all():
		assert_eq(LootRules.starter_cars().has(String(car["id"])), int(car["ring"]) == 0, String(car["id"]))


# Catalogue contract on the SHIPPED data: an entry without a ring on the island could never go on
# sale, and one without a price would be free.
func test_shipped_cars_engines_and_parts_each_name_a_ring_on_the_island_and_a_price() -> void:
	CarFixtures.restore()
	var rings := FreeRoamSettings.new().ring_count
	var check := func(who: String, entry: Dictionary) -> void:
		assert_true(entry.get("ring") is int and int(entry["ring"]) >= 0 and int(entry["ring"]) < rings,
			"%s has a ring in 0..%d" % [who, rings - 1])
		assert_gt(int(entry.get("price", 0)), 0, "%s has a price" % who)
	for car: Dictionary in CarLibrary.all():
		check.call(String(car["id"]), car)
	for e: Dictionary in EngineLibrary.all():
		if bool(e.get("swap_tier", false)):
			check.call(String(e["id"]), e)
	for id in BoostLibrary.CATALOGUE.keys():
		check.call(String(id), BoostLibrary.CATALOGUE[id])
	for mode in Drivetrain.DriveMode.values():
		assert_true(LootRules.KITS.has(mode), "kit %d has a ring" % mode)
		assert_gt(LootRules.price({"kind": "part", "id": "drivetrain:%d" % mode}), 0, "kit %d has a price" % mode)
	assert_false(LootRules.starter_cars().is_empty(), "ring 0 has a starter car")


func test_a_ring_with_no_rest_stop_is_sold_in_the_nearest_ring_that_has_one() -> void:
	assert_eq(LootRules.pool_rings(PackedInt32Array([1, 0, 2, 0])), [[0, 1], [], [2, 3], []],
		"rings 1 and 3 have no rest stop: their stock goes to the nearest ring that does (inward first)")


func test_a_price_comes_from_the_items_own_entry() -> void:
	var car: Dictionary = CarLibrary.all()[0]
	assert_eq(LootRules.price({"kind": "car", "id": String(car["id"])}), int(car.get("price", 0)))
	var id: String = BoostLibrary.CATALOGUE.keys()[0]
	assert_eq(LootRules.price({"kind": "part", "id": id, "level": 0}), int(BoostLibrary.CATALOGUE[id]["price"]))


# --- parts on a car ---------------------------------------------------------------------------------

func test_switched_on_parts_reach_the_car_only_through_the_funnel_keys() -> void:
	var owned := {"model_id": String(CarLibrary.all()[0]["id"]), "instance_id": 1, "tuning": {},
		"parts": [{"kind": "part", "id": String(BoostLibrary.CATALOGUE.keys()[0]), "level": 2},
			{"kind": "part", "id": "engine_swap:some_engine"},
			{"kind": "part", "id": "drivetrain:%d" % Drivetrain.DriveMode.AWD}]}
	var f := LootRules.fielded(owned)
	assert_eq((f["boosts"] as Array).size(), 1)
	assert_eq(f["boosts"][0]["id"], BoostLibrary.CATALOGUE.keys()[0])
	assert_eq(f["boosts"][0]["effect"], BoostLibrary.magnitude_for(String(BoostLibrary.CATALOGUE.keys()[0]), 2))
	assert_eq(f["swapped_engine"], "some_engine")
	assert_eq(f["drivetrain_override"], Drivetrain.DriveMode.AWD)
	assert_false(owned.has("boosts"), "the saved car is untouched")
	var bare := LootRules.fielded({"model_id": "x", "parts": []})
	assert_eq(bare["boosts"], [])
	assert_false(bare.has("swapped_engine") or bare.has("drivetrain_override"))


func test_parts_switched_off_dont_reach_the_car() -> void:
	var owned := {"model_id": String(CarLibrary.all()[0]["id"]), "parts": [
		{"kind": "part", "id": "engine_swap:some_engine", "on": false},
		{"kind": "part", "id": "drivetrain:%d" % Drivetrain.DriveMode.AWD, "on": false}]}
	var f := LootRules.fielded(owned)
	assert_false(f.has("swapped_engine") or f.has("drivetrain_override"))


func test_one_of_each_part_and_no_kit_for_the_cars_own_layout() -> void:
	var owned := {"model_id": String(CarLibrary.all()[0]["id"]), "parts": [{"kind": "part", "id": "grip", "level": 0}]}
	var own := UpgradeLibrary.stock_drive_mode(owned)
	assert_eq(LootRules.fit_block_reason(owned, {"kind": "part", "id": "grip", "level": 3}), "Already unlocked", "one of each")
	assert_eq(LootRules.fit_block_reason(owned, {"kind": "part", "id": "drivetrain:%d" % own}),
		"Already " + CarLibrary.drive_text(own), "a kit for the car's own layout would do nothing")
	assert_true(LootRules.can_fit(owned, {"kind": "part", "id": "engine_swap:a"}))
	assert_false(LootRules.can_fit(owned, {"kind": "car", "id": "anything"}), "a car isn't a part")


func test_a_cars_upgrade_count_is_its_unlocked_parts_on_or_off_out_of_every_part_it_could_have() -> void:
	var owned := {"model_id": String(CarLibrary.all()[0]["id"]), "parts": [
		{"kind": "part", "id": "grip", "level": 0, "on": true}, {"kind": "part", "id": "turbo", "level": 0, "on": false}]}
	var own := UpgradeLibrary.stock_drive_mode(owned)
	var all := LootRules.parts_for(owned)
	var keys := {}
	for item: Dictionary in all:
		assert_eq(String(item["kind"]), "part", "only parts count")
		keys[LootRules.item_key(item)] = true
	assert_false(keys.has(LootRules.item_key({"kind": "part", "id": "drivetrain:%d" % own})),
		"the kit for the car's own layout can never be fitted, so it isn't counted")
	var catalogue := 0
	for table: Array in LootRules.ring_tables(1):
		for item: Dictionary in table:
			if String(item["kind"]) == "part":
				catalogue += 1
	assert_eq(all.size(), catalogue - 1, "every other part in the catalogue counts")
	assert_eq(LootRules.upgrades_text(owned), "2 / %d upgrades" % all.size(), "switched-off parts still count as bought")
	assert_eq(LootRules.upgrades_text({"model_id": owned["model_id"]}), "0 / %d upgrades" % all.size())


func test_switching_an_engine_or_kit_on_switches_the_other_one_off() -> void:
	var parts := [{"kind": "part", "id": "engine_swap:a", "on": true}, {"kind": "part", "id": "engine_swap:b", "on": false},
		{"kind": "part", "id": "grip", "level": 0, "on": true}]
	var on_b := LootRules.toggled(parts, 1)
	assert_eq(on_b.map(func(p: Dictionary) -> bool: return LootRules.is_on(p)), [false, true, true],
		"one engine at a time; other parts are left alone")
	assert_eq(LootRules.toggled(on_b, 1).map(func(p: Dictionary) -> bool: return LootRules.is_on(p)), [false, false, true],
		"switching it off again leaves the stock engine")
	assert_true(LootRules.is_on(parts[0]), "the input is untouched")


# --- in the world ----------------------------------------------------------------------------------

func _boot() -> Node3D:
	WorldSession.new_world(7, String(CarLibrary.all()[0]["id"]))
	var scene: Node3D = load("res://free_roam.tscn").instantiate()
	(scene.get_node("Terrain") as TerrainStreamer).settings = _settings()
	add_child_autofree(scene)
	await get_tree().physics_frame
	return scene


func _coin_site(loot: LootDirector) -> int:
	for i in loot.streamer.sites.count():
		if not loot.loot_at(i).is_empty():
			return i
	return -1


func _drive_to(scene: Node3D, p: Vector2) -> void:
	var st: TerrainStreamer = scene.get_node("Terrain")
	st.prefill_at(p)
	(scene.get_node("Car") as VehicleBody3D).reset_to(Transform3D(Basis.IDENTITY, Vector3(p.x, st.height_at(p.x, p.y) + 1.0, p.y)))
	await get_tree().physics_frame


func test_every_loot_spot_holds_a_coin_and_rest_stops_none() -> void:
	var scene := await _boot()
	var loot: LootDirector = scene.get_node("LootDirector")
	var sites := loot.streamer.sites
	for i in sites.count():
		assert_eq(loot.loot_at(i).is_empty(), sites.kind[i] == RoadSites.Kind.REST, "site %d" % i)


func test_driving_to_a_coin_adds_its_value_and_spends_the_spot() -> void:
	var scene := await _boot()
	var loot: LootDirector = scene.get_node("LootDirector")
	var st: TerrainStreamer = scene.get_node("Terrain")
	var site := _coin_site(loot)
	var value := int(loot.loot_at(site)["value"])
	await _drive_to(scene, st.sites.pos[site])
	loot.step()
	assert_true(loot.is_collected(site))
	assert_eq(WorldSession.money(), value)
	assert_true(loot.loot_at(site).is_empty(), "the coin is gone")
	loot.step()
	assert_eq(WorldSession.money(), value, "a spent spot pays once")
	loot._physics_process(0.0)
	assert_string_contains(loot.money_label.text, str(value), "the corner counter shows the money")
	assert_eq(loot.money_label.get_parent(), scene.get_node("HUD"), "on the HUD, so it hides under paused pages")


# A coin is picked up by driving past it at speed, anywhere on the road beside its pad: the check
# sweeps the step's whole travel, so even a fast car on the far lane can't skip over it.
func test_driving_past_a_coin_on_the_far_lane_at_speed_picks_it_up() -> void:
	var scene := await _boot()
	var loot: LootDirector = scene.get_node("LootDirector")
	loot.set_physics_process(false)
	var sites := (scene.get_node("Terrain") as TerrainStreamer).sites
	var s := (scene.get_node("Terrain") as TerrainStreamer).settings
	var site := _coin_site(loot)
	var away := (sites.pos[site] - sites.anchor[site]).normalized()
	var far_lane := sites.anchor[site] - away * s.road_half_width_m * 0.6
	var d := sites.dir[site]
	loot._last_p = far_lane - d * 15.0
	var to := far_lane + d * 15.0
	(scene.get_node("Car") as Node3D).global_position = Vector3(to.x, 0.0, to.y)
	loot.step()
	assert_true(loot.is_collected(site), "picked up in passing")


func test_a_teleport_past_a_coin_does_not_pick_it_up() -> void:
	var scene := await _boot()
	var loot: LootDirector = scene.get_node("LootDirector")
	loot.set_physics_process(false)
	var sites := (scene.get_node("Terrain") as TerrainStreamer).sites
	var site := _coin_site(loot)
	var d := sites.dir[site]
	loot._last_p = sites.anchor[site] - d * 400.0
	var to := sites.anchor[site] + d * 400.0
	(scene.get_node("Car") as Node3D).global_position = Vector3(to.x, 0.0, to.y)
	loot.step()
	assert_false(loot.is_collected(site), "a jump across the map isn't driving past")


# A short hop (well under the 100 m guard) over a coin is a teleport, not a drive past.
func test_a_short_teleport_over_a_coin_does_not_pick_it_up() -> void:
	var scene := await _boot()
	var loot: LootDirector = scene.get_node("LootDirector")
	loot.set_physics_process(false)
	var sites := (scene.get_node("Terrain") as TerrainStreamer).sites
	var site := _coin_site(loot)
	var d := sites.dir[site]
	var from := sites.anchor[site] - d * 40.0
	var to := sites.anchor[site] + d * 40.0
	loot._last_p = from
	(scene.get_node("Car") as Node3D).global_position = Vector3(to.x, 0.0, to.y)
	loot.car_teleported(to)
	loot.step()
	assert_false(loot.is_collected(site), "a teleport over the pad isn't driving past")


func test_giving_up_drops_all_the_money_at_the_wreck_and_brings_every_coin_back() -> void:
	var scene := await _boot()
	var loot: LootDirector = scene.get_node("LootDirector")
	var site := _coin_site(loot)
	loot.collect(site)
	var had := WorldSession.money()
	assert_gt(had, 0)
	(scene.get_node("Car").damage as DamageModel).gave_up.emit()
	assert_eq(WorldSession.money(), 0, "a wreck takes it all")
	assert_eq(int(WorldSession.dropped().get("money", 0)), had, "and leaves it at the wreck")
	assert_not_null(loot.get_node_or_null("DroppedMoney"), "under a crystal")
	assert_eq(loot.lost, had, "and the wreck page can say how much")
	assert_false(loot.is_collected(site), "the coin is back on the road")
	await _drive_to(scene, loot.streamer.sites.pos[site])
	loot.step()
	assert_eq(WorldSession.money(), 0, "a wrecked car picks nothing up until it respawns")
	(scene.get_node("RestStops") as RestStops).respawned.emit(0, Vector3.ZERO)
	loot._last_p = loot.streamer.sites.pos[site]
	loot.step()
	assert_eq(WorldSession.money(), had, "and after the respawn the coin pays again")


func test_only_unlocked_rings_sell_and_only_what_the_player_lacks() -> void:
	var scene := await _boot()
	var loot: LootDirector = scene.get_node("LootDirector")
	var stock := loot.ring_stock()
	var keys := func(items: Array) -> Array: return items.map(LootRules.item_key)
	var want: Array = keys.call(stock[0])
	want.erase(LootRules.item_key({"kind": "car", "id": String(WorldSession.active_car()["model_id"])}))
	assert_eq(keys.call(loot.for_sale()), want, "ring 0 only, without the car already owned")
	var ring := -1
	for r in range(1, stock.size()):
		if ring < 0 and not (stock[r] as Array).is_empty():
			ring = r
	assert_gt(ring, 0, "the test island sells something past ring 0")
	loot.unlock(ring)
	assert_true(keys.call(loot.for_sale()).has(LootRules.item_key(stock[ring][0])), "lighting a checkpoint there unlocks it")


func test_buying_spends_the_money_and_a_car_joins_the_garage_and_a_part_is_handed_back_to_unlock() -> void:
	var scene := await _boot()
	var loot: LootDirector = scene.get_node("LootDirector")
	for r in 4:
		loot.unlock(r)
	var car: Dictionary = loot.for_sale().filter(func(i: Dictionary) -> bool: return i["kind"] == "car")[0]
	var part: Dictionary = loot.for_sale().filter(func(i: Dictionary) -> bool:
		return i["kind"] == "part" and LootRules.can_fit(WorldSession.active_car(), i))[0]
	WorldSession.set_money(LootRules.price(car) + LootRules.price(part))
	var cars := (_save.profile[_save.KEY_CARS] as Array).size()
	assert_eq(String(loot.buy(car).get("model_id", "")), String(car["id"]), "returns the new owned car")
	assert_eq((_save.profile[_save.KEY_CARS] as Array).size(), cars + 1, "the car is owned")
	assert_eq(loot.buy(part), part)
	assert_eq(WorldSession.money(), 0)
	assert_false(loot.for_sale().has(car), "bought things leave the shop")


func test_the_player_cant_buy_what_they_cant_afford() -> void:
	var scene := await _boot()
	var loot: LootDirector = scene.get_node("LootDirector")
	var item: Dictionary = loot.for_sale()[0]
	WorldSession.set_money(LootRules.price(item) - 1)
	assert_true(loot.buy(item).is_empty())
	assert_eq(WorldSession.money(), LootRules.price(item) - 1, "nothing is spent")


# The parts and garage tests below count cards; with nothing on sale, only the player's own show.
func _nothing_for_sale() -> void:
	WorldSession.set_list("revealed", [])


func test_the_parts_page_sells_parts_and_buying_one_switches_it_on() -> void:
	var scene := await _boot()
	var page: RestStopPage = scene.get_node("RestStopPage")
	var sale: Array = page.loot.for_sale().filter(func(i: Dictionary) -> bool:
		return i["kind"] == "part" and LootRules.fit_block_reason(WorldSession.active_car(), i).is_empty())
	var part: Dictionary = sale[0]
	WorldSession.set_money(LootRules.price(part))
	page.open(0)
	page._show(RestStopPage.View.PARTS)
	assert_eq(page.cards().card_count(), sale.size(), "a card per part on sale")
	for k in sale.size():
		assert_eq(page.cards()._cards[k].disabled, LootRules.price(sale[k]) > WorldSession.money(), "card %d" % k)
	watch_signals(page)
	_confirm(page.cards(), 0)
	assert_eq(WorldSession.money(), 0, "bought")
	var on := part.duplicate()
	on["on"] = true
	assert_eq(WorldSession.active_car().get("parts", []), [on], "unlocked for this car and switched on")
	assert_false(page.loot.for_sale().has(part), "this car can't buy it twice")
	page.close()
	assert_signal_emitted(page, "car_changed", "the car is re-fielded with it")


func test_the_garage_sells_cars_and_buying_one_switches_to_it() -> void:
	var scene := await _boot()
	var page: RestStopPage = scene.get_node("RestStopPage")
	var cars: Array = page.loot.for_sale().filter(func(i: Dictionary) -> bool: return i["kind"] == "car")
	var car: Dictionary = cars[0]
	WorldSession.set_money(LootRules.price(car))
	page.open(0)
	page._show(RestStopPage.View.GARAGE)
	assert_eq(page.cards().card_count(), 1 + cars.size(), "the car owned, then a card per car on sale")
	watch_signals(page)
	_confirm(page.cards(), 1)
	assert_eq(String(WorldSession.active_car()["model_id"]), String(car["id"]), "driving the car just bought")
	assert_eq(WorldSession.money(), 0)
	assert_eq(page.cards().card_count(), 2, "it's now an owned car, not one on sale")
	page.close()
	assert_signal_emitted(page, "car_changed")


func test_a_car_on_sale_that_cant_be_afforded_is_greyed_out() -> void:
	var scene := await _boot()
	var page: RestStopPage = scene.get_node("RestStopPage")
	var car: Dictionary = page.loot.for_sale().filter(func(i: Dictionary) -> bool: return i["kind"] == "car")[0]
	WorldSession.set_money(LootRules.price(car) - 1)
	page.open(0)
	page._show(RestStopPage.View.GARAGE)
	assert_true(page.cards()._cards[1].disabled)
	page.close()


func _put_car_at(scene: Node3D, at: Array) -> void:
	var loot: LootDirector = scene.get_node("LootDirector")
	var p := Vector3(float(at[0]), float(at[1]), float(at[2]))
	(scene.get_node("Car") as Node3D).global_position = p
	loot._last_p = Vector2(p.x, p.z)


func test_driving_back_to_the_wreck_recovers_the_money() -> void:
	var scene := await _boot()
	var loot: LootDirector = scene.get_node("LootDirector")
	loot.set_physics_process(false)
	WorldSession.set_money(500)
	(scene.get_node("Car").damage as DamageModel).gave_up.emit()
	var at: Array = WorldSession.dropped()["pos"]
	(scene.get_node("RestStops") as RestStops).respawned.emit(0, Vector3.ZERO)
	_put_car_at(scene, at)
	loot.step()
	assert_eq(WorldSession.money(), 500, "picked back up")
	assert_true(WorldSession.dropped().is_empty())
	await get_tree().process_frame
	assert_null(loot.get_node_or_null("DroppedMoney"), "the crystal goes")


func test_boot_warm_up_shows_a_crystal_without_dropping_money() -> void:
	var scene := await _boot()
	var loot: LootDirector = scene.get_node("LootDirector")
	loot.warm_up(Vector3(1.0, 2.0, 3.0))
	var warm := loot.get_node_or_null("CrystalWarmUp") as Node3D
	assert_not_null(warm, "a crystal is drawn so its shader compiles")
	assert_eq(warm.global_position, Vector3(1.0, 2.0, 3.0))
	assert_true(WorldSession.dropped().is_empty(), "but nothing is dropped")
	loot.clear_warm_up()
	await get_tree().process_frame
	assert_null(loot.get_node_or_null("CrystalWarmUp"), "and it goes once warmed")


func test_wrecking_again_before_recovering_loses_the_drop_for_good() -> void:
	var scene := await _boot()
	var loot: LootDirector = scene.get_node("LootDirector")
	loot.set_physics_process(false)
	var damage := scene.get_node("Car").damage as DamageModel
	WorldSession.set_money(500)
	damage.gave_up.emit()
	var at: Array = WorldSession.dropped()["pos"]
	(scene.get_node("RestStops") as RestStops).respawned.emit(0, Vector3.ZERO)
	damage.gave_up.emit()
	assert_true(WorldSession.dropped().is_empty(), "the first drop is gone, and there was nothing new to drop")
	(scene.get_node("RestStops") as RestStops).respawned.emit(0, Vector3.ZERO)
	_put_car_at(scene, at)
	loot.step()
	assert_eq(WorldSession.money(), 0, "nothing to recover at the old wreck")


func test_the_wreck_page_says_the_money_was_dropped() -> void:
	var scene := await _boot()
	var page: RestStopPage = scene.get_node("RestStopPage")
	var loot: LootDirector = page.loot
	WorldSession.set_money(1234)
	(scene.get_node("Car").damage as DamageModel).gave_up.emit()
	page.open_wrecked()
	assert_eq(page.view, RestStopPage.View.WRECKED)
	assert_eq(loot.lost, 1234)
	var text := ""
	for l in page._page.find_children("*", "Label", true, false):
		text += (l as Label).text + "\n"
	assert_string_contains(text.to_lower(), "dropped $1234")
	page.close()


func test_the_garage_with_cars_on_sale_is_navigable() -> void:
	var scene := await _boot()
	var page: RestStopPage = scene.get_node("RestStopPage")
	page.open(0)
	assert_true(page.pick("garage"))
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(page.get_viewport().gui_get_focus_owner(), page.cards())
	assert_gt(page.cards().card_count(), 1, "the owned car and the cars on sale")
	var right := InputEventAction.new()
	right.action = "ui_right"
	right.pressed = true
	page.cards()._gui_input(right)
	assert_eq(page.cards().selected_index(), 1, "right moves onto a car on sale")
	var e := InputEventAction.new()
	e.action = "ui_cancel"
	e.pressed = true
	MenuNav.of(page._page)._unhandled_input(e)
	await get_tree().process_frame
	assert_eq(page.view, RestStopPage.View.MAIN, "back returns to the checkpoint")
	page.close()


func test_the_parts_page_switches_parts_on_and_off_and_reloads_the_car_on_close() -> void:
	var scene := await _boot()
	_nothing_for_sale()
	var page: RestStopPage = scene.get_node("RestStopPage")
	_save.set_car_parts(int(WorldSession.active_car()["instance_id"]), [{"kind": "part", "id": "grip", "level": 1, "on": false}])
	page.owned = WorldSession.active_car()
	page.open(0)
	watch_signals(page)
	page._show(RestStopPage.View.PARTS)
	assert_eq(page.cards().card_count(), 1, "a card for the unlocked part")
	_confirm(page.cards(), 0)
	assert_true(LootRules.is_on(WorldSession.active_car()["parts"][0]), "switched on, and saved on the car")
	_confirm(page.cards(), 0)
	assert_false(LootRules.is_on(WorldSession.active_car()["parts"][0]), "switched off")
	assert_eq((WorldSession.active_car()["parts"] as Array).size(), 1, "and still unlocked")
	page.close()
	assert_signal_emitted(page, "car_changed")


# A part belongs to the car it was bought for: another car neither sees it nor counts as owning it.
func test_a_part_on_one_car_is_not_available_to_another() -> void:
	var scene := await _boot()
	var page: RestStopPage = scene.get_node("RestStopPage")
	var loot: LootDirector = page.loot
	for r in 4:
		loot.unlock(r)
	var part: Dictionary = loot.for_sale().filter(func(i: Dictionary) -> bool:
		return i["kind"] == "part" and not LootRules.is_drivetrain(i))[0]
	var other: Dictionary = _save.grant_car(String(CarLibrary.all()[1]["id"]))
	_save.set_car_parts(int(other["instance_id"]), [part])
	assert_true(loot.for_sale().has(part), "the car being driven can still buy its own")
	page.open(0)
	page._show(RestStopPage.View.PARTS)
	var on_sale := loot.for_sale().filter(func(i: Dictionary) -> bool: return i["kind"] == "part").size()
	assert_eq(page.cards().card_count(), on_sale, "only parts on sale: nothing of the other car's to switch on")
	page.close()


# A part the car can't use is never sold to it.
func test_a_part_the_car_cant_fit_cant_be_bought() -> void:
	var scene := await _boot()
	var loot: LootDirector = scene.get_node("LootDirector")
	for r in 4:
		loot.unlock(r)
	var own := UpgradeLibrary.stock_drive_mode(WorldSession.active_car())
	var kit := {"kind": "part", "id": "drivetrain:%d" % own}
	if not loot.for_sale().has(kit):
		pass_test("this island sells no kit for the car's own layout")
		return
	WorldSession.set_money(LootRules.price(kit))
	assert_true(loot.buy(kit).is_empty(), "a kit for the layout the car already has is refused")
	assert_eq(WorldSession.money(), LootRules.price(kit), "and nothing is spent")


func test_an_old_shared_stash_moves_onto_the_car_being_driven() -> void:
	await _boot()
	var part := {"kind": "part", "id": "grip", "level": 1}
	(_save.profile[_save.KEY_WORLD] as Dictionary)["stash"] = [part]
	WorldSession.adopt_old_stash()
	var off := part.duplicate()
	off["on"] = false
	assert_eq(WorldSession.active_car().get("parts", []), [off], "unlocked for that car, switched off")
	assert_false((_save.profile[_save.KEY_WORLD] as Dictionary).has("stash"), "and the shared stash is gone")


func test_the_garage_switches_the_active_car() -> void:
	var scene := await _boot()
	_nothing_for_sale()
	var page: RestStopPage = scene.get_node("RestStopPage")
	var second: Dictionary = _save.grant_car(String(CarLibrary.all()[1]["id"]))
	page.open(0)
	page._show(RestStopPage.View.GARAGE)
	assert_eq(page.cards().card_count(), 2, "a card per owned car")
	assert_eq(page.cards().selected_index(), 0, "the cursor starts on the car being driven")
	_confirm(page.cards(), 0)
	assert_ne(int(WorldSession.active_car()["instance_id"]), int(second["instance_id"]), "picking the car being driven changes nothing")
	_confirm(page.cards(), 1)
	assert_eq(int(WorldSession.active_car()["instance_id"]), int(second["instance_id"]))
	assert_eq(page.cards().selected_index(), 1, "the rebuilt garage sits on the car now driven")
	page.close()


func test_each_owned_car_in_the_garage_says_how_many_upgrades_it_has() -> void:
	var scene := await _boot()
	_nothing_for_sale()
	var page: RestStopPage = scene.get_node("RestStopPage")
	_save.set_car_parts(int(WorldSession.active_car()["instance_id"]), [{"kind": "part", "id": "grip", "level": 0, "on": false}])
	var second: Dictionary = _save.grant_car(String(CarLibrary.all()[1]["id"]))
	page.owned = WorldSession.active_car()
	page.open(0)
	page._show(RestStopPage.View.GARAGE)
	var cars: Array = [WorldSession.active_car(), second]
	for i in 2:
		var lines: Array = []
		for l in page.cards().get_card(i).info.get_children():
			if l is Label:
				lines.append((l as Label).text.to_lower())
		assert_has(lines, LootRules.upgrades_text(cars[i]).to_lower(), "card %d shows its car's upgrade count" % i)
		var model := CarLibrary.by_id(String(cars[i]["model_id"]))
		assert_gt(lines.find(LootRules.upgrades_text(cars[i]).to_lower()), lines.find(CardUI.car_subtitle(model).to_lower()),
			"card %d has the upgrade count under the power line" % i)
	assert_true(LootRules.upgrades_text(cars[0]).begins_with("1 / "), "a switched-off part still counts")
	assert_true(LootRules.upgrades_text(cars[1]).begins_with("0 / "))
	page.close()


# Confirm a card the way a player does, flash and all (no skip_confirm_flash), and wait for it.
func _confirm_for_real(page: RestStopPage, index: int) -> void:
	page.cards().select(index, false)
	page.cards()._confirm_selected()
	await get_tree().create_timer(Config.data.card_carousel_confirm_flash_duration_s + 0.2).timeout
	await get_tree().process_frame


func test_switching_a_part_keeps_the_cursor_where_it_was() -> void:
	var scene := await _boot()
	_nothing_for_sale()
	var page: RestStopPage = scene.get_node("RestStopPage")
	_save.set_car_parts(int(WorldSession.active_car()["instance_id"]), [{"kind": "part", "id": "grip", "level": 1, "on": false},
		{"kind": "part", "id": "turbo", "level": 0, "on": false}, {"kind": "part", "id": "aero", "level": 0, "on": false}])
	page.owned = WorldSession.active_car()
	page.open(0)
	page._show(RestStopPage.View.PARTS)
	await _confirm_for_real(page, 2)
	assert_true(LootRules.is_on(WorldSession.active_car()["parts"][2]), "switched on")
	assert_eq(page.cards().selected_index(), 2, "the cursor stays put")
	await get_tree().process_frame
	assert_almost_eq(page.cards()._offset, page.cards()._target_offset_for(2), 0.5, "and the strip is scrolled to it")
	page.dirty = false
	page.close()


func test_picking_a_car_keeps_the_cursor_on_it() -> void:
	var scene := await _boot()
	_nothing_for_sale()
	var page: RestStopPage = scene.get_node("RestStopPage")
	_save.grant_car(String(CarLibrary.all()[1]["id"]))
	var third: Dictionary = _save.grant_car(String(CarLibrary.all()[2]["id"]))
	page.open(0)
	page._show(RestStopPage.View.GARAGE)
	await _confirm_for_real(page, 2)
	assert_eq(int(WorldSession.active_car()["instance_id"]), int(third["instance_id"]))
	assert_eq(page.cards().selected_index(), 2, "the cursor stays on the car picked")
	await get_tree().process_frame
	assert_almost_eq(page.cards()._offset, page.cards()._target_offset_for(2), 0.5, "and the strip is scrolled to it")
	page.dirty = false
	page.close()


func _confirm(cards: CardCarousel, index: int) -> void:
	cards.select(index, false)
	cards._confirm_selected()
	cards.skip_confirm_flash()



# Risky driving pays and says so like a coin pickup: a held drift or jump pays once it ends, a hit voids it,
# a tree passed close pays once, and a wrecked car earns nothing. Fed synthetic readings, no physics.
func test_stunts_pay_when_they_end_and_a_hit_voids_them() -> void:
	var scene := await _boot()
	var loot: LootDirector = scene.get_node("LootDirector")
	loot.car = null  # only the synthetic readings below drive it
	var s := loot.streamer.settings
	var dt := 0.1
	var drift := deg_to_rad(s.drift_min_angle_deg) + 0.1
	var steps := ceili(s.stunt_min_s / dt) + 2
	var calm := func() -> void:
		for i in ceili(s.stunt_grace_s / dt) + 1:
			loot.stunt_step(dt, 0.0, 0.0, 4, [])
	WorldSession.set_money(0)
	watch_signals(loot)

	for i in steps:
		loot.stunt_step(dt, drift, s.drift_min_speed_mps, 4, [])
	assert_eq(WorldSession.money(), 0, "a drift pays only once it ends")
	calm.call()
	var after_drift := WorldSession.money()
	assert_gt(after_drift, 0, "a held drift pays")
	assert_string_contains(String(get_signal_parameters(loot, "said")[0]), "Drift +$%d" % after_drift, "said like a coin")
	calm.call()
	assert_eq(WorldSession.money(), after_drift, "it pays once")

	for i in steps:
		loot.stunt_step(dt, drift, s.drift_min_speed_mps, 4, [])
	loot._void_stunts()
	calm.call()
	assert_eq(WorldSession.money(), after_drift, "a hit voids the drift")

	for i in ceili(s.jump_min_s / dt) + 2:
		loot.stunt_step(dt, 0.0, 0.0, 0, [])
	loot._void_stunts()  # the landing jolt
	calm.call()
	var after_jump := WorldSession.money()
	assert_gt(after_jump, after_drift, "a jump pays on landing")
	loot._reset_stunts()  # a spawn or teleport: the car drops in from above the road
	for i in ceili(s.jump_min_s / dt) + 2:
		loot.stunt_step(dt, 0.0, 0.0, 0, [])
	calm.call()
	assert_eq(WorldSession.money(), after_jump, "dropping in after a spawn isn't a jump")

	var fast := s.near_miss_min_speed_mps
	loot.stunt_step(dt, 0.0, fast, 4, ["tree"])
	loot.stunt_step(dt, 0.0, fast, 4, ["tree"])
	loot.stunt_step(dt, 0.0, fast, 4, [])
	assert_eq(WorldSession.money(), after_jump + s.near_miss_money, "a tree passed close pays once")
	loot.stunt_step(dt, 0.0, fast, 4, ["tree"])
	loot._void_stunts()
	loot.stunt_step(dt, 0.0, fast, 4, [])
	assert_eq(WorldSession.money(), after_jump + s.near_miss_money, "a tree that was hit doesn't pay")

	loot._wrecked = true  # what wreck() sets, without its drop needing the car
	WorldSession.set_money(0)
	for i in steps:
		loot.stunt_step(dt, drift, s.drift_min_speed_mps, 4, [])
	calm.call()
	assert_eq(WorldSession.money(), 0, "a wrecked car earns nothing")
