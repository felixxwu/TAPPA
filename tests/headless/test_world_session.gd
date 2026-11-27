extends GutTest
# The save's world (features/world-session.md): WorldSession's state and its round trips through
# the profile.

const TEST_PATH := "user://test_world_session_profile.json"

var _save: Node


func before_each() -> void:
	_save = get_node("/root/Save")
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.reset_new_game() if _save.has_method("reset_new_game") else _save.load_or_new()
	_save.profile = _save._default_profile()
	CarFixtures.install()


func after_each() -> void:
	get_tree().paused = false
	CarFixtures.restore()
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


func _any_car() -> String:
	return String(CarLibrary.all()[0]["id"])


func test_a_fresh_profile_has_no_world() -> void:
	assert_false(WorldSession.has_world())


func test_a_new_world_owns_its_starter_car() -> void:
	WorldSession.new_world(42, _any_car())
	assert_true(WorldSession.has_world())
	assert_eq(WorldSession.world_seed(), 42)
	assert_eq(String(WorldSession.active_car().get("model_id", "")), _any_car())


func test_a_new_world_replaces_the_old_one_and_its_cars() -> void:
	WorldSession.new_world(1, _any_car())
	var second := String(CarLibrary.all()[1]["id"])
	WorldSession.new_world(2, second)
	assert_eq(WorldSession.world_seed(), 2)
	assert_eq((_save.profile[_save.KEY_CARS] as Array).size(), 1)
	assert_eq(String(WorldSession.active_car()["model_id"]), second)


func test_the_world_survives_a_save_and_reload() -> void:
	WorldSession.new_world(77, _any_car())
	_save.save_now()
	_save.profile = {}
	_save.load_or_new()
	assert_true(WorldSession.has_world())
	assert_eq(WorldSession.world_seed(), 77)


# An island-era world keeps loading: keys no longer read are ignored.
func test_an_old_world_with_island_keys_still_loads() -> void:
	WorldSession.new_world(3, _any_car())
	var w: Dictionary = _save.profile[_save.KEY_WORLD]
	w.merge({"pose": [1.0, 2.0, 3.0, 0.0], "lit": [0, 4], "seen": [0.0], "money": 12, "dropped": {}})
	_save.save_now()
	_save.profile = {}
	_save.load_or_new()
	assert_true(WorldSession.has_world())
	assert_eq(String(WorldSession.active_car()["model_id"]), _any_car())


# Any replacement of the world, from inside (a new world) or out (a downloaded or wiped profile),
# moves the generation on and is announced, so a scene or cache holding the old one lets go.
func test_replacing_the_world_moves_the_generation_on() -> void:
	WorldSession.new_world(1, _any_car())
	var g := WorldSession.generation
	watch_signals(WorldSession)
	_save.adopt_profile(_save._default_profile())
	assert_gt(WorldSession.generation, g, "a downloaded profile")
	assert_signal_emitted(WorldSession, "world_changed")
	g = WorldSession.generation
	WorldSession.new_world(2, _any_car())
	assert_gt(WorldSession.generation, g, "a new world")


func test_a_pre_free_roam_profile_is_refused() -> void:
	var old: Dictionary = _save._default_profile()
	old["schema_version"] = 7
	old[_save.KEY_WORLD] = {"seed": 5}
	assert_true(_save._migrate(old).is_empty())
