extends GutTest
# The Save autoload (player profile / persistence). Exercises the round-trip,
# default profile, migration, integrity fallbacks, and wreck semantics described
# in todo/save-persistence.md. Runs against a throwaway user:// file so a real
# profile is never touched.

const TEST_PATH := "user://test_profile.json"

var _save: Node


func before_each() -> void:
	_save = get_node("/root/Save")
	_clean()
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.load_or_new()  # fresh default against the test path


func after_each() -> void:
	_clean()
	# Restore the real path so we don't leak the test redirect into other files.
	_save.profile_path = _save.DEFAULT_PROFILE_PATH


func _clean() -> void:
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


func test_default_profile_is_empty_and_valid() -> void:
	assert_false(_save.has_save(), "no file on disk yet -> has_save() false")
	assert_eq(_save.profile["schema_version"], _save.SCHEMA_VERSION, "default carries current schema")
	assert_eq(_save.profile["cars"].size(), 0, "no owned cars")
	assert_false(_save.profile["starter_picked"], "starter not yet picked")


func test_round_trip_survives_save_and_reload() -> void:
	var car: Dictionary = _save.grant_car("mx5")
	_save.add_item("repair_kit", 2)
	_save.complete_rally("alpine", 123456)
	_save.set_tuning(car["instance_id"], {"brake_bias": 0.55})
	_save.save_now()
	assert_true(_save.has_save(), "file written to disk")

	# Wipe in-memory state, reload from disk, assert it came back intact.
	_save.profile = {}
	_save.load_or_new()
	assert_eq(_save.profile["cars"].size(), 1, "owned car reloaded")
	assert_eq(_save.profile["cars"][0]["model_id"], "mx5", "model id reloaded")
	assert_eq(int(_save.profile["inventory"]["repair_kit"]), 2, "inventory reloaded")
	assert_true(_save.rally_completed("alpine"), "rally completion reloaded")
	assert_eq(int(_save.profile["rallies"]["alpine"]["best_combined_ms"]), 123456, "best time reloaded")
	assert_almost_eq(float(_save.profile["cars"][0]["tuning"]["brake_bias"]), 0.55, 0.001, "tuning reloaded")


func test_instance_ids_are_unique_per_grant() -> void:
	var a: Dictionary = _save.grant_car("mx5")
	var b: Dictionary = _save.grant_car("mx5")  # same model, must diverge
	assert_ne(a["instance_id"], b["instance_id"], "two instances of one model get distinct ids")
	assert_eq(_save.profile["cars"].size(), 2, "both instances owned")


func test_grant_car_seeds_hp_from_library_max() -> void:
	var car: Dictionary = _save.grant_car("aventador")
	assert_almost_eq(float(car["hp"]), float(CarLibrary.by_id("aventador")["max_hp"]), 0.001,
		"new car starts at the library max_hp")


func test_complete_rally_is_idempotent_and_keeps_best_time() -> void:
	_save.complete_rally("alpine", 5000)
	_save.complete_rally("alpine", 6000)  # slower: should not replace
	_save.complete_rally("alpine", 4000)  # faster: should replace
	assert_eq(_save.completed_rally_count(), 1, "completing the same rally twice counts once")
	assert_eq(int(_save.profile["rallies"]["alpine"]["best_combined_ms"]), 4000, "keeps the fastest time")


func test_wreck_keeps_car_at_zero_hp_with_upgrades() -> void:
	var car: Dictionary = _save.grant_car("mustang")
	_save.add_item("engine_stage1", 1)
	assert_true(_save.install_upgrade(car["instance_id"], "engine_stage1"), "upgrade installed")
	assert_false(_save.profile["inventory"].has("engine_stage1"), "item left inventory once fitted")

	_save.wreck_car(car["instance_id"])
	# A wrecked car is NOT deleted — it stays owned at 0 HP, repairable with a kit.
	assert_eq(_save.profile["cars"].size(), 1, "the wrecked car is kept, not removed")
	assert_eq(float(_save.get_car(car["instance_id"])["hp"]), 0.0, "the wrecked car sits at 0 HP")
	assert_true(_save.car_is_wrecked(_save.get_car(car["instance_id"])), "and reads as wrecked")
	# Its upgrades ride along with the car (parts are consumed on fit; never returned).
	assert_false(_save.profile["inventory"].has("engine_stage1"), "the fitted upgrade stays on the car")
	assert_true(_save.get_car(car["instance_id"])["installed_upgrades"].has("engine_stage1"),
		"the upgrade is still installed on the wrecked car")


func test_scrap_removes_car_consumes_upgrades_and_spares_last_car() -> void:
	var starter: Dictionary = _save.grant_car("mx5")
	var car: Dictionary = _save.grant_car("mustang")
	_save.add_item("engine_stage1", 1)
	assert_true(_save.install_upgrade(car["instance_id"], "engine_stage1"), "upgrade installed")

	# Scrapping a car removes it; its fitted upgrade is lost with it (consumed
	# for good when applied, like a wreck — not refunded).
	assert_true(_save.scrap_car(car["instance_id"]), "scrapping a car succeeds while others remain")
	assert_eq(_save.profile["cars"].size(), 1, "scrapped car removed (only the starter remains)")
	assert_false(_save.profile["inventory"].has("engine_stage1"), "fitted upgrade is not refunded on scrap")

	# The player's LAST car can never be scrapped (keeps ≥1 car so the repair-kit
	# safety net always has something to bring back).
	assert_false(_save.scrap_car(starter["instance_id"]), "the last owned car can't be scrapped")
	assert_eq(_save.profile["cars"].size(), 1, "the last car is still owned")
	# An unknown instance is a harmless no-op.
	assert_false(_save.scrap_car(99999), "scrapping an unknown instance is a no-op")


func test_install_replaces_same_slot_incumbent() -> void:
	var car: Dictionary = _save.grant_car("porsche911")
	_save.add_item("engine_stage1", 1)
	_save.add_item("engine_stage2", 1)
	assert_true(_save.install_upgrade(car["instance_id"], "engine_stage1"), "first engine kit fitted")
	# Installing a second engine upgrade replaces the first (same slot).
	assert_true(_save.install_upgrade(car["instance_id"], "engine_stage2"), "second engine kit fitted")
	var fitted: Array = _save.get_car(car["instance_id"])["installed_upgrades"]
	assert_eq(fitted.size(), 1, "only one engine upgrade occupies the slot")
	assert_true(fitted.has("engine_stage2"), "the newer engine kit is fitted")
	assert_false(_save.profile["inventory"].has("engine_stage1"),
		"the replaced incumbent is scrapped, not refunded")


func test_install_rejects_consumables_and_unknown_items() -> void:
	var car: Dictionary = _save.grant_car("mx5")
	_save.add_item("repair_kit", 1)
	assert_false(_save.install_upgrade(car["instance_id"], "repair_kit"), "repair kit can't be slotted")
	assert_false(_save.install_upgrade(car["instance_id"], "bogus"), "unknown item can't be installed")
	assert_eq(int(_save.profile["inventory"]["repair_kit"]), 1, "rejected install leaves inventory intact")


func test_repair_kit_restores_to_full() -> void:
	var car: Dictionary = _save.grant_car("mustang")  # max_hp 1100
	var max_hp := float(CarLibrary.by_id("mustang")["max_hp"])
	_save.apply_damage(car["instance_id"], 500.0)  # 600 hp
	_save.add_item("repair_kit", 2)
	assert_true(_save.use_repair_kit(car["instance_id"]), "repair kit consumed")
	# A kit fully restores the car, not a partial heal.
	assert_almost_eq(float(_save.get_car(car["instance_id"])["hp"]), max_hp, 0.001, "restored to full health")
	assert_eq(int(_save.profile["inventory"]["repair_kit"]), 1, "one kit consumed")
	assert_false(_save.use_repair_kit(car["instance_id"] + 999), "no kit spent on an unknown car")


func test_repair_kit_revives_a_wrecked_car() -> void:
	var car: Dictionary = _save.grant_car("mustang")
	var id := int(car["instance_id"])
	var max_hp := float(CarLibrary.by_id("mustang")["max_hp"])
	_save.apply_damage(id, 999999.0)  # wreck it -> 0 HP, still owned
	assert_true(_save.car_is_wrecked(_save.get_car(id)), "the car is wrecked")
	assert_false(_save.use_repair_kit(id), "can't repair without a kit")
	_save.add_item("repair_kit", 1)
	assert_true(_save.use_repair_kit(id), "a kit revives the wrecked car")
	assert_almost_eq(float(_save.get_car(id)["hp"]), max_hp, 0.001, "the revived car is at full health")
	assert_false(_save.car_is_wrecked(_save.get_car(id)), "and is no longer wrecked")


func test_starter_wrecks_like_any_car() -> void:
	# The starter is no longer invulnerable: lethal damage wrecks it (0 HP, still owned).
	var car: Dictionary = _save.grant_car("mx5")
	_save.apply_damage(car["instance_id"], 999999.0)
	assert_eq(_save.profile["cars"].size(), 1, "the wrecked starter is kept in the garage")
	assert_true(_save.car_is_wrecked(_save.get_car(car["instance_id"])), "the starter can be wrecked")


func test_safety_net_grants_kit_when_all_wrecked_and_none_held() -> void:
	var a: Dictionary = _save.grant_car("mx5")
	var b: Dictionary = _save.grant_car("mustang")
	_save.apply_damage(a["instance_id"], 999999.0)
	_save.apply_damage(b["instance_id"], 999999.0)
	assert_eq(int(_save.profile["inventory"].get("repair_kit", 0)), 0, "no kit before the net fires")
	assert_true(_save.ensure_repair_safety_net(), "a free kit is granted when all cars are wrecked")
	assert_eq(int(_save.profile["inventory"].get("repair_kit", 0)), 1, "exactly one free kit granted")
	# Idempotent: once a kit is held, the net does not keep topping up.
	assert_false(_save.ensure_repair_safety_net(), "no second kit while one is already held")
	assert_eq(int(_save.profile["inventory"].get("repair_kit", 0)), 1, "still just the one kit")


func test_safety_net_no_op_when_a_car_is_healthy() -> void:
	var a: Dictionary = _save.grant_car("mx5")
	_save.grant_car("mustang")  # healthy
	_save.apply_damage(a["instance_id"], 999999.0)  # only one wrecked
	assert_false(_save.ensure_repair_safety_net(), "not stranded: at least one car can still race")
	assert_eq(int(_save.profile["inventory"].get("repair_kit", 0)), 0, "no free kit granted")


func test_safety_net_no_op_with_no_cars() -> void:
	assert_false(_save.ensure_repair_safety_net(), "owning no cars is not the wrecked-out case")
	assert_eq(int(_save.profile["inventory"].get("repair_kit", 0)), 0, "no free kit granted")


func test_apply_damage_wrecks_mortal_car_at_zero() -> void:
	var car: Dictionary = _save.grant_car("mustang")  # mortal
	_save.apply_damage(car["instance_id"], 999999.0)
	# Lethal damage wrecks the car but keeps it owned at 0 HP (repairable), not deleted.
	assert_eq(_save.profile["cars"].size(), 1, "the wrecked car is kept in the garage")
	assert_eq(float(_save.get_car(car["instance_id"])["hp"]), 0.0, "wrecked at 0 HP")


func test_consume_item_respects_counts() -> void:
	_save.add_item("repair_kit", 2)
	assert_true(_save.consume_item("repair_kit", 1), "consume succeeds when stock available")
	assert_eq(int(_save.profile["inventory"]["repair_kit"]), 1, "count decremented")
	assert_false(_save.consume_item("repair_kit", 5), "consume fails when stock insufficient")
	assert_eq(int(_save.profile["inventory"]["repair_kit"]), 1, "failed consume leaves count untouched")


func test_migration_refuses_newer_version() -> void:
	var future: Dictionary = _save._default_profile()
	future["schema_version"] = _save.SCHEMA_VERSION + 1
	assert_true(_save._migrate(future).is_empty(), "a newer-version profile is refused (returns empty)")


func test_migration_backfills_missing_keys() -> void:
	# A correctly-versioned but partial dict gets missing keys filled from default.
	var partial := {"schema_version": _save.SCHEMA_VERSION, "cars": []}
	var migrated: Dictionary = _save._migrate(partial)
	assert_true(migrated.has("inventory"), "missing inventory backfilled")
	assert_true(migrated.has("rallies"), "missing rallies backfilled")
	assert_true(migrated.has("settings"), "missing settings bag backfilled (old profiles)")


func test_settings_get_set_round_trip() -> void:
	# Unset keys return the supplied default.
	assert_eq(_save.get_setting("mobile_control_scheme", 0), 0, "unset setting returns the default")
	_save.set_setting("mobile_control_scheme", 4)
	assert_eq(_save.get_setting("mobile_control_scheme", 0), 4, "a set setting reads back")
	# Persists across a save/reload cycle.
	_save.save_now()
	_save.load_or_new()
	assert_eq(_save.get_setting("mobile_control_scheme", 0), 4, "settings survive save + reload")


func test_corrupt_json_falls_back_to_default() -> void:
	var f := FileAccess.open(TEST_PATH, FileAccess.WRITE)
	f.store_string("{ this is not valid json ]")
	f.close()
	_save.load_or_new()
	assert_eq(_save.profile["cars"].size(), 0, "garbage file -> fresh default profile")
	assert_eq(_save.profile["schema_version"], _save.SCHEMA_VERSION, "default schema after corruption")


func test_corrupt_primary_falls_back_to_bak() -> void:
	# A good .bak should be used when the primary file is unparseable.
	var good := FileAccess.open(TEST_PATH + ".bak", FileAccess.WRITE)
	good.store_string(JSON.stringify({"schema_version": _save.SCHEMA_VERSION, "cars": [],
		"inventory": {"flare": 3}}))
	good.close()
	var bad := FileAccess.open(TEST_PATH, FileAccess.WRITE)
	bad.store_string("garbage")
	bad.close()
	_save.load_or_new()
	assert_eq(int(_save.profile["inventory"].get("flare", 0)), 3, "recovered inventory from .bak")


func test_unknown_model_id_dropped_on_load() -> void:
	var f := FileAccess.open(TEST_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify({
		"schema_version": _save.SCHEMA_VERSION,
		"cars": [
			{"instance_id": 1, "model_id": "mx5", "hp": 800.0,
				"installed_upgrades": [], "tuning": {}},
			{"instance_id": 2, "model_id": "ghost_car", "hp": 1.0,
				"installed_upgrades": [], "tuning": {}},
		],
	}))
	f.close()
	_save.load_or_new()
	assert_eq(_save.profile["cars"].size(), 1, "orphaned car (unknown model) dropped")
	assert_eq(_save.profile["cars"][0]["model_id"], "mx5", "valid car kept")


func test_reset_new_game_overwrites_with_fresh_profile() -> void:
	_save.grant_car("mx5")
	_save.reset_new_game()
	assert_eq(_save.profile["cars"].size(), 0, "new game clears owned cars")
	assert_true(_save.has_save(), "new game written to disk immediately")
