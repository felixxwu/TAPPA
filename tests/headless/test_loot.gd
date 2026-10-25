extends GutTest
# Free-roam coins and shops (features/loot.md): the ring tables and prices, fitting parts through
# the owned-car funnel, and the economy in the world: picking up coins, dropping the money on a wreck,
# buying at a checkpoint, and the rest-stop Parts / Garage / Journal pages. A synthetic car
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

func test_fitted_parts_reach_the_car_only_through_the_funnel_keys() -> void:
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


func test_one_of_each_part_one_engine_and_no_kit_for_the_cars_own_layout() -> void:
	var car: Dictionary = CarLibrary.all()[0]
	var owned := {"model_id": String(car["id"]), "parts": [{"kind": "part", "id": "grip", "level": 0},
		{"kind": "part", "id": "engine_swap:a"}]}
	assert_false(LootRules.can_fit(owned, {"kind": "part", "id": "grip", "level": 3}), "one of each")
	assert_eq(LootRules.occupant(owned, {"kind": "part", "id": "engine_swap:b"})["id"], "engine_swap:a", "the engine slot is taken")
	var own_mode := int(car.get("drive_mode", CarLibrary.RWD))
	assert_false(LootRules.can_fit(owned, {"kind": "part", "id": "drivetrain:%d" % own_mode}))
	assert_false(LootRules.can_fit(owned, {"kind": "car", "id": "anything"}), "a car isn't a part")


func test_a_kit_for_the_cars_own_layout_swaps_out_another_kit_to_change_the_car_back() -> void:
	var own := CarLibrary.RWD
	var other := CarLibrary.FWD
	var owned := {"model_id": String(CarLibrary.all()[0]["id"]), "parts": []}
	own = UpgradeLibrary.stock_drive_mode(owned)
	other = CarLibrary.FWD if own != CarLibrary.FWD else CarLibrary.AWD
	owned["parts"] = [{"kind": "part", "id": "drivetrain:%d" % other}]
	var own_kit := {"kind": "part", "id": "drivetrain:%d" % own}
	assert_true(LootRules.can_fit(owned, own_kit), "a converted car can take its own layout back")
	assert_eq(LootRules.occupant(owned, own_kit)["id"], "drivetrain:%d" % other, "swapping out the other kit")


func test_a_part_that_cant_fit_says_why() -> void:
	var owned := {"model_id": String(CarLibrary.all()[0]["id"]), "parts": [{"kind": "part", "id": "grip", "level": 0}]}
	var own := UpgradeLibrary.stock_drive_mode(owned)
	assert_eq(LootRules.fit_block_reason(owned, {"kind": "part", "id": "drivetrain:%d" % own}),
		"Already " + CarLibrary.drive_text(own), "a kit for the car's own layout names the layout")
	assert_eq(LootRules.fit_block_reason(owned, {"kind": "part", "id": "grip", "level": 2}), "Already fitted")
	assert_eq(LootRules.fit_block_reason(owned, {"kind": "part", "id": "brakes", "level": 0}), "", "a part that fits has no reason")


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


func test_buying_spends_the_money_and_a_car_joins_the_garage_and_a_part_the_stash() -> void:
	var scene := await _boot()
	var loot: LootDirector = scene.get_node("LootDirector")
	for r in 4:
		loot.unlock(r)
	var car: Dictionary = loot.for_sale().filter(func(i: Dictionary) -> bool: return i["kind"] == "car")[0]
	var part: Dictionary = loot.for_sale().filter(func(i: Dictionary) -> bool: return i["kind"] == "part")[0]
	WorldSession.set_money(LootRules.price(car) + LootRules.price(part))
	var cars := (_save.profile[_save.KEY_CARS] as Array).size()
	assert_eq(String(loot.buy(car).get("model_id", "")), String(car["id"]), "returns the new owned car")
	assert_eq((_save.profile[_save.KEY_CARS] as Array).size(), cars + 1, "the car is owned")
	assert_eq(loot.buy(part), part)
	assert_eq(WorldSession.list("stash"), [part], "the part is in the stash")
	assert_eq(WorldSession.money(), 0)
	assert_false(loot.for_sale().has(car), "bought things leave the shop")
	assert_true(loot.buy(part).is_empty(), "and can't be bought twice")


func test_the_player_cant_buy_what_they_cant_afford() -> void:
	var scene := await _boot()
	var loot: LootDirector = scene.get_node("LootDirector")
	var item: Dictionary = loot.for_sale()[0]
	WorldSession.set_money(LootRules.price(item) - 1)
	assert_true(loot.buy(item).is_empty())
	assert_eq(WorldSession.money(), LootRules.price(item) - 1, "nothing is spent")
	assert_true(WorldSession.list("stash").is_empty())


# The parts and garage tests below count cards; with nothing on sale, only the player's own show.
func _nothing_for_sale() -> void:
	WorldSession.set_list("revealed", [])


func test_the_parts_page_sells_parts_and_buying_one_fits_it() -> void:
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
	assert_eq(WorldSession.active_car().get("parts", []), [part], "and fitted straight away")
	assert_eq(page.loot.owned_parts(), [part], "and owned, for any car to fit")
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


func test_the_parts_page_fits_and_removes_parts_and_reloads_the_car_on_close() -> void:
	var scene := await _boot()
	_nothing_for_sale()
	var page: RestStopPage = scene.get_node("RestStopPage")
	WorldSession.set_list("stash", [{"kind": "part", "id": "grip", "level": 1}])
	page.open(0)
	watch_signals(page)
	page._show(RestStopPage.View.PARTS)
	assert_eq(page.cards().card_count(), 1, "a card for the stash part")
	_confirm(page.cards(), 0)
	assert_eq((WorldSession.active_car().get("parts", []) as Array).size(), 1, "fitted, and saved on the car")
	assert_eq(page.cards().card_count(), 1, "now a card for the fitted part")
	_confirm(page.cards(), 0)
	assert_eq(WorldSession.active_car().get("parts", []), [], "taken off")
	assert_eq(page.loot.owned_parts().size(), 1, "and still owned")
	page.close()
	assert_signal_emitted(page, "car_changed")


# A part fitted to one car can go on another too, without coming off the first.
func test_the_parts_page_fits_a_part_already_on_another_car_without_taking_it_off() -> void:
	var scene := await _boot()
	_nothing_for_sale()
	var page: RestStopPage = scene.get_node("RestStopPage")
	var other: Dictionary = _save.grant_car(String(CarLibrary.all()[1]["id"]))
	var other_id := int(other["instance_id"])
	var part := {"kind": "part", "id": "grip", "level": 1}
	_save.set_car_parts(other_id, [part])
	page.open(0)
	page._show(RestStopPage.View.PARTS)
	assert_eq(page.cards().card_count(), 1, "the part owned shows as fittable here")
	_confirm(page.cards(), 0)
	assert_null(ConfirmPopup.any_open(get_tree()), "no asking: nothing moves")
	assert_eq(WorldSession.active_car().get("parts", []), [part], "fitted to this car")
	assert_eq(_save.get_car(other_id).get("parts", []), [part], "and still on the other one")
	page.dirty = false
	page.close()


func test_the_parts_page_swaps_the_own_layout_kit_in_to_change_a_converted_car_back() -> void:
	var scene := await _boot()
	_nothing_for_sale()
	var page: RestStopPage = scene.get_node("RestStopPage")
	var own := UpgradeLibrary.stock_drive_mode(WorldSession.active_car())
	var other := CarLibrary.FWD if own != CarLibrary.FWD else CarLibrary.AWD
	var owned := WorldSession.active_car()
	owned["parts"] = [{"kind": "part", "id": "drivetrain:%d" % other}]
	page.owned = owned
	WorldSession.set_list("stash", [{"kind": "part", "id": "drivetrain:%d" % own}])
	page.open(0)
	page._show(RestStopPage.View.PARTS)
	assert_eq(page.cards().card_count(), 2, "the fitted kit, then the stash kit")
	assert_false(page.cards()._cards[1].disabled, "the own-layout kit can swap in for the other kit")
	_confirm(page.cards(), 1)
	var own_kit := {"kind": "part", "id": "drivetrain:%d" % own}
	assert_eq(page.owned.get("parts", []), [own_kit], "the car is back on its own layout")
	assert_true(page.loot.owned_parts().has({"kind": "part", "id": "drivetrain:%d" % other}), "the other kit is still owned")
	page.dirty = false
	page.close()


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


# Confirm a card the way a player does, flash and all (no skip_confirm_flash), and wait for it.
func _confirm_for_real(page: RestStopPage, index: int) -> void:
	page.cards().select(index, false)
	page.cards()._confirm_selected()
	await get_tree().create_timer(Config.data.card_carousel_confirm_flash_duration_s + 0.2).timeout
	await get_tree().process_frame


func test_fitting_a_part_keeps_the_cursor_where_it_was() -> void:
	var scene := await _boot()
	_nothing_for_sale()
	var page: RestStopPage = scene.get_node("RestStopPage")
	WorldSession.set_list("stash", [{"kind": "part", "id": "grip", "level": 1},
		{"kind": "part", "id": "turbo", "level": 0}, {"kind": "part", "id": "aero", "level": 0}])
	page.open(0)
	page._show(RestStopPage.View.PARTS)
	await _confirm_for_real(page, 2)
	assert_eq((WorldSession.active_car().get("parts", []) as Array).size(), 1, "fitted")
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


func test_the_journal_pages_are_navigable() -> void:
	var scene := await _boot()
	var page: RestStopPage = scene.get_node("RestStopPage")
	var closed := [false]
	page.open_journal(func() -> void: closed[0] = true)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(page.view, RestStopPage.View.JOURNAL)
	var regions: int = page.loot.journal().size()
	assert_gt(regions, 0)
	assert_eq(page.cards().card_count(), regions, "a card per unlocked region")
	assert_eq(page.get_viewport().gui_get_focus_owner(), page.cards())
	var ring := int(page.loot.journal()[0]["ring"])
	page.cards()._confirm_selected()
	page.cards().skip_confirm_flash()
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(page.view, RestStopPage.View.REGION)
	assert_eq(page.journal_ring, ring)
	assert_eq(page.cards().card_count(), (page.loot.journal()[0]["items"] as Array).size(),
		"a card per item in that region")
	assert_eq(page.get_viewport().gui_get_focus_owner(), page.cards())
	var e := InputEventAction.new()
	e.action = "ui_cancel"
	e.pressed = true
	MenuNav.of(page._page)._unhandled_input(e)
	await get_tree().process_frame
	assert_eq(page.view, RestStopPage.View.JOURNAL, "back from a region returns to the region list")
	MenuNav.of(page._page)._unhandled_input(e)
	await get_tree().process_frame
	assert_true(closed[0], "and back again hands back to the caller")


func _confirm(cards: CardCarousel, index: int) -> void:
	cards.select(index, false)
	cards._confirm_selected()
	cards.skip_confirm_flash()

