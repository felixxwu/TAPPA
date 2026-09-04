extends GutTest
# Menus vertical slice (todo/menus.md, todo/diegetic-hq.md): the diegetic 3D HQ
# (camera stations: exterior title → garage → map table → car park) → run → podium
# loop, and the run-scene fielding that wires it to RallySession
# (features/rally-session.md). Runs against a throwaway Save profile.

const SceneHelpers = preload("res://tests/headless/scene_helpers.gd")
const CarFixtures = preload("res://tests/headless/car_fixtures.gd")
const TEST_PATH := "user://test_menu_flow_profile.json"

var _save: Node


func before_each() -> void:
	# Clear any focus a previous test's overlay grabbed (menus grab focus deferred
	# for gamepad nav), so per-test focus assertions aren't contaminated by order.
	get_viewport().gui_release_focus()
	Config.reset()
	# PIN THE FLAT HOST. Most of this file asserts on the flat CanvasLayer menus — layer visibility,
	# focus in the main viewport — and `world_space_menus` is an authored value a designer may set
	# either way in game_config.tres. When it was switched on for tuning, eight of these failed for a
	# reason that had nothing to do with what they test. The world-mode tests below set it true
	# themselves, so pinning it false here makes both halves independent of the shipped default.
	Config.data.world_space_menus = false
	# These tests build hq.tscn many times but never assert on the HQ scenery COUNT
	# (only that a tree field of the right type exists), so trim the framing scatter to
	# keep each of the ~88 HQ builds cheap — the full 320+320 default is a pure-look
	# value exercised in the real game, not here.
	Config.data.hq_tree_count = 8
	Config.data.hq_bush_count = 8
	# Light the WHOLE map by default. Reveal is geometric now
	# (features/map-exploration.md), so a synthetic roster's pins are dark unless they
	# happen to sit near RallyLibrary.HQ_MAP_POS — and these tests deliberately spread pins
	# to the map's corners to exercise panning, selection and layout. Without this they
	# would all be locked, leaving the table with no pickable pin at all, which is a
	# reveal-rule assertion smuggled into every menu test rather than something they mean
	# to check. The tests that DO cover reveal set their own radius back (see
	# _dark_map_radius) so this default can't hide the behaviour it is standing in for.
	Config.data.map_hq_reveal_radius = 10.0
	CarFixtures.install()
	RallyFixtures.install()
	_save = get_node("/root/Save")
	_clean()
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.load_or_new()
	# Most HQ tests exercise a player who has already chosen their starter (the normal
	# state), so grant the starter car here. The first-run tests that cover the
	# starter-pick flow call _reset_to_first_run() to clear it back to an empty garage.
	_pick_starter()
	RallySession.auto_load_scenes = false
	if RallySession.is_active():
		RallySession.abandon()
	ChallengeSession.auto_load_scenes = false
	if ChallengeSession.is_active():
		ChallengeSession.abandon()


# Restore a REAL reveal radius for the tests that are actually about the map going dark —
# before_each lights everything so the layout/nav tests can see their pins. Returns HQ's
# radius to the shipped default, which is the value the roster is authored against.
func _dark_map_radius() -> void:
	Config.data.map_hq_reveal_radius = GameConfig.new().map_hq_reveal_radius
	Config.data.map_reveal_radius = GameConfig.new().map_reveal_radius


func after_each() -> void:
	if RallySession.is_active():
		RallySession.abandon()
	RallySession.auto_load_scenes = true
	if ChallengeSession.is_active():
		ChallengeSession.abandon()
	ChallengeSession.auto_load_scenes = true
	# ChallengeSession.abandon() clears profile["challenge_run"] on the LIVE Save
	# autoload — but Save.profile itself gets swapped out from under it per-test
	# (_save.load_or_new() below), so also clear any run a previous test left in the
	# throwaway profile file directly, the same belt-and-braces reset RallySession
	# gets via .abandon() above.
	Save.profile["challenge_run"] = {}
	_clean()
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	Config.reset()
	CarFixtures.restore()
	RallyFixtures.restore()
	RallyLibrary.reset()  # drop any synthetic rally roster a test installed
	RegionLibrary.reset()  # drop any synthetic region roster a test installed


func _clean() -> void:
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


# Simulate a completed first-run starter pick: grant the starter car and flag the
# profile so Start goes straight to the garage (the first run now picks a starter in the
# car park — see test_first_run_start_opens_starter_pick_then_grants_first_car). Tests that
# need an existing garage call this before booting HQ.
# The model a synthetic roster's OPENING rally awards. Any id will do — nothing looks it
# up in CarLibrary; what matters is that the profile's `starter_model_id` and some rally's
# `prize_car` agree, which is what lights that rally from the start.
const STARTER_PRIZE_CAR := "fx_start_car"


func _pick_starter(model_id := "fx_light_rwd") -> void:
	_save.profile["starter_picked"] = true
	_save.profile["starter_model_id"] = model_id
	_save.grant_car(model_id)


# Undo the before_each starter grant: a fresh first-run profile with an empty garage.
# Used by the tests that cover the first-run starter-pick flow itself.
func _reset_to_first_run() -> void:
	_save.profile["cars"] = []
	_save.profile["starter_picked"] = false
	_save.profile["starter_model_id"] = ""
	_save.profile["selected_instance_id"] = -1


# Car-park props now stream in one-per-frame (hq.gd._spawn_lineup_progressive), so wait
# until the whole lineup is parked before asserting on _cars. Pumps frames until the
# spawned count catches up to the eligible list (bounded so a stuck build can't hang).
func _await_lineup(hq: Node3D) -> void:
	for _i in 600:
		if hq._cars.size() >= hq._eligible.size():
			return
		await get_tree().process_frame


func _label_texts(root: Node) -> String:
	var parts: Array[String] = []
	for label in root.find_children("*", "Label", true, false):
		parts.append((label as Label).text)
	return "\n".join(parts)


# --- HQ (diegetic 3D hub) ----------------------------------------------------

# The 3D map pin for a rally (each pin Node3D carries a "rally_id" meta).
func _pin_for(hq: Node3D, rally_id: String) -> Node3D:
	for pin in hq._pins:
		if String((pin as Node3D).get_meta("rally_id", "")) == rally_id:
			return pin
	return null


# The table target (pin node) whose position is nearest `center` in the map (XZ)
# plane — the same "reticle over the map" rule the table selection uses.
func _nearest_target_to(hq: Node3D, center: Vector3) -> Node3D:
	var best: Node3D = null
	var best_d := INF
	for t in hq._table_ui._table_targets():
		var off: Vector3 = Vector3(t["pos"]) - center
		off.y = 0.0
		var d := off.length()
		if d < best_d:
			best_d = d
			best = t["node"]
	return best


# Glide the table camera in `dir` a step at a time until `rally_id` is the selected target;
# true if it ever was. Selection only happens while a pin is actually within
# GameConfig.map_select_radius_m of the view centre, so a pan big enough to slam into the
# map clamp sails PAST the far pin and selects nothing — the reticle has to be walked over
# it, which is also what a player holding a direction does.
func _pan_until_selected(hq: Node3D, dir: Vector2, rally_id: String) -> bool:
	for _i in 60:
		hq._table_ui._pan_table_step(dir, 0.1)
		var i: int = hq._table_focus_index
		if i < 0:
			continue
		var node: Node3D = hq._table_ui._table_targets()[i]["node"]
		if String(node.get_meta("rally_id", "")) == rally_id:
			return true
	return false


# The billboarded readout-box sprite a pin floats above its flag.
# The player's currently-owned car (before_each already grants a starter via
# _pick_starter) — the first entry in the profile's garage.
func _first_owned_car() -> Dictionary:
	return _save.profile["cars"][0]


# Any rally from the (possibly synthetic) catalogue — no assertion on which one, only
# that it exists, so this stays valid under CarFixtures/RallyLibrary overrides.
# Any ORDINARY MULTI-STAGE rally — the shape most of these tests mean by "a rally":
# three events, so per-stage standings, between-stage interstitials and "the final stage"
# all exist to assert on.
#
# It used to be `all()[0]`, which stopped being multi-stage the day the opening rallies
# were cut to a single event (todo/opening-rally.md) — and a caller driving three events
# through a one-stage rally fails somewhere far from the cause. Asking for the shape rather
# than for an index says what the caller actually needs.
func _any_rally() -> Dictionary:
	for rally in RallyLibrary.all():
		if (rally.get("events", []) as Array).size() >= RallySession.EVENTS_PER_RALLY:
			return rally
	return RallyLibrary.all()[0]


func _pin_label_sprite(pin: Node3D) -> Sprite3D:
	return pin.find_children("*", "Sprite3D", true, false)[0]


# The live pin nodes' instance ids, in map order — so a test can tell a pin set that was
# REUSED from one that was rebuilt (see test_hq_table_entry_reuses_unchanged_pins).
func _pin_ids(hq: Node3D) -> Array:
	var ids: Array = []
	for pin in hq._pins:
		ids.append((pin as Node3D).get_instance_id())
	return ids


func test_input_before_the_hq_is_built_does_not_crash() -> void:
	# _build_hq runs behind the "Entering HQ…" cover, after two process frames and a
	# possible boot-time cloud pull, and _unhandled_input is live for that whole window.
	# A player mashing a key while the cover is up used to reach station handlers that had
	# not been constructed yet and crash on a null base.
	#
	# No await here ON PURPOSE: the point is to drive input at a freshly-added, un-built HQ.
	_reset_to_first_run()
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	var press := InputEventAction.new()
	press.action = "ui_accept"
	press.pressed = true
	hq._unhandled_input(press)   # must simply do nothing rather than crash
	assert_true(true, "input arriving before the stations exist is ignored")


func test_hq_boots_to_the_exterior_title() -> void:
	_reset_to_first_run()
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	# First run no longer auto-grants a car — the player picks a starter on Start
	# (see test_first_run_start_opens_starter_pick_then_grants_first_car). The garage
	# is empty until then.
	assert_eq(_save.profile["cars"].size(), 0, "no car granted before the starter is picked")
	# Boots to the exterior/title station: the title overlay is up.
	assert_eq(hq._view, hq.View.EXTERIOR, "HQ boots to the exterior title station")
	assert_true(hq._title_layer.visible, "the title overlay is shown")
	assert_false(hq._car_layer.visible, "the car-park overlay is hidden at the title")
	await _await_lineup(hq)
	assert_eq(hq._cars.size(), 0, "an empty garage parks no cars on the title")
	# The 3D map table is populated with one pin per rally.
	assert_eq(hq._pins.size(), RallyLibrary.all().size(),
		"one map pin per rally — the single world map shows the whole roster")


func test_title_has_a_reachable_exit_game_button_on_desktop() -> void:
	# The exterior title carries an Exit Game button at the end of the row on
	# non-web builds (the headless test host is one). It's a real widget wired to
	# quit — reachable by keyboard/gamepad via the title cursor, not just the pointer.
	if OS.has_feature("web"):
		pass_test("web build omits Exit Game (the tab owns the process lifecycle)")
		return
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	assert_not_null(hq._overlays._title_exit_button, "the title screen has an Exit Game button")
	assert_true(hq._title_cursor.buttons.has(hq._overlays._title_exit_button),
		"Exit Game is a stop on the title's left/right cursor")
	# CHANGED DELIBERATELY: Exit Game used to sit AFTER Start. The house order is
	# exit-left / proceed-right (features/menus.md → "Button order"), so it now leads
	# the row and Start closes it.
	var parent: Node = hq._title_start_button.get_parent()
	assert_lt(hq._overlays._title_exit_button.get_index(), hq._title_start_button.get_index(),
		"Exit Game sits BEFORE Start — leaving is leftmost, proceeding is rightmost")
	assert_eq(hq._overlays._title_exit_button.get_parent(), parent,
		"Exit Game lives in the same title button row")


func test_hq_frames_the_lot_with_config_matched_trees() -> void:
	# HQ trees are spawned through the shared Foliage helper, so they match the
	# game's tree representation (opaque billboard cutout) instead of a hardcoded
	# mesh — and they're scenery (no collision).
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var field := hq.get_node_or_null("HQTrees")
	assert_not_null(field, "HQ frames the lot with a tree field")
	# Trees are always billboards.
	assert_true(field is BillboardField, "HQ frames the lot with billboard trees")
	assert_null(field.get_node_or_null("Collision"), "HQ trees are scenery (no collision)")


func test_hq_map_table_is_a_proper_wooden_model() -> void:
	# The map table is a built MapTable (top + apron + legs + stretchers), not a
	# single placeholder block, and its top surface sits at the configured height so
	# the map plane / pins still align.
	var cfg: GameConfig = Config.data
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	assert_true(hq._map_table is MapTable, "the table is a MapTable model")
	assert_eq(hq._map_table.position, cfg.hq_table_pos, "the table sits at the configured spot")
	assert_almost_eq(hq._map_table.top_y(), cfg.hq_table_size.y, 0.001,
		"the table top stays at the configured height (map plane / pins align)")
	# Tabletop slab + four apron rails + four legs + three stretchers = 12 meshes.
	var meshes: Array = hq._map_table.find_children("*", "MeshInstance3D", true, false)
	assert_eq(meshes.size(), 12, "the table is built from a top, apron, legs and stretchers")
	# Every part wears the shared wood texture.
	for mi in meshes:
		var mat := (mi as MeshInstance3D).material_override as StandardMaterial3D
		assert_not_null(mat, "each table part has a material")
		assert_not_null(mat.albedo_texture, "each table part wears the wood grain texture")


func test_hq_settings_page_selects_and_persists_control_scheme() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	# Settings now lives on the title screen (moved off the garage row).
	hq._open_settings(false)
	assert_true(hq._settings_layer.visible, "the settings overlay is shown")
	assert_false(hq._title_layer.visible, "the title overlay is hidden in settings")
	assert_true(hq._settings_menu.at_root(), "Settings opens on the category list")
	# The shared SettingsMenu: a camera-angle row per mode and a row per control scheme.
	assert_eq(hq._settings_menu.camera_rows.size(), CameraManager.MODES.size(),
		"one settings row per camera angle")
	assert_eq(hq._settings_menu.scheme_rows.size(), MobileControls.SCHEMES.size(),
		"one settings row per control scheme")
	# Drill into the Camera page, then pick the bonnet camera; it persists to the save profile.
	hq._settings_menu.show_camera()
	assert_false(hq._settings_menu.at_root(), "tapping a category opens its own page")
	assert_eq(hq._settings_action_button.text.to_upper(), "< BACK",
		"the bottom button reads Back on a sub-page")
	hq._settings_menu.select_camera(CameraManager.Mode.BONNET)
	assert_eq(int(_save.get_setting(CameraManager.SETTING_KEY, -1)),
		CameraManager.Mode.BONNET, "the chosen camera angle is saved")
	# Drill into the Mobile controls page and pick the tilt scheme; it persists.
	hq._settings_menu.show_schemes()
	hq._settings_menu.select_scheme(MobileControls.SCHEME_TILT_GAS_BRAKE)
	assert_eq(int(_save.get_setting(MobileControls.SETTING_KEY, -1)),
		MobileControls.SCHEME_TILT_GAS_BRAKE, "the chosen scheme is saved")
	# The bottom button backs out a level at a time: sub-page then list then title.
	hq._on_settings_action()
	assert_true(hq._settings_menu.at_root(), "Back from a sub-page returns to the list")
	assert_true(hq._settings_layer.visible, "still in Settings after backing to the list")
	hq._on_settings_action()
	assert_true(hq._title_layer.visible, "Back from the list returns to the title")
	assert_false(hq._settings_layer.visible, "the settings overlay is hidden again")


# --- Keyboard / gamepad navigation -------------------------------------------

# The title row (Start / Settings / Free Roam, plus Exit Game on desktop) is a single
# left/right ButtonCursor, same diegetic idiom as the garage row and lift hub —
# menu_left/menu_right move the cursor, menu_select fires the item under it.
func test_hq_title_is_a_left_right_cursor() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.EXTERIOR, "boots to the title")
	# Order is exit-left / proceed-right: [Exit Game] Free Roam Settings [Start], with
	# Exit Game absent on web. Asserted by BUTTON IDENTITY at each step rather than by
	# literal index, so the web build (one fewer stop) walks the same path.
	var cursor: Array = hq._title_cursor.buttons
	assert_eq(cursor[cursor.size() - 1], hq._title_start_button,
		"Start is LAST — it is the proceeding action")
	assert_eq(hq._title_focus, cursor.size() - 1, "the title cursor starts on Start")
	if hq._overlays._title_exit_button != null:
		assert_eq(cursor[0], hq._overlays._title_exit_button, "Exit Game is FIRST — it is the way out")
	hq._move_title_focus(1)
	assert_eq(hq._title_focus, 0, "right from the end wraps to the first stop")
	hq._move_title_focus(-1)
	assert_eq(hq._title_focus, cursor.size() - 1, "and left from there wraps back onto Start")
	# Walk the whole row and confirm every stop is reachable and distinct.
	var seen: Array = []
	for _i in cursor.size():
		assert_false(seen.has(hq._title_focus), "each left/right step lands on a new stop")
		seen.append(hq._title_focus)
		hq._move_title_focus(1)
	assert_eq(seen.size(), cursor.size(), "every button in the row is reachable")

	# Select on Settings opens the settings page.
	hq._title_focus = cursor.find(hq._overlays._title_settings_button)
	hq._activate_title_focus()
	assert_eq(hq._view, hq.View.SETTINGS, "select on Settings opens the settings page")


# Settings opened from the title screen must return to the title on back — it no
# longer lives on the garage row, so there is nothing else to route back to.
func test_hq_title_settings_returns_to_title_on_back() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._open_settings(false)
	assert_eq(hq._view, hq.View.SETTINGS, "Settings is open")
	assert_true(hq._settings_menu.at_root(), "Settings opens on the category list")
	hq._on_settings_action()
	assert_eq(hq._view, hq.View.EXTERIOR, "Back from the settings list returns to the title")
	assert_true(hq._title_layer.visible, "the title overlay is shown again")
	assert_eq(hq._title_focus, hq._title_start_index(),
		"re-entering the title re-seats the cursor on Start")


# Regression: menu_select on the title must fire the item the CURSOR sits on, not
# hard-route to Start. menu_select shares Enter with ui_accept, so a stray EXTERIOR
# menu_select handler used to start the run even when Settings was the cursor stop.
func test_hq_title_accept_does_not_force_start() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.EXTERIOR, "boots to the title")
	# Move the cursor onto Settings (not Start), then feed a menu_select action as the
	# engine would. The title's input handler must NOT start the run (which would leave
	# EXTERIOR for GARAGE); the cursor's current stop drives select.
	hq._title_focus = 2
	hq._refresh_title_focus()
	var ev := InputEventAction.new()
	ev.action = "menu_select"
	ev.pressed = true
	hq._unhandled_input(ev)
	assert_eq(hq._view, hq.View.SETTINGS,
		"menu_select on the title fires whatever the cursor sits on, not Start")



# The build version is shown on the title screen only (it was removed from the
# in-run HUD). build_web.sh stamps application/config/version; editor/test runs
# fall back to the project default ("0.0-dev").
func test_hq_title_shows_build_version() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var ver := str(ProjectSettings.get_setting("application/config/version", ""))
	assert_ne(ver, "", "project.godot defines application/config/version")
	assert_not_null(hq._overlays._title_version_label, "the title overlay has a version label")
	# UITheme.enforce() uppercases every overlay label (house style), so the
	# version renders capped (e.g. "V0.0-DEV").
	assert_eq(hq._overlays._title_version_label.text, UITheme.caps("v" + ver),
		"the title version label mirrors application/config/version")
	# NOT on _title_layer: that layer is stood down when the title screen migrates to a
	# WorldPanel, and the watermark went invisible for the whole session with it — the one
	# readout that says which build you are looking at, missing from the shipped config. It has
	# its own layer now, shown with the title screen.
	assert_ne(hq._overlays._title_version_label.get_parent(), hq._title_layer as Node,
		"the version label is not riding on the title's migratable layer")
	assert_true(MenuNav.is_on_screen(hq._overlays._title_version_label),
		"and it is on screen at the title station")


func test_the_build_watermark_survives_a_world_hosted_title() -> void:
	# The whole point of giving it its own layer: it must be legible on either host.
	Config.data.world_space_menus = true
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	assert_false(hq._title_layer.visible, "precondition: the title is on its panel, flat layer down")
	assert_true(MenuNav.is_on_screen(hq._overlays._title_version_label),
		"the build watermark is still on screen with world menus on")
	hq.go_to(hq.View.GARAGE)
	await get_tree().process_frame
	assert_false(MenuNav.is_on_screen(hq._overlays._title_version_label),
		"and it goes away with the title screen, rather than following you round the HQ")


# The pan path repaints the focus highlight only when the selection CHANGES (it runs every
# frame while a direction is held, and repainting allocates a StyleBoxFlat per pin). The
# guard is keyed on the pin NODE, not the focus index, because _refresh_map_pins throws the
# pin nodes away and rebuilds them while _table_focus_index keeps its old value — so an
# index-keyed guard would leave the newly-built pin unpainted. This asserts the rebuilt pin
# still ends up wearing the highlight.
func test_hq_map_table_focus_highlight_survives_a_pin_rebuild() -> void:
	RegionLibrary.override_for_test([{"id": "home", "name": "Home"}])
	RallyLibrary.override_for_test([
		{"id": "a", "name": "A", "region": "home", "special": false, "map_pos": Vector2(0.5, 0.5), "restriction": {}, "events": []},
	])
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._table_ui._enter_table()
	await get_tree().process_frame

	var before: Node3D = hq._table_ui._table_targets()[hq._table_focus_index]["node"]
	var idx_before: int = hq._table_focus_index
	var box_before: StyleBoxFlat = before.get_meta("label_panel").get_theme_stylebox("panel")
	assert_eq(box_before.bg_color, UITheme.SURFACE_HOVER, "the entry selection is painted as focused")

	# Rebuild the pins, then re-run the per-frame selection step exactly as _process would.
	# The stamp is cleared first because _refresh_map_pins now SKIPS a refresh whose inputs
	# are unchanged (see test_hq_table_entry_reuses_unchanged_pins) — this test is about what
	# happens when a real rebuild does replace the nodes, which is what any profile / roster /
	# reveal-parade change causes.
	hq._pins_stamp = null
	hq._refresh_map_pins()
	hq._table_ui._select_target_under_center()
	var after: Node3D = hq._table_ui._table_targets()[hq._table_focus_index]["node"]
	assert_eq(hq._table_focus_index, idx_before,
		"the rebuild reuses the same focus index — which is why the guard can't key on it")
	assert_ne(after, before, "the rebuild replaced the pin nodes")
	var box_after: StyleBoxFlat = after.get_meta("label_panel").get_theme_stylebox("panel")
	assert_eq(box_after.bg_color, UITheme.SURFACE_HOVER,
		"the rebuilt pin is repainted as focused, not left unhighlighted")
	RegionLibrary.reset()
	RallyLibrary.reset()


# Opening the map table must not rebuild a pin set that would come out identical. HQ boot
# already builds the pins behind the loading cover, so the rebuild _enter_table used to do
# unconditionally was ~32 pins' worth of work (meshes, readout SubViewports, prize-car
# re-parenting) landing in the frame the camera starts its glide to the table — the hitch
# features/menus.md -> "What a map-table entry costs" describes. Anything the pins actually
# read still forces the rebuild, which is the other half of the contract.
func test_hq_table_entry_reuses_unchanged_pins() -> void:
	RegionLibrary.override_for_test([{"id": "home", "name": "Home"}])
	RallyLibrary.override_for_test([
		{"id": "a", "name": "A", "region": "home", "special": false,
			"map_pos": Vector2(0.5, 0.5), "restriction": {}, "events": []},
		{"id": "b", "name": "B", "region": "home", "special": false,
			"map_pos": Vector2(0.6, 0.5), "restriction": {}, "events": []},
	])
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._table_ui._enter_table()
	await get_tree().process_frame
	# The FIRST entry may legitimately rebuild (it banks any pending reveals, which writes the
	# profile). From here the state is settled.
	var settled := _pin_ids(hq)
	assert_eq(settled.size(), 2, "both rallies are pinned")

	hq.go_to(hq.View.GARAGE, true)
	hq._table_ui._enter_table()
	await get_tree().process_frame
	assert_eq(_pin_ids(hq), settled, "re-entering the table with nothing changed keeps the pins")

	# ...and a change the pins DO read rebuilds them. Completing a rally moves both its star
	# row and the fog the map is shaded with.
	Save.record_podium_rally("a", 100000, 1)
	hq._table_ui._enter_table()
	await get_tree().process_frame
	var rebuilt := _pin_ids(hq)
	assert_eq(rebuilt.size(), 2, "still two pins after the rebuild")
	assert_ne(rebuilt, settled, "a profile change the pins read forces a real rebuild")
	RegionLibrary.reset()
	RallyLibrary.reset()


# A pin's readout is composited in its own off-screen SubViewport, and only the ONE the
# cursor is on may render: they used to sit at UPDATE_ALWAYS, so every pin re-composited a
# 400x150 panel every frame from HQ boot onward — invisible work, since the boxes are
# hover-only and the player is usually nowhere near the table.
func test_hq_only_the_hovered_pin_readout_renders() -> void:
	RegionLibrary.override_for_test([{"id": "home", "name": "Home"}])
	RallyLibrary.override_for_test([
		{"id": "a", "name": "A", "region": "home", "special": false,
			"map_pos": Vector2(0.5, 0.5), "restriction": {}, "events": []},
		{"id": "b", "name": "B", "region": "home", "special": false,
			"map_pos": Vector2(0.9, 0.9), "restriction": {}, "events": []},
	])
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._table_ui._enter_table()
	await get_tree().process_frame

	var focused: Node3D = hq._table_ui._table_targets()[hq._table_focus_index]["node"]
	for pin in hq._pins:
		var sprite: Node3D = pin.get_meta("label_sprite")
		var vp: SubViewport = sprite.get_meta("viewport")
		var on: bool = pin == focused
		assert_eq(sprite.visible, on, "only the hovered pin shows its readout")
		assert_eq(vp.render_target_update_mode,
			SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED,
			"a readout viewport renders only while its box is up")

	# Dropping the cursor entirely closes every box AND stops every viewport.
	hq._table_ui._clear_table_focus()
	for pin in hq._pins:
		var sprite2: Node3D = pin.get_meta("label_sprite")
		assert_false(sprite2.visible, "clearing the cursor closes every readout")
		assert_eq((sprite2.get_meta("viewport") as SubViewport).render_target_update_mode,
			SubViewport.UPDATE_DISABLED, "and leaves no viewport rendering")
	RegionLibrary.reset()
	RallyLibrary.reset()


# The map table pans the camera directly: pressing a direction slides the view centre
# that way, and selection snaps to whichever pin now sits nearest the centre (a
# reticle over the map, not discrete jumps). Select opens the selected rally.
func test_hq_map_table_pans_camera_and_tracks_centre() -> void:
	RegionLibrary.override_for_test([{"id": "home", "name": "Home"}])
	# Three pins at known map_pos: b is "up-map" of a (smaller y), c is off to +x.
	RallyLibrary.override_for_test([
		{"id": "a", "name": "A", "region": "home", "special": false, "map_pos": Vector2(0.5, 0.8), "restriction": {}, "events": []},
		{"id": "b", "name": "B", "region": "home", "special": false, "map_pos": Vector2(0.5, 0.2), "restriction": {}, "events": []},
		{"id": "c", "name": "C", "region": "home", "special": false, "map_pos": Vector2(0.85, 0.5), "restriction": {}, "events": []},
	])
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._table_ui._enter_table()
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.TABLE, "the map table is open")
	assert_gt(hq._table_focus_index, -1, "a target is selected on entry")

	var axes: Array = hq._table_ui._table_plane_axes()
	var up: Vector3 = axes[0]

	# Core contract: the selected target is always the one nearest the view centre.
	assert_eq(hq._table_ui._table_targets()[hq._table_focus_index]["node"],
		_nearest_target_to(hq, hq._table_ui._table_center_pos()),
		"selection = the target nearest the camera centre on entry")

	# Gliding up slides the camera centre in the screen-up direction...
	var before_up: float = hq._table_ui._table_center_pos().dot(up)
	hq._table_ui._pan_table_step(Vector2.UP, 0.4)
	assert_gt(hq._table_ui._table_center_pos().dot(up), before_up, "gliding up pans the view centre upward")
	# ...and selection re-snaps to whatever is now nearest the centre.
	assert_eq(hq._table_ui._table_targets()[hq._table_focus_index]["node"],
		_nearest_target_to(hq, hq._table_ui._table_center_pos()),
		"selection tracks the view centre after panning")

	# Glide up the map: the reticle picks up the up-most pin (b) as it crosses it.
	assert_true(_pan_until_selected(hq, Vector2.UP, "b"),
		"panning up the map selects the up-most pin")

	# Keep going, past every pin: nothing is under the reticle and nothing is selected, so
	# Select over empty map opens no rally (GameConfig.map_select_radius_m).
	for _i in 40:
		hq._table_ui._pan_table_step(Vector2.UP, 0.4)
	assert_eq(hq._table_focus_index, -1, "panned off past every pin, nothing is selected")
	hq._table_ui._activate_table_focus()
	assert_false(hq._detail_open, "and Select over empty map opens nothing")

	# Fresh view, then glide right along the map's centre line: the right-most pin (c) ends
	# up selected. The pan is zeroed first because entry seats the camera on a pin (a, which
	# is up-map), and sweeping right from THERE runs along a line c never comes near.
	hq._table_ui._enter_table()
	await get_tree().process_frame
	hq._table_pan = Vector3.ZERO
	assert_true(_pan_until_selected(hq, Vector2.RIGHT, "c"),
		"panning right across the map selects the right-most pin")
	var sel: Node3D = hq._table_ui._table_targets()[hq._table_focus_index]["node"]

	# The selected pin gets the hover-style underline; a pin stays scale 1.
	var box: StyleBoxFlat = sel.get_meta("label_panel").get_theme_stylebox("panel")
	assert_eq(box.border_width_bottom, 3, "the selected pin gets the hover-style underline")
	assert_almost_eq(float(sel.scale.x), 1.0, 0.01, "the selected pin is NOT scaled up")

	# Select on the selected pin opens its rally detail.
	hq._table_ui._activate_table_focus()
	assert_true(hq._detail_open, "selecting the pin opens its rally detail")
	assert_eq(hq._selected_rally_id, String(sel.get_meta("rally_id")), "it opens the selected pin's rally")
	RegionLibrary.reset()
	RallyLibrary.reset()


# Opening the map steers straight to the hardest event the player hasn't beaten:
# on entry focus (and the camera) land on the highest-difficulty incomplete pin,
# skipping ones already completed. Falls back to the centre-nearest pin once every
# event is done.
func test_hq_table_entry_focuses_hardest_incomplete_rally() -> void:
	RegionLibrary.override_for_test([{"id": "home", "name": "Home"}])
	RallyLibrary.override_for_test([
		{"id": "easy", "name": "Easy", "region": "home", "difficulty": 1, "special": false, "map_pos": Vector2(0.3, 0.5), "restriction": {}, "events": []},
		{"id": "hard", "name": "Hard", "region": "home", "difficulty": 4, "special": false, "map_pos": Vector2(0.7, 0.5), "restriction": {}, "events": []},
		{"id": "mid", "name": "Mid", "region": "home", "difficulty": 2, "special": false, "map_pos": Vector2(0.5, 0.2), "restriction": {}, "events": []},
	])
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame

	# Nothing completed → focus the highest-difficulty pin ("hard").
	hq._table_ui._enter_table()
	await get_tree().process_frame
	assert_eq(String(hq._table_ui._table_targets()[hq._table_focus_index]["node"].get_meta("rally_id")), "hard",
		"entry focuses the highest-difficulty incomplete rally")

	# Complete the hardest → entry now skips it and lands on the next-hardest ("mid").
	_save.record_podium_rally("hard", 60000, 1)
	hq._table_ui._enter_table()
	await get_tree().process_frame
	assert_eq(String(hq._table_ui._table_targets()[hq._table_focus_index]["node"].get_meta("rally_id")), "mid",
		"a completed event is skipped; focus falls to the next-hardest incomplete one")

	# Everything done → fall back to the centre-nearest target (still a valid pin).
	_save.record_podium_rally("mid", 60000, 1)
	_save.record_podium_rally("easy", 60000, 1)
	hq._table_ui._enter_table()
	await get_tree().process_frame
	assert_gt(hq._table_focus_index, -1, "with all events done, entry still seats a target")

	RegionLibrary.reset()
	RallyLibrary.reset()


# There is ONE world map with every rally pinned on it, so an unrevealed rally still
# gets a pin — it just renders locked: greyed, no pickable hit area, and excluded from
# the keyboard/gamepad focus ring. That's the invariant the single-map change most
# easily breaks (the old per-region map simply never drew the rally at all).
func test_unrevealed_rallies_still_get_a_disabled_pin() -> void:
	# About REVEAL, so it needs the real radius rather than before_each's lit-everything
	# default — and "locked" is a pin POSITION now: at HQ = open, far out = dark.
	_dark_map_radius()
	var hq_pos: Vector2 = RallyLibrary.HQ_MAP_POS
	RegionLibrary.override_for_test([{"id": "home", "name": "Home"}])
	RallyLibrary.override_for_test([
		{"id": "open", "name": "Open", "region": "home", "special": false,
			"map_pos": hq_pos, "restriction": {}, "events": []},
		{"id": "later", "name": "Later", "region": "home", "special": false,
			"map_pos": hq_pos + Vector2(0.9, 0.0), "restriction": {}, "events": []},
		{"id": "sd", "name": "SD", "region": "home", "special": true,
			"map_pos": Vector2(0.5, 0.2), "restriction": {}, "events": []},
	])
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._table_ui._enter_table()
	await get_tree().process_frame

	# The fog DIMS what the player cannot reach; it does not delete it. Every rally in the
	# roster stands a pin, reached or not — a map that only exists where you have already
	# driven gives you nothing to steer by. What the dark withholds is the ROUTE and the
	# ability to enter, not the knowledge that something is out there.
	var by_id: Dictionary = {}
	for pin in hq._pins:
		by_id[String(pin.get_meta("rally_id"))] = pin
	assert_eq(hq._pins.size(), 3, "every rally in the roster is pinned, reached or not")
	assert_false(bool(by_id["open"].get_meta("locked")), "a revealed rally's pin is not locked")
	assert_true(bool(by_id["later"].get_meta("locked")), "an unreached rally's pin is locked")
	assert_true(bool(by_id["sd"].get_meta("locked")), "and so is an unreached special's")

	# Locked = look, don't touch: no pickable hit area, so it can't be tapped into.
	assert_gt(by_id["open"].find_children("*", "Area3D", true, false).size(), 0,
		"a revealed rally's pin IS clickable")
	for rid in ["later", "sd"]:
		assert_eq((by_id[rid] as Node3D).find_children("*", "Area3D", true, false).size(), 0,
			"an unreached rally's pin has no hit area to tap")

	# The cursor, though, IS allowed onto a locked pin: readouts are hover-only, so a pin the
	# cursor cannot reach could never answer when you point at it. Every map target is a rally
	# now — the present box that used to sit among them is gone with the car-purchase economy
	# (features/star-economy.md).
	hq._refresh_map_pins()
	var focusable: Array = []
	for t in hq._table_ui._table_targets():
		assert_eq(String(t["kind"]), "pin", "every map target is a rally pin")
		focusable.append(String((t["node"] as Node3D).get_meta("rally_id")))
	assert_eq(focusable, ["open", "later", "sd"], "every pin is a cursor target, enterable or not")

	# ...and it is SELECT that refuses, not the cursor: parking on the unreached pin and
	# pressing it opens nothing. ("sd" rather than "later" because the pan clamps to the map
	# extents and "later" is authored deliberately off the edge, out of the camera's reach.)
	assert_true(_pan_until_selected(hq, Vector2.UP, "sd"),
		"panning out into the dark lands the cursor on the unreached pin")
	hq._table_ui._activate_table_focus()
	assert_false(hq._detail_open, "selecting an unreached pin opens no rally detail")

	RegionLibrary.reset()
	RallyLibrary.reset()


# The tuning hub's ACTIONS row is a manual left/right cursor over Back / Upgrades /
# Tuning / Test Drive; select fires the focused item, opening a page (native focus).
# (The car-selector row ABOVE it, and up/down between the two, are covered by
# test_hq_lift_selector_is_a_second_cursor_row.)
func test_hq_lift_actions_row_is_a_left_right_cursor() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_lift()
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.LIFT, "the tuning bay is open")
	assert_eq(hq._lift_page, hq.LiftPage.HUB, "it opens on the hub")
	# The hub is a left/right cursor over Back (0) / Upgrades (1) / Tuning (2) /
	# Repair (3) / Test Drive (4), wrapping at both ends. (Wheels moved into the Tuning
	# panel itself, so it's no longer a hub cursor stop; Repair arrived with the star
	# sinks — features/star-economy.md.)
	# Repair is DISABLED here (this car is undamaged), and the cursor skips disabled stops —
	# so it is passed over rather than being a dead landing spot. See
	# test_hq_lift_repair_button_is_reachable_once_the_car_is_damaged for the other half.
	var last: int = hq._hub_cursor.buttons.size() - 1
	assert_eq(hq._hub_focus, 1, "the hub cursor starts on Upgrades")
	hq._move_hub_focus(1)
	assert_eq(hq._hub_focus, 2, "right moves the cursor to Tuning")
	hq._move_hub_focus(1)
	assert_eq(hq._hub_focus, last, "right again skips the disabled Repair and lands on Test Drive")
	hq._move_hub_focus(1)
	assert_eq(hq._hub_focus, 0, "right from the end wraps to Back")
	hq._move_hub_focus(-1)
	assert_eq(hq._hub_focus, last, "left from Back wraps onto Test Drive")

	# Select on the Tuning item opens the Tune page (stays in the bay).
	hq._hub_focus = 2
	hq._activate_hub_focus()
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.LIFT, "select on Tuning stays in the bay")
	assert_eq(hq._lift_page, hq.LiftPage.TUNE, "select on Tuning opens the Tune page")
	hq._lift_hub()
	await get_tree().process_frame

	# Opening the Tune page seats native focus on one of its sliders.
	hq._open_lift_page(hq.LiftPage.TUNE)
	await get_tree().process_frame
	assert_true(hq.get_viewport().gui_get_focus_owner() is HSlider,
		"opening the Tune page focuses a tuning slider for keyboard/gamepad")


# The lift HUB is TWO cursor rows: the car SELECTOR (< name >) above, the ACTIONS row
# (Back / Upgrades / Tuning / Test Drive) below. up/down move between them, left/right
# within whichever is active, and select fires that row's item. Exactly one row is ever
# highlighted, so a press is never ambiguous.
func test_hq_lift_selector_is_a_second_cursor_row() -> void:
	_save.grant_car("fx_fwd_hatch")  # a second car, so the selector has somewhere to go
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_lift()
	await get_tree().process_frame
	assert_eq(hq._lift_row, hq.LiftRow.ACTIONS, "the bay opens on the actions row")

	# Up reaches the selector; left/right then walk the chevrons, NOT the actions row.
	hq._move_lift_row(hq.LiftRow.SELECTOR)
	assert_eq(hq._lift_row, hq.LiftRow.SELECTOR, "up moves the cursor onto the car selector")
	var actions_before: int = hq._hub_focus
	assert_eq(hq._lift_selector_focus, 0, "it lands on the first chevron")
	hq._move_hub_focus(1)
	assert_eq(hq._lift_selector_focus, 1, "right moves along the selector row")
	assert_eq(hq._hub_focus, actions_before,
		"...and leaves the actions row's own cursor where it was")
	hq._move_hub_focus(1)
	assert_eq(hq._lift_selector_focus, 0, "right from the last chevron wraps")

	# Down returns to the actions row, still seated where it was left.
	hq._move_lift_row(hq.LiftRow.ACTIONS)
	assert_eq(hq._lift_row, hq.LiftRow.ACTIONS, "down returns to the actions row")
	assert_eq(hq._hub_focus, actions_before, "the actions cursor is where it was left")
	hq._move_hub_focus(1)
	assert_ne(hq._hub_focus, actions_before, "and left/right drives the actions row again")


# Selecting a chevron — by cursor OR by click, which share one callable — puts a
# different owned car on the lift and redraws the readout for it.
func test_hq_lift_selector_cycles_the_car_on_the_lift() -> void:
	_save.grant_car("fx_fwd_hatch")
	_save.grant_car("fx_rwd_coupe")
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_lift()
	await get_tree().process_frame
	var first: int = _save.selected_instance_id()
	assert_eq(hq._lift_car_instance_id, first, "the selected car is the one on the lift")

	# A cursor select on the "next" chevron.
	hq._move_lift_row(hq.LiftRow.SELECTOR)
	hq._lift_selector_focus = 1
	hq._activate_hub_focus()
	await get_tree().process_frame
	var second: int = _save.selected_instance_id()
	assert_ne(second, first, "selecting a chevron selects a different car")
	assert_eq(hq._lift_car_instance_id, second, "and that car is the one now on the lift")
	# UITheme.enforce uppercases every label, so compare through the same helper rather
	# than against the raw display name.
	assert_eq(hq._lift_car_label.text, UITheme.caps(EngineSwap.display_name(
		CarLibrary.by_id(String(_save.selected_car().get("model_id", ""))), _save.selected_car())),
		"the nameplate names the car that is on the lift")

	# A CLICK on the other chevron goes back — same path, so the two can't disagree.
	hq._lift_prev_button.pressed.emit()
	await get_tree().process_frame
	assert_eq(_save.selected_instance_id(), first, "the other chevron walks back to the first car")
	assert_eq(hq._lift_car_instance_id, first, "and the lift follows")


# Cycling walks the WHOLE collection rather than flipping between two cars. Regression:
# Save.set_selected_car promotes the selected car to the front of profile["cars"], so
# cycling by list position renumbered the list on every press and ping-ponged.
func test_hq_lift_selector_tours_every_owned_car() -> void:
	_save.grant_car("fx_fwd_hatch")
	_save.grant_car("fx_rwd_coupe")
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_lift()
	await get_tree().process_frame
	var owned: int = _save.profile["cars"].size()
	assert_gt(owned, 2, "setup: more than two cars, so ping-ponging is detectable")

	var seen := {}
	for _i in owned:
		seen[_save.selected_instance_id()] = true
		hq._cycle_lift_car(1)
		await get_tree().process_frame
	assert_eq(seen.size(), owned, "stepping forward once per car visits every one of them")


# With a single car there is nothing to cycle to: the chevrons are hidden AND disabled, and
# up must not strand the cursor on a button that isn't on screen.
func test_hq_lift_selector_is_unreachable_with_one_car() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	assert_eq(_save.profile["cars"].size(), 1, "setup: the starter car alone")
	hq._enter_lift()
	await get_tree().process_frame
	assert_false(hq._lift_prev_button.visible, "nothing to cycle to, so no chevrons are drawn")
	assert_true(hq._lift_prev_button.disabled, "and they are not cursor stops either")

	hq._move_lift_row(hq.LiftRow.SELECTOR)
	assert_eq(hq._lift_row, hq.LiftRow.ACTIONS, "up is a no-op with an empty selector row")
	# The single car still reads out normally.
	assert_ne(hq._lift_car_label.text, "", "the nameplate still names the car")
	assert_ne(hq._lift_car_stats_label.text, "", "and the stats row is still filled")


# A fitted nitrous bottle is named on the stats readout, after the health segment — shared
# by the lift and the car-park lineup, since both read _car_stats_text (hq.gd). Synthetic
# part, so this can't drift from (or depend on) the real nitrous ladder's ids or names.
func test_car_stats_text_names_a_fitted_nitrous_rung_after_health() -> void:
	UpgradeLibrary.override_for_test([
		{"id": "fx_nitrous", "name": "Fixture Nitrous", "slot": "nitrous", "consumable": false,
			"effect": {"install_nitrous": {"nitrous_boost_gain": 0.2, "nitrous_tank_seconds": 3.0}}},
	])
	var owned: Dictionary = _save.profile["cars"][0]
	var entry := CarLibrary.by_id(String(owned.get("model_id", "")))
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame

	var without: String = hq._car_stats_text(owned, entry)
	assert_false(without.contains("Fixture Nitrous"), "no nitrous fitted -> no segment at all")

	owned["installed_upgrades"] = ["fx_nitrous"]
	var with_nitrous: String = hq._car_stats_text(owned, entry)
	assert_true(with_nitrous.ends_with("Fixture Nitrous"),
		"the fitted rung's name is appended last, after health")


# Regression: the Upgrades page must seat keyboard/gamepad focus on a real control.
# On a fresh car it has no installed parts, is at full health (no repair button) and
# its Swap Engine button is disabled, so without an always-enabled control (the Back
# button) focus would land on nothing and the page would be dead to non-pointer input.
# The UPGRADES menu shows the STAR BALANCE, because this menu is where stars are
# spent — every part the player cannot afford quotes a price they would otherwise have to
# leave the menu to check against. It is the COMPONENT that draws it (UpgradesGrid), so
# every host of the page gets it; see test_upgrades_grid.gd.
func test_hq_upgrades_page_shows_the_star_balance() -> void:
	_save.profile["stars_earned"] = 7
	_save.profile["stars_spent"] = 0
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_lift()
	await get_tree().process_frame
	hq._open_lift_page(hq.LiftPage.UPGRADES)
	await get_tree().process_frame
	assert_eq(hq._lift_upgrades_box.balance_text(), "7", "the menu names the balance")
	# And it TRACKS the balance — buying a part on this page spends stars, so a readout
	# taken only on open would go stale the moment the player used it.
	_save.profile["stars_spent"] = 5
	hq._lift_upgrades_box.rebuild()
	await get_tree().process_frame
	assert_eq(hq._lift_upgrades_box.balance_text(), "2", "spending updates the balance")


# REGRESSION: no menu text may lean on a character the BUNDLED font can't draw. Syne Mono
# has no ★ glyph, so the star prices this page is full of ("Small (2★)", "Repair (1★)")
# looked right on desktop only because the OS handed Godot a system fallback font — the web
# export has no system fonts, so on mobile web every price rendered as a tofu box. Stars are
# drawn now: a StarRow.price_icon on the price BUTTONS, a StarRow node beside the heading's
# digits. Sweeps the whole lift station rather than the one label that broke, so the next
# glyph someone reaches for is caught here instead of on a phone.
func test_hq_lift_text_only_uses_characters_the_bundled_font_can_draw() -> void:
	# Damaged + solvent, so the Repair button quotes its price too (the other star label).
	_save.get_car(_save.selected_instance_id())["hp"] = 1.0
	_save.award_stars(20)
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_lift()
	await get_tree().process_frame
	hq._open_lift_page(hq.LiftPage.UPGRADES)
	await get_tree().process_frame

	var font: Font = UITheme.theme().default_font
	assert_not_null(font, "the house theme ships a font to check against")
	var priced := 0
	for node in hq._lift_layer.find_children("*", "Control", true, false):
		var text := ""
		if node is Label:
			text = (node as Label).text
		elif node is Button:
			text = (node as Button).text
			# A star price is the button's icon now, not a character in its label.
			if (node as Button).icon != null:
				priced += 1
		for i in text.length():
			var c := text.unicode_at(i)
			if c < 0x20:   # newlines / tabs are layout, not glyphs
				continue
			assert_true(font.has_char(c),
				"%s draws '%s' (U+%04X) in %s" % [node.name, text[i], c, text])
	assert_gt(priced, 0, "the page shows at least one drawn star price")


func test_hq_upgrades_page_is_keyboard_navigable() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_lift()
	await get_tree().process_frame
	hq._open_lift_page(hq.LiftPage.UPGRADES)
	await get_tree().process_frame
	var focused: Control = hq.get_viewport().gui_get_focus_owner()
	assert_true(focused != null, "opening the Upgrades page seats focus for keyboard/gamepad")
	if focused is BaseButton:
		assert_false((focused as BaseButton).disabled,
			"the focused control is interactive (not a disabled button)")


# Regression: the Upgrades page rebuilds its rows on every refresh (per car / after a
# toggle), and the WASD/gamepad focus nav is a MenuNav node parented to the box. The
# rebuild must NOT free that MenuNav (it clears only the row children) or the page loses
# keyboard nav, so exactly one survives across a rebuild.
func test_hq_upgrades_menunav_survives_rebuild() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_lift()
	await get_tree().process_frame
	hq._open_lift_page(hq.LiftPage.UPGRADES)
	await get_tree().process_frame
	assert_eq(_count_menunav(hq._lift_upgrades_box), 1,
		"the Upgrades box has its focus-nav helper after opening")
	hq._lift_upgrades_box.rebuild()  # a fresh rebuild (as a car swap / edit would trigger)
	await get_tree().process_frame
	assert_eq(_count_menunav(hq._lift_upgrades_box), 1,
		"the rebuild preserves exactly one focus-nav helper (WASD/gamepad nav survives)")


func _count_menunav(box: Node) -> int:
	var n := 0
	for c in box.get_children():
		if c is MenuNav and not c.is_queued_for_deletion():
			n += 1
	return n


# Regression: picking an option rebuilds the whole grid; the keyboard/gamepad cursor must
# stay on THAT TILE, not jump to the top of the page (or go null when the deferred re-grab
# lands on the freed old button). Uses whatever the catalogue offers (opaque — no dependence
# on a specific entry), skipping the drivetrain slot (its options need the swap kit; the
# fitted part below lands in one of the generic slots).
func test_hq_upgrades_toggle_keeps_focus_on_same_control() -> void:
	var item_id := ""
	for u in UpgradeLibrary.UPGRADES:
		if not bool(u.get("consumable", false)) \
				and String(u.get("slot", "")) != "drivetrain":
			item_id = String(u.get("id", ""))
			break
	if item_id == "":
		pass_test("no non-consumable option upgrade in the catalogue to install")
		return
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	Save.install_upgrade(int(Save.selected_car().get("instance_id", -1)), item_id, true)
	hq._enter_lift()
	await get_tree().process_frame
	hq._open_lift_page(hq.LiftPage.UPGRADES)
	await get_tree().process_frame
	# Focus a slot TILE, then rebuild the grid — which is exactly what applying an option
	# from that tile's picker does once the edit has landed.
	var opt: Button = null
	for node in hq._lift_upgrades_box.find_children("*", "Button", true, false):
		if node is Button and not (node as Button).disabled and node.has_meta("upgrade_focus_key") \
				and String(node.get_meta("upgrade_focus_key")).begins_with("tile:"):
			opt = node
			break
	assert_true(opt != null, "the grid shows a focusable slot tile")
	var key := String(opt.get_meta("upgrade_focus_key"))
	opt.grab_focus()
	await get_tree().process_frame
	hq._lift_upgrades_box.rebuild()
	await get_tree().process_frame
	await get_tree().process_frame
	var after: Control = hq.get_viewport().gui_get_focus_owner()
	assert_true(after != null, "focus is not lost across the rebuild")
	assert_true(after != null and after.has_meta("upgrade_focus_key") \
			and String(after.get_meta("upgrade_focus_key")) == key,
		"focus stays on the same tile after the rebuild (doesn't jump to the top)")


# The cursor resting on a tuning slider is enough to change it: a menu_left / menu_right
# press (WASD/stick, which don't natively drive the Range) nudges the value by its step
# instead of jumping focus to a neighbour — no "select the slider first" step.
func test_hq_tune_slider_changes_on_left_right_without_selecting() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_lift()
	await get_tree().process_frame
	hq._open_lift_page(hq.LiftPage.TUNE)
	await get_tree().process_frame
	var slider: HSlider = hq.get_viewport().gui_get_focus_owner()
	assert_true(slider is HSlider, "a tuning slider holds the cursor")
	slider.value = 0.0
	var before := slider.value
	_press_action("menu_right")
	await get_tree().process_frame
	assert_gt(slider.value, before, "menu_right raises the focused slider's value")
	assert_eq(hq.get_viewport().gui_get_focus_owner(), slider,
		"the cursor stays on the slider (left/right doesn't jump to a neighbour)")
	var mid := slider.value
	_press_action("menu_left")
	await get_tree().process_frame
	assert_lt(slider.value, mid, "menu_left lowers the focused slider's value")


# Regression: a sub-page's bottom action row lives OUTSIDE the scroll container (a
# different node level), but must still be reachable by keyboard/gamepad. menu_down off
# the last slider lands in the row, and menu_left walks along it to "< Back".
#
# This used to be a straight vertical walk (Reset / Wheels / Back were three stacked
# full-width rows, so menu_down passed through each). They share ONE horizontal row now,
# so reaching Back is down-then-left — the row is the bottom of the page, and further
# menu_down has nowhere to go.
func test_hq_tune_page_can_navigate_down_to_the_action_row() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_lift()
	await get_tree().process_frame
	hq._open_lift_page(hq.LiftPage.TUNE)
	await get_tree().process_frame
	assert_true(hq.get_viewport().gui_get_focus_owner() is HSlider, "starts on a slider")
	assert_eq(hq._lift_back_button.focus_mode, Control.FOCUS_ALL, "the Back button is focusable")
	var row: Node = hq._lift_back_button.get_parent()

	# Down out of the sliders lands SOMEWHERE in the bottom action row.
	var in_row := false
	for _i in 8:
		var focused: Node = hq.get_viewport().gui_get_focus_owner()
		if focused != null and focused.get_parent() == row:
			in_row = true
			break
		_press_action("menu_down")
		await get_tree().process_frame
	assert_true(in_row, "menu_down from the sliders reaches the bottom action row")

	# And Back is reachable along it — it leads the row, so left gets there.
	var reached := false
	for _i in 8:
		if hq.get_viewport().gui_get_focus_owner() == hq._lift_back_button:
			reached = true
			break
		_press_action("menu_left")
		await get_tree().process_frame
	assert_true(reached, "menu_left along the action row reaches the shared Back button")


func _press_action(action: String) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	get_viewport().push_input(ev)


func test_hq_dev_page_unlocks_cars_and_upgrades() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var dev = hq._settings_menu
	# The Dev category opens its own page from the list.
	hq._open_settings(false)
	dev.show_dev()
	assert_false(dev.at_root(), "the Dev category opens its own page")
	# Unlock any car: a new owned instance is added.
	var before: int = _save.profile["cars"].size()
	dev._grant_car("fx_awd", "Fixture AWD")
	assert_eq(int(_save.profile["cars"].size()), before + 1, "unlocking grants a car instance")
	# Fit any slottable upgrade: parts are car-bound, so it installs onto the
	# selected car (not a shared inventory, which no longer holds parts).
	dev._fit_upgrade("fx_turbo_small", "Small Turbo")
	assert_true((_save.selected_car().get("installed_upgrades", []) as Array).has("fx_turbo_small"),
		"fitting an upgrade installs it on the selected car")
	assert_eq(int(_save.profile["inventory"].get("fx_turbo_small", 0)), 0,
		"fitting an upgrade does not touch the consumable inventory")
	# NOTE: wiping the save is NOT on this page any more — it is a player setting on its
	# own Reset progress page, behind a confirm modal (tests/headless/test_settings_menu.gd).


# Fitting an upgrade from the Dev page changes Save's data with no reference back to the
# lift, so nothing rebuilds the already-fielded display car on its own (unlike the real
# upgrades menu, which calls back into _on_lift_upgrade_changed). SettingsMenu's
# dev_car_upgraded signal closes that gap — this is the regression test for it.
func test_dev_page_upgrade_fit_rebuilds_the_lift_car() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_lift()
	await get_tree().process_frame
	var before_stats: String = hq._lift_car_stats_label.text
	var before_hash: int = hq._lift_car_hash

	hq._open_settings(false)
	hq._settings_menu.show_dev()
	hq._settings_menu._fit_upgrade("fx_turbo_small", "Small Turbo")

	assert_ne(hq._lift_car_hash, before_hash,
		"the lift's cache key moved on, so _ensure_lift_car treats the fit as a real change")
	assert_ne(hq._lift_car_stats_label.text, before_stats,
		"the stats readout reflects the fitted part without leaving and re-entering the lift")


func test_hq_title_parks_all_owned_cars() -> void:
	# The title shows the whole collection, regardless of rally eligibility — grant
	# an RWD XJS (which an RWD rally would exclude) and it's still parked.
	_save.grant_car("fx_awd")
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	await _await_lineup(hq)
	assert_eq(hq._cars.size(), 2, "the title parks every owned car (starter + XJS)")


func test_returning_to_the_title_still_parks_the_selected_car() -> void:
	# REGRESSION: _lift_car shares its node with _car_cache, and _clear_lift_car
	# hides + stows that node. _go_to used to build the title lineup BEFORE
	# clearing the lift, so the selected car was parked and then immediately
	# hidden — and because set_selected_car promotes it to index 0, the first bay
	# on the title screen was always empty.
	_save.grant_car("fx_awd")
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	await _await_lineup(hq)

	# Go inside (the selected car moves onto the lift), then back out to the title.
	hq.go_to(hq.View.GARAGE)
	await get_tree().process_frame
	hq.go_to(hq.View.EXTERIOR)
	await get_tree().process_frame
	await _await_lineup(hq)

	assert_eq(hq._cars.size(), 2, "both owned cars are parked again")
	for car in hq._cars:
		assert_true(is_instance_valid(car) and (car as Node3D).visible,
			"every parked car is actually visible — no empty bay")


func test_a_cloud_restored_career_rebuilds_the_car_park() -> void:
	# Signing in on a new device downloads a career while the HQ is already up. If
	# the lot is not rebuilt the player is told they are signed in while still
	# looking at the empty garage they started with.
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	await _await_lineup(hq)
	var before: int = hq._cars.size()

	# Stand in for the download: the profile gains cars, then Cloud announces it.
	_save.grant_car("fx_awd")
	_save.grant_car("fx_rwd_coupe")
	Cloud.profile_replaced.emit()
	await get_tree().process_frame
	await _await_lineup(hq)

	assert_gt(hq._cars.size(), before,
		"the restored cars appear in the car park without a relaunch")


# The settings CATEGORY buttons (the list page), joined for substring checks.
func _settings_category_labels(menu: SettingsMenu) -> String:
	var labels: Array = []
	for node in menu._list_page.find_children("*", "Button", true, false):
		labels.append((node as Button).text)
	return "|".join(PackedStringArray(labels))


func test_players_do_not_see_the_developer_settings_pages() -> void:
	# Benchmark / Dev / Seed lab are dev tooling — a release build must not offer
	# them. The pages still exist (show_* still works); only the way in is gone.
	SettingsMenu.dev_tools_override = 0
	var menu := SettingsMenu.new()
	add_child_autofree(menu)
	await get_tree().process_frame
	# Scope to the CATEGORY LIST: the dev pages themselves are still built (only
	# unreachable), and their own buttons would otherwise match.
	var joined := _settings_category_labels(menu)
	SettingsMenu.dev_tools_override = -1

	assert_false(joined.contains("BENCHMARK"), "no Benchmark entry for players")
	assert_false(joined.contains("DEV"), "no Dev entry for players")
	assert_false(joined.contains("SEED LAB"), "no Seed lab entry for players")
	assert_true(joined.contains("AUDIO"), "the real settings are still there")
	assert_true(joined.contains("ACCOUNT"), "and so is the account page")
	assert_true(joined.contains("RESET PROGRESS"),
		"starting over is a player setting, not dev tooling")


func test_developer_builds_still_reach_the_dev_pages() -> void:
	SettingsMenu.dev_tools_override = 1
	var menu := SettingsMenu.new()
	add_child_autofree(menu)
	await get_tree().process_frame
	var joined := _settings_category_labels(menu)
	SettingsMenu.dev_tools_override = -1

	assert_true(joined.contains("BENCHMARK"))
	assert_true(joined.contains("SEED LAB"))


func test_hq_title_parks_starter_previews_when_garage_is_empty() -> void:
	# A fresh player (no car owned, starter not picked) would have an empty lot behind
	# the title — instead the starter cars are shown as previews so it's populated.
	# This backdrop is driven by hq.gd's STARTER_MODEL_IDS constant, which hardcodes real
	# catalogue ids (mx5/focus/twingo) — it can't be pointed at the synthetic fixtures
	# without touching production code, so restore the real catalogue for this one test
	# (same as test_first_run_start_opens_starter_pick_then_grants_first_car).
	CarFixtures.restore()
	_reset_to_first_run()
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	await _await_lineup(hq)
	assert_eq(hq._eligible.size(), hq.STARTER_MODEL_IDS.size(),
		"the empty-garage title parks one preview per starter car")
	for owned in hq._eligible:
		assert_lt(int(owned.get("instance_id", 0)), 0,
			"each parked car is a preview (negative id), not an owned car")


func test_hq_start_flies_into_the_garage() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	assert_eq(hq._view, hq.View.GARAGE, "Start flies the camera into the garage")
	assert_true(hq._garage_layer.visible, "the garage overlay is shown")
	assert_false(hq._title_layer.visible, "the title overlay is hidden in the garage")


# The garage overlay is ONE left/right cursor over Back (0) / Career (1) / Garage (2) /
# [Mystery Box] / Online (last), wrapping at both ends, with select firing the item under
# the cursor. (Repair lives on the tuning-lift HUB row; Settings and Free Roam live on the
# title screen — none of the three is on the garage row. The old "Drive" sub-level that
# used to hide Career/Online behind an extra press is gone.)
func test_hq_garage_is_a_left_right_cursor() -> void:
	# A second car, so the garage has something to page through. The row itself is a
	# fixed four stops now (Back / Career / Garage / Online) — the Mystery Box button that
	# used to pad it is gone with the box.
	_save.grant_car("fx_rwd_coupe")
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	assert_eq(hq._view, hq.View.GARAGE, "start lands in the garage")
	# Mystery Box is omitted when none is held, so no index in this row is a constant —
	# ask the cursor's own array rather than assuming positions.
	var cursor: Array = hq._garage_cursor.buttons
	var last: int = cursor.size() - 1
	assert_eq(hq._garage_career_index, 1, "Career is the first stop after Back")
	assert_eq(hq._garage_focus, hq._garage_career_index, "the garage cursor starts on Career")
	hq._move_garage_focus(-1)
	assert_eq(hq._garage_focus, 0, "left from Career reaches Back")
	hq._move_garage_focus(-1)
	assert_eq(hq._garage_focus, last, "left from Back wraps to the end of the row")
	# Every stop is reachable and distinct.
	var seen: Array = []
	for _i in cursor.size():
		assert_false(seen.has(hq._garage_focus), "each step lands on a new stop")
		seen.append(hq._garage_focus)
		hq._move_garage_focus(1)
	assert_eq(seen.size(), cursor.size(), "every button in the row is reachable")

	# Select on Career opens the map — no intermediate level to pass through.
	hq._garage_focus = hq._garage_career_index
	hq._activate_garage_focus()
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.TABLE, "select on Career opens the map directly")

	# Select on Garage goes straight to the tuning lift bay (there is no car-pick step in
	# between any more — the bay's own selector chevrons change the car in place).
	hq.go_to(hq.View.GARAGE)
	hq._garage_focus = 2  # Back(0) | Career(1) | Garage(2) | ...
	hq._activate_garage_focus()
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.LIFT, "select on Garage opens the tuning lift bay")

	# Back-to-garage, then select on the Back item leaves for the exterior.
	hq.go_to(hq.View.GARAGE)
	assert_eq(hq._garage_focus, hq._garage_career_index,
		"re-entering the garage re-seats the cursor on Career")
	hq._garage_focus = 0
	hq._activate_garage_focus()
	assert_eq(hq._view, hq.View.EXTERIOR, "select on Back leaves the garage for the exterior")


# menu_back on the garage row leaves the station outright. There is no longer a
# sub-level for it to step up into, so this is the only behaviour it has.
func test_hq_garage_menu_back_leaves_for_the_exterior() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	assert_eq(hq._view, hq.View.GARAGE, "setup: in the garage")
	var back := InputEventAction.new()
	back.action = "menu_back"
	back.pressed = true
	hq._unhandled_input(back)
	assert_eq(hq._view, hq.View.EXTERIOR, "menu_back leaves the garage for the exterior")


# The garage station has ONE framing now — the wide shell view. The low 3/4 hero shot
# that used to come with the "Drive" sub-level went with it, so entering Career or
# Garage must not re-pose the station camera behind the player's back.
func test_hq_garage_has_a_single_station_framing() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	var wide: Transform3D = hq._station_xform(hq.View.GARAGE)
	assert_true(is_instance_valid(hq._lift_car), "setup: a car stands on the lift")
	# Walk the row: no stop may change what the GARAGE station's framing is.
	for i in hq._garage_cursor.buttons.size():
		hq._garage_focus = i
		assert_eq(hq._station_xform(hq.View.GARAGE).origin, wide.origin,
			"the garage framing is the same wherever the cursor sits")


# The map table deliberately KEEPS the car standing on the lift (every other station
# away from the garage clears it). The table never shows the lift, but the teardown
# landed in the frame the camera starts its flight to the table — and the car park /
# title lineup, which DO borrow that node out of _car_cache, still get it handed back.
func test_opening_the_map_keeps_the_lift_car_but_the_car_park_still_gets_it_back() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	assert_true(is_instance_valid(hq._lift_car), "the garage stands the selected car on the lift")
	var on_lift: Node3D = hq._lift_car

	hq._table_ui._enter_table()
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.TABLE, "Career opens the map")
	assert_true(is_instance_valid(hq._lift_car), "the lift car is NOT torn down for the map")
	assert_eq(hq._lift_car, on_lift, "it is the same prop, not a respawn")
	assert_true(on_lift.visible, "and it is left standing, not hidden and stowed")

	# Back to the garage and out to the title: the title parks the collection, which
	# borrows the cached node, so the lift must have released it.
	hq.go_to(hq.View.GARAGE)
	hq.go_to(hq.View.EXTERIOR)
	assert_null(hq._lift_car, "leaving for a station that parks cars still clears the lift")


# --- Rally Challenge entry point (spec §7) -----------------------------------

# The garage row's Online button (renamed from Challenge) opens a modal,
# keyboard/gamepad-navigable entry screen over the garage, and Back closes it back
# to the garage. Online is the LAST stop on the row (the proceeding action).
# The challenge screen must NOT resize as the player switches Daily / Weekly / Monthly. Each
# kind has a different amount to say, and MenuPage's body box hugs its contents by default —
# so without a pinned size the panel re-fits on every tab press and jumps around under the
# player, moving the very tabs being clicked. Pinned via set_body_width/set_body_fixed_height
# in build_challenge_overlay.
func test_hq_challenge_screen_keeps_one_size_across_the_kind_tabs() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._challenge_ui._open_challenge_overlay()
	await get_tree().process_frame
	await get_tree().process_frame

	var page: MenuPage = null
	for child in hq._challenge_layer.find_children("*", "MenuPage", true, false):
		page = child
	assert_not_null(page, "the challenge screen is built on the shared MenuPage shape")
	var box := page.panel()

	var sizes: Array = []
	for kind in [ChallengeLibrary.DAILY, ChallengeLibrary.WEEKLY, ChallengeLibrary.MONTHLY]:
		hq._challenge_kind = kind
		hq._challenge_ui._refresh_challenge_overlay()
		await get_tree().process_frame
		await get_tree().process_frame
		sizes.append(box.size)

	for i in range(1, sizes.size()):
		assert_almost_eq(sizes[i].x, sizes[0].x, 1.0,
			"the panel keeps its width when the kind changes (%s vs %s)" % [sizes[i], sizes[0]])
		assert_almost_eq(sizes[i].y, sizes[0].y, 1.0,
			"the panel keeps its height when the kind changes (%s vs %s)" % [sizes[i], sizes[0]])
	assert_gt(sizes[0].x, 0.0, "sanity: the panel actually laid out")
	assert_gt(sizes[0].y, 0.0, "sanity: the panel actually laid out")


# The two headline strings must each read as ONE line at the CURRENT UI scale. Both the box
# (set_body_width / set_body_fixed_height) and the fonts inside it are authored sizes inflated
# by UITheme.UI_SCALE — but the box's numbers were left as raw logical pixels, so when the UI
# was rescaled the text grew and its container did not and the header broke across lines.
# Asserts the RELATION (the title and the ceiling subtitle fit on one line, whatever the kind),
# so it survives a retune of the box, the type scale or the strings themselves.
func test_hq_challenge_header_never_breaks_across_lines() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._challenge_ui._open_challenge_overlay()
	await get_tree().process_frame
	await get_tree().process_frame

	for kind in [ChallengeLibrary.DAILY, ChallengeLibrary.WEEKLY, ChallengeLibrary.MONTHLY]:
		hq._challenge_kind = kind
		hq._challenge_ui._refresh_challenge_overlay()
		await get_tree().process_frame
		await get_tree().process_frame
		var title: Label = hq._challenge_title_label
		var subtitle: Label = hq._challenge_subtitle_label
		assert_false(title.text.is_empty(), "sanity: the %s title says something" % kind)
		assert_eq(title.get_line_count(), 1,
			"the %s challenge title renders on one line (%s)" % [kind, title.text])
		# The ceiling subtitle is empty for a kind that sets no rating ceiling; only a
		# populated one has a line count to check.
		if not subtitle.text.is_empty():
			assert_eq(subtitle.get_line_count(), 1,
				"the %s ceiling subtitle renders on one line (%s)" % [kind, subtitle.text])


func test_hq_challenge_entry_opens_and_is_navigable() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	assert_false(hq._challenge_layer.visible, "the challenge overlay starts hidden")

	# Find Online by TEXT, not by position — the row has grown before (Multiplayer
	# was appended after it) and a positional pick silently opens the wrong screen.
	var online_idx := -1
	for i: int in range(hq._garage_cursor.buttons.size()):
		if String((hq._garage_cursor.buttons[i] as Button).text).to_lower() == "online":
			online_idx = i
			break
	assert_true(online_idx >= 0, "the garage row still carries an Online button")
	hq._garage_focus = online_idx
	hq._activate_garage_focus()
	assert_true(hq._challenge_layer.visible, "Online on the garage row opens the entry screen")
	assert_false(hq._garage_layer.visible, "the garage hides behind the modal challenge overlay")

	await get_tree().process_frame  # deferred MenuNav focus grab
	var focused := hq.get_viewport().gui_get_focus_owner()
	assert_true(focused is Button and hq._challenge_layer.is_ancestor_of(focused),
		"the cursor lands on one of the challenge screen's own buttons")

	# Back (via the screen's own MenuNav, wired with on_back = _close_challenge_overlay)
	# closes the modal and returns to the garage.
	# Found by SEARCHING the layer, not by child index: the overlay's node order is not a
	# contract (it used to carry a full-rect MODAL_DIM backing as child 0, which went away
	# when the page moved to MenuPage — whose body box hugs its contents, so a full-screen
	# backing would have painted over the garage it is meant to float above).
	var nav: MenuNav = null
	for child in hq._challenge_layer.find_children("*", "MenuNav", true, false):
		nav = child
	assert_not_null(nav, "the challenge screen has MenuNav attached")
	nav._unhandled_input(_press("menu_back"))
	assert_false(hq._challenge_layer.visible, "menu_back closes the challenge overlay")
	assert_true(hq._garage_layer.visible, "closing the overlay restores the garage")


# The kind tabs are real FOCUS_ALL controls reachable by native left/right
# focus-neighbour movement (menu_nav.gd), and arriving via focus IS the selection
# (focus_entered). Opening the screen lands focus on the CURRENT kind's own tab.
#
# CHANGED DELIBERATELY: these used to assert `mouse_filter == MOUSE_FILTER_IGNORE`,
# i.e. that a pointer could never touch a tab. That left a phone with no way at all to
# change kind — the tabs are the only control that picks one, and menu_left/menu_right
# are keyboard/gamepad-only actions. They are hit-testable now; what must still hold is
# that a pointer press SELECTS ONLY and never starts the run (see the next test).
func test_hq_challenge_kind_tabs_are_focusable_and_left_right_navigable() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	hq._challenge_ui._open_challenge_overlay()
	assert_eq(hq._challenge_kind, ChallengeLibrary.DAILY, "opens on Daily by default")

	for btn in hq._challenge_kind_buttons:
		assert_ne(btn.mouse_filter, Control.MOUSE_FILTER_IGNORE,
			"a kind tab must be hit-testable, or touch players cannot change kind at all")
		assert_eq(btn.focus_mode, Control.FOCUS_ALL, "and still reachable by keyboard/gamepad")
		assert_false(btn.toggle_mode, "no press/pressed state — focus_entered is the selection")

	await get_tree().process_frame  # deferred focus grab from _open_challenge_overlay
	assert_eq(hq.get_viewport().gui_get_focus_owner(), hq._challenge_ui._challenge_kind_button(ChallengeLibrary.DAILY),
		"opening the screen focuses the current kind's own tab")

	# Drive REAL focus-neighbour navigation through MenuNav's own _unhandled_input (the
	# same path a keyboard/gamepad press takes in the real game), not a direct call into
	# hq — there is no hq-level interception of menu_left/menu_right anymore.
	# Searched, not indexed — see the sibling test: the overlay's child order is not a
	# contract.
	var nav: MenuNav = null
	for child in hq._challenge_layer.find_children("*", "MenuNav", true, false):
		nav = child
	assert_not_null(nav, "the challenge screen has MenuNav attached")

	nav._unhandled_input(_press("menu_right"))
	assert_eq(hq._challenge_kind, ChallengeLibrary.WEEKLY, "menu_right moves focus onto the Weekly tab")
	assert_string_contains(hq._challenge_title_label.text.to_upper(), "WEEKLY",
		"the header title tracks the switch")

	nav._unhandled_input(_press("menu_right"))
	assert_eq(hq._challenge_kind, ChallengeLibrary.MONTHLY, "menu_right again reaches Monthly")

	nav._unhandled_input(_press("menu_left"))
	assert_eq(hq._challenge_kind, ChallengeLibrary.WEEKLY, "menu_left moves back to Weekly")


# Enter/gamepad-accept on a focused kind TAB acts as Start (not just on the Start
# button itself) — the player shouldn't have to tab down once they've picked a kind.
func test_hq_challenge_tab_activate_starts_like_the_start_button() -> void:
	_reset_to_first_run()
	_install_guaranteed_eligible_car()
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	hq._challenge_ui._open_challenge_overlay()
	hq._challenge_ui._select_challenge_kind(ChallengeLibrary.DAILY)
	assert_false(hq._challenge_start_button.disabled, "setup: Start is enabled with an eligible car")

	hq._challenge_ui._challenge_kind_button(ChallengeLibrary.DAILY).grab_focus()
	hq._challenge_ui._challenge_kind_button(ChallengeLibrary.DAILY).pressed.emit()
	await get_tree().process_frame
	assert_false(hq._challenge_layer.visible,
		"activating the focused tab committed Start, same as pressing the Start button")


# The SAME activation must respect Start's disabled gate — no eligible car means
# Enter-on-a-tab must not silently start anyway.
func test_hq_challenge_tab_activate_respects_disabled_start() -> void:
	_reset_to_first_run()  # empty garage: no owned car can possibly be eligible
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	hq._challenge_ui._open_challenge_overlay()
	assert_true(hq._challenge_start_button.disabled, "setup: Start is disabled with no eligible car")

	hq._challenge_ui._challenge_kind_button(ChallengeLibrary.DAILY).pressed.emit()
	await get_tree().process_frame
	assert_true(hq._challenge_layer.visible,
		"activating a tab while Start is disabled must not start anything")


# The four concise sections all repaint from ChallengeSession/ChallengeLibrary's
# current state for whichever kind is selected: the subtitle (ceiling)/win
# condition/win reward always show SOME text, and the eligible-cars section responds
# to the period's rolled ceiling — not a fixed list — for every kind.
func test_hq_challenge_sections_reflect_the_current_kind_and_ceiling() -> void:
	_save.grant_car("fx_fwd_hatch")
	_save.grant_car("fx_rwd_coupe")
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	hq._challenge_ui._open_challenge_overlay()

	var unix_time := int(Time.get_unix_time_from_system())
	for kind_str in [ChallengeLibrary.DAILY, ChallengeLibrary.WEEKLY, ChallengeLibrary.MONTHLY]:
		hq._challenge_ui._select_challenge_kind(kind_str)
		# UITheme.enforce upper-cases every label (house style), so compare case-insensitively.
		assert_string_contains(hq._challenge_title_label.text.to_upper(), kind_str.to_upper(),
			"the header title names the current kind")
		assert_false(hq._challenge_subtitle_label.text.is_empty(),
			"the subtitle always shows the rolled ceiling")
		assert_false(hq._challenge_win_label.text.is_empty(), "win condition is always shown")
		assert_false(hq._challenge_reward_label.text.is_empty(), "win reward is always shown")
		@warning_ignore("static_called_on_instance")
		var expected := ChallengeSession.eligible_cars(kind_str, Save.profile, unix_time)
		if expected.is_empty():
			assert_string_contains(hq._challenge_eligible_label.text.to_lower(), "no eligible car",
				"the %s tab explains why Start is blocked" % kind_str)
		else:
			assert_false(hq._challenge_eligible_label.text.is_empty(),
				"the %s tab names the eligible car(s)" % kind_str)


# Zero eligible owned cars blocks starting outright: no loaner car, no forced
# auto-detune (spec §2) — the eligible-cars section explains why and Start is disabled.
func test_hq_challenge_blocks_start_with_no_eligible_car() -> void:
	_reset_to_first_run()  # empty garage: no owned car can possibly be eligible
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	hq._challenge_ui._open_challenge_overlay()

	assert_string_contains(hq._challenge_eligible_label.text.to_lower(), "no eligible car",
		"the eligible-cars section explains why Start is blocked")
	assert_true(hq._challenge_start_button.disabled, "Start is blocked with no eligible car")


# A car so far below every entry of ChallengeLibrary.CEILING_BAND_HP_TONNE (the lowest
# is 120 hp/tonne) that it qualifies for every kind no matter which band value that
# day's roll happens to land on — CarFixtures' own cars sit close enough to the band
# that whether they qualify depends on the roll, which would make this test flaky by
# the calendar date it runs on. Appends onto the already-installed CarFixtures roster
# (restored the same way in after_each) rather than replacing it.
func _install_guaranteed_eligible_car() -> Dictionary:
	var cars := CarFixtures.cars()
	var heavy := CarFixtures.cars()[0].duplicate(true)
	heavy["id"] = "fx_challenge_eligible"
	heavy["name"] = "Fixture Challenge Eligible"
	heavy["mass"] = 6000.0  # crushes power-to-weight far under the lowest band value
	cars.append(heavy)
	CarLibrary.override_for_test(cars)
	return _save.grant_car("fx_challenge_eligible")


# The flip side: a car so far ABOVE every value the rating band can roll that it is over
# the ceiling whichever one comes up — the car ChallengeSession.classify_car marks
# EXCLUDED, so it never reaches the challenge car park at all.
func _install_guaranteed_over_ceiling_car() -> Dictionary:
	var cars := CarFixtures.cars()
	var hot := CarFixtures.cars()[2].duplicate(true)  # fx_rwd_coupe (the fx_v8 engine)
	hot["id"] = "fx_challenge_over_ceiling"
	hot["name"] = "Fixture Challenge Over Ceiling"
	hot["mass"] = 300.0  # a featherweight V8: rated far OVER the highest band value
	cars.append(hot)
	CarLibrary.override_for_test(cars)
	return _save.grant_car("fx_challenge_over_ceiling")


# Start/Resume switches on ChallengeSession.resumable_run: a fresh entry shows "Start" and
# OPENS THE REAL CAR PARK restricted to this kind's eligible cars (spec §7 point 4) rather
# than committing straight from a focused list item; committing the car park's own Start
# begins the run. Once that run is persisted, reopening the same kind's entry screen shows
# "Resume" instead, and pressing it resumes directly (no car to pick) rather than restarting.
func test_hq_challenge_start_opens_carpark_then_resume() -> void:
	# _reset_to_first_run + the guaranteed-eligible fixture: the default starter car
	# (before_each's _pick_starter) sits ABOVE today's lowest ceiling band and would
	# also show up eligible-with-a-note (spec §2/§7 point 4) — sidestep that here by
	# starting from an empty garage so the fixture is the ONLY eligible car, and Start
	# in the car park commits it cleanly with no over-ceiling agreement in the way.
	_reset_to_first_run()
	var owned := _install_guaranteed_eligible_car()
	var id := int(owned["instance_id"])
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	hq._challenge_ui._open_challenge_overlay()
	hq._challenge_ui._select_challenge_kind(ChallengeLibrary.DAILY)
	assert_eq(hq._challenge_start_button.text.to_upper(), "START", "no stored run yet: the button reads Start")
	assert_false(hq._challenge_start_button.disabled, "Start is enabled with an eligible car")
	assert_string_contains(hq._challenge_progress_label.text.to_lower(), "not started",
		"with no stored run the progress row reads Not started")

	hq._challenge_ui._on_challenge_start_pressed()
	await get_tree().process_frame
	assert_eq(hq._carpark_mode, hq.CarparkMode.CHALLENGE, "Start opens the challenge car park, not a direct commit")
	assert_false(hq._challenge_layer.visible, "opening the car park closes the entry overlay")
	assert_eq(hq._eligible.size(), 1, "the fixture car is the ONLY one parked in the REAL car-park lineup")
	assert_eq(int(hq._eligible[0].get("instance_id", -1)), id, "it's the fixture car that's focused/parked")
	assert_false(ChallengeSession.is_active(), "no run has begun yet — only the picker opened")

	# Committing the focused car in the car park is what actually begins the run.
	hq._on_start_pressed()
	assert_true(ChallengeSession.is_active(), "committing the car park begins a ChallengeSession run")
	assert_eq(ChallengeSession.kind(), ChallengeLibrary.DAILY, "the run is for the selected kind")

	# Reopening the same kind's entry now offers Resume, since a run is stored for it.
	hq.go_to(hq.View.GARAGE)
	hq._challenge_ui._open_challenge_overlay()
	hq._challenge_ui._select_challenge_kind(ChallengeLibrary.DAILY)
	assert_eq(hq._challenge_start_button.text.to_upper(), "RESUME",
		"a stored run for the current kind shows Resume instead of Start")
	# A live run must SAY it's live — a bare "0 / N stages" reads the same as not
	# started, and gives no hint that this kind is holding a car locked out of the
	# other pickers. Stage counts come from the session (a tunable per kind), never
	# pinned to a literal here.
	var progress: String = hq._challenge_progress_label.text.to_upper()
	assert_string_contains(progress, "IN PROGRESS",
		"a resumable run marks the progress row as in progress")
	assert_string_contains(progress, "%d/%d STAGES" % [
		ChallengeSession.events_completed(), ChallengeSession.stage_count()],
		"the progress row reports completed/total stages for the active run")
	# The car is already committed and locked, so the eligible row must name THAT car
	# alone — not the wider eligible set, which would imply a choice that no longer
	# exists. Derived from the committed instance, never a hardcoded model name.
	var locked_car: Dictionary = Save.get_car(ChallengeSession.car_instance_id())
	var locked_name: String = EngineSwap.display_name(
		CarLibrary.by_id(String(locked_car.get("model_id", ""))), locked_car)
	# Compared upper-cased: UITheme.enforce applies the house uppercase styling to
	# the rendered label, so the raw text is not the raw display name.
	assert_eq(hq._challenge_eligible_label.text.to_upper(), locked_name.to_upper(),
		"a run in progress shows only the locked car it was started with")

	hq._challenge_ui._on_challenge_start_pressed()
	assert_true(ChallengeSession.is_active(), "Resume keeps the same run active — no car park involved")


# An over-ceiling car is simply EXCLUDED from the challenge car park. There is no detune
# escape any more (the rating design doc's D5): the ceiling is a CarPerformance rating,
# over it means out, and the player brings or builds another car. The park showing it as
# an enterable option with a "too powerful" prompt behind Start was the old p/w-band
# behaviour and is gone with it.
func test_hq_challenge_carpark_excludes_an_over_ceiling_car() -> void:
	# Start from an empty garage so the ONLY owned car is the over-ceiling fixture —
	# otherwise the default starter would fill the park and the emptiness assertion below
	# would say nothing about the car under test.
	_reset_to_first_run()
	_save.profile["cars"] = []
	_install_guaranteed_over_ceiling_car()
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	hq._challenge_ui._enter_challenge_car_screen(ChallengeLibrary.DAILY)
	await get_tree().process_frame

	assert_eq(hq._eligible.size(), 0, "an over-ceiling car does not park — it cannot enter")
	assert_false(ChallengeSession.is_active(), "and no run began")


# Free roam (Test Drive) launches a plain drive: no rally session, and a fresh random seed each
# entry (so the track differs every time), with neutral terrain settings.
func test_hq_free_roam_prepares_a_fresh_unseeded_run() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()

	hq._prepare_free_roam()
	assert_false(RallySession.is_active(),
		"free roam runs with no active rally session (world fields the picked car)")
	var first_seed: int = Config.data.track_seed
	# A second preparation re-rolls the seed — a different track on the next entry.
	# (randi() collisions are astronomically unlikely, so a mismatch is a safe assert.)
	hq._prepare_free_roam()
	assert_ne(Config.data.track_seed, first_seed, "free roam re-seeds the track on every entry")


# Free roam rolls a random lake depth, large-scale relief, and region each entry —
# every roll must land inside the configured bands / the real region roster.
func test_hq_free_roam_randomises_water_relief_and_location() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	for _i in 20:
		hq._prepare_free_roam()
		assert_between(Config.data.track_water_level_m,
			Config.data.free_roam_water_level_min_m, Config.data.free_roam_water_level_max_m,
			"free-roam water level stays inside the configured band")
		assert_between(Config.data.terrain_layer1_amplitude,
			Config.data.free_roam_relief_min, Config.data.free_roam_relief_max,
			"free-roam layer-1 amplitude stays inside the configured band")
		assert_true(RegionLibrary.index_of(RallySession.free_roam_region_id) >= 0,
			"free-roam location is a real RegionLibrary region")


# The garage "Garage" button goes STRAIGHT into the tuning lift bay for the selected car.
# It used to open the car park first to pick a car; the lift's own selector chevrons change
# the car in place now (test_hq_lift_selector_cycles_the_car_on_the_lift), so that
# intermediate pick was a press in and a press back on the way to the only screen anyone
# wanted. Back from the bay returns to the garage.
func test_hq_garage_button_goes_straight_to_the_tuning_bay() -> void:
	_save.grant_car("fx_fwd_hatch")  # a second car so the collection isn't just the starter
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame

	hq._enter_lift()
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.LIFT, "Garage opens the tuning lift bay with no car pick first")
	assert_eq(hq._lift_page, hq.LiftPage.HUB, "it lands on the hub")
	assert_eq(hq._lift_car_instance_id, _save.selected_instance_id(),
		"the car on the lift is the currently selected one")

	# The bay's own Back returns to the garage.
	hq.go_to(hq.View.GARAGE)
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.GARAGE, "Back from the bay returns to the garage")


# The run scene fields the owned car the player picked for free roam, with no active
# rally session (world.gd's free-roam branch).
func test_free_roam_fields_the_picked_owned_car() -> void:
	var owned: Dictionary = _save.grant_car("fx_fwd_hatch")
	var id := int(owned["instance_id"])
	RallySession.free_roam_instance_id = id
	assert_false(RallySession.is_active(), "free roam runs with no active session")
	SceneHelpers.minimal_world()
	var scene: Node3D = load("res://main.tscn").instantiate()
	add_child_autofree(scene)
	await get_tree().process_frame
	var car: VehicleBody3D = scene.get_node("Car")
	assert_eq(car.damage.instance_id, id, "free roam fields the picked owned-car instance")
	# Don't leak the pick into later tests.
	RallySession.free_roam_instance_id = -1


# Finishing the track in free roam has no session to report to; the finish panel's
# Next must still DO something — it returns to HQ (not silently no-op). Drives the
# REAL signal chain (stage_completed → world's handler), not the handler directly:
# the wiring itself once only existed for session runs, which is exactly the bug.
func test_free_roam_finish_next_returns_to_hq() -> void:
	var owned: Dictionary = _save.grant_car("fx_fwd_hatch")
	RallySession.free_roam_instance_id = int(owned["instance_id"])
	SceneHelpers.minimal_world()
	var scene: Node3D = load("res://main.tscn").instantiate()
	add_child_autofree(scene)
	await get_tree().process_frame
	var requested: Array = [""]
	scene.scene_change_hook = func(path: String) -> void: requested[0] = path
	# The finish emits stage_completed (proceed_to_results); world must have it
	# connected even with no session — that connection is what routes Next to HQ.
	scene._stage_manager.stage_completed.emit(12.0)
	# Scenes.hub_path(), not the literal: which scene IS the hub is now a flag
	# (GameConfig.overworld_enabled), and asserting the literal makes this test fail the moment a
	# developer flips it. The behaviour under test is "Next routes to the hub", not "the hub is
	# hq.tscn" — that second fact belongs to Scenes and is tested there.
	assert_eq(String(requested[0]), Scenes.hub_path(),
		"the free-roam finish panel's Next returns to the hub")
	RallySession.free_roam_instance_id = -1


# A rival who crashed out of THIS event is staged by the roadside: their ACTUAL car
# frozen as a solid obstacle (hitbox kept), lazy engine smoke, and a small standing
# crowd around it (features/opponent-wrecks.md). Drives the real world build with an
# active session whose field wrecks one rival in event 0.
func test_run_scene_stages_a_roadside_opponent_wreck() -> void:
	var owned: Dictionary = _save.grant_car("fx_light_rwd")
	RallySession.start_rally(RallyLibrary.by_id("fx_open"), owned, true)
	# Overwrite the field so a known rival (in a resolvable fixture car) wrecks event 0.
	RallySession._opponent_field = [
		{"name": "A", "car_id": "fx_rwd_coupe", "car_name": "Fixture Coupe",
			"event_times_ms": [50000, 0, 0], "dnf": false, "combined_ms": 1,
			"wreck_event": -1, "wreck_progress": 0.0, "wreck_side": 1.0},
		{"name": "B", "car_id": "fx_fwd_hatch", "car_name": "Fixture Hatch",
			"event_times_ms": [-1, -1, -1], "dnf": true, "combined_ms": -1,
			"wreck_event": 0, "wreck_progress": 0.5, "wreck_side": 1.0},
	]
	SceneHelpers.minimal_world()
	Config.data.start_line_enabled = false  # skip the start-line staging; just build the world
	var scene: Node3D = load("res://main.tscn").instantiate()
	add_child_autofree(scene)
	await get_tree().process_frame
	var wreck := scene.get_node_or_null("OpponentWreck")
	assert_not_null(wreck, "a crashed rival is staged by the roadside")
	if wreck == null:
		return
	# The staged car is the ACTUAL car the crashed rival drove, frozen (its hitbox kept)
	# so it's a solid obstacle that won't be shoved.
	var car: VehicleBody3D = wreck.find_children("*", "VehicleBody3D", true, false)[0]
	assert_true(car.freeze, "the wreck is frozen")
	assert_eq(car.freeze_mode, RigidBody3D.FREEZE_MODE_STATIC,
		"frozen static, so the collider stays a solid immovable obstacle")
	# It's placed ANALYTICALLY (car.gd:settled_ride_height) and frozen at once — no live
	# settle — so it rests with wheels on the ground, never sunk through the un-streamed
	# verge nor floating. Its body sits ~one ride-height above the terrain under it.
	var terrain := scene.get_node_or_null("Floor")
	var ground: float = terrain.height_at(car.global_position.x, car.global_position.z)
	# The wreck is seated on the HIGHEST ground under its footprint (world.gd
	# _flattest_wreck_spot → top_y), so on a slope it legitimately sits somewhat above
	# the single centre sample. Assert the behaviour that must hold for ANY terrain
	# seed (the per-event terrain seed varies the verge slope): wheels on the ground
	# (not sunk) and not floating absurdly high — rather than pinning an exact gap
	# that only held for the old fixed terrain.
	var gap := car.global_position.y - ground
	assert_between(gap, car.settled_ride_height() - 0.1, car.settled_ride_height() + 1.0,
		"wreck rests on the verge — wheels down, not sunk, not floating (slope-tolerant)")
	# A small crowd of onlookers gathered around it.
	var crowd := wreck.get_node_or_null("WreckCrowd") as MultiMeshInstance3D
	assert_not_null(crowd, "a crowd gathers around the wreck")
	assert_gt(crowd.multimesh.instance_count, 0, "the crowd is populated")
	# And it smokes like a damaged HQ car (a synthetic-smoke pool parented to it).
	assert_gt(car.find_children("*", "EngineSmoke", true, false).size(), 0,
		"the wreck puffs engine smoke")


# The HQ clearing is dressed like a stage verge: the framing tree ring is joined by
# an interleaved bush ring and spectators spread around the clearing (pure scenery —
# no steering; there is no car in HQ to react to). Spectators stand on the grass,
# never on the concrete apron.
func test_hq_has_bush_and_spectator_scenery() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	# The tree field is billboard OR mesh (per config); the bush field is always
	# a 3D TreeMeshField.
	assert_not_null(hq.get_node_or_null("HQTrees"), "the HQ tree ring field exists")
	var bushes: TreeMeshField = hq.get_node_or_null("HQBushes")
	assert_not_null(bushes, "the HQ scatters a bush field alongside the trees")
	assert_gt(bushes.instance_positions.size(), 0, "the bush field is populated")
	# Scale contract (same guard as the podium): the HQ bush field is normalized by the
	# shared Foliage routine + config, never left at native GLB size. Pins the routing,
	# not the tunable height — retuning cfg.bush_height_m moves both sides together.
	var expect := TreeMeshField.uniform_scale_for(Foliage.bush_mesh(), Config.data.bush_height_m)
	assert_almost_eq(bushes.instance_scale, expect, 0.0001,
		"HQ bushes use the shared Foliage scale normalization, not native size")
	var crowd := hq.get_node_or_null("HQSpectators") as MultiMeshInstance3D
	assert_not_null(crowd, "spectators stand around the lot")
	assert_gt(crowd.multimesh.instance_count, 0, "the spectator scatter is populated")
	# All of them keep off the tarmac (the concrete apron the cars park on). The
	# scatter is read from meta — headless MultiMesh buffers can't be read back.
	var cfg: GameConfig = Config.data
	var half := cfg.hq_concrete_size * 0.5
	var positions: PackedVector2Array = crowd.get_meta("positions")
	assert_eq(positions.size(), crowd.multimesh.instance_count, "one instance per scattered spectator")
	for p in positions:
		assert_true(absf(p.x - cfg.hq_concrete_center.x) > half.x
			or absf(p.y - cfg.hq_concrete_center.z) > half.y,
			"spectators stand beyond the tarmac (%s)" % p)


func test_hq_opening_the_table_shows_the_map() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	hq._table_ui._enter_table()
	assert_eq(hq._view, hq.View.TABLE, "tapping the table drops the camera to the map view")
	assert_true(hq._table_layer.visible, "the map HUD is shown")
	# CHANGED DELIBERATELY (three times): the meter used to read "Progress to the Showdown" for
	# one region, then "N / M rallies completed" for the whole roster, then "Stars: N". It now
	# reports the star BALANCE as digits alone, beside a star polygon — the word was redundant
	# next to the glyph, and stars are what gate the special pins, so the table HUD and the
	# pins speak the same metric. Assert the number, and that the glyph is actually there.
	assert_eq(hq._map_meter.text, str(Save.stars_available()),
		"the meter shows the spendable star balance")
	assert_eq(hq._map_meter.get_parent().find_children("*", "StarRow", true, false).size(), 1,
		"a drawn star stands in for the word 'stars'")


# An unreached special still stands its trophy on the map — the fog fades it rather than
# deleting it. Locking must hide availability, never information: the player should be able
# to see what exists and roughly where, long before they can drive to it.
func test_hq_map_fogs_a_special_the_player_has_not_explored_out_to() -> void:
	# Needs the REAL reveal radius: before_each lights the whole map so the layout tests can
	# see their pins, and this test is about a rally being out in the dark.
	_dark_map_radius()
	# Needs a roster with a special that is genuinely NOT reachable from a fresh profile.
	# RallyFixtures' one special (fx_showdown) is deliberately parked inside HQ's lit
	# circle so it's open from the start (see rally_fixtures.gd) — there is no dark special
	# in that roster to assert against, so fall back to the shipped roster's shape here.
	# This depends on the roster's STRUCTURE (some special is unreached from a fresh
	# profile), never on any specific rally's identity or stats.
	RallyLibrary.reset()
	# EARN a lit frontier. Nothing is revealed on a fresh profile any more (see
	# _light_the_first_rally), so without this there is no open pin to contrast the dark special
	# against and the test would be asserting the fog against nothing.
	var lit_id := _light_the_first_rally()
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	# The special the map reaches LAST is certainly still dark, even with that frontier lit.
	var dark_pin := _pin_for(hq, _top_special_id())
	assert_not_null(dark_pin, "an unreached special is still on the map")
	assert_true(bool(dark_pin.get_meta("locked")), "and reads as locked")
	assert_eq(dark_pin.find_children("*", "Area3D", true, false).size(), 0,
		"with nothing pickable on it — look, don't touch")
	# The rally the player has completed is lit by its own circle — so the lock above is the fog
	# working, not the table failing to build every pin locked.
	var open_pin := _pin_for(hq, lit_id)
	assert_not_null(open_pin, "the completed rally is on the map")
	assert_false(bool(open_pin.get_meta("locked")), "and is lit by its own completion")


func test_hq_unavailable_ordinary_rally_fades_its_floating_readout() -> void:
	# ONE readout rule for every pin: the box is always built, always starts HIDDEN, and is
	# shown only while the cursor is on it — that is what keeps the table a map rather than a
	# noticeboard of a dozen open menus. What "can't enter this" changes is the OPACITY: a
	# rally out in the fog, or reachable but with nothing in the garage that fits, fades its
	# box, while an available one is full opacity. The 3D flag stands at both pins either way.
	#
	# Needs the REAL reveal radius: before_each lights the whole map, which would leave no
	# unavailable ordinary pin to look at and quietly turn this into a no-op.
	_dark_map_radius()
	# Falls back to the SHIPPED roster: the opening-rally seeding this leans on (a rally whose
	# prize_car is a starter model) is something RallyFixtures' roster does not model at all, so
	# over the fixtures there is no opening rally to complete. This depends on the roster's
	# STRUCTURE (an opening rally exists), never on any rally's identity or stats.
	RallyLibrary.reset()
	# Same reason as the fog test above: without a completed rally the whole map is dark, so
	# there would be no AVAILABLE pin to contrast the faded one against.
	_light_the_first_rally()
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var hidden := _unavailable_ordinary_pin(hq)
	if hidden == null:
		# Nothing on the lit map is out of the garage's reach right now — the case this test
		# describes simply is not present, so there is nothing to assert about it.
		return
	var shakedown := _available_pin(hq)
	if shakedown == null:
		# The contrast half is missing: the fixture garage holds no car that can enter anything
		# currently lit. Say so rather than asserting half a comparison.
		pending("no available pin in this fixture lineup — nothing to contrast the fade against")
		return
	assert_true(hidden.has_meta("label_panel"),
		"an unavailable rally still carries a panel for the focus cursor to paint")
	assert_lt(_pin_label_sprite(hidden).modulate.a, 1.0,
		"but its box is faded — a full-opacity menu would read as live")
	assert_eq(_pin_label_sprite(shakedown).modulate, Color.WHITE,
		"an available rally's box is at full opacity")
	for pin in [hidden, shakedown]:
		assert_gt((pin as Node3D).find_children("*", "MeshInstance3D", true, false).size(), 0,
			"the 3D flag is built for available and unavailable rallies alike")


# The id of the special the map reaches LAST — certain to be dark on a fresh profile,
# without pinning which rally that is. Reveal is geometric now, so "last" is the deepest
# reachability wave (RallyLibrary.reveal_depths), not the top authored rung.
func _top_special_id() -> String:
	var depth := RallyLibrary.reveal_depths()
	var best := ""
	var best_wave := -1
	for rally in RallyLibrary.all():
		var rid := String(rally["id"])
		if RallyLibrary.is_special(rally) and int(depth.get(rid, -1)) > best_wave:
			best_wave = int(depth.get(rid, -1))
			best = rid
	return best


# Some pin the map currently renders as AVAILABLE — revealed AND with a car in the garage that can
# enter it. Read from the same two predicates the map itself uses (the `locked` meta, set from
# RallyLibrary.rally_revealed, and _has_eligible_car), so it cannot drift from what the pin shows.
#
# NOT derived from RallyLibrary.reveal_depths(). A rally's reveal DEPTH is which wave of progress
# would reach it — depth 1 means "its prize is a starter car", not "it is lit right now". These
# tests used to conflate the two, and it broke the moment HQ's circle stopped touching any pin.
func _available_pin(hq: Node3D) -> Node3D:
	for pin in hq._pins:
		var rally := RallyLibrary.by_id(String(pin.get_meta("rally_id")))
		if not bool(pin.get_meta("locked")) and hq._has_eligible_car(rally):
			return pin
	return null


# Complete the deepest-seeded opening rally so the map has a LIT FRONTIER, and return its id.
#
# On a fresh profile with the real radii NOTHING is revealed: `map_hq_reveal_radius` ships
# deliberately too small to touch any shipped pin (see the comment on RallyLibrary.lit_sources,
# pinned by test_the_hq_circle_alone_reveals_no_rally). Progress is therefore the ONLY thing that
# lights the map, so a test that needs an open pin has to earn one. Completing a rally lights a
# circle centred on that rally, so the rally itself is revealed.
func _light_the_first_rally() -> String:
	var depth := RallyLibrary.reveal_depths()
	for rally in RallyLibrary.all():
		if int(depth.get(String(rally["id"]), 1 << 30)) == 1:
			var rid := String(rally["id"])
			_save.record_podium_rally(rid, 60000, 1)
			return rid
	return ""


# Some ORDINARY rally pin that is currently locked, or null if none is.
func _unavailable_ordinary_pin(hq: Node3D) -> Node3D:
	for pin in hq._pins:
		var rally := RallyLibrary.by_id(String(pin.get_meta("rally_id")))
		# Either out in the fog or revealed with nothing in the garage that can enter it —
		# both render the same way, which is the point of the test that uses this.
		if not RallyLibrary.is_special(rally) and not hq._has_eligible_car(rally):
			return pin
	return null


# The garage's next-carrot line (a readout naming the nearest locked special) is GONE, so
# the three tests that guarded its text, its reward subtitle and its hide-when-nothing-left
# behaviour went with it. What the garage station DOES carry is asserted by
# test_hq_garage_is_a_left_right_cursor — the action row, and nothing else over the room.


func test_hq_pins_stars_reflect_best_placement() -> void:
	# The pin shows what the rally's BEST placement rates, through the one scoring curve — a
	# podium best rates the maximum, a non-podium finish rates less but not nothing, and an
	# unplayed rally rates nothing.
	var podium_stars := RallyLibrary.stars_for_placement(1)
	var finish_stars := RallyLibrary.stars_for_placement(RallyLibrary.PODIUM_PLACES + 1)
	_save.record_podium_rally("fx_open", 60000, 1)
	_save.record_podium_rally("fx_fwd_band", 90000, RallyLibrary.PODIUM_PLACES + 1)
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	assert_eq(hq._stars_for("fx_open"), podium_stars, "a podium best rates the full count")
	assert_eq(hq._stars_for("fx_fwd_band"), finish_stars, "a finish rates less, but not zero")
	assert_gt(podium_stars, finish_stars, "and the podium really does rate more")
	assert_eq(hq._stars_for("fx_rwd_band"), 0, "an unplayed rally earns 0 stars")
	# The readout box on the pin is the design-system black panel (a Sprite3D) carrying
	# a StarRow lit to the earned count — and no leftover 3D sphere "stars".
	var pin := _pin_for(hq, "fx_open")
	assert_gt(pin.find_children("*", "Sprite3D", true, false).size(), 0,
		"the pin carries a billboarded readout box (Sprite3D)")
	var rows := pin.find_children("*", "StarRow", true, false)
	assert_eq(rows.size(), 1, "the readout box holds one StarRow")
	assert_eq((rows[0] as StarRow).earned, podium_stars,
		"the StarRow is lit to the earned star count")
	assert_eq((rows[0] as StarRow).total, hq.MAX_STARS, "out of MAX_STARS stars")


func test_hq_tapping_a_pin_opens_its_detail() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	hq._table_ui._enter_table()
	# Tapping CENTRES the camera on the pin and only then opens the panel, so the detail
	# lands one camera glide later — await the handler rather than reading _detail_open
	# before the glide it deliberately waits out.
	await hq._table_ui._on_rally_pin("fx_rwd_band")
	assert_true(hq._detail_open, "tapping a pin opens the rally detail")
	assert_true(hq._detail_layer.visible, "the detail overlay is shown")
	assert_false(hq._table_layer.visible, "the map HUD is hidden behind the detail")
	# Name and stage count both ride on the title (there is no per-stage column); derive both
	# from the rally itself so renaming or retuning the roster can't break this.
	var rally: Dictionary = RallyLibrary.by_id("fx_rwd_band")
	assert_string_contains(hq._detail_title.text, String(rally.get("name", "")).to_upper(),
		"the detail names the rally")
	var stages: int = (rally.get("events", []) as Array).size()
	assert_string_contains(hq._detail_title.text, "%d STAGE" % stages,
		"the title carries the rally's stage count")
	# Derive the expected restriction text the same way the detail panel does (rather than
	# pinning an authored string like "RWD CARS"), so retuning the fixture's restriction
	# can't break this.
	assert_string_contains(hq._detail_restriction.text,
		hq._restriction_text(rally["restriction"]).to_upper(),
		"the detail spells out the eligibility")


func test_hq_table_drag_pans_and_clamps() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._table_ui._enter_table()
	# Entry now steers the camera onto the hardest incomplete pin (see the
	# dedicated test below), so zero the pan first to isolate drag behaviour.
	hq._table_pan = Vector3.ZERO
	var before_x: float = hq._table_pan.x
	hq._pan_table(Vector2(-100, -50))
	assert_gt(hq._table_pan.x, before_x, "dragging pans the map view")
	# A huge drag clamps to the map extents (half the plane each way). This also covers the
	# off-screen case: the ray through a point 100000px away tilts above the horizon and
	# never meets the map plane, so the delta is sampled near the pointer and scaled.
	hq._pan_table(Vector2(-100000, -100000))
	var cfg: GameConfig = Config.data
	assert_almost_eq(hq._table_pan.x, cfg.hq_map_plane_size.x * 0.5, 0.001, "pan clamps to the map's far X edge")
	assert_almost_eq(hq._table_pan.z, cfg.hq_map_plane_size.y * 0.5, 0.001, "pan clamps to the map's far Z edge")


# THE contract for map dragging: whatever map point you grabbed stays under the pointer.
# FINDING: the pan used to be pixels x a fixed metres-per-pixel constant (hq_table_pan_speed
# = 0.012), which for the shipped table camera / 360px-tall viewport was over 2x the real
# scale — so the map raced ahead of the finger and a pin you started the drag beside was
# nowhere near it when you let go. Measuring the delta on the map plane makes it exact, and
# this test fails on any reintroduced constant because it compares world points, not pixels.
func test_hq_dragging_the_map_keeps_the_grabbed_point_under_the_pointer() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._table_ui._enter_table()
	# Entry eases the camera onto a pin over menu_camera_move_time; zero the pan and snap
	# there so the drag is measured against a SETTLED table view, not a half-finished tween.
	hq._table_pan = Vector3.ZERO
	hq._move_camera_to(hq._station_xform(hq.View.TABLE), true)
	# Track a real point on the map (the plane's own centre) through the camera's FORWARD
	# projection — unproject_position, not the ray/plane maths the pan itself uses, so this
	# can't pass by agreeing with the code under test.
	var mark: Vector3 = hq._map_plane.global_position
	var before: Vector2 = hq._camera.unproject_position(mark)
	var rel := Vector2(37.0, -23.0)  # a plausible one-frame drag, off both axes
	hq._pan_table(rel, before + rel)  # grab at `before`, drag to `before + rel`
	var after: Vector2 = hq._camera.unproject_position(mark)
	assert_almost_eq(after.x, before.x + rel.x, 1.0,
		"the grabbed map point tracked the pointer horizontally, within a pixel")
	assert_almost_eq(after.y, before.y + rel.y, 1.0,
		"the grabbed map point tracked the pointer vertically, within a pixel")
	# And it really moved — a test that passed because nothing panned would be worthless.
	assert_gt(hq._table_pan.length(), 0.01, "the drag panned the map")


func test_hq_dragging_the_map_does_not_open_a_rally() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._table_ui._enter_table()
	# Press → move → the press becomes a pan-drag, not a tap.
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	hq._table_pan_input(press)
	var move := InputEventMouseMotion.new()
	move.relative = Vector2(40, 0)
	hq._table_pan_input(move)
	assert_true(hq._table_dragged, "a drag past the threshold is detected")
	# A release over a pin while dragging must NOT open that rally.
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	hq._on_pin_input(null, release, Vector3.ZERO, Vector3.ZERO, 0, "fx_open")
	assert_false(hq._detail_open, "dragging the map does not open the pin under the finger")
	# A clean tap (no drag) on a pin DOES open it (selection fires on release). The handler
	# is fire-and-forget and _on_rally_pin centres the camera on the pin before opening the
	# panel, so the detail arrives one camera glide later.
	hq._table_dragged = false
	hq._on_pin_input(null, release, Vector3.ZERO, Vector3.ZERO, 0, "fx_open")
	await get_tree().create_timer(Config.data.menu_camera_move_time).timeout
	assert_true(hq._detail_open, "a tap with no drag opens the rally detail")


func test_hq_parks_the_enterable_and_the_fixable_but_not_the_hopeless() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	# Three-way split: a car that can enter is parked; a car that is merely the wrong
	# DRIVETRAIN is parked too (marked with its reason, so the player can go and convert
	# it); a car that can never enter — wrong body, country, doors — is left out, because
	# parking it would offer the player nothing to act on.
	_save.grant_car("fx_awd")
	_save.grant_car("fx_rwd_coupe")
	hq._table_ui._on_rally_pin("fx_rwd_band")
	hq._enter_car_screen()
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.CARPARK, "Enter Rally flies out to the car park")
	assert_true(hq._car_layer.visible, "the car-park overlay is shown")
	assert_false(hq._detail_layer.visible, "the detail overlay is hidden in the car park")
	# Expected = the cars the RULE says can enter or be made to, derived from the rule
	# itself over the owned roster rather than pinned model names, so it stays correct if
	# the fixture cars or the rally's class are retuned.
	var rally := RallyLibrary.by_id("fx_rwd_band")
	var expected := {}
	var fixable := 0
	var hopeless := 0
	for car in _save.profile.get("cars", []):
		var spec := CarLibrary.by_id(String(car.get("model_id", "")))
		var meta := UpgradeLibrary.effective_meta(car, spec.duplicate())
		if RallyLibrary.is_eligible(rally, meta):
			expected[String(spec["name"])] = true
		elif hq._convertible_for(rally, car, spec):
			expected[String(spec["name"])] = true
			fixable += 1
		else:
			hopeless += 1
	await _await_lineup(hq)
	var parked := {}
	for car in hq._cars:
		parked[car.current_car_name()] = true
	assert_eq(parked, expected, "HQ parks the enterable and the fixable, and nothing else")
	assert_gt(fixable + hopeless, 0,
		"setup: at least one owned car is not eligible as built (else this proves nothing)")
	# The banner spells out the rally's restriction. Derive the expected text from the
	# rally's actual restriction (same helper HQ uses) rather than pinning "RWD CARS",
	# so it tracks any retune of the rally's restriction. The banner is upper-cased for
	# display, so compare case-insensitively.
	assert_string_contains(hq._rally_banner.text.to_upper(),
		hq._restriction_text(rally["restriction"]).to_upper(),
		"the banner spells out the rally restriction")


func test_hq_open_rally_parks_the_whole_lineup_with_per_car_meshes() -> void:
	# Two box-bodied cars of different sizes must keep their OWN body meshes — the
	# car scene shares mesh sub-resources across instances, so without per-instance
	# duplication both would render at whichever was applied last.
	_save.grant_car("fx_awd")     # two differently-sized box bodies
	_save.grant_car("fx_rwd_coupe")
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._table_ui._on_rally_pin("fx_open")  # open-class: all three are eligible
	hq._enter_car_screen()
	await get_tree().process_frame
	await _await_lineup(hq)
	assert_eq(hq._cars.size(), 3, "starter + the two granted cars are all eligible + parked")
	var size_by_name := {}
	for car in hq._cars:
		var chassis := car.get_node("Chassis") as MeshInstance3D
		size_by_name[car.current_car_name()] = (chassis.mesh as BoxMesh).size
	# Each parked car keeps its OWN library body size — derived from the catalogue so a
	# retune of either body doesn't break the test; what it proves is per-instance meshes.
	assert_eq(size_by_name["Fixture AWD"], CarLibrary.by_id("fx_awd")["body"], "the Fixture AWD keeps its own body size")
	assert_eq(size_by_name["Fixture Coupe"], CarLibrary.by_id("fx_rwd_coupe")["body"], "the Fixture Coupe keeps its own body size")
	assert_ne(size_by_name["Fixture AWD"], size_by_name["Fixture Coupe"],
		"parked cars do NOT share one mesh (per-instance duplication)")


func test_hq_parked_cars_rest_on_their_wheels_frozen() -> void:
	# Parked cars are placed at their analytic rest ride height (wheels on the bay) and
	# frozen at once — no live physics — so a full car park costs nothing to keep parked.
	_save.grant_car("fx_awd")
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._table_ui._on_rally_pin("fx_open")  # open-class: starter + the granted car both eligible
	hq._enter_car_screen()
	await get_tree().process_frame
	await _await_lineup(hq)
	assert_gt(hq._cars.size(), 0, "the lineup is parked")
	for i in hq._cars.size():
		var car = hq._cars[i]
		assert_true(car.freeze, "parked cars are frozen at once (no live settle)")
		# Body rests one ride-height above its bay marker (wheels on the ground), not
		# dropped to marker level (which would sink the body).
		if i < hq._markers.size():
			var marker_y: float = hq._markers[i].global_position.y
			assert_almost_eq(car.global_position.y, marker_y + car.settled_ride_height(), 0.02,
				"parked car sits on its wheels at the bay, not sunk to marker level")


func test_hq_cycling_focus_changes_the_focused_and_selected_car() -> void:
	_save.grant_car("fx_awd")
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._table_ui._on_rally_pin("fx_open")  # open-class: both cars eligible
	hq._enter_car_screen()
	await get_tree().process_frame
	await _await_lineup(hq)
	assert_eq(hq._cars.size(), 2, "both eligible cars are parked")
	assert_eq(hq._selected_instance_id, int(hq._eligible[0]["instance_id"]), "the first car is selected on entry")
	hq._carpark_ui._cycle_focus(1)
	assert_eq(hq._focus, 1, "cycling right advances the focus")
	assert_eq(hq._selected_instance_id, int(hq._eligible[1]["instance_id"]), "the newly focused car is selected")
	hq._carpark_ui._cycle_focus(1)
	assert_eq(hq._focus, 0, "cycling right off the last car wraps to the first")
	hq._carpark_ui._cycle_focus(-1)
	assert_eq(hq._focus, 1, "cycling left from the first car wraps to the last")


# Feed a pointer press / drag / release into the car-park input handler, the same
# events a mouse (or a finger via emulate_mouse_from_touch) produces.
func _lineup_button(hq: Node3D, pressed: bool, pos: Vector2) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = pos
	hq._cars_input(ev)


func _lineup_motion(hq: Node3D, relative: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.relative = relative
	hq._cars_input(ev)


func _lineup_gesture(hq: Node3D, drag: Vector2, pos := Vector2(400, 300)) -> void:
	_lineup_button(hq, true, pos)
	if drag != Vector2.ZERO:
		_lineup_motion(hq, drag)
	_lineup_button(hq, false, pos + drag)


func test_hq_carpark_swipe_cycles_the_focus() -> void:
	_save.grant_car("fx_awd")
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._table_ui._on_rally_pin("fx_open")  # open-class: both cars eligible
	hq._enter_car_screen()
	await get_tree().process_frame
	var swipe: float = Config.data.menu_swipe_min_px + 20.0
	# Dragging LEFT pulls the next car in from the right (carousel feel).
	_lineup_gesture(hq, Vector2(-swipe, 0.0))
	assert_eq(hq._focus, 1, "a leftward swipe advances the focus to the next car")
	_lineup_gesture(hq, Vector2(swipe, 0.0))
	assert_eq(hq._focus, 0, "a rightward swipe steps the focus back")
	# A mostly-vertical drag is neither a swipe nor a tap: the focus stays put.
	_lineup_gesture(hq, Vector2(-swipe * 0.3, -swipe * 2.0))
	assert_eq(hq._focus, 0, "a vertical drag does not swipe the lineup")


func test_hq_carpark_tap_on_a_parked_car_focuses_it() -> void:
	_save.grant_car("fx_awd")
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._table_ui._on_rally_pin("fx_open")
	hq._enter_car_screen()
	await get_tree().process_frame
	await _await_lineup(hq)
	hq._snap_camera_to_focus()
	await get_tree().physics_frame
	await get_tree().physics_frame
	assert_eq(hq._focus, 0, "the first car starts focused")
	# Tap where the SECOND parked car appears on screen: the raycast picks it and the
	# focus (and selection) jump straight to it — no ◄ ► button hunting.
	var target: Node3D = hq._cars[1]
	var screen: Vector2 = hq._camera.unproject_position(target.global_position)
	_lineup_gesture(hq, Vector2.ZERO, screen)
	assert_eq(hq._focus, 1, "tapping a parked car focuses it")
	assert_eq(hq._selected_instance_id, int(hq._eligible[1]["instance_id"]),
		"the tapped car becomes the selected car")
	# A tap on empty lot (high above the lineup, into the sky) leaves the focus alone.
	_lineup_gesture(hq, Vector2.ZERO, Vector2(screen.x, 1.0))
	assert_eq(hq._focus, 1, "tapping empty space keeps the current focus")


# The car-park overlay must NOT swallow pointer input: everything but the buttons is
# MOUSE_FILTER_IGNORE (via _passthrough_overlay), or a desktop click / touch tap would
# stop at the full-rect container and never reach _unhandled_input's swipe + tap-a-car
# handling.
func test_hq_lineup_overlays_pass_pointer_input_through() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var root: Control = (hq._car_layer as CanvasLayer).get_child(0)
	assert_eq(root.mouse_filter, Control.MOUSE_FILTER_IGNORE,
		"the overlay root lets clicks fall through to the 3D lineup")
	for n in root.find_children("*", "Control", true, false):
		if not (n is BaseButton):
			assert_eq((n as Control).mouse_filter, Control.MOUSE_FILTER_IGNORE,
				"%s lets clicks fall through to the 3D lineup" % n.get_class())


func test_hq_carpark_parks_cars_in_bays_facing_the_camera() -> void:
	# The lineup is a centred row ALONG X — one car per painted bay — each parked
	# nose-out toward the courtyard / menu camera (+Z), not the old recede-along-Z row.
	_save.grant_car("fx_awd")
	_save.grant_car("fx_rwd_coupe")
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._table_ui._on_rally_pin("fx_open")  # open-class: starter + the two granted cars
	hq._enter_car_screen()
	await get_tree().process_frame
	assert_eq(hq._markers.size(), 3, "three eligible cars are parked")
	var cfg: GameConfig = Config.data
	var lot_z: float = (cfg.hq_carpark_origin + Vector3(cfg.menu_car_park_offset, 0.0, 0.0)).z
	for m in hq._markers:
		var marker := m as Marker3D
		assert_almost_eq(marker.position.z, lot_z, 0.001, "the lineup is a row along X at the lot's Z")
		assert_almost_eq(marker.rotation.y, PI, 0.001, "each car is parked nose-out toward the camera (+Z)")
	# Distinct bay columns along X, centred within the bay grid + aligned to bay centres.
	assert_ne((hq._markers[0] as Marker3D).position.x, (hq._markers[1] as Marker3D).position.x,
		"adjacent cars occupy separate bays along X")
	var bays: int = max(1, cfg.carpark_page_size)
	var start: int = max(0, floori((bays - 3) / 2.0))
	for i in 3:
		assert_almost_eq((hq._markers[i] as Marker3D).position.x, hq._bay_center_x(start + i, bays), 0.001,
			"car %d sits centred in its painted bay" % i)


func test_hq_carpark_camera_frames_the_car_from_the_front() -> void:
	# The menu camera sits IN FRONT of the focused car (the cars face +Z), looking back
	# past it toward the garage (−Z) — the new framing, not the old 3/4-from-behind.
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._table_ui._on_rally_pin("fx_open")
	hq._enter_car_screen()
	await get_tree().process_frame
	var car_pos: Vector3 = hq._focused_car_pos()
	var xform: Transform3D = hq._camera_target_xform()
	assert_gt(xform.origin.z, car_pos.z, "the camera is in front of the car (+Z), not behind it")
	var forward: Vector3 = -xform.basis.z  # a camera looks down its local −Z
	assert_lt(forward.z, 0.0, "the camera looks back toward the car and the garage (−Z)")


# WORLD-SPACE CAR-PARK MENU (features/world-panel.md) — the mode game_config.tres SHIPS (this file's
# before_each pins it off, so world-mode tests opt back in). Three things have to
# move together when it is on, and all three are invisible in the flat default:
#   1. the overlay tree is hosted on the WorldPanel, not its CanvasLayer;
#   2. the bare labels get an opaque backing (the panel is transparent, so text would
#      otherwise sit straight on the sunlit car park);
#   3. the camera shifts to frame the panel as well as the car.
# Asserts the RELATIONSHIPS, not the authored offsets — every value involved is a look
# tunable a designer retunes by eye.
func test_hq_carpark_world_space_menu_hosts_backs_and_reframes() -> void:
	Config.data.world_space_menus = true
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._table_ui._on_rally_pin("fx_open")
	hq._enter_car_screen()
	await get_tree().process_frame

	var flat_sep: int = int(hq._car_root.get_meta(
		WorldPanel.FLAT_METRICS_META, {}).get("separation", 0))

	# 1. Hosted on the panel, and the flat layer has let go of the tree.
	assert_not_null(hq._panel_host("car").panel, "world mode builds a panel")
	assert_eq(hq._panel_host("car").panel.hosted(), hq._car_root as Control,
		"the car overlay tree is hosted on the panel")
	assert_false(hq._car_layer.visible, "the flat car-park layer stands down")

	# 2. Every label backing wears a real box rather than the empty one it has when flat.
	var backings: Array = hq._car_root.find_children("*", "PanelContainer", true, false).filter(
		func(n: Node) -> bool: return n.has_meta(WorldPanel.BACKING_META))
	assert_gt(backings.size(), 0, "the car overlay has backed labels")
	for n in backings:
		assert_true((n as PanelContainer).get_theme_stylebox("panel") is StyleBoxFlat,
			"a backed label must have an opaque box while on a world panel")

	# 2b. Rows are tighter than the flat screen's. A world panel's canvas is only ~200 px
	# tall, and the screen-authored gaps push the bottom action row clean off the panel once
	# a wrapped line takes two rows — Back / Start Rally get cut in half. Compared against
	# the tree's OWN recorded flat metrics rather than a pinned number, since both are look
	# tunables.
	assert_lt(hq._car_root.get_theme_constant("separation"), flat_sep,
		"a world panel's short canvas needs tighter rows than the flat screen")
	assert_lt(hq._car_root.offset_top, 16.0,
		"...and tighter margins, for the same reason")

	# 3. The shot is re-framed to fit the panel, and by EXACTLY the two authored shifts — no more.
	#
	# It used to assert the eye never moved at all, on the rule that panning the aim is preferable to
	# recomposing the shot. That rule still holds as GUIDANCE (see the field comments) but is no longer
	# an invariant: the car park has world_panel_camera_eye_shift for what panning cannot fix, distance
	# and occlusion. So the check became "the eye moves by the configured shift", which still catches
	# both a shift wired to nothing and a shift leaking somewhere it shouldn't.
	var eye_shift: Vector3 = Config.data.world_panel_camera_eye_shift
	var world_shot: Transform3D = hq._camera_target_xform()
	Config.data.world_space_menus = false
	var flat_shot: Transform3D = hq._camera_target_xform()
	assert_true((world_shot.origin - flat_shot.origin).is_equal_approx(eye_shift),
		"world mode must move the eye by exactly world_panel_camera_eye_shift, and no more")
	assert_false(world_shot.basis.is_equal_approx(flat_shot.basis),
		"world mode must pan the aim over to bring the panel into frame")

	# ...and flipping back off returns the tree to the flat host with its boxes cleared,
	# which is what makes the F7 A/B honest rather than one-way.
	hq.update_overlays()
	assert_eq(hq._car_root.get_parent(), hq._car_layer as Node,
		"turning world menus off returns the tree to its CanvasLayer")
	for n in backings:
		assert_false((n as PanelContainer).get_theme_stylebox("panel") is StyleBoxFlat,
			"the flat host must not inherit the panel's opaque label boxes")
	assert_eq(hq._car_root.get_theme_constant("separation"), flat_sep,
		"...nor the panel's tightened row gaps")


# MIGRATION STEP 2 — the tuning lift. This is the screen that actually exercises the input
# pump end to end: unlike the car park (FOCUS_NONE buttons, no sliders) the lift's sub-pages
# are native-focus with real HSliders, so it is the first host where MenuNav and drag have to
# work THROUGH a panel rather than only in a synthetic test.
func test_hq_lift_hosts_its_menu_on_a_world_panel() -> void:
	Config.data.world_space_menus = true
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_lift()
	await get_tree().process_frame

	assert_eq(hq._view, hq.View.LIFT, "we are on the lift")
	assert_not_null(hq._panel_host("lift"), "the lift has a world-panel host")
	assert_not_null(hq._panel_host("lift").panel, "...which built a panel in world mode")
	assert_eq(hq._panel_host("lift").panel.hosted(), hq._lift_root as Control,
		"the whole lift tree — sub-page AND hub column — is hosted on the panel")
	assert_false(hq._lift_layer.visible, "the flat lift layer stands down")

	# The sliders came along. This is the point of migrating this screen rather than another:
	# it puts a real Range inside a panel, where only the event pump can reach it.
	var sliders: Array = hq._lift_root.find_children("*", "Slider", true, false)
	assert_gt(sliders.size(), 0, "the tuning panel's sliders are inside the world panel")

	# And it reverts: the tree goes home and the flat layer takes over again.
	Config.data.world_space_menus = false
	hq.update_overlays()
	assert_eq(hq._lift_root.get_parent(), hq._lift_layer as Node,
		"turning world menus off returns the lift tree to its CanvasLayer")
	assert_true(hq._lift_layer.visible, "...and the flat lift layer comes back up")


# --- Unbounded collection + car-park pagination ------------------------------

# The collection is unbounded: owning far more cars than the car park has bays never
# gates the player — HQ boots straight to the title, no garage-full prompt. (The car
# park pages through the collection instead; see test_car_list.gd for the paging logic.)
func test_hq_boots_to_title_with_more_cars_than_bays() -> void:
	Config.data.carpark_page_size = 2  # tiny page so a handful of cars overflows a page
	for _i in 4:
		_save.grant_car("fx_awd")  # starter + 4 = 5 owned, well over the 2 bays
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.EXTERIOR, "an over-full garage still boots to the title (no gate)")
	assert_true(hq._title_layer.visible, "the title overlay is shown")


# Free Roam parks the WHOLE catalogue (owned or not) and pages through it: each page
# holds at most carpark_page_size cars, and cycling past a page boundary flips the page
# while the global position keeps counting up.
func test_hq_free_roam_lists_whole_catalogue_and_paginates() -> void:
	Config.data.carpark_page_size = 2
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_free_roam()
	await _await_lineup(hq)
	assert_eq(hq._view, hq.View.CARPARK, "Free Roam drops into the car park")
	assert_eq(hq._carpark_mode, hq.CarparkMode.FREEROAM, "the car park is in free-roam mode")
	assert_eq(hq._lineup.total(), CarLibrary.all().size(),
		"the whole catalogue is offered to pick from")
	assert_true(hq._lineup.total() > 2, "the catalogue is bigger than one page for this test")
	assert_lte(hq._cars.size(), 2, "only one page of cars is parked at a time")
	# Cycling right off the last car of page 0 flips to page 1's first car.
	assert_eq(hq._lineup.page, 0, "starts on page 0")
	hq._carpark_ui._cycle_focus(1)  # 0 -> 1 (still page 0)
	hq._carpark_ui._cycle_focus(1)  # 1 -> page 1, car 0
	assert_eq(hq._lineup.page, 1, "cycling past the page boundary flips to the next page")
	assert_eq(hq._lineup.global_index(), 2, "the global position keeps counting across pages")
	# Back returns to the garage.
	hq._car_back()
	assert_ne(hq._carpark_mode, hq.CarparkMode.FREEROAM, "backing out clears free-roam mode")
	# Free Roam is entered from the TITLE screen, so Back returns there — not the garage.
	assert_eq(hq._view, hq.View.EXTERIOR, "Back from Free Roam returns to the title screen")


func test_hq_carpark_lets_a_zero_hp_car_be_selected_and_fielded() -> void:
	# A car damaged to 0 HP is still an ordinary car: it appears in the eligible lineup,
	# can be focused, and can be entered. Nothing gates on the bottomed-out state.
	var owned: Dictionary = _save.grant_car("fx_awd")
	var id := int(owned["instance_id"])
	_save.apply_damage(id, 999999.0)  # floored at 0 HP, kept and owned
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._table_ui._on_rally_pin("fx_open")  # open-class: starter + the granted car both eligible
	hq._enter_car_screen()
	await get_tree().process_frame
	# Focus the 0-HP car in the lineup.
	var idx := -1
	for i in hq._eligible.size():
		if int(hq._eligible[i]["instance_id"]) == id:
			idx = i
	assert_gt(idx, -1, "the 0-HP car is still parked in the lineup")
	hq._focus = idx
	hq._carpark_ui._focus_changed()
	# Damage WARNS but never bars: damage only ever weakens (features/damage.md), so a
	# battered car is one you can still race — badly — and the label points at the repair
	# rather than declaring the car dead.
	assert_false(hq._start_button.disabled, "a 0-HP car can still be entered")
	assert_true(hq._car_warning_label.visible, "but it is flagged as damaged")
	assert_true(_save.car_needs_repair(id), "and it does need a repair")


# The car park no longer auto-switches a wrong-drivetrain car at the Start button. That
# switch was free, silent and reverted afterwards, which — now that conversion carries a
# per-car star price — handed the player for nothing exactly what the garage charges for,
# and (once resolve_drive_override began ignoring unpaid overrides) would have sent the car
# out still ineligible while the game believed it qualified.
#
# A wrong-drivetrain car is simply ineligible now: parked, marked, and left for the player
# to convert themselves.
func test_a_wrong_drivetrain_car_is_ineligible_and_says_so() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var rally := {"id": "t_rwd", "name": "T", "restriction": {"drive_mode": CarLibrary.RWD}}
	var entry := {"id": "t_fwd", "name": "FWD car", "drive_mode": CarLibrary.FWD,
		"engine": "", "mass": 1200.0, "max_hp": 1000.0}
	var car := {"instance_id": 2, "model_id": "t_fwd", "hp": 1000.0,
		"installed_upgrades": [], "disabled_upgrades": [], "drivetrain_override": -1,
		"drivetrain_modes_bought": []}
	assert_false(bool(hq._entry_plan(rally, car)["eligible"]),
		"the wrong drive mode makes the car ineligible, with nothing proposed to fix it")
	# And the rally panel counts it as convertible, which is the prompt that tells the
	# player what they could do about it.
	assert_ne(RallyLibrary.ineligibility_reason(
		rally, UpgradeLibrary.effective_meta(car, entry)), "",
		"and the reason is stated, so the car park has something to show")


# Being parked is not being enterable: focusing an ineligible car must kill Start and put
# the rally's own reason on screen, so the player learns what is wrong from the car itself.
func test_focusing_an_ineligible_car_blocks_start_and_names_the_reason() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	_save.grant_car("fx_awd")
	_save.grant_car("fx_rwd_coupe")
	hq._table_ui._on_rally_pin("fx_rwd_band")
	hq._enter_car_screen()
	await _await_lineup(hq)
	var rally := RallyLibrary.by_id("fx_rwd_band")
	# Walk the parked lineup and check each car against the eligibility rule directly.
	var saw_ineligible := false
	for i in hq._eligible.size():
		var owned: Dictionary = hq._eligible[i]
		var entry := CarLibrary.for_owned(owned)
		var reason := RallyLibrary.ineligibility_reason(
			rally, UpgradeLibrary.effective_meta(owned, entry))
		hq._focus = i
		hq._carpark_ui._focus_changed()
		if reason == "":
			assert_false(hq._start_button.disabled, "an eligible car can be started")
			continue
		saw_ineligible = true
		assert_true(hq._start_button.disabled, "an ineligible car cannot be started")
		assert_true(hq._car_warning_label.visible, "and it is flagged on screen")
		# Compared case-insensitively: the house style uppercases every label on display.
		assert_eq(hq._car_warning_label.text.to_upper(), reason.to_upper(),
			"in the rally's own words, so the car park cannot invent a different story")
	assert_true(saw_ineligible, "setup: the lineup contains an ineligible car to test")


# A car that can NEVER enter — no upgrade changes its body, country or doors — is left out
# of the lineup entirely. Parking it would be a row the player can do nothing about.
func test_a_car_that_can_never_qualify_is_not_parked() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var rally := RallyLibrary.by_id("fx_rwd_band")
	assert_false(rally.is_empty(), "setup: the fixture rally exists")
	# A restriction no upgrade can satisfy, on a car that fails it.
	var hopeless := {"instance_id": 99, "model_id": "fx_awd", "hp": 1000.0,
		"installed_upgrades": [], "disabled_upgrades": [], "drivetrain_override": -1,
		"drivetrain_modes_bought": []}
	var body_rally := {"id": "t_body", "name": "T", "restriction": {"car_type": "not_a_real_type"}}
	assert_false(hq._can_ever_enter(body_rally, hopeless),
		"a body-type mismatch is unfixable, so the car is excluded from the lineup")


# ...but a car that is only the wrong DRIVETRAIN is kept, because the player can convert it.
func test_a_convertible_car_is_kept_in_the_lineup() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var rwd_rally := {"id": "t_rwd", "name": "T", "restriction": {"drive_mode": CarLibrary.RWD}}
	var awd := {"instance_id": 98, "model_id": "fx_awd", "hp": 1000.0,
		"installed_upgrades": [], "disabled_upgrades": [], "drivetrain_override": -1,
		"drivetrain_modes_bought": []}
	assert_false(bool(hq._entry_plan(rwd_rally, awd)["eligible"]),
		"setup: it cannot enter as built")
	assert_true(hq._can_ever_enter(rwd_rally, awd),
		"but a conversion would fix it, so it stays in the lineup to be marked")


# --- Tuning lift (features/tuning.md / todo/menus.md rig 4) ----------------------

func test_hq_lift_raises_the_selected_car() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	# The starter is selected on first boot, so it's the one on the lift.
	assert_eq(_save.selected_instance_id(), int(_save.profile["cars"][0]["instance_id"]),
		"the starter is selected on first boot")
	# In the garage the car rests lowered on the ground.
	hq._on_exterior_start()  # -> GARAGE: spawns the lift car, lowered
	await get_tree().process_frame
	assert_true(is_instance_valid(hq._lift_car), "the selected car sits on the lift in the garage")
	assert_false(hq._lift_raised, "the car is lowered to the ground in the garage view")
	hq._enter_lift()
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.LIFT, "tapping the lift flies the camera to the tuning bay")
	assert_true(hq._lift_layer.visible, "the tuning menu is shown")
	assert_true(is_instance_valid(hq._lift_car), "the selected car is raised on the lift")
	assert_true(hq._lift_raised, "entering the bay raises the car on the lift")
	assert_eq(hq._lift_car.current_car_name(), "Fixture Roadster", "the lift shows the selected car")
	# Going back to the garage lowers it again.
	hq._lift_back()
	assert_eq(hq._view, hq.View.GARAGE, "Back returns to the garage")
	assert_false(hq._lift_raised, "the car lowers back to the ground in the garage")


func test_hq_lift_lowest_pose_matches_the_cars_calculated_rest_height() -> void:
	# The lift's LOWERED pose respects how low the car actually sits: it rests on the lot
	# FLOOR (hq_lift_pos.y) at the car's calculated settled ride height (car.gd
	# settled_ride_height) — exactly how it sits parked — not floated up by the beam
	# thickness. Behaviour that must hold for ANY car geometry, not a pinned value.
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()  # -> GARAGE: spawns the lift car, lowered
	await get_tree().process_frame
	assert_true(is_instance_valid(hq._lift_car), "the selected car sits on the lift in the garage")
	assert_false(hq._lift_raised, "the car is lowered in the garage view")
	var cfg: GameConfig = Config.data
	assert_almost_eq(hq._lift_car.global_position.y,
		cfg.hq_lift_pos.y + hq._lift_car.settled_ride_height(), 0.001,
		"the lowered car rests on the floor at its calculated settled ride height")


func test_hq_lift_opens_on_a_hub_with_its_own_menu_pages() -> void:
	# The bay opens on the HUB (Tuning/Upgrades + Test Drive buttons beside the
	# car); each menu button opens that menu as its own page, and Back returns to the hub.
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_lift()
	await get_tree().process_frame
	assert_eq(hq._lift_page, hq.LiftPage.HUB, "entering the bay lands on the hub page")
	assert_true(hq._lift_hub_controls.visible, "the hub shows the menu + test-drive buttons")
	assert_true(hq._lift_info_panel.visible, "the car description shows on the hub")
	assert_false(hq._lift_menu_bg.visible, "no sub-menu panel is shown on the hub")
	# Open Tuning: its page (the sliders) takes over; the hub controls + car desc hide.
	hq._open_lift_page(hq.LiftPage.TUNE)
	assert_true(hq._lift_menu_bg.visible, "the sub-menu panel shows on the Tuning page")
	assert_true(hq._tune_panel.visible, "the Tuning page shows the sliders")
	assert_false(hq._lift_upgrades_box.visible, "the Upgrades menu is hidden on the Tuning page")
	assert_false(hq._lift_hub_controls.visible, "the hub controls hide while a menu is open")
	assert_false(hq._lift_info_panel.visible, "the car description hides while a menu is open")
	# Back returns to the hub (still in the bay, car still raised).
	hq._lift_back()
	assert_eq(hq._lift_page, hq.LiftPage.HUB, "Back from a menu returns to the hub")
	assert_eq(hq._view, hq.View.LIFT, "still in the tuning bay")
	# Open Upgrades the same way, then Back-from-hub leaves the bay for the garage.
	hq._open_lift_page(hq.LiftPage.UPGRADES)
	assert_true(hq._lift_upgrades_box.visible, "the Upgrades page shows the install list")
	assert_false(hq._tune_panel.visible, "the Tuning menu is hidden on the Upgrades page")
	hq._lift_back()
	hq._lift_back()
	assert_eq(hq._view, hq.View.GARAGE, "Back from the hub returns to the garage")


func test_hq_lift_tune_sliders_save_tuning_per_car() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_lift()
	await get_tree().process_frame
	# Moving the (always-available) grip slider stores the value on the selected car.
	hq._tune_panel._sliders["grip_balance"].value = 0.6
	var owned: Dictionary = _save.selected_car()
	assert_almost_eq(float(owned["tuning"]["grip_balance"]), 0.6, 0.001,
		"the grip slider saves onto the selected car's tuning")
	# Reset zeroes every axis (free + instant).
	hq._tune_panel._reset()
	assert_true(_save.selected_car().get("tuning", {}).is_empty(), "Reset clears the tuning deltas")



# Wheels moved off the lift hub row and into the Tuning menu itself. It's a real,
# focusable button wired to the same _enter_wheel_swap the hub row used to call.
func test_hq_lift_tuning_panel_has_a_wheels_button() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_lift()
	await get_tree().process_frame
	hq._open_lift_page(hq.LiftPage.TUNE)
	await get_tree().process_frame
	assert_not_null(hq._tune_panel._wheels_button, "the Tuning panel has a Wheels button")
	assert_true(hq._tune_panel._wheels_button.visible, "Wheels is shown when the host wires on_wheels")
	assert_eq(hq._tune_panel._wheels_button.focus_mode, Control.FOCUS_ALL,
		"Wheels is keyboard/gamepad focusable, matching the panel's native-focus sliders")
	assert_false(hq._tune_panel._wheels_button.disabled, "Wheels is enabled")
	# Firing it enters the wheel-swap flow (the solo car-park view), the same handoff
	# the old hub-row Wheels button used.
	hq._tune_panel._on_wheels_pressed()
	assert_eq(hq._view, hq.View.CARPARK, "Wheels leaves the lift for the car park")
	assert_eq(hq._carpark_mode, hq.CarparkMode.WHEELS, "Wheels opens the wheel-swap car park mode")


func test_hq_lift_gates_locked_sliders_by_upgrade() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_lift()
	await get_tree().process_frame
	# The starter has no kits: grip + brake bias are free, aero is locked.
	assert_true(hq._tune_panel._sliders["grip_balance"].editable, "grip is always tunable")
	assert_true(hq._tune_panel._sliders["brake_bias"].editable, "brake bias is always tunable")
	assert_false(hq._tune_panel._sliders["aero_balance"].editable, "aero locked without the aero kit")
	# Fit an aero kit to a fresh car and select it — its aero slider unlocks.
	var owned: Dictionary = _save.grant_car("fx_awd")
	var id := int(owned["instance_id"])
	_save.add_item("fx_aero")
	_save.install_upgrade(id, "fx_aero")
	_save.set_selected_car(id)
	hq._enter_lift()
	await get_tree().process_frame
	assert_true(hq._tune_panel._sliders["aero_balance"].editable, "the aero kit unlocks aero tuning")


func test_hq_lift_hub_has_a_test_drive_button_targeting_the_lift_car() -> void:
	# The tuning bay's hub carries a Test Drive button (Back / Tuning / Upgrades /
	# Test Drive, then a hidden Repair). Test Drive fields the car ALREADY on the lift
	# for a free-roam drive — no car picker — so it never opens the car park.
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_lift()
	await get_tree().process_frame
	# Find Test Drive by LABEL, not by row index — the hub row grows as pages are added
	# (Wheels landed after this test was written) and its position isn't the contract.
	var test_drive: Button = null
	for child in hq._lift_hub_controls.get_children():
		# The menu theme uppercases button labels (_normalize_menus), so compare
		# case-insensitively.
		if child is Button and (child as Button).text.to_upper() == "TEST DRIVE":
			test_drive = child
	assert_not_null(test_drive, "the hub row has a Test Drive button")
	# It's the LAST hub cursor stop, so keyboard/gamepad can reach it by wrapping left off
	# Back. (We don't fire it here: _test_drive delegates to _start_free_roam, whose real
	# scene change would swap the test runner's scene; the launch is covered separately.)
	assert_eq(hq._hub_cursor.buttons.back(), test_drive, "Test Drive is the last cursor stop")
	assert_eq(hq._hub_focus, 1, "the hub cursor still seats on Tuning on entry")
	hq._move_hub_focus(-1)
	assert_eq(hq._hub_focus, 0, "left from Tuning lands on Back")
	hq._move_hub_focus(-1)
	assert_eq(hq._hub_focus, hq._hub_cursor.buttons.size() - 1,
		"left from Back wraps onto Test Drive")


func test_hq_lift_upgrades_menu_has_no_apply_from_pool_rows() -> void:
	# Upgrades are car-bound and fitted when won — the garage no longer applies
	# pooled parts to a car. Even with a slottable id sitting in inventory (a stale
	# state that shouldn't occur post-migration), no "Apply" row is offered.
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var owned: Dictionary = _save.grant_car("fx_awd")
	var id := int(owned["instance_id"])
	_save.set_selected_car(id)
	_save.profile["inventory"]["fx_turbo_small"] = 1  # deliberately stale pool entry
	hq._enter_lift()
	await get_tree().process_frame
	hq._open_lift_page(hq.LiftPage.UPGRADES)
	await get_tree().process_frame
	for b in hq._lift_upgrades_box.find_children("*", "Button", true, false):
		assert_false(String(b.text).begins_with("APPLY"),
			"no apply-from-pool button appears in the garage upgrades menu")
	assert_false(_save.get_car(id)["installed_upgrades"].has("fx_turbo_small"),
		"nothing gets fitted from the pool")



func test_hq_back_steps_carpark_to_table_to_garage() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	hq._table_ui._enter_table()
	hq._table_ui._on_rally_pin("fx_open")
	hq._enter_car_screen()
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.CARPARK, "in the car park after entering")
	# Back from the car park returns to the map table, clearing the lineup.
	hq._car_back()
	assert_eq(hq._view, hq.View.TABLE, "Back from the car park returns to the map table")
	assert_eq(hq._cars.size(), 0, "the parked lineup is cleared when leaving the car park")
	assert_true(hq._table_layer.visible, "the map HUD is shown again")
	# Back from the table returns to the garage.
	hq.go_to(hq.View.GARAGE)
	assert_eq(hq._view, hq.View.GARAGE, "Back from the table returns to the garage")


func test_hq_choose_rally_then_car_then_start_launches_a_session() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	# Pick a rally → enter, then Start with the focused car. auto_load_scenes is off,
	# so no scene change; start_rally derives targets.
	hq._table_ui._on_rally_pin("fx_open")
	hq._enter_car_screen()
	await get_tree().process_frame
	assert_false(hq._start_button.disabled, "Start is enabled once a rally + eligible car are chosen")
	# Start shows the loading overlay first, then hands off after a frame (so the
	# overlay paints before the heavy target derivation) — await the whole thing.
	await hq._on_start_pressed()
	assert_gt(hq.find_children("*", "LoadingScreen", true, false).size(), 0,
		"a loading overlay is shown immediately on Start")
	assert_true(RallySession.is_active(), "Start hands off to an active RallySession")
	assert_eq(RallySession.rally_id(), "fx_open", "the chosen rally is running")


func test_hq_starting_a_rally_selects_the_fielded_car() -> void:
	# Fielding a car for a rally also makes it the selected car (the one on the
	# tuning lift), so the garage shows the car the player last raced.
	_save.grant_car("fx_awd")
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._table_ui._on_rally_pin("fx_open")  # open-class: both cars eligible
	hq._enter_car_screen()
	await get_tree().process_frame
	await _await_lineup(hq)
	# Focus a car that is NOT the currently selected one, then start.
	var before: int = _save.selected_instance_id()
	var other := -1
	for i in hq._eligible.size():
		if int(hq._eligible[i]["instance_id"]) != before:
			hq._focus = i
			hq._carpark_ui._focus_changed(true)
			other = int(hq._eligible[i]["instance_id"])
			break
	assert_ne(other, -1, "a second eligible car exists to field")
	await hq._on_start_pressed()
	assert_true(RallySession.is_active(), "the rally launches with the fielded car")
	assert_eq(_save.selected_instance_id(), other,
		"fielding a car for a rally makes it the selected (lift) car")


func test_hq_mobile_first_start_gates_on_control_scheme_pick() -> void:
	Config.data.mobile_controls_force = true  # simulate a touch device
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._table_ui._on_rally_pin("fx_open")
	hq._enter_car_screen()
	await get_tree().process_frame
	# No control scheme saved yet -> Start shows the picker as a gate, not the rally.
	assert_null(_save.get_setting(MobileControls.SETTING_KEY, null), "no control preference yet")
	hq._on_start_pressed()
	assert_eq(hq._view, hq.View.SETTINGS, "first mobile start shows the control picker")
	assert_true(hq._settings_gate, "the picker is in pre-rally gate mode")
	# The gate jumps straight to the mobile-controls page (not the full category list),
	# and its bottom button starts the rally rather than backing out.
	assert_false(hq._settings_menu.at_root(), "the gate opens on the mobile-controls page, not the category list")
	assert_eq(hq._settings_menu._scheme_page.visible, true, "the mobile-controls page is the one shown")
	assert_eq(hq._settings_action_button.text.to_upper(), "START >", "the gate button starts the rally")
	assert_false(RallySession.is_active(), "the rally hasn't started — it's gated on the pick")
	# Confirm: saves the (default, untouched) scheme so we never ask again, then starts.
	hq._on_settings_action()
	assert_eq(int(_save.get_setting(MobileControls.SETTING_KEY, -1)), MobileControls.DEFAULT_SCHEME,
		"confirming the gate persists the chosen scheme")
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	assert_true(RallySession.is_active(), "after the pick the rally starts")


func test_hq_mobile_start_skips_gate_once_scheme_chosen() -> void:
	Config.data.mobile_controls_force = true
	_save.set_setting(MobileControls.SETTING_KEY, MobileControls.SCHEME_TILT_GAS_BRAKE)
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._table_ui._on_rally_pin("fx_open")
	hq._enter_car_screen()
	await get_tree().process_frame
	# A preference exists, so Start goes straight to the rally (no gate).
	await hq._on_start_pressed()
	assert_ne(hq._view, hq.View.SETTINGS, "an existing preference skips the picker")
	assert_true(RallySession.is_active(), "Start launches the rally directly")


func test_standings_interstitial_renders_the_leaderboard() -> void:
	# After a non-final event the rally pauses on the standings; the scene shows the
	# cumulative leaderboard so far. (auto_load_scenes is off, so no scene loads.)
	var owned: Dictionary = _save.grant_car("fx_awd")
	RallySession.start_rally(RallyLibrary.by_id("fx_open"), owned, true)
	RallySession._opponent_field = [
		{"name": "Quick", "event_times_ms": [40000, 40000, 40000], "dnf": false, "combined_ms": 120000},
		{"name": "Slow", "event_times_ms": [80000, 80000, 80000], "dnf": false, "combined_ms": 240000},
	]
	RallySession.report_event_result(50000)  # complete event 1 -> STANDINGS
	var sc: Control = load("res://standings.tscn").instantiate()
	add_child_autofree(sc)
	await get_tree().process_frame
	var text := _label_texts(sc)
	# No screen title / rally-name line any more — the section heading is the header,
	# so both leaderboards fit without scrolling.
	assert_string_contains(text, "STAGE 1 RESULT", "the section heading names the stage")
	# Stage 1's two lists are identical, but BOTH still show — the screen keeps the
	# same shape from the first stage to the last.
	assert_string_contains(text, UITheme.caps(Standings.overall_heading(1)),
		"stage 1 still carries the overall section, marked as stage 1 only")
	assert_false(text.contains("FIXTURE OPEN"), "the rally-name line is gone")
	assert_string_contains(text, "QUICK", "the opponent field is listed")
	assert_string_contains(text, "SLOW", "the whole field is shown")
	# Continue is focused on entry so a keyboard / gamepad can advance with no pointer.
	var cont := sc.find_children("*", "Button", true, false)[0] as Button
	assert_eq(cont.focus_mode, Control.FOCUS_ALL, "the Continue button is focusable")
	assert_eq(sc.get_viewport().gui_get_focus_owner(), cont,
		"Continue is focused for keyboard / gamepad")
func _challenge_after_stage_one() -> Control:
	var car: Dictionary = _save.grant_car("fx_light_rwd")
	var longest := ChallengeLibrary.WEEKLY
	for kind_str in ChallengeLibrary.STAGE_COUNTS:
		if int(ChallengeLibrary.STAGE_COUNTS[kind_str]) \
				> int(ChallengeLibrary.STAGE_COUNTS.get(longest, 0)):
			longest = String(kind_str)
	assert_true(ChallengeSession.start(longest, car, int(Time.get_unix_time_from_system())))
	ChallengeSession.report_event_result(50000)
	var sc: Control = load("res://standings.tscn").instantiate()
	add_child_autofree(sc)
	return sc


func test_standings_opens_a_challenge_stage_straight_on_the_world_board() -> void:
	# A challenge has no AI opponents — only real people online — so page 1 (the local
	# event standings) has nothing to rank and is fed an empty row list. The
	# interstitial skips it entirely and opens on the world board.
	var sc := _challenge_after_stage_one()
	await get_tree().process_frame
	assert_true(sc._global_shown, "the challenge interstitial opens on the world board")
	assert_false(is_instance_valid(sc._root_box), "page 1 is not left behind it")
	assert_string_contains(_label_texts(sc), "ONLINE LEADERBOARD",
		"what is shown is the online board, not a one-row local table")
func _ranked(names: Array, player: String) -> Array:
	var rows: Array = []
	for i in names.size():
		rows.append({"name": names[i], "placed": i + 1, "is_player": names[i] == player})
	return rows


func test_visible_rows_keeps_only_the_podium_when_the_player_is_on_it() -> void:
	var rows := _ranked(["A", "You", "C", "D", "E"], "You")
	var shown: Array = Standings.visible_rows(rows, 3)
	assert_eq(shown.size(), 3, "a player inside the top 3 needs no extra row")
	assert_eq(String(shown[1].get("name", "")), "You", "the player keeps their real position")


func test_visible_rows_appends_the_player_below_the_podium() -> void:
	var rows := _ranked(["A", "B", "C", "D", "E", "You"], "You")
	var shown: Array = Standings.visible_rows(rows, 3)
	assert_eq(shown.size(), 5, "top 3, a gap marker, then the player")
	assert_true(bool(shown[3].get("gap", false)), "a non-adjacent player is cut in with a gap")
	assert_eq(String(shown[4].get("name", "")), "You", "the player's own row is always shown")


func test_visible_rows_omits_the_gap_when_the_player_is_next_in_line() -> void:
	var rows := _ranked(["A", "B", "C", "You"], "You")
	var shown: Array = Standings.visible_rows(rows, 3)
	assert_eq(shown.size(), 4, "P4 follows the podium directly")
	for entry in shown:
		assert_false(bool(entry.get("gap", false)), "nothing was skipped, so no gap marker")


func test_visible_rows_handles_a_field_smaller_than_the_podium() -> void:
	var rows := _ranked(["You", "B"], "You")
	var shown: Array = Standings.visible_rows(rows, 3)
	assert_eq(shown.size(), 2, "a short field is shown whole")


# The OVERALL heading spells out which stages it sums, so stage 1's identical pair of
# lists reads as intentional rather than as a duplicate.
func test_overall_heading_names_every_stage_summed_so_far() -> void:
	assert_eq(Standings.overall_heading(1), "OVERALL — stage 1 only",
		"stage 1 says outright that only one stage is in the total")
	assert_eq(Standings.overall_heading(2), "OVERALL — stages 1 + 2",
		"stage 2 lists both stages")
	assert_eq(Standings.overall_heading(3), "OVERALL — stages 1 + 2 + 3",
		"stage 3 lists all three")


# A first-won SPECIAL gets its own podium stage naming the upgrade it unlocked, and the card
# says which car it went on. Ordinary rallies must not see the stage at all.
func test_podium_reveals_a_special_unlock_and_names_the_car() -> void:
	# Synthetic part, so the test neither depends on a shipped catalogue entry nor cares
	# what the real ladder is named (CLAUDE.md). Also robust to whatever override an
	# earlier test left installed.
	UpgradeLibrary.override_for_test([
		{"id": "fx_part", "name": "Fixture Part", "slot": "fxslot", "consumable": false,
			"cost": 0, "free": true},
	] as Array[Dictionary])
	RallySession._last_result = {
		"placed": 1, "completed": true, "combined_ms": 65000, "dnf": false,
		"special_unlock": {"item_id": "fx_part", "granted": ["fx_part"]},
		"standings": [{"name": "You", "car_name": "V12 Test Car", "car_id": "",
			"combined_ms": 65000, "dnf": false, "is_player": true, "placed": 1}],
	}
	var pod: Node3D = load("res://podium.tscn").instantiate()
	add_child_autofree(pod)
	await get_tree().process_frame
	assert_true(pod._stages.has(pod.Stage.SPECIAL_UNLOCK), "the unlock stage is in the sequence")
	pod._enter_stage(pod.Stage.SPECIAL_UNLOCK)
	var text := _label_texts(pod)
	# The part is named from the catalogue rather than asserted as a literal, so retitling
	# the upgrade moves the test with it.
	var part_name := UITheme.caps(String(UpgradeLibrary.by_id("fx_part").get("name", "")))
	assert_ne(part_name, "", "precondition: the synthetic part resolves")
	assert_string_contains(text, part_name, "the card names the unlocked part")
	assert_string_contains(text, "V12 TEST CAR", "and the car it was applied to")
	assert_string_contains(text, "CAN NOW BE WON", "and that it joins the rally rewards")
	# The HOUSE card, not a bespoke inverted one: this was the only white surface in the
	# game and read as another app's dialog. Compared against UITheme.reward_card_box
	# rather than a literal colour, so retuning the house card carries this with it.
	assert_eq(pod._slot_panel.get_theme_stylebox("panel").bg_color,
		UITheme.reward_card_box().bg_color,
		"the unlock card wears the house reward card, like every other reveal")
	# The house rules set a font_color of their own, so the check is that the ink is not
	# the black the inverted card used to paint back on over them.
	assert_ne(pod._slot_label.get_theme_color("font_color"), Color(0, 0, 0, 1),
		"and takes the house light ink, not the inverted card's black")


# A special that gates a CAPABILITY rather than a part still gets a reveal. Engine swaps are
# authored as RallyLibrary.ENGINE_SWAP_UNLOCK_RALLY, not as a catalogue entry, and they are
# now the LOWEST rung — so without this the very first unlock a player earns is silent.
func test_podium_reveals_a_capability_unlock_with_nothing_to_fit() -> void:
	RallySession._last_result = {
		"placed": 1, "completed": true, "combined_ms": 65000, "dnf": false,
		"special_unlock": {"item_id": "", "capability": "engine_swap", "granted": []},
		"standings": [],
	}
	var pod: Node3D = load("res://podium.tscn").instantiate()
	add_child_autofree(pod)
	await get_tree().process_frame
	assert_true(pod._stages.has(pod.Stage.SPECIAL_UNLOCK),
		"a capability unlock still gets its own stage")
	pod._enter_stage(pod.Stage.SPECIAL_UNLOCK)
	var text := _label_texts(pod)
	assert_string_contains(text, "ENGINE SWAPS", "the card names the capability")
	assert_false(text.contains("APPLIED TO"),
		"and claims nothing was fitted — there is no part to fit")


# An ordinary rally never sees the unlock stage.
func test_podium_skips_the_unlock_stage_for_an_ordinary_rally() -> void:
	RallySession._last_result = {"placed": 1, "completed": true, "combined_ms": 65000,
		"dnf": false, "special_unlock": {}}
	var pod: Node3D = load("res://podium.tscn").instantiate()
	add_child_autofree(pod)
	await get_tree().process_frame
	assert_false(pod._stages.has(pod.Stage.SPECIAL_UNLOCK),
		"no unlock stage without a special_unlock")


func test_a_win_still_reads_as_a_win() -> void:
	# The other side of the wording split — P1 is the one result that may claim it.
	RallySession._last_result = {"placed": 1, "completed": true, "combined_ms": 60000,
		"dnf": false}
	var pod: Node3D = load("res://podium.tscn").instantiate()
	add_child_autofree(pod)
	await get_tree().process_frame
	assert_string_contains(_label_texts(pod), "WON", "first place reads as a win")


# A rally completed from OFF the podium — only the opening rally does this
# (todo/opening-rally.md). It must not claim a top-3 finish that did not happen.
func test_an_off_podium_completion_claims_no_podium() -> void:
	RallySession._last_result = {"placed": 6, "completed": true, "combined_ms": 90000,
		"dnf": false}
	var pod: Node3D = load("res://podium.tscn").instantiate()
	add_child_autofree(pod)
	await get_tree().process_frame
	var text := _label_texts(pod)
	assert_string_contains(text, "COMPLETED", "it still reads as completed")
	assert_false(text.contains("TOP 3"), "but does not claim a podium it did not get")
	assert_false(text.contains("WON"), "nor a win")


func test_podium_shows_the_finish_summary() -> void:
	# The podium opens on its first stage (the 3D podium) showing the headline result.
	RallySession._last_result = {"placed": 2, "completed": true, "combined_ms": 65000, "dnf": false}
	var pod: Node3D = load("res://podium.tscn").instantiate()
	add_child_autofree(pod)
	await get_tree().process_frame
	assert_eq(pod._stage, pod.Stage.PODIUM, "the podium opens on the PODIUM stage")
	var text := _label_texts(pod)
	assert_string_contains(text, "P2", "podium shows the placement")
	# CHANGED DELIBERATELY: a P2/P3 finish used to read "RALLY WON". It completes the
	# rally — claims the prize, lights the map — but it is not a win, and the placement
	# on the line above already says so.
	assert_string_contains(text, "COMPLETED", "a podium finish reads as completed")
	assert_false(text.contains("WON"), "and does not claim a win from second place")
	# The text sits on a solid black plate: it is drawn over the live 3D podium scene,
	# where unbacked light text is hard to read at the moment the player most wants to.
	assert_true(pod._body_plate.visible, "the body text's black plate is up")
	var plate_box: StyleBox = pod._body_plate.get_theme_stylebox("panel")
	assert_true(plate_box is StyleBoxFlat, "the plate carries a flat stylebox")
	assert_eq((plate_box as StyleBoxFlat).bg_color.a, 1.0, "and it is fully opaque")
	# The plate must FILL, not shrink to its content. _body_label autowraps, and an
	# autowrapping label's minimum width is ONE CHARACTER — so a shrink-to-fit plate
	# collapsed to a narrow column and rendered the summary vertically, one letter per
	# line. Asserting the measured width catches that however it is reintroduced.
	await get_tree().process_frame
	assert_gt(pod._body_plate.size.x, 200.0,
		"the plate spans the page rather than collapsing to a one-character column")
	assert_false(pod._body_label.text.is_empty(), "setup: there is text to lay out")
	# The grass floor with feathered tarmac pads is built as a custom ArrayMesh
	# (scenery MultiMeshes are skipped headless, but the floor swap always runs).
	var floor_mi := pod.get_node_or_null("Floor")
	assert_not_null(floor_mi, "the podium builds a named Floor mesh")
	assert_true(floor_mi.mesh is ArrayMesh, "the floor is the custom feathered-tarmac mesh")
	assert_eq(pod._middle.alignment, BoxContainer.ALIGNMENT_CENTER,
		"the content stack is centred on the podium stage")
	# The Next button is focused (once revealed) so the reward sequence steps with a
	# keyboard / gamepad.
	assert_eq(pod._next_button.focus_mode, Control.FOCUS_ALL, "the Next button is focusable")
	assert_eq(pod.get_viewport().gui_get_focus_owner(), pod._next_button,
		"Next is focused for keyboard / gamepad")
	# _ready skips the decorative scenery under headless (pure dressing), so drive it
	# directly to exercise the mesh-extraction + MultiMesh build paths and confirm
	# every focal-area decoration lands (trees, bushes, crowd).
	pod._build_scenery()
	# Trees + bushes go through the shared Foliage fields (trees a BillboardField,
	# bushes a TreeMeshField), so read their renderer-independent instance_positions
	# mirror (headless has no MultiMesh buffer). The crowd is a plain
	# MultiMeshInstance3D placed directly.
	for node_name in ["Trees", "Bushes"]:
		var field := pod.get_node_or_null(node_name)
		assert_not_null(field, "scenery builds a %s field" % node_name)
		assert_gt(field.instance_positions.size(), 0, "%s has placed instances" % node_name)
	var crowd := pod.get_node_or_null("Crowd") as MultiMeshInstance3D
	assert_not_null(crowd, "scenery builds a Crowd MultiMesh")
	assert_gt(crowd.multimesh.instance_count, 0, "Crowd has placed instances")

	# Routing contract (regression guard): the podium must build its foliage through
	# the shared Foliage fields, NOT a hand-rolled MultiMesh at the mesh's native GLB
	# size (the bug this replaced). The bush field is always the 3D TreeMeshField;
	# the tree field is always a BillboardField.
	var bushes := pod.get_node_or_null("Bushes")
	assert_true(bushes is TreeMeshField, "podium bushes route through the shared bush field")
	var trees := pod.get_node_or_null("Trees")
	assert_true(trees is BillboardField, "podium trees use the shared billboard field")
	# Scale contract: the bush field is normalized by the SAME routine + config the
	# rest of the game uses (never left at native GLB size). Asserts the routing, not a
	# tunable height — retuning cfg.bush_height_m moves both sides together.
	var expect := TreeMeshField.uniform_scale_for(Foliage.bush_mesh(), Config.data.bush_height_m)
	assert_almost_eq(bushes.instance_scale, expect, 0.0001,
		"podium bushes use the shared Foliage scale normalization, not native size")


func test_podium_camera_points_at_the_player_car_off_pole() -> void:
	# The podium camera always frames the PLAYER's car, even when they didn't win —
	# here the player is P2 (on the left step), so the camera must aim at that car,
	# not the centre P1 step. Uses opaque catalogue ids (iterating the roster is the
	# code's contract, not a dependency on any one entry).
	var ids: Array = []
	for entry in CarLibrary.all():
		ids.append(String(entry.get("id", "")))
		if ids.size() >= 3:
			break
	assert_gt(ids.size(), 1, "roster has enough cars to stage a podium")
	RallySession._last_result = {
		"placed": 2, "completed": true, "combined_ms": 65000, "dnf": false,
		"standings": [
			{"name": "Rival 1", "car_id": ids[0], "combined_ms": 60000, "dnf": false, "is_player": false, "placed": 1},
			{"name": "You", "car_id": ids[min(1, ids.size() - 1)], "combined_ms": 65000, "dnf": false, "is_player": true, "placed": 2},
		],
	}
	var pod: Node3D = load("res://podium.tscn").instantiate()
	add_child_autofree(pod)
	await get_tree().process_frame
	assert_true(is_instance_valid(pod._player_car), "the player's car is tracked among the podium props")
	# The camera's -Z looks at its target; confirm that ray points at the player car
	# (left step, x < 0), not the centre P1 step.
	var cam: Camera3D = pod._camera
	var to_player: Vector3 = (pod._player_car.global_position - cam.global_position).normalized()
	var fwd := -cam.global_transform.basis.z.normalized()
	assert_gt(fwd.dot(to_player), 0.9, "the camera looks toward the player's (off-pole) car")
	# Low and close: below the player car (looking up) and nearer than the old wide shot.
	assert_lt(cam.global_position.y, pod._player_car.global_position.y,
		"the camera sits below the car so it looks up at it")


func test_podium_sequence_reveals_leaderboard_then_car() -> void:
	# A top-3 win reveals PODIUM -> LEADERBOARD -> CAR_REVEAL. Per-event upgrades are
	# revealed on the standings screens now, so the podium has no upgrade stage even
	# though the result still records the won upgrade ids.
	var driven: Dictionary = _save.grant_car("fx_awd")
	var driven_id := int(driven["instance_id"])
	RallySession._last_result = {
		"placed": 1, "completed": true, "combined_ms": 60000, "dnf": false,
		"rally_name": "Coastal Sprint", "game_won": false,
		"car_reward": "fx_rwd_coupe", "car_reward_is_new": true,
		"upgrades": ["fx_turbo_small", "fx_aero"],  # recorded, but NOT revealed here
		"car_instance_id": driven_id,
		"standings": [
			{"name": "You", "combined_ms": 60000, "dnf": false, "is_player": true, "placed": 1},
			{"name": "Rival 1", "combined_ms": 70000, "dnf": false, "is_player": false, "placed": 2},
			{"name": "Rival 2", "combined_ms": -1, "dnf": true, "is_player": false, "placed": -1},
		],
	}
	var pod: Node3D = load("res://podium.tscn").instantiate()
	add_child_autofree(pod)
	await get_tree().process_frame
	# CHANGED DELIBERATELY: the podium no longer reveals the won car. That beat moved to
	# HQ's present box, which the player has to open (hq.gd::_enter_present_box) — the
	# slot-machine-and-turntable version happened on the results screen, away from the
	# garage the car actually arrives in.
	assert_eq(pod._stages,
		[pod.Stage.PODIUM, pod.Stage.LEADERBOARD, pod.Stage.STARS] as Array[int],
		"the podium reveals podium, leaderboard and stars — the car is revealed at HQ")

	# Next -> the leaderboard.
	pod._on_next()
	await get_tree().process_frame
	assert_eq(pod._stage, pod.Stage.LEADERBOARD, "Next from the podium shows the leaderboard")
	var lb := _label_texts(pod)
	assert_string_contains(lb, "RIVAL 1", "the leaderboard lists the opponent field")
	assert_string_contains(lb, "WRECKED", "a DNF opponent reads as WRECKED on the leaderboard")

	# Next -> the stars beat (resolves instantly headless), which is now the LAST stage.
	pod._on_next()
	await get_tree().process_frame
	assert_eq(pod._stage, pod.Stage.STARS, "Next from the leaderboard shows the stars beat")
	assert_eq(pod._next_button.text, "CONTINUE TO HQ", "the final stage's button returns to HQ")


# A DNF in the OPENING rally still completes it (todo/opening-rally.md), so the podium must
# not tell the player it "stays incomplete" — they are about to be shown a map that says
# otherwise. The ordinary DNF keeps the honest wording.
func test_a_dnf_that_still_completes_does_not_claim_otherwise() -> void:
	RallySession._last_result = {"placed": -1, "completed": true, "combined_ms": -1,
		"dnf": true, "rally_name": "Opener"}
	var pod: Node3D = load("res://podium.tscn").instantiate()
	add_child_autofree(pod)
	await get_tree().process_frame
	var text := _label_texts(pod)
	assert_string_contains(text, "DNF", "it still says the run ended in a DNF")
	assert_false(text.contains("STAYS INCOMPLETE"),
		"but does not claim a completion that was recorded did not happen")


func test_an_ordinary_dnf_still_reads_as_incomplete() -> void:
	RallySession._last_result = {"placed": -1, "completed": false, "combined_ms": -1,
		"dnf": true, "rally_name": "Ordinary"}
	var pod: Node3D = load("res://podium.tscn").instantiate()
	add_child_autofree(pod)
	await get_tree().process_frame
	assert_string_contains(_label_texts(pod), "INCOMPLETE",
		"a DNF that completed nothing says so")


# --- The present-box car reveal ----------------------------------------------
# A won car is revealed at HQ, in a box the player must open. The rally GRANTS the car and
# hands HQ the instance; HQ opens on the box and holds the player there until they open it.

func test_a_won_car_opens_hq_on_a_forced_present_box() -> void:
	var won: Dictionary = _save.grant_car("fx_rwd_coupe")
	var won_id := int(won["instance_id"])
	RallySession.pending_car_reveal_instance_id = won_id
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.CARPARK, "HQ opens on the car park, not the garage")
	assert_eq(hq._carpark_mode, hq.CarparkMode.PRESENT, "in present-box mode")
	assert_eq(RallySession.pending_car_reveal_instance_id, -1,
		"the hand-off is one-shot — cleared so it cannot replay on the next boot")

	# FORCED: Back does nothing while the box is shut, and its button is hidden.
	assert_false(hq._car_back_button.visible, "the Back button is hidden while the box is shut")
	hq._car_back()
	assert_eq(hq._carpark_mode, hq.CarparkMode.PRESENT, "Back cannot leave an unopened box")

	# Opening it reveals the car and hands back a way out.
	hq._on_start_pressed()
	await get_tree().process_frame
	assert_true(hq._present_opened, "the box is open")
	assert_eq(_save.selected_instance_id(), won_id, "the won car becomes the selected car")
	assert_true(hq._car_back_button.visible, "and Back returns once it is open")
	hq._car_back()
	assert_eq(hq._view, hq.View.GARAGE, "leaving the opened box lands in the garage")


# The car-park panel carries the "Open it" button, and it is welded to _markers[_focus]
# (hq._car_panel_xform). Entering the present beat clears the lineup, which frees every
# marker — so without a bay of its own the panel had no anchor at all, WorldPanel.place
# early-returned on the null transform, and the box came up with no visible way to open it
# on a screen the player is forced through.
#
# Asserted as "the panel is anchored, and opening the box does not move it" rather than
# against authored offsets: every number involved is a look tunable.
func test_the_present_box_panel_is_anchored_before_it_is_opened() -> void:
	var won: Dictionary = _save.grant_car("fx_rwd_coupe")
	RallySession.pending_car_reveal_instance_id = int(won["instance_id"])
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	assert_eq(hq._carpark_mode, hq.CarparkMode.PRESENT, "setup: the box is up")
	var shut: Variant = hq._car_panel_xform()
	assert_true(shut is Transform3D,
		"the panel has an anchor while the box is still shut — the Open button rides on it")

	hq._on_start_pressed()
	await get_tree().process_frame
	var opened: Variant = hq._car_panel_xform()
	assert_true(opened is Transform3D, "and still has one once the car is revealed")
	# The whole point: the Open button and the car detail that replaces it are read at the
	# same place and the same angle, so the panel does not jump when the lid comes off.
	assert_eq(opened, shut, "opening the box does not move the panel")


# The car is granted by the rally, NOT by opening the box — so a player who quits before
# opening it still owns what they won. The box is a presentation, not a transaction.
func test_the_present_box_only_presents_a_car_already_owned() -> void:
	var owned_before: int = (_save.profile["cars"] as Array).size()
	var won: Dictionary = _save.grant_car("fx_rwd_coupe")
	RallySession.pending_car_reveal_instance_id = int(won["instance_id"])
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_start_pressed()
	await get_tree().process_frame
	assert_eq((_save.profile["cars"] as Array).size(), owned_before + 1,
		"opening the box mints nothing — the rally already granted the car")


# A stale hand-off (a car that no longer exists) must not strand the player in a forced
# screen with nothing in it.
func test_a_stale_car_reveal_hand_off_is_ignored() -> void:
	RallySession.pending_car_reveal_instance_id = 999999
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	assert_ne(hq._carpark_mode, hq.CarparkMode.PRESENT,
		"an instance that does not exist opens no box")


# --- Podium stars beat (todo/star-economy.md) --------------------------------
# The beat shows TWO different numbers: gold stars = the rally's rating at the player's
# best-ever placement, caption = what the ledger actually moved by. They diverge on a
# re-win, and these tests pin that split rather than any particular star count.

func _podium_with_stars(star_rating: int, stars_gained: int) -> Node3D:
	RallySession._last_result = {
		"placed": 1, "completed": true, "combined_ms": 60000, "dnf": false,
		"rally_name": "Shakedown", "car_reward": "", "upgrades": [],
		"star_rating": star_rating, "stars_gained": stars_gained,
		"standings": [
			{"name": "You", "combined_ms": 60000, "dnf": false, "is_player": true, "placed": 1},
		],
	}
	var pod: Node3D = load("res://podium.tscn").instantiate()
	add_child_autofree(pod)
	await get_tree().process_frame
	pod._enter_stage(pod.Stage.STARS)
	await get_tree().process_frame
	return pod


func test_the_stars_beat_lights_the_rallys_rating_in_gold() -> void:
	var rating := RallyLibrary.stars_for_placement(1)
	var pod: Node3D = await _podium_with_stars(rating, rating)
	assert_true(pod._stars_panel.visible, "the stars card is shown on the STARS stage")
	assert_eq(pod._star_row.earned, rating, "gold star count is the rally's rating")
	assert_eq(pod._star_row.total, RallyLibrary.MAX_STARS_PER_RALLY,
		"the row always shows the full three, so a miss reads as a miss")
	assert_true(pod._reveal_done, "the reveal resolves instantly under headless")
	assert_true(pod._next_button.visible, "Next is available once the stars land")


func test_the_stars_beat_reports_what_was_banked_not_the_rating() -> void:
	# The bug this split exists to prevent: the gold row shows the rally's best-ever RATING,
	# so it must never be read as a claim about what this run banked. Now that every finish
	# pays, the case where they diverge is a run that did not place at all (a DNF) on a rally
	# already rated — the row stays gold, the caption must not claim a gain.
	var rating := RallyLibrary.stars_for_placement(1)
	var pod: Node3D = await _podium_with_stars(rating, 0)
	assert_eq(pod._star_row.earned, rating, "the rating is still shown in gold")
	assert_string_contains(_label_texts(pod), "NO STARS",
		"banking nothing says so rather than claiming a gain")
	assert_false(pod._star_caption.text.contains("+"),
		"and never renders as a '+' gain")


func test_the_stars_beat_shows_a_gain_when_the_ledger_moved() -> void:
	var pod: Node3D = await _podium_with_stars(RallyLibrary.stars_for_placement(1), 1)
	assert_string_contains(_label_texts(pod), "+1 STAR", "a positive delta reads as a gain")


func test_the_stars_beat_runs_with_no_stars_won() -> void:
	# Off the podium: three dim stars and an honest line, not a skipped stage.
	var pod: Node3D = await _podium_with_stars(0, 0)
	assert_true(pod._stars_panel.visible, "the card still shows")
	assert_eq(pod._star_row.earned, 0, "no stars are lit")
	assert_true(pod._reveal_done, "a zero-star beat is immediately steppable")
	assert_true(pod._next_button.visible, "Next is not gated behind an empty reveal")


func test_the_stars_beat_quotes_the_spendable_balance() -> void:
	_save.award_stars(7)
	var pod: Node3D = await _podium_with_stars(RallyLibrary.stars_for_placement(1), 0)
	assert_string_contains(_label_texts(pod), "7 IN THE BANK",
		"the caption ends with the spendable balance")
	# And no denominator: stars are renewable and spendable, so there is no maximum.
	assert_false(pod._star_caption.text.contains("/"),
		"the balance is shown bare, with no 'x of N' denominator")


func test_podium_dnf_sequence_has_no_reward_stages() -> void:
	# A DNF earns no car and no upgrade, so only the podium + leaderboard show.
	RallySession._last_result = {
		"placed": -1, "completed": false, "combined_ms": -1, "dnf": true,
		"rally_name": "Coastal Sprint", "car_reward": "", "upgrades": [],
		"standings": [
			{"name": "Rival 1", "combined_ms": 70000, "dnf": false, "is_player": false, "placed": 1},
			{"name": "You", "combined_ms": -1, "dnf": true, "is_player": true, "placed": -1},
		],
	}
	var pod: Node3D = load("res://podium.tscn").instantiate()
	add_child_autofree(pod)
	await get_tree().process_frame
	assert_eq(pod._stages,
		[pod.Stage.PODIUM, pod.Stage.LEADERBOARD, pod.Stage.STARS] as Array[int],
		"a DNF queues no reward reveals, but the stars beat still runs (0 stars is feedback)")
	assert_string_contains(_label_texts(pod), "DNF", "the headline reads as a DNF")


func test_run_scene_fields_the_bound_session_car() -> void:
	var owned: Dictionary = _save.grant_car("fx_awd")
	var id := int(owned["instance_id"])
	RallySession.start_rally(RallyLibrary.by_id("fx_open"), owned, true)
	# Boot the run scene with a session active: world.gd fields the OwnedCar.
	SceneHelpers.minimal_world()
	var scene: Node3D = load("res://main.tscn").instantiate()
	add_child_autofree(scene)
	await get_tree().process_frame
	var car: VehicleBody3D = scene.get_node("Car")
	assert_eq(car.damage.instance_id, id, "the car's damage model is bound to the fielded instance")
	assert_eq(car.current_car_name(), "Fixture AWD", "the owned car's model is fielded, not the default")


func test_first_run_start_opens_starter_pick_then_grants_first_car() -> void:
	# This flow is driven by hq.gd's STARTER_MODEL_IDS constant, which hardcodes real
	# catalogue ids (mx5/focus/twingo) — it can't be pointed at the synthetic fixtures
	# without touching production code, so restore the real catalogue for this one test.
	CarFixtures.restore()
	# Likewise the OPENING RALLY the picked starter drops the player into is found by
	# matching a real rally's prize_car against one of those hardcoded ids — none of
	# RallyFixtures' roster awards a starter model — so restore the shipped rally roster
	# too, or picking a starter would have no opening rally to start.
	RallyLibrary.reset()
	_reset_to_first_run()
	# Fresh profile has no starter picked and an empty garage.
	assert_false(bool(_save.profile.get("starter_picked", false)), "fresh profile: no starter yet")
	assert_eq(_save.profile["cars"].size(), 0, "fresh profile: empty garage")
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	await _await_lineup(hq)
	assert_eq(hq._view, hq.View.CARPARK, "first run lands in the car park")
	assert_eq(hq._carpark_mode, hq.CarparkMode.STARTER, "in starter-pick mode")
	assert_eq(hq._eligible.size(), hq.STARTER_MODEL_IDS.size(),
		"one parked starter preview per STARTER_MODEL_IDS entry")
	# Pick whichever starter is parked first — the flow, not a particular car.
	hq._focus = 0
	hq._carpark_ui._focus_changed(true)
	var picked_id := String(hq._eligible[0].get("model_id", ""))
	assert_ne(picked_id, "", "the parked preview names its model")
	# Confirming the pick now DRIVES — the player is put straight into the rally that
	# awards the car they chose, before the map is ever shown (todo/opening-rally.md).
	# Kept out of the scene change so the assertion is about the flow, not the load.
	RallySession.auto_load_scenes = false
	await hq._on_start_pressed()
	assert_true(bool(_save.profile["starter_picked"]), "starter recorded")
	assert_eq(String(_save.profile["starter_model_id"]), picked_id)
	var cars: Array = _save.profile["cars"]
	assert_eq(cars.size(), 1, "exactly one car granted")
	assert_eq(String(cars[0]["model_id"]), picked_id, "the granted car is the picked starter")
	assert_false(_save.car_needs_repair(int(cars[0]["instance_id"])),
		"the chosen starter arrives in one piece")
	assert_eq(_save.selected_instance_id(), int(cars[0]["instance_id"]), "the starter is selected")
	# The picker no longer lands in the garage: it starts the player's OPENING rally, so
	# the starter choice decides where on the map their career begins.
	assert_true(RallySession.is_active(), "picking a starter starts a rally")
	assert_eq(String(RallySession._rally.get("id", "")),
		RallyLibrary.opening_rally_id_for(picked_id),
		"and it is the rally that awards the car they picked")
	assert_ne(hq._view, hq.View.GARAGE, "the picker does not drop them in the garage")
	RallySession.abandon()


func test_returning_player_start_goes_straight_to_garage() -> void:
	# before_each already granted a starter (a returning player).
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	assert_ne(hq._carpark_mode, hq.CarparkMode.STARTER, "not in starter-pick mode")
	assert_eq(hq._view, hq.View.GARAGE, "existing player skips the picker")


func test_starter_pick_back_returns_to_title() -> void:
	_reset_to_first_run()
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	await _await_lineup(hq)
	hq._car_back()
	assert_ne(hq._carpark_mode, hq.CarparkMode.STARTER, "starter mode cleared on back")
	assert_eq(hq._view, hq.View.EXTERIOR, "back from the picker returns to the title")
	assert_eq(_save.profile["cars"].size(), 0, "backing out grants nothing")


func test_engine_swap_flow_exchanges_engines() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var a: Dictionary = _save.selected_car()
	var b: Dictionary = _save.grant_car("fx_rwd_coupe")
	var stock_b: String = CarLibrary.by_id("fx_rwd_coupe")["engine"]
	_unlock_engine_swaps()
	hq._enter_engine_swap()
	await _await_lineup(hq)
	assert_true(hq._eligible.size() >= 1, "swap lineup lists the other owned car(s)")
	hq._selected_instance_id = int(b["instance_id"])
	hq._on_start_pressed()  # pops the confirm; OK commits
	hq._on_swap_confirmed()
	assert_eq(String(_save.get_car(int(a["instance_id"])).get("swapped_engine", "")), stock_b,
		"selected car received the target's engine")


# A damaged car no longer blocks a swap: with a token owned, confirming a swap
# exchanges engines and leaves the damaged car's HP untouched (no repair coupling).
func test_engine_swap_works_on_a_damaged_car_and_leaves_hp() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var a: Dictionary = _save.selected_car()
	var a_id := int(a["instance_id"])
	var b: Dictionary = _save.grant_car("fx_rwd_coupe")
	var stock_b: String = CarLibrary.by_id("fx_rwd_coupe")["engine"]
	_save.apply_damage(a_id, 1.0)  # lift car below 100% — no longer a blocker
	var hp_before := float(_save.get_car(a_id)["hp"])
	_unlock_engine_swaps()
	hq._enter_engine_swap()
	await _await_lineup(hq)
	# The damaged lift car still has a target (no car excluded on health).
	hq._selected_instance_id = int(b["instance_id"])
	hq._carpark_ui._focus_changed()
	assert_false(hq._start_button.disabled, "the partner is never excluded on health")
	assert_false(hq._car_warning_label.visible, "no repair-cost warning in swap mode anymore")
	# Confirm the swap: OK exchanges engines and spends the token.
	hq._select_swap_target()
	hq._on_swap_confirmed()
	assert_eq(String(_save.get_car(a_id).get("swapped_engine", "")), stock_b,
		"the damaged car received the partner's engine")
	assert_almost_eq(float(_save.get_car(a_id)["hp"]), hp_before, 0.001,
		"the swap left the damaged car's HP unchanged")


func test_swap_preview_visible_only_in_swap_mode() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	# Needs >=2 owned full-health cars so a swap target exists (before_each already
	# granted the starter car for the lift; grant a second, healthy fixture car).
	_save.grant_car("fx_rwd_coupe")
	hq._enter_engine_swap()
	await _await_lineup(hq)
	assert_true(hq._eligible.size() >= 1, "swap lineup lists the other owned car(s)")
	hq._carpark_ui._focus_changed(true)
	assert_true(hq._swap_preview_label.visible, "preview shows in swap mode")
	assert_string_contains(hq._swap_preview_label.text, "hp/tonne", "preview names the unit")
	# Leaving swap mode for the normal car-select hides it.
	hq._carpark_mode = hq.CarparkMode.RALLY
	hq._carpark_ui._focus_changed(true)
	assert_false(hq._swap_preview_label.visible, "preview hidden outside swap mode")


func test_display_name_reflects_swap() -> void:
	# EngineSwap.display_name looks the swapped engine's layout up in EngineLibrary by id
	# and upper-cases it into a prefix. Driven off the synthetic fixture engines, with the
	# expected prefix derived from the swapped engine's own `layout` field.
	var swapped: Dictionary = EngineLibrary.by_id("fx_v8")
	var prefix := String(swapped["layout"]).to_upper()
	assert_eq(EngineSwap.display_name({"name": "Fixture Roadster", "engine": "fx_i4"},
		{"swapped_engine": "fx_v8"}), "%s Fixture Roadster" % prefix,
		"swapped owned car shows the swapped engine's layout as a prefix")
	assert_eq(EngineSwap.display_name({"name": "Fixture Roadster", "engine": "fx_i4"}, {}),
		"Fixture Roadster", "an unswapped car keeps its plain name")


func test_tuning_sliders_are_all_the_same_length() -> void:
	# Every handling-axis row's slider must line up to the same width, regardless of how
	# long each row's value label is (the fixed 180px label column guarantees it).
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_lift()
	hq._open_lift_page(hq.LiftPage.TUNE)
	await get_tree().process_frame
	await get_tree().process_frame
	var widths: Array = []
	for axis in TuningLibrary.AXES:
		widths.append((hq._tune_panel._sliders[axis] as HSlider).size.x)
	for w in widths:
		assert_almost_eq(float(w), float(widths[0]), 0.5, "all tuning sliders share the same length")





# Engine swapping is a star-gated CAPABILITY (RallyLibrary.ENGINE_SWAP_UNLOCK_RALLY): tokens
# drop and bank from the start but cannot be SPENT until that special is won. Tests below
# exercise the token/partner rules, so they open the capability gate first — otherwise the
# lock (correctly) masks everything else. `_engine_swap_lock_test` covers the locked state.
func _unlock_engine_swaps() -> void:
	_save.record_podium_rally(RallyLibrary.ENGINE_SWAP_UNLOCK_RALLY, 60_000, 1)
func test_garage_focus_is_unchanged_by_menu_nav_while_a_modal_is_open() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	var focus_before: int = hq._garage_focus

	ConfirmPopup.open(hq, "Busy", "Something is on screen", [{"label": "OK", "callback": Callable()}], 0)
	await get_tree().process_frame

	for action in ["menu_left", "menu_right", "menu_select"]:
		var ev := InputEventAction.new()
		ev.action = action
		ev.pressed = true
		hq._unhandled_input(ev)

	assert_eq(hq._garage_focus, focus_before,
		"none of left/right/select reach the garage cursor while the modal is up")


# The same hole from the input side: a station row must not act on a keypress while a
# modal owns the screen. The popup's focused button normally consumes it first, but
# that relies on the popup holding focus — when it doesn't, the press fell through to
# the garage row and fired a second action behind the popup.
func test_the_garage_row_ignores_select_while_a_modal_is_open() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	assert_eq(hq._view, hq.View.GARAGE, "setup: on the garage row, cursor on Career")
	var seated: int = hq._garage_focus

	ConfirmPopup.open(hq, "Busy", "Something is on screen", [{"label": "OK", "callback": Callable()}], 0)
	await get_tree().process_frame
	var press := InputEventAction.new()
	press.action = "menu_select"
	press.pressed = true
	hq._unhandled_input(press)

	# Career (the seated action) would have flown to the map table; nothing moved.
	assert_eq(hq._view, hq.View.GARAGE,
		"select did not reach the garage row while the modal was up")
	assert_eq(hq._garage_focus, seated, "and the cursor did not move either")


func test_detune_prompt_change_upgrades_opens_navigable_popup_without_swap() -> void:
	# The detune-to-enter prompt offers "Change Upgrades…" as an alternative to detuning:
	# it opens a popup hosting the UpgradesGrid for the focused car, keyboard/gamepad
	# navigable, with NO engine-swap action (the swap flow would change the HQ view).
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var id := int(_save.selected_car().get("instance_id", -1))
	hq._selected_instance_id = id
	hq._eligible = [_save.get_car(id)]
	hq._focus = 0
	hq._carpark_ui._show_upgrades_popup(_save.get_car(id))
	await get_tree().process_frame
	assert_true(hq._carpark_ui._upgrades_popup.visible, "the popup is shown")
	assert_not_null(hq._carpark_ui._upgrades_popup_menu, "the popup hosts an UpgradesGrid")
	assert_not_null(hq._carpark_ui._upgrades_popup_menu.first_control(), "has a focusable tile (navigable)")
	assert_false(hq._carpark_ui._upgrades_popup_menu._on_swap.is_valid(),
		"no engine-swap action is wired here — the swap flow would change the HQ view")
	hq._carpark_ui._close_upgrades_popup()
	assert_false(hq._carpark_ui._upgrades_popup.visible, "Done / back closes the popup")


func test_carpark_upgrades_popup_renders_with_world_space_menus() -> void:
	# The Change-Upgrades modal must be ON SCREEN whichever host the car-park overlay is
	# using. With world_space_menus on, the car-park tree migrates into a 3D WorldPanel and
	# its flat CanvasLayer is hidden (WorldPanelHost.sync) — a modal parented to that layer
	# was fully built and navigable but invisible, so "Change Upgrades" on the "Too powerful"
	# prompt looked like it just dropped the player back to car-select.
	Config.data.world_space_menus = true
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var id := int(_save.selected_car().get("instance_id", -1))
	hq._selected_instance_id = id
	hq._eligible = [_save.get_car(id)]
	hq._focus = 0
	hq.go_to(hq.View.CARPARK)
	await get_tree().process_frame
	assert_false(hq._car_layer.visible, "precondition: the flat car-park layer stands down")
	hq._carpark_ui._show_upgrades_popup(_save.get_car(id))
	await get_tree().process_frame
	assert_true(hq._carpark_ui._upgrades_popup.is_visible_in_tree(),
		"the upgrades modal is actually on screen, not on the hidden flat car-park layer")
	assert_not_null(hq._carpark_ui._upgrades_popup_menu.first_control(),
		"and its options are focusable (a hidden tree has no focusable controls)")


func test_carpark_upgrades_modal_sits_below_a_confirm_popup() -> void:
	# The Change-Upgrades modal HOSTS ConfirmPopups (the Auto-Upgrade row opens one), so its
	# CanvasLayer must be strictly BELOW ConfirmPopup's. On a tie the confirm can be drawn
	# under this modal's opaque panel while its own full-screen MOUSE_FILTER_STOP dim goes on
	# swallowing clicks — the menu reads as frozen. Compares the two layers against each
	# other, never against a pinned number.
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var id := int(_save.selected_car().get("instance_id", -1))
	hq._selected_instance_id = id
	hq._eligible = [_save.get_car(id)]
	hq._focus = 0
	hq._carpark_ui._show_upgrades_popup(_save.get_car(id))
	await get_tree().process_frame
	var modal_layer := hq._carpark_ui._upgrades_popup.get_parent() as CanvasLayer
	assert_not_null(modal_layer, "the modal is hosted on its own CanvasLayer")
	var confirm := ConfirmPopup.open(hq, "Fixture", "body",
		[{"label": "Ok", "callback": Callable()}])
	assert_not_null(confirm, "a confirm can open over the modal")
	assert_lt(modal_layer.layer, (confirm as CanvasLayer).layer,
		"the upgrades modal draws BELOW any confirm popup opened over it")
	confirm.trigger_back()



func test_migratable_layers_gain_no_runtime_children() -> void:
	# THE STRUCTURAL NET for the class of bug that made the Change-Upgrades modal invisible.
	# A CanvasLayer managed by a WorldPanelHost holds exactly one thing: the screen tree it
	# migrates. Anything else parented there renders nowhere as soon as world menus are on
	# (WorldPanelHost stands the flat layer down), and nothing fails — so assert it directly,
	# in flat mode where every entry point is easy to drive.
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var managed: Dictionary = {}
	for key in ["car", "lift", "title", "garage"]:
		var host: WorldPanelHost = hq._panel_host(key)
		assert_not_null(host, "setup: the '%s' screen has a panel host" % key)
		if host != null:
			managed[key] = host
	# Drive every path that creates UI at runtime over a station.
	var id := int(_save.selected_car().get("instance_id", -1))
	hq._selected_instance_id = id
	hq._eligible = [_save.get_car(id)]
	hq._focus = 0
	hq._carpark_ui._show_upgrades_popup(_save.get_car(id))
	hq._carpark_ui._show_over_limit_prompt(_save.get_car(id))
	hq._show_android_app_notice()
	hq._challenge_ui._open_challenge_overlay()
	hq._enter_lift()
	await get_tree().process_frame
	for key in managed:
		var host: WorldPanelHost = managed[key]
		for child in host.flat_layer.get_children():
			assert_eq(child, host.tree as Node,
				("'%s' is on the migratable '%s' layer — it will render nowhere with world menus "
				+ "on. Modals belong on their own layer (MenuPage.open_modal / ConfirmPopup).")
				% [child.name, key])


func test_leaving_a_station_releases_focus_on_both_hosts() -> void:
	# `get_viewport().gui_release_focus()` is answered by the viewport HQ sits in, so it never
	# reached a migrated station's SubViewport: a button on the screen you just left kept focus
	# and went on swallowing arrow keys / Enter in the next, spatially-navigated station.
	Config.data.world_space_menus = true
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_lift()
	await get_tree().process_frame
	var host: WorldPanelHost = hq._panel_host("lift")
	assert_not_null(host, "setup: the lift has a panel host")
	if host == null or host.panel == null:
		return
	assert_true(host.is_world(), "setup: the lift menu is on its panel")
	var sub := host.panel.viewport()
	var buttons := host.tree.find_children("*", "Button", true, false)
	assert_gt(buttons.size(), 0, "setup: the lift page has a button to focus")
	(buttons[0] as Button).grab_focus()
	await get_tree().process_frame
	assert_not_null(sub.gui_get_focus_owner(), "setup: the panel's own viewport holds focus")
	hq.go_to(hq.View.GARAGE)
	await get_tree().process_frame
	assert_null(sub.gui_get_focus_owner(),
		"leaving the station drops focus inside the panel, not just in the main viewport")


# --- Android app boot notice (features/menus.md → "Android app notice") ------

func _press(action: String) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = action
	e.pressed = true
	return e


# A normal boot outside an Android browser never shows the notice: the headless test
# runner is not a web build, so the platform gate must leave the title untouched.
func test_boot_shows_no_android_notice_outside_android_web() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	assert_null(hq._android_notice_layer, "no Android-app notice off Android web")
	assert_true(hq._title_layer.visible, "the title overlay is shown as normal")


# The notice overlay itself: it hides the title while up (so the two MenuNavs can't
# fight for focus), seats the cursor on a real button for keyboard/gamepad players,
# and back (Esc / gamepad B) dismisses it, restoring the title and its focus.
func test_android_notice_is_navigable_and_back_dismisses() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	hq._show_android_app_notice()
	assert_not_null(hq._android_notice_layer, "the notice overlay is up")
	assert_false(hq._title_layer.visible, "the title hides while the notice is up")
	await get_tree().process_frame  # deferred MenuNav focus grab
	var focused := hq.get_viewport().gui_get_focus_owner()
	assert_true(focused is Button and hq._android_notice_layer.is_ancestor_of(focused),
		"the cursor lands on one of the notice's buttons")
	# Showing twice must not stack a second overlay.
	var layer: CanvasLayer = hq._android_notice_layer
	hq._show_android_app_notice()
	assert_eq(hq._android_notice_layer, layer, "a second show reuses the open notice")
	# Back dismisses via the notice's MenuNav on_back.
	var nav: MenuNav = null
	for child in layer.get_child(0).get_children():
		if child is MenuNav:
			nav = child
	assert_not_null(nav, "the notice has MenuNav attached")
	nav._unhandled_input(_press("menu_back"))
	assert_null(hq._android_notice_layer, "back dismisses the notice")
	assert_true(hq._title_layer.visible, "dismissing restores the title overlay")
	assert_eq(hq._title_focus, hq._title_start_index(), "the title cursor is back on Start")


func test_android_notice_stands_down_a_world_hosted_title() -> void:
	# The notice must stand the title down on WHICHEVER host is holding it. With world menus
	# on the title tree has migrated into a 3D WorldPanel and the flat layer is already hidden
	# and empty, so the old `_title_layer.visible = false` stood nothing down: the notice drew
	# over a live title menu and both MenuNavs answered the same keypress. Asserts the tree's
	# on-screen-ness (MenuNav's own host-agnostic predicate), never a particular layer.
	Config.data.world_space_menus = true
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	assert_true(MenuNav.is_on_screen(hq._title_root),
		"precondition: the title menu is on screen at the exterior station")
	hq._show_android_app_notice()
	await get_tree().process_frame
	assert_not_null(hq._android_notice_layer, "the notice is up")
	assert_false(MenuNav.is_on_screen(hq._title_root),
		"the title menu is off screen while the notice owns it — on either host")
	hq._dismiss_android_app_notice()
	await get_tree().process_frame
	assert_true(MenuNav.is_on_screen(hq._title_root), "dismissing restores the title menu")
	assert_false(hq._title_layer.visible,
		"and the flat layer stays down — the world panel is the live host, not both")


# The final event used to skip straight to the podium. It now pauses on the SAME
# interstitial as every other event, carrying BOTH leaderboards — that stage's
# result and the overall standings — stacked on one page before it resolves.
func test_final_event_shows_both_leaderboards_before_proceeding() -> void:
	var owned := _first_owned_car()
	RallySession.start_rally(_any_rally(), owned, true)
	RallySession.report_event_result(1000, 0.0)   # event 1
	RallySession.continue_to_next_event()
	RallySession.report_event_result(1000, 0.0)   # event 2
	RallySession.continue_to_next_event()
	RallySession.report_event_result(1000, 0.0)   # event 3 (final)
	var s: Control = load("res://standings.tscn").instantiate()
	add_child_autofree(s)
	var text := _label_texts(s)
	assert_string_contains(text, UITheme.caps("STAGE 3 RESULT"),
		"the final event's own stage result is on the page")
	assert_string_contains(text, UITheme.caps(Standings.overall_heading(3)),
		"the cumulative standings are on the same page, naming all three stages")
	assert_eq(s._action_button.text, UITheme.caps("Next >"),
		"page 1 leads to the world board; the podium is one page further on")











# A stand-in for Cloud.leaderboard.submit_and_fetch: no network, no catalogue, no
# tunables — just the result shape the page reads.
func _fake_board(rank: int = 0, total: int = 12, signed_in: bool = false) -> Callable:
	return func(_key: String, _ms: int, _identity: Dictionary) -> Dictionary:
		var rows: Array = []
		for i in 3:
			rows.append({"placed": i + 1, "name": "RIVAL%d" % i, "car_name": "TEST CAR",
				"combined_ms": 50000 + i * 100, "dnf": false, "is_player": false})
		var mine: Dictionary = {}
		if rank >= 1:
			mine = {"placed": rank, "name": "TESTER", "car_name": "TEST CAR",
				"combined_ms": 60000, "dnf": false, "is_player": true}
		return {"ok": true, "error": "", "rows": rows, "total": total,
			"signed_in": signed_in, "player_rank": rank, "player_row": mine,
			"posted": rank >= 1}


func _global_page(fetch: Callable, opts: Dictionary = {}) -> GlobalStandings:
	var page := GlobalStandings.new()
	page.fetcher = fetch
	var base := {"stage_key": "test__0__abc__e1", "stage_number": 2, "time_ms": 60000,
		"car_name": "TEST CAR", "car_id": "test_car"}
	base.merge(opts, true)
	page.configure(base)
	add_child_autofree(page)
	return page


# Park the rally on the standings after a non-final stage, with a rival field, and
# return the built interstitial.
func _standings_after_stage_one() -> Control:
	var owned: Dictionary = _save.grant_car("fx_awd")
	RallySession.start_rally(RallyLibrary.by_id("fx_open"), owned, true)
	RallySession._opponent_field = [
		{"name": "Rival", "event_times_ms": [40000, 40000, 40000], "dnf": false,
			"combined_ms": 120000},
	]
	RallySession.report_event_result(50000)
	var sc: Control = load("res://standings.tscn").instantiate()
	add_child_autofree(sc)
	return sc


# EXIT 1 — the plain Continue. It must NOT resume the rally; it hands off to the
# global page, which owns the route onward.
func test_standings_continue_shows_the_global_page_before_resuming() -> void:
	var sc := _standings_after_stage_one()
	await get_tree().process_frame
	assert_eq(RallySession.phase(), RallySession.Phase.STANDINGS, "parked on the standings")

	sc._on_action()
	await get_tree().process_frame
	assert_not_null(sc._global_page, "Continue hands off to the global page")
	assert_eq(RallySession.phase(), RallySession.Phase.STANDINGS,
		"and does NOT resume the rally on the way past")
	assert_false(sc._root_box.visible,
		"page 2 replaces page 1's content rather than stacking over it")

	sc._global_page._on_continue()
	assert_eq(RallySession.phase(), RallySession.Phase.RUNNING,
		"page 2's Continue is what resumes the next stage")
	RallySession.abandon()
# THE WHOLE LADDER, asserted as a sequence rather than a press count: page 1 (local
# standings) -> page 2 (world standings) -> the rally. TWO rungs, not three.
#
# There used to be a third rung — a reveal card for the random per-event upgrade — and a
# sibling test asserting which order the two beats came in. Parts are won at their prize
# rally or bought with stars now, so nothing is drawn between stages and that rung is
# gone; this is the only ladder there is.
#
# continue_to_next_event() has exactly ONE call site (Standings._advance), and counting the
# phase transitions is what proves it is reached exactly once, at the end.
func test_the_standings_ladder_is_local_then_global_then_resume() -> void:
	var sc := _standings_after_stage_one()
	await get_tree().process_frame
	var resumes := [0]
	RallySession.phase_changed.connect(func(p: int) -> void:
		if p == RallySession.Phase.RUNNING:
			resumes[0] += 1)

	sc._on_action()
	await get_tree().process_frame
	assert_not_null(sc._global_page, "page 1 still leads to the world board")
	assert_eq(sc._global_page._continue_button.text, UITheme.caps("Continue to next stage >"),
		"and page 2 names the next stage")

	sc._global_page._on_continue()
	await get_tree().process_frame
	assert_eq(RallySession.phase(), RallySession.Phase.RUNNING, "page 2 resumes the rally")
	assert_eq(resumes[0], 1, "exactly once, with no third rung in between")
	RallySession.abandon()


# A signed-out player still sees the board, is told how many times are posted, and
# is offered a way in — nothing about being signed out blocks Continue.
func test_global_page_signed_out_offers_sign_in_and_still_continues() -> void:
	var page := _global_page(_fake_board(0, 12, false))
	await get_tree().process_frame
	assert_eq(page.state(), GlobalStandings.State.SIGNED_OUT, "signed out is its own state")
	assert_not_null(page._action_button, "the state carries an extra affordance")
	assert_string_contains(page._action_button.text.to_upper(), "SIGN IN",
		"which is the way in")
	assert_string_contains(_label_texts(page), "12 TIMES POSTED",
		"the total shows even signed out — it says whether the board is really empty")
	assert_false(page._continue_button.disabled, "Continue is live from the first frame")
	var advanced := [false]
	page.continued.connect(func() -> void: advanced[0] = true)
	page._continue_button.pressed.emit()
	assert_true(advanced[0], "and advancing is never gated on signing in")


# Signed in with no name chosen yet: the board reads, and the prompt is to pick a
# name rather than to sign in (§3 — the name is captured on first post).
func test_global_page_signed_in_without_a_name_prompts_for_one() -> void:
	_save.profile["username"] = ""
	var page := _global_page(_fake_board(0, 7, true))
	await get_tree().process_frame
	assert_eq(page.state(), GlobalStandings.State.NO_USERNAME,
		"signed in but nameless is its own state")
	assert_string_contains(page._action_button.text.to_upper(), "NAME",
		"the prompt is to choose a name, not to sign in")


# Any failure class at all — offline, timeout, 5xx, 429, unparseable — is one dim
# line, and the rally still advances. A lost board can never cost a player a rally.
func test_global_page_unavailable_still_advances() -> void:
	var page := _global_page(func(_k: String, _m: int, _i: Dictionary) -> Dictionary:
		return {"ok": false, "error": "offline"})
	await get_tree().process_frame
	assert_eq(page.state(), GlobalStandings.State.UNAVAILABLE, "a failed fetch is unavailable")
	assert_string_contains(_label_texts(page).to_upper(), "UNAVAILABLE",
		"which reads as one dim line")
	var advanced := [false]
	page.continued.connect(func() -> void: advanced[0] = true)
	page._continue_button.pressed.emit()
	assert_true(advanced[0], "Continue still resumes the rally")


# The name the board posts under is sanitised to the house style: uppercase,
# A-Z / 0-9 / space only, trimmed, and capped in length.
func test_username_sanitiser_enforces_the_house_rules() -> void:
	assert_eq(UsernamePopup.sanitize("  kangaroo "), "KANGAROO", "trimmed and uppercased")
	assert_eq(UsernamePopup.sanitize("k@ng#aroo!"), "KNGAROO", "illegal characters dropped")
	assert_eq(UsernamePopup.sanitize("a     b"), "A B", "runs of spaces collapse")
	assert_eq(UsernamePopup.sanitize("   "), "", "a name that filters away to nothing is empty")
	assert_lte(UsernamePopup.sanitize("ABCDEFGHIJKLMNOPQRSTUVWXYZ").length(),
		UsernamePopup.MAX_LEN, "a long name is capped")


# The chosen name round-trips through the profile, so the account menu and the
# board agree about who the player is.
func test_username_is_stored_on_the_profile() -> void:
	assert_eq(UsernamePopup.store("milk float"), "MILK FLOAT", "store returns the stored form")
	assert_eq(UsernamePopup.current(), "MILK FLOAT", "and current() reads it back")
	assert_eq(UsernamePopup.store("!!!"), "", "an unusable name is rejected")
	assert_eq(UsernamePopup.current(), "MILK FLOAT", "and leaves the existing one alone")


# REGRESSION (reported from the real game): the page rendered its heading and its
# Continue button with NOTHING in between — no rows, no total, not even the
# "unavailable" line. The body was built hidden by a staggered per-row reveal that
# then failed to un-hide it, and because that reveal was skipped headless
# (Platform.is_headless) NO test ever exercised the code the player actually ran.
#
# So this asserts the invariant directly, in every state: the body is never empty
# and never invisible. It fails against the reveal, and it does not care how the
# page chooses to animate — only that something is on screen.
func test_global_page_body_is_never_blank_in_any_state() -> void:
	var cases := {
		"signed out": _fake_board(0, 12, false),
		"posted": _fake_board(7, 40, true),
		"on the podium": _fake_board(2, 40, true),
		"empty board": func(_k: String, _m: int, _i: Dictionary) -> Dictionary:
			return {"ok": true, "error": "", "rows": [], "total": 0, "signed_in": true,
				"player_rank": 0, "player_row": {}, "posted": false},
		"unavailable": func(_k: String, _m: int, _i: Dictionary) -> Dictionary:
			return {"ok": false, "error": "offline"},
	}
	for label in cases:
		var page := _global_page(cases[label])
		await get_tree().process_frame
		var shown: Array[String] = []
		for l in page.find_children("*", "Label", true, false):
			var text := String((l as Label).text)
			assert_true((l as Label).is_visible_in_tree(),
				"%s: every body line the page builds is actually on screen (%s)" % [label, text])
			if not text.begins_with("GLOBAL"):
				shown.append(text)
		assert_gt(shown.size(), 0,
			"%s: the page renders SOMETHING between the heading and Continue" % label)


# REGRESSION: a signed-in player with no leaderboard name posts NOTHING, silently
# — the cloud layer degrades to a plain read on a blank name. So this prompt is
# the only thing that ever gets such a player onto the board, and it must be
# genuinely on screen (is_visible_in_tree, not merely built), focusable, and
# seated under the cursor. It must ALSO survive the board failing to load: the
# first player on a new board can be the one whose read fails, and gating the
# prompt on a successful fetch left them permanently unable to post.
func test_no_username_player_is_offered_a_visible_focusable_prompt() -> void:
	# A failed fetch returns no "signed_in" field — there was no answer to be had —
	# so the page falls back to asking Cloud. That means the player has to be
	# ACTUALLY signed in for this branch to be the scenario it claims to be;
	# `signed_in: true` in a fetcher result the failing branch never returns is not
	# a sign-in. Same stub test_account_menu.gd uses.
	var saved := {"uid": Cloud.auth.uid, "refresh": Cloud.auth.refresh_token}
	Cloud.auth.uid = "test_uid"
	Cloud.auth.refresh_token = "test_refresh"
	for label in ["board loaded", "board unavailable"]:
		_save.profile["username"] = ""
		var fetch: Callable = _fake_board(0, 5, true)
		if label == "board unavailable":
			fetch = func(_k: String, _m: int, _i: Dictionary) -> Dictionary:
				return {"ok": false, "error": "offline"}
		var page := _global_page(fetch)
		await get_tree().process_frame
		await get_tree().process_frame  # deferred focus grab settles
		var prompt: Button = page._action_button
		assert_not_null(prompt, "%s: the player is prompted to choose a name" % label)
		if prompt == null:
			continue
		assert_true(prompt.is_visible_in_tree(),
			"%s: the prompt is actually on screen, not just built" % label)
		assert_eq(prompt.focus_mode, Control.FOCUS_ALL,
			"%s: keyboard / gamepad can reach the prompt" % label)
		assert_eq(page.get_viewport().gui_get_focus_owner(), prompt,
			"%s: and the cursor starts on it" % label)
		assert_string_contains(prompt.text.to_upper(), "NAME",
			"%s: it asks for a name rather than a sign-in" % label)
	Cloud.auth.uid = String(saved["uid"])
	Cloud.auth.refresh_token = String(saved["refresh"])


# Answering the prompt posts the time THERE AND THEN — the player does not have
# to drive another stage for their name to take effect. The name is written where
# the cloud layer reads it from (the identity handed to submit_and_fetch).
func test_choosing_a_name_re_posts_the_time_immediately() -> void:
	_save.profile["username"] = ""
	var seen: Array = []
	var page := _global_page(func(_k: String, ms: int, identity: Dictionary) -> Dictionary:
		seen.append({"time_ms": ms, "name": String(identity.get("name", ""))})
		return {"ok": true, "error": "", "rows": [], "total": 0, "signed_in": true,
			"player_rank": 0, "player_row": {}, "posted": false})
	await get_tree().process_frame
	assert_eq(page.state(), GlobalStandings.State.NO_USERNAME, "starts with no name")
	assert_eq(seen.size(), 1, "the first pass fetched")
	assert_eq(String(seen[0]["name"]), "", "and carried no name, so it posted nothing")

	# Answer the prompt through the real popup, so the write path is the one the
	# player uses rather than a direct poke at the profile.
	page._on_choose_name_pressed()
	var popup: UsernamePopup = null
	for child in page.get_children():
		if child is UsernamePopup:
			popup = child as UsernamePopup
	assert_not_null(popup, "the prompt opens the name popup")
	popup._field.set_text("kangaroo")
	popup._on_save()
	await get_tree().process_frame
	assert_eq(UsernamePopup.current(), "KANGAROO",
		"the popup writes the name to profile[\"username\"], where the page reads it")

	assert_eq(seen.size(), 2, "choosing a name re-runs submit-and-fetch in place")
	assert_eq(String(seen[1]["name"]), "KANGAROO",
		"and this time the identity carries the name the cloud layer needs to write")
	assert_eq(int(seen[1]["time_ms"]), int(seen[0]["time_ms"]),
		"posting the SAME time — no need to drive the stage again")


# --- Name capture at sign-in (AccountMenu) -----------------------------------
# The leaderboard name is asked for the moment an account exists without one,
# rather than relying on the player noticing a button on the post-stage page. All
# three sign-in paths (email, register, Google) route through
# _maybe_prompt_username, which is what these drive.

func _account_menu() -> AccountMenu:
	var menu := AccountMenu.new()
	add_child_autofree(menu)
	return menu


func _popup_under(node: Node) -> UsernamePopup:
	for child in node.get_children():
		if child is UsernamePopup:
			return child as UsernamePopup
	return null


func test_sign_in_with_a_blank_username_prompts_for_a_name() -> void:
	_save.profile["username"] = ""
	var menu := _account_menu()
	await get_tree().process_frame
	menu._maybe_prompt_username()
	await get_tree().process_frame
	var popup := _popup_under(menu)
	assert_not_null(popup, "a fresh account is asked for a leaderboard name")
	if popup == null:
		return
	assert_true(popup._field.line.is_visible_in_tree(),
		"the field is actually on screen, not merely built")
	assert_eq(popup._field.line.focus_mode, Control.FOCUS_ALL,
		"and it can be typed into from a keyboard / gamepad")


func test_sign_in_with_an_existing_username_does_not_prompt() -> void:
	UsernamePopup.store("kangaroo")
	var menu := _account_menu()
	await get_tree().process_frame
	menu._maybe_prompt_username()
	await get_tree().process_frame
	assert_null(_popup_under(menu),
		"a player who already has a name is not asked again on every sign-in")


# The name captured at sign-in lands in the same place, through the same
# sanitiser, as the one captured from the leaderboard page — the two entry points
# cannot diverge.
func test_name_captured_at_sign_in_is_stored_where_the_cloud_layer_reads_it() -> void:
	_save.profile["username"] = ""
	var menu := _account_menu()
	await get_tree().process_frame
	menu._maybe_prompt_username()
	await get_tree().process_frame
	var popup := _popup_under(menu)
	popup._field.set_text("  milk float!! ")
	popup._on_save()
	await get_tree().process_frame
	assert_eq(UsernamePopup.current(), "MILK FLOAT",
		"stored sanitised, at profile[\"username\"], which is what the page posts")


# Declining is allowed (the popup is deliberately dismissable — the global page's
# prompt and the Account row are the two ways back), and declining must not leave
# the prompt reopening on every rebuild.
func test_declining_the_name_prompt_writes_nothing_and_does_not_reopen() -> void:
	_save.profile["username"] = ""
	var menu := _account_menu()
	await get_tree().process_frame
	menu._maybe_prompt_username()
	await get_tree().process_frame
	_popup_under(menu)._on_cancel()
	await get_tree().process_frame
	assert_eq(UsernamePopup.current(), "", "cancelling writes no name")
	assert_null(_popup_under(menu), "and the prompt does not immediately come back")


# --- A challenge-committed car stays usable EVERYWHERE else ---------------------------
#
# A challenge locks the RUN to the car it started with; it does NOT reserve the car.
# It stays fully usable in the garage, career rallies, engine swaps and free roam while
# a run is in progress. An earlier design excluded it from all of those, which made an
# owned car unusable across the whole game — these tests pin the corrected rule so that
# exclusion can't come back.

# Lock `id` by starting a real Daily challenge run on it.
func _lock_car_in_a_challenge(id: int) -> void:
	assert_true(ChallengeSession.start(ChallengeLibrary.DAILY, _save.get_car(id),
		int(Time.get_unix_time_from_system())), "setup: the challenge run starts")
	assert_true(DrivingContext.is_car_locked(id), "setup: the run is committed to that car")


# A challenge locks the RUN to the car it started with; it does not RESERVE the car. So a
# committed car stays fully usable elsewhere — here, as an engine-swap partner. (This used
# to be asserted against the garage car picker, which no longer exists; the contract it
# guards does, so it moved to a surface that survives.)
func test_challenge_committed_car_is_still_offered_as_a_swap_partner() -> void:
	var locked: Dictionary = _save.grant_car("fx_fwd_hatch")
	var locked_id := int(locked["instance_id"])
	_lock_car_in_a_challenge(locked_id)
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame

	# Swap partners are the OTHER owned cars, judged from some car that isn't the locked
	# one, so the locked car can legitimately appear in the list.
	var others: Array = hq._other_owned_cars(locked_id)
	assert_false(others.is_empty(), "setup: there is another owned car to swap from")
	var from_id := int(others[0].get("instance_id", -1))
	var partner_ids: Array = []
	for car in hq._swap_targets(from_id):
		partner_ids.append(int(car.get("instance_id", -1)))
	assert_true(partner_ids.has(locked_id),
		"the car an active run is committed to is STILL a valid swap partner — the run is locked to it, the car is not reserved")

	# And the challenge still resumes on it — commitment and availability coexist.
	var run := ChallengeSession.resumable_run(Save.profile, int(Time.get_unix_time_from_system()))
	assert_eq(int(run.get("car_instance_id", -1)), locked_id,
		"the run is still fixed to that car")


func test_challenge_committed_car_is_still_an_engine_swap_partner() -> void:
	var current: Dictionary = _save.grant_car("fx_awd")
	var current_id := int(current["instance_id"])
	var locked: Dictionary = _save.grant_car("fx_fwd_hatch")
	var locked_id := int(locked["instance_id"])
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame

	var before: Array = []
	for car in hq._swap_targets(current_id):
		before.append(int(car.get("instance_id", -1)))
	assert_true(before.has(locked_id), "precondition: it IS an ordinary swap partner while unlocked")

	_lock_car_in_a_challenge(locked_id)
	var after: Array = []
	for car in hq._swap_targets(current_id):
		after.append(int(car.get("instance_id", -1)))
	assert_true(after.has(locked_id),
		"a car an active run is committed to is STILL a valid swap partner — the run is locked to it, the car is not reserved")
	assert_eq(after.size(), before.size(), "starting a run removes no swap partner")


# --- Free roam seats the WHOLE track config, not a subset (spec item 3) ---------
#
# Config.data is never reset between scenes, so any field free roam doesn't write
# survives from the last event that did. Free roam therefore goes through the same
# canonical writer a rally does (StageConfig.apply_event_config), which pins every
# field the caller omits back to the authored baseline.
func test_hq_free_roam_clears_a_previous_events_track_shape() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()

	# Poison the live config the way a just-finished rally would: every field the old
	# hand-written free-roam setup did NOT touch. Values are deliberately absurd (not
	# tunings) — the point is only that they must not survive into free roam.
	var base: GameConfig = load(Config.CONFIG_PATH)
	Config.data.track_turn_count = base.track_turn_count + 37
	Config.data.track_width = base.track_width + 11.0
	Config.data.terrain_layer2_amplitude = base.terrain_layer2_amplitude + 123.0
	Config.data.terrain_layer3_wavelength = base.terrain_layer3_wavelength + 456.0

	hq._prepare_free_roam()

	assert_eq(Config.data.track_turn_count, base.track_turn_count,
		"free roam resets the turn count to the authored baseline, not the last event's")
	assert_almost_eq(Config.data.track_width, base.track_width, 0.001,
		"free roam resets the track width to the authored baseline")
	assert_almost_eq(Config.data.terrain_layer2_amplitude, base.terrain_layer2_amplitude, 0.001,
		"a previous event's terrain layer-2 amplitude can't leak into free roam")
	assert_almost_eq(Config.data.terrain_layer3_wavelength, base.terrain_layer3_wavelength, 0.001,
		"nor its layer-3 wavelength")
	assert_almost_eq(Config.data.cliff_amount, base.cliff_amount, 0.001,
		"free roam runs the game's normal cliffs — the authored baseline, not the last event's")


# --- Every start path runs the same pre-flight (spec item 6) -------------------

# Committing a car to a challenge run also SELECTS it, so the tuning lift shows the car
# the player last raced — the career start always did this; the challenge start skipped it.
func test_hq_challenge_start_selects_the_fielded_car() -> void:
	_reset_to_first_run()
	var owned := _install_guaranteed_eligible_car()
	var id := int(owned["instance_id"])
	_save.profile["selected_instance_id"] = -1  # nothing selected going in
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	hq._challenge_ui._open_challenge_overlay()
	hq._challenge_ui._select_challenge_kind(ChallengeLibrary.DAILY)
	hq._challenge_ui._on_challenge_start_pressed()
	await get_tree().process_frame
	assert_eq(hq._carpark_mode, hq.CarparkMode.CHALLENGE, "setup: the challenge car park is open")

	await hq._on_start_pressed()
	assert_true(ChallengeSession.is_active(), "the run started")
	assert_eq(_save.selected_instance_id(), id,
		"fielding a car for a challenge selects it too, same as a career start")


# The mobile control-scheme gate belongs to EVERY start path, not just the career one:
# a touch player whose first-ever drive is a challenge must still be asked to pick a
# scheme, and confirming the gate resumes the CHALLENGE start (not the career one).
func test_hq_mobile_challenge_start_gates_on_control_scheme_pick() -> void:
	Config.data.mobile_controls_force = true  # simulate a touch device
	_reset_to_first_run()
	_install_guaranteed_eligible_car()
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	hq._challenge_ui._open_challenge_overlay()
	hq._challenge_ui._select_challenge_kind(ChallengeLibrary.DAILY)
	hq._challenge_ui._on_challenge_start_pressed()
	await get_tree().process_frame
	assert_eq(hq._carpark_mode, hq.CarparkMode.CHALLENGE, "setup: the challenge car park is open")
	assert_null(_save.get_setting(MobileControls.SETTING_KEY, null), "setup: no control preference yet")

	await hq._on_start_pressed()
	assert_eq(hq._view, hq.View.SETTINGS, "a first mobile challenge start shows the control picker")
	assert_true(hq._settings_gate, "the picker is in pre-start gate mode")
	assert_false(ChallengeSession.is_active(), "the run hasn't started — it's gated on the pick")

	hq._on_settings_action()
	assert_eq(int(_save.get_setting(MobileControls.SETTING_KEY, -1)), MobileControls.DEFAULT_SCHEME,
		"confirming the gate persists the chosen scheme")
	await get_tree().process_frame
	assert_true(ChallengeSession.is_active(),
		"confirming resumes the CHALLENGE start it interrupted, not the career one")
	assert_false(RallySession.is_active(), "and it is not a career rally that started")


# Same gate on the free-roam path, which also used to skip it.
func test_hq_mobile_free_roam_gates_on_control_scheme_pick() -> void:
	Config.data.mobile_controls_force = true
	RallySession.free_roam_instance_id = -1
	RallySession.free_roam_model_id = ""
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	assert_null(_save.get_setting(MobileControls.SETTING_KEY, null), "setup: no control preference yet")

	await hq._launch_free_roam(_save.selected_instance_id(), "")
	assert_eq(hq._view, hq.View.SETTINGS, "a first mobile free-roam drive shows the control picker")
	assert_true(hq._settings_gate, "the picker is in pre-start gate mode")
	assert_eq(RallySession.free_roam_instance_id, -1,
		"no car was handed to free roam — the launch is gated on the pick")


# A board fetch that really suspends, so "in flight" is observable.
func _slow_board(_key: String, _time_ms: int, _identity: Dictionary) -> Dictionary:
	await get_tree().process_frame
	return {"ok": true, "error": "", "rows": [], "total": 0, "signed_in": false,
		"player_rank": 0, "player_row": {}, "posted": false}


# The global page's wait is the SHARED one (scripts/cloud/cloud_busy.gd), in its
# ambient shape — no cover, because nothing here may block a rally. Assert the
# relationship (busy during, gone after), never the copy.
func test_global_page_shows_the_shared_busy_state_while_fetching() -> void:
	var page := _global_page(_slow_board)
	assert_true(CloudBusy.showing(page), "a fetch in flight says so")
	assert_eq(page.state(), GlobalStandings.State.LOADING, "and the page reads as loading")
	var covers := 0
	for child in page.get_children():
		if child.is_in_group("loading_screen"):
			covers += 1
	assert_eq(covers, 0, "a leaderboard read is ambient — it must not throw up a cover")
	await get_tree().process_frame
	await get_tree().process_frame
	assert_false(CloudBusy.showing(page), "and the busy state is gone once it lands")
	assert_ne(page.state(), GlobalStandings.State.LOADING, "with the page repainted")
	assert_false(page._continue_button.disabled, "Continue was never blocked by the wait")


# --- Challenge placing on the entry screen -------------------------------------
# A finished period shows COMPLETED, then gains "- 3 of 42" from a LIVE board query.
# Never a stored rank: only live periods survive the outcome prune, so every
# completed record on screen belongs to a board that is still taking entries — the
# field grows and faster times push the player down after they finish.

class _StubBoard:
	# A real ChallengeLeaderboard subclass, not a bare Node: Cloud.challenge_leaderboard
	# is typed, so anything else fails to assign. Only fetch_final_rank is overridden —
	# nothing else is reached, and rest/auth stay null so a stray call would be loud.
	extends ChallengeLeaderboard
	var answer: Dictionary = {"ok": false}
	var calls := 0
	var gate: Array = []  # non-empty -> park here until the test clears it
	var cutoff: Dictionary = {"ok": false}
	var cutoff_calls := 0
	# PERIOD KEYS parked in flight — a call whose own key is listed here waits until
	# the test removes it. Per-key, NOT a global flag: a global one also parks the
	# query the test switches TO, so the "other kind answered normally" half of a
	# staleness test could never be set up.
	var cutoff_gate: Array = []

	# Yields at least one frame before answering, for the same reason fetch_cutoff
	# does: a synchronous stub can't observe the in-flight state, and it would let
	# the row be written before the enforce pass instead of after it, as in the game.
	func fetch_final_rank(_period_key: String, _stage_count: int) -> Dictionary:
		calls += 1
		await Engine.get_main_loop().process_frame
		while not gate.is_empty():
			await Engine.get_main_loop().process_frame
		return answer

	# Yields TWO frames before answering, not one — a fake must reproduce the real
	# thing's async shape (see fake_rest_client.gd's own comment on the same point).
	# In the game, the row is built, THEN UITheme.enforce uppercases it, and only
	# THEN does this query resolve — collapsing that to a single await frame made the
	# original bug pass by luck of where enforce happened to land relative to it.
	# cutoff_gate lets a test hold the query in flight deliberately, mirroring `gate`
	# on fetch_final_rank above.
	func fetch_cutoff(period_key: String, _stage_count: int) -> Dictionary:
		cutoff_calls += 1
		# Snapshot the answer at call time, like a real query would capture whatever
		# `cutoff_ms` the board held the instant it was asked — a test can then change
		# `cutoff` for a LATER call without also rewriting the answer to a call already
		# parked in flight.
		var snapshot: Dictionary = cutoff
		await Engine.get_main_loop().process_frame
		await Engine.get_main_loop().process_frame
		while cutoff_gate.has(period_key):
			await Engine.get_main_loop().process_frame
		return snapshot


# The placing query needs a signed-in Cloud (fetch_final_rank can only find the
# player's own row with a token), so these swap in a fake auth and put the real one
# back afterwards.
var _real_auth = null
var _real_board = null


func _sign_in_for_placing() -> void:
	_real_auth = Cloud.auth
	var auth := AuthService.new()
	auth.uid = "uid123"
	auth.refresh_token = "refresh"
	auth.id_token = "id"
	auth.expires_at = Time.get_unix_time_from_system() + 3600.0
	Cloud.auth = auth


func _restore_after_placing() -> void:
	Cloud.auth = _real_auth
	Cloud.challenge_leaderboard = _real_board
	# MUST be cleared. A leaked completed period makes every LATER test in this file
	# render the COMPLETED row, which fires a placing query against whatever board is
	# installed by then — the real one, i.e. a live network request per test.
	Save.profile["challenge_results"] = {}


func _hq_with_a_completed_daily(board: Node) -> Node3D:
	_reset_to_first_run()
	_install_guaranteed_eligible_car()
	var t := int(Time.get_unix_time_from_system())
	var key := String(ChallengeLibrary.current_period(ChallengeLibrary.DAILY, t)["key"])
	# Seat a finished (non-DNF) outcome directly — this is about how the row RENDERS,
	# not about driving a run to its end.
	Save.profile["challenge_results"] = {
		key: {"kind": ChallengeLibrary.DAILY, "dnf": false, "cumulative_ms": 1},
	}
	_real_board = Cloud.challenge_leaderboard
	Cloud.challenge_leaderboard = board
	_sign_in_for_placing()
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._challenge_ui._open_challenge_overlay()
	return hq


func test_a_completed_period_shows_the_live_placing() -> void:
	var board := _StubBoard.new()
	add_child_autofree(board)
	board.answer = {"ok": true, "rank": 3, "total_entries": 42}
	var hq := await _hq_with_a_completed_daily(board)

	hq._challenge_ui._select_challenge_kind(ChallengeLibrary.DAILY)
	for _i in 5:
		await get_tree().process_frame

	var text: String = hq._challenge_progress_label.text.to_upper()
	assert_string_contains(text, "COMPLETED", "it still says the period is done")
	assert_string_contains(text, "3 OF 42", "and gains the placing the board reported")
	assert_true(board.calls > 0, "the placing came from a live query, not a stored value")
	_restore_after_placing()


func test_a_completed_period_stays_at_completed_when_the_board_cannot_answer() -> void:
	# Signed out, no username, or the board is unreachable — all read the same way.
	# The row must degrade to a bare COMPLETED, never to "0 of 0" or an error.
	var board := _StubBoard.new()
	add_child_autofree(board)
	board.answer = {"ok": false}
	var hq := await _hq_with_a_completed_daily(board)

	hq._challenge_ui._select_challenge_kind(ChallengeLibrary.DAILY)
	for _i in 5:
		await get_tree().process_frame

	assert_eq(hq._challenge_progress_label.text.to_upper(), "COMPLETED",
		"an unanswerable board leaves the row exactly as it was")
	_restore_after_placing()


func test_a_placing_never_lands_on_a_different_kinds_row() -> void:
	# The player can switch tabs while the query is in flight. Without the re-check
	# the Daily's placing would be written onto whatever row is showing now.
	var board := _StubBoard.new()
	add_child_autofree(board)
	board.answer = {"ok": true, "rank": 3, "total_entries": 42}
	board.gate = [true]  # hold the answer until we have switched away
	var hq := await _hq_with_a_completed_daily(board)

	hq._challenge_ui._select_challenge_kind(ChallengeLibrary.DAILY)
	await get_tree().process_frame
	hq._challenge_ui._select_challenge_kind(ChallengeLibrary.WEEKLY)
	var weekly_text: String = hq._challenge_progress_label.text
	board.gate = []  # let the daily's query answer, now that the row belongs to weekly
	for _i in 5:
		await get_tree().process_frame

	assert_eq(hq._challenge_progress_label.text, weekly_text,
		"the daily's placing does not overwrite the weekly's row")
	_restore_after_placing()


func test_a_signed_out_player_never_queries_the_board_for_a_placing() -> void:
	# fetch_final_rank needs a token to find the player's own row, so signed out it
	# can only answer "not ok" — but it issues the board query before discovering
	# that. Asking anyway would be a real network round trip on every visit to the
	# page, for an answer that cannot exist.
	var board := _StubBoard.new()
	add_child_autofree(board)
	board.answer = {"ok": true, "rank": 3, "total_entries": 42}
	var hq := await _hq_with_a_completed_daily(board)
	# Undo the fake sign-in and discard the queries the signed-in setup already made:
	# this test is about what happens from here, signed out.
	Cloud.auth = _real_auth
	board.calls = 0

	hq._challenge_ui._select_challenge_kind(ChallengeLibrary.DAILY)
	for _i in 5:
		await get_tree().process_frame

	assert_eq(board.calls, 0, "no query is made at all when signed out")
	assert_eq(hq._challenge_progress_label.text.to_upper(), "COMPLETED",
		"and the row still reads correctly")
	_restore_after_placing()


# The COMPLETED row says it is fetching too, rather than leaving the placing to pop
# in later. Same contract as the win row.
func test_a_completed_period_says_loading_while_the_placing_is_fetched() -> void:
	var board := _StubBoard.new()
	add_child_autofree(board)
	board.answer = {"ok": true, "rank": 2, "total_entries": 3}
	var hq := await _hq_with_a_completed_daily(board)
	hq._challenge_ui._select_challenge_kind(ChallengeLibrary.DAILY)  # query is in flight on return

	var loading: String = hq._challenge_progress_label.text.to_upper()
	assert_string_contains(loading, "COMPLETED", "it still says the period is done")
	assert_string_contains(loading, "LOADING", "and says the placing is being fetched")

	for _i in 5:
		await get_tree().process_frame
	var settled: String = hq._challenge_progress_label.text.to_upper()
	assert_string_contains(settled, "2 OF 3", "the placing replaces it")
	assert_false(settled.contains("LOADING"),
		"and the placeholder is GONE, not left in front of the placing")
	_restore_after_placing()


# The placeholder is not a resting state here either: an unreachable board must fall
# back to a bare COMPLETED, never leave "COMPLETED - LOADING…" stuck on screen.
func test_the_completed_loading_placeholder_is_cleared_when_the_board_cannot_answer() -> void:
	var board := _StubBoard.new()
	add_child_autofree(board)
	board.answer = {"ok": false}
	var hq := await _hq_with_a_completed_daily(board)
	hq._challenge_ui._select_challenge_kind(ChallengeLibrary.DAILY)
	for _i in 5:
		await get_tree().process_frame

	assert_eq(hq._challenge_progress_label.text.to_upper(), "COMPLETED",
		"back to a bare COMPLETED, with no placeholder left behind")
	_restore_after_placing()


# --- Board-answer cache (per visit to the online challenge screen) ------------

# Flipping between Daily/Weekly/Monthly re-renders the whole screen, which used to
# re-issue both board queries every time and flash "Loading…" on rows the player had
# already seen answered. Answers are cached per period key for the visit.
func test_switching_kinds_does_not_re_query_an_answer_already_fetched() -> void:
	var board := _StubBoard.new()
	add_child_autofree(board)
	board.answer = {"ok": true, "rank": 2, "total_entries": 3}
	board.cutoff = {"ok": true, "exists": true, "cutoff_ms": 112240, "total_entries": 3}
	var hq := await _hq_with_a_completed_daily(board)
	hq._challenge_ui._select_challenge_kind(ChallengeLibrary.DAILY)
	for _i in 5:
		await get_tree().process_frame
	var placing_calls := board.calls
	var cutoff_calls := board.cutoff_calls
	assert_true(placing_calls > 0 and cutoff_calls > 0, "setup: the Daily was really fetched")

	# Away to another kind and back.
	hq._challenge_ui._select_challenge_kind(ChallengeLibrary.WEEKLY)
	for _i in 5:
		await get_tree().process_frame
	var weekly_cutoff_calls := board.cutoff_calls
	hq._challenge_ui._select_challenge_kind(ChallengeLibrary.DAILY)
	for _i in 5:
		await get_tree().process_frame

	assert_eq(board.calls, placing_calls, "returning to the Daily re-uses the cached placing")
	assert_eq(board.cutoff_calls, weekly_cutoff_calls,
		"and the cached cut line — neither is asked for twice")
	# And it is RENDERED from the cache, not left blank or stuck at Loading.
	assert_string_contains(hq._challenge_progress_label.text.to_upper(), "2 OF 3")
	assert_string_contains(hq._challenge_win_label.text, UITheme.format_time(112240))
	assert_false(hq._challenge_win_label.text.to_upper().contains("LOADING"),
		"a cached answer renders immediately, with no Loading flash")
	_restore_after_placing()


# The cache is per VISIT: closing back to the garage invalidates it, so re-opening
# asks again rather than showing numbers from the last visit (the board keeps moving).
func test_closing_the_challenge_screen_invalidates_the_cached_answers() -> void:
	var board := _StubBoard.new()
	add_child_autofree(board)
	board.answer = {"ok": true, "rank": 2, "total_entries": 3}
	board.cutoff = {"ok": true, "exists": true, "cutoff_ms": 112240, "total_entries": 3}
	var hq := await _hq_with_a_completed_daily(board)
	hq._challenge_ui._select_challenge_kind(ChallengeLibrary.DAILY)
	for _i in 5:
		await get_tree().process_frame
	var placing_calls := board.calls
	var cutoff_calls := board.cutoff_calls

	hq._challenge_ui._close_challenge_overlay()
	hq._challenge_ui._open_challenge_overlay()
	for _i in 5:
		await get_tree().process_frame

	assert_true(board.calls > placing_calls, "re-opening re-asks for the placing")
	assert_true(board.cutoff_calls > cutoff_calls, "and for the cut line")
	_restore_after_placing()


# A failure is a transient condition, not a value — it must not be cached, or one
# offline moment would stick for the rest of the visit.
func test_a_failed_query_is_not_cached_and_is_retried_on_the_next_visit() -> void:
	var board := _StubBoard.new()
	add_child_autofree(board)
	board.cutoff = {"ok": false}
	var hq := await _hq_with_a_completed_daily(board)
	hq._challenge_ui._select_challenge_kind(ChallengeLibrary.DAILY)
	for _i in 5:
		await get_tree().process_frame
	var cutoff_calls := board.cutoff_calls

	hq._challenge_ui._select_challenge_kind(ChallengeLibrary.WEEKLY)
	for _i in 5:
		await get_tree().process_frame
	hq._challenge_ui._select_challenge_kind(ChallengeLibrary.DAILY)
	for _i in 5:
		await get_tree().process_frame

	assert_true(board.cutoff_calls > cutoff_calls + 1,
		"the failed Daily is asked again, not remembered as an answer")
	_restore_after_placing()


# --- Win condition row: the live top-50% cut line -----------------------------

# The win condition names the placing needed and, when the board can answer, the
# time currently holding that line — on the SAME row ("Top 50% - 1:52.24"), since
# the entry screen is a compact HUD readout. Live, never stored: the cut moves as
# entrants arrive and times improve.
func test_the_win_condition_shows_the_live_time_to_beat() -> void:
	var board := _StubBoard.new()
	add_child_autofree(board)
	board.cutoff = {"ok": true, "exists": true, "cutoff_ms": 112240, "total_entries": 9}
	var hq := await _hq_with_a_completed_daily(board)

	hq._challenge_ui._select_challenge_kind(ChallengeLibrary.DAILY)
	for _i in 5:
		await get_tree().process_frame

	var text: String = hq._challenge_win_label.text
	assert_string_contains(text.to_upper(), UITheme.caps(HqChallenge._CHALLENGE_WIN_CONDITION),
		"the placing needed is still named")
	assert_string_contains(text, UITheme.format_time(112240),
		"and the row gains the time on the cut line, formatted like every other time")
	assert_true(board.cutoff_calls > 0, "the time came from a live query")
	assert_false(text.to_lower().contains("clean"),
		"the old 'finish clean' clause is gone from the win condition")
	_restore_after_placing()


# Nobody on the line yet (or an unreachable board): the row degrades to the bare
# condition — never "0:00.00", never an error.
func test_the_win_condition_stays_bare_when_there_is_no_time_to_beat() -> void:
	var board := _StubBoard.new()
	add_child_autofree(board)
	board.cutoff = {"ok": true, "exists": false, "cutoff_ms": 0, "total_entries": 3}
	var hq := await _hq_with_a_completed_daily(board)

	hq._challenge_ui._select_challenge_kind(ChallengeLibrary.DAILY)
	for _i in 5:
		await get_tree().process_frame

	assert_string_contains(hq._challenge_win_label.text.to_upper(),
		UITheme.caps(HqChallenge._CHALLENGE_WIN_CONDITION))
	assert_false(hq._challenge_win_label.text.contains("-"),
		"no dash-and-time tail is appended when there is no line to beat")
	_restore_after_placing()


# THE REGRESSION: the row must gain its time on the real entry path, which runs
# UITheme.enforce (uppercasing every Label) immediately after building the row and
# before the board answers. Asserted through _open_challenge_overlay, not a direct
# _refresh_challenge_overlay call, because it is exactly that enforce pass the earlier
# version silently lost the answer to.
func test_the_cut_line_survives_the_uppercase_enforce_pass_on_open() -> void:
	var board := _StubBoard.new()
	add_child_autofree(board)
	board.cutoff = {"ok": true, "exists": true, "cutoff_ms": 112240, "total_entries": 2}
	var hq := await _hq_with_a_completed_daily(board)  # opens the overlay for real
	for _i in 5:
		await get_tree().process_frame

	var text: String = hq._challenge_win_label.text
	assert_eq(text, text.to_upper(), "setup: the enforce pass really did uppercase the row")
	assert_string_contains(text, UITheme.caps(HqChallenge._CHALLENGE_WIN_CONDITION),
		"the condition is still named")
	assert_string_contains(text, UITheme.format_time(112240),
		"and the time to beat landed despite the row having been uppercased under it")
	_restore_after_placing()


# While the board is being asked, the row SAYS so rather than leaving a gap the time
# pops into later. The stub parks for a frame, so the placeholder is observable.
func test_the_win_condition_says_loading_while_the_board_is_being_asked() -> void:
	var board := _StubBoard.new()
	add_child_autofree(board)
	board.cutoff = {"ok": true, "exists": true, "cutoff_ms": 112240, "total_entries": 2}
	var hq := await _hq_with_a_completed_daily(board)  # query is in flight on return

	assert_string_contains(hq._challenge_win_label.text.to_upper(), "LOADING",
		"the row says it is fetching instead of showing an empty space")
	assert_string_contains(hq._challenge_win_label.text.to_upper(),
		UITheme.caps(HqChallenge._CHALLENGE_WIN_CONDITION),
		"and still states the condition while it waits")

	for _i in 5:
		await get_tree().process_frame
	var settled: String = hq._challenge_win_label.text
	assert_string_contains(settled, UITheme.format_time(112240), "the time replaces it")
	assert_false(settled.to_upper().contains("LOADING"),
		"and the placeholder is GONE, not left cemented in front of the answer")
	_restore_after_placing()


# "Loading…" is not a resting state: an unreachable board (or no cut line yet) must
# clear it back to the bare condition, never leave it stuck.
func test_the_loading_placeholder_is_cleared_when_the_board_cannot_answer() -> void:
	var board := _StubBoard.new()
	add_child_autofree(board)
	board.cutoff = {"ok": false}
	var hq := await _hq_with_a_completed_daily(board)
	for _i in 5:
		await get_tree().process_frame

	var text: String = hq._challenge_win_label.text
	assert_false(text.to_upper().contains("LOADING"), "the placeholder is cleared")
	assert_string_contains(text.to_upper(), UITheme.caps(HqChallenge._CHALLENGE_WIN_CONDITION),
		"leaving the bare condition")
	_restore_after_placing()


func test_a_signed_out_player_never_queries_the_board_for_the_cut_line() -> void:
	# The board is world-readable, so this query WOULD answer — but a signed-out
	# player can't post a checkpoint, so there's no cut for them to make and no
	# reason to spend a network round trip on every visit to the page.
	var board := _StubBoard.new()
	add_child_autofree(board)
	board.cutoff = {"ok": true, "exists": true, "cutoff_ms": 112240, "total_entries": 9}
	var hq := await _hq_with_a_completed_daily(board)
	Cloud.auth = _real_auth  # undo the fake sign-in; discard the setup's own calls
	board.cutoff_calls = 0

	hq._challenge_ui._select_challenge_kind(ChallengeLibrary.DAILY)
	for _i in 5:
		await get_tree().process_frame

	assert_eq(board.cutoff_calls, 0, "no query is made at all when signed out")
	assert_string_contains(hq._challenge_win_label.text.to_upper(),
		UITheme.caps(HqChallenge._CHALLENGE_WIN_CONDITION),
		"and the row still states the condition")
	_restore_after_placing()


# THE GENERATION COUNTER'S WHOLE JOB: a cutoff query parked in flight for one kind
# must be DISCARDED, not written, once the screen has moved on to another kind. This
# is the exact regression class the fix (_challenge_refresh_generation) exists for —
# nothing above actually proves a stale answer gets thrown away rather than merely
# not overwriting a DIFFERENT already-cached value.
func test_a_stale_cut_line_is_discarded_when_the_kind_changes_before_it_answers() -> void:
	var board := _StubBoard.new()
	add_child_autofree(board)
	board.cutoff = {"ok": true, "exists": true, "cutoff_ms": 111111, "total_entries": 9}
	# Park ONLY the Daily's query; the Weekly must be free to answer normally.
	var now := int(Time.get_unix_time_from_system())
	var daily_key := String(ChallengeLibrary.current_period(ChallengeLibrary.DAILY, now)["key"])
	board.cutoff_gate = [daily_key]
	var hq := await _hq_with_a_completed_daily(board)  # opens on Daily; its query is parked
	await get_tree().process_frame
	# Give the Weekly its own, distinguishable answer BEFORE asking for it — the stub
	# snapshots at call time, same as a real query would capture whatever was live then.
	board.cutoff = {"ok": true, "exists": true, "cutoff_ms": 222222, "total_entries": 9}
	# Switch away before the Daily's parked query can answer.
	hq._challenge_ui._select_challenge_kind(ChallengeLibrary.WEEKLY)
	for _i in 5:
		await get_tree().process_frame
	var weekly_time := UITheme.format_time(222222)
	assert_string_contains(hq._challenge_win_label.text, weekly_time,
		"setup: the Weekly's own query already answered")

	# Now release the Daily's stale query and let it try to land.
	board.cutoff_gate = []
	for _i in 5:
		await get_tree().process_frame

	assert_false(hq._challenge_win_label.text.contains(UITheme.format_time(111111)),
		"the Daily's stale cut line never overwrites the Weekly's row")
	assert_string_contains(hq._challenge_win_label.text, weekly_time,
		"the Weekly's row is exactly as it was")
	_restore_after_placing()


# A tap on a kind tab SELECTS that kind and does nothing else. The tabs' `pressed`
# signal is wired to START the challenge, and a pointer press would otherwise both move
# focus onto the tab (selecting) and fire `pressed` in the same gesture — so tapping
# "Weekly" to look at it would launch the Weekly run. hq_overlays.gd::_tab_pointer_select
# consumes the press and grabs focus itself, keeping "`pressed` only ever arrives from
# ui_accept" true for touch too.
func test_tapping_a_kind_tab_selects_it_without_starting_the_challenge() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	hq._challenge_ui._open_challenge_overlay()
	await get_tree().process_frame
	assert_eq(hq._challenge_kind, ChallengeLibrary.DAILY, "setup: opens on Daily")

	var weekly: Button = hq._challenge_ui._challenge_kind_button(ChallengeLibrary.WEEKLY)
	var touch := InputEventScreenTouch.new()
	touch.pressed = true
	# Drive the `gui_input` SIGNAL, not the `_gui_input` virtual. Godot's
	# Control::_call_gui_input emits the signal FIRST and then skips the virtual entirely
	# if the viewport reports the event handled — which is exactly why accept_event() in
	# our handler suppresses BaseButton's own press handling. Calling the virtual directly
	# would bypass our handler and really launch a run (it did, and hung the suite).
	weekly.gui_input.emit(touch)
	await get_tree().process_frame

	assert_eq(hq._challenge_kind, ChallengeLibrary.WEEKLY, "the tap selected the Weekly tab")
	assert_true(hq._challenge_layer.visible,
		"and did NOT start a run — the challenge screen is still up")
	assert_false(ChallengeSession.is_active(),
		"no challenge run was started by merely tapping a tab")
	# The select-only guarantee rests on the handler being on the SIGNAL (which runs
	# before, and can pre-empt, the button's own press handling). Assert that wiring
	# directly — driving it through a real viewport is not available headless.
	assert_true(weekly.gui_input.get_connections().size() > 0,
		"the tab consumes pointer presses via gui_input, so `pressed` stays ui_accept-only")


# --- New-rally reveal on the map ---------------------------------------------
#
# When rallies become enterable, the next map open pans to each and flips its pin from
# the locked to the unlocked look, so the player is TOLD what opened up instead of
# having to notice a grey pin turned green. The queue is derived fresh from current
# state on every open (never cached at rally-completion time), which is what makes it
# work for any unlock route — finishing a rally, buying a car, a Mystery Box car, an
# engine swap, a cloud restore. See docs/superpowers/specs/2026-08-02-new-rally-reveal-design.md.
#
# The tests below exercise the pure queue-derivation and the skip, never the timings
# (those are tunables) and never a shipped rally (the roster is synthetic).

# A synthetic three-rally roster: one anyone can enter, one gated behind a power floor
# nothing in the fixture garage can reach, and a SPECIAL locked behind a star gate. The
# gate is set to exactly one 1st-place finish's worth of stars, so completing a single
# rally opens it — the same shape the old "complete the region" gate had.
# The shipped roster, but with the profile recording a starter whose opening rally sits at
# the middle of the map — the one patch of light a fresh profile has now that HQ provides
# none. Used by the fog tests, which need a known lit spot and known dark corners.
func _install_opening_rally_at_centre() -> void:
	var hq_pos: Vector2 = RallyLibrary.HQ_MAP_POS
	_save.profile["starter_model_id"] = STARTER_PRIZE_CAR
	RallyLibrary.override_for_test([
		{"id": "fog_start", "name": "Fog Start", "region": "home", "difficulty": 1,
			"special": false, "map_pos": hq_pos, "restriction": {},
			"prize_car": STARTER_PRIZE_CAR, "events": []},
		# Something out in the dark for the player to light next, so the "fog recedes"
		# test has somewhere left to go.
		{"id": "fog_next", "name": "Fog Next", "region": "home", "difficulty": 2,
			"special": false, "map_pos": hq_pos + Vector2(0.12, 0.0), "restriction": {},
			"events": []},
	])


func _install_reveal_roster() -> void:
	# rv_open is the player's OPENING rally — the map's one starting light, since HQ lights
	# nothing (features/map-exploration.md) — and rv_hot sits inside its circle, held back
	# by its power floor rather than by the map. rv_special is parked far out in the dark.
	# Reveal is geometric, so the real radius is what makes that distinction.
	_dark_map_radius()
	var hq_pos: Vector2 = RallyLibrary.HQ_MAP_POS
	_save.profile["starter_model_id"] = STARTER_PRIZE_CAR
	RallyLibrary.override_for_test([
		{"id": "rv_open", "name": "Reveal Open", "region": "home", "difficulty": 1,
			"special": false, "map_pos": hq_pos, "restriction": {},
			"prize_car": STARTER_PRIZE_CAR, "events": []},
		# rv_hot lights a WIDE circle, so completing it is what reveals rv_special — the
		# roster's one reveal edge, and what the parade tests drive.
		{"id": "rv_hot", "name": "Reveal Hot", "region": "home", "difficulty": 2,
			"special": false, "map_pos": hq_pos + Vector2(0.03, 0.0), "reveal_radius": 0.7,
			# A class no fixture car is in, so no owned car can enter it until the test
			# grants one that is (_grant_in_class_car).
			"restriction": {"country": RV_HOT_COUNTRY}, "events": []},
		{"id": "rv_special", "name": "Reveal Special", "region": "home", "difficulty": 3,
			"special": true, "map_pos": hq_pos + Vector2(0.5, 0.0),
			"restriction": {}, "events": []},
	])


# The country rv_hot restricts entry to. Deliberately not one any fixture car carries, so
# "no owned car can enter it" holds however the fixtures are retuned.
const RV_HOT_COUNTRY := "__rv_hot_only__"


# Grants a car in rv_hot's class — the only owned car that qualifies for it.
func _grant_in_class_car() -> void:
	var cars := CarFixtures.cars()
	var in_class: Dictionary = CarFixtures.cars()[0].duplicate(true)
	in_class["id"] = "fx_reveal_in_class"
	in_class["name"] = "Fixture In Class"
	in_class["country"] = RV_HOT_COUNTRY
	cars.append(in_class)
	CarLibrary.override_for_test(cars)
	_save.grant_car("fx_reveal_in_class")


func _new_hq() -> Node3D:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	return hq


func test_reveal_queue_holds_a_rally_until_a_car_can_enter_it() -> void:
	# THE CORE OF THE DESIGN: a reveal is not "this rally unlocked", it's "you can go do
	# this now". An unlocked rally the garage cannot field is held back — and appears the
	# moment a qualifying car arrives, by whatever route.
	_install_reveal_roster()
	var hq: Node3D = await _new_hq()
	var pending: Array = hq._table_ui._pending_reveals()
	assert_true(pending.has("rv_open"), "an open rally with a car that can enter it is revealed")
	assert_false(pending.has("rv_hot"), "a rally no owned car can enter is held back")
	assert_false(pending.has("rv_special"), "a star-locked special is not revealed")

	_grant_in_class_car()
	assert_true(hq._table_ui._pending_reveals().has("rv_hot"),
		"the held rally appears once the player owns a car that qualifies for it")


func test_reveal_queue_skips_rallies_already_shown() -> void:
	_install_reveal_roster()
	var hq: Node3D = await _new_hq()
	assert_true(hq._table_ui._pending_reveals().has("rv_open"))
	_save.mark_rally_revealed("rv_open")
	assert_false(hq._table_ui._pending_reveals().has("rv_open"),
		"a rally the player has already been shown is never revealed twice")


func test_opening_the_map_reveals_the_pending_rallies_and_leaves_the_table_live() -> void:
	_install_reveal_roster()
	var hq: Node3D = await _new_hq()
	hq._table_ui._enter_table()
	await get_tree().process_frame
	assert_true(_save.rally_revealed_seen("rv_open"), "the revealed rally is marked seen")
	assert_false(hq._revealing, "the sequence has ended")
	assert_eq(hq._view, hq.View.TABLE, "the player is left on the map")
	assert_gt(hq._table_focus_index, -1, "a pin is focused, so table input is live again")
	assert_true(hq._table_ui._pending_reveals().is_empty(),
		"re-opening the map does not replay what was already shown")


func test_an_existing_career_is_seeded_instead_of_paraded() -> void:
	# THE BACKFILL TRAP: a save from before this feature carries no reveal flags, and
	# `false` is the wrong default for it — a player with a dozen open rallies would get
	# a dozen-pin parade on next launch. Everything already open is seeded as seen.
	#
	# The seeding itself now lives in Save (Save._seed_reveals_if_needed), run the moment
	# a profile becomes live — load_or_new / adopt_profile — rather than as a call hq.gd
	# has to remember to make. So this exercises it through an actual reload, not through
	# any hq.gd hook. It seeds by UNLOCKED-OR-COMPLETED, deliberately with NO eligible-car
	# clause (seeding's job is "anything already open already reads as seen", not
	# "anything the player can currently enter") — rv_hot is revealed (it sits in the light)
	# even though nothing in the garage can enter it yet, so it gets silently seeded too.
	# Only a rally that is genuinely still LOCKED at seed time — rv_special, gated on the
	# ordinary-completion count — survives the pass to become a real future reveal.
	_install_reveal_roster()
	_save.record_podium_rally("rv_open", 60_000, 2)  # 1 completion: still short of rv_special
	assert_true(_save.needs_reveal_seeding())
	_save.save_now()
	_save.load_or_new()  # the profile becoming live is what must trigger the backfill
	assert_false(_save.needs_reveal_seeding(), "the profile now carries reveal flags")

	var hq: Node3D = await _new_hq()
	assert_true(hq._table_ui._pending_reveals().is_empty(),
		"an existing career's first map open has nothing to parade")
	assert_true(_save.rally_revealed_seen("rv_hot"),
		"an unlocked-but-uncarriageable rally is seeded too — seeding has no eligible-car hold")

	# ...and a rally that was still LOCKED at seed time still gets a real reveal once it
	# actually unlocks — seeding backfilling the open roster does not swallow that.
	_save.record_podium_rally("rv_hot", 45_000, 1)  # 2nd completion -> opens the special
	assert_true(hq._table_ui._pending_reveals().has("rv_special"),
		"seeding never swallows a rally that was still locked at seed time")


func test_a_press_during_the_reveal_cannot_cancel_it() -> void:
	# Player input is LOCKED for the duration of the parade. This used to be the opposite:
	# any press skipped the whole queue. But skipping marked every queued rally SEEN, so a
	# stray keypress permanently burned the "NEW RALLY - …" beat for up to
	# hq_reveal_max_queue rallies with no way to replay it — the reveal is the only place
	# the game announces a new rally. The parade is short (pan + hold each, capped), so it
	# simply plays. The press is still SWALLOWED so nothing underneath it reacts.
	_install_reveal_roster()
	var hq: Node3D = await _new_hq()
	hq._table_ui._enter_table()
	await get_tree().process_frame
	# Re-arm the sequence by hand: headless drains it instantly (no awaits allowed in
	# the suite), so this is the only way to stand in the middle of one.
	_save.profile["rallies"] = {}
	hq._revealing = true
	hq._table_ui._reveal_queue.append("rv_open")
	hq._table_ui._reveal_queue.append("rv_hot")

	var key := InputEventKey.new()
	key.keycode = KEY_SPACE
	key.pressed = true
	hq._unhandled_input(key)

	assert_true(hq._revealing, "the press did NOT end the sequence")
	assert_false(_save.rally_revealed_seen("rv_open"),
		"nothing was marked seen, so the reveal still has its rallies to show")
	assert_false(_save.rally_revealed_seen("rv_hot"),
		"and the queued rally is still pending, not silently burned")
	assert_eq(hq._view, hq.View.TABLE, "the player stays on the map")


func test_table_input_is_suspended_while_the_reveal_runs() -> void:
	_install_reveal_roster()
	var hq: Node3D = await _new_hq()
	hq._table_ui._enter_table()
	await get_tree().process_frame
	hq._table_panning = true  # as if a drag were already under way
	hq._revealing = true
	var before: Vector3 = hq._table_pan
	var drag := InputEventMouseMotion.new()
	drag.relative = Vector2(40.0, 40.0)
	hq._table_pan_input(drag)
	assert_eq(hq._table_pan, before, "map dragging is inert while the camera is revealing")
	hq._revealing = false


func test_a_stale_reveal_token_cannot_touch_a_newer_sequences_state() -> void:
	# FINDING: the reveal coroutine used to have no generation guard. Skip, leave the
	# table, and re-enter before a parked `await` resumes, and a SECOND sequence may
	# already have set `_revealing = true` by the time the first one wakes up — without
	# a guard the stale coroutine would go on to pan the camera, bump the banner, and
	# erase() entries out of the NEW queue. `_reveal_token` fixes this: each sequence
	# captures its own generation, and `_reveal_continue` refuses a stale one outright.
	#
	# Headless drains a sequence synchronously (nothing ever actually parks mid-`await`),
	# so this drives the guard directly instead of racing real coroutines.
	_install_reveal_roster()
	var hq: Node3D = await _new_hq()
	hq._table_ui._enter_table()
	await get_tree().process_frame

	# Simulate: a first sequence started and captured this token...
	var stale_token: int = hq._table_ui._reveal_token
	# ...then, before it resumed, a second sequence started (bumping the token) and is
	# now mid-flight with its own queue.
	hq._table_ui._reveal_token += 1
	hq._revealing = true
	hq._table_ui._reveal_queue.clear()
	hq._table_ui._reveal_queue.append("rv_hot")
	hq._table_ui._reveal_shown.clear()
	hq._view = hq.View.TABLE

	assert_false(hq._table_ui._reveal_continue(stale_token),
		"a coroutine carrying an outdated token is told to stop, not to keep going")
	assert_eq(hq._table_ui._reveal_queue, ["rv_hot"] as Array[String],
		"the stale coroutine's abort must not mutate the new sequence's queue")
	assert_true(hq._revealing,
		"nor may a stale coroutine's abort clear the new sequence's _revealing flag")


# Free Roam is a TITLE-screen action, not a garage one: it needs no owned car, session
# or lift, so routing the player through the garage to reach it was a detour. Account
# gave up that slot — it is reachable as a Settings page instead, one route not two.
func test_free_roam_is_on_the_title_row_and_account_is_not() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.EXTERIOR, "boots to the title")
	assert_not_null(hq._overlays._title_free_roam_button, "the title screen has a Free Roam button")
	assert_true(hq._title_cursor.buttons.has(hq._overlays._title_free_roam_button),
		"Free Roam is a stop on the title's left/right cursor, not pointer-only")
	for b: Button in hq._title_cursor.buttons:
		assert_false(b.text.to_upper().contains("ACCOUNT"),
			"the title row no longer carries Account — Settings hosts the only route")
	# Firing it from the title drops straight into the free-roam picker.
	hq._title_focus = hq._title_cursor.buttons.find(hq._overlays._title_free_roam_button)
	hq._activate_title_focus()
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.CARPARK, "Free Roam from the title opens the car park")
	assert_eq(hq._carpark_mode, hq.CarparkMode.FREEROAM, "in free-roam mode")


# ...and it is NOT on the garage row any more.
func test_free_roam_is_not_on_the_garage_row() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	for b: Button in hq._garage_cursor.buttons:
		assert_false(b.text.to_upper().contains("FREE ROAM"),
			"the garage row no longer carries Free Roam (it lives on the title screen)")


# --- Present box on the map (todo/star-economy.md) ----------------------------


# --- Repair (features/star-economy.md) ---------------------------------------
# The lift hub's Repair action: the per-car star sink. Never pins the PRICE
# (GameConfig.star_cost_per_repair is tunable) — only that the button states its three
# cases and that pressing it fixes the car and moves the balance.

# A button anywhere in the LIFT station by its label. Searches the whole subtree rather
# than just the hub row: the lift's controls are spread across two cursor rows — the
# actions row and the car selector, which is where Repair lives (it moved there when the
# actions row outgrew the screen).
func _lift_button(hq: Node3D, label: String) -> Button:
	for node in hq.find_children("*", "Button", true, false):
		if (node as Button).text.to_upper().begins_with(label.to_upper()):
			return node
	return null


func test_hq_lift_repair_button_is_disabled_for_an_undamaged_car() -> void:
	# Stated, not hidden: "your car is fine" is something the player can read off the row.
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_lift()
	await get_tree().process_frame
	var repair := _lift_button(hq, "REPAIR")
	assert_not_null(repair, "the hub row has a Repair button")
	assert_true(repair.disabled, "nothing to fix, so nothing to buy")


func test_hq_lift_repair_button_is_reachable_once_the_car_is_damaged() -> void:
	# CLAUDE.md: no menu ships pointer-only — a damaged car's Repair must be a real
	# keyboard/gamepad cursor stop, not just a clickable rectangle.
	var save: Node = get_node("/root/Save")
	save.get_car(save.selected_instance_id())["hp"] = 1.0
	save.award_stars(20)
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_lift()
	await get_tree().process_frame
	var repair := _lift_button(hq, "REPAIR")
	assert_false(repair.disabled, "a damaged car with stars in hand can be repaired")
	# Repair sits on the SELECTOR row (beside the car name) rather than the actions row,
	# so it is that row's cursor it has to be a stop on. Moving a button must never cost it
	# keyboard/gamepad reachability (CLAUDE.md).
	assert_has(hq._lift_selector_cursor.buttons, repair, "and it is a cursor stop")


func test_hq_lift_repair_restores_the_car_and_spends_the_stars() -> void:
	var save: Node = get_node("/root/Save")
	var id: int = save.selected_instance_id()
	save.get_car(id)["hp"] = 1.0
	save.award_stars(20)
	var before: int = save.stars_available()
	var price: int = save.repair_price(id)
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_lift()
	await get_tree().process_frame
	hq._repair_selected_car()
	await get_tree().process_frame
	var entry: Dictionary = CarLibrary.by_id(String(save.get_car(id)["model_id"]))
	assert_eq(float(save.get_car(id)["hp"]), float(entry["max_hp"]), "back to full health")
	assert_eq(save.stars_available(), before - price, "and the balance moved by the price")
	assert_true(_lift_button(hq, "REPAIR").disabled,
		"and the button goes quiet again — there is nothing left to fix")


# --- Exploration fog + prize markers (features/map-exploration.md) ------------

func test_the_map_plane_is_shaded_by_the_exploration_fog() -> void:
	# The map is DARK except where the player has driven, so the plane carries the fog
	# shader with a mask — not the plain unshaded texture it used to.
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var mat: Material = hq._map_plane.material_override
	assert_true(mat is ShaderMaterial, "the map plane is fog-shaded")
	assert_not_null((mat as ShaderMaterial).get_shader_parameter("fog_mask"),
		"and carries a lit-region mask")


func test_the_fog_mask_lights_the_opening_rally_and_leaves_the_far_map_dark() -> void:
	# The mask must agree with the reveal RULE — it is built from the same
	# RallyLibrary.lit_sources — or the player would see lit ground they cannot enter.
	#
	# The lit ground is the player's OPENING RALLY, not HQ: HQ lights nothing and is not
	# even drawn on the map any more (features/map-exploration.md). Parking that rally at
	# the map's centre keeps the geometry of the original check — one lit patch in the
	# middle, dark corners — while measuring the thing that actually lights it.
	_dark_map_radius()
	_install_opening_rally_at_centre()
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var tex: Texture2D = (hq._map_plane.material_override as ShaderMaterial) \
		.get_shader_parameter("fog_mask")
	var img: Image = tex.get_image()
	var n: int = img.get_width()
	var hq_pos: Vector2 = RallyLibrary.HQ_MAP_POS
	var at_hq: float = img.get_pixel(int(hq_pos.x * n), int(hq_pos.y * n)).r
	var at_corner: float = img.get_pixel(1, 1).r
	assert_gt(at_hq, 0.5, "the ground around the opening rally is lit")
	assert_lt(at_corner, 0.5, "the far corner of the map is dark")


func test_completing_a_rally_lights_more_of_the_mask() -> void:
	# The fog RECEDES as the player explores — the mask is rebuilt from current progress
	# every time the pins are, so it can never lag behind what is enterable.
	_dark_map_radius()
	_install_opening_rally_at_centre()
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var lit := func() -> int:
		var img: Image = ((hq._map_plane.material_override as ShaderMaterial) \
			.get_shader_parameter("fog_mask") as Texture2D).get_image()
		var n := 0
		for y in img.get_height():
			for x in img.get_width():
				if img.get_pixel(x, y).r > 0.5:
					n += 1
		return n
	var before: int = lit.call()
	for rally in RallyLibrary.all():
		if RallyLibrary.rally_revealed(rally, _save.profile):
			_save.dev_three_star_rally(String(rally["id"]))
	hq._refresh_map_pins()
	await get_tree().process_frame
	assert_gt(lit.call(), before, "winning what was reachable lights more of the map")


# The reveal graph is drawn only between pins the player has already LIT
# (RallyLibrary.reveal_link_pairs). Asserted on the geometry the table actually builds,
# because the geometry is the whole point: a dotted line running off into the dark draws the
# shape of a roster the player has not explored, which is what the fog is there to withhold.
func test_the_map_draws_no_reveal_link_out_into_the_dark() -> void:
	_dark_map_radius()
	var hq_pos: Vector2 = RallyLibrary.HQ_MAP_POS
	var r: float = Config.data.map_reveal_radius
	_save.profile["starter_model_id"] = STARTER_PRIZE_CAR
	RallyLibrary.override_for_test([
		{"id": "lk_start", "name": "Link Start", "region": "home", "difficulty": 1,
			"special": false, "map_pos": hq_pos, "restriction": {},
			"prize_car": STARTER_PRIZE_CAR, "events": []},
		# Inside the opening rally's circle: lit from the start, so this edge may be drawn.
		{"id": "lk_near", "name": "Link Near", "region": "home", "difficulty": 1,
			"special": false, "map_pos": hq_pos + Vector2(r * 0.6, 0.0),
			"restriction": {}, "events": []},
		# Out in the dark, but near enough lk_near that completing it lights this one — an
		# edge of the graph that exists and must still not be drawn yet.
		{"id": "lk_dark", "name": "Link Dark", "region": "home", "difficulty": 2,
			"special": false, "map_pos": hq_pos + Vector2(r * 1.5, 0.0),
			"restriction": {}, "events": []},
	])
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	assert_true(_link_reaches_pin(hq, "lk_near"),
		"the two lit pins are joined by a dotted line")
	assert_false(_link_reaches_pin(hq, "lk_dark"),
		"nothing is drawn out to the pin still in the fog")
	_save.dev_three_star_rally("lk_near")
	hq._refresh_map_pins()
	await get_tree().process_frame
	assert_true(_link_reaches_pin(hq, "lk_dark"),
		"and the line appears once that pin is lit")
	RallyLibrary.reset()


# Whether the map's reveal-link geometry runs all the way out to a given rally's pin. The
# links are one merged ImmediateMesh under _pins_root, built in the space the pins are
# positioned in (hq._map_to_table mirrors _make_pin), so a pin's own position is what a line
# ending there must reach.
#
# The tolerance is one dash GAP, not zero: a link is stippled at a fixed pitch, so its far
# end lands within a gap's length of the pin rather than exactly on it. That is orders of
# magnitude smaller than the spacing between the pins this is asked about, so it cannot
# confuse one link's end for another's.
func _link_reaches_pin(hq: Node3D, rally_id: String) -> bool:
	var pin := _pin_for(hq, rally_id)
	if pin == null:
		return false
	var tol: float = Config.data.map_link_gap_m + 0.001
	var target := Vector2(pin.position.x, pin.position.z)
	for child in hq._pins_root.get_children():
		var mi := child as MeshInstance3D
		if mi == null or mi.mesh == null or mi.mesh.get_surface_count() == 0:
			continue
		var verts: PackedVector3Array = mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		for v in verts:
			# XZ only: the lines float a hair above the table (hq.MAP_LINK_LIFT) so they do
			# not z-fight with the map plane.
			if Vector2(v.x, v.z).distance_to(target) < tol:
				return true
	return false


func test_a_car_prize_pin_stands_the_actual_car_model() -> void:
	# The map's incentive: a car-unlock pin shows the car you win, so the destination
	# describes itself and needs no permanent label.
	RegionLibrary.override_for_test([{"id": "home", "name": "Home"}])
	var prize_id := String(CarFixtures.cars()[1]["id"])
	RallyLibrary.override_for_test([
		{"id": "car_prize", "name": "Car Prize", "region": "home", "special": false,
			"map_pos": RallyLibrary.HQ_MAP_POS, "prize_car": prize_id,
			"restriction": {}, "events": []},
	])
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var pin := _pin_for(hq, "car_prize")
	assert_eq(String(pin.get_meta("prize_car_model")), prize_id,
		"the pin knows which car it advertises")
	assert_gt(pin.find_children("*", "MeshInstance3D", true, false).size(), 0,
		"and stands a 3D model for it")
	RegionLibrary.reset()
	RallyLibrary.reset()


func test_only_the_focused_pin_shows_its_readout() -> void:
	# HOVER-ONLY readouts: the table is a map with one thing selected, not a noticeboard of
	# a dozen open menus. Every pin keeps its 3D marker, so nothing is hidden — only chrome.
	RegionLibrary.override_for_test([{"id": "home", "name": "Home"}])
	var hq_pos: Vector2 = RallyLibrary.HQ_MAP_POS
	RallyLibrary.override_for_test([
		{"id": "one", "name": "One", "region": "home", "special": false,
			"map_pos": hq_pos, "restriction": {}, "events": []},
		{"id": "two", "name": "Two", "region": "home", "special": false,
			"map_pos": hq_pos + Vector2(0.06, 0.0), "restriction": {}, "events": []},
	])
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._table_ui._enter_table()
	await get_tree().process_frame
	var shown := 0
	for pin in hq._pins:
		if pin.has_meta("label_sprite") and (pin.get_meta("label_sprite") as Node3D).visible:
			shown += 1
	assert_eq(shown, 1, "exactly one readout is open — the focused pin's")
	RegionLibrary.reset()
	RallyLibrary.reset()


func test_a_prize_car_model_is_seated_flush_on_its_pin() -> void:
	# REGRESSION: CarProp.spawn's apply_car ends in _reset(), which puts the car back at its
	# spawn transform — metres up. Positioning it AFTER spawn is therefore undone; it has to
	# happen in the `configure` step, which runs before that reset. Left unfixed, the prize
	# cars hovered in mid-air over the map with nothing on screen to explain them.
	#
	# Asserts the car's LOCAL transform under its pin — the thing `configure` actually
	# controls — rather than a world height, which depends on how the HQ is parented.
	#
	# Runs on the SHIPPED roster and catalogue, because that is the pairing the bug lived in:
	# under the synthetic car fixtures no prize car resolves and no model is ever built.
	CarFixtures.restore()
	RallyLibrary.reset()
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var checked := 0
	for pin in hq._pins:
		if not pin.has_meta("prize_car_model"):
			continue
		var cars: Array = pin.find_children("*", "RigidBody3D", true, false)
		assert_gt(cars.size(), 0, "the prize pin stands a car prop")
		var car: Node3D = cars[0]
		assert_almost_eq(car.position.y, 0.0, 0.01,
			"the car is seated on its pin, not left at the spawn height _reset() applies")
		assert_lt(car.scale.x, 1.0, "and shrunk to a map token rather than left full size")
		checked += 1
	assert_gt(checked, 0, "the shipped roster has prize cars to check")


# F8 HOT RELOAD (hq.hot_reload_config) must not fight F7. `world_space_menus` is stored FALSE in
# game_config.tres, so a straight re-read switches world menus off — which looked exactly like
# "pressing F8 resets me to the flat menus". The toggle is a live A/B switch for the session, not one
# of the values being tuned, so it has to survive a reload of everything else.
func test_hq_hot_reload_keeps_the_world_menu_toggle() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	Config.data.world_space_menus = true
	hq.update_overlays()
	assert_not_null(hq._panel_host("title").panel, "world mode is on before the reload")

	assert_true(hq.hot_reload_config(), "the config re-reads from disk")
	assert_true(bool(Config.data.world_space_menus),
		"F8 must not switch world menus off — it re-reads TUNING values, not the A/B toggle")

	# ...and the flat direction survives too, so F8 is neutral either way.
	Config.data.world_space_menus = false
	hq.update_overlays()
	assert_true(hq.hot_reload_config(), "the config re-reads from disk again")
	assert_false(bool(Config.data.world_space_menus), "and a flat session stays flat")


# A ui_scale RETUNE MUST REACH THE PANEL. This is the bug that made F8 look half-broken: panel
# offsets and yaw updated (their anchors read Config.data per call) while height and ui_scale did
# not, because a WorldPanelHost kept the spec Callable it was BORN with — and that closure had
# captured the GameConfig instance, which reload_from_disk() replaces wholesale.
#
# Asserts the observable consequence: the hosted tree's layout canvas is logical_size / ui_scale, so
# changing ui_scale must change the frame's size. Compared as a RELATIONSHIP (a bigger scale means a
# smaller canvas), never against a pinned pixel count.
func test_hq_panel_ui_scale_retune_reaches_the_panel() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	Config.data.world_space_menus = true
	hq.update_overlays()
	var before: Vector2 = hq._panel_host("title").panel.frame().size

	Config.data.world_panel_title_ui_scale = float(Config.data.world_panel_title_ui_scale) * 2.0
	hq.update_overlays()
	var after: Vector2 = hq._panel_host("title").panel.frame().size
	assert_lt(after.x, before.x, "doubling ui_scale must halve the layout canvas — the panel rebuilt")

	# ...and it still works ACROSS a hot reload, which swaps the GameConfig instance out from under
	# any callable that captured it. This half is the actual regression.
	assert_true(hq.hot_reload_config(), "the config re-reads from disk")
	var reloaded: Vector2 = hq._panel_host("title").panel.frame().size
	Config.data.world_panel_title_ui_scale = float(Config.data.world_panel_title_ui_scale) * 2.0
	hq.update_overlays()
	assert_lt(hq._panel_host("title").panel.frame().size.x, reloaded.x,
		"a retune AFTER a hot reload must still reach the panel (no stale GameConfig capture)")


# BOTH CAR-PARK CAMERA SHIFTS ARE ACTUALLY WIRED, and F8 re-applies them.
#
# This exists because `world_panel_camera_eye_shift` shipped for a few minutes as a config field that
# was READ BY NOTHING — the export and the .tres entry landed but the edit that consumed it silently
# failed, so turning the dial did nothing and looked like a hot-reload bug. A field that no code reads
# is invisible from the game, so it gets a test.
#
# Asserts the RELATIONSHIP, not the values: a non-zero look shift must change the aim, a non-zero eye
# shift must change the viewpoint, and neither may touch the flat framing.
func test_hq_carpark_world_camera_shifts_are_applied() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_free_roam()
	await get_tree().process_frame

	var flat: Transform3D = hq._camera_target_xform()

	Config.data.world_space_menus = true
	Config.data.world_panel_camera_look_shift = Vector3(3.0, 0.5, 0.0)
	Config.data.world_panel_camera_eye_shift = Vector3.ZERO
	var panned: Transform3D = hq._camera_target_xform()
	assert_true(panned.origin.is_equal_approx(flat.origin),
		"a LOOK shift must not move the camera's position")
	assert_false(panned.basis.is_equal_approx(flat.basis), "a LOOK shift must change the aim")

	Config.data.world_panel_camera_eye_shift = Vector3(0.0, 2.0, 3.0)
	var moved: Transform3D = hq._camera_target_xform()
	assert_false(moved.origin.is_equal_approx(panned.origin),
		"an EYE shift must move the camera's position — otherwise the field is wired to nothing")

	# ...and neither leaks into the flat framing.
	Config.data.world_space_menus = false
	var flat_again: Transform3D = hq._camera_target_xform()
	assert_true(flat_again.origin.is_equal_approx(flat.origin),
		"the flat shot keeps its authored eye")
	assert_true(flat_again.basis.is_equal_approx(flat.basis), "the flat shot keeps its authored aim")


# ENTERING THE MAP TABLE SEATS THE CURSOR ON A PIN THE PLAYER CAN ACTUALLY START: unlocked and not
# yet completed. `_table_targets()` includes LOCKED pins on purpose (readouts are hover-only, so a pin
# you cannot point at is just a shape on a dark table), which is right for hovering and wrong for
# seating — a locked pin is the one target `_activate_table_focus` refuses to open, so parking the
# cursor there hands the player a selection that does nothing when they press enter. And because the
# rule picks the HIGHEST-difficulty incomplete pin, the locked special was very often exactly the one
# it chose.
#
# Locked-ness is forced onto whatever pin the rule would otherwise pick, rather than hoping the fixture
# roster contains a locked special — so this tests the rule, not the roster.
func test_hq_table_entry_never_seats_the_cursor_on_a_locked_pin() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._table_ui._enter_table()
	await get_tree().process_frame

	var first: Node3D = hq._table_focus_node
	assert_not_null(first, "entering the table seats the cursor on something")
	if first == null:
		return
	assert_false(bool(first.get_meta("locked", false)), "and not on a locked pin")

	# Lock the chosen pin and re-enter: the cursor must move to a different, enterable pin rather
	# than staying on the one that can no longer be opened.
	first.set_meta("locked", true)
	hq._table_ui._enter_table()
	await get_tree().process_frame
	var second: Node3D = hq._table_focus_node
	assert_not_null(second, "re-entering still seats the cursor")
	if second == null:
		return
	assert_false(bool(second.get_meta("locked", false)),
		"the locked pin is skipped, not seated on")
