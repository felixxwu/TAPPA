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
	# These tests build hq.tscn many times but never assert on the HQ scenery COUNT
	# (only that a tree field of the right type exists), so trim the framing scatter to
	# keep each of the ~88 HQ builds cheap — the full 320+320 default is a pure-look
	# value exercised in the real game, not here.
	Config.data.hq_tree_count = 8
	Config.data.hq_bush_count = 8
	CarFixtures.install()
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


func after_each() -> void:
	if RallySession.is_active():
		RallySession.abandon()
	RallySession.auto_load_scenes = true
	_clean()
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	Config.reset()
	CarFixtures.restore()
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


# The table target (pin/arrow node) whose position is nearest `center` in the map (XZ)
# plane — the same "reticle over the map" rule the table selection uses.
func _nearest_target_to(hq: Node3D, center: Vector3) -> Node3D:
	var best: Node3D = null
	var best_d := INF
	for t in hq._table_targets():
		var off: Vector3 = Vector3(t["pos"]) - center
		off.y = 0.0
		var d := off.length()
		if d < best_d:
			best_d = d
			best = t["node"]
	return best


# The billboarded readout-box sprite a pin floats above its flag.
# The player's currently-owned car (before_each already grants a starter via
# _pick_starter) — the first entry in the profile's garage.
func _first_owned_car() -> Dictionary:
	return _save.profile["cars"][0]


# Any rally from the (possibly synthetic) catalogue — no assertion on which one, only
# that it exists, so this stays valid under CarFixtures/RallyLibrary overrides.
func _any_rally() -> Dictionary:
	return RallyLibrary.all()[0]


func _pin_label_sprite(pin: Node3D) -> Sprite3D:
	return pin.find_children("*", "Sprite3D", true, false)[0]


# The text on an arrow's floating label (read via the arrow's label_panel meta).
func _arrow_label_text(arrow: Area3D) -> String:
	var panel: PanelContainer = arrow.get_meta("label_panel")
	return (panel.find_children("*", "Label", true, false)[0] as Label).text


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
	assert_eq(hq._pins.size(), RegionLibrary.rallies_in(hq._viewed_region_id()).size(),
		"one map pin per rally in the viewed region")


func test_title_has_focusable_exit_game_button_on_desktop() -> void:
	# The exterior title carries an Exit Game button at the bottom of the list on
	# non-web builds (the headless test host is one). It's a real, focusable widget
	# wired to quit — reachable by keyboard/gamepad, not just the pointer.
	if OS.has_feature("web"):
		pass_test("web build omits Exit Game (the tab owns the process lifecycle)")
		return
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	assert_not_null(hq._title_exit_button, "the title screen has an Exit Game button")
	assert_eq(hq._title_exit_button.focus_mode, Control.FOCUS_ALL,
		"the Exit Game button is keyboard/gamepad focusable")
	# It sits below Settings — the bottom of the title button list.
	var parent: Node = hq._title_settings_button.get_parent()
	assert_gt(hq._title_exit_button.get_index(), hq._title_settings_button.get_index(),
		"Exit Game sits after Settings in the title list")
	assert_eq(hq._title_exit_button.get_parent(), parent,
		"Exit Game lives in the same title button list")


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
	# Open Settings from the title screen — it lands on the category list.
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
	# The bottom button backs out a level at a time: sub-page → list → exterior.
	hq._on_settings_action()
	assert_true(hq._settings_menu.at_root(), "Back from a sub-page returns to the list")
	assert_true(hq._settings_layer.visible, "still in Settings after backing to the list")
	hq._on_settings_action()
	assert_true(hq._title_layer.visible, "Back from the list returns to the title")
	assert_false(hq._settings_layer.visible, "the settings overlay is hidden again")


# --- Keyboard / gamepad navigation -------------------------------------------

# The title is a flat menu (Start / Settings, plus Exit Game on desktop) driven by native
# focus: Start is focused on entry so ui_up/ui_down + ui_accept work the menu with no
# pointer. (Free Roam moved to the garage action row; see test_hq_free_roam_*.)
func test_hq_title_focuses_start_for_keyboard_nav() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	await get_tree().process_frame  # let the deferred grab_focus run
	assert_eq(hq._view, hq.View.EXTERIOR, "boots to the title")
	assert_eq(hq._title_start_button.focus_mode, Control.FOCUS_ALL, "Start is focusable")
	assert_eq(hq.get_viewport().gui_get_focus_owner(), hq._title_start_button,
		"the title focuses Start for keyboard / gamepad")
	assert_eq(hq._title_settings_button.focus_mode, Control.FOCUS_ALL, "Settings is focusable")
	# Settings sits directly after Start in the flat overlay's child order.
	var parent: Node = hq._title_start_button.get_parent()
	assert_eq(parent.get_children().find(hq._title_settings_button),
		parent.get_children().find(hq._title_start_button) + 1,
		"Settings sits directly after Start")


# Regression: menu_select on the title must fire the FOCUSED button (native focus),
# not hard-route to Start. menu_select shares Enter with ui_accept, so a stray
# EXTERIOR menu_select handler used to start the run even when Settings was focused.
func test_hq_title_accept_does_not_force_start() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	await get_tree().process_frame  # let the deferred grab_focus run
	assert_eq(hq._view, hq.View.EXTERIOR, "boots to the title")
	# Focus Settings, then feed a menu_select action as the engine would. The title's
	# input handler must NOT start the run (which would leave EXTERIOR for GARAGE).
	hq._title_settings_button.grab_focus()
	var ev := InputEventAction.new()
	ev.action = "menu_select"
	ev.pressed = true
	hq._unhandled_input(ev)
	assert_eq(hq._view, hq.View.EXTERIOR,
		"menu_select on the title doesn't force Start; the focused button drives accept")


# The build version is shown on the title screen only (it was removed from the
# in-run HUD). build_web.sh stamps application/config/version; editor/test runs
# fall back to the project default ("0.0-dev").
func test_hq_title_shows_build_version() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var ver := str(ProjectSettings.get_setting("application/config/version", ""))
	assert_ne(ver, "", "project.godot defines application/config/version")
	assert_not_null(hq._title_version_label, "the title overlay has a version label")
	# UITheme.enforce() uppercases every overlay label (house style), so the
	# version renders capped (e.g. "V0.0-DEV").
	assert_eq(hq._title_version_label.text, UITheme.caps("v" + ver),
		"the title version label mirrors application/config/version")
	assert_eq(hq._title_version_label.get_parent(), hq._title_layer,
		"the version label lives on the title overlay (shown only there)")


# The map table pans the camera directly: pressing a direction slides the view centre
# that way, and selection snaps to whichever pin/arrow now sits nearest the centre (a
# reticle over the map, not discrete jumps). Select opens the selected rally.
func test_hq_map_table_pans_camera_and_tracks_centre() -> void:
	RegionLibrary.override_for_test([{"id": "home", "name": "Home"}])
	# Three pins at known map_pos: b is "up-map" of a (smaller y), c is off to +x.
	RallyLibrary.override_for_test([
		{"id": "a", "name": "A", "region": "home", "showdown": false, "map_pos": Vector2(0.5, 0.8), "restriction": {}, "events": []},
		{"id": "b", "name": "B", "region": "home", "showdown": false, "map_pos": Vector2(0.5, 0.2), "restriction": {}, "events": []},
		{"id": "c", "name": "C", "region": "home", "showdown": false, "map_pos": Vector2(0.85, 0.5), "restriction": {}, "events": []},
	])
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_table()
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.TABLE, "the map table is open")
	assert_gt(hq._table_focus_index, -1, "a target is selected on entry")

	var axes: Array = hq._table_plane_axes()
	var up: Vector3 = axes[0]

	# Core contract: the selected target is always the one nearest the view centre.
	assert_eq(hq._table_targets()[hq._table_focus_index]["node"],
		_nearest_target_to(hq, hq._table_center_pos()),
		"selection = the target nearest the camera centre on entry")

	# Gliding up slides the camera centre in the screen-up direction...
	var before_up: float = hq._table_center_pos().dot(up)
	hq._pan_table_step(Vector2.UP, 0.4)
	assert_gt(hq._table_center_pos().dot(up), before_up, "gliding up pans the view centre upward")
	# ...and selection re-snaps to whatever is now nearest the centre.
	assert_eq(hq._table_targets()[hq._table_focus_index]["node"],
		_nearest_target_to(hq, hq._table_center_pos()),
		"selection tracks the view centre after panning")

	# Glide fully up (past the clamp): the up-most pin (b) ends up nearest the centre.
	for _i in 12:
		hq._pan_table_step(Vector2.UP, 0.4)
	assert_eq(String(hq._table_targets()[hq._table_focus_index]["node"].get_meta("rally_id")), "b",
		"panning to the top of the map selects the up-most pin")

	# Fresh view, then glide fully right: the right-most pin (c) ends up selected.
	hq._enter_table()
	await get_tree().process_frame
	for _i in 12:
		hq._pan_table_step(Vector2.RIGHT, 0.4)
	var sel: Node3D = hq._table_targets()[hq._table_focus_index]["node"]
	assert_eq(String(sel.get_meta("rally_id")), "c", "panning to the right of the map selects the right-most pin")

	# The selected pin gets the hover-style underline; a pin stays scale 1.
	var box: StyleBoxFlat = sel.get_meta("label_panel").get_theme_stylebox("panel")
	assert_eq(box.border_width_bottom, 3, "the selected pin gets the hover-style underline")
	assert_almost_eq(float(sel.scale.x), 1.0, 0.01, "the selected pin is NOT scaled up")

	# Select on the selected pin opens its rally detail.
	hq._activate_table_focus()
	assert_true(hq._detail_open, "selecting the pin opens its rally detail")
	assert_eq(hq._selected_rally_id, String(sel.get_meta("rally_id")), "it opens the selected pin's rally")
	RegionLibrary.reset()
	RallyLibrary.reset()


# The two regions sit left/right of the map; navigating right from the right-most pin
# lands focus on the RIGHT ARROW (a focus target, highlighted), and select on it swaps
# the region and re-seats focus onto a pin. Left/right no longer swap directly.
func test_table_arrow_is_a_focus_target_that_swaps_on_select() -> void:
	RegionLibrary.override_for_test([
		{"id": "home", "name": "Home"},
		{"id": "greece", "name": "Greece", "map_image": "res://textures/greece.png"},
	])
	RallyLibrary.override_for_test([
		{"id": "h1", "name": "H1", "region": "home", "showdown": false, "map_pos": Vector2(0.3, 0.5), "restriction": {}, "events": []},
		{"id": "h_sd", "name": "HSD", "region": "home", "showdown": true, "map_pos": Vector2(0.5, 0.2), "restriction": {}, "events": []},
		{"id": "g1", "name": "G1", "region": "greece", "showdown": false, "map_pos": Vector2(0.4, 0.5), "restriction": {}, "events": []},
		{"id": "g_sd", "name": "GSD", "region": "greece", "showdown": true, "map_pos": Vector2(0.5, 0.2), "restriction": {}, "events": []},
	])
	_save.profile["rallies"] = {"h1": {"completed": true}, "h_sd": {"completed": true}}
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._go_to(hq.View.TABLE)
	hq._set_viewed_region_for_test(0)  # home
	await get_tree().process_frame

	# The right arrow is in the focus set (a further region exists); the left arrow is not.
	var kinds: Array = []
	for t in hq._table_targets():
		kinds.append(t["kind"])
	assert_true(kinds.has("arrow_right"), "the right arrow is a focus target when a next region exists")
	assert_false(kinds.has("arrow_left"), "no left arrow target at the first region")

	# Glide right until the right arrow (near the map's right edge) is nearest the centre.
	var guard := 0
	while hq._table_targets()[hq._table_focus_index]["kind"] != "arrow_right" and guard < 20:
		hq._pan_table_step(Vector2.RIGHT, 0.4)
		guard += 1
	assert_eq(hq._table_targets()[hq._table_focus_index]["kind"], "arrow_right",
		"gliding right eventually selects the right arrow")
	assert_eq(_arrow_label_text(hq._env.arrow_right).to_lower(), "change map",
		"an unlocked forward arrow reads 'change map'")

	# Select on the arrow swaps the region and re-seats focus on a pin.
	hq._activate_table_focus()
	assert_eq(hq._viewed_region_index, 1, "select on the right arrow advances the viewed region")
	for pin in hq._pins:
		assert_eq(RegionLibrary.region_for_rally(String(pin.get_meta("rally_id"))).get("id", ""),
			"greece", "every pin now belongs to the newly-viewed region")
	assert_eq(hq._table_targets()[hq._table_focus_index]["kind"], "pin",
		"focus re-seats on a pin after the swap")
	RegionLibrary.reset()
	RallyLibrary.reset()


func test_table_arrows_hide_at_the_ends_of_the_region_list() -> void:
	# A swap arrow is only shown when a region exists that way: no left arrow at the
	# first region, no right arrow at the furthest unlocked one. Two unlocked regions
	# (home's showdown completed unlocks greece) → each end hides one arrow.
	RegionLibrary.override_for_test([
		{"id": "home", "name": "Home"},
		{"id": "greece", "name": "Greece"},
	])
	RallyLibrary.override_for_test([
		{"id": "h_sd", "name": "HSD", "region": "home", "showdown": true, "map_pos": Vector2(0.5, 0.2), "restriction": {}, "events": []},
		{"id": "g_sd", "name": "GSD", "region": "greece", "showdown": true, "map_pos": Vector2(0.5, 0.2), "restriction": {}, "events": []},
	])
	_save.profile["rallies"] = {"h_sd": {"completed": true}}  # unlocks greece
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._go_to(hq.View.TABLE)
	hq._set_viewed_region_for_test(0)  # first region
	assert_false(hq._env.arrow_left.visible, "no left arrow at the first region")
	assert_false(hq._env.arrow_left.input_ray_pickable, "hidden left arrow is not clickable")
	assert_true(hq._env.arrow_right.visible, "right arrow shown when a next region exists")
	hq._set_viewed_region_for_test(1)  # furthest unlocked
	assert_true(hq._env.arrow_left.visible, "left arrow shown when a prev region exists")
	assert_false(hq._env.arrow_right.visible, "no right arrow at the furthest unlocked region")
	assert_false(hq._env.arrow_right.input_ray_pickable, "hidden right arrow is not clickable")
	RegionLibrary.reset()
	RallyLibrary.reset()


# The forward arrow is shown even when the next region is LOCKED, floating a dimmed
# "Complete showdown to unlock" label; it is a landable focus target but select on it
# is inert (no swap). An unlocked/back arrow instead reads "Change map".
func test_table_arrow_labels_reflect_lock_state() -> void:
	RegionLibrary.override_for_test([
		{"id": "home", "name": "Home"},
		{"id": "greece", "name": "Greece"},
		{"id": "alps", "name": "Alps"},
	])
	RallyLibrary.override_for_test([
		{"id": "h1", "name": "H1", "region": "home", "showdown": false, "map_pos": Vector2(0.3, 0.5), "restriction": {}, "events": []},
		{"id": "h_sd", "name": "HSD", "region": "home", "showdown": true, "map_pos": Vector2(0.5, 0.2), "restriction": {}, "events": []},
		{"id": "g1", "name": "G1", "region": "greece", "showdown": false, "map_pos": Vector2(0.4, 0.5), "restriction": {}, "events": []},
	])
	# No rallies completed → greece and alps stay locked.
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._go_to(hq.View.TABLE)
	hq._set_viewed_region_for_test(0)  # home (first region)
	await get_tree().process_frame

	assert_true(hq._env.arrow_right.visible, "forward arrow is shown even when the next region is locked")
	assert_eq(_arrow_label_text(hq._env.arrow_right).to_lower(), "complete showdown to unlock",
		"a locked forward arrow prompts to complete the showdown")

	# The locked arrow is a landable focus target.
	var kinds: Array = []
	for t in hq._table_targets():
		kinds.append(t["kind"])
	assert_true(kinds.has("arrow_right"), "the locked forward arrow is a focus target")

	# Glide onto it and select: inert — the region does not change and focus stays.
	var guard := 0
	while hq._table_targets()[hq._table_focus_index]["kind"] != "arrow_right" and guard < 20:
		hq._pan_table_step(Vector2.RIGHT, 0.4)
		guard += 1
	assert_eq(hq._table_targets()[hq._table_focus_index]["kind"], "arrow_right", "cursor reached the locked arrow")
	hq._activate_table_focus()
	assert_eq(hq._viewed_region_index, 0, "select on a locked forward arrow does not swap the region")
	assert_eq(hq._table_targets()[hq._table_focus_index]["kind"], "arrow_right", "focus stays on the locked arrow")
	RegionLibrary.reset()
	RallyLibrary.reset()


# The tuning hub is a manual up/down cursor over Change Car / Tuning / Upgrades;
# select fires the focused item, opening a page (native focus) or the car park.
func test_hq_lift_hub_has_an_up_down_cursor() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	_save.grant_car("fx_fwd_hatch")  # a second car so Change Car is enabled + navigable
	hq._enter_lift()
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.LIFT, "the tuning bay is open")
	assert_eq(hq._lift_page, hq.LiftPage.HUB, "it opens on the hub")
	# The hub is a left/right cursor over Back (0) / Change Car (1) / Tuning (2) /
	# Upgrades (3), wrapping at both ends.
	assert_eq(hq._hub_focus, 1, "the hub cursor starts on Change Car")
	hq._move_hub_focus(1)
	assert_eq(hq._hub_focus, 2, "right moves the cursor to Tuning")
	hq._move_hub_focus(1)
	assert_eq(hq._hub_focus, 3, "right again moves the cursor to Upgrades")
	hq._move_hub_focus(1)
	assert_eq(hq._hub_focus, 0, "right from the end wraps to Back")
	hq._move_hub_focus(-1)
	assert_eq(hq._hub_focus, 3, "left from Back wraps to Upgrades")

	# Select on the Change Car item drops into the car park.
	hq._hub_focus = 1
	hq._activate_hub_focus()
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.CARPARK, "select on Change Car opens the car park")
	assert_eq(hq._carpark_mode, hq.CarparkMode.CHANGE, "in change-car mode")
	hq._car_back()
	await get_tree().process_frame

	# Opening the Tune page seats native focus on one of its sliders.
	hq._open_lift_page(hq.LiftPage.TUNE)
	await get_tree().process_frame
	assert_true(hq.get_viewport().gui_get_focus_owner() is HSlider,
		"opening the Tune page focuses a tuning slider for keyboard/gamepad")


# Regression: the Upgrades page must seat keyboard/gamepad focus on a real control.
# On a fresh car it has no installed parts, is at full health (no repair button) and
# its Swap Engine button is disabled, so without an always-enabled control (the Back
# button) focus would land on nothing and the page would be dead to non-pointer input.
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
	hq._lift_upgrades_box.rebuild()  # a fresh rebuild (as a car swap / toggle would trigger)
	await get_tree().process_frame
	assert_eq(_count_menunav(hq._lift_upgrades_box), 1,
		"the rebuild preserves exactly one focus-nav helper (WASD/gamepad nav survives)")


func _count_menunav(box: Node) -> int:
	var n := 0
	for c in box.get_children():
		if c is MenuNav and not c.is_queued_for_deletion():
			n += 1
	return n


# Regression: picking an option on the Upgrades page rebuilds the rows; the keyboard/gamepad
# cursor must stay on THAT option, not jump to the top of the list (or go null when the
# deferred re-grab lands on the freed old button). Uses whatever the catalogue offers
# (opaque — no dependence on a specific entry), skipping the drivetrain slot (its selector
# needs the swap kit; the fitted part below lands in one of the generic option slots).
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
	# Focus an available option button, then activate it (which rebuilds the rows).
	var opt: Button = null
	for node in hq._lift_upgrades_box.find_children("*", "Button", true, false):
		if node is Button and not (node as Button).disabled and node.has_meta("upgrade_focus_key") \
				and String(node.get_meta("upgrade_focus_key")).begins_with("opt:"):
			opt = node
			break
	assert_true(opt != null, "the slot shows a focusable option button")
	var key := String(opt.get_meta("upgrade_focus_key"))
	opt.grab_focus()
	await get_tree().process_frame
	opt.pressed.emit()
	await get_tree().process_frame
	await get_tree().process_frame
	var after: Control = hq.get_viewport().gui_get_focus_owner()
	assert_true(after != null, "focus is not lost after picking an option")
	assert_true(after != null and after.has_meta("upgrade_focus_key") \
			and String(after.get_meta("upgrade_focus_key")) == key,
		"focus stays on the same option after the rebuild (doesn't jump to the top)")


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


# Regression: the shared "< Back" button on a sub-page lives outside the scroll
# container (a different node level), but must still be reachable by keyboard/gamepad —
# menu_down off the last slider walks through Reset and lands on Back.
func test_hq_tune_page_can_navigate_down_to_back_button() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_lift()
	await get_tree().process_frame
	hq._open_lift_page(hq.LiftPage.TUNE)
	await get_tree().process_frame
	assert_true(hq.get_viewport().gui_get_focus_owner() is HSlider, "starts on a slider")
	assert_eq(hq._lift_back_button.focus_mode, Control.FOCUS_ALL, "the Back button is focusable")
	var reached := false
	for i in range(8):
		if hq.get_viewport().gui_get_focus_owner() == hq._lift_back_button:
			reached = true
			break
		_press_action("menu_down")
		await get_tree().process_frame
	assert_true(reached, "menu_down from the sliders reaches the shared Back button")


func _press_action(action: String) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	get_viewport().push_input(ev)


func test_hq_dev_page_unlocks_cars_upgrades_and_wipes() -> void:
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
	dev._fit_upgrade("turbo_small", "Small Turbo")
	assert_true((_save.selected_car().get("installed_upgrades", []) as Array).has("turbo_small"),
		"fitting an upgrade installs it on the selected car")
	assert_eq(int(_save.profile["inventory"].get("turbo_small", 0)), 0,
		"fitting an upgrade does not touch the consumable inventory")
	# The repair kit is the one true consumable — it still lands in inventory.
	dev._add_upgrade(UpgradeLibrary.REPAIR_KIT_ID, "Repair Kit")
	assert_eq(int(_save.profile["inventory"].get(UpgradeLibrary.REPAIR_KIT_ID, 0)), 1,
		"adding the repair kit puts it in inventory")
	# Wipe: everything resets to a fresh new game.
	dev._wipe_progress()
	assert_eq(int(_save.profile["cars"].size()), 0, "wipe clears all owned cars")
	assert_true((_save.profile["inventory"] as Dictionary).is_empty(), "wipe clears the inventory")


func test_hq_title_parks_all_owned_cars() -> void:
	# The title shows the whole collection, regardless of rally eligibility — grant
	# an RWD XJS (which an RWD rally would exclude) and it's still parked.
	_save.grant_car("fx_awd")
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	await _await_lineup(hq)
	assert_eq(hq._cars.size(), 2, "the title parks every owned car (starter + XJS)")


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


# The lift-HUB Repair button reflects the SELECTED car's state: it's DISABLED when
# there's nothing to do — full health, or damaged with no kit — and only enabled when a
# kit can restore a damaged car; its label spells out the case. Enabled, pressing it
# spends one Repair Kit to fully restore the car. (The button is currently HIDDEN while
# Repair Kits are disabled, but the label/repair logic still holds — see
# todo/remove-repair-kits.md.)
func test_hq_lift_repair_button_reflects_state_and_repairs() -> void:
	# A second, healthy car so the wreck-recovery safety net (a free kit when EVERY car is
	# wrecked) doesn't fire and mask the "no kits" state under test.
	_save.grant_car("fx_fwd_hatch")
	var id := int(_save.profile["cars"][0]["instance_id"])
	_save.set_selected_car(id)
	var max_hp := float(CarLibrary.by_id(String(_save.get_car(id)["model_id"]))["max_hp"])

	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame

	# Healthy selected car: nothing to repair, so the button is disabled.
	hq._refresh_lift_repair_button()
	assert_string_contains(hq._lift_repair_button.text.to_lower(), "full health",
		"a full-health selected car reads 'Repair — full health'")
	assert_true(hq._lift_repair_button.disabled, "a full-health car disables Repair")

	# Wreck it with no kits: still disabled (nothing can be done), label flags the kit.
	_save.wreck_car(id)
	_save.profile["inventory"] = {}
	hq._refresh_lift_repair_button()
	assert_string_contains(hq._lift_repair_button.text.to_lower(), "no kits",
		"a damaged car with no kit reads 'Repair — no kits'")
	assert_true(hq._lift_repair_button.disabled, "no kit disables Repair")

	# Grant a kit: the button ENABLES, and pressing it fully restores the car.
	_save.add_item(UpgradeLibrary.REPAIR_KIT_ID, 1)
	hq._refresh_lift_repair_button()
	assert_string_contains(hq._lift_repair_button.text.to_lower(), "kit",
		"a damaged car with a kit reads 'Repair (n kit)'")
	assert_false(hq._lift_repair_button.disabled, "a damaged car with a kit enables Repair")
	hq._repair_selected_car()
	assert_almost_eq(float(_save.get_car(id)["hp"]), max_hp, 0.001,
		"repairing from the lift restores the selected car to full health")
	assert_true(hq._lift_repair_button.disabled, "once restored, Repair disables again")

	# Full health again: pressing Repair is a no-op — no further kit is spent.
	var kits_before := int(_save.profile.get("inventory", {}).get(UpgradeLibrary.REPAIR_KIT_ID, 0))
	hq._repair_selected_car()
	assert_eq(int(_save.profile.get("inventory", {}).get(UpgradeLibrary.REPAIR_KIT_ID, 0)), kits_before,
		"repairing a full-health car spends no kit")


func test_hq_start_flies_into_the_garage() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	assert_eq(hq._view, hq.View.GARAGE, "Start flies the camera into the garage")
	assert_true(hq._garage_layer.visible, "the garage overlay is shown")
	assert_false(hq._title_layer.visible, "the title overlay is hidden in the garage")


# The garage overlay is a left/right cursor over Back (0) / Map (1) / Tune Car (2) /
# Free Roam (3), wrapping at both ends, with select firing the item under the cursor.
# (Repair lives on the tuning-lift HUB row now, not the garage.)
func test_hq_garage_is_a_left_right_cursor() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	assert_eq(hq._view, hq.View.GARAGE, "start lands in the garage")
	assert_eq(hq._garage_focus, 1, "the garage cursor starts on Map")
	hq._move_garage_focus(1)
	assert_eq(hq._garage_focus, 2, "right moves the cursor to Tune Car")
	hq._move_garage_focus(1)
	assert_eq(hq._garage_focus, 3, "right moves the cursor to Free Roam")
	hq._move_garage_focus(1)
	assert_eq(hq._garage_focus, 0, "right from the end wraps to Back")
	hq._move_garage_focus(-1)
	assert_eq(hq._garage_focus, 3, "left from Back wraps to Free Roam")

	# Select on the map-table item opens the map.
	hq._garage_focus = 1
	hq._activate_garage_focus()
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.TABLE, "select on Map opens the map")

	# Back-to-garage, then select on the Back item leaves for the exterior.
	hq._go_to(hq.View.GARAGE)
	assert_eq(hq._garage_focus, 1, "re-entering the garage re-seats the cursor on Map")
	hq._garage_focus = 0
	hq._activate_garage_focus()
	assert_eq(hq._view, hq.View.EXTERIOR, "select on Back leaves the garage for the exterior")


# Free Roam launches a plain drive: no rally session, and a fresh random seed each
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


# Free roam rolls a random lake depth, large-scale relief, and home/Greece location
# each entry — every roll must land inside the requested ranges / region set.
func test_hq_free_roam_randomises_water_relief_and_location() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	for _i in 20:
		hq._prepare_free_roam()
		assert_between(Config.data.track_water_level_m, -15.0, -5.0,
			"free-roam water level stays in the -15..-5 band")
		assert_between(Config.data.terrain_layer1_amplitude, 10.0, 35.0,
			"free-roam layer-1 amplitude stays in the 10..35 band")
		assert_true(RallySession.free_roam_region_id in ["home", "greece"],
			"free-roam location is home or Greece")


# Free Roam (from the GARAGE action row) opens the car park to pick which owned car
# to drive: the whole owned collection is parked, and Back returns to the garage.
func test_hq_free_roam_opens_the_car_park_to_pick_a_car() -> void:
	_save.grant_car("fx_fwd_hatch")  # a second car so the collection isn't just the starter
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame

	hq._enter_free_roam()
	await _await_lineup(hq)
	assert_eq(hq._view, hq.View.CARPARK, "Free Roam drops into the car park")
	assert_eq(hq._carpark_mode, hq.CarparkMode.FREEROAM, "the car park is in free-roam mode")
	assert_eq(hq._eligible.size(), _save.profile["cars"].size(),
		"the whole owned collection is parked to pick from")

	# Back leaves free roam for the garage.
	hq._car_back()
	assert_ne(hq._carpark_mode, hq.CarparkMode.FREEROAM, "backing out clears free-roam mode")
	assert_eq(hq._view, hq.View.GARAGE, "Back from free-roam car pick returns to the garage")


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
	assert_eq(String(requested[0]), "res://hq.tscn",
		"the free-roam finish panel's Next returns to HQ")
	RallySession.free_roam_instance_id = -1


# A rival who crashed out of THIS event is staged by the roadside: their ACTUAL car
# frozen as a solid obstacle (hitbox kept), lazy engine smoke, and a small standing
# crowd around it (features/opponent-wrecks.md). Drives the real world build with an
# active session whose field wrecks one rival in event 0.
func test_run_scene_stages_a_roadside_opponent_wreck() -> void:
	var owned: Dictionary = _save.grant_car("fx_light_rwd")
	RallySession.start_rally(RallyLibrary.by_id("coastal_sprint"), owned, true)
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
	hq._enter_table()
	assert_eq(hq._view, hq.View.TABLE, "tapping the table drops the camera to the map view")
	assert_true(hq._table_layer.visible, "the map HUD is shown")
	assert_string_contains(hq._map_meter.text, "PROGRESS TO THE SHOWDOWN", "the progress meter is shown")


func test_hq_map_locks_the_showdown_until_all_others_complete() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var showdown := _pin_for(hq, "the_showdown")
	assert_true(bool(showdown.get_meta("locked")),
		"the showdown pin is locked until every other rally is completed")
	assert_eq(showdown.find_children("*", "Area3D", true, false).size(), 0,
		"a locked pin is not pickable (no hit area)")
	var normal := _pin_for(hq, "shakedown")
	assert_false(bool(normal.get_meta("locked")), "a normal rally pin is unlocked")
	var areas := normal.find_children("*", "Area3D", true, false)
	assert_eq(areas.size(), 2, "an unlocked pin is pickable on BOTH the flag and its menu box")
	# One hit target sits up at the readout box (flag pole + label rise), so a click on
	# the menu itself enters the rally just like a click on the flag.
	var label_y: float = RallyFlag.POLE_HEIGHT + hq.PIN_LABEL_RISE
	var menu_targets := 0
	for a in areas:
		if absf((a as Area3D).position.y - label_y) < 0.01:
			menu_targets += 1
	assert_eq(menu_targets, 1, "the floating menu box is itself a click target")


func test_hq_unavailable_rally_dims_its_floating_readout() -> void:
	# A rally that can't be entered yet (the locked showdown) greys out its floating
	# readout box; an available rally (open-class shakedown, starter eligible) is
	# shown at full brightness.
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var showdown_sprite := _pin_label_sprite(_pin_for(hq, "the_showdown"))
	var shakedown_sprite := _pin_label_sprite(_pin_for(hq, "shakedown"))
	assert_eq(showdown_sprite.modulate, hq.PIN_LABEL_DIM, "the locked showdown's readout is dimmed")
	assert_eq(shakedown_sprite.modulate, Color.WHITE, "an available rally's readout is full brightness")


func test_hq_pins_stars_reflect_best_placement() -> void:
	# A 1st-place best earns 3 stars; a 3rd-place best earns 1.
	_save.complete_rally("shakedown", 60000, 1)
	_save.complete_rally("coastal_sprint", 90000, 3)
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	assert_eq(hq._stars_for("shakedown"), 3, "1st place earns 3 stars")
	assert_eq(hq._stars_for("coastal_sprint"), 1, "3rd place earns 1 star")
	assert_eq(hq._stars_for("rwd_masters"), 0, "an unplayed rally earns 0 stars")
	# The readout box on the pin is the design-system black panel (a Sprite3D) carrying
	# a StarRow lit to the earned count — and no leftover 3D sphere "stars".
	var pin := _pin_for(hq, "shakedown")
	assert_gt(pin.find_children("*", "Sprite3D", true, false).size(), 0,
		"the pin carries a billboarded readout box (Sprite3D)")
	var rows := pin.find_children("*", "StarRow", true, false)
	assert_eq(rows.size(), 1, "the readout box holds one StarRow")
	assert_eq((rows[0] as StarRow).earned, 3, "the StarRow is lit to the earned star count")
	assert_eq((rows[0] as StarRow).total, hq.MAX_STARS, "out of MAX_STARS stars")


func test_hq_tapping_a_pin_opens_its_detail() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	hq._enter_table()
	hq._on_rally_pin("rwd_masters")
	assert_true(hq._detail_open, "tapping a pin opens the rally detail")
	assert_true(hq._detail_layer.visible, "the detail overlay is shown")
	assert_false(hq._table_layer.visible, "the map HUD is hidden behind the detail")
	assert_string_contains(hq._detail_title.text, "RWD MASTERS", "the detail names the rally")
	assert_string_contains(hq._detail_restriction.text, "RWD CARS", "the detail spells out the eligibility")


func test_hq_table_drag_pans_and_clamps() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_table()
	assert_eq(hq._table_pan, Vector3.ZERO, "the map re-centres when opened")
	hq._pan_table(Vector2(-100, -50))
	assert_gt(hq._table_pan.x, 0.0, "dragging pans the map view")
	# A huge drag clamps to the map extents (half the plane each way).
	hq._pan_table(Vector2(-100000, -100000))
	var cfg: GameConfig = Config.data
	assert_almost_eq(hq._table_pan.x, cfg.hq_map_plane_size.x * 0.5, 0.001, "pan clamps to the map's far X edge")
	assert_almost_eq(hq._table_pan.z, cfg.hq_map_plane_size.y * 0.5, 0.001, "pan clamps to the map's far Z edge")


func test_hq_dragging_the_map_does_not_open_a_rally() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_table()
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
	hq._on_pin_input(null, release, Vector3.ZERO, Vector3.ZERO, 0, "shakedown")
	assert_false(hq._detail_open, "dragging the map does not open the pin under the finger")
	# A clean tap (no drag) on a pin DOES open it (selection fires on release).
	hq._table_dragged = false
	hq._on_pin_input(null, release, Vector3.ZERO, Vector3.ZERO, 0, "shakedown")
	assert_true(hq._detail_open, "a tap with no drag opens the rally detail")


func test_hq_choosing_a_rally_filters_to_eligible_cars() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	# RWD Masters wants RWD cars inside a mid power-to-weight band. Own an XJS and a
	# 911 alongside the low-power RWD starter, pick that rally and enter: HQ parks
	# exactly the owned cars the eligibility rule accepts (derived below, not pinned).
	_save.grant_car("fx_awd")
	_save.grant_car("fx_rwd_coupe")
	hq._on_rally_pin("rwd_masters")
	hq._enter_car_screen()
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.CARPARK, "Enter Rally flies out to the car park")
	assert_true(hq._car_layer.visible, "the car-park overlay is shown")
	assert_false(hq._detail_layer.visible, "the detail overlay is hidden in the car park")
	# Expected = exactly the owned cars RallyLibrary deems eligible, plus any
	# over-powered car a detune would qualify (those park with a detune-to-enter
	# prompt — see test_hq_carpark_offers_detune_to_enter_an_over_powered_car).
	# Derived from the eligibility rule + owned roster (not a pinned model name), so
	# it stays correct if cars or the rally's p/w band are retuned — what it really
	# asserts is that HQ parks the library's enterable set, no more, no less.
	var rally := RallyLibrary.by_id("rwd_masters")
	var expected := {}
	for model_id in ["fx_light_rwd", "fx_awd", "fx_rwd_coupe"]:  # the player's owned roster here
		var spec := CarLibrary.by_id(model_id)
		var frac := RallyLibrary.qualifying_detune(rally, spec)
		var over_cap: bool = CarLibrary.power_to_weight(spec) * RallyLibrary.KW_KG_TO_HP_TONNE \
			> float(rally["restriction"].get("pw_max", INF))
		if RallyLibrary.is_eligible(rally, spec) or (over_cap and frac > 0.0):
			expected[spec["name"]] = true
	await _await_lineup(hq)
	var parked := {}
	for car in hq._cars:
		parked[car.current_car_name()] = true
	assert_eq(parked, expected, "HQ parks exactly the eligible + detunable-to-fit cars")
	assert_gt(expected.size(), 0, "at least one owned car qualifies (else the test proves nothing)")
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
	hq._on_rally_pin("the_showdown")  # open-class: all three are eligible
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
	hq._on_rally_pin("the_showdown")  # open-class: starter + XJS both eligible
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
	hq._on_rally_pin("the_showdown")  # open-class: both cars eligible
	hq._enter_car_screen()
	await get_tree().process_frame
	await _await_lineup(hq)
	assert_eq(hq._cars.size(), 2, "both eligible cars are parked")
	assert_eq(hq._selected_instance_id, int(hq._eligible[0]["instance_id"]), "the first car is selected on entry")
	hq._cycle_focus(1)
	assert_eq(hq._focus, 1, "cycling right advances the focus")
	assert_eq(hq._selected_instance_id, int(hq._eligible[1]["instance_id"]), "the newly focused car is selected")
	hq._focus = 0
	hq._cycle_focus(-1)
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
	hq._on_rally_pin("the_showdown")  # open-class: both cars eligible
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
	hq._on_rally_pin("the_showdown")
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


# The car-park / overflow overlays must NOT swallow pointer input: everything but
# the buttons is MOUSE_FILTER_IGNORE (via _passthrough_overlay), or a desktop click /
# touch tap would stop at the full-rect container and never reach _unhandled_input's
# swipe + tap-a-car handling.
func test_hq_lineup_overlays_pass_pointer_input_through() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	for layer in [hq._car_layer, hq._overflow_layer]:
		var root: Control = (layer as CanvasLayer).get_child(0)
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
	hq._on_rally_pin("the_showdown")  # open-class: starter + the two granted cars
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
	var bays: int = max(1, cfg.max_owned_cars)
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
	hq._on_rally_pin("shakedown")
	hq._enter_car_screen()
	await get_tree().process_frame
	var car_pos: Vector3 = hq._focused_car_pos()
	var xform: Transform3D = hq._camera_target_xform()
	assert_gt(xform.origin.z, car_pos.z, "the camera is in front of the car (+Z), not behind it")
	var forward: Vector3 = -xform.basis.z  # a camera looks down its local −Z
	assert_lt(forward.z, 0.0, "the camera looks back toward the car and the garage (−Z)")


# --- Garage overflow: scrap a car to make room (max_owned_cars) --------------

# Boot HQ owning more than the cap and it routes to the OVERFLOW scrap prompt
# (instead of the title), parking the whole collection.
func test_hq_over_car_limit_boots_to_the_scrap_prompt() -> void:
	Config.data.max_owned_cars = 2  # small cap so the test stays light
	_save.grant_car("fx_awd")
	_save.grant_car("fx_rwd_coupe")  # 2 granted; the boot starter makes 3 > cap
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.OVERFLOW, "over the cap, HQ boots to the scrap prompt")
	assert_true(hq._overflow_layer.visible, "the overflow overlay is shown")
	assert_false(hq._title_layer.visible, "the title overlay is hidden while overflowing")
	await _await_lineup(hq)
	assert_eq(hq._cars.size(), 3, "the whole collection is parked to choose from")
	assert_string_contains(hq._overflow_banner.text, "3 / 2", "the banner shows owned vs the cap")


# Scrapping cars drops the count and, once back at the cap, flies out to the title.
func test_hq_scrapping_clears_overflow_and_returns_to_title() -> void:
	Config.data.max_owned_cars = 2
	_save.grant_car("fx_awd")
	_save.grant_car("fx_rwd_coupe")
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	assert_eq(_save.profile["cars"].size(), 3, "3 owned at boot (starter + 2)")
	# Scrap the focused car (any car is scrappable while others remain).
	hq._on_scrap_pressed()
	await get_tree().process_frame
	assert_eq(_save.profile["cars"].size(), 2, "scrapping removed one car")
	assert_eq(hq._view, hq.View.EXTERIOR, "back at the cap, HQ flies out to the title")
	assert_true(hq._title_layer.visible, "the title overlay is shown again")


# The player's last car can't be scrapped: with a 0 cap the lone owned car still
# overflows, and its scrap button is disabled with a note (keeps ≥1 car so the
# repair-kit safety net always has something to bring back).
func test_hq_overflow_cannot_scrap_last_car() -> void:
	Config.data.max_owned_cars = 0  # even one owned car overflows
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	assert_eq(_save.profile["cars"].size(), 1, "just the boot starter owned")
	assert_eq(hq._view, hq.View.OVERFLOW, "over the (zero) cap on boot")
	await _await_lineup(hq)
	assert_true(hq._scrap_button.disabled, "the last owned car's scrap action is disabled")
	assert_string_contains(hq._overflow_note.text.to_lower(), "last car", "a note explains why")
	# Scrapping it anyway is a no-op (count unchanged, still overflowing).
	hq._on_scrap_pressed()
	assert_eq(_save.profile["cars"].size(), 1, "the last car wasn't scrapped")
	assert_eq(hq._view, hq.View.OVERFLOW, "still in the scrap prompt")


# At or under the cap, HQ boots straight to the title (no scrap prompt).
func test_hq_at_car_limit_boots_to_the_title() -> void:
	Config.data.max_owned_cars = 3
	_save.grant_car("fx_awd")
	_save.grant_car("fx_rwd_coupe")  # starter + 2 = 3 == cap (not over)
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.EXTERIOR, "at the cap (not over), HQ boots to the title")
	assert_false(hq._overflow_layer.visible, "no scrap prompt at the cap")


func test_hq_carpark_gates_a_wrecked_car_and_repairs_it() -> void:
	# A wrecked (0 HP) car still appears in the eligible lineup, but it's too damaged
	# to enter — Start is disabled until a Repair Kit restores it to full health.
	var owned: Dictionary = _save.grant_car("fx_awd")
	var id := int(owned["instance_id"])
	_save.apply_damage(id, 999999.0)  # wreck it (kept at 0 HP, not deleted)
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_rally_pin("the_showdown")  # open-class: starter + XJS both eligible
	hq._enter_car_screen()
	await get_tree().process_frame
	# Focus the wrecked XJS in the lineup.
	var idx := -1
	for i in hq._eligible.size():
		if int(hq._eligible[i]["instance_id"]) == id:
			idx = i
	assert_gt(idx, -1, "the wrecked car is still parked in the lineup")
	hq._focus = idx
	hq._focus_changed()
	# Too damaged, no kit: Start disabled, the warning shows, no Repair offered.
	assert_true(hq._start_button.disabled, "a wrecked car cannot be entered")
	assert_true(hq._car_warning_label.visible, "the too-damaged warning is shown")
	assert_false(hq._car_repair_button.visible, "no Repair option without a kit")
	# Grant a kit and refresh: the Repair option appears.
	_save.add_item("repair_kit", 1)
	hq._focus_changed()
	assert_true(hq._car_repair_button.visible, "with a kit available, Repair is offered")
	# Repair: full restore, Start unlocks, the warning clears.
	hq._repair_focused_car()
	assert_false(hq._start_button.disabled, "repairing the car enables Start")
	assert_false(hq._car_warning_label.visible, "the warning clears once repaired")
	assert_almost_eq(float(_save.get_car(id)["hp"]), float(CarLibrary.by_id("fx_awd")["max_hp"]), 0.001,
		"the repaired car is restored to full health")


func test_hq_carpark_routes_over_powered_car_to_change_upgrades() -> void:
	# A car OVER a rally's pw_max cap still parks in the car-select lineup and LOOKS
	# eligible there (no warning label, plain Start — the overlay stays compact).
	# Pressing Start pops a "Too powerful" confirm that routes to Change Upgrades (the
	# gated upgrades menu) — NOT a one-press auto-detune. The player sheds power there.
	var owned: Dictionary = _save.grant_car("fx_rwd_coupe")
	var id := int(owned["instance_id"])
	# A synthetic rally whose pw_max sits between the starter's p/w and the coupe's,
	# so the starter is plainly eligible and the coupe is over the cap — the cap is
	# derived from the cars' own effective figures, never a pinned number.
	var pw_starter := CarLibrary.power_to_weight(UpgradeLibrary.effective_meta(
		_save.profile["cars"][0], CarLibrary.by_id("fx_light_rwd"))) * RallyLibrary.KW_KG_TO_HP_TONNE
	var pw_coupe := CarLibrary.power_to_weight(UpgradeLibrary.effective_meta(
		owned, CarLibrary.by_id("fx_rwd_coupe"))) * RallyLibrary.KW_KG_TO_HP_TONNE
	assert_gt(pw_coupe, pw_starter, "the coupe out-powers the starter (else this test proves nothing)")
	var rallies: Array[Dictionary] = [
		{
			"id": "fx_capped", "name": "Fixture Capped", "difficulty": 1, "showdown": false,
			"map_pos": Vector2(0.3, 0.3),
			"restriction": {"pw_max": (pw_starter + pw_coupe) * 0.5},
			"events": [
				{"seed": 11, "turn_count": 4}, {"seed": 12, "turn_count": 4}, {"seed": 13, "turn_count": 4},
			],
		},
		{
			"id": "fx_showdown", "name": "Fixture Showdown", "difficulty": 4, "showdown": true,
			"map_pos": Vector2(0.7, 0.7), "restriction": {},
			"events": [
				{"seed": 21, "turn_count": 4}, {"seed": 22, "turn_count": 4}, {"seed": 23, "turn_count": 4},
			],
		},
	]
	RallyLibrary.override_for_test(rallies)
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_rally_pin("fx_capped")
	hq._enter_car_screen()
	await get_tree().process_frame
	# Both cars park: the eligible starter AND the over-cap coupe, which carries the
	# detune that would qualify it.
	assert_eq(hq._eligible.size(), 2, "the over-powered car still parks alongside the eligible one")
	assert_true(hq._detune_needed.has(id), "the over-cap car carries its qualifying detune")
	var frac: float = hq._detune_needed.get(id, -1.0)
	assert_between(frac, 0.01, 0.99, "the qualifying detune is a real down-tune")
	# Focus the over-powered coupe: it LOOKS eligible — no warning label, the plain
	# Start label, and Start enabled. The detune agreement only surfaces on press.
	var idx := -1
	for i in hq._eligible.size():
		if int(hq._eligible[i]["instance_id"]) == id:
			idx = i
	assert_gt(idx, -1, "the over-powered car is in the lineup")
	hq._focus = idx
	hq._focus_changed()
	assert_false(hq._car_warning_label.visible, "no warning label — the car looks eligible in the park")
	assert_false(hq._start_button.disabled, "Start stays enabled — pressing it opens the agreement")
	# The overlays upper-case their labels (house style), so compare case-insensitively.
	assert_eq(hq._start_button.text.to_upper(), "START RALLY",
		"the over-powered car keeps the plain Start label")
	# Press Start: instead of launching, the "Too powerful" confirm pops offering Change
	# Upgrades (not a one-press detune). Nothing is applied and the rally doesn't launch.
	await hq._on_start_pressed()
	assert_true(is_instance_valid(hq._active_carpark_popup),
		"pressing Start on an over-powered car pops the over-limit prompt")
	var popup: ConfirmPopup = hq._active_carpark_popup
	assert_string_contains(popup._buttons[0].text.to_upper(), "CHANGE UPGRADES",
		"the first choice routes to the upgrades menu")
	for b in popup._buttons:
		assert_false("detune" in (b as Button).text.to_lower(),
			"there is no one-press auto-detune button anymore")
	assert_false(RallySession.is_active(), "the rally does not launch from the prompt")
	assert_almost_eq(float(_save.get_car(id).get("tuning", {}).get("engine_detune", 1.0)), 1.0, 0.0001,
		"nothing is applied to the car by the prompt")
	# Choosing Change Upgrades opens the gated upgrades popup where the player sheds power.
	hq._detune_change_upgrades()
	assert_true(hq._upgrades_popup != null and hq._upgrades_popup.visible,
		"Change Upgrades opens the upgrades popup")


func test_hq_carpark_excludes_a_car_below_the_band_floor() -> void:
	# A car below a rally's p/w BAND floor — even at its MAX potential (full tune + kits
	# enabled + ballast dropped) — is INELIGIBLE, so it never parks in the rally's eligible
	# lineup. This is the observable consequence of the retired soft "Underpowered but Start
	# Anyway" prompt: there is no eligible-but-underpowered state to warn about anymore.
	# Derived from the car's own max-potential figure so it's not pinned to authored stats.
	var owned: Dictionary = _save.profile["cars"][0]
	var id := int(owned["instance_id"])
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var entry := CarLibrary.by_id(String(owned.get("model_id", "")))
	var pw := CarLibrary.power_to_weight(UpgradeLibrary.max_potential_meta(owned, entry)) * RallyLibrary.KW_KG_TO_HP_TONNE
	var rallies: Array[Dictionary] = [
		{
			"id": "fx_high_band", "name": "Fixture High Band", "difficulty": 2, "showdown": false,
			"map_pos": Vector2(0.4, 0.4),
			# A band whose FLOOR sits above the car's max potential -> ineligible.
			"restriction": {"pw_min": pw * 1.5},
			"events": [
				{"seed": 31, "turn_count": 4}, {"seed": 32, "turn_count": 4}, {"seed": 33, "turn_count": 4},
			],
		},
	]
	RallyLibrary.override_for_test(rallies)
	hq._on_rally_pin("fx_high_band")
	hq._enter_car_screen()
	await get_tree().process_frame
	await _await_lineup(hq)
	var idx := -1
	for i in hq._eligible.size():
		if int(hq._eligible[i]["instance_id"]) == id:
			idx = i
	assert_eq(idx, -1, "a car below the band floor (even at max potential) is not in the eligible lineup")
	RallyLibrary.reset()


func test_swap_car_qualifies_for_restricted_rally() -> void:
	# A car whose STOCK mode fails a RWD-only rally becomes eligible once it carries the
	# swap kit (it can switch to RWD); without the kit it stays ineligible.
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var rally := {"id": "t_rwd", "name": "T", "restriction": {"drive_mode": CarLibrary.RWD}}
	var entry := {"id": "t_fwd", "name": "FWD car", "drive_mode": CarLibrary.FWD, "engine": "", "mass": 1200.0, "max_hp": 1000.0}
	var with_kit := {"instance_id": 1, "model_id": "t_fwd", "hp": 1000.0,
		"installed_upgrades": ["drivetrain_swap"], "disabled_upgrades": [], "drivetrain_override": -1}
	var no_kit := {"instance_id": 2, "model_id": "t_fwd", "hp": 1000.0,
		"installed_upgrades": [], "disabled_upgrades": [], "drivetrain_override": -1}
	assert_eq(hq._qualifying_drivetrain_for(rally, with_kit, entry,
			UpgradeLibrary.effective_meta(with_kit, entry)), CarLibrary.RWD,
		"kitted car can switch to the required RWD")
	assert_eq(hq._qualifying_drivetrain_for(rally, no_kit, entry,
			UpgradeLibrary.effective_meta(no_kit, entry)), -1,
		"un-kitted car cannot switch, so no qualifying mode")


func test_swap_and_detune_stack_for_a_rally_restricting_both() -> void:
	# A rally that restricts BOTH drive_mode AND pw_max should be reachable by a car
	# that needs to STACK a drivetrain switch with an engine detune — neither move
	# alone qualifies it, but the two together do.
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var entry := {"id": "t_fwd_stack", "name": "FWD stack car", "drive_mode": CarLibrary.FWD,
		"engine": "", "peak_torque": 300.0, "redline": 6000.0, "mass": 1200.0}
	var full_pw := CarLibrary.power_to_weight(entry) * CarLibrary.KW_KG_TO_HP_TONNE
	# The cap sits well under the car's full-tune p/w (full pw ~= 1.5x the cap), so a
	# partial detune is needed on top of the switch — comfortably inside (0, 1).
	var pw_max := full_pw / 1.5
	var rally := {"id": "t_rwd_pw", "name": "T2",
		"restriction": {"drive_mode": CarLibrary.RWD, "pw_max": pw_max}}
	var with_kit := {"instance_id": 3, "model_id": "t_fwd_stack",
		"installed_upgrades": ["drivetrain_swap"], "disabled_upgrades": [], "drivetrain_override": -1}
	var no_kit := {"instance_id": 4, "model_id": "t_fwd_stack",
		"installed_upgrades": [], "disabled_upgrades": [], "drivetrain_override": -1}
	assert_eq(hq._qualifying_drivetrain_for(rally, with_kit, entry,
			UpgradeLibrary.effective_meta(with_kit, entry)), CarLibrary.RWD,
		"switch+detune stack qualifies the kitted car for the dual-restricted rally")
	assert_eq(hq._qualifying_drivetrain_for(rally, no_kit, entry,
			UpgradeLibrary.effective_meta(no_kit, entry)), -1,
		"un-kitted car cannot switch, so no qualifying mode even with a detune available")


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
	# The bay opens on the HUB (Change Car + Tuning/Upgrades buttons beside the
	# car); each menu button opens that menu as its own page, and Back returns to the hub.
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_lift()
	await get_tree().process_frame
	assert_eq(hq._lift_page, hq.LiftPage.HUB, "entering the bay lands on the hub page")
	assert_true(hq._lift_hub_controls.visible, "the hub shows the change-car + menu buttons")
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


func test_hq_lift_gates_locked_sliders_by_upgrade() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_lift()
	await get_tree().process_frame
	# The starter has no kits: grip is tunable, brake bias + aero are locked.
	assert_true(hq._tune_panel._sliders["grip_balance"].editable, "grip is always tunable")
	assert_false(hq._tune_panel._sliders["brake_bias"].editable, "brake bias locked without the brake kit")
	assert_false(hq._tune_panel._sliders["aero_balance"].editable, "aero locked without the aero kit")
	# Fit a brake kit to a fresh car and select it — its brake-bias slider unlocks.
	var owned: Dictionary = _save.grant_car("fx_awd")
	var id := int(owned["instance_id"])
	_save.add_item("brake_kit")
	_save.install_upgrade(id, "brake_kit")
	_save.set_selected_car(id)
	hq._enter_lift()
	await get_tree().process_frame
	assert_true(hq._tune_panel._sliders["brake_bias"].editable, "the brake kit unlocks brake-bias tuning")
	assert_false(hq._tune_panel._sliders["aero_balance"].editable, "aero still locked (no aero kit)")


func test_hq_lift_change_car_opens_the_car_park_and_updates_the_selection() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var other: Dictionary = _save.grant_car("fx_awd")  # now two owned cars
	hq._enter_lift()
	await get_tree().process_frame
	var before: int = _save.selected_instance_id()
	# "Change Car" drops into the car park (change-car mode) showing every OTHER owned
	# car — the one already on the lift is excluded (reselecting it would be a no-op).
	hq._enter_change_car()
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.CARPARK, "Change Car opens the car park")
	assert_eq(hq._carpark_mode, hq.CarparkMode.CHANGE, "the car park is in change-car mode")
	assert_eq(hq._eligible.size(), _save.profile["cars"].size() - 1,
		"every owned car EXCEPT the one on the lift is parked to pick from")
	for owned in hq._eligible:
		assert_ne(int(owned.get("instance_id", -1)), before,
			"the current lift car is not among the options")
	# The framed car is one of the OTHER cars; Select it.
	assert_ne(hq._selected_instance_id, before, "it opens framed on a different car")
	hq._on_start_pressed()
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.LIFT, "selecting a car returns to the tuning bay")
	assert_ne(hq._carpark_mode, hq.CarparkMode.CHANGE, "change-car mode is cleared on the way back")
	assert_ne(_save.selected_instance_id(), before, "picking a car changes the selected car")
	assert_eq(_save.selected_instance_id(), int(other["instance_id"]), "the picked car is now selected")
	assert_eq(hq._lift_car_instance_id, _save.selected_instance_id(),
		"the raised car follows the new selection")


func test_hq_lift_change_car_back_returns_to_the_bay_without_changing_selection() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	_save.grant_car("fx_awd")
	hq._enter_lift()
	await get_tree().process_frame
	var before: int = _save.selected_instance_id()
	hq._enter_change_car()
	await get_tree().process_frame
	hq._car_back()
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.LIFT, "Back from change-car returns to the tuning bay")
	assert_ne(hq._carpark_mode, hq.CarparkMode.CHANGE, "change-car mode is cleared")
	assert_eq(_save.selected_instance_id(), before, "backing out leaves the selection unchanged")


func test_hq_lift_change_car_disabled_with_only_one_car() -> void:
	# The before_each starter is the sole owned car — Change Car has nothing else to
	# offer (the current car is excluded), so its hub button is disabled and the hub
	# cursor skips it (seating on Tuning instead of Change Car).
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	assert_eq(_save.profile["cars"].size(), 1, "only the starter is owned for this case")
	hq._enter_lift()
	await get_tree().process_frame
	assert_true(hq._lift_change_car_button.disabled, "Change Car is disabled with one car")
	assert_ne(hq._hub_focus, 1, "the hub cursor doesn't seat on the disabled Change Car")
	# Firing the hub while sitting on the (disabled) Change Car slot does nothing.
	hq._hub_focus = 1
	hq._activate_hub_focus()
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.LIFT, "activating disabled Change Car stays in the bay")


func test_hq_lift_change_car_enabled_with_a_second_car() -> void:
	# Grant a second car and the Change Car button is live again — there's another car
	# to switch to, so the button enables and the cursor seats on it on entry.
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	_save.grant_car("fx_fwd_hatch")
	hq._enter_lift()
	await get_tree().process_frame
	assert_false(hq._lift_change_car_button.disabled, "Change Car is enabled with a second car")
	assert_eq(hq._hub_focus, 1, "the hub cursor seats on the enabled Change Car")


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
	_save.profile["inventory"]["turbo_small"] = 1  # deliberately stale pool entry
	hq._enter_lift()
	await get_tree().process_frame
	hq._open_lift_page(hq.LiftPage.UPGRADES)
	await get_tree().process_frame
	for b in hq._lift_upgrades_box.find_children("*", "Button", true, false):
		assert_false(String(b.text).begins_with("APPLY"),
			"no apply-from-pool button appears in the garage upgrades menu")
	assert_false(_save.get_car(id)["installed_upgrades"].has("turbo_small"),
		"nothing gets fitted from the pool")


# A single-part slot (brakes) is a None / <Kit> option selector, earn-gated like turbo:
# None is always available, the kit is greyed until fitted, and picking it enables the part
# (picking None parks it). Free, instant, reversible — no confirmation dialog.
func test_hq_lift_single_part_slot_is_an_option_selector() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var owned: Dictionary = _save.grant_car("fx_awd")
	var id := int(owned["instance_id"])
	_save.set_selected_car(id)
	hq._enter_lift()
	await get_tree().process_frame
	hq._open_lift_page(hq.LiftPage.UPGRADES)
	await get_tree().process_frame
	# Before the kit is won: a greyed kit option sits beside an available None; no toggles.
	var kit_name := String(UpgradeLibrary.by_id("brake_kit").get("name", "")).to_upper()
	assert_eq(_count_buttons_with_text(hq._lift_upgrades_box, ["Enable", "Disable"]), 0,
		"no Enable/Disable toggle — the slot is a selector")
	var kit_btn := _turbo_button(hq._lift_upgrades_box, kit_name)  # matches by (upper-cased) label
	assert_not_null(kit_btn, "the slot shows its kit as an option")
	assert_true(kit_btn.disabled, "the kit option is greyed until it's won")
	assert_eq(kit_btn.focus_mode, Control.FOCUS_ALL, "the option is keyboard / gamepad focusable")
	# Win + fit the kit (disabled), reopen: the kit option ungreys.
	_save.add_item("brake_kit")
	_save.install_upgrade(id, "brake_kit", false)
	hq._lift_upgrades_box.rebuild()
	await get_tree().process_frame
	assert_false(_turbo_button(hq._lift_upgrades_box, kit_name).disabled,
		"the kit option ungreys once fitted")
	# Picking the kit enables the part; picking None parks it (still fitted, effect off).
	_press_slot_button_with_text(hq._lift_upgrades_box, "brakes", kit_name)
	await get_tree().process_frame
	assert_true(UpgradeLibrary.is_enabled(_save.get_car(id), "brake_kit"), "picking the kit enables it")
	_press_slot_button_with_text(hq._lift_upgrades_box, "brakes", "STOCK")
	await get_tree().process_frame
	var car: Dictionary = _save.get_car(id)
	assert_true(car["installed_upgrades"].has("brake_kit"), "a parked part stays fitted to the car")
	assert_false(UpgradeLibrary.is_enabled(car, "brake_kit"), "picking None switches the part off")


func test_hq_back_steps_carpark_to_table_to_garage() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	hq._enter_table()
	hq._on_rally_pin("shakedown")
	hq._enter_car_screen()
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.CARPARK, "in the car park after entering")
	# Back from the car park returns to the map table, clearing the lineup.
	hq._car_back()
	assert_eq(hq._view, hq.View.TABLE, "Back from the car park returns to the map table")
	assert_eq(hq._cars.size(), 0, "the parked lineup is cleared when leaving the car park")
	assert_true(hq._table_layer.visible, "the map HUD is shown again")
	# Back from the table returns to the garage.
	hq._go_to(hq.View.GARAGE)
	assert_eq(hq._view, hq.View.GARAGE, "Back from the table returns to the garage")


func test_hq_choose_rally_then_car_then_start_launches_a_session() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	# Pick a rally → enter, then Start with the focused car. auto_load_scenes is off,
	# so no scene change; start_rally derives targets.
	hq._on_rally_pin("shakedown")
	hq._enter_car_screen()
	await get_tree().process_frame
	assert_false(hq._start_button.disabled, "Start is enabled once a rally + eligible car are chosen")
	# Start shows the loading overlay first, then hands off after a frame (so the
	# overlay paints before the heavy target derivation) — await the whole thing.
	await hq._on_start_pressed()
	assert_gt(hq.find_children("*", "LoadingScreen", true, false).size(), 0,
		"a loading overlay is shown immediately on Start")
	assert_true(RallySession.is_active(), "Start hands off to an active RallySession")
	assert_eq(RallySession.rally_id(), "shakedown", "the chosen rally is running")


func test_hq_starting_a_rally_selects_the_fielded_car() -> void:
	# Fielding a car for a rally also makes it the selected car (the one on the
	# tuning lift), so the garage shows the car the player last raced.
	_save.grant_car("fx_awd")
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_rally_pin("the_showdown")  # open-class: both cars eligible
	hq._enter_car_screen()
	await get_tree().process_frame
	await _await_lineup(hq)
	# Focus a car that is NOT the currently selected one, then start.
	var before: int = _save.selected_instance_id()
	var other := -1
	for i in hq._eligible.size():
		if int(hq._eligible[i]["instance_id"]) != before:
			hq._focus = i
			hq._focus_changed(true)
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
	hq._on_rally_pin("shakedown")
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
	hq._on_rally_pin("shakedown")
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
	RallySession.start_rally(RallyLibrary.by_id("coastal_sprint"), owned, true)
	RallySession._opponent_field = [
		{"name": "Quick", "event_times_ms": [40000, 40000, 40000], "dnf": false, "combined_ms": 120000},
		{"name": "Slow", "event_times_ms": [80000, 80000, 80000], "dnf": false, "combined_ms": 240000},
	]
	RallySession.report_event_result(50000)  # complete event 1 -> STANDINGS
	var sc: Control = load("res://standings.tscn").instantiate()
	add_child_autofree(sc)
	await get_tree().process_frame
	var text := _label_texts(sc)
	assert_string_contains(text, "AFTER EVENT 1", "the interstitial headers the event just finished")
	assert_string_contains(text, "COASTAL SPRINT", "it names the rally")
	assert_string_contains(text, "QUICK", "the opponent field is listed")
	assert_string_contains(text, "SLOW", "the whole field is shown")
	# Continue is focused on entry so a keyboard / gamepad can advance with no pointer.
	var cont := sc.find_children("*", "Button", true, false)[0] as Button
	assert_eq(cont.focus_mode, Control.FOCUS_ALL, "the Continue button is focusable")
	assert_eq(sc.get_viewport().gui_get_focus_owner(), cont,
		"Continue is focused for keyboard / gamepad")


func test_standings_non_final_event_collects_an_upgrade_reward() -> void:
	# After a non-final event the combined page offers "Collect reward"; pressing it
	# hides the leaderboard and reveals the won upgrade with a single "Next" (granted to
	# the garage, installed later), then the button continues to the next event.
	var driven: Dictionary = _save.grant_car("fx_awd")
	RallySession.start_rally(RallyLibrary.by_id("shakedown"), driven, true)
	RallySession._opponent_field = [
		{"name": "Rival", "event_times_ms": [40000, 40000, 40000], "dnf": false, "combined_ms": 120000},
	]
	RallySession.report_event_result(50000)  # event 1 -> one upgrade drawn, STANDINGS
	var won := RallySession.current_event_upgrade()
	assert_ne(won, "", "event 1 awarded an upgrade to collect")

	var sc: Control = load("res://standings.tscn").instantiate()
	add_child_autofree(sc)
	await get_tree().process_frame
	# Event 1 skips the event-only page, so we're on the combined page already.
	assert_false(sc.showing_event_page(), "event 1 opens on the combined page")
	assert_eq(sc._action_button.text, UITheme.caps("Collect reward >"),
		"a non-final event with an award offers Collect reward")

	sc._action_button.pressed.emit()
	await get_tree().process_frame
	assert_true(is_instance_valid(sc._reveal), "collecting shows the reward reveal")
	# A normal slottable part is now granted fitted-disabled with a single "Next" — no
	# Apply/Keep choice (the player enables it later in the upgrades menu). Repair kit /
	# drivetrain also auto-finish.
	if not UpgradeLibrary.is_consumable(won) and UpgradeLibrary.slot_of(won) != "" \
			and UpgradeLibrary.slot_of(won) != "drivetrain":
		assert_false(sc._reveal._choice_pending, "a slottable reward no longer opens Apply/Keep")
	await get_tree().process_frame
	assert_eq(sc._action_button.text, UITheme.caps("Continue to next event >"),
		"after collecting, the button continues to the next event")

	sc._action_button.pressed.emit()
	assert_eq(RallySession.phase(), RallySession.Phase.RUNNING, "continue resumes the next event")
	RallySession.abandon()


func test_standings_final_event_has_no_collect_reward() -> void:
	var driven: Dictionary = _save.grant_car("fx_awd")
	RallySession.start_rally(RallyLibrary.by_id("shakedown"), driven, true)
	RallySession._opponent_field = [
		{"name": "Rival", "event_times_ms": [40000, 40000, 40000], "dnf": false, "combined_ms": 120000},
	]
	for i in RallySession.EVENTS_PER_RALLY:
		RallySession.report_event_result(50000)
		if i < RallySession.EVENTS_PER_RALLY - 1:
			RallySession.continue_to_next_event()
	# Now paused on the FINAL event's standings.
	var sc: Control = load("res://standings.tscn").instantiate()
	add_child_autofree(sc)
	await get_tree().process_frame
	while sc.showing_event_page():
		sc._action_button.pressed.emit()
		await get_tree().process_frame
	assert_eq(sc._action_button.text, UITheme.caps("Continue to podium >"),
		"the final event has no reward to collect")
	RallySession.abandon()


func test_podium_shows_the_finish_summary() -> void:
	# The podium opens on its first stage (the 3D podium) showing the headline result.
	RallySession._last_result = {"placed": 2, "completed": true, "combined_ms": 65000, "dnf": false}
	var pod: Node3D = load("res://podium.tscn").instantiate()
	add_child_autofree(pod)
	await get_tree().process_frame
	assert_eq(pod._stage, pod.Stage.PODIUM, "the podium opens on the PODIUM stage")
	var text := _label_texts(pod)
	assert_string_contains(text, "P2", "podium shows the placement")
	assert_string_contains(text, "WON", "a top-3 finish reads as a win")
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
		"rally_name": "Coastal Sprint", "showdown_won": false,
		"car_reward": "fx_rwd_coupe", "car_reward_is_new": true,
		"upgrades": ["turbo_small", "brake_kit"],  # recorded, but NOT revealed here
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
	assert_eq(pod._stages, [pod.Stage.PODIUM, pod.Stage.LEADERBOARD, pod.Stage.CAR_REVEAL] as Array[int],
		"the podium reveals podium, leaderboard, then the car — no upgrade stages")

	# Next -> the leaderboard.
	pod._on_next()
	await get_tree().process_frame
	assert_eq(pod._stage, pod.Stage.LEADERBOARD, "Next from the podium shows the leaderboard")
	var lb := _label_texts(pod)
	assert_string_contains(lb, "RIVAL 1", "the leaderboard lists the opponent field")
	assert_string_contains(lb, "WRECKED", "a DNF opponent reads as WRECKED on the leaderboard")

	# Next -> the car slot-machine reveal (resolves instantly headless).
	pod._on_next()
	await get_tree().process_frame
	assert_eq(pod._stage, pod.Stage.CAR_REVEAL, "Next from the leaderboard shows the car reveal")
	assert_true(pod._reveal_done, "the slot spin resolves instantly under headless")
	assert_true(pod._next_button.visible, "Next reappears once the spin locks on")
	# The showroom car is spawned by the slot's on_done (only once the reel locks on).
	assert_true(is_instance_valid(pod._showroom_car), "the won car is spawned once the reveal lands")
	assert_true(pod._showroom_car.visible, "the revealed car is shown after the spin")
	var car := _label_texts(pod)
	# Derive the reward car's name from the catalogue (labels are upper-cased for
	# display) rather than pinning an authored name that a rename would break.
	var reward_name: String = String(CarLibrary.by_id("fx_rwd_coupe")["name"]).to_upper()
	assert_string_contains(car, reward_name, "the won car is revealed by name")
	assert_string_contains(car, "NEW", "an un-owned car reward is flagged NEW")
	# The car reveal is a single caption line — the big slot label is hidden so the
	# car name isn't shown twice.
	assert_false(pod._slot_label.visible, "the big slot label is hidden on the one-line car reveal")
	assert_eq(pod._next_button.text, "CONTINUE TO HQ", "the final stage's button returns to HQ")


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
	assert_eq(pod._stages, [pod.Stage.PODIUM, pod.Stage.LEADERBOARD] as Array[int],
		"a DNF result queues only the podium + leaderboard (no reward reveals)")
	assert_string_contains(_label_texts(pod), "DNF", "the headline reads as a DNF")


func test_run_scene_fields_the_bound_session_car() -> void:
	var owned: Dictionary = _save.grant_car("fx_awd")
	var id := int(owned["instance_id"])
	RallySession.start_rally(RallyLibrary.by_id("coastal_sprint"), owned, true)
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
	assert_eq(hq._eligible.size(), 3, "three starter cars parked (mx5 + focus + twingo)")
	# Pick the focus.
	for i in hq._eligible.size():
		if String(hq._eligible[i].get("model_id", "")) == "focus":
			hq._focus = i
			hq._focus_changed(true)
			break
	hq._on_start_pressed()
	assert_true(bool(_save.profile["starter_picked"]), "starter recorded")
	assert_eq(String(_save.profile["starter_model_id"]), "focus")
	var cars: Array = _save.profile["cars"]
	assert_eq(cars.size(), 1, "exactly one car granted")
	assert_eq(String(cars[0]["model_id"]), "focus")
	assert_false(_save.car_is_wrecked(cars[0]), "the chosen starter is a healthy, ordinary car")
	assert_eq(_save.selected_instance_id(), int(cars[0]["instance_id"]), "the starter is selected")
	assert_eq(hq._view, hq.View.GARAGE, "lands in the garage after picking")


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
	_save.add_item(UpgradeLibrary.ENGINE_SWAP_TOKEN_ID, 1)
	hq._enter_engine_swap()
	await _await_lineup(hq)
	assert_true(hq._eligible.size() >= 1, "swap lineup lists the other owned car(s)")
	hq._selected_instance_id = int(b["instance_id"])
	hq._on_start_pressed()  # pops the confirm; OK commits
	hq._on_swap_confirmed()
	assert_eq(String(_save.get_car(int(a["instance_id"])).get("swapped_engine", "")), stock_b,
		"selected car received the target's engine")
	assert_eq(_save.engine_swap_tokens_owned(), 0, "the swap spent the token")


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
	_save.add_item(UpgradeLibrary.ENGINE_SWAP_TOKEN_ID, 1)
	hq._enter_engine_swap()
	await _await_lineup(hq)
	# The damaged lift car still has a target (no car excluded on health).
	hq._selected_instance_id = int(b["instance_id"])
	hq._focus_changed()
	assert_false(hq._start_button.disabled, "the partner is never excluded on health")
	assert_false(hq._car_warning_label.visible, "no repair-cost warning in swap mode anymore")
	# Confirm the swap: OK exchanges engines and spends the token.
	hq._select_swap_target()
	hq._on_swap_confirmed()
	assert_eq(String(_save.get_car(a_id).get("swapped_engine", "")), stock_b,
		"the damaged car received the partner's engine")
	assert_almost_eq(float(_save.get_car(a_id)["hp"]), hp_before, 0.001,
		"the swap left the damaged car's HP unchanged")
	assert_eq(_save.engine_swap_tokens_owned(), 0, "the swap spent the token")


# Without a token, a swap is blocked: the button is reachable but the popup's OK is
# disabled — the player is told, not excluded — and no swap happens.
func test_engine_swap_blocked_without_a_token() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var a: Dictionary = _save.selected_car()
	var a_id := int(a["instance_id"])
	var b: Dictionary = _save.grant_car("fx_rwd_coupe")
	assert_eq(_save.engine_swap_tokens_owned(), 0, "no tokens owned")
	hq._enter_engine_swap()
	await _await_lineup(hq)
	hq._selected_instance_id = int(b["instance_id"])
	hq._focus_changed()
	hq._select_swap_target()
	hq._on_swap_confirmed()
	assert_eq(String(_save.get_car(a_id).get("swapped_engine", "")), "",
		"no swap happened without a token")


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
	hq._focus_changed(true)
	assert_true(hq._swap_preview_label.visible, "preview shows in swap mode")
	assert_string_contains(hq._swap_preview_label.text, "hp/tonne", "preview names the unit")
	# Leaving swap mode for the normal car-select hides it.
	hq._carpark_mode = hq.CarparkMode.RALLY
	hq._focus_changed(true)
	assert_false(hq._swap_preview_label.visible, "preview hidden outside swap mode")


func test_display_name_reflects_swap() -> void:
	# EngineSwap.display_name looks the swapped engine's layout up in EngineLibrary by id,
	# so it needs a real engine id to resolve — restore the real catalogue for this one test.
	CarFixtures.restore()
	assert_eq(EngineSwap.display_name({"name": "Twingo", "engine": "renault_12_i4"},
		{"swapped_engine": "ford_50_v8"}), "V8 Twingo", "swapped owned car shows the layout prefix")


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


func test_restriction_text_shows_power_to_weight_in_hp_per_tonne() -> void:
	# The rally requirement string must show its p/w ceiling in hp/tonne, matching every
	# other player-facing p/w readout. The ceiling is authored in hp/tonne, shown straight.
	# Injected value, so no authored rally number is pinned.
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var txt: String = hq._restriction_text({"pw_max": 300.0})
	assert_true(txt.contains("hp/tonne"), "requirement carries the hp/tonne unit")
	assert_true(txt.contains("300"), "authored hp/tonne ceiling is shown straight")


func test_detune_label_shows_power_to_weight() -> void:
	# The detune value label carries the percent AND the live power-to-weight readout
	# (format, not a pinned value). Detune lives on the UPGRADES page (p/w knob).
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_lift()
	hq._open_lift_page(hq.LiftPage.UPGRADES)
	var id: int = _save.selected_instance_id()
	hq._lift_upgrades_box._on_detune_changed(80.0, id)
	var txt := String(hq._lift_upgrades_box._detune_value.text)
	assert_true(txt.begins_with("80%"), "detune label leads with the percent")
	assert_true(txt.to_lower().contains("hp/tonne"), "detune label shows the power-to-weight readout")


func test_detune_slider_is_present_and_focusable() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_lift()
	hq._open_lift_page(hq.LiftPage.UPGRADES)
	var slider: HSlider = hq._lift_upgrades_box._detune_slider
	assert_not_null(slider, "upgrades page has a detune slider")
	assert_eq(slider.focus_mode, Control.FOCUS_ALL, "detune slider is keyboard/gamepad focusable")
	assert_eq(slider.min_value, 0.0, "detune slider starts at 0%")
	assert_eq(slider.max_value, 100.0, "detune slider tops at 100%")


func test_detune_slider_persists_as_fraction() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_lift()
	hq._open_lift_page(hq.LiftPage.UPGRADES)
	var id: int = _save.selected_instance_id()
	hq._lift_upgrades_box._on_detune_changed(50.0, id)
	assert_almost_eq(float(_save.get_car(id)["tuning"]["engine_detune"]), 0.5, 0.001,
		"a 50% slider stores a 0.5 torque fraction")


func _find_swap_button(hq: Node3D) -> Button:
	for row in hq._lift_upgrades_box.get_children():
		if row.is_queued_for_deletion():
			continue  # a rebuild queue_free'd the old rows; ignore them
		for child in row.get_children():
			if child is Button and String(child.text).to_lower().begins_with("swap engine"):
				return child
	return null


func test_swap_button_disabled_without_an_eligible_partner() -> void:
	# before_each grants a single Fixture Roadster starter — no other car to swap with, so the
	# Swap Engine button is disabled. A token owned + a second car both present enables it.
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	_save.add_item(UpgradeLibrary.ENGINE_SWAP_TOKEN_ID, 1)  # isolate partner-presence as the variable
	hq._enter_lift()
	hq._open_lift_page(hq.LiftPage.UPGRADES)
	var btn := _find_swap_button(hq)
	assert_not_null(btn, "the upgrades page has a Swap Engine button")
	assert_true(btn.disabled, "no partner -> swap button disabled")
	_save.grant_car("fx_rwd_coupe")
	hq._enter_lift()
	hq._open_lift_page(hq.LiftPage.UPGRADES)
	await get_tree().process_frame  # let the rebuild's queue_free'd old rows clear
	assert_false(_find_swap_button(hq).disabled, "a second car + a token enables the swap")


func test_swap_button_without_a_token_is_disabled_until_one_is_owned() -> void:
	# With an eligible partner but no token, the swap button is DISABLED and its label
	# spells out the no-token state (a tooltip explains how to earn one) — it does NOT
	# enter swap mode. A token then owned enables the button and lets it swap normally.
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	_save.grant_car("fx_rwd_coupe")  # a partner exists, but no token owned
	hq._enter_lift()
	hq._open_lift_page(hq.LiftPage.UPGRADES)
	var btn := _find_swap_button(hq)
	assert_not_null(btn, "the upgrades page has a Swap Engine button")
	assert_true(btn.disabled, "partner but no token -> button disabled")
	assert_true(String(btn.text).to_lower().contains("no token"), "label spells out the no-token state")
	assert_ne(hq._view, hq.View.CARPARK, "no token -> not in swap mode")
	# A token owned: the button is enabled and enters the real swap flow.
	_save.add_item(UpgradeLibrary.ENGINE_SWAP_TOKEN_ID, 1)
	hq._enter_lift()
	hq._open_lift_page(hq.LiftPage.UPGRADES)
	await get_tree().process_frame
	assert_false(_find_swap_button(hq).disabled, "a token enables the swap")


func test_detune_prompt_change_upgrades_opens_navigable_popup_without_swap() -> void:
	# The detune-to-enter prompt offers "Change Upgrades…" as an alternative to detuning:
	# it opens a popup hosting the UpgradesMenu for the focused car, keyboard/gamepad
	# navigable, with NO engine-swap row (the swap flow would change the HQ view).
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var id := int(_save.selected_car().get("instance_id", -1))
	hq._selected_instance_id = id
	hq._eligible = [_save.get_car(id)]
	hq._focus = 0
	# The popup is only ever opened from the detune prompt over the (visible) car-park
	# layer; mirror that precondition so its controls are visible-in-tree (the layer is
	# hidden outside View.CARPARK, which would make first_control() see nothing).
	hq._car_layer.visible = true
	hq._show_upgrades_popup(_save.get_car(id))
	await get_tree().process_frame
	assert_true(hq._upgrades_popup.visible, "the popup is shown")
	assert_not_null(hq._upgrades_popup_menu, "the popup hosts an UpgradesMenu")
	assert_not_null(hq._upgrades_popup_menu.first_control(), "has a focusable option (navigable)")
	var has_swap := false
	for node in hq._upgrades_popup_menu.find_children("*", "Button", true, false):
		if String((node as Button).text).to_lower().begins_with("swap engine"):
			has_swap = true
	assert_false(has_swap, "the engine-swap row is dropped in the popup")
	hq._close_upgrades_popup()
	assert_false(hq._upgrades_popup.visible, "Done / back closes the popup")


func test_engine_swap_button_is_focusable() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_lift()
	hq._open_lift_page(hq.LiftPage.UPGRADES)
	var found := false
	for row in hq._lift_upgrades_box.get_children():
		for child in row.get_children():
			if child is Button and String(child.text).to_upper() == "SWAP ENGINE":
				assert_eq(child.focus_mode, Control.FOCUS_ALL, "swap button is focusable")
				found = true
	assert_true(found, "the upgrades page has a Swap Engine button")


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
	await get_tree().process_frame  # title MenuNav re-grabs on visibility
	assert_eq(hq.get_viewport().gui_get_focus_owner(), hq._title_start_button,
		"focus returns to the title Start button")


# The final event used to skip straight to the podium from its event-only page. It
# should now show the SAME two-page flow as every other event: event result page,
# then Continue steps to the combined/cumulative standings page before resolving.
func test_final_event_shows_combined_page_before_proceeding() -> void:
	var owned := _first_owned_car()
	RallySession.start_rally(_any_rally(), owned, true)
	RallySession.report_event_result(1000, 0.0)   # event 1
	RallySession.continue_to_next_event()
	RallySession.report_event_result(1000, 0.0)   # event 2
	RallySession.continue_to_next_event()
	RallySession.report_event_result(1000, 0.0)   # event 3 (final)
	var s: Control = load("res://standings.tscn").instantiate()
	add_child_autofree(s)
	assert_true(s.showing_event_page(), "final event opens on the event page")
	s._on_action()                                 # advance from the event page
	assert_false(s.showing_event_page(), "final event now shows the combined page")


# Drivetrain selector on the upgrades page's drivetrain slot row (todo/drivetrain-swap):
# ALWAYS shows three FOCUS_ALL mode buttons (RWD/AWD/FWD). Without the kit only the car's
# stock mode is enabled + selected (the rest greyed, earn-gated); once the kit is owned all
# three are selectable and pressing one stores the override on the car.
func _count_buttons_with_text(box: Node, needles: Array) -> int:
	var count := 0
	for b in box.find_children("*", "Button", true, false):
		for needle in needles:
			if String(b.text).contains(needle):
				count += 1
				break
	return count


func _press_button_with_text(box: Node, needle: String) -> void:
	for b in box.find_children("*", "Button", true, false):
		if String(b.text).contains(needle):
			b.pressed.emit()
			return
	fail_test("no button found containing '%s'" % needle)


# The option-selector rows share button labels — every slot renders a "None" — so a
# whole-box search over-counts and can press the wrong slot's button. Each option
# button carries an "opt:<slot>:..." focus-key meta (hq.gd _make_option_selector), so
# scope by that meta to confine a count / press to a single selector row.
func _slot_buttons(box: Node, slot: String) -> Array:
	var out: Array = []
	var prefix := "opt:%s:" % slot
	for b in box.find_children("*", "Button", true, false):
		if String(b.get_meta("upgrade_focus_key", "")).begins_with(prefix):
			out.append(b)
	return out


func _count_slot_buttons_with_text(box: Node, slot: String, needles: Array) -> int:
	var count := 0
	for b in _slot_buttons(box, slot):
		for needle in needles:
			if String(b.text).contains(needle):
				count += 1
				break
	return count


func _press_slot_button_with_text(box: Node, slot: String, needle: String) -> void:
	for b in _slot_buttons(box, slot):
		if String(b.text).contains(needle):
			b.pressed.emit()
			return
	fail_test("no button in slot '%s' containing '%s'" % [slot, needle])


func _drivetrain_mode_buttons(box: Node) -> Array:
	var out: Array = []
	for b in box.find_children("*", "Button", true, false):
		if String(b.get_meta("upgrade_focus_key", "")).begins_with("drivetrain:"):
			out.append(b)
	return out


func test_drivetrain_selector_always_shown_gated_until_unlocked() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var owned: Dictionary = _save.grant_car("fx_awd")  # stock drive mode is AWD
	var id := int(owned["instance_id"])
	_save.set_selected_car(id)
	hq._enter_lift()
	await get_tree().process_frame
	hq._open_lift_page(hq.LiftPage.UPGRADES)
	await get_tree().process_frame
	# All three modes are shown even without the kit — but only the stock mode (AWD) is
	# enabled + selected; the other two are greyed (earn-gated, like a part option).
	var buttons := _drivetrain_mode_buttons(hq._lift_upgrades_box)
	assert_eq(buttons.size(), 3, "all three modes shown before the kit is owned")
	for b in buttons:
		var is_stock := String(b.text).contains("AWD")
		assert_eq(b.disabled, not is_stock,
			"only the stock mode is selectable without the kit (%s)" % b.text)
		if is_stock:
			assert_true(String(b.text).begins_with("["), "stock mode is selected")
		assert_eq(b.focus_mode, Control.FOCUS_ALL, "each mode button is keyboard / gamepad focusable")
	# Owning the kit (even DISABLED — the won-but-not-podium-applied state) enables all modes.
	_save.add_item("drivetrain_swap")
	_save.install_upgrade(id, "drivetrain_swap", false)
	hq._lift_upgrades_box.rebuild()
	await get_tree().process_frame
	buttons = _drivetrain_mode_buttons(hq._lift_upgrades_box)
	assert_eq(buttons.size(), 3, "all three modes shown once the kit is owned")
	for b in buttons:
		assert_false(b.disabled, "every mode is selectable once the kit is owned (%s)" % b.text)
	# No Enable/Disable toggle for the drivetrain slot — the selector's stock choice is off.
	assert_eq(_count_buttons_with_text(hq._lift_upgrades_box, ["Enable", "Disable"]), 0,
		"drivetrain slot has no enable/disable toggle")


func test_drivetrain_selector_sets_override() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var owned: Dictionary = _save.grant_car("fx_awd")
	var id := int(owned["instance_id"])
	_save.set_selected_car(id)
	_save.add_item("drivetrain_swap")
	_save.install_upgrade(id, "drivetrain_swap")
	hq._enter_lift()
	await get_tree().process_frame
	hq._open_lift_page(hq.LiftPage.UPGRADES)
	await get_tree().process_frame
	_press_button_with_text(hq._lift_upgrades_box, "AWD")
	await get_tree().process_frame
	assert_eq(int(_save.get_car(id).get("drivetrain_override", -1)), CarLibrary.AWD,
		"pressing a mode stores the override")


# Regression: selecting a drivetrain rebuilds the upgrade rows via _set_drivetrain →
# _rebuild_upgrades_box. The row builders author their own font_size (15); the house
# rule is FONT_SIZE (16). The rebuild must re-apply the house rules so the text doesn't
# visibly shrink 16 → 15 the moment you pick a mode (the live rebuild paths don't call
# _normalize_menus, so the enforce must live in _rebuild_upgrades_box itself).
func test_selecting_a_drivetrain_keeps_the_house_font_size() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var owned: Dictionary = _save.grant_car("fx_awd")
	var id := int(owned["instance_id"])
	_save.set_selected_car(id)
	_save.add_item("drivetrain_swap")
	_save.install_upgrade(id, "drivetrain_swap")
	hq._enter_lift()
	await get_tree().process_frame
	hq._open_lift_page(hq.LiftPage.UPGRADES)
	await get_tree().process_frame
	_press_button_with_text(hq._lift_upgrades_box, "AWD")
	await get_tree().process_frame
	for node in hq._lift_upgrades_box.find_children("*", "Control", true, false):
		var c := node as Control
		if c is Label or c is Button:
			assert_eq(c.get_theme_font_size("font_size"), UITheme.FONT_SIZE,
				"'%s' keeps the house font size after a drivetrain rebuild" % c.name)


# The turbo slot is an earn-gated None / Small / Big selector, not enable/disable toggles.
func _turbo_button(box: Node, needle: String) -> Button:
	for b in box.find_children("*", "Button", true, false):
		if String(b.text).contains(needle):
			return b
	return null


func test_turbo_selector_is_earn_gated() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var owned: Dictionary = _save.grant_car("fx_awd")
	var id := int(owned["instance_id"])
	_save.set_selected_car(id)
	hq._enter_lift()
	await get_tree().process_frame
	hq._open_lift_page(hq.LiftPage.UPGRADES)
	await get_tree().process_frame
	# All three options always render; the turbo slot has no Enable/Disable toggles.
	# (Button labels render uppercased by the theme, so match on the upper-cased text.)
	assert_eq(_count_slot_buttons_with_text(hq._lift_upgrades_box, "turbo", ["STOCK", "SMALL", "BIG"]), 3,
		"Stock / Small / Big always shown")
	# With no kit won, Stock is selectable but Small / Big are greyed until earned.
	assert_false(_turbo_button(hq._lift_upgrades_box, "STOCK").disabled, "Stock is always available")
	assert_true(_turbo_button(hq._lift_upgrades_box, "SMALL").disabled, "Small locked until its kit is won")
	assert_true(_turbo_button(hq._lift_upgrades_box, "BIG").disabled, "Big locked until its kit is won")
	# Winning the Small kit unlocks Small only; Big stays greyed.
	_save.add_item("turbo_small")
	_save.install_upgrade(id, "turbo_small", false)
	hq._lift_upgrades_box.rebuild()
	await get_tree().process_frame
	assert_false(_turbo_button(hq._lift_upgrades_box, "SMALL").disabled, "Small unlocks once its kit is fitted")
	assert_true(_turbo_button(hq._lift_upgrades_box, "BIG").disabled, "Big still locked")
	# Each option button is keyboard / gamepad focusable.
	assert_eq(_turbo_button(hq._lift_upgrades_box, "STOCK").focus_mode, Control.FOCUS_ALL,
		"turbo option buttons are focusable")


func test_turbo_selector_sets_enabled_part() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var owned: Dictionary = _save.grant_car("fx_awd")
	var id := int(owned["instance_id"])
	_save.set_selected_car(id)
	_save.add_item("turbo_small")
	_save.install_upgrade(id, "turbo_small", false)
	_save.add_item("turbo_large")
	_save.install_upgrade(id, "turbo_large", false)
	hq._enter_lift()
	await get_tree().process_frame
	hq._open_lift_page(hq.LiftPage.UPGRADES)
	await get_tree().process_frame
	# Picking Big enables the large turbo (exclusivity keeps the small one off).
	# (Button labels render uppercased by the theme.)
	_press_button_with_text(hq._lift_upgrades_box, "BIG")
	await get_tree().process_frame
	assert_true(UpgradeLibrary.is_enabled(_save.get_car(id), "turbo_large"), "Big enables the large turbo")
	assert_false(UpgradeLibrary.is_enabled(_save.get_car(id), "turbo_small"), "and switches the small one off")
	# Picking Stock parks both — no turbo enabled.
	_press_button_with_text(hq._lift_upgrades_box, "STOCK")
	await get_tree().process_frame
	assert_false(UpgradeLibrary.is_enabled(_save.get_car(id), "turbo_large"), "Stock disables the large turbo")
	assert_false(UpgradeLibrary.is_enabled(_save.get_car(id), "turbo_small"), "Stock disables the small turbo")
