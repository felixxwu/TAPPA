extends GutTest
# Docs: features/hq.md, features/reward-system.md, features/prize-rallies.md
# Tests: (this file) — and see test_menu_flow.gd's "present-box car reveal" section, which
# pins the player-facing FLOW (forced Back, the anchored panel, "opening mints nothing").
# This file covers the SEAM instead: that hq.gd constructs and wires
# scripts/hq_present_reveal.gd (class_name HqPresentReveal), that the three entry points the
# controller is called by still delegate into it, and that the reveal's state ends up where
# the rest of hq.gd reads it from.
#
# The beat deliberately has NO input branch of its own — it runs inside View.CARPARK
# (CarparkMode.PRESENT), so keyboard/gamepad input reaches it through _carpark_ui.handle_input
# and hq.gd's _car_back / _on_start_pressed. That routing is asserted below, because it is
# exactly what the cut must not have changed.
#
# Nothing here asserts an authored value: no box size, no lid rise, no animation timing, no
# catalogue entry by identity (the roster is CarFixtures' synthetic one).

const SceneHelpers = preload("res://tests/headless/scene_helpers.gd")
const CarFixtures = preload("res://tests/headless/car_fixtures.gd")
const TEST_PATH := "user://test_hq_present_reveal_profile.json"

var _save: Node


func before_each() -> void:
	get_viewport().gui_release_focus()
	Config.reset()
	Config.data.world_space_menus = false
	Config.data.hq_tree_count = 8
	Config.data.hq_bush_count = 8
	Config.data.map_hq_reveal_radius = 10.0
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
	RallySession.pending_car_reveal_instance_id = -1
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


# --- The wiring ---------------------------------------------------------------

func test_hq_constructs_the_present_reveal_module_wired_back_to_itself() -> void:
	var hq: Node3D = await _hq()
	assert_not_null(hq._present_ui, "_build_hq constructs the reveal")
	assert_true(hq._present_ui is HqPresentReveal, "and it is an HqPresentReveal")
	assert_eq(hq._present_ui._hq, hq,
		"the module holds a back-reference to the controller, like every other hq_*.gd cut")


# The three names hq.gd (and, through _build_hq's hand-off, the rally result) reaches the beat
# by. They stay on the controller so no call site had to move.
func test_the_controller_still_exposes_the_three_entry_points() -> void:
	var hq: Node3D = await _hq()
	for name in ["_enter_present_box", "_open_present", "_leave_present_to_garage"]:
		assert_true(hq.has_method(name), "hq.%s must stay on the controller" % name)


# --- The behaviour reachable through it ---------------------------------------

# Entering the beat through the controller's forwarder puts the player in the forced screen,
# on an EMPTY lot with exactly one bay — the bay both the panel and the camera key off.
func test_entering_the_present_box_opens_a_forced_single_bay_lot() -> void:
	var hq: Node3D = await _hq()
	var won: Dictionary = _save.grant_car("fx_light_rwd")
	hq._enter_present_box(int(won["instance_id"]))
	await get_tree().process_frame
	assert_eq(hq.view(), hq.View.CARPARK, "the beat runs inside the car park view")
	assert_eq(hq._carpark_mode, hq.CarparkMode.PRESENT, "in present-box mode")
	assert_false(hq._present_opened, "the box starts shut")
	assert_true(is_instance_valid(hq._present_box), "and there is a box standing in the lot")
	assert_eq(hq._markers.size(), 1,
		"one bay, which the panel is welded to and the camera frames")
	assert_true(is_instance_valid(hq._present_marker), "and the module recorded it")


# The reveal's STATE lives on HqController, not inside the module — deliberately, because
# hq.gd's own _car_back and _on_start_pressed branch on `_present_opened` and test_menu_flow.gd
# asserts on it. Opening through the module has to move the controller's copy.
func test_opening_the_box_moves_the_state_the_controller_reads() -> void:
	var hq: Node3D = await _hq()
	var won: Dictionary = _save.grant_car("fx_light_rwd")
	var won_id := int(won["instance_id"])
	hq._enter_present_box(won_id)
	await get_tree().process_frame

	hq._open_present()
	await get_tree().process_frame
	assert_true(hq._present_opened, "the controller's flag is what flipped")
	assert_eq(Save.selected_instance_id(), won_id,
		"the opened car becomes the selected one, so the exit lands on it")


# The forced beat, still forced: Back does nothing until the box is open, then leaves for the
# GARAGE. Driven through hq.gd's own handlers rather than the module, since that is the route
# a keyboard/gamepad Back actually takes — the present has no input branch of its own.
func test_back_is_refused_until_the_box_is_open_then_lands_in_the_garage() -> void:
	var hq: Node3D = await _hq()
	var won: Dictionary = _save.grant_car("fx_light_rwd")
	hq._enter_present_box(int(won["instance_id"]))
	await get_tree().process_frame

	hq._car_back()
	assert_eq(hq._carpark_mode, hq.CarparkMode.PRESENT, "Back cannot leave an unopened box")

	hq._open_present()
	await get_tree().process_frame
	hq._car_back()
	assert_eq(hq.view(), hq.View.GARAGE, "once open, Back leaves for the garage")
	assert_eq(hq._carpark_mode, hq.CarparkMode.RALLY, "and the lot returns to its ordinary mode")
	assert_false(is_instance_valid(hq._present_box), "the box prop is freed on the way out")


# A profile edited between the win and the reveal must not strand the player in a forced
# screen with nothing in it: the box bails to the garage rather than opening on no car.
func test_opening_a_box_whose_car_no_longer_exists_leaves_rather_than_stranding() -> void:
	var hq: Node3D = await _hq()
	hq._enter_present_box(999999)
	await get_tree().process_frame
	hq._open_present()
	await get_tree().process_frame
	assert_eq(hq.view(), hq.View.GARAGE, "no car to show, so the beat lets the player out")
	assert_false(hq._present_opened, "and nothing was presented")
