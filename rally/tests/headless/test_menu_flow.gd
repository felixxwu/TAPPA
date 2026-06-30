extends GutTest
# Menus vertical slice (todo/menus.md, todo/diegetic-hq.md): the diegetic 3D HQ
# (camera stations: exterior title → garage → map table → car park) → run → podium
# loop, and the run-scene fielding that wires it to RallySession
# (features/rally-session.md). Runs against a throwaway Save profile.

const SceneHelpers = preload("res://tests/headless/scene_helpers.gd")
const TEST_PATH := "user://test_menu_flow_profile.json"

var _save: Node


func before_each() -> void:
	Config.reset()
	_save = get_node("/root/Save")
	_clean()
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.load_or_new()
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


func _clean() -> void:
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


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


func test_hq_boots_to_the_exterior_title() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	assert_eq(_save.profile["cars"].size(), 1, "the immortal starter is granted on the first HQ visit")
	assert_true(_save.profile["cars"][0]["immortal"], "the starter is immortal")
	# Boots to the exterior/title station: the title overlay is up, and the player's
	# whole collection is parked in the car park (just the starter so far).
	assert_eq(hq._view, hq.View.EXTERIOR, "HQ boots to the exterior title station")
	assert_true(hq._title_layer.visible, "the title overlay is shown")
	assert_false(hq._car_layer.visible, "the car-park overlay is hidden at the title")
	assert_eq(hq._cars.size(), 1, "the player's whole collection is parked on the title (the starter so far)")
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


# The 3D map table can't take native focus (left/right pans / the pins are spatial),
# so it carries a keyboard cursor: a selected pin that cycles (wrapping), pops bigger,
# and opens its rally detail on select.
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
	assert_almost_eq(float((pins[0] as Node3D).scale.x), 1.4, 0.01, "the focused pin is enlarged")
	assert_almost_eq(float((pins[1] as Node3D).scale.x), 1.0, 0.01, "an unfocused pin stays normal size")

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


# The tuning hub keeps left/right for cycling the car, so Tuning/Upgrades are a manual
# up/down cursor; opening a page hands off to native focus on its sliders/buttons.
func test_hq_lift_hub_has_an_up_down_cursor() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_lift()
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.LIFT, "the tuning bay is open")
	assert_eq(hq._lift_page, hq.LiftPage.HUB, "it opens on the hub")
	assert_eq(hq._hub_focus, 0, "the hub cursor starts on Tuning")
	hq._move_hub_focus(1)
	assert_eq(hq._hub_focus, 1, "down moves the cursor to Upgrades")
	hq._move_hub_focus(1)
	assert_eq(hq._hub_focus, 0, "it wraps back to Tuning")

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
	dev._grant_car("aventador", "Lamborghini Aventador")
	assert_eq(int(_save.profile["cars"].size()), before + 1, "unlocking grants a car instance")
	# Add any upgrade: it lands in the inventory.
	dev._add_upgrade("engine_stage1", "Stage 1 Engine Kit")
	assert_eq(int(_save.profile["inventory"].get("engine_stage1", 0)), 1,
		"adding an upgrade puts it in inventory")
	# Wipe: everything resets to a fresh new game.
	dev._wipe_progress()
	assert_eq(int(_save.profile["cars"].size()), 0, "wipe clears all owned cars")
	assert_true((_save.profile["inventory"] as Dictionary).is_empty(), "wipe clears the inventory")


func test_hq_title_parks_all_owned_cars() -> void:
	# The title shows the whole collection, regardless of rally eligibility — grant
	# an AWD RS3 (which an RWD rally would exclude) and it's still parked.
	_save.grant_car("rs3", false)
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	assert_eq(hq._cars.size(), 2, "the title parks every owned car (starter + RS3)")


func test_hq_start_flies_into_the_garage() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_exterior_start()
	assert_eq(hq._view, hq.View.GARAGE, "Start flies the camera into the garage")
	assert_true(hq._garage_layer.visible, "the garage overlay is shown")
	assert_false(hq._title_layer.visible, "the title overlay is hidden in the garage")


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
	assert_gt(normal.find_children("*", "Area3D", true, false).size(), 0, "an unlocked pin is pickable")


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
	# Own an AWD RS3 alongside the RWD starter, pick the RWD-only rally and enter: only
	# the eligible (RWD) car is parked, the AWD car is filtered out.
	_save.grant_car("rs3", false)
	hq._on_rally_pin("rwd_masters")
	hq._enter_car_screen()
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.CARPARK, "Enter Rally flies out to the car park")
	assert_true(hq._car_layer.visible, "the car-park overlay is shown")
	assert_false(hq._detail_layer.visible, "the detail overlay is hidden in the car park")
	assert_eq(hq._cars.size(), 1, "only the eligible (RWD) car is parked")
	assert_eq(hq._cars[0].current_car_name(), "Mazda MX-5", "the AWD RS3 is filtered out of an RWD-only rally")
	assert_string_contains(hq._rally_banner.text, "RWD CARS", "the banner spells out the rally restriction")


func test_hq_open_rally_parks_the_whole_lineup_with_per_car_meshes() -> void:
	# Two box-bodied cars of different sizes must keep their OWN body meshes — the
	# car scene shares mesh sub-resources across instances, so without per-instance
	# duplication both would render at whichever was applied last.
	_save.grant_car("rs3", false)       # body 1.55 x 0.60 x 4.00
	_save.grant_car("mustang", false)   # body 1.92 x 0.55 x 4.78
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_rally_pin("shakedown")  # open-class: all three are eligible
	hq._enter_car_screen()
	await get_tree().process_frame
	assert_eq(hq._cars.size(), 3, "starter + the two granted cars are all eligible + parked")
	var size_by_name := {}
	for car in hq._cars:
		var chassis := car.get_node("Chassis") as MeshInstance3D
		size_by_name[car.current_car_name()] = (chassis.mesh as BoxMesh).size
	assert_eq(size_by_name["Audi RS3"], Vector3(1.55, 0.6, 4.0), "the RS3 keeps its own body size")
	assert_eq(size_by_name["Ford Mustang GT"], Vector3(1.92, 0.55, 4.78), "the Mustang keeps its own body size")
	assert_ne(size_by_name["Audi RS3"], size_by_name["Ford Mustang GT"],
		"parked cars do NOT share one mesh (per-instance duplication)")


func test_hq_parked_cars_settle_live_then_freeze() -> void:
	# Parked cars drop in LIVE (so they settle onto their suspension), then freeze at
	# the settled pose so a full car park costs nothing to keep parked.
	_save.grant_car("rs3", false)
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_rally_pin("shakedown")
	hq._enter_car_screen()
	await get_tree().process_frame
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
	hq._freeze_lineup(hq._settle_generation - 1)
	for car in hq._cars:
		assert_false(car.freeze, "a superseded freeze leaves the new lineup live")


func test_hq_cycling_focus_changes_the_focused_and_selected_car() -> void:
	_save.grant_car("rs3", false)
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_rally_pin("shakedown")  # open-class: both cars eligible
	hq._enter_car_screen()
	await get_tree().process_frame
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
	_save.grant_car("rs3", false)
	_save.grant_car("mustang", false)
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_rally_pin("shakedown")  # open-class: starter + the two granted cars
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
	_save.grant_car("rs3", false)
	_save.grant_car("mustang", false)  # 2 granted; the boot starter makes 3 > cap
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.OVERFLOW, "over the cap, HQ boots to the scrap prompt")
	assert_true(hq._overflow_layer.visible, "the overflow overlay is shown")
	assert_false(hq._title_layer.visible, "the title overlay is hidden while overflowing")
	assert_eq(hq._cars.size(), 3, "the whole collection is parked to choose from")
	assert_string_contains(hq._overflow_banner.text, "3 / 2", "the banner shows owned vs the cap")


# Scrapping cars drops the count and, once back at the cap, flies out to the title.
func test_hq_scrapping_clears_overflow_and_returns_to_title() -> void:
	Config.data.max_owned_cars = 2
	_save.grant_car("rs3", false)
	_save.grant_car("mustang", false)
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	assert_eq(_save.profile["cars"].size(), 3, "3 owned at boot (starter + 2)")
	# Focus a scrappable (non-immortal) car and scrap it.
	while bool(hq._eligible[hq._focus].get("immortal", false)):
		hq._cycle_focus(1)
	hq._on_scrap_pressed()
	await get_tree().process_frame
	assert_eq(_save.profile["cars"].size(), 2, "scrapping removed one car")
	assert_eq(hq._view, hq.View.EXTERIOR, "back at the cap, HQ flies out to the title")
	assert_true(hq._title_layer.visible, "the title overlay is shown again")


# The immortal starter can't be scrapped: its scrap button is disabled with a note.
func test_hq_overflow_cannot_scrap_immortal_starter() -> void:
	Config.data.max_owned_cars = 1
	_save.grant_car("rs3", false)  # starter + this = 2 > cap
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.OVERFLOW, "over the cap on boot")
	# Find the immortal starter in the lineup and focus it.
	for i in hq._eligible.size():
		if bool(hq._eligible[i].get("immortal", false)):
			hq._focus = i
			hq._focus_changed(true)
			break
	assert_true(hq._scrap_button.disabled, "the immortal starter's scrap action is disabled")
	assert_string_contains(hq._overflow_note.text, "CAN'T BE SCRAPPED", "a note explains why")
	# Scrapping it anyway is a no-op (count unchanged, still overflowing).
	hq._on_scrap_pressed()
	assert_eq(_save.profile["cars"].size(), 2, "the starter wasn't scrapped")
	assert_eq(hq._view, hq.View.OVERFLOW, "still in the scrap prompt")


# At or under the cap, HQ boots straight to the title (no scrap prompt).
func test_hq_at_car_limit_boots_to_the_title() -> void:
	Config.data.max_owned_cars = 3
	_save.grant_car("rs3", false)
	_save.grant_car("mustang", false)  # starter + 2 = 3 == cap (not over)
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	assert_eq(hq._view, hq.View.EXTERIOR, "at the cap (not over), HQ boots to the title")
	assert_false(hq._overflow_layer.visible, "no scrap prompt at the cap")


func test_hq_carpark_gates_a_wrecked_car_and_repairs_it() -> void:
	# A wrecked (0 HP) car still appears in the eligible lineup, but it's too damaged
	# to enter — Start is disabled until a Repair Kit restores it to full health.
	var owned: Dictionary = _save.grant_car("rs3", false)
	var id := int(owned["instance_id"])
	_save.apply_damage(id, 999999.0)  # wreck it (kept at 0 HP, not deleted)
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._on_rally_pin("shakedown")  # open-class: starter + RS3 both eligible
	hq._enter_car_screen()
	await get_tree().process_frame
	# Focus the wrecked RS3 in the lineup.
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
	assert_almost_eq(float(_save.get_car(id)["hp"]), float(CarLibrary.by_id("rs3")["max_hp"]), 0.001,
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
	assert_eq(hq._lift_car.current_car_name(), "Mazda MX-5", "the lift shows the selected car")
	# Going back to the garage lowers it again.
	hq._lift_back()
	assert_eq(hq._view, hq.View.GARAGE, "Back returns to the garage")
	assert_false(hq._lift_raised, "the car lowers back to the ground in the garage")


func test_hq_lift_opens_on_a_hub_with_its_own_menu_pages() -> void:
	# The bay opens on the HUB (change-car selector + Tuning/Upgrades buttons beside the
	# car); each button opens that menu as its own page, and Back returns to the hub.
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._enter_lift()
	await get_tree().process_frame
	assert_eq(hq._lift_page, hq.LiftPage.HUB, "entering the bay lands on the hub page")
	assert_true(hq._lift_hub_controls.visible, "the hub shows the change-car + menu buttons")
	assert_false(hq._lift_menu_bg.visible, "no sub-menu panel is shown on the hub")
	# Open Tuning: its page (the sliders) takes over; the hub controls hide.
	hq._open_lift_page(hq.LiftPage.TUNE)
	assert_true(hq._lift_menu_bg.visible, "the sub-menu panel shows on the Tuning page")
	assert_true(hq._lift_tune_box.visible, "the Tuning page shows the sliders")
	assert_false(hq._lift_upgrades_box.visible, "the Upgrades menu is hidden on the Tuning page")
	assert_false(hq._lift_hub_controls.visible, "the hub controls hide while a menu is open")
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
	var owned: Dictionary = _save.grant_car("rs3", false)
	var id := int(owned["instance_id"])
	_save.add_item("brake_kit")
	_save.install_upgrade(id, "brake_kit")
	_save.set_selected_car(id)
	hq._enter_lift()
	await get_tree().process_frame
	assert_true(hq._lift_sliders["brake_bias"].editable, "the brake kit unlocks brake-bias tuning")
	assert_false(hq._lift_sliders["aero_balance"].editable, "aero still locked (no aero kit)")


func test_hq_lift_change_car_updates_the_selection() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	_save.grant_car("rs3", false)  # now two owned cars
	hq._enter_lift()
	await get_tree().process_frame
	var before: int = _save.selected_instance_id()
	hq._cycle_lift_car(1)
	assert_ne(_save.selected_instance_id(), before, "cycling the lift car changes the selected car")
	assert_eq(hq._lift_car_instance_id, _save.selected_instance_id(),
		"the raised car follows the new selection")


func test_hq_lift_installs_an_upgrade_from_inventory() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var owned: Dictionary = _save.grant_car("rs3", false)
	var id := int(owned["instance_id"])
	_save.set_selected_car(id)
	_save.add_item("engine_stage1")
	hq._enter_lift()
	await get_tree().process_frame
	hq._open_lift_page(hq.LiftPage.UPGRADES)
	# Installing now asks for confirmation first — nothing is fitted until accepted.
	hq._install_upgrade(id, "engine_stage1")
	assert_false(_save.get_car(id)["installed_upgrades"].has("engine_stage1"),
		"the part is not fitted until the confirmation dialog is accepted")
	assert_eq(int(_save.profile["inventory"].get("engine_stage1", 0)), 1,
		"the part stays in inventory until the fit is confirmed")
	# Accepting the dialog commits the fit and consumes the part for good.
	hq._confirm_dialog.confirmed.emit()
	assert_true(_save.get_car(id)["installed_upgrades"].has("engine_stage1"),
		"accepting the confirmation fits the part to the selected car")
	assert_eq(int(_save.profile["inventory"].get("engine_stage1", 0)), 0,
		"the installed part is consumed from inventory")


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
	var owned: Dictionary = _save.grant_car("rs3", false)
	RallySession.start_rally(RallyLibrary.by_id("coastal_sprint"), owned, [60000, 60000, 60000])
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
	# The Next button is focused (once revealed) so the reward sequence steps with a
	# keyboard / gamepad.
	assert_eq(pod._next_button.focus_mode, Control.FOCUS_ALL, "the Next button is focusable")
	assert_eq(pod.get_viewport().gui_get_focus_owner(), pod._next_button,
		"Next is focused for keyboard / gamepad")


func test_podium_sequence_reveals_leaderboard_then_car_then_upgrade() -> void:
	# A top-3 win that grants the Porsche 911 plus the single per-rally upgrade. The
	# reward sequence steps PODIUM -> LEADERBOARD -> CAR_REVEAL -> UPGRADE_REVEAL, with
	# the slot-machine spins resolving instantly under headless.
	RallySession._last_result = {
		"placed": 1, "completed": true, "combined_ms": 60000, "dnf": false,
		"rally_name": "Coastal Sprint", "showdown_won": false,
		"car_reward": "porsche911", "car_reward_is_new": true,
		"upgrades": ["engine_stage1"],
		"standings": [
			{"name": "You", "combined_ms": 60000, "dnf": false, "is_player": true, "placed": 1},
			{"name": "Rival 1", "combined_ms": 70000, "dnf": false, "is_player": false, "placed": 2},
			{"name": "Rival 2", "combined_ms": -1, "dnf": true, "is_player": false, "placed": -1},
		],
	}
	var pod: Node3D = load("res://podium.tscn").instantiate()
	add_child_autofree(pod)
	await get_tree().process_frame
	assert_eq(pod._stages, [pod.Stage.PODIUM, pod.Stage.LEADERBOARD, pod.Stage.CAR_REVEAL, pod.Stage.UPGRADE_REVEAL] as Array[int],
		"all four reward stages are queued when a car + upgrade were won")

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
	var car := _label_texts(pod)
	assert_string_contains(car, "PORSCHE 911", "the won car is revealed by name")
	assert_string_contains(car, "NEW", "an un-owned car reward is flagged NEW")

	# Next -> the upgrade slot-machine reveal.
	pod._on_next()
	await get_tree().process_frame
	assert_eq(pod._stage, pod.Stage.UPGRADE_REVEAL, "Next from the car reveal shows the upgrade reveal")
	assert_string_contains(_label_texts(pod), "STAGE 1 ENGINE KIT", "the won upgrade is revealed by name")
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
	var owned: Dictionary = _save.grant_car("rs3", false)
	var id := int(owned["instance_id"])
	RallySession.start_rally(RallyLibrary.by_id("coastal_sprint"), owned, [60000, 60000, 60000])
	# Boot the run scene with a session active: world.gd fields the OwnedCar.
	SceneHelpers.minimal_world()
	var scene: Node3D = load("res://main.tscn").instantiate()
	add_child_autofree(scene)
	await get_tree().process_frame
	var car: VehicleBody3D = scene.get_node("Car")
	assert_eq(car.damage.instance_id, id, "the car's damage model is bound to the fielded instance")
	assert_false(car.damage.immortal, "a non-immortal owned car")
	assert_eq(car.current_car_name(), "Audi RS3", "the owned car's model is fielded, not the default")
