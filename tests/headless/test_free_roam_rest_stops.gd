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
	_rest._offered = -1  # a fresh arrival, as if driven in (move_car_to marks the stop as
	_rest._on_site = -1  # already reached, which is right for travel and respawn, not for this)
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


# A car SPAWNED at a rest stop (a new game, Continue, the reload after a parts change) has already
# arrived there: sitting still doesn't open the page. Driving away and back does.
func test_a_car_spawned_at_a_rest_stop_is_not_offered_the_page() -> void:
	var site := _a_rest_stop()
	_rest.set_physics_process(false)
	var pose := _rest.pose_at(site)
	_streamer.prefill_at(Vector2(pose.origin.x, pose.origin.z))
	_car.reset_to(_rest.pose_at(site))
	await get_tree().physics_frame
	_rest._primed = false  # as on a fresh scene load
	_rest._on_site = -1
	_rest._offered = -1
	watch_signals(_rest)
	for i in 10:
		_car.linear_velocity = Vector3.ZERO
		_rest.step(Config.data.rest_stop_hold_s * 0.5)
	assert_signal_not_emitted(_rest, "opened", "spawning there isn't stopping there")
	_rest._on_site = -1  # drive away...
	_rest._offered = -1
	for i in 10:
		_car.linear_velocity = Vector3.ZERO
		_rest.step(Config.data.rest_stop_hold_s * 0.5)
	assert_signal_emit_count(_rest, "opened", 1, "...and back, then stop: the page")
	_page.close()
	_rest.set_physics_process(true)


func test_stopping_on_a_rest_stop_offers_the_page_once_per_visit() -> void:
	var site := _a_rest_stop()
	await _park_on(site)
	watch_signals(_rest)
	_rest._on_site = -1
	for i in 10:
		_car.linear_velocity = Vector3.ZERO
		_rest.step(Config.data.rest_stop_hold_s * 0.5)
	assert_signal_emit_count(_rest, "opened", 1)
	_page.close()


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
	assert_signal_emitted(_rest, "respawned")
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
