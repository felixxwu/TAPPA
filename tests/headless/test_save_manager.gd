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
	for suffix in ["", ".bak", ".tmp", ".conflict.bak"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


func test_dev_three_star_all_rallies_completes_everything_and_finishes_the_game() -> void:
	# Dev cheat: every rally becomes completed + 3-starred (1st place). Regions no
	# longer unlock in sequence (todo/one-map-four-corners.md), so the end state to
	# assert is the one that now ends the game: every region's showdown completed,
	# which is what fires the credits. Treats the catalogues as opaque (no dependency
	# on any entry).
	_save.dev_three_star_all_rallies()
	for rally in RallyLibrary.all():
		var rid := String(rally["id"])
		assert_true(_save.rally_completed(rid), "rally %s marked completed" % rid)
		assert_eq(_save.best_placement(rid), 1, "rally %s is 3-starred (1st place)" % rid)
	assert_true(RegionLibrary.all_showdowns_completed(_save.profile),
		"every region's showdown completed after 3-starring all rallies")


func test_default_profile_is_empty_and_valid() -> void:
	assert_false(_save.has_save(), "no file on disk yet -> has_save() false")
	assert_eq(_save.profile["schema_version"], _save.SCHEMA_VERSION, "default carries current schema")
	assert_eq(_save.profile["cars"].size(), 0, "no owned cars")
	assert_false(_save.profile["starter_picked"], "starter not yet picked")


func test_round_trip_survives_save_and_reload() -> void:
	var car: Dictionary = _save.grant_car("fx_light_rwd")
	_save.add_item(UpgradeLibrary.MYSTERY_BOX_ID, 2)
	_save.complete_rally("alpine", 123456)
	_save.set_tuning(car["instance_id"], {"brake_bias": 0.55})
	_save.save_now()
	assert_true(_save.has_save(), "file written to disk")

	# Wipe in-memory state, reload from disk, assert it came back intact.
	_save.profile = {}
	_save.load_or_new()
	assert_eq(_save.profile["cars"].size(), 1, "owned car reloaded")
	assert_eq(_save.profile["cars"][0]["model_id"], "fx_light_rwd", "model id reloaded")
	assert_eq(int(_save.profile["inventory"][UpgradeLibrary.MYSTERY_BOX_ID]), 2, "inventory reloaded")
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
	assert_false(_save.set_upgrade_enabled(id, "fx_aero", true), "toggling an unapplied part is rejected")


func test_install_rejects_consumables_and_unknown_items() -> void:
	var car: Dictionary = _save.grant_car("fx_light_rwd")
	_save.add_item(UpgradeLibrary.ENGINE_SWAP_TOKEN_ID, 1)
	assert_false(_save.install_upgrade(car["instance_id"], UpgradeLibrary.ENGINE_SWAP_TOKEN_ID),
		"a consumable can't be slotted")
	assert_false(_save.install_upgrade(car["instance_id"], "bogus"), "unknown item can't be installed")
	assert_eq(int(_save.profile["inventory"][UpgradeLibrary.ENGINE_SWAP_TOKEN_ID]), 1,
		"rejected install leaves inventory intact")


func test_damage_is_one_way_apart_from_the_field_repair() -> void:
	# There is no full restore any more (repair kits are gone), so HP only ever climbs
	# back through the free between-event field repair — and never past max.
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")
	var id := int(car["instance_id"])
	var max_hp := float(CarLibrary.by_id("fx_rwd_coupe")["max_hp"])
	_save.apply_damage(id, 500.0)
	var damaged := float(_save.get_car(id)["hp"])
	assert_lt(damaged, max_hp, "the car took damage")
	_save.field_repair(id, 0.5, 1.0)
	var patched := float(_save.get_car(id)["hp"])
	assert_gt(patched, damaged, "the field repair claws some HP back")
	assert_lt(patched, max_hp, "but a partial repair never reaches full health")


func test_wheel_toe_persists_and_survives_reload() -> void:
	var car: Dictionary = _save.grant_car("fx_light_rwd")
	var id: int = car["instance_id"]
	assert_eq(_save.get_car(id)["wheel_toe"], [0.0, 0.0, 0.0, 0.0], "a fresh car has straight wheels")
	_save.set_wheel_toe(id, [0.01, -0.02, 0.03, -0.04])
	_save.save_now()
	_save.profile = {}
	_save.load_or_new()
	assert_eq(_save.get_car(id)["wheel_toe"], [0.01, -0.02, 0.03, -0.04], "bent wheels reloaded from disk")


func test_field_repair_straightens_wheels_fully_at_full_fraction() -> void:
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")
	var id: int = car["instance_id"]
	_save.apply_damage(id, 100.0)  # the field repair only acts on a car that needs it
	_save.set_wheel_toe(id, [0.05, -0.05, 0.05, -0.05])
	_save.field_repair(id, 0.5, 1.0)  # toe_fraction 1.0 = bend all the way back
	assert_eq(_save.get_car(id)["wheel_toe"], [0.0, 0.0, 0.0, 0.0],
		"a full-fraction repair straightens the wheels")


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


func test_sanitise_drops_parts_retired_from_the_catalogue() -> void:
	# A part removed from UpgradeLibrary leaves stale ids on old saves; load must
	# prune them from both lists so the id can't occupy a phantom slot in the menu.
	_save.profile["cars"] = [{
		"instance_id": 9, "model_id": "fx_light_rwd", "hp": 500.0,
		"installed_upgrades": ["fx_aero", "retired_part"],
		"disabled_upgrades": ["retired_part"], "tuning": {},
	}]
	_save.profile = _save._sanitise(_save.profile)
	var car: Dictionary = _save.profile["cars"][0]
	assert_eq(car["installed_upgrades"], ["fx_aero"], "the retired part is dropped, the real one kept")
	assert_eq(car["disabled_upgrades"], [], "the retired part is dropped from the toggles too")


func test_a_wrecked_car_can_never_be_revived() -> void:
	# Wrecking is TERMINAL now that repair kits are gone. The car is kept in the garage
	# but nothing restores it — not even the free field repair, which refuses a wreck.
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")
	var id := int(car["instance_id"])
	_save.apply_damage(id, 999999.0)  # wreck it -> 0 HP, still owned
	assert_true(_save.car_is_wrecked(_save.get_car(id)), "the car is wrecked")
	var summary: Dictionary = _save.field_repair(id, 1.0, 1.0)
	assert_false(bool(summary.get("repaired", false)), "the field repair will not touch a wreck")
	assert_true(_save.car_is_wrecked(_save.get_car(id)), "and it stays wrecked")


func test_starter_wrecks_like_any_car() -> void:
	# The starter is no longer invulnerable: lethal damage wrecks it (0 HP, still owned).
	var car: Dictionary = _save.grant_car("fx_light_rwd")
	_save.apply_damage(car["instance_id"], 999999.0)
	assert_eq(_save.profile["cars"].size(), 1, "the wrecked starter is kept in the garage")
	assert_true(_save.car_is_wrecked(_save.get_car(car["instance_id"])), "the starter can be wrecked")


func test_safety_net_grants_a_box_when_all_wrecked_and_none_held() -> void:
	var a: Dictionary = _save.grant_car("fx_light_rwd")
	var b: Dictionary = _save.grant_car("fx_rwd_coupe")
	_save.apply_damage(a["instance_id"], 999999.0)
	_save.apply_damage(b["instance_id"], 999999.0)
	assert_true(_save.all_cars_wrecked(), "every owned car is a write-off")
	assert_eq(_save.mystery_boxes_owned(), 0, "no box before the net fires")
	assert_true(_save.ensure_wreck_safety_net(), "a free box is granted when all cars are wrecked")
	assert_eq(_save.mystery_boxes_owned(), 1, "exactly one free box granted")
	# Idempotent: once a box is held, the net does not keep topping up.
	assert_false(_save.ensure_wreck_safety_net(), "no second box while one is already held")
	assert_eq(_save.mystery_boxes_owned(), 1, "still just the one box")


func test_safety_net_no_op_when_a_car_is_healthy() -> void:
	var a: Dictionary = _save.grant_car("fx_light_rwd")
	_save.grant_car("fx_rwd_coupe")  # healthy
	_save.apply_damage(a["instance_id"], 999999.0)  # only one wrecked
	assert_false(_save.all_cars_wrecked(), "one car can still race")
	assert_false(_save.ensure_wreck_safety_net(), "not stranded: at least one car can still race")
	assert_eq(_save.mystery_boxes_owned(), 0, "no free box granted")


func test_safety_net_no_op_with_no_cars() -> void:
	assert_false(_save.all_cars_wrecked(), "owning no cars is not the wrecked-out case")
	assert_false(_save.ensure_wreck_safety_net(), "owning no cars is not the wrecked-out case")
	assert_eq(_save.mystery_boxes_owned(), 0, "no free box granted")


func test_apply_damage_wrecks_mortal_car_at_zero() -> void:
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")  # mortal
	_save.apply_damage(car["instance_id"], 999999.0)
	# Lethal damage wrecks the car but keeps it owned at 0 HP (repairable), not deleted.
	assert_eq(_save.profile["cars"].size(), 1, "the wrecked car is kept in the garage")
	assert_eq(float(_save.get_car(car["instance_id"])["hp"]), 0.0, "wrecked at 0 HP")


func test_consume_item_respects_counts() -> void:
	var item := UpgradeLibrary.ENGINE_SWAP_TOKEN_ID
	_save.add_item(item, 2)
	assert_true(_save.consume_item(item, 1), "consume succeeds when stock available")
	assert_eq(int(_save.profile["inventory"][item]), 1, "count decremented")
	assert_false(_save.consume_item(item, 5), "consume fails when stock insufficient")
	assert_eq(int(_save.profile["inventory"][item]), 1, "failed consume leaves count untouched")


# Every non-consumable, non-free part in the real catalogue, up to MAX_TIER —
# derived from the live catalogue so a retune doesn't break the test. Mirrors
# test_reward_system.gd's _maxed_car (open_mystery_box's grant resolution goes
# through RewardSystem, which iterates the raw catalogue const, per that file's
# note — so this test stays against the real shipped UPGRADES table).
func _all_real_parts() -> Array:
	var parts := []
	for item in UpgradeLibrary.UPGRADES:
		if not item["consumable"] and not bool(item.get("free", false)):
			parts.append(String(item["id"]))
	return parts


func test_open_mystery_box_installs_a_disabled_part_on_a_car_with_room() -> void:
	# Install_upgrade's slot_of()/is_consumable() lookups ARE override-aware, but
	# RewardSystem.pick_mystery_box_grant iterates the raw UpgradeLibrary.UPGRADES
	# const (same caveat test_reward_system.gd documents for draw_upgrade) — so
	# with UpgradeFixtures installed (this file's shared before_each), the grant
	# resolves to a REAL id that the overridden slot_of() doesn't recognise,
	# spuriously falling back. Use the real catalogue for this test.
	UpgradeFixtures.restore()
	var maxed: Dictionary = _save.grant_car("fx_light_rwd")
	maxed["installed_upgrades"] = _all_real_parts()
	var other: Dictionary = _save.grant_car("fx_awd")
	_save.add_item(UpgradeLibrary.MYSTERY_BOX_ID, 1)
	var result: Dictionary = _save.open_mystery_box(_rng(1))
	assert_false(bool(result.get("car", false)), "nobody is wrecked, so this is a part grant")
	assert_eq(int(result["recipient_instance_id"]), int(other["instance_id"]),
		"the gift lands on the car with room, not the maxed one")
	var recipient: Dictionary = _save.get_car(int(other["instance_id"]))
	assert_true((recipient["installed_upgrades"] as Array).has(result["item_id"]),
		"the resolved item is fitted to the recipient")
	assert_false((recipient["disabled_upgrades"] as Array).is_empty(),
		"the gifted part installs DISABLED, same as any other per-event reward")
	assert_eq(_save.mystery_boxes_owned(), 0, "the box is consumed")


func test_open_mystery_box_keeps_the_box_when_no_car_has_room() -> void:
	# There is no consolation prize left to fall back on (repair kits are gone), so a
	# box with nowhere to land is NOT spent — the garage row shows it disabled instead.
	UpgradeFixtures.restore()  # see comment in the test above
	var maxed: Dictionary = _save.grant_car("fx_light_rwd")
	maxed["installed_upgrades"] = _all_real_parts()
	var also_maxed: Dictionary = _save.grant_car("fx_awd")
	also_maxed["installed_upgrades"] = _all_real_parts()
	_save.add_item(UpgradeLibrary.MYSTERY_BOX_ID, 1)
	var result: Dictionary = _save.open_mystery_box(_rng(1))
	assert_true(result.is_empty(), "nothing could be granted, so nothing is reported")
	assert_eq(_save.mystery_boxes_owned(), 1, "and the box is NOT spent")


func test_open_mystery_box_grants_a_car_when_every_car_is_wrecked() -> void:
	# The anti-soft-lock rescue. A part fitted to a wreck would be worthless, so a
	# wrecked-out garage gets a whole new car instead — checked ahead of the part grant.
	UpgradeFixtures.restore()  # see comment in the test above
	var a: Dictionary = _save.grant_car("fx_light_rwd")
	var b: Dictionary = _save.grant_car("fx_awd")
	_save.apply_damage(int(a["instance_id"]), 999999.0)
	_save.apply_damage(int(b["instance_id"]), 999999.0)
	assert_true(_save.all_cars_wrecked(), "setup: wrecked out")
	var owned_before: int = (_save.profile["cars"] as Array).size()
	_save.add_item(UpgradeLibrary.MYSTERY_BOX_ID, 1)
	var result: Dictionary = _save.open_mystery_box(_rng(1))
	assert_true(bool(result["car"]), "the box paid a car, not a part")
	assert_eq((_save.profile["cars"] as Array).size(), owned_before + 1, "a new car joined the garage")
	var granted: Dictionary = _save.get_car(int(result["recipient_instance_id"]))
	assert_false(granted.is_empty(), "the reported recipient is the newly granted car")
	assert_false(_save.car_is_wrecked(granted), "and it arrives raceable, not wrecked")
	assert_false(_save.all_cars_wrecked(), "so the player is no longer soft-locked")
	assert_eq(_save.mystery_boxes_owned(), 0, "the box is consumed")


func test_the_wreck_box_scales_its_replacement_to_what_was_lost() -> void:
	# The box sizes its payout one rung BELOW the best car the player wrecked, rather
	# than always paying out at the bottom of the ladder (which handed a late-game
	# player a starter car). Relation only — no authored tier or model id is pinned.
	UpgradeFixtures.restore()
	var by_tier := {}
	for entry in CarLibrary.all():
		by_tier[int(entry.get("reward_tier", 0))] = String(entry["id"])
	var tiers: Array = by_tier.keys()
	tiers.sort()
	if tiers.size() < 3:
		return  # fixture roster too shallow for "one rung below" to be observable
	var top_tier: int = tiers[tiers.size() - 1]
	var wrecked: Dictionary = _save.grant_car(String(by_tier[top_tier]))
	_save.apply_damage(int(wrecked["instance_id"]), 999999.0)
	assert_true(_save.all_cars_wrecked(), "setup: wrecked out holding the best car")
	# Enough completions that the earned ceiling cannot be what limits the draw.
	var rallies: Dictionary = _save.profile.get("rallies", {})
	for n in 12:
		rallies["done_%d" % n] = {"completed": true}
	_save.profile["rallies"] = rallies
	_save.add_item(UpgradeLibrary.MYSTERY_BOX_ID, 1)
	var result: Dictionary = _save.open_mystery_box(_rng(3))
	assert_true(bool(result["car"]), "the box paid a car")
	var granted_tier := int(CarLibrary.by_id(String(result["item_id"])).get("reward_tier", 0))
	assert_lt(granted_tier, top_tier,
		"the replacement sits below the tier that was wrecked (a consolation, not a swap)")
	assert_gt(granted_tier, 0, "but it is still a real car, never below the bottom tier")


# A ONE-CAR garage: the box now fits a part to the only car you own, instead of
# being permanently unopenable because there was no "other" car to gift.
func test_open_mystery_box_can_fit_a_part_to_your_only_car() -> void:
	UpgradeFixtures.restore()  # see comment in the test above
	var only: Dictionary = _save.grant_car("fx_light_rwd")
	_save.add_item(UpgradeLibrary.MYSTERY_BOX_ID, 1)
	var result: Dictionary = _save.open_mystery_box(_rng(1))
	assert_false(bool(result.get("car", false)),
		"your one car has empty slots, so a part is granted rather than a car")
	assert_eq(int(result["recipient_instance_id"]), int(only["instance_id"]),
		"the gift lands on the only car you own")
	var recipient: Dictionary = _save.get_car(int(only["instance_id"]))
	assert_true((recipient["installed_upgrades"] as Array).has(result["item_id"]),
		"the resolved item is fitted to it")
	assert_false((recipient["disabled_upgrades"] as Array).is_empty(),
		"and installs DISABLED, same as every other gifted part")


func test_open_mystery_box_returns_empty_when_none_held() -> void:
	_save.grant_car("fx_light_rwd")
	assert_eq(_save.mystery_boxes_owned(), 0, "setup: no box held")
	var result: Dictionary = _save.open_mystery_box()
	assert_true(result.is_empty(), "opening with none held is a no-op")


func _rng(seed_value: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed_value
	return r


func test_migration_refuses_newer_version() -> void:
	var future: Dictionary = _save._default_profile()
	future["schema_version"] = _save.SCHEMA_VERSION + 1
	assert_true(_save._migrate(future).is_empty(), "a newer-version profile is refused (returns empty)")


func test_migration_v1_strips_the_unbound_inventory() -> void:
	# v1 -> v2: upgrades became car-bound, so the old shared pool of slottable parts is
	# dropped (they were never applied and have no car to belong to). The repair kits
	# that used to be preserved here go too — the item no longer exists.
	var v1: Dictionary = _save._default_profile()
	v1["schema_version"] = 1
	v1["inventory"] = {"fx_turbo_small": 2, "fx_aero": 1, "repair_kit": 3}
	var migrated: Dictionary = _save._migrate(v1)
	assert_eq(int(migrated["schema_version"]), _save.SCHEMA_VERSION, "migrated to current schema")
	var inv: Dictionary = migrated["inventory"]
	assert_false(inv.has("fx_turbo_small"), "unbound slottable part dropped")
	assert_false(inv.has("fx_aero"), "unbound slottable part dropped")
	assert_false(inv.has("repair_kit"), "the retired repair kit is dropped too")


func test_sanitise_drops_the_retired_repair_kit_from_an_existing_profile() -> void:
	# Cleaned up in the tolerant sanitise pass rather than a schema migration, so older
	# builds can still read the profile (no SCHEMA_VERSION bump).
	_save.profile["inventory"] = {"repair_kit": 4, UpgradeLibrary.MYSTERY_BOX_ID: 2}
	_save.profile = _save._sanitise(_save.profile)
	var inv: Dictionary = _save.profile["inventory"]
	assert_false(inv.has("repair_kit"), "the dead consumable is stripped on load")
	assert_eq(int(inv.get(UpgradeLibrary.MYSTERY_BOX_ID, 0)), 2, "live consumables are untouched")


func test_migration_backfills_missing_keys() -> void:
	# A correctly-versioned but partial dict gets missing keys filled from default.
	var partial := {"schema_version": _save.SCHEMA_VERSION, "cars": []}
	var migrated: Dictionary = _save._migrate(partial)
	assert_true(migrated.has("inventory"), "missing inventory backfilled")
	assert_true(migrated.has("rallies"), "missing rallies backfilled")
	assert_true(migrated.has("settings"), "missing settings bag backfilled (old profiles)")


func test_migration_backfills_username_on_an_older_profile() -> void:
	# username (global leaderboards, features/global-leaderboards.md) rides the same
	# key-backfill mechanism as cloud_revision/unsynced — no SCHEMA_VERSION bump, so
	# an older, correctly-versioned profile that predates the field simply gets "".
	var older := {"schema_version": _save.SCHEMA_VERSION, "cars": []}
	assert_false(older.has("username"), "fixture predates the field")
	var migrated: Dictionary = _save._migrate(older)
	assert_true(migrated.has("username"), "username backfilled")
	assert_eq(String(migrated["username"]), "", "backfilled default is empty")


func test_username_survives_save_and_reload() -> void:
	_save.profile["username"] = "KANGAROO"
	_save.save_now()
	_save.profile = {}
	_save.load_or_new()
	assert_eq(String(_save.profile["username"]), "KANGAROO", "username reloaded")


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


# --- Cloud-save bookkeeping ---------------------------------------------------
# The two fields the optional cloud layer keeps on the profile, and the entry
# points it uses. Tested here (not in the cloud tests) because they are part of
# Save's contract: they must behave correctly whether or not anyone is signed in.

func test_a_fresh_profile_has_never_synced() -> void:
	assert_eq(int(_save.profile["cloud_revision"]), 0)
	assert_false(_save.has_unsynced(), "a brand-new profile owes the cloud nothing")


func test_the_cloud_fields_are_backfilled_onto_an_older_profile() -> void:
	# Added without a SCHEMA_VERSION bump, so they must arrive via the key
	# backfill rather than requiring a migration step.
	var f := FileAccess.open(TEST_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify({"schema_version": _save.SCHEMA_VERSION, "cars": []}))
	f.close()
	_save.load_or_new()
	assert_true(_save.profile.has("cloud_revision"))
	assert_true(_save.profile.has("unsynced"))


func test_saving_marks_the_profile_unsynced() -> void:
	_save.mark_synced()
	assert_false(_save.has_unsynced())
	_save.save()
	assert_true(_save.has_unsynced(), "a local change is owed to the cloud")


func test_the_unsynced_flag_survives_a_restart() -> void:
	# Progress made offline must still be recognised as unsynced after a relaunch,
	# or the next pull would see "cloud ahead, local clean" and discard the session.
	_save.grant_car("fx_light_rwd")
	_save.save_now()
	_save.profile = {}
	_save.load_or_new()
	assert_true(_save.has_unsynced())


func test_marking_synced_writes_immediately() -> void:
	_save.save()
	_save.mark_synced()
	_save.profile = {}
	_save.load_or_new()
	assert_false(_save.has_unsynced(), "the cleared flag must be on disk, not just in memory")


func test_save_emits_profile_changed() -> void:
	watch_signals(_save)
	_save.save()
	assert_signal_emitted(_save, "profile_changed")


func test_blocked_storage_still_notifies_the_cloud() -> void:
	# Blocked local storage (private browsing, read-only fs) is exactly when a
	# cloud copy matters most, so it must not also switch off cloud sync.
	_save.save_disabled = true
	watch_signals(_save)
	_save.save()
	assert_signal_emitted(_save, "profile_changed")


func test_flush_and_sync_emits_flushed() -> void:
	watch_signals(_save)
	_save.flush_and_sync()
	assert_signal_emitted(_save, "flushed")


func test_adopting_a_profile_runs_it_through_the_shared_load_path() -> void:
	# A downloaded profile gets the same pruning a local file does — one
	# validation path, so cloud data can never be less checked than disk data.
	var incoming: Dictionary = _save._default_profile()
	incoming["starter_picked"] = true
	incoming["cars"] = [{"instance_id": 1, "model_id": "a_model_that_does_not_exist", "hp": 50}]
	assert_true(_save.adopt_profile(incoming))
	assert_true(_save.profile["starter_picked"])
	assert_eq((_save.profile["cars"] as Array).size(), 0, "unknown models are pruned as on load")


func test_adopting_a_newer_profile_is_refused_and_changes_nothing() -> void:
	_save.profile["starter_model_id"] = "keep_me"
	var incoming: Dictionary = _save._default_profile()
	incoming["schema_version"] = _save.SCHEMA_VERSION + 1
	assert_false(_save.adopt_profile(incoming))
	assert_eq(_save.profile["starter_model_id"], "keep_me",
		"a profile we cannot read must not replace one we can")


func test_the_conflict_backup_is_separate_from_the_rolling_bak() -> void:
	# The ordinary .bak is consumed by the very next write; a conflict backup has
	# to outlive that to be worth anything.
	_save.profile["starter_model_id"] = "replaced"
	_save.write_conflict_backup()
	_save.save_now()
	_save.save_now()
	assert_true(FileAccess.file_exists(TEST_PATH + ".conflict.bak"))


func test_adopting_a_profile_keeps_this_devices_settings() -> void:
	# Settings describe the hardware in the player's hands (touch scheme, frame
	# cap, key bindings), so a profile downloaded from another device must not
	# bring its settings with it.
	_save.set_setting("probe_setting", "this_device")
	var incoming: Dictionary = _save._default_profile()
	incoming["settings"] = {"probe_setting": "other_device"}
	assert_true(_save.adopt_profile(incoming))
	assert_eq(_save.get_setting("probe_setting", ""), "this_device")


# --- New-rally reveal acknowledgement ----------------------------------------

func test_marking_a_rally_revealed_survives_a_save_and_load() -> void:
	assert_false(_save.rally_revealed_seen("some_rally"),
		"a rally nobody has been shown reads as not yet revealed")
	_save.mark_rally_revealed("some_rally")
	_save.save_now()     # the ordinary save() is debounced; force the write
	_save.load_or_new()  # re-read the file from disk
	assert_true(_save.rally_revealed_seen("some_rally"),
		"the acknowledgement round-trips through a save + load")


func test_marking_a_rally_revealed_keeps_its_other_state() -> void:
	# The flag lives in the SAME per-rally record as `completed`, so writing one must
	# not clobber the other in either order.
	_save.complete_rally("some_rally", 60_000, 1)
	_save.mark_rally_revealed("some_rally")
	assert_true(_save.rally_completed("some_rally"), "the completion is still there")
	assert_eq(_save.best_placement("some_rally"), 1, "the best placement is still there")
	assert_true(_save.rally_revealed_seen("some_rally"))


func test_a_progressed_profile_with_no_reveal_flags_wants_seeding() -> void:
	# THE BACKFILL TRAP: a save written before the reveal feature existed carries no
	# flags at all, and treating that as "nothing revealed yet" would parade every open
	# rally at a player who has been looking at them for weeks.
	assert_false(_save.needs_reveal_seeding(), "a brand-new career has nothing to backfill")
	_save.complete_rally("some_rally", 60_000, 1)
	assert_true(_save.needs_reveal_seeding(),
		"career progress with not one reveal flag is a pre-feature save")
	_save.mark_rally_revealed("some_rally")
	assert_false(_save.needs_reveal_seeding(),
		"once any flag exists the profile has been through the seeding")


# FINDING 1: the backfill used to be a call site living in hq.gd (_seed_reveals_if_needed),
# invoked from two places (_enter_table, _on_cloud_profile_replaced) — a third path that
# reaches the map or replaces the profile could silently forget it. It now lives INSIDE
# Save, run at the points a profile actually becomes live, so it cannot be skipped by a
# future entry point. These tests exercise that directly through load_or_new/adopt_profile
# rather than through hq.gd at all.
func test_load_or_new_seeds_an_existing_career_with_no_reveal_flags() -> void:
	RallyLibrary.override_for_test([
		{"id": "sm_open", "name": "Save Open", "region": "home", "difficulty": 1,
			"showdown": false, "reveal_after": 0, "restriction": {}, "events": []},
		{"id": "sm_locked", "name": "Save Locked", "region": "home", "difficulty": 2,
			"showdown": false, "reveal_after": 99, "restriction": {}, "events": []},
	])
	_save.complete_rally("sm_open", 60_000, 1)  # career progress, but no reveal flags at all
	assert_true(_save.needs_reveal_seeding())
	_save.save_now()

	_save.load_or_new()  # the profile becoming live is what must trigger the backfill

	assert_true(_save.rally_revealed_seen("sm_open"),
		"an already-open (and completed) rally is seeded as seen on load, no parade")
	assert_false(_save.rally_revealed_seen("sm_locked"),
		"a rally that never unlocked is not seeded — it still gets a real reveal later")
	assert_false(_save.needs_reveal_seeding(), "the profile now carries reveal flags")
	RallyLibrary.reset()


func test_adopt_profile_seeds_a_restored_career_with_no_reveal_flags() -> void:
	# A cloud restore onto a fresh device must not parade the whole roster either —
	# same backfill, reached through the OTHER point a profile becomes live.
	RallyLibrary.override_for_test([
		{"id": "sm_open", "name": "Save Open", "region": "home", "difficulty": 1,
			"showdown": false, "reveal_after": 0, "restriction": {}, "events": []},
	])
	var incoming: Dictionary = _save._default_profile()
	incoming["rallies"] = {"sm_open": {"completed": true, "best_combined_ms": 1, "best_placed": 1}}
	assert_true(_save.adopt_profile(incoming))
	assert_true(_save.rally_revealed_seen("sm_open"),
		"a restored career's already-open rally is seeded as seen, not paraded")
	RallyLibrary.reset()
