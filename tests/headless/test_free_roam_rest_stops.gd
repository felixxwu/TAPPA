extends GutTest
# Free-roam rest stops (features/free-roam.md → "Rest stops"): lighting, the respawn point, the
# page on stopping, respawning when the car gives up, travel, and the rest-stop page's
# keyboard/gamepad navigation. The scene is built ONCE on a small synthetic island.

const TEST_PATH := "user://test_free_roam_rest_profile.json"

var _scene: Node3D
var _car: VehicleBody3D
var _streamer: TerrainStreamer
var _rest: RestStops
var _page: RestStopPage
var _banner: CheckpointBanner
var _save: Node


func before_all() -> void:
	_save = get_node("/root/Save")
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.load_or_new()
	_scene = load("res://free_roam.tscn").instantiate()
	var s := FreeRoamSettings.new()
	s.world_seed = 7
	s.island_radius_m = 3000.0
	s.near_radius = 1
	s.far_radius = 3
	(_scene.get_node("Terrain") as TerrainStreamer).settings = s
	add_child(_scene)
	await get_tree().physics_frame
	_car = _scene.get_node("Car")
	_streamer = _scene.get_node("Terrain")
	_rest = _scene.get_node("RestStops")
	_page = _scene.get_node("RestStopPage")
	_banner = _scene.get_node("CheckpointBanner")


func after_all() -> void:
	get_tree().paused = false
	_scene.free()
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


func after_each() -> void:
	if _page.is_open():
		_page.close()
	if _banner._band != null:
		_banner._band.free()
		_banner._band = null
	get_tree().paused = false


func _press(action: String) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = action
	e.pressed = true
	return e


# A rest stop other than spawn.
func _a_rest_stop() -> int:
	var rests := _streamer.sites.of_kind(RoadSites.Kind.REST)
	assert_gt(rests.size(), 1, "the test island has rest stops beyond spawn")
	return rests[1]


func _park_on(site: int) -> void:
	_rest.move_car_to(site)
	_rest._on_site = -1  # a fresh arrival, as if driven in (move_car_to marks the stop as reached)
	_car.linear_velocity = Vector3.ZERO
	await get_tree().physics_frame
	await get_tree().physics_frame
	_car.linear_velocity = Vector3.ZERO


func test_spawn_is_lit_from_the_start() -> void:
	assert_true(_rest.is_lit(0))


# Spawn, a respawn there, and every other stop put the car on the road facing along it, with the
# stop's cabin never in front of it (2026-10-25: spawn used to start pointed into its cabin).
func test_the_car_never_starts_facing_a_rest_stop_cabin() -> void:
	var sites := _streamer.sites
	for site in sites.of_kind(RoadSites.Kind.REST):
		var pose := _rest.pose_at(site)
		var car := Vector2(pose.origin.x, pose.origin.z)
		var fwd := Vector2(-pose.basis.z.x, -pose.basis.z.z).normalized()
		var cabin := sites.pos[site] + sites.back(site) * Config.data.rest_stop_cabin_back_m
		assert_lt(fwd.dot((cabin - car).normalized()), 0.5, "the cabin of stop %d is not ahead" % site)
		assert_true(_streamer.network.nearest(car.x, car.y, _streamer.settings.road_half_width_m),
			"stop %d's car is on the road" % site)
		assert_gt(absf(fwd.dot(_streamer.network.hit_dir)), 0.9, "and faces along it")
	# Spawn's cabin stands behind the car, back down the road out.
	var p0 := _rest.pose_at(0)
	var cabin0 := sites.pos[0] + sites.back(0) * Config.data.rest_stop_cabin_back_m
	var to_cabin := cabin0 - Vector2(p0.origin.x, p0.origin.z)
	assert_lt(Vector2(-p0.basis.z.x, -p0.basis.z.z).normalized().dot(to_cabin.normalized()), -0.5)


func test_driving_onto_a_rest_stop_lights_it_and_makes_it_the_respawn_point() -> void:
	var site := _a_rest_stop()
	_rest.lit_sites.erase(site)
	watch_signals(_rest)
	await _park_on(site)
	_rest.step(0.01)
	assert_true(_rest.is_lit(site))
	assert_eq(_rest.last_site, site)
	assert_signal_emitted_with_parameters(_rest, "lit", [site])


# Driving straight past a rest stop, on the far lane of its road and at speed, still counts: it
# lights, becomes the respawn point and heals the car fully — without stopping, and without the
# page (that's for stopping).
func test_driving_past_a_rest_stop_at_speed_lights_it_and_heals_the_car() -> void:
	var site := _a_rest_stop()
	_rest.lit_sites.erase(site)
	_rest.set_physics_process(false)
	_rest._on_site = -1
	var sites := _streamer.sites
	var away := (sites.pos[site] - sites.anchor[site]).normalized()  # the pad's side of the road
	var far_lane := sites.anchor[site] - away * _streamer.settings.road_half_width_m * 0.6
	var d := sites.dir[site]
	var dmg: DamageModel = _car.damage
	dmg.hp = dmg.max_hp * 0.3
	dmg.cooling_broken = true
	dmg.engine_temp = 50.0
	watch_signals(_rest)
	# One physics step's travel at ~200 km/h straight past it, so a per-frame point check would miss.
	_rest._last_p = far_lane - d * 15.0
	var to := far_lane + d * 15.0
	_car.global_position = Vector3(to.x, _streamer.height_at(to.x, to.y) + 1.0, to.y)
	_car.linear_velocity = Vector3(d.x, 0.0, d.y) * 55.0
	_rest.step(1.0 / 60.0)
	assert_true(_rest.is_lit(site), "lit by driving past")
	assert_eq(_rest.last_site, site, "and the respawn point")
	assert_eq(dmg.hp, dmg.max_hp, "fully healed")
	assert_false(dmg.cooling_broken, "cooling mended too")
	assert_eq(dmg.engine_temp, 50.0, "a repair is not a reset: the engine keeps its heat")
	assert_signal_emitted_with_parameters(_rest, "healed", [site])
	assert_signal_not_emitted(_rest, "opened", "no page without stopping")
	_rest.set_physics_process(true)


# Stopping alone doesn't open the page: menu_select (Enter / gamepad A) does.
func test_menu_select_while_stopped_at_a_rest_stop_opens_the_page() -> void:
	var site := _a_rest_stop()
	await _park_on(site)
	_rest.set_physics_process(false)
	watch_signals(_rest)
	for i in 10:
		_car.linear_velocity = Vector3.ZERO
		_rest.step(0.5)
	assert_signal_not_emitted(_rest, "opened", "stopping alone doesn't open it")
	assert_eq(_rest.prompt_site(), site)
	_rest._unhandled_input(_press("menu_select"))
	assert_signal_emitted_with_parameters(_rest, "opened", [site])
	_rest.set_physics_process(true)


func test_menu_select_while_moving_through_a_rest_stop_opens_the_page() -> void:
	var site := _a_rest_stop()
	await _park_on(site)
	_rest.set_physics_process(false)
	_rest.step(0.01)
	_car.linear_velocity = -_car.global_transform.basis.z * 30.0
	watch_signals(_rest)
	assert_eq(_rest.prompt_site(), site)
	_rest._unhandled_input(_press("menu_select"))
	assert_signal_emitted_with_parameters(_rest, "opened", [site])
	_rest.set_physics_process(true)


func test_giving_up_cuts_the_engine_then_shows_the_wreck_page_then_respawns_cold() -> void:
	var site := _a_rest_stop()
	_rest.lit_sites[site] = true
	# Parked on spawn's pad, the live step would (rightly) make spawn the respawn point again.
	# With physics_process off the wreck-page delay is stepped by hand below.
	_rest.set_physics_process(false)
	_rest.move_car_to(0)
	_rest.last_site = site
	var saved_delay := Config.data.wreck_page_delay_s
	Config.data.wreck_page_delay_s = 2.0
	await get_tree().physics_frame
	watch_signals(_rest)
	var dmg: DamageModel = _car.damage
	var engine: EngineSim = _car.drivetrain.engine
	dmg.apply_loss(dmg.max_hp * 2.0)
	await get_tree().process_frame
	await get_tree().physics_frame
	await get_tree().physics_frame
	assert_true(engine.killed, "the engine cuts out the moment the car gives up")
	assert_true(_car.ai_controlled, "the wreck rolls on with no player controls")
	assert_eq(_car.ai_throttle, 0.0)
	assert_signal_not_emitted(_rest, "wrecked", "the wreck page waits")
	assert_false(_page.is_open())
	_rest.step(1.0)
	assert_signal_not_emitted(_rest, "wrecked", "still waiting partway through the delay")
	_rest.step(1.1)
	assert_signal_emit_count(_rest, "wrecked", 1)
	_rest.step(5.0)
	assert_signal_emit_count(_rest, "wrecked", 1, "the page is shown once")
	assert_signal_not_emitted(_rest, "respawned", "the wreck page comes first")
	assert_true(_page.is_open())
	assert_eq(_page.view, RestStopPage.View.WRECKED)
	assert_false(get_tree().paused, "the wreck page leaves the game running")
	dmg.engine_temp = 80.0
	assert_true(_page.pick("Respawn"))
	assert_signal_emitted(_rest, "respawned")
	assert_false(_page.is_open())
	assert_false(_car.ai_controlled, "the controls come back with the respawn")
	assert_false(engine.killed, "and the engine runs again")
	assert_eq(dmg.hp, dmg.max_hp)
	assert_eq(dmg.engine_temp, 0.0, "a respawned car starts with a cold engine")
	var pose := _rest.pose_at(site)
	assert_lt(Vector2(_car.global_position.x, _car.global_position.z).distance_to(Vector2(pose.origin.x, pose.origin.z)), 3.0)
	assert_true(_streamer.has_collision_at(pose.origin.x, pose.origin.z), "it lands on built ground")
	Config.data.wreck_page_delay_s = saved_delay
	_rest.set_physics_process(true)


func test_travel_goes_only_to_lit_rest_stops() -> void:
	var site := _a_rest_stop()
	_rest.lit_sites.erase(site)
	assert_false(_rest.travel_to(site))
	_rest.lit_sites[site] = true
	assert_true(_rest.travel_to(site))
	assert_eq(_rest.last_site, site)


func test_opening_the_page_repairs_the_car_and_freezes_the_game() -> void:
	var dmg: DamageModel = _car.damage
	dmg.hp = dmg.max_hp * 0.3
	dmg.cooling_broken = true
	_page.open(0)
	assert_true(get_tree().paused)
	assert_eq(dmg.hp, dmg.max_hp)
	assert_false(dmg.cooling_broken)
	_page.close()
	assert_false(get_tree().paused)


func test_the_rest_stop_page_is_keyboard_and_gamepad_navigable() -> void:
	var site := _a_rest_stop()
	_rest.lit_sites[site] = true
	_page.open(0)
	await get_tree().process_frame
	await get_tree().process_frame
	var vp := _page.get_viewport()
	var cards := _page.cards()
	assert_eq(vp.gui_get_focus_owner(), cards, "the card list has the cursor")
	assert_eq(CardUI.titles(cards)[cards.selected_index()], "Continue", "on Continue")
	var nav := MenuNav.of(_page._page)
	nav._unhandled_input(_press("menu_right"))
	assert_eq(cards.selected_index(), 1, "right walks the cards")
	nav._unhandled_input(_press("menu_left"))
	assert_eq(cards.selected_index(), 0, "and left walks back")
	assert_true(_page.pick("garage"))
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(_page.view, RestStopPage.View.GARAGE)
	assert_eq(vp.gui_get_focus_owner(), _page.cards())
	MenuNav.of(_page._page)._unhandled_input(_press("ui_cancel"))
	await get_tree().process_frame
	assert_eq(_page.view, RestStopPage.View.MAIN, "back steps out to the main page")
	MenuNav.of(_page._page)._unhandled_input(_press("ui_cancel"))
	await get_tree().process_frame
	assert_false(_page.is_open(), "and back again closes it")
	assert_false(get_tree().paused)


# Travel after a parts change: the car moves first, so the save the reload makes holds the
# destination (not the old stop), and the respawn point is the destination.
func test_travel_after_a_parts_change_saves_the_destination() -> void:
	var site := _a_rest_stop()
	_rest.lit_sites[site] = true
	var reload := Callable(_scene, "_reload_car")
	_page.car_changed.disconnect(reload)
	var saved := []
	var rec := func() -> void:
		_scene.save_world()
		saved.append(WorldSession.pose_transform())
	_page.car_changed.connect(rec)
	_page.open(0)
	_page.dirty = true
	_rest.travel_to(site)  # what the map's Travel does, over the page
	_page.return_from_map()
	_page.car_changed.disconnect(rec)
	_page.car_changed.connect(reload)
	assert_eq(saved.size(), 1, "the changed car is reloaded")
	var dest := _rest.pose_at(site).origin
	var at: Vector3 = (saved[0] as Transform3D).origin
	assert_lt(Vector2(at.x, at.z).distance_to(Vector2(dest.x, dest.z)), 2.0, "saved at the destination")
	assert_eq(_rest.last_site, site)


# A travel / respawn hop that lands within 100 m of the old spot still isn't swept as driving.
func test_moving_the_car_is_not_a_pass_through_the_stops_in_between() -> void:
	var site := _a_rest_stop()
	_rest.lit_sites[site] = true
	var before := Vector2(_car.global_position.x, _car.global_position.z)
	_rest._last_p = before
	_rest.move_car_to(site)
	var pose := _rest.pose_at(site)
	assert_eq(_rest._last_p, Vector2(pose.origin.x, pose.origin.z), "the sweep restarts at the destination")


func test_the_tune_page_edits_the_fielded_car() -> void:
	_page.open(0)
	_page._show(RestStopPage.View.TUNE)
	assert_not_null(_page._tune_panel)
	assert_not_null(_page._tune_panel.first_slider())
	var slider := _page._tune_panel.first_slider() as HSlider
	slider.value = slider.max_value
	assert_true((_page.owned.get("tuning", {}) as Dictionary).size() > 0, "the edit lands on the car's tuning")


func test_the_hud_shows_engine_temperature_and_warns_when_the_cooling_fails() -> void:
	var hud := _scene.get_node("HUD")
	var dmg: DamageModel = _car.damage
	dmg.repair(Config.data)
	await get_tree().process_frame
	assert_true(hud.temp_gauge_visible())
	assert_eq(hud.cooling_warning(), "")
	dmg.cooling_broken = true
	await get_tree().process_frame
	assert_ne(hud.cooling_warning(), "")
	dmg.repair(Config.data)


# No menu blocks out the world behind it with a solid colour: every full-screen dim is
# see-through, and the page's own body box is too, on the card pages and on Tune car.
func test_no_rest_stop_page_paints_an_opaque_backdrop() -> void:
	_page.open(0)
	for v in [RestStopPage.View.MAIN, RestStopPage.View.TUNE, RestStopPage.View.PARTS]:
		_page._show(v)
		for rect in _page._page.find_children("*", "ColorRect", true, false):
			var cr := rect as ColorRect
			if cr.anchor_right == 1.0 and cr.anchor_bottom == 1.0:
				assert_lt(cr.color.a, 1.0, "view %d: a full-screen backdrop lets the world through" % v)
		var box := (_page._page._panel.get_theme_stylebox("panel") as UIHardShadowBox).inner as StyleBoxFlat
		assert_eq(box.bg_color.a, 0.0, "view %d: the body box is see-through" % v)
	_page.close()


# Lighting a checkpoint shows the "Checkpoint reached" band and opens no page, and puts its biome
# ring's cars and parts on sale.
func test_lighting_a_checkpoint_shows_the_banner_and_unlocks_its_ring_in_the_shop() -> void:
	var site := _a_rest_stop()
	var ring := clampi(_streamer.sites.ring[site], 0, _streamer.settings.ring_count - 1)
	_rest.lit_sites.erase(site)
	var revealed := WorldSession.list("revealed")
	WorldSession.set_list("revealed", revealed.filter(func(r: Variant) -> bool: return int(r) != ring))
	assert_false(_banner.loot.is_unlocked(ring))
	await _park_on(site)
	_rest.step(0.01)
	assert_true(_banner.is_showing_banner())
	var sub := _banner._band.find_child("Subtitle", true, false) as Label
	assert_not_null(sub, "the band says the car was repaired")
	assert_eq(sub.text, UITheme.caps(CheckpointBanner.SUBTITLE))
	assert_lt(sub.get_theme_font_size("font_size"), (_banner._band.find_child("Stack", true, false).get_child(0) as Label).get_theme_font_size("font_size"), "the subtitle is smaller than the title")
	assert_true(_banner.loot.is_unlocked(ring), "the ring's stock is on sale")
	_banner._banner_done()
	await get_tree().process_frame
	await get_tree().process_frame
	assert_false(_banner.is_showing_banner())
	assert_false(get_tree().paused, "no page freezes the game")
	WorldSession.set_list("revealed", revealed)

