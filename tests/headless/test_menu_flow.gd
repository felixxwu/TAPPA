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


# The billboarded readout-box sprite a pin floats above its flag.
func _pin_label_sprite(pin: Node3D) -> Sprite3D:
	return pin.find_children("*", "Sprite3D", true, false)[0]


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
	assert_eq(hq._pins.size(), RallyLibrary.RALLIES.size(), "one map pin per rally")


func test_hq_frames_the_lot_with_tree_meshes() -> void:
	# HQ trees were swapped from billboards to the shared low-poly mesh field,
	# as scenery (no collision).
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var field: TreeMeshField = null
	for c in hq.get_children():
		if c is TreeMeshField:
			field = c
	assert_not_null(field, "HQ frames the lot with a TreeMeshField (3D trees, not billboards)")
	if field != null:
		assert_gt(field.bin_count, 0, "HQ tree field has at least one bin")
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

# The title is a flat two-button menu driven by native focus: Start is focused on
# entry so ui_up/ui_down + ui_accept work the menu with no pointer.
func test_hq_title_focuses_start_for_keyboard_nav() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	await get_tree().process_frame  # let the deferred grab_focus run
	assert_eq(hq._view, hq.View.EXTERIOR, "boots to the title")
	assert_eq(hq._title_start_button.focus_mode, Control.FOCUS_ALL, "Start is focusable")
	assert_eq(hq.get_viewport().gui_get_focus_owner(), hq._title_start_button,
		"the title focuses Start for keyboard / gamepad")


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


# The 3D map table can't take native focus (left/right pans / the pins are spatial),
# so it carries a keyboard cursor: a selected pin that cycles (wrapping), gets the
# hover-style highlight (all pins stay one size), and opens its rally detail on select.
func test_hq_map_table_has_a_keyboard_pin_cursor() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_table()
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.TABLE, "the map table is open")
	var pins: Array = hq._unlocked_pins()
	assert_gt(pins.size(), 1, "there is more than one unlocked rally to cycle between")
	assert_eq(hq._table_pin_index, 0, "the cursor seats on the first pin")
	# Selection is shown by the hover-style highlight on the readout box, not by size:
	# every pin keeps scale 1, and only the selected one gets the green underline.
	assert_almost_eq(float((pins[0] as Node3D).scale.x), 1.0, 0.01, "the selected pin is NOT scaled up")
	assert_almost_eq(float((pins[1] as Node3D).scale.x), 1.0, 0.01, "an unselected pin is the same size")
	var sel_box: StyleBoxFlat = (pins[0] as Node3D).get_meta("label_panel").get_theme_stylebox("panel")
	var idle_box: StyleBoxFlat = (pins[1] as Node3D).get_meta("label_panel").get_theme_stylebox("panel")
	assert_eq(sel_box.border_width_bottom, 3, "the selected pin gets the hover-style underline")
	assert_eq(idle_box.border_width_bottom, 0, "an unselected pin has no underline")

	hq._cycle_table_pin(1)
	assert_eq(hq._table_pin_index, 1, "cycling advances the cursor")
	hq._select_table_pin(0)
	hq._cycle_table_pin(-1)
	assert_eq(hq._table_pin_index, pins.size() - 1, "cycling back from the first wraps to the last")

	hq._select_table_pin(0)
	hq._open_selected_pin()
	assert_true(hq._detail_open, "selecting the focused pin opens its rally detail")
	assert_eq(hq._selected_rally_id, String((pins[0] as Node3D).get_meta("rally_id")),
		"it opens the focused pin's rally")


# The tuning hub is a manual up/down cursor over Change Car / Tuning / Upgrades;
# select fires the focused item, opening a page (native focus) or the car park.
func test_hq_lift_hub_has_an_up_down_cursor() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
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
	assert_true(hq._carpark_change_mode, "in change-car mode")
	hq._car_back()
	await get_tree().process_frame

	# Opening the Tune page seats native focus on one of its sliders.
	hq._open_lift_page(hq.LiftPage.TUNE)
	await get_tree().process_frame
	assert_true(hq.get_viewport().gui_get_focus_owner() is HSlider,
		"opening the Tune page focuses a tuning slider for keyboard/gamepad")


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
	# Add any upgrade: it lands in the inventory.
	dev._add_upgrade("turbo_small", "Small Turbo")
	assert_eq(int(_save.profile["inventory"].get("turbo_small", 0)), 1,
		"adding an upgrade puts it in inventory")
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


# Free Roam opens the car park to pick which owned car to drive: the whole owned
# collection is parked, and Back returns to the garage (not the map).
func test_hq_free_roam_opens_the_car_park_to_pick_a_car() -> void:
	_save.grant_car("fx_fwd_hatch")  # a second car so the collection isn't just the starter
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()

	hq._enter_free_roam()
	await _await_lineup(hq)
	assert_eq(hq._view, hq.View.CARPARK, "Free Roam drops into the car park")
	assert_true(hq._carpark_freeroam_mode, "the car park is in free-roam mode")
	assert_eq(hq._eligible.size(), _save.profile["cars"].size(),
		"the whole owned collection is parked to pick from")

	# Back leaves free roam for the garage.
	hq._car_back()
	assert_false(hq._carpark_freeroam_mode, "backing out clears free-roam mode")
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
	assert_string_contains(hq._detail_body.text, "RWD CARS", "the detail spells out the eligibility")


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
	# Expected = exactly the owned cars RallyLibrary deems eligible. Derived from the
	# eligibility rule + owned roster (not a pinned model name), so it stays correct
	# if cars or the rally's p/w band are retuned — what it really asserts is that HQ
	# parks the library's eligible set, no more, no less.
	var rally := RallyLibrary.by_id("rwd_masters")
	var expected := {}
	for model_id in ["fx_light_rwd", "fx_awd", "fx_rwd_coupe"]:  # the player's owned roster here
		if RallyLibrary.is_eligible(rally, CarLibrary.by_id(model_id)):
			expected[CarLibrary.by_id(model_id)["name"]] = true
	await _await_lineup(hq)
	var parked := {}
	for car in hq._cars:
		parked[car.current_car_name()] = true
	assert_eq(parked, expected, "HQ parks exactly the cars RallyLibrary deems eligible")
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


func test_hq_parked_cars_settle_live_then_freeze() -> void:
	# Parked cars drop in LIVE (so they settle onto their suspension), then freeze at
	# the settled pose so a full car park costs nothing to keep parked.
	_save.grant_car("fx_awd")
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_rally_pin("the_showdown")  # open-class: starter + XJS both eligible
	hq._enter_car_screen()
	await get_tree().process_frame
	await _await_lineup(hq)
	assert_gt(hq._cars.size(), 0, "the lineup is parked")
	for car in hq._cars:
		assert_false(car.freeze, "parked cars start live so they settle on their suspension")
	# The settle timer freezes them; drive that directly (deterministic, no waiting).
	hq._freeze_lineup(hq._settle_generation)
	for car in hq._cars:
		assert_true(car.freeze, "settled cars are frozen at their pose")
	# A stale freeze (old generation) must not touch a freshly-rebuilt lineup.
	hq._enter_car_screen()
	await get_tree().process_frame
	await _await_lineup(hq)
	hq._freeze_lineup(hq._settle_generation - 1)
	for car in hq._cars:
		assert_false(car.freeze, "a superseded freeze leaves the new lineup live")


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
	assert_true(hq._lift_tune_box.visible, "the Tuning page shows the sliders")
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
	assert_false(hq._lift_tune_box.visible, "the Tuning menu is hidden on the Upgrades page")
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
	hq._lift_sliders["grip_balance"].value = 0.6
	var owned: Dictionary = _save.selected_car()
	assert_almost_eq(float(owned["tuning"]["grip_balance"]), 0.6, 0.001,
		"the grip slider saves onto the selected car's tuning")
	# Reset zeroes every axis (free + instant).
	hq._reset_tuning()
	assert_true(_save.selected_car().get("tuning", {}).is_empty(), "Reset clears the tuning deltas")


func test_hq_lift_gates_locked_sliders_by_upgrade() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_lift()
	await get_tree().process_frame
	# The starter has no kits: grip is tunable, brake bias + aero are locked.
	assert_true(hq._lift_sliders["grip_balance"].editable, "grip is always tunable")
	assert_false(hq._lift_sliders["brake_bias"].editable, "brake bias locked without the brake kit")
	assert_false(hq._lift_sliders["aero_balance"].editable, "aero locked without the aero kit")
	# Fit a brake kit to a fresh car and select it — its brake-bias slider unlocks.
	var owned: Dictionary = _save.grant_car("fx_awd")
	var id := int(owned["instance_id"])
	_save.add_item("brake_kit")
	_save.install_upgrade(id, "brake_kit")
	_save.set_selected_car(id)
	hq._enter_lift()
	await get_tree().process_frame
	assert_true(hq._lift_sliders["brake_bias"].editable, "the brake kit unlocks brake-bias tuning")
	assert_false(hq._lift_sliders["aero_balance"].editable, "aero still locked (no aero kit)")


func test_hq_lift_change_car_opens_the_car_park_and_updates_the_selection() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var other: Dictionary = _save.grant_car("fx_awd")  # now two owned cars
	hq._enter_lift()
	await get_tree().process_frame
	var before: int = _save.selected_instance_id()
	# "Change Car" drops into the car park (change-car mode) showing the whole collection.
	hq._enter_change_car()
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.CARPARK, "Change Car opens the car park")
	assert_true(hq._carpark_change_mode, "the car park is in change-car mode")
	assert_eq(hq._eligible.size(), _save.profile["cars"].size(),
		"every owned car is parked to pick from")
	# It frames the car already on the lift; pan to the other car and Select it.
	assert_eq(hq._selected_instance_id, before, "it opens framed on the current lift car")
	hq._cycle_focus(1)  # two cars — pan to the other one
	hq._on_start_pressed()
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.LIFT, "selecting a car returns to the tuning bay")
	assert_false(hq._carpark_change_mode, "change-car mode is cleared on the way back")
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
	assert_false(hq._carpark_change_mode, "change-car mode is cleared")
	assert_eq(_save.selected_instance_id(), before, "backing out leaves the selection unchanged")


func test_hq_lift_installs_an_upgrade_from_inventory() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var owned: Dictionary = _save.grant_car("fx_awd")
	var id := int(owned["instance_id"])
	_save.set_selected_car(id)
	_save.add_item("turbo_small")
	hq._enter_lift()
	await get_tree().process_frame
	hq._open_lift_page(hq.LiftPage.UPGRADES)
	# Installing now asks for confirmation first — nothing is fitted until accepted.
	hq._install_upgrade(id, "turbo_small")
	assert_false(_save.get_car(id)["installed_upgrades"].has("turbo_small"),
		"the part is not fitted until the confirmation dialog is accepted")
	assert_eq(int(_save.profile["inventory"].get("turbo_small", 0)), 1,
		"the part stays in inventory until the fit is confirmed")
	# Accepting the dialog commits the fit and consumes the part for good.
	hq._confirm_dialog.confirmed.emit()
	assert_true(_save.get_car(id)["installed_upgrades"].has("turbo_small"),
		"accepting the confirmation fits the part to the selected car")
	assert_eq(int(_save.profile["inventory"].get("turbo_small", 0)), 0,
		"the installed part is consumed from inventory")


func test_hq_lift_toggles_an_applied_upgrade() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var owned: Dictionary = _save.grant_car("fx_awd")
	var id := int(owned["instance_id"])
	_save.set_selected_car(id)
	_save.add_item("turbo_small")
	_save.install_upgrade(id, "turbo_small")
	hq._enter_lift()
	await get_tree().process_frame
	hq._open_lift_page(hq.LiftPage.UPGRADES)
	await get_tree().process_frame
	# The applied part gets a focusable toggle row in the upgrades menu.
	var toggle: Button = null
	for b in hq._lift_upgrades_box.find_children("*", "Button", true, false):
		if String(b.text).begins_with("DISABLE"):
			toggle = b
			break
	assert_not_null(toggle, "an applied part shows a Disable toggle")
	assert_eq(toggle.focus_mode, Control.FOCUS_ALL, "the toggle is keyboard / gamepad focusable")
	# Disabling parks the part: still fitted, but its effect is off.
	hq._toggle_upgrade(id, "turbo_small", false)
	var car: Dictionary = _save.get_car(id)
	assert_true(car["installed_upgrades"].has("turbo_small"), "a disabled part stays applied to the car")
	assert_false(UpgradeLibrary.is_enabled(car, "turbo_small"), "the toggle switches the part off")
	# Re-enabling brings it back — free and reversible, no confirmation dialog.
	hq._toggle_upgrade(id, "turbo_small", true)
	assert_true(UpgradeLibrary.is_enabled(_save.get_car(id), "turbo_small"),
		"the toggle switches the part back on")


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
	for node_name in ["Trees", "Bushes", "Crowd"]:
		var mmi := pod.get_node_or_null(node_name)
		assert_not_null(mmi, "scenery builds a %s MultiMesh" % node_name)
		assert_true(mmi.multimesh.instance_count > 0, "%s has placed instances" % node_name)


func test_podium_sequence_reveals_leaderboard_then_upgrades_then_car() -> void:
	# A top-3 win that grants the Fixture Coupe plus the two per-rally upgrades. The
	# reward sequence steps PODIUM -> LEADERBOARD -> UPGRADE_REVEAL x2 -> CAR_REVEAL
	# (upgrades first, at the podium, then the fly-over to the showroom), with the
	# slot-machine spins resolving instantly under headless. Each upgrade reveal
	# ends on an Apply/Keep choice targeting the car the player just drove.
	var driven: Dictionary = _save.grant_car("fx_awd")
	var driven_id := int(driven["instance_id"])
	_save.add_item("turbo_small")
	_save.add_item("brake_kit")
	RallySession._last_result = {
		"placed": 1, "completed": true, "combined_ms": 60000, "dnf": false,
		"rally_name": "Coastal Sprint", "showdown_won": false,
		"car_reward": "fx_rwd_coupe", "car_reward_is_new": true,
		"upgrades": ["turbo_small", "brake_kit"],
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
	assert_eq(pod._stages, [pod.Stage.PODIUM, pod.Stage.LEADERBOARD, pod.Stage.UPGRADE_REVEAL,
			pod.Stage.UPGRADE_REVEAL, pod.Stage.CAR_REVEAL] as Array[int],
		"two upgrades + a car queue the podium, leaderboard, one reveal per upgrade, then the car")

	# Next -> the leaderboard.
	pod._on_next()
	await get_tree().process_frame
	assert_eq(pod._stage, pod.Stage.LEADERBOARD, "Next from the podium shows the leaderboard")
	var lb := _label_texts(pod)
	assert_string_contains(lb, "RIVAL 1", "the leaderboard lists the opponent field")
	assert_string_contains(lb, "WRECKED", "a DNF opponent reads as WRECKED on the leaderboard")

	# Next -> the first upgrade slot-machine reveal (resolves instantly headless).
	# Upgrades come FIRST, handed out at the podium; the showroom car doesn't exist
	# yet — it is only spawned by the closing car reveal.
	pod._on_next()
	await get_tree().process_frame
	assert_eq(pod._stage, pod.Stage.UPGRADE_REVEAL, "Next from the leaderboard shows the first upgrade reveal")
	assert_string_contains(_label_texts(pod), "SMALL TURBO", "the first won upgrade is revealed by name")
	assert_string_contains(_label_texts(pod), "UPGRADE 1 OF 2", "the reveal counts up when several were won")
	assert_false(is_instance_valid(pod._showroom_car),
		"no showroom car exists yet — upgrades are revealed at the podium")
	# The content stack drops to the bottom during a reveal so the card clears the 3D view.
	assert_eq(pod._middle.alignment, BoxContainer.ALIGNMENT_END,
		"the menu drops to the bottom during the upgrade reveal")
	# The reveal lands on the Apply/Keep choice for the car the player just drove:
	# Next is held back until the player picks, and Apply is focused for keyboard/pad.
	assert_true(pod._choice_pending, "the upgrade reveal opens the apply/keep choice")
	assert_true(pod._choice_box.visible, "the choice buttons are shown")
	assert_false(pod._next_button.visible, "Next is hidden until the choice is made")
	assert_eq(pod._apply_button.focus_mode, Control.FOCUS_ALL, "Apply is focusable")
	assert_eq(pod._keep_button.focus_mode, Control.FOCUS_ALL, "Keep is focusable")
	await get_tree().process_frame
	assert_eq(pod.get_viewport().gui_get_focus_owner(), pod._apply_button,
		"Apply is focused for keyboard / gamepad")
	# Applying fits the part straight onto the driven car.
	pod._apply_button.pressed.emit()
	assert_true(_save.get_car(driven_id)["installed_upgrades"].has("turbo_small"),
		"Apply fits the won part to the car the player drove")
	assert_eq(int(_save.profile["inventory"].get("turbo_small", 0)), 0,
		"the applied part is consumed from the unlocked pool")
	assert_false(pod._choice_pending, "the choice resolves once picked")
	assert_true(pod._next_button.visible, "Next returns after the choice")
	assert_ne(pod._next_button.text, "CONTINUE TO HQ", "more stages remain, so this isn't the last one")

	# Next -> the second upgrade reveal. Keeping the part leaves it unlocked for
	# the garage upgrades menu instead of fitting it.
	pod._on_next()
	await get_tree().process_frame
	assert_eq(pod._stage, pod.Stage.UPGRADE_REVEAL, "Next shows the second upgrade reveal")
	assert_string_contains(_label_texts(pod), "BIG BRAKE KIT", "the second won upgrade is revealed by name")
	pod._keep_button.pressed.emit()
	assert_false(_save.get_car(driven_id)["installed_upgrades"].has("brake_kit"),
		"Keep does not fit the part to the car")
	assert_eq(int(_save.profile["inventory"].get("brake_kit", 0)), 1,
		"a kept part stays in the unlocked pool for the garage menu")

	# Next -> the car slot-machine reveal (the closing stage: the fly-over to the
	# showroom happens only after the upgrades are handed out).
	pod._on_next()
	await get_tree().process_frame
	assert_eq(pod._stage, pod.Stage.CAR_REVEAL, "Next from the last upgrade shows the car reveal")
	assert_true(pod._reveal_done, "the slot spin resolves instantly under headless")
	assert_true(pod._next_button.visible, "Next reappears once the spin locks on")
	# The showroom car is spawned by the slot's on_done (only once the reel locks
	# on), so after the reveal resolves it exists and is shown — not before.
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
	assert_true(hq._carpark_starter_mode, "in starter-pick mode")
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
	assert_false(hq._carpark_starter_mode, "not in starter-pick mode")
	assert_eq(hq._view, hq.View.GARAGE, "existing player skips the picker")


func test_starter_pick_back_returns_to_title() -> void:
	_reset_to_first_run()
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	await _await_lineup(hq)
	hq._car_back()
	assert_false(hq._carpark_starter_mode, "starter mode cleared on back")
	assert_eq(hq._view, hq.View.EXTERIOR, "back from the picker returns to the title")
	assert_eq(_save.profile["cars"].size(), 0, "backing out grants nothing")


func test_engine_swap_flow_exchanges_engines() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var a: Dictionary = _save.selected_car()
	var b: Dictionary = _save.grant_car("fx_rwd_coupe")
	var stock_b: String = CarLibrary.by_id("fx_rwd_coupe")["engine"]
	hq._enter_engine_swap()
	await _await_lineup(hq)
	assert_true(hq._eligible.size() >= 1, "swap lineup lists the other owned car(s)")
	hq._selected_instance_id = int(b["instance_id"])
	hq._on_start_pressed()
	assert_eq(String(_save.get_car(int(a["instance_id"])).get("swapped_engine", "")), stock_b,
		"selected car received the target's engine")


func test_display_name_reflects_swap() -> void:
	# EngineSwap.display_name looks the swapped engine's layout up in EngineLibrary by id,
	# so it needs a real engine id to resolve — restore the real catalogue for this one test.
	CarFixtures.restore()
	assert_eq(EngineSwap.display_name({"name": "Twingo", "engine": "renault_12_i4"},
		{"swapped_engine": "ford_50_v8"}), "V8 Twingo", "swapped owned car shows the layout prefix")


func test_tuning_sliders_are_all_the_same_length() -> void:
	# Every axis row's slider must line up to the same width, even though the detune
	# row's value label ("80% - 0.20 HP/kg") is longer than the others.
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_lift()
	hq._open_lift_page(hq.LiftPage.TUNE)
	await get_tree().process_frame
	await get_tree().process_frame
	var widths: Array = []
	for axis in TuningLibrary.AXES:
		widths.append((hq._lift_sliders[axis] as HSlider).size.x)
	for w in widths:
		assert_almost_eq(float(w), float(widths[0]), 0.5, "all tuning sliders share the same length")


func test_restriction_text_shows_power_to_weight_in_hp_per_kg() -> void:
	# The rally requirement string must show its p/w band in HP/kg, matching every other
	# player-facing p/w readout. The band is authored in HP/kg, so it is shown straight.
	# Injected band values, so no authored rally number is pinned.
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var txt: String = hq._restriction_text({"pw_min": 0.22, "pw_max": 0.30})
	assert_true(txt.contains("HP/kg"), "requirement carries the HP/kg unit")
	assert_true(txt.contains("0.22"), "authored HP/kg floor is shown straight")
	assert_true(txt.contains("0.30"), "authored HP/kg ceiling is shown straight")


func test_detune_label_shows_power_to_weight() -> void:
	# The detune value label carries the percent AND the live power-to-weight readout
	# (format, not a pinned value).
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_lift()
	hq._open_lift_page(hq.LiftPage.TUNE)
	hq._on_tune_slider_changed(80.0, "engine_detune")
	var txt := String(hq._lift_slider_values["engine_detune"].text)
	assert_true(txt.begins_with("80%"), "detune label leads with the percent")
	assert_true(txt.to_lower().contains("hp/kg"), "detune label shows the power-to-weight readout")


func test_detune_slider_is_present_and_focusable() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_lift()
	hq._open_lift_page(hq.LiftPage.TUNE)
	assert_true(hq._lift_sliders.has("engine_detune"), "tuning page has a detune slider")
	var slider: HSlider = hq._lift_sliders["engine_detune"]
	assert_eq(slider.focus_mode, Control.FOCUS_ALL, "detune slider is keyboard/gamepad focusable")
	assert_eq(slider.min_value, 0.0, "detune slider starts at 0%")
	assert_eq(slider.max_value, 100.0, "detune slider tops at 100%")


func test_detune_slider_persists_as_fraction() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_lift()
	hq._open_lift_page(hq.LiftPage.TUNE)
	hq._on_tune_slider_changed(50.0, "engine_detune")
	var id: int = _save.selected_instance_id()
	assert_almost_eq(float(_save.get_car(id)["tuning"]["engine_detune"]), 0.5, 0.001,
		"a 50% slider stores a 0.5 torque fraction")


func _find_swap_button(hq: Node3D) -> Button:
	for row in hq._lift_upgrades_box.get_children():
		if row.is_queued_for_deletion():
			continue  # a rebuild queue_free'd the old rows; ignore them
		for child in row.get_children():
			if child is Button and String(child.text).to_lower() == "swap engine":
				return child
	return null


func test_swap_button_disabled_without_an_eligible_partner() -> void:
	# before_each grants a single Fixture Roadster starter — no other car to swap with, so the
	# Swap Engine button is disabled. Granting a second full-health car enables it.
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_lift()
	hq._open_lift_page(hq.LiftPage.UPGRADES)
	var btn := _find_swap_button(hq)
	assert_not_null(btn, "the upgrades page has a Swap Engine button")
	assert_true(btn.disabled, "no partner -> swap button disabled")
	_save.grant_car("fx_rwd_coupe")
	hq._enter_lift()
	hq._open_lift_page(hq.LiftPage.UPGRADES)
	await get_tree().process_frame  # let the rebuild's queue_free'd old rows clear
	assert_false(_find_swap_button(hq).disabled, "a second 100%-HP car enables the swap")


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
