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
	# longer gate anything, so the end state to assert is the one that now ends the
	# game: every SPECIAL completed, which is what fires the credits. Treats the
	# catalogues as opaque (no dependency on any entry).
	_save.dev_three_star_all_rallies()
	for rally in RallyLibrary.all():
		var rid := String(rally["id"])
		assert_true(_save.rally_completed(rid), "rally %s marked completed" % rid)
		assert_eq(_save.best_placement(rid), 1, "rally %s is 3-starred (1st place)" % rid)
	assert_true(RallyLibrary.all_specials_completed(_save.profile),
		"every special completed after 3-starring all rallies")


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


func test_set_challenge_run_persists_and_survives_reload() -> void:
	# The three challenge-run methods (ChallengeSession's only writers of these
	# keys) go through the same save/reload path as every other domain.
	var run := {"period_key": "2026-W1", "kind": "weekly", "car_instance_id": 7,
		"stage_index": 1, "stage_times_ms": [1000], "dnf": false}
	_save.set_challenge_run(run)
	_save.save_now()
	_save.profile = {}
	_save.load_or_new()
	# Field-by-field with casts rather than a verbatim dict compare: the profile round-trips
	# through JSON, which has no integer type, so every int comes back as a float (7 -> 7.0).
	var back: Dictionary = _save.profile["challenge_run"]
	assert_eq(String(back["period_key"]), "2026-W1", "period key reloaded")
	assert_eq(String(back["kind"]), "weekly", "kind reloaded")
	assert_eq(int(back["car_instance_id"]), 7, "car instance id reloaded")
	assert_eq(int(back["stage_index"]), 1, "stage index reloaded")
	assert_eq(int((back["stage_times_ms"] as Array)[0]), 1000, "stage times reloaded")
	assert_false(bool(back["dnf"]), "dnf flag reloaded")


func test_clear_challenge_run_empties_the_key() -> void:
	_save.set_challenge_run({"period_key": "x", "kind": "daily"})
	_save.clear_challenge_run()
	assert_eq(_save.profile["challenge_run"], {}, "cleared back to empty")


func test_set_challenge_results_replaces_the_whole_map() -> void:
	_save.set_challenge_results({"2026-D1": {"kind": "daily", "dnf": false, "cumulative_ms": 500}})
	_save.save_now()
	_save.profile = {}
	_save.load_or_new()
	assert_eq(_save.profile["challenge_results"].keys(), ["2026-D1"], "the map round-trips")
	# A later call REPLACES rather than merges — this is how ChallengeSession's
	# own pruning (dropping rolled-over periods) actually takes effect.
	_save.set_challenge_results({"2026-D2": {"kind": "daily", "dnf": true, "cumulative_ms": 0}})
	assert_false(_save.profile["challenge_results"].has("2026-D1"), "the old entry is gone")
	assert_true(_save.profile["challenge_results"].has("2026-D2"), "replaced by the new map")


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


# --- Star ledger (todo/star-economy.md) --------------------------------------
# Stars are a persisted ledger, not a derived total. These assert the LEDGER RULES,
# never a particular star count for a particular placement — stars_for_placement is
# the single definition and is free to change.

func test_a_fresh_profile_has_an_empty_star_ledger() -> void:
	assert_eq(int(_save.profile["stars_earned"]), 0, "nothing earned yet")
	assert_eq(int(_save.profile["stars_spent"]), 0, "nothing spent yet")
	assert_eq(_save.stars_available(), 0, "nothing to spend")


func test_completing_a_rally_credits_the_placement_and_returns_it() -> void:
	var gained: int = _save.complete_rally("alpine", 60_000, 1)
	assert_eq(gained, RallyLibrary.stars_for_placement(1),
		"a first win credits what that placement is worth")
	assert_eq(_save.stars_available(), gained, "the balance reflects the credit")


func test_a_rally_can_be_rewon_for_stars() -> void:
	# Rallies are a RENEWABLE star source: replaying one pays for the finish again, every time.
	# (It used to credit only the improvement on the rally's best placement, so a replay at an
	# equal or worse placement paid nothing.)
	var first: int = _save.complete_rally("alpine", 60_000, 1)
	var again: int = _save.complete_rally("alpine", 61_000, 1)
	assert_gt(first, 0, "the original win pays")
	assert_eq(again, first, "re-winning at the same placement pays the same again")
	assert_eq(_save.stars_available(), first + again, "and both credits are in the balance")


func test_a_worse_replay_still_pays_for_what_it_placed() -> void:
	# The payout follows THIS run's placement, not the record — so a scrappier replay still
	# earns, just less if it dropped off the podium.
	_save.complete_rally("alpine", 60_000, 1)
	var before: int = _save.stars_available()
	var off_podium: int = _save.complete_rally("alpine", 90_000, RallyLibrary.PODIUM_PLACES + 1)
	assert_eq(off_podium, RallyLibrary.stars_for_placement(RallyLibrary.PODIUM_PLACES + 1),
		"a non-podium replay pays what finishing is worth")
	assert_eq(_save.stars_available(), before + off_podium, "the balance moved by that much")
	# The map rating still tracks the BEST placement — paying for a replay must not demote it.
	assert_eq(_save.best_placement("alpine"), 1, "the record is still the best finish")


func test_a_dnf_replay_pays_nothing() -> void:
	# The one case that must stay at zero: the opening rally can complete on a DNF, and a
	# ledger that paid for that would pay for quitting.
	_save.complete_rally("alpine", 60_000, 1)
	var before: int = _save.stars_available()
	var dnf: int = _save.complete_rally("alpine", 0, 0)
	assert_eq(dnf, 0, "a run that did not place credits nothing")
	assert_eq(_save.stars_available(), before, "the balance did not move")


func test_award_stars_credits_non_rally_sources() -> void:
	_save.award_stars(4)
	assert_eq(_save.stars_available(), 4, "a non-rally source credits the ledger")
	_save.award_stars(0)
	_save.award_stars(-5)
	assert_eq(_save.stars_available(), 4, "zero and negative awards are ignored")


func test_spending_debits_the_balance_and_refuses_when_short() -> void:
	_save.award_stars(10)
	assert_true(_save.spend_stars(4), "an affordable spend succeeds")
	assert_eq(_save.stars_available(), 6, "the balance dropped by the amount spent")
	assert_false(_save.spend_stars(7), "an unaffordable spend is refused")
	assert_eq(_save.stars_available(), 6, "a refused spend changes nothing")
	assert_false(_save.spend_stars(-1), "a negative spend is refused")
	assert_eq(_save.stars_available(), 6, "a negative spend changes nothing")


func test_earned_never_decreases_and_balance_never_goes_negative() -> void:
	_save.award_stars(6)
	_save.spend_stars(6)
	assert_eq(_save.stars_available(), 0, "spending everything leaves nothing")
	assert_eq(int(_save.profile["stars_earned"]), 6, "earned is a ledger, not a balance")
	assert_false(_save.spend_stars(1), "cannot spend past zero")
	assert_true(_save.stars_available() >= 0, "the balance is never negative")


func test_the_star_ledger_survives_a_save_and_reload() -> void:
	_save.complete_rally("alpine", 60_000, 1)
	_save.award_stars(3)
	_save.spend_stars(2)
	var earned := int(_save.profile["stars_earned"])
	var spent := int(_save.profile["stars_spent"])
	_save.save_now()
	_save.load_or_new()
	assert_eq(int(_save.profile["stars_earned"]), earned, "earned round-trips")
	assert_eq(int(_save.profile["stars_spent"]), spent, "spent round-trips")


func test_a_profile_predating_the_ledger_backfills_to_zero() -> void:
	# No migration by design: an older profile starts at 0 rather than being seeded
	# from the old derived total. The _migrate key backfill is what supplies the keys.
	var legacy: Dictionary = _save._default_profile()
	legacy.erase("stars_earned")
	legacy.erase("stars_spent")
	var migrated: Dictionary = _save._migrate(legacy)
	assert_eq(int(migrated["stars_earned"]), 0, "stars_earned backfills to 0")
	assert_eq(int(migrated["stars_spent"]), 0, "stars_spent backfills to 0")


func test_a_wreck_hands_the_car_back_damaged_with_its_upgrades() -> void:
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")
	# Upgrades are CAR-BOUND — install_upgrade fits the won part straight to the car
	# (no shared inventory pool for slottable parts).
	assert_true(_save.install_upgrade(car["instance_id"], "fx_turbo_small"), "upgrade installed")

	_save.record_wreck(car["instance_id"])
	# A wreck is a bad RESULT, not a lost asset: the car comes back damaged and repairable.
	# Never pins the recovery FRACTION (GameConfig.wreck_recovery_hp_fraction is tunable) —
	# only that the car survives, is worth repairing, and is not written off.
	assert_eq(_save.profile["cars"].size(), 1, "the car is kept")
	var hp: float = float(_save.get_car(car["instance_id"])["hp"])
	var max_hp: float = float(CarLibrary.by_id("fx_rwd_coupe")["max_hp"])
	assert_gt(hp, 0.0, "it comes back with health, not written off")
	assert_lt(hp, max_hp, "but damaged — there is a repair bill to pay")
	assert_true(_save.car_needs_repair(car["instance_id"]), "and it reads as needing repair")
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


func test_no_slot_is_hidden_so_every_part_installs_as_asked() -> void:
	# The hidden-slot rule (Save.install_upgrade -> UpgradeLibrary.installs_enabled) forces a
	# part in a slot with NO GARAGE ROW to install enabled, since installing it disabled
	# would leave it permanently dead. `nitrous` was the only slot that ever claimed it and
	# now has a row of its own, so UpgradeLibrary.HIDDEN_SLOTS is empty and the rule is
	# DORMANT — every part installs exactly as the caller asked.
	#
	# Asserted rather than deleted so the dormancy is visible: if a slot is hidden again the
	# rule wakes up, and this test is where that shows.
	assert_true(UpgradeLibrary.HIDDEN_SLOTS.is_empty(), "no slot is hidden from the garage")
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")
	assert_true(_save.install_upgrade(car["instance_id"], "fx_hidden", false),
		"the part is fitted")
	var fitted: Dictionary = _save.get_car(car["instance_id"])
	assert_false(UpgradeLibrary.is_enabled(fitted, "fx_hidden"),
		"and stays DISABLED, as the caller asked")


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


func test_field_repair_works_on_a_car_that_has_wrecked() -> void:
	# A wrecked car is an ordinary damaged car now, so the free between-event pit repair
	# treats it like any other — it used to refuse one outright as unrecoverable.
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")
	var id: int = car["instance_id"]
	_save.record_wreck(id)
	var before: float = float(_save.get_car(id)["hp"])
	var summary: Dictionary = _save.field_repair(id, 0.2, 0.5)
	assert_true(summary.get("repaired", false), "a wrecked car can still be pit-repaired")
	assert_gt(float(_save.get_car(id)["hp"]), before, "and it gains health")


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


# --- Wrecking is not terminal (features/damage.md) ---------------------------
# A wreck ends the RUN as a DNF and hands the car back damaged. The whole scaffolding
# that terminal wrecking needed — an all-cars-wrecked check, a free rescue box, a
# wrecked-car exclusion in the stranded test — is gone with it.

func test_a_wrecked_car_can_be_repaired_back_into_service() -> void:
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")
	var id := int(car["instance_id"])
	_save.apply_damage(id, 999999.0)  # lethal damage -> a wreck
	assert_true(_save.car_needs_repair(id), "the car comes back needing repair")
	_save.award_stars(20)
	assert_true(_save.repair_car(id), "and stars put it right")
	assert_false(_save.car_needs_repair(id), "back in service")


func test_the_starter_wrecks_and_recovers_like_any_car() -> void:
	# The starter is not invulnerable and not special-cased: lethal damage wrecks it, and
	# it comes back exactly as any other car does.
	var car: Dictionary = _save.grant_car("fx_light_rwd")
	var id := int(car["instance_id"])
	_save.apply_damage(id, 999999.0)
	assert_eq(_save.profile["cars"].size(), 1, "still owned")
	assert_gt(float(_save.get_car(id)["hp"]), 0.0, "and still raceable, just damaged")


func test_wrecking_every_car_leaves_the_player_able_to_drive() -> void:
	# THE reason terminal wrecking went: no sequence of crashes can strand a player, so
	# nothing needs to rescue them. This is also what makes the map's reachability
	# guarantee sound — a car an authored route depends on can never be lost.
	var a: Dictionary = _save.grant_car("fx_light_rwd")
	var b: Dictionary = _save.grant_car("fx_rwd_coupe")
	_save.apply_damage(int(a["instance_id"]), 999999.0)
	_save.apply_damage(int(b["instance_id"]), 999999.0)
	for car in _save.profile["cars"]:
		assert_gt(float((car as Dictionary)["hp"]), 0.0,
			"every car survives its wreck with health left")


func test_apply_damage_past_zero_wrecks_rather_than_going_negative() -> void:
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")
	var id := int(car["instance_id"])
	_save.apply_damage(id, 999999.0)
	# Damage that would take HP below zero routes through record_wreck instead: the car is
	# kept, and comes back with health rather than sitting at (or below) 0.
	assert_eq(_save.profile["cars"].size(), 1, "the car is kept in the garage")
	assert_gt(float(_save.get_car(id)["hp"]), 0.0, "and never lands on a negative or zero HP")


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


func test_a_mystery_box_never_pays_a_car() -> void:
	# The box used to have a second branch — a whole new CAR when every owned car was
	# wrecked — as the anti-soft-lock rescue. Both the rescue and the branch are gone:
	# wrecks are recoverable (features/damage.md) so nothing needs rescuing, and cars are
	# won at the rally that advertises them (features/prize-rallies.md), so a box handing
	# one out would undercut that. A box opens onto a PART or stays unopened.
	UpgradeFixtures.restore()  # see comment in the test above
	var a: Dictionary = _save.grant_car("fx_light_rwd")
	var b: Dictionary = _save.grant_car("fx_awd")
	_save.apply_damage(int(a["instance_id"]), 999999.0)
	_save.apply_damage(int(b["instance_id"]), 999999.0)
	var owned_before: int = (_save.profile["cars"] as Array).size()
	_save.add_item(UpgradeLibrary.MYSTERY_BOX_ID, 1)
	var result: Dictionary = _save.open_mystery_box(_rng(1))
	assert_eq((_save.profile["cars"] as Array).size(), owned_before,
		"however battered the garage is, a box never adds a car")
	if not result.is_empty():
		assert_false(bool(result["car"]), "and never reports one")


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


func test_migration_v2_restores_full_power_to_detuned_cars() -> void:
	# v2 -> v3: rally entry stopped gating on power-to-weight, so a saved engine_detune
	# set to duck under a ceiling has nothing left to duck under — and the slider that
	# set it went with the ceiling. Without this the car would be permanently and
	# invisibly down on power with no way for the player to put it right.
	var v2: Dictionary = _save._default_profile()
	v2["schema_version"] = 2
	v2[_save.KEY_CARS] = [
		{"model_id": "a", "tuning": {"engine_detune": 0.72}},
		{"model_id": "b", "tuning": {"engine_detune": 1.0}},
		{"model_id": "c", "tuning": {}},
	]
	var migrated: Dictionary = _save._migrate(v2)
	assert_eq(int(migrated["schema_version"]), _save.SCHEMA_VERSION, "migrated to current schema")
	var cars: Array = migrated[_save.KEY_CARS]
	assert_eq(float(cars[0]["tuning"]["engine_detune"]), 1.0, "the detuned car is restored to full power")
	assert_eq(float(cars[1]["tuning"]["engine_detune"]), 1.0, "an already-full car is untouched")
	assert_false((cars[2]["tuning"] as Dictionary).has("engine_detune"),
		"a car that never carried a detune does not gain one")


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
		# Reveal is geometric: a pin AT HQ is open from the start, one parked far outside
		# every circle never opens. (map_pos, not a wave count, is what locks a rally now.)
		{"id": "sm_open", "name": "Save Open", "region": "home", "difficulty": 1,
			"special": false, "map_pos": RallyLibrary.HQ_MAP_POS, "restriction": {}, "events": []},
		{"id": "sm_locked", "name": "Save Locked", "region": "home", "difficulty": 2,
			"special": false, "map_pos": RallyLibrary.HQ_MAP_POS + Vector2(0.9, 0.0),
			"restriction": {}, "events": []},
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
			"special": false, "map_pos": RallyLibrary.HQ_MAP_POS, "restriction": {}, "events": []},
	])
	var incoming: Dictionary = _save._default_profile()
	incoming["rallies"] = {"sm_open": {"completed": true, "best_combined_ms": 1, "best_placed": 1}}
	assert_true(_save.adopt_profile(incoming))
	assert_true(_save.rally_revealed_seen("sm_open"),
		"a restored career's already-open rally is seeded as seen, not paraded")
	RallyLibrary.reset()

# --- Star sinks: repair + part copies (features/star-economy.md) --------------
# Cars are not bought any more, so these are what the balance is FOR. Neither test pins a
# price — star_cost_per_repair / star_cost_per_part are tunable content; they assert the
# balance moves BY the configured price and that the transaction is all-or-nothing.

func _damaged_car() -> int:
	var car: Dictionary = _save.grant_car(String(CarFixtures.cars()[0]["id"]))
	var id: int = int(car["instance_id"])
	_save.get_car(id)["hp"] = 1.0
	return id


func test_a_repair_restores_health_and_charges_the_price() -> void:
	var id := _damaged_car()
	_save.award_stars(20)
	var before: int = _save.stars_available()
	var price: int = _save.repair_price(id)
	assert_true(_save.repair_car(id), "the repair went through")
	var entry: Dictionary = CarLibrary.by_id(String(_save.get_car(id)["model_id"]))
	assert_eq(float(_save.get_car(id)["hp"]), float(entry["max_hp"]), "back to full health")
	assert_eq(_save.stars_available(), before - price, "and the balance moved by the price")


func test_a_repair_straightens_bent_wheels_too() -> void:
	var id := _damaged_car()
	_save.get_car(id)["wheel_toe"] = [0.05, -0.05, 0.0, 0.0]
	_save.award_stars(20)
	assert_true(_save.repair_car(id))
	for toe in _save.get_car(id)["wheel_toe"]:
		assert_almost_eq(float(toe), 0.0, 0.0001, "every wheel is straight again")


func test_an_undamaged_car_cannot_be_charged_for_a_repair() -> void:
	# NOTHING TO FIX = NOTHING SPENT. A flat price makes this the one thing that must not
	# happen: paying a star and getting nothing back.
	var car: Dictionary = _save.grant_car(String(CarFixtures.cars()[0]["id"]))
	_save.award_stars(20)
	var before: int = _save.stars_available()
	assert_eq(_save.repair_price(int(car["instance_id"])), 0, "a pristine car is quoted nothing")
	assert_false(_save.repair_car(int(car["instance_id"])), "and cannot be repaired")
	assert_eq(_save.stars_available(), before, "so nothing is spent")


func test_a_repair_is_refused_when_the_balance_is_short() -> void:
	var id := _damaged_car()
	var hp_before: float = float(_save.get_car(id)["hp"])
	assert_eq(_save.stars_available(), 0, "precondition: broke")
	assert_false(_save.repair_car(id), "refused")
	assert_eq(float(_save.get_car(id)["hp"]), hp_before, "and the car is untouched")


func test_buying_a_part_fits_it_disabled_and_charges_the_price() -> void:
	var item_id := String(UpgradeFixtures.upgrades()[0]["id"])
	var car: Dictionary = _save.grant_car(String(CarFixtures.cars()[0]["id"]))
	var id: int = int(car["instance_id"])
	_save.award_stars(50)
	var before: int = _save.stars_available()
	assert_true(_save.can_buy_part(id, item_id), "precondition: discovered, affordable, no prereq")
	assert_true(_save.buy_part(id, item_id), "the purchase went through")
	assert_has(_save.get_car(id)["installed_upgrades"], item_id, "fitted to this car")
	assert_has(_save.get_car(id)["disabled_upgrades"], item_id,
		"but PARKED — which part runs in a slot stays the player's choice")
	assert_eq(_save.stars_available(), before - _save.part_price(item_id),
		"and the balance moved by the price")


func test_a_part_cannot_be_bought_twice_for_one_car() -> void:
	# Per-car dedup: a car can never hold the same part twice, so the second sale is refused
	# rather than silently charging for a duplicate.
	var item_id := String(UpgradeFixtures.upgrades()[0]["id"])
	var car: Dictionary = _save.grant_car(String(CarFixtures.cars()[0]["id"]))
	var id: int = int(car["instance_id"])
	_save.award_stars(50)
	assert_true(_save.buy_part(id, item_id))
	var after_first: int = _save.stars_available()
	assert_false(_save.can_buy_part(id, item_id), "already fitted")
	assert_false(_save.buy_part(id, item_id), "so the second sale is refused")
	assert_eq(_save.stars_available(), after_first, "and costs nothing")


func test_an_undiscovered_part_is_not_for_sale() -> void:
	# The shop sells what the player has proven they can earn. A part whose unlock rally is
	# unwon must not be purchasable, or stars would buy a shortcut past the exploration.
	var gated := {"id": "fx_gated_part", "name": "Gated", "slot": "fxslot",
		"consumable": false, "unlocked_by_rally": "fx_never_won"}
	var items: Array[Dictionary] = UpgradeFixtures.upgrades()
	items.append(gated)
	UpgradeLibrary.override_for_test(items)
	var car: Dictionary = _save.grant_car(String(CarFixtures.cars()[0]["id"]))
	_save.award_stars(50)
	assert_false(_save.can_buy_part(int(car["instance_id"]), "fx_gated_part"),
		"not discovered, so not for sale")
	assert_false(_save.buy_part(int(car["instance_id"]), "fx_gated_part"))
	UpgradeLibrary.reset()


func test_a_part_is_not_for_sale_until_this_car_has_its_prerequisite() -> void:
	# Upgrades are car-bound, so buying must not skip a rung: every car climbs its own
	# ladder even when another car in the garage is already at the top.
	var items: Array[Dictionary] = UpgradeFixtures.upgrades()
	var base_id := String(items[0]["id"])
	items.append({"id": "fx_rung_two", "name": "Rung Two", "slot": "fxslot",
		"consumable": false, "requires_upgrade_id": base_id})
	UpgradeLibrary.override_for_test(items)
	var car: Dictionary = _save.grant_car(String(CarFixtures.cars()[0]["id"]))
	var id: int = int(car["instance_id"])
	_save.award_stars(50)
	assert_false(_save.can_buy_part(id, "fx_rung_two"), "prerequisite not fitted to THIS car")
	assert_true(_save.buy_part(id, base_id), "buy the rung below first")
	assert_true(_save.can_buy_part(id, "fx_rung_two"), "now the ladder is satisfied")
	UpgradeLibrary.reset()


func test_a_part_is_not_for_sale_when_the_balance_is_short() -> void:
	var item_id := String(UpgradeFixtures.upgrades()[0]["id"])
	var car: Dictionary = _save.grant_car(String(CarFixtures.cars()[0]["id"]))
	var id: int = int(car["instance_id"])
	assert_eq(_save.stars_available(), 0, "precondition: broke")
	assert_false(_save.can_buy_part(id, item_id), "cannot afford it")
	assert_false(_save.buy_part(id, item_id), "so the sale is refused")
	assert_eq((_save.get_car(id)["installed_upgrades"] as Array).size(), 0, "nothing fitted")


# --- Handling warning vs. needs-repair ----------------------------------------

# Two DIFFERENT questions that used to be one call. "Needs repair" is true of any car that
# is not pristine — right for offering a repair, wrong as a red warning, which is why a car
# at 98% health was told it would handle badly.
func test_a_lightly_scratched_car_needs_repair_but_still_handles_fine() -> void:
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")
	var id := int(car["instance_id"])
	var entry := CarLibrary.by_id("fx_rwd_coupe")
	var max_hp := float(entry.get("max_hp", 1000.0))
	# Just under pristine: damage exists but is nowhere near the point it costs power.
	_save.get_car(id)["hp"] = max_hp * 0.99
	assert_true(_save.car_needs_repair(id), "any lost health is worth repairing")
	assert_false(_save.car_handles_badly(id), "but a scratch does not make it handle badly")


func test_a_properly_hurt_car_warns() -> void:
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")
	var id := int(car["instance_id"])
	var entry := CarLibrary.by_id("fx_rwd_coupe")
	# Comfortably below the misfire threshold, so the engine really is down on power.
	_save.get_car(id)["hp"] = (float(entry.get("max_hp", 1000.0))
		* Config.data.damage_misfire_health_threshold * 0.5)
	assert_true(_save.car_handles_badly(id), "a properly damaged car warns")


# Bent alignment alone does NOT warn. The warning is about damage costing engine power, and
# a car at full health has lost none — the red line appearing over "HEALTH 100%" reads as a
# bug, whatever the alignment says. Alignment is still repaired (car_needs_repair counts
# it), it just does not raise the alarm.
func test_bent_alignment_alone_does_not_warn() -> void:
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")
	var id := int(car["instance_id"])
	_save.get_car(id)["wheel_toe"] = [0.0, 0.0, 0.03, 0.0]
	assert_false(_save.car_handles_badly(id), "a full-health car does not warn")
	assert_true(_save.car_needs_repair(id), "but it is still worth repairing")


# --- Legacy NOS migration -----------------------------------------------------

# NOS was four chained rungs sharing one slot, of which only the highest was ever ENABLED —
# the rest sat in disabled_upgrades. Collapsing the ladder deletes the higher rungs, so the
# survivor would load in fitted but switched OFF, and the player would never know.
func test_a_legacy_nitrous_save_loads_with_nitrous_enabled() -> void:
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")
	var id := int(car["instance_id"])
	var live: Dictionary = _save.get_car(id)
	# The shape an old save had: a lower rung parked, the higher rung (now retired) live.
	live["installed_upgrades"] = ["fx_hidden", "fx_retired_rung"]
	live["disabled_upgrades"] = ["fx_hidden"]
	_save.save_now()
	_save.load_or_new()

	var loaded: Dictionary = _save.get_car(id)
	assert_false((loaded["installed_upgrades"] as Array).has("fx_retired_rung"),
		"the retired rung is pruned")
	assert_true((loaded["installed_upgrades"] as Array).has("fx_hidden"),
		"the surviving nitrous part is still fitted")
	assert_true(UpgradeLibrary.is_enabled(loaded, "fx_hidden"),
		"and comes back ENABLED rather than silently parked")


# The migration must not override a deliberate choice: a player who has switched nitrous
# off keeps it off.
func test_the_migration_leaves_a_live_nitrous_choice_alone() -> void:
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")
	var id := int(car["instance_id"])
	var live: Dictionary = _save.get_car(id)
	live["installed_upgrades"] = ["fx_hidden"]
	live["disabled_upgrades"] = []
	_save.save_now()
	_save.load_or_new()
	assert_true(UpgradeLibrary.is_enabled(_save.get_car(id), "fx_hidden"),
		"an already-enabled part is untouched")


# A car with no nitrous at all must not be handed one.
func test_the_migration_never_installs_nitrous_a_car_lacks() -> void:
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")
	var id := int(car["instance_id"])
	_save.save_now()
	_save.load_or_new()
	var loaded: Dictionary = _save.get_car(id)
	# The sweep below is vacuous on an empty list, so assert the shape first — otherwise a
	# migration that dropped installed_upgraded entirely would pass this test by having
	# nothing to iterate.
	var installed: Array = loaded["installed_upgrades"]
	assert_true(installed.is_empty(), "a freshly granted car carries no upgrades at all")
	for item_id in installed:
		assert_ne(UpgradeLibrary.slot_of(String(item_id)), "nitrous",
			"no nitrous is invented for a car that had none")
