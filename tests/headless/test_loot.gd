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


func _shown_keys(placed: Dictionary) -> Dictionary:
	var out := {}
	for site: int in placed:
		out[LootLibrary.item_key(placed[site])] = true
	return out


func _loot_sites_by_ring(sites: RoadSites, ring_count: int) -> Array:
	var out: Array = []
	for r in ring_count:
		out.append([])
	for i in sites.count():
		if sites.kind[i] != RoadSites.Kind.REST:
			(out[clampi(sites.ring[i], 0, ring_count - 1)] as Array).append(i)
	return out


func test_the_pool_is_seeded_and_only_loot_sites_show_items_from_the_tables() -> void:
	var s := _settings()
	var sites := _sites(s)
	var a := LootLibrary.assign(sites, s.ring_count, s.world_seed, {}, [])
	var b := LootLibrary.assign(sites, s.ring_count, s.world_seed, {}, [])
	assert_eq(a, b, "the same world shows the same loot")
	assert_gt(a.size(), 0)
	var table_keys := {}
	for t: Array in LootLibrary.ring_tables(s.ring_count):
		for item: Dictionary in t:
			table_keys[LootLibrary.item_key(item)] = true
	for site: int in a:
		assert_ne(sites.kind[site], RoadSites.Kind.REST, "no loot at rest stops")
		assert_true(table_keys.has(LootLibrary.item_key(a[site])), "a real table item")


func test_an_item_the_player_has_is_gone_from_every_site() -> void:
	var s := _settings()
	var sites := _sites(s)
	var before := LootLibrary.assign(sites, s.ring_count, s.world_seed, {}, [])
	var key := LootLibrary.item_key(before.values()[0])
	var after := LootLibrary.assign(sites, s.ring_count, s.world_seed, {key: true}, [])
	assert_false(_shown_keys(after).has(key), "taken: no site shows it any more")
	var all_taken := {}
	for t: Array in LootLibrary.ring_tables(s.ring_count):
		for item: Dictionary in t:
			all_taken[LootLibrary.item_key(item)] = true
	assert_eq(LootLibrary.assign(sites, s.ring_count, s.world_seed, all_taken, []), {},
		"with everything found, nothing is left to show")


func test_with_enough_sites_every_remaining_item_shows_somewhere() -> void:
	var s := _settings()
	var sites := _sites(s)
	var by_ring := _loot_sites_by_ring(sites, s.ring_count)
	var counts := PackedInt32Array()
	for r in s.ring_count:
		counts.append((by_ring[r] as Array).size())
	var hosts := LootLibrary.pool_rings(counts)
	var tables := LootLibrary.ring_tables(s.ring_count)
	# Take items until every ring's pool fits its sites, then everything left must show.
	var taken := {}
	var left: Array = []
	for r in s.ring_count:
		var pool: Array = []
		for t: int in hosts[r]:
			pool.append_array(tables[t])
		for k in pool.size():
			if k < counts[r]:
				left.append(pool[k])
			else:
				taken[LootLibrary.item_key(pool[k])] = true
	assert_gt(left.size(), 0)
	var shown := _shown_keys(LootLibrary.assign(sites, s.ring_count, s.world_seed, taken, []))
	for item: Dictionary in left:
		assert_true(shown.has(LootLibrary.item_key(item)), "%s shows somewhere" % LootLibrary.item_key(item))


func test_a_ring_with_no_loot_sites_folds_into_the_nearest_ring_that_has_some() -> void:
	var hosts := LootLibrary.pool_rings(PackedInt32Array([3, 0, 2, 0]))
	var all: Array = []
	for r in 4:
		all.append_array(hosts[r])
	all.sort()
	assert_eq(all, [0, 1, 2, 3], "every ring's table is carried somewhere, once")
	assert_eq(hosts[1], [], "a ring with no sites hosts nothing")
	assert_eq(hosts[3], [], "a ring with no sites hosts nothing")
	assert_true(3 in hosts[2], "the outer empty ring folds inward to its nearest neighbour")
	assert_eq(LootLibrary.pool_rings(PackedInt32Array([0, 0])), [[], []], "no sites anywhere: nothing shows")


func test_a_site_picked_from_is_spent_for_good() -> void:
	var s := _settings()
	var sites := _sites(s)
	var placed := LootLibrary.assign(sites, s.ring_count, s.world_seed, {}, [])
	# Spend every site but one, taking nothing: the pool is now far bigger than the free sites,
	# and still no spent site shows anything.
	var spent: Array = placed.keys()
	var keep: int = spent.pop_back()
	var after := LootLibrary.assign(sites, s.ring_count, s.world_seed, {}, spent)
	for site: int in spent:
		assert_false(after.has(site), "spent site %d stays empty" % site)
	assert_true(after.has(keep), "the one free site still shows something")


func test_a_ring_short_of_sites_moves_its_lesser_items_to_a_ring_with_spare() -> void:
	var s := _settings()
	var sites := _sites(s)
	var by_ring := _loot_sites_by_ring(sites, s.ring_count)
	var with_sites: Array = []
	for r in s.ring_count:
		if not (by_ring[r] as Array).is_empty():
			with_sites.append(r)
	if with_sites.size() < 2:
		pass_test("this island has loot sites in only one ring")
		return
	var short: int = with_sites[0]
	var spare: int = with_sites[1]
	# Take everything except one item of each ring's own table, so the other ring has room,
	# then spend all but one of the short ring's sites while it still holds two items.
	var tables := LootLibrary.ring_tables(s.ring_count)
	var taken := {}
	for r in s.ring_count:
		for k in (tables[r] as Array).size():
			taken[LootLibrary.item_key(tables[r][k])] = true
	var stay: Dictionary = tables[short][0]
	var moved: Dictionary = tables[short][1]
	taken.erase(LootLibrary.item_key(stay))
	taken.erase(LootLibrary.item_key(moved))
	var spent: Array = (by_ring[short] as Array).slice(1)
	var placed := LootLibrary.assign(sites, s.ring_count, s.world_seed, taken, spent)
	var shown_in := {}
	for site: int in placed:
		shown_in[LootLibrary.item_key(placed[site])] = sites.ring[site]
	assert_eq(shown_in.size(), 2, "both items still show somewhere")
	var short_keys := []
	for key: String in shown_in:
		if shown_in[key] == short:
			short_keys.append(key)
	assert_eq(short_keys.size(), 1, "the short ring's one free site shows one item")
	assert_true(spare in shown_in.values(), "the other went to the ring with sites to spare")


func test_scarce_spare_sites_show_the_best_of_what_overflowed() -> void:
	var s := _settings()
	var sites := _sites(s)
	var by_ring := _loot_sites_by_ring(sites, s.ring_count)
	var with_sites: Array = []
	for r in s.ring_count:
		if not (by_ring[r] as Array).is_empty():
			with_sites.append(r)
	if with_sites.size() < 2:
		pass_test("this island has loot sites in only one ring")
		return
	var short: int = with_sites[0]
	var spare: int = with_sites[1]
	var tables := LootLibrary.ring_tables(s.ring_count)
	# Three items of the short ring with distinct worth.
	var by_rank := {}
	for item: Dictionary in tables[short]:
		if not by_rank.has(LootLibrary._rank(item)):
			by_rank[LootLibrary._rank(item)] = item
	if by_rank.size() < 3:
		pass_test("the ring has fewer than three distinct kinds of item")
		return
	var ranks := by_rank.keys()
	ranks.sort()
	var best: Dictionary = by_rank[ranks[0]]
	var mid: Dictionary = by_rank[ranks[1]]
	var worst: Dictionary = by_rank[ranks[2]]
	var taken := {}
	for r in s.ring_count:
		for item: Dictionary in tables[r]:
			taken[LootLibrary.item_key(item)] = true
	for item in [best, mid, worst]:
		taken.erase(LootLibrary.item_key(item))
	# Two free sites in all: one in the short ring, one in the spare ring.
	var spent: Array = []
	for r in s.ring_count:
		var keep := 1 if (r == short or r == spare) else 0
		spent.append_array((by_ring[r] as Array).slice(keep))
	var shown := _shown_keys(LootLibrary.assign(sites, s.ring_count, s.world_seed, taken, spent))
	assert_true(shown.has(LootLibrary.item_key(best)), "the best stays")
	assert_true(shown.has(LootLibrary.item_key(mid)), "the next best takes the one spare site")
	assert_false(shown.has(LootLibrary.item_key(worst)), "the worst is the one left with nowhere to show")


func test_dead_ends_show_the_best_of_their_ring() -> void:
	var s := _settings()
	var sites := _sites(s)
	var placed := LootLibrary.assign(sites, s.ring_count, s.world_seed, {}, [])
	var dead_ends := sites.of_kind(RoadSites.Kind.DEAD_END)
	assert_gt(dead_ends.size(), 0)
	for d in dead_ends:
		assert_true(placed.has(d), "dead end %d has a payoff" % d)
		for site: int in placed:
			if sites.kind[site] == RoadSites.Kind.LOOT and sites.ring[site] == sites.ring[d] \
					and placed[site]["kind"] == "car":
				assert_eq(placed[d]["kind"], "car", "a roadside car means every dead end in ring %d took one" % sites.ring[d])


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


func test_a_kit_for_the_cars_own_layout_is_never_fittable_even_beside_another_kit() -> void:
	var own := CarLibrary.RWD
	var other := CarLibrary.FWD
	var owned := {"model_id": String(CarLibrary.all()[0]["id"]), "parts": []}
	own = UpgradeLibrary.stock_drive_mode(owned)
	other = CarLibrary.FWD if own != CarLibrary.FWD else CarLibrary.AWD
	owned["parts"] = [{"kind": "part", "id": "drivetrain:%d" % other}]
	var own_kit := {"kind": "part", "id": "drivetrain:%d" % own}
	assert_false(LootLibrary.can_fit(owned, own_kit), "no kit for the stock layout, swap or not")
	assert_false(LootLibrary.occupant(owned, own_kit).is_empty(), "though another kit does occupy the slot")


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
	var key := LootLibrary.item_key(loot.loot_at(part_site))
	loot.step()
	assert_true(loot.is_collected(part_site))
	assert_eq(WorldSession.list("carried").size(), 1, "carried, not yet yours")
	assert_true(loot.loot_at(part_site).is_empty(), "the site is emptied")
	assert_false(_shown_keys(loot.placement).has(key), "and the item is gone from every other site too")
	var page: RestStopPage = scene.get_node("RestStopPage")
	page.open(0)
	assert_eq(page.banked.size(), 1)
	assert_eq(WorldSession.list("carried").size(), 0)
	assert_eq(WorldSession.list("stash").size(), 1, "banked into the stash")
	page.close()


# Loot is picked up by driving past it at speed, anywhere on the road beside its pad: the check
# sweeps the step's whole travel, so even a fast car on the far lane can't skip over it.
func test_driving_past_loot_on_the_far_lane_at_speed_picks_it_up() -> void:
	var scene := await _boot()
	var loot: LootDirector = scene.get_node("LootDirector")
	loot.set_physics_process(false)
	var sites := (scene.get_node("Terrain") as TerrainStreamer).sites
	var s := (scene.get_node("Terrain") as TerrainStreamer).settings
	var site := _site_with(loot, func(i: Dictionary) -> bool: return i["kind"] == "part")
	var away := (sites.pos[site] - sites.anchor[site]).normalized()
	var far_lane := sites.anchor[site] - away * s.road_half_width_m * 0.6
	var d := sites.dir[site]
	loot._last_p = far_lane - d * 15.0
	var to := far_lane + d * 15.0
	(scene.get_node("Car") as Node3D).global_position = Vector3(to.x, 0.0, to.y)
	loot.step()
	assert_true(loot.is_collected(site), "picked up in passing")
	assert_eq(WorldSession.list("carried").size(), 1)


func test_a_teleport_past_loot_does_not_pick_it_up() -> void:
	var scene := await _boot()
	var loot: LootDirector = scene.get_node("LootDirector")
	loot.set_physics_process(false)
	var sites := (scene.get_node("Terrain") as TerrainStreamer).sites
	var site := _site_with(loot, func(i: Dictionary) -> bool: return i["kind"] == "part")
	var d := sites.dir[site]
	loot._last_p = sites.anchor[site] - d * 400.0
	var to := sites.anchor[site] + d * 400.0
	(scene.get_node("Car") as Node3D).global_position = Vector3(to.x, 0.0, to.y)
	loot.step()
	assert_false(loot.is_collected(site), "a jump across the map isn't driving past")


# A short hop (well under the 100 m guard) over a loot pad is a teleport, not a drive past.
func test_a_short_teleport_over_loot_does_not_pick_it_up() -> void:
	var scene := await _boot()
	var loot: LootDirector = scene.get_node("LootDirector")
	loot.set_physics_process(false)
	var sites := (scene.get_node("Terrain") as TerrainStreamer).sites
	var site := _site_with(loot, func(i: Dictionary) -> bool: return i["kind"] == "part")
	var d := sites.dir[site]
	var from := sites.anchor[site] - d * 40.0
	var to := sites.anchor[site] + d * 40.0
	loot._last_p = from
	(scene.get_node("Car") as Node3D).global_position = Vector3(to.x, 0.0, to.y)
	loot.car_teleported(to)
	loot.step()
	assert_false(loot.is_collected(site), "a teleport over the pad isn't driving past")


func test_a_car_the_player_owns_never_shows_on_the_ground() -> void:
	var scene := await _boot()
	var loot: LootDirector = scene.get_node("LootDirector")
	var starter := String(WorldSession.active_car()["model_id"])
	assert_false(_shown_keys(loot.placement).has(LootLibrary.item_key({"kind": "car", "id": starter})),
		"the starter car is already yours")


func test_loot_on_the_ground_has_a_beam_and_a_name_and_they_go_when_it_is_taken() -> void:
	var scene := await _boot()
	var loot: LootDirector = scene.get_node("LootDirector")
	var site: int = loot.placement.keys()[0]
	var marker := loot.beacons.get_node_or_null("Loot%d" % site) as Node3D
	assert_not_null(marker, "a beam over the loot")
	# Far off: a faint beam and no name. Close: a stronger beam, and the name shows.
	var cfg: GameConfig = Config.data
	var beam := marker.get_node("Beam") as Node3D
	var p := marker.global_position
	loot.beacons._fit(beam, p + Vector3(cfg.beacon_range_m * 0.9, 0, 0), cfg)
	var far_a := SiteBeacons.beam_color(beam).a
	loot.beacons._fit(beam, p + Vector3(5, 0, 0), cfg)
	assert_gt(SiteBeacons.beam_color(beam).a, far_a, "the beam is fainter the further off it is")
	var label := marker.get_node("Label") as Label3D
	loot.beacons.update_from(p + Vector3(cfg.beacon_label_range_m + 50.0, 0, 0))
	assert_false(label.visible, "far off, the beam doesn't say what it is")
	loot.beacons.update_from(p + Vector3(cfg.beacon_label_range_m * 0.5, 0, 0))
	assert_true(label.visible, "close up, it does")
	assert_eq((marker.get_node("Label") as Label3D).text, LootLibrary.ground_label(loot.placement[site]).to_upper())
	loot.collect(site)
	await get_tree().process_frame
	assert_false(loot.placement.has(site))
	var gone := loot.beacons.get_node_or_null("Loot%d" % site)
	assert_true(gone == null or gone.is_queued_for_deletion(), "the emptied site's beam goes")
	var rest := (scene.get_node("Terrain") as TerrainStreamer).sites.of_kind(RoadSites.Kind.REST)[0]
	assert_not_null(loot.beacons.get_node_or_null("Rest%d" % rest), "every rest stop has a beam")


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
	var is_part := func(i: Dictionary) -> bool: return i["kind"] == "part"
	var first := _site_with(loot, is_part)
	var lost_key := LootLibrary.item_key(loot.placement[first])
	loot.collect(first)
	loot.drop_at(Vector3(10, 0, 10))
	assert_true(loot.taken_keys().has(lost_key), "lying in the drop, it's still yours to fetch")
	var second := _site_with(loot, is_part)
	loot.collect(second)
	loot.drop_at(Vector3(-20, 0, 15))
	var d := WorldSession.dropped()
	assert_eq((d["items"] as Array).size(), 1)
	assert_eq(int(d["items"][0]["site"]), second, "the first drop is lost")
	assert_false(loot.taken_keys().has(lost_key), "and what it held is back in the pool to be found again")


func test_the_parts_page_fits_and_removes_parts_and_reloads_the_car_on_close() -> void:
	var scene := await _boot()
	var page: RestStopPage = scene.get_node("RestStopPage")
	WorldSession.set_list("stash", [{"kind": "part", "id": "grip", "level": 1}])
	page.open(0)
	watch_signals(page)
	page._show(RestStopPage.View.PARTS)
	assert_eq(page.cards().card_count(), 1, "a card for the stash part")
	_confirm(page.cards(), 0)
	assert_eq(WorldSession.list("stash").size(), 0)
	assert_eq((WorldSession.active_car().get("parts", []) as Array).size(), 1, "fitted, and saved on the car")
	assert_eq(page.cards().card_count(), 1, "now a card for the fitted part")
	_confirm(page.cards(), 0)
	assert_eq(WorldSession.list("stash").size(), 1, "and back in the stash")
	page.close()
	assert_signal_emitted(page, "car_changed")


func test_the_parts_page_never_offers_the_own_layout_kit_even_with_another_kit_fitted() -> void:
	var scene := await _boot()
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
	assert_true(page.cards()._cards[1].disabled, "the own-layout kit can't be fitted or swapped in")
	page.dirty = false
	page.close()


func test_the_garage_switches_the_active_car() -> void:
	var scene := await _boot()
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


func test_the_journal_and_parts_pages_are_navigable() -> void:
	var scene := await _boot()
	var page: RestStopPage = scene.get_node("RestStopPage")
	page.open(0)
	assert_true(page.pick("journal"))
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(page.view, RestStopPage.View.JOURNAL)
	assert_gt(page.cards().card_count(), 0, "the revealed biome's loot is listed")
	assert_eq(page.get_viewport().gui_get_focus_owner(), page.cards())
	var e := InputEventAction.new()
	e.action = "ui_cancel"
	e.pressed = true
	MenuNav.of(page._page)._unhandled_input(e)
	await get_tree().process_frame
	assert_eq(page.view, RestStopPage.View.MAIN)
	page.close()


func _confirm(cards: CardCarousel, index: int) -> void:
	cards.select(index, false)
	cards._confirm_selected()
	cards.skip_confirm_flash()
