extends GutTest
# The reward reveal must NOT auto-enable a normal part; the player enables it later
# in the upgrades menu. Synthetic car + synthetic granted part (no catalogue lean).

const CarFixtures = preload("res://tests/headless/car_fixtures.gd")

const T_PART := {
	"id": "t_reveal_part", "name": "Synthetic Reveal Part", "slot": "chassis",
	"tier": 1, "consumable": false, "effect": {},
}

var _save: Node

func before_each() -> void:
	Config.reset()
	CarFixtures.install()
	UpgradeLibrary.override_for_test([T_PART] as Array[Dictionary])
	_save = get_node("/root/Save")
	_save.profile_path = "user://test_upgrade_reveal_grant_profile.json"
	_save.save_disabled = false
	_save.load_or_new()

func after_each() -> void:
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	Config.reset()
	UpgradeLibrary.reset()
	CarFixtures.restore()

func test_normal_part_reveal_leaves_part_fitted_disabled_and_emits_finished() -> void:
	var car: Dictionary = _save.grant_car("fx_awd")
	var id := int(car["instance_id"])
	var item_id := "t_reveal_part"
	_save.install_upgrade(id, item_id, false)  # granted fitted-disabled (as rally_session does)
	var reveal := UpgradeReveal.new()
	add_child_autofree(reveal)
	reveal._car_instance_id = id
	var got_finished := [false]
	reveal.finished.connect(func() -> void: got_finished[0] = true)
	reveal._offer_choice(item_id, "Test Part")  # normal-part path
	await get_tree().process_frame
	var owned_car: Dictionary = _save.get_car(id)
	assert_true(owned_car["installed_upgrades"].has(item_id), "part stays fitted")
	assert_false(UpgradeLibrary.is_enabled(owned_car, item_id), "part stays DISABLED (no auto-enable)")
	assert_true(got_finished[0], "reveal emits finished without Apply/Keep")
