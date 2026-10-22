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
	_banner._pending_site = -1
	_banner.close()
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
	assert_signal_emitted_with_parameters(_rest, "healed", [site])
	assert_signal_not_emitted(_rest, "opened", "no page without stopping")
	_rest.set_physics_process(true)


# Stopping alone doesn't open the page: menu_select (Enter / gamepad A) does, and only when slow.
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


func test_menu_select_while_moving_through_a_rest_stop_does_nothing() -> void:
	var site := _a_rest_stop()
	await _park_on(site)
	_rest.set_physics_process(false)
	_rest.step(0.01)
	_car.linear_velocity = -_car.global_transform.basis.z * 30.0
	watch_signals(_rest)
	assert_eq(_rest.prompt_site(), -1)
	_rest._unhandled_input(_press("menu_select"))
	assert_signal_not_emitted(_rest, "opened")
	_rest.set_physics_process(true)


func test_giving_up_respawns_repaired_at_the_last_lit_rest_stop() -> void:
	var site := _a_rest_stop()
	_rest.lit_sites[site] = true
	# Parked on spawn's pad, the live step would (rightly) make spawn the respawn point again.
	_rest.set_physics_process(false)
	_rest.move_car_to(0)
	_rest.last_site = site
	await get_tree().physics_frame
	watch_signals(_rest)
	var dmg: DamageModel = _car.damage
	dmg.apply_loss(dmg.max_hp * 2.0)
	await get_tree().process_frame
	await get_tree().physics_frame
	await get_tree().physics_frame
	assert_signal_emitted(_rest, "wrecked")
	assert_signal_not_emitted(_rest, "respawned", "the wreck page comes first")
	assert_true(_page.is_open())
	assert_eq(_page.view, RestStopPage.View.WRECKED)
	assert_false(get_tree().paused, "the wreck page leaves the game running")
	assert_true(_car.ai_controlled, "the wreck rolls on with no player controls")
	assert_eq(_car.ai_throttle, 0.0)
	assert_true(_page.pick("Respawn"))
	assert_signal_emitted(_rest, "respawned")
	assert_false(_page.is_open())
	assert_false(_car.ai_controlled, "the controls come back with the respawn")
	assert_eq(dmg.hp, dmg.max_hp)
	var pose := _rest.pose_at(site)
	assert_lt(Vector2(_car.global_position.x, _car.global_position.z).distance_to(Vector2(pose.origin.x, pose.origin.z)), 3.0)
	assert_true(_streamer.has_collision_at(pose.origin.x, pose.origin.z), "it lands on built ground")
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
	assert_true(_page.pick("travel"))
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(_page.view, RestStopPage.View.TRAVEL)
	assert_gt(_page.cards().card_count(), 0, "the lit rest stop is offered")
	assert_eq(vp.gui_get_focus_owner(), _page.cards())
	MenuNav.of(_page._page)._unhandled_input(_press("ui_cancel"))
	await get_tree().process_frame
	assert_eq(_page.view, RestStopPage.View.MAIN, "back steps out to the main page")
	MenuNav.of(_page._page)._unhandled_input(_press("ui_cancel"))
	await get_tree().process_frame
	assert_false(_page.is_open(), "and back again closes it")
	assert_false(get_tree().paused)


func test_picking_a_travel_target_goes_there() -> void:
	var site := _a_rest_stop()
	_rest.lit_sites[site] = true
	_page.open(0)
	_page._show(RestStopPage.View.TRAVEL)
	var idx := Array(_rest.travel_targets(0)).find(site)
	assert_true(idx >= 0)
	_page.cards().select(idx, false)
	_page.cards()._confirm_selected()
	_page.cards().skip_confirm_flash()
	assert_false(_page.is_open())
	assert_eq(_rest.last_site, site)


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
	_page._travel(site)
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


# Lighting a checkpoint shows the "Checkpoint reached" band; once it has faded, a page of what is
# still to be found in that biome comes up, walkable by keyboard / gamepad, and Back closes it.
func test_lighting_a_checkpoint_shows_the_banner_then_a_navigable_items_page() -> void:
	var site := _a_rest_stop()
	_rest.lit_sites.erase(site)
	await _park_on(site)
	_rest.step(0.01)
	assert_true(_banner.is_showing_banner())
	assert_false(_banner.is_open(), "no page while the banner is up")
	_banner._banner_done(site)
	await get_tree().process_frame
	await get_tree().process_frame
	if _banner.items_for(site).is_empty():
		assert_false(_banner.is_open(), "nothing left to find: no page")
		return
	assert_true(_banner.is_open())
	assert_true(get_tree().paused)
	await get_tree().process_frame
	var cards := _banner.cards()
	assert_eq(cards.card_count(), _banner.items_for(site).size() + 1, "Continue, then one card per item")
	assert_eq(_banner.get_viewport().gui_get_focus_owner(), cards, "the card list has the cursor")
	var nav := MenuNav.of(_banner._page)
	nav._unhandled_input(_press("menu_right"))
	assert_eq(cards.selected_index(), 1, "right walks the cards")
	nav._unhandled_input(_press("ui_cancel"))
	await get_tree().process_frame
	assert_false(_banner.is_open(), "back closes it")
	assert_false(get_tree().paused)

