extends GutTest
# The Save autoload (player profile / persistence). Exercises the round-trip,
# default profile, migration, integrity fallbacks, and wreck semantics described
# in todo/save-persistence.md. Runs against a throwaway user:// file so a real
# profile is never touched.

const TEST_PATH := "user://test_profile.json"
const CarFixtures = preload("res://tests/headless/car_fixtures.gd")
const UpgradeFixtures = preload("res://tests/headless/upgrade_fixtures.gd")

var _save: Node


func before_each() -> void:
	_save = get_node("/root/Save")
	CarFixtures.install()
	UpgradeFixtures.install()
	_clean()
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.load_or_new()  # fresh default against the test path


func after_each() -> void:
	_clean()
	# Restore the real path so we don't leak the test redirect into other files.
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	CarFixtures.restore()
	UpgradeFixtures.restore()


func _clean() -> void:
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


func test_dev_three_star_all_rallies_completes_everything_and_unlocks_regions() -> void:
	# Dev cheat: every rally becomes completed + 3-starred (1st place), and — since
	# region unlock is derived from each region's showdown completion — every region
	# ends up unlocked. Treats the catalogues as opaque (no dependency on any entry).
	_save.dev_three_star_all_rallies()
	for rally in RallyLibrary.all():
		var rid := String(rally["id"])
		assert_true(_save.rally_completed(rid), "rally %s marked completed" % rid)
		assert_eq(_save.best_placement(rid), 1, "rally %s is 3-starred (1st place)" % rid)
	for region in RegionLibrary.all():
		var region_id := String(region["id"])
		assert_true(RegionLibrary.unlocked(region_id, _save.profile),
			"region %s unlocked after 3-starring all rallies" % region_id)


func test_default_profile_is_empty_and_valid() -> void:
	assert_false(_save.has_save(), "no file on disk yet -> has_save() false")
	assert_eq(_save.profile["schema_version"], _save.SCHEMA_VERSION, "default carries current schema")
	assert_eq(_save.profile["cars"].size(), 0, "no owned cars")
	assert_false(_save.profile["starter_picked"], "starter not yet picked")


func test_round_trip_survives_save_and_reload() -> void:
	var car: Dictionary = _save.grant_car("fx_light_rwd")
	_save.add_item("repair_kit", 2)
	_save.complete_rally("alpine", 123456)
	_save.set_tuning(car["instance_id"], {"brake_bias": 0.55})
	_save.save_now()
	assert_true(_save.has_save(), "file written to disk")

	# Wipe in-memory state, reload from disk, assert it came back intact.
	_save.profile = {}
	_save.load_or_new()
	assert_eq(_save.profile["cars"].size(), 1, "owned car reloaded")
	assert_eq(_save.profile["cars"][0]["model_id"], "fx_light_rwd", "model id reloaded")
	assert_eq(int(_save.profile["inventory"]["repair_kit"]), 2, "inventory reloaded")
	assert_true(_save.rally_completed("alpine"), "rally completion reloaded")
	assert_eq(int(_save.profile["rallies"]["alpine"]["best_combined_ms"]), 123456, "best time reloaded")
	assert_almost_eq(float(_save.profile["cars"][0]["tuning"]["brake_bias"]), 0.55, 0.001, "tuning reloaded")


func test_instance_ids_are_unique_per_grant() -> void:
	var a: Dictionary = _save.grant_car("fx_light_rwd")
	var b: Dictionary = _save.grant_car("fx_light_rwd")  # same model, must diverge
	assert_ne(a["instance_id"], b["instance_id"], "two instances of one model get distinct ids")
	assert_eq(_save.profile["cars"].size(), 2, "both instances owned")


func test_grant_car_seeds_hp_from_library_max() -> void:
	var car: Dictionary = _save.grant_car("fx_awd")
	assert_almost_eq(float(car["hp"]), float(CarLibrary.by_id("fx_awd")["max_hp"]), 0.001,
		"new car starts at the library max_hp")


func test_complete_rally_is_idempotent_and_keeps_best_time() -> void:
	_save.complete_rally("alpine", 5000)
	_save.complete_rally("alpine", 6000)  # slower: should not replace
	_save.complete_rally("alpine", 4000)  # faster: should replace
	assert_eq(_save.completed_rally_count(), 1, "completing the same rally twice counts once")
	assert_eq(int(_save.profile["rallies"]["alpine"]["best_combined_ms"]), 4000, "keeps the fastest time")


func test_wreck_keeps_car_at_zero_hp_with_upgrades() -> void:
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")
	# Upgrades are CAR-BOUND — install_upgrade fits the won part straight to the car
	# (no shared inventory pool for slottable parts).
	assert_true(_save.install_upgrade(car["instance_id"], "fx_turbo_small"), "upgrade installed")

	_save.wreck_car(car["instance_id"])
	# A wrecked car is NOT deleted — it stays owned at 0 HP, repairable with a kit.
	assert_eq(_save.profile["cars"].size(), 1, "the wrecked car is kept, not removed")
	assert_eq(float(_save.get_car(car["instance_id"])["hp"]), 0.0, "the wrecked car sits at 0 HP")
	assert_true(_save.car_is_wrecked(_save.get_car(car["instance_id"])), "and reads as wrecked")
	# Its upgrades ride along with the car (bound to it; never moved or returned).
	assert_true(_save.get_car(car["instance_id"])["installed_upgrades"].has("fx_turbo_small"),
		"the upgrade is still installed on the wrecked car")


func test_scrap_removes_car_consumes_upgrades_and_spares_last_car() -> void:
	var starter: Dictionary = _save.grant_car("fx_light_rwd")
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")
	assert_true(_save.install_upgrade(car["instance_id"], "fx_turbo_small"), "upgrade installed")

	# Scrapping a car removes it; its fitted upgrade is lost with it (bound to the
	# car, like a wreck — never refunded to a pool).
	assert_true(_save.scrap_car(car["instance_id"]), "scrapping a car succeeds while others remain")
	assert_eq(_save.profile["cars"].size(), 1, "scrapped car removed (only the starter remains)")
	assert_false(_save.profile["inventory"].has("fx_turbo_small"), "the bound upgrade is gone with the car")

	# The player's LAST car can never be scrapped (keeps ≥1 car so the repair-kit
	# safety net always has something to bring back).
	assert_false(_save.scrap_car(starter["instance_id"]), "the last owned car can't be scrapped")
	assert_eq(_save.profile["cars"].size(), 1, "the last car is still owned")
	# An unknown instance is a harmless no-op.
	assert_false(_save.scrap_car(99999), "scrapping an unknown instance is a no-op")


func test_install_disables_same_slot_incumbent() -> void:
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")
	assert_true(_save.install_upgrade(car["instance_id"], "fx_turbo_small"), "first engine kit fitted")
	# Applying a second engine upgrade keeps both on the car but switches the
	# incumbent off — at most one ENABLED part per slot.
	assert_true(_save.install_upgrade(car["instance_id"], "fx_turbo_big"), "second engine kit fitted")
	var fitted_car: Dictionary = _save.get_car(car["instance_id"])
	var fitted: Array = fitted_car["installed_upgrades"]
	assert_true(fitted.has("fx_turbo_small") and fitted.has("fx_turbo_big"),
		"both engine kits stay applied to the car")
	assert_true(UpgradeLibrary.is_enabled(fitted_car, "fx_turbo_big"), "the newly-applied kit is enabled")
	assert_false(UpgradeLibrary.is_enabled(fitted_car, "fx_turbo_small"),
		"the same-slot incumbent is disabled, not scrapped")


func test_install_disabled_parks_the_part_without_enabling() -> void:
	# The reward loop fits every won part disabled (enabled=false); the podium's
	# Apply enables the player's pick. A disabled fit lands parked, not live.
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")
	var id := int(car["instance_id"])
	assert_true(_save.install_upgrade(id, "fx_turbo_small", false), "part fitted disabled")
	var fitted_car: Dictionary = _save.get_car(id)
	assert_true((fitted_car["installed_upgrades"] as Array).has("fx_turbo_small"), "part is on the car")
	assert_false(UpgradeLibrary.is_enabled(fitted_car, "fx_turbo_small"), "but it is not enabled")
	# The podium Apply flow (set_upgrade_enabled true) turns it on.
	assert_true(_save.set_upgrade_enabled(id, "fx_turbo_small", true), "it can be enabled later")
	assert_true(UpgradeLibrary.is_enabled(_save.get_car(id), "fx_turbo_small"), "now live")


func test_install_rejects_a_part_already_on_the_car() -> void:
	# Per-car dedup: a car can never hold the same upgrade twice.
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")
	assert_true(_save.install_upgrade(car["instance_id"], "fx_turbo_small"), "first copy fitted")
	assert_false(_save.install_upgrade(car["instance_id"], "fx_turbo_small"),
		"a part already on the car can't be applied again")
	assert_eq((_save.get_car(car["instance_id"])["installed_upgrades"] as Array).count("fx_turbo_small"), 1,
		"the car still carries exactly one copy")


func test_same_part_fits_on_two_different_cars_independently() -> void:
	# Dedup is PER CAR — two different cars may each own their own copy of a part.
	var a: Dictionary = _save.grant_car("fx_rwd_coupe")
	var b: Dictionary = _save.grant_car("fx_light_rwd")
	assert_true(_save.install_upgrade(a["instance_id"], "fx_turbo_small"), "car A gets a copy")
	assert_true(_save.install_upgrade(b["instance_id"], "fx_turbo_small"), "car B gets its own copy")
	assert_true((_save.get_car(a["instance_id"])["installed_upgrades"] as Array).has("fx_turbo_small"),
		"car A carries it")
	assert_true((_save.get_car(b["instance_id"])["installed_upgrades"] as Array).has("fx_turbo_small"),
		"car B carries it")


func test_toggle_upgrade_enabled_is_exclusive_per_slot() -> void:
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")
	var id := int(car["instance_id"])
	_save.install_upgrade(id, "fx_turbo_small")
	_save.install_upgrade(id, "fx_turbo_big")
	# Disabling the enabled part leaves the slot with nothing live.
	assert_true(_save.set_upgrade_enabled(id, "fx_turbo_big", false), "the enabled part can be disabled")
	assert_false(UpgradeLibrary.is_enabled(_save.get_car(id), "fx_turbo_big"), "the part is now off")
	# Re-enabling the older part works, and enabling its sibling swaps them.
	assert_true(_save.set_upgrade_enabled(id, "fx_turbo_small", true), "a parked part can be re-enabled")
	assert_true(_save.set_upgrade_enabled(id, "fx_turbo_big", true), "enabling the sibling succeeds")
	var fitted_car: Dictionary = _save.get_car(id)
	assert_true(UpgradeLibrary.is_enabled(fitted_car, "fx_turbo_big"), "the sibling is enabled")
	assert_false(UpgradeLibrary.is_enabled(fitted_car, "fx_turbo_small"),
		"enabling one part disables the same-slot other")
	# A part that isn't on the car can't be toggled.
	assert_false(_save.set_upgrade_enabled(id, "fx_brakes", true), "toggling an unapplied part is rejected")


func test_install_rejects_consumables_and_unknown_items() -> void:
	var car: Dictionary = _save.grant_car("fx_light_rwd")
	_save.add_item("repair_kit", 1)
	assert_false(_save.install_upgrade(car["instance_id"], "repair_kit"), "repair kit can't be slotted")
	assert_false(_save.install_upgrade(car["instance_id"], "bogus"), "unknown item can't be installed")
	assert_eq(int(_save.profile["inventory"]["repair_kit"]), 1, "rejected install leaves inventory intact")


func test_repair_kit_restores_to_full() -> void:
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")
	var max_hp := float(CarLibrary.by_id("fx_rwd_coupe")["max_hp"])
	_save.apply_damage(car["instance_id"], 500.0)  # 500 hp
	_save.add_item("repair_kit", 2)
	assert_true(_save.use_repair_kit(car["instance_id"]), "repair kit consumed")
	# A kit fully restores the car, not a partial heal.
	assert_almost_eq(float(_save.get_car(car["instance_id"])["hp"]), max_hp, 0.001, "restored to full health")
	assert_eq(int(_save.profile["inventory"]["repair_kit"]), 1, "one kit consumed")
	assert_false(_save.use_repair_kit(car["instance_id"] + 999), "no kit spent on an unknown car")


func test_wheel_toe_persists_and_survives_reload() -> void:
	var car: Dictionary = _save.grant_car("fx_light_rwd")
	var id: int = car["instance_id"]
	assert_eq(_save.get_car(id)["wheel_toe"], [0.0, 0.0, 0.0, 0.0], "a fresh car has straight wheels")
	_save.set_wheel_toe(id, [0.01, -0.02, 0.03, -0.04])
	_save.save_now()
	_save.profile = {}
	_save.load_or_new()
	assert_eq(_save.get_car(id)["wheel_toe"], [0.01, -0.02, 0.03, -0.04], "bent wheels reloaded from disk")


func test_repair_kit_straightens_wheels() -> void:
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")
	var id: int = car["instance_id"]
	_save.set_wheel_toe(id, [0.05, -0.05, 0.05, -0.05])
	_save.add_item("repair_kit", 1)
	assert_true(_save.use_repair_kit(id), "repair kit consumed")
	assert_eq(_save.get_car(id)["wheel_toe"], [0.0, 0.0, 0.0, 0.0], "a repair straightens the wheels")


func test_field_repair_restores_the_given_fraction_of_lost_hp() -> void:
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")
	var id: int = car["instance_id"]
	var max_hp := float(CarLibrary.by_id("fx_rwd_coupe")["max_hp"])
	_save.apply_damage(id, 400.0)  # lost 400
	var before := float(_save.get_car(id)["hp"])
	var summary: Dictionary = _save.field_repair(id, 0.5, 0.5)
	assert_true(summary.get("repaired", false), "a damaged car is repaired")
	# Restores hp_fraction (0.5) of the 400 lost -> +200, for ANY reasonable fraction.
	assert_almost_eq(float(_save.get_car(id)["hp"]), before + 200.0, 0.001, "half the lost hp came back")
	assert_almost_eq(float(summary["hp_gained"]), 200.0, 0.001, "summary reports the hp gained")
	assert_lt(float(_save.get_car(id)["hp"]), max_hp, "a partial repair does not reach full health")


func test_field_repair_bends_each_wheel_back_toward_straight() -> void:
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")
	var id: int = car["instance_id"]
	_save.apply_damage(id, 100.0)  # some hp lost so the repair runs
	_save.set_wheel_toe(id, [0.08, -0.06, 0.04, -0.02])
	_save.field_repair(id, 0.2, 0.5)  # bend each wheel 50% back toward zero
	var toe: Array = _save.get_car(id)["wheel_toe"]
	# Each wheel moves toward straight by toe_fraction, keeping its sign — for ANY fraction.
	for i in 4:
		assert_almost_eq(float(toe[i]), [0.08, -0.06, 0.04, -0.02][i] * 0.5, 0.0001, "wheel %d bent halfway back" % i)


func test_field_repair_skips_a_pristine_car() -> void:
	var car: Dictionary = _save.grant_car("fx_light_rwd")  # full hp, straight wheels
	var summary: Dictionary = _save.field_repair(car["instance_id"], 0.2, 0.5)
	assert_false(summary.get("repaired", false), "nothing to repair on a spotless car")


func test_field_repair_leaves_a_wrecked_car_wrecked() -> void:
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")
	var id: int = car["instance_id"]
	_save.wreck_car(id)
	var summary: Dictionary = _save.field_repair(id, 0.2, 0.5)
	assert_false(summary.get("repaired", false), "a wrecked car is not field-repaired")
	assert_eq(float(_save.get_car(id)["hp"]), 0.0, "still wrecked")


func test_sanitise_backfills_wheel_toe_on_old_saves() -> void:
	# A pre-feature owned car has no wheel_toe key; load must backfill it straight.
	_save.profile["cars"] = [{
		"instance_id": 7, "model_id": "fx_light_rwd", "hp": 500.0,
		"installed_upgrades": [], "disabled_upgrades": [], "tuning": {},
	}]
	_save.profile = _save._sanitise(_save.profile)
	assert_eq(_save.profile["cars"][0]["wheel_toe"], [0.0, 0.0, 0.0, 0.0], "backfilled straight")


func test_repair_kit_revives_a_wrecked_car() -> void:
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")
	var id := int(car["instance_id"])
	var max_hp := float(CarLibrary.by_id("fx_rwd_coupe")["max_hp"])
	_save.apply_damage(id, 999999.0)  # wreck it -> 0 HP, still owned
	assert_true(_save.car_is_wrecked(_save.get_car(id)), "the car is wrecked")
	assert_false(_save.use_repair_kit(id), "can't repair without a kit")
	_save.add_item("repair_kit", 1)
	assert_true(_save.use_repair_kit(id), "a kit revives the wrecked car")
	assert_almost_eq(float(_save.get_car(id)["hp"]), max_hp, 0.001, "the revived car is at full health")
	assert_false(_save.car_is_wrecked(_save.get_car(id)), "and is no longer wrecked")


func test_starter_wrecks_like_any_car() -> void:
	# The starter is no longer invulnerable: lethal damage wrecks it (0 HP, still owned).
	var car: Dictionary = _save.grant_car("fx_light_rwd")
	_save.apply_damage(car["instance_id"], 999999.0)
	assert_eq(_save.profile["cars"].size(), 1, "the wrecked starter is kept in the garage")
	assert_true(_save.car_is_wrecked(_save.get_car(car["instance_id"])), "the starter can be wrecked")


func test_safety_net_grants_kit_when_all_wrecked_and_none_held() -> void:
	var a: Dictionary = _save.grant_car("fx_light_rwd")
	var b: Dictionary = _save.grant_car("fx_rwd_coupe")
	_save.apply_damage(a["instance_id"], 999999.0)
	_save.apply_damage(b["instance_id"], 999999.0)
	assert_eq(int(_save.profile["inventory"].get("repair_kit", 0)), 0, "no kit before the net fires")
	assert_true(_save.ensure_repair_safety_net(), "a free kit is granted when all cars are wrecked")
	assert_eq(int(_save.profile["inventory"].get("repair_kit", 0)), 1, "exactly one free kit granted")
	# Idempotent: once a kit is held, the net does not keep topping up.
	assert_false(_save.ensure_repair_safety_net(), "no second kit while one is already held")
	assert_eq(int(_save.profile["inventory"].get("repair_kit", 0)), 1, "still just the one kit")


func test_safety_net_no_op_when_a_car_is_healthy() -> void:
	var a: Dictionary = _save.grant_car("fx_light_rwd")
	_save.grant_car("fx_rwd_coupe")  # healthy
	_save.apply_damage(a["instance_id"], 999999.0)  # only one wrecked
	assert_false(_save.ensure_repair_safety_net(), "not stranded: at least one car can still race")
	assert_eq(int(_save.profile["inventory"].get("repair_kit", 0)), 0, "no free kit granted")


func test_safety_net_no_op_with_no_cars() -> void:
	assert_false(_save.ensure_repair_safety_net(), "owning no cars is not the wrecked-out case")
	assert_eq(int(_save.profile["inventory"].get("repair_kit", 0)), 0, "no free kit granted")


func test_apply_damage_wrecks_mortal_car_at_zero() -> void:
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")  # mortal
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


func test_migration_v1_strips_unbound_slottable_parts_keeps_repair_kits() -> void:
	# v1 -> v2: upgrades became car-bound; the old shared pool of slottable parts
	# is dropped (they were never applied and have no car to belong to), but repair
	# kits (the one consumable) stay pooled.
	var v1: Dictionary = _save._default_profile()
	v1["schema_version"] = 1
	v1["inventory"] = {"fx_turbo_small": 2, "fx_brakes": 1, UpgradeLibrary.REPAIR_KIT_ID: 3}
	var migrated: Dictionary = _save._migrate(v1)
	assert_eq(int(migrated["schema_version"]), _save.SCHEMA_VERSION, "migrated to current schema")
	var inv: Dictionary = migrated["inventory"]
	assert_false(inv.has("fx_turbo_small"), "unbound slottable part dropped")
	assert_false(inv.has("fx_brakes"), "unbound slottable part dropped")
	assert_eq(int(inv.get(UpgradeLibrary.REPAIR_KIT_ID, 0)), 3, "repair kits preserved")


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
			{"instance_id": 1, "model_id": "fx_light_rwd", "hp": 800.0,
				"installed_upgrades": [], "tuning": {}},
			{"instance_id": 2, "model_id": "ghost_car", "hp": 1.0,
				"installed_upgrades": [], "tuning": {}},
		],
	}))
	f.close()
	_save.load_or_new()
	assert_eq(_save.profile["cars"].size(), 1, "orphaned car (unknown model) dropped")
	assert_eq(_save.profile["cars"][0]["model_id"], "fx_light_rwd", "valid car kept")


func test_reset_new_game_overwrites_with_fresh_profile() -> void:
	_save.grant_car("fx_light_rwd")
	_save.reset_new_game()
	assert_eq(_save.profile["cars"].size(), 0, "new game clears owned cars")
	assert_true(_save.has_save(), "new game written to disk immediately")


func test_swap_engines_exchanges_current_engines() -> void:
	var a: Dictionary = _save.grant_car("fx_light_rwd")
	var b: Dictionary = _save.grant_car("fx_rwd_coupe")
	var stock_a: String = CarLibrary.by_id("fx_light_rwd")["engine"]
	var stock_b: String = CarLibrary.by_id("fx_rwd_coupe")["engine"]
	_save.add_item(UpgradeLibrary.ENGINE_SWAP_TOKEN_ID, 1)
	assert_true(_save.swap_engines(a["instance_id"], b["instance_id"]), "swap with a token succeeds")
	# Re-fetch (grant_car returns a live ref, but re-read to be explicit).
	a = _save.get_car(a["instance_id"])
	b = _save.get_car(b["instance_id"])
	assert_eq(String(a.get("swapped_engine", "")), stock_b, "Fixture Roadster now runs the Fixture Coupe engine")
	assert_eq(String(b.get("swapped_engine", "")), stock_a, "Fixture Coupe now runs the Fixture Roadster engine")
	assert_eq(_save.engine_swap_tokens_owned(), 0, "the swap spent the token")


func test_swap_with_identical_engines_is_a_noop_and_keeps_token() -> void:
	# Two instances of the same model run the same engine, so there is nothing to
	# exchange — the swap must be refused WITHOUT spending a token (a token is a
	# scarce reward; burning one on a no-op is a bug).
	var a: Dictionary = _save.grant_car("fx_light_rwd")
	var b: Dictionary = _save.grant_car("fx_light_rwd")
	_save.add_item(UpgradeLibrary.ENGINE_SWAP_TOKEN_ID, 1)
	assert_false(_save.swap_engines(a["instance_id"], b["instance_id"]),
		"swapping identical current engines is a no-op")
	assert_eq(_save.engine_swap_tokens_owned(), 1, "a no-op swap must not spend the token")


func test_swapping_back_restores_stock_and_clears_field() -> void:
	var a: Dictionary = _save.grant_car("fx_light_rwd")
	var b: Dictionary = _save.grant_car("fx_rwd_coupe")
	_save.add_item(UpgradeLibrary.ENGINE_SWAP_TOKEN_ID, 2)  # each swap costs one, incl. the revert
	_save.swap_engines(a["instance_id"], b["instance_id"])
	_save.swap_engines(a["instance_id"], b["instance_id"])  # swap back
	a = _save.get_car(a["instance_id"])
	b = _save.get_car(b["instance_id"])
	assert_eq(String(a.get("swapped_engine", "")), "", "Fixture Roadster back to stock -> field cleared")
	assert_eq(String(b.get("swapped_engine", "")), "", "Fixture Coupe back to stock -> field cleared")
	assert_eq(_save.engine_swap_tokens_owned(), 0, "reverting also spent a token (two swaps, two tokens)")


func test_swap_blocked_without_a_token() -> void:
	var a: Dictionary = _save.grant_car("fx_light_rwd")
	var b: Dictionary = _save.grant_car("fx_rwd_coupe")
	assert_eq(_save.engine_swap_tokens_owned(), 0, "no tokens to start")
	assert_false(_save.swap_engines(a["instance_id"], b["instance_id"]), "no token -> swap blocked")
	a = _save.get_car(a["instance_id"])
	assert_eq(String(a.get("swapped_engine", "")), "", "blocked swap leaves engines untouched")


func test_swap_succeeds_between_damaged_cars_with_a_token() -> void:
	var a: Dictionary = _save.grant_car("fx_light_rwd")
	var b: Dictionary = _save.grant_car("fx_rwd_coupe")
	_save.apply_damage(b["instance_id"], 1.0)  # b below max HP — no longer a blocker
	_save.add_item(UpgradeLibrary.ENGINE_SWAP_TOKEN_ID, 1)
	assert_true(_save.swap_engines(a["instance_id"], b["instance_id"]), "damaged car swaps fine with a token")
	b = _save.get_car(b["instance_id"])
	assert_lt(float(b.get("hp", 0.0)), float(CarLibrary.by_id("fx_rwd_coupe")["max_hp"]),
		"the swap did not repair the damaged car")


func test_set_engine_detune_clamps_and_persists() -> void:
	var a: Dictionary = _save.grant_car("fx_light_rwd")
	_save.set_engine_detune(a["instance_id"], 0.5)
	assert_almost_eq(float(_save.get_car(a["instance_id"])["tuning"]["engine_detune"]), 0.5, 0.0001, "stores fraction")
	_save.set_engine_detune(a["instance_id"], 1.7)
	assert_almost_eq(float(_save.get_car(a["instance_id"])["tuning"]["engine_detune"]), 1.0, 0.0001, "clamps above 1")
	_save.set_engine_detune(a["instance_id"], -0.3)
	assert_almost_eq(float(_save.get_car(a["instance_id"])["tuning"]["engine_detune"]), 0.0, 0.0001, "clamps below 0")


func test_set_drivetrain_override_persists() -> void:
	var car: Dictionary = _save.grant_car(CarLibrary.all()[0]["id"])
	var id := int(car["instance_id"])
	assert_eq(int(_save.get_car(id).get("drivetrain_override", -99)), -1, "new car defaults to stock (-1)")
	_save.set_drivetrain_override(id, CarLibrary.AWD)
	assert_eq(int(_save.get_car(id).get("drivetrain_override", -99)), CarLibrary.AWD, "override stored")


func test_drivetrain_override_defaults_for_legacy_car() -> void:
	# A car dict without the key (an older save) reads as stock via .get default.
	var legacy := {"instance_id": 1, "model_id": "x", "installed_upgrades": [], "disabled_upgrades": []}
	assert_eq(int(legacy.get("drivetrain_override", -1)), -1, "missing key reads as stock")


# --- Selected car promotes to the front of the lineup ------------------------

func test_selecting_a_car_promotes_it_to_front_and_shifts_others_down() -> void:
	# Grant three cars: they land in append order [a, b, c].
	var a: Dictionary = _save.grant_car("fx_light_rwd")
	var b: Dictionary = _save.grant_car("fx_rwd_coupe")
	var c: Dictionary = _save.grant_car("fx_awd")
	_save.set_selected_car(int(c["instance_id"]))
	var ids := _instance_ids()
	# c jumps to front; a and b keep their relative order, shifted down one.
	assert_eq(ids, [int(c["instance_id"]), int(a["instance_id"]), int(b["instance_id"])],
		"selected car promoted to front, others keep relative order")


func test_selecting_the_front_car_is_a_no_op() -> void:
	var a: Dictionary = _save.grant_car("fx_light_rwd")
	var b: Dictionary = _save.grant_car("fx_rwd_coupe")
	_save.set_selected_car(int(a["instance_id"]))  # a is already at index 0
	assert_eq(_instance_ids(), [int(a["instance_id"]), int(b["instance_id"])],
		"selecting the already-front car leaves order unchanged")


func test_selecting_an_unowned_id_does_not_corrupt_the_lineup() -> void:
	var a: Dictionary = _save.grant_car("fx_light_rwd")
	var b: Dictionary = _save.grant_car("fx_rwd_coupe")
	var before := _instance_ids()
	_save.set_selected_car(-1)  # no owned car matches
	assert_eq(_instance_ids(), before, "unowned/-1 selection leaves the array intact")


func test_promoted_order_survives_save_and_reload() -> void:
	var a: Dictionary = _save.grant_car("fx_light_rwd")
	_save.grant_car("fx_rwd_coupe")
	var c: Dictionary = _save.grant_car("fx_awd")
	_save.set_selected_car(int(c["instance_id"]))
	_save.save_now()
	_save.profile = {}
	_save.load_or_new()
	assert_eq(int(_save.profile["cars"][0]["instance_id"]), int(c["instance_id"]),
		"most recently selected car is first after reload")


func _instance_ids() -> Array:
	var ids := []
	for car in _save.profile.get("cars", []):
		ids.append(int(car["instance_id"]))
	return ids
