extends GutTest
# Docs: features/hq.md, features/tuning.md, features/menu-navigation.md
# Tests: (this file)
# The tuning-lift station (scripts/hq_tuning_lift.gd, class_name HqTuningLift) — the seam
# tests for the cut that moved it out of hq.gd. Three things are pinned here:
#
#   1. hq.gd CONSTRUCTS and WIRES the module.
#   2. INPUT ROUTING is unchanged. `handle_input` is the LIFT branch of hq.gd's
#      _unhandled_input dispatch (it was `hq._lift_input` before the cut), and the station is
#      still fully keyboard/gamepad navigable — up/down between the two HUB rows, left/right
#      within a row, select to fire, back to leave. CLAUDE.md: no menu ships pointer-only.
#   3. The controller's forwarders still delegate, because hq_overlays.gd wires the lift's
#      buttons to them by name (_hq._lift_hub, _hq._cycle_lift_car, _hq._open_lift_page, …)
#      and the existing menu tests drive them off the controller.
#
# Nothing here asserts an authored value: no lift height, no raise time, no repair price, no
# car stat, no catalogue entry by identity. The roster is CarFixtures' synthetic one.

const SceneHelpers = preload("res://tests/headless/scene_helpers.gd")
const CarFixtures = preload("res://tests/headless/car_fixtures.gd")
const TEST_PATH := "user://test_hq_tuning_lift_profile.json"

var _save: Node


func before_each() -> void:
	get_viewport().gui_release_focus()
	Config.reset()
	Config.data.world_space_menus = false
	Config.data.hq_tree_count = 8
	Config.data.hq_bush_count = 8
	CarFixtures.install()
	UpgradeFixtures.install()
	RallyFixtures.install()
	_save = get_node("/root/Save")
	_clean()
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.load_or_new()
	_save.profile["starter_picked"] = true
	_save.grant_car("fx_light_rwd")


func after_each() -> void:
	_clean()
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	Config.reset()
	CarFixtures.restore()
	UpgradeFixtures.restore()
	RallyFixtures.restore()
	RallyLibrary.reset()
	RegionLibrary.reset()


func _clean() -> void:
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


func _hq() -> Node3D:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	return hq


func _press(action: String) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = action
	e.pressed = true
	return e


# --- The wiring ---------------------------------------------------------------

func test_hq_constructs_the_tuning_lift_module_wired_back_to_itself() -> void:
	var hq: Node3D = await _hq()
	assert_not_null(hq._tuning_lift, "_build_hq constructs the lift station")
	assert_true(hq._tuning_lift is HqTuningLift, "and it is an HqTuningLift")
	assert_eq(hq._tuning_lift._hq, hq,
		"the module holds a back-reference to the controller, like every other hq_*.gd cut")


# The station's public surface stayed on the controller, because hq_overlays.gd binds the
# lift's buttons to these exact names. If one of them disappears the overlay wires a dead
# Callable and the menu goes pointer-dead — silently, at run time.
func test_the_controller_still_exposes_every_entry_point_the_overlay_binds() -> void:
	var hq: Node3D = await _hq()
	for name in ["_enter_lift", "_lift_hub", "_lift_back", "_open_lift_page", "_cycle_lift_car",
			"_repair_selected_car", "_refresh_repair_button", "_on_dev_car_upgraded",
			"_on_lift_upgrade_changed", "_test_drive", "_ensure_lift_car", "_clear_lift_car",
			"_refresh_lift_ui", "_move_hub_focus", "_move_lift_row", "_activate_hub_focus"]:
		assert_true(hq.has_method(name),
			"hq_overlays.gd / the menu tests call hq.%s — the forwarder must stay" % name)


func test_the_forwarders_delegate_into_the_module() -> void:
	var hq: Node3D = await _hq()
	hq._enter_lift()
	await get_tree().process_frame
	assert_eq(hq.view(), hq.View.LIFT, "the forwarder walked us into the bay")
	assert_eq(hq._lift_page, hq.LiftPage.HUB, "entering the bay lands on the hub")

	hq._open_lift_page(hq.LiftPage.TUNE)
	assert_eq(hq._lift_page, hq.LiftPage.TUNE, "the forwarder opened a sub-page")
	hq._lift_hub()
	assert_eq(hq._lift_page, hq.LiftPage.HUB, "and the forwarder came back to the hub")


# --- Input routing (features/menu-navigation.md) ------------------------------

# The LIFT branch of the dispatch. `handle_input` answers whether the event was this
# station's to act on — the same contract HqTable.handle_input and HqCarpark.handle_input
# have — and hq.gd's `match _view` hands it every event while the bay is up.
func test_handle_input_is_the_lift_branch_and_reports_what_it_consumed() -> void:
	var hq: Node3D = await _hq()
	hq._enter_lift()
	await get_tree().process_frame
	assert_true(hq._tuning_lift.handle_input(_press("menu_left")),
			"left is the hub cursor's, so the station consumes it")
	assert_true(hq._tuning_lift.handle_input(_press("menu_right")),
			"and so is right")
	assert_false(hq._tuning_lift.handle_input(_press("dev_complete_rally")),
			"an action the station has no use for is left for anything below it")


# The HUB is two cursor rows. Up/down move BETWEEN them, and the cursor never lands on a row
# with nothing live in it — with one car owned the chevrons are hidden and disabled, and the
# selector row is only reachable because Repair lives there too. Asserted as "the row the
# cursor is on is a row with a live stop", not as a particular row index.
func test_the_hub_rows_are_reachable_by_keyboard_and_never_strand_the_cursor() -> void:
	var hq: Node3D = await _hq()
	hq._enter_lift()
	await get_tree().process_frame
	assert_eq(hq._lift_row, hq.LiftRow.ACTIONS, "entering the bay starts on the actions row")

	hq._tuning_lift.handle_input(_press("menu_up"))
	var went_up: bool = hq._lift_row == hq.LiftRow.SELECTOR
	if went_up:
		# It moved, so the selector row must have had something live to move ONTO.
		var live := false
		for button in hq._lift_selector_cursor.buttons:
			if is_instance_valid(button) and not (button as BaseButton).disabled:
				live = true
		assert_true(live, "up only lands on the selector row when that row has a live stop")
		hq._tuning_lift.handle_input(_press("menu_down"))
	assert_eq(hq._lift_row, hq.LiftRow.ACTIONS, "down returns to the actions row")


# Left/right walk the actions row, and the two are inverses. Driven entirely through
# handle_input, so this covers the routing as well as the cursor. Asserted as "it moves, and
# stepping back undoes it" rather than against any index — the row's CONTENTS are authored
# (Back / Upgrades / Tuning / Test Drive, and the row is rebuilt by hq_overlays.gd).
func test_the_actions_row_walks_under_left_right() -> void:
	var hq: Node3D = await _hq()
	hq._enter_lift()
	await get_tree().process_frame
	var start: int = hq._hub_focus
	hq._tuning_lift.handle_input(_press("menu_right"))
	assert_ne(hq._hub_focus, start, "right moves the cursor along the row")
	hq._tuning_lift.handle_input(_press("menu_left"))
	assert_eq(hq._hub_focus, start, "and left steps straight back onto where it was")

	assert_true(hq._tuning_lift.handle_input(_press("menu_select")),
			"select on the hub is the station's to act on")


# Back is one level at a time: a sub-page returns to the hub, and the hub leaves for the
# garage. This is the whole reason the station needs its own branch rather than a MenuNav.
func test_back_unwinds_the_bay_one_level_at_a_time() -> void:
	var hq: Node3D = await _hq()
	hq._enter_lift()
	await get_tree().process_frame
	hq._open_lift_page(hq.LiftPage.UPGRADES)
	assert_true(hq._tuning_lift.handle_input(_press("menu_back")),
			"back on a sub-page is the station's")
	assert_eq(hq._lift_page, hq.LiftPage.HUB, "and it returns to the hub rather than leaving")

	assert_true(hq._tuning_lift.handle_input(_press("menu_back")),
			"back on the hub is the station's too")
	assert_eq(hq.view(), hq.View.GARAGE, "and it leaves the bay for the garage")


# --- The display car ----------------------------------------------------------

# The lift's own prop, still spawned and stowed through the module. Asserted structurally (a
# car node is on the lift, and clearing takes it off) — no position, height or timing, all of
# which are GameConfig tunables.
func test_the_lift_car_is_spawned_and_cleared_through_the_module() -> void:
	var hq: Node3D = await _hq()
	hq._ensure_lift_car()
	assert_true(is_instance_valid(hq._lift_car), "the selected car is put on the lift")
	assert_eq(hq._lift_car_instance_id, Save.selected_instance_id(),
		"and the cache key names the car it was built for")

	hq._clear_lift_car()
	assert_false(is_instance_valid(hq._lift_car) and hq._lift_car.visible,
		"clearing takes it off the lift (freed, or hidden and stowed for reuse)")
