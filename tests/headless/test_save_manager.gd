extends GutTest
# The Save autoload (player profile / persistence). Exercises the round-trip,
# default profile, migration, integrity fallbacks, and damage semantics described
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
		assert_true(_save.rally_podiumed(rid), "rally %s marked completed" % rid)
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
	_save.add_item("fx_consumable", 2)
	_save.record_podium_rally("alpine", 123456)
	_save.set_tuning(car["instance_id"], {"brake_bias": 0.55})
	_save.save_now()
	assert_true(_save.has_save(), "file written to disk")

	# Wipe in-memory state, reload from disk, assert it came back intact.
	_save.profile = {}
	_save.load_or_new()
	assert_eq(_save.profile["cars"].size(), 1, "owned car reloaded")
	assert_eq(_save.profile["cars"][0]["model_id"], "fx_light_rwd", "model id reloaded")
	assert_eq(int(_save.profile["inventory"]["fx_consumable"]), 2, "inventory reloaded")
	assert_true(_save.rally_podiumed("alpine"), "rally completion reloaded")
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
	_save.record_podium_rally("alpine", 5000)
	_save.record_podium_rally("alpine", 6000)  # slower: should not replace
	_save.record_podium_rally("alpine", 4000)  # faster: should replace
	assert_eq(_save.podium_rally_count(), 1, "completing the same rally twice counts once")
	assert_eq(int(_save.profile["rallies"]["alpine"]["best_combined_ms"]), 4000, "keeps the fastest time")


# --- Star ledger: DELETED (todo/roguelike-pivot.md decision 21) -------------------------
# The whole "Star ledger" test block (a fresh profile's empty ledger, a completion crediting
# a placement and returning it, re-winning for stars, award_stars / spend_stars, the ledger
# surviving a save/reload, an old profile backfilling to zero) is gone with
# Save.stars_earned / stars_spent / stars_available / award_stars / spend_stars and
# RallyLibrary.stars_for_placement — see Save._default_profile()'s "Star ledger: DELETED"
# note. Two of those tests mixed STAR assertions with BOOKKEEPING assertions
# (record_podium_rally's `completed` / `best_placed` / `best_combined_ms` survive the star
# deletion — see that function's own comment); their bookkeeping halves are kept below,
# trimmed of the star half.

func test_a_dnf_does_not_corrupt_the_best_placement_record() -> void:
	# The one case record_podium_rally's own guard exists for: a DNF (combined_ms <= 0) must
	# not overwrite a real best time, and a placed=0 call must not demote a real best
	# placement. Used to also assert this "pays nothing"; that half is gone with the ledger.
	_save.record_podium_rally("alpine", 60_000, 1)
	_save.record_podium_rally("alpine", 0, 0)
	assert_eq(int(_save.profile["rallies"]["alpine"]["best_combined_ms"]), 60_000,
		"a DNF does not overwrite the recorded best time")
	assert_eq(_save.best_placement("alpine"), 1, "nor does it demote the recorded best placement")


func test_a_worse_replay_keeps_the_best_placement_record() -> void:
	# The record follows the BEST placement ever achieved, not the most recent — so a
	# scrappier replay must not demote it. Used to also assert what a worse replay "pays";
	# that half is gone with the ledger.
	_save.record_podium_rally("alpine", 60_000, 1)
	_save.record_podium_rally("alpine", 90_000, 4)  # off the podium; RallyLibrary.PODIUM_PLACES is deleted
	assert_eq(_save.best_placement("alpine"), 1, "the record is still the best finish")




func test_damage_past_zero_keeps_the_car_its_upgrades_and_its_bent_wheels() -> void:
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")
	var id := int(car["instance_id"])
	# Upgrades are CAR-BOUND — install_upgrade fits the won part straight to the car
	# (no shared inventory pool for slottable parts).
	assert_true(_save.install_upgrade(id, "fx_turbo_small"), "upgrade installed")
	_save.set_wheel_toe(id, [0.05, -0.03, 0.0, 0.0])

	_save.apply_damage(id, 999999.0)  # far past zero
	# 0 HP is a STATE, not an event: nothing is removed, reset, or handed back at part
	# health. The car sits at exactly 0 and stays fully owned.
	assert_eq(_save.profile["cars"].size(), 1, "the car is kept")
	assert_eq(float(_save.get_car(id)["hp"]), 0.0, "HP clamps at exactly zero, never negative")
	# car_needs_repair() was asserted here too; it is deleted with the paid garage repair
	# (todo/roguelike-pivot.md decision 21) — see the "Star sinks" block comment further down.
	# Its upgrades ride along with the car (bound to it; never moved or returned).
	assert_true(_save.get_car(id)["installed_upgrades"].has("fx_turbo_small"),
		"the upgrade is still installed on the 0-HP car")
	assert_eq(_save.get_car(id)["wheel_toe"], [0.05, -0.03, 0.0, 0.0],
		"and its stored wheel_toe is untouched — no hidden restore")


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
	# The SYNTHETIC consumable: nothing shipped is one any more, but the refusal is still
	# real code and still has to hold for whatever claims the flag next.
	_save.add_item("fx_consumable", 1)
	assert_false(_save.install_upgrade(car["instance_id"], "fx_consumable"),
		"a consumable can't be slotted")
	assert_false(_save.install_upgrade(car["instance_id"], "bogus"), "unknown item can't be installed")
	assert_eq(int(_save.profile["inventory"]["fx_consumable"]), 1,
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


# --- apply_field_repair_to: the ONE fraction pairing ---------------------------
#
# Every between-stage and final-stage repair in the game goes through this wrapper
# so no caller picks its own fractions (it was folded here off RallySession). What
# is pinned is the AGREEMENT with a hand-made field_repair at the config's own
# fractions — not the fractions themselves, which are tunables.

func test_apply_field_repair_to_uses_the_configs_own_fractions() -> void:
	var cfg: GameConfig = Config.data
	var driven := int(_save.grant_car("fx_rwd_coupe")["instance_id"])
	var control := int(_save.grant_car("fx_rwd_coupe")["instance_id"])
	_save.apply_damage(driven, 400.0)
	_save.apply_damage(control, 400.0)
	_save.set_wheel_toe(driven, [0.08, -0.06, 0.04, -0.02])
	_save.set_wheel_toe(control, [0.08, -0.06, 0.04, -0.02])

	var wrapped: Dictionary = _save.apply_field_repair_to(driven)
	var by_hand: Dictionary = _save.field_repair(control,
		cfg.field_repair_hp_fraction, cfg.field_repair_toe_fraction)

	assert_eq(bool(wrapped.get("repaired", false)), bool(by_hand.get("repaired", false)),
		"the wrapper repairs exactly when the raw call does")
	assert_almost_eq(float(_save.get_car(driven)["hp"]), float(_save.get_car(control)["hp"]),
		0.001, "the wrapper's HP result is field_repair at the config fractions")
	assert_eq(_save.get_car(driven)["wheel_toe"], _save.get_car(control)["wheel_toe"],
		"and its wheel result too")


func test_apply_field_repair_to_no_ops_when_nothing_is_fielded() -> void:
	# -1 is "no car fielded" (a session between runs), not an error.
	var summary: Dictionary = _save.apply_field_repair_to(-1)
	assert_false(summary.get("repaired", false), "no fielded car -> nothing repaired")


func test_field_repair_skips_a_pristine_car() -> void:
	var car: Dictionary = _save.grant_car("fx_light_rwd")  # full hp, straight wheels
	var summary: Dictionary = _save.field_repair(car["instance_id"], 0.2, 0.5)
	assert_false(summary.get("repaired", false), "nothing to repair on a spotless car")


func test_field_repair_works_on_a_zero_hp_car() -> void:
	# A 0-HP car is an ordinary damaged car, so the free between-event pit repair
	# treats it like any other — nothing gates on the bottomed-out state.
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")
	var id: int = car["instance_id"]
	_save.apply_damage(id, 999999.0)
	var summary: Dictionary = _save.field_repair(id, 0.2, 0.5)
	assert_true(summary.get("repaired", false), "a 0-HP car can still be pit-repaired")
	assert_gt(float(_save.get_car(id)["hp"]), 0.0, "and it gains health off the floor")


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


# --- Damage never wrecks (features/damage.md) --------------------------------
# Damage only ever weakens: HP floors at 0 and stays there. There is no write-off,
# no wreck record, no terminal state — so the whole scaffolding terminal wrecking
# needed (an all-cars-wrecked check, a free rescue box) is gone with it.

# test_a_zero_hp_car_can_be_repaired_back_into_service DELETED: repair_car / car_needs_repair
# / award_stars are all gone with the paid garage repair and the star ledger
# (todo/roguelike-pivot.md decision 21).


func test_the_starter_bottoms_out_and_recovers_like_any_car() -> void:
	# The starter is not invulnerable and not special-cased: heavy damage floors it, and
	# it stays owned exactly as any other car does.
	var car: Dictionary = _save.grant_car("fx_light_rwd")
	var id := int(car["instance_id"])
	_save.apply_damage(id, 999999.0)
	assert_eq(_save.profile["cars"].size(), 1, "still owned")
	assert_eq(float(_save.get_car(id)["hp"]), 0.0, "sitting on the floor, not written off")


func test_flooring_every_car_leaves_the_player_able_to_drive() -> void:
	# THE reason terminal wrecking went: no sequence of crashes can strand a player, so
	# nothing needs to rescue them. This is also what makes the map's reachability
	# guarantee sound — a car an authored route depends on can never be lost.
	var a: Dictionary = _save.grant_car("fx_light_rwd")
	var b: Dictionary = _save.grant_car("fx_rwd_coupe")
	_save.apply_damage(int(a["instance_id"]), 999999.0)
	_save.apply_damage(int(b["instance_id"]), 999999.0)
	assert_eq(_save.profile["cars"].size(), 2, "both cars are still owned and fieldable")


func test_apply_damage_clamps_at_zero_rather_than_going_negative() -> void:
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")
	var id := int(car["instance_id"])
	_save.apply_damage(id, 999999.0)
	_save.apply_damage(id, 999999.0)  # and again — 0 is a stable floor, not a trigger
	assert_eq(_save.profile["cars"].size(), 1, "the car is kept in the garage")
	assert_eq(float(_save.get_car(id)["hp"]), 0.0, "HP rests at exactly 0, never negative")


func test_consume_item_respects_counts() -> void:
	# Any id will do: add_item/consume_item are generic inventory bookkeeping and do not
	# consult the catalogue.
	var item := "fx_consumable"
	_save.add_item(item, 2)
	assert_true(_save.consume_item(item, 1), "consume succeeds when stock available")
	assert_eq(int(_save.profile["inventory"][item]), 1, "count decremented")
	assert_false(_save.consume_item(item, 5), "consume fails when stock insufficient")
	assert_eq(int(_save.profile["inventory"][item]), 1, "failed consume leaves count untouched")


# Every non-consumable, non-free part in the real catalogue, up to MAX_TIER —
# derived from the live catalogue so a retune doesn't break the test.
func _all_real_parts() -> Array:
	var parts := []
	for item in UpgradeLibrary.UPGRADES:
		if not item["consumable"] and not bool(item.get("free", false)):
			parts.append(String(item["id"]))
	return parts


func _rng(seed_value: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed_value
	return r


func test_migration_refuses_newer_version() -> void:
	var future: Dictionary = _save._default_profile()
	future["schema_version"] = _save.SCHEMA_VERSION + 1
	assert_true(_save._migrate(future).is_empty(), "a newer-version profile is refused (returns empty)")


# test_migration_v2_restores_full_power_to_detuned_cars and
# test_migration_v1_strips_the_unbound_inventory DELETED: both drove
# Save._migrate_step's per-version transforms (2 -> 3, 1 -> 2), which are deleted along
# with the whole migration ladder (todo/roguelike-pivot.md decision 34) -- see
# SCHEMA_VERSION's own comment for why a pre-pivot profile now resets instead of stepping
# forward. test_sanitise_drops_the_retired_repair_kit_from_an_existing_profile below is
# untouched -- it exercises _sanitise(), a separate, version-independent tolerant pass.



func test_sanitise_drops_the_retired_repair_kit_from_an_existing_profile() -> void:
	# Cleaned up in the tolerant sanitise pass rather than a schema migration, so older
	# builds can still read the profile (no SCHEMA_VERSION bump).
	_save.profile["inventory"] = {"repair_kit": 4, "fx_consumable": 2}
	_save.profile = _save._sanitise(_save.profile)
	var inv: Dictionary = _save.profile["inventory"]
	assert_false(inv.has("repair_kit"), "the dead consumable is stripped on load")
	assert_eq(int(inv.get("fx_consumable", 0)), 2, "live consumables are untouched")


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
	assert_true(_save.swap_engines(a["instance_id"], b["instance_id"]), "the swap succeeds")
	# Re-fetch (grant_car returns a live ref, but re-read to be explicit).
	a = _save.get_car(a["instance_id"])
	b = _save.get_car(b["instance_id"])
	assert_eq(String(a.get("swapped_engine", "")), stock_b, "Fixture Roadster now runs the Fixture Coupe engine")
	assert_eq(String(b.get("swapped_engine", "")), stock_a, "Fixture Coupe now runs the Fixture Roadster engine")


func test_swap_with_identical_engines_is_a_noop() -> void:
	# Two instances of the same model run the same engine, so there is nothing to
	# exchange and the swap reports no change. Swaps are free now, so nothing is at stake
	# in the refusal — but a caller that believed a no-op had happened would repaint the
	# garage for a change that never occurred.
	var a: Dictionary = _save.grant_car("fx_light_rwd")
	var b: Dictionary = _save.grant_car("fx_light_rwd")
	assert_false(_save.swap_engines(a["instance_id"], b["instance_id"]),
		"swapping identical current engines is a no-op")


func test_swapping_back_restores_stock_and_clears_field() -> void:
	var a: Dictionary = _save.grant_car("fx_light_rwd")
	var b: Dictionary = _save.grant_car("fx_rwd_coupe")
	_save.swap_engines(a["instance_id"], b["instance_id"])
	_save.swap_engines(a["instance_id"], b["instance_id"])  # swap back
	a = _save.get_car(a["instance_id"])
	b = _save.get_car(b["instance_id"])
	assert_eq(String(a.get("swapped_engine", "")), "", "Fixture Roadster back to stock -> field cleared")
	assert_eq(String(b.get("swapped_engine", "")), "", "Fixture Coupe back to stock -> field cleared")


func test_swap_succeeds_between_damaged_cars() -> void:
	var a: Dictionary = _save.grant_car("fx_light_rwd")
	var b: Dictionary = _save.grant_car("fx_rwd_coupe")
	_save.apply_damage(b["instance_id"], 1.0)  # b below max HP — no longer a blocker
	assert_true(_save.swap_engines(a["instance_id"], b["instance_id"]), "a damaged car swaps fine")
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
	_save.record_podium_rally("some_rally", 60_000, 1)
	_save.mark_rally_revealed("some_rally")
	assert_true(_save.rally_podiumed("some_rally"), "the completion is still there")
	assert_eq(_save.best_placement("some_rally"), 1, "the best placement is still there")
	assert_true(_save.rally_revealed_seen("some_rally"))


func test_a_progressed_profile_with_no_reveal_flags_wants_seeding() -> void:
	# THE BACKFILL TRAP: a save written before the reveal feature existed carries no
	# flags at all, and treating that as "nothing revealed yet" would parade every open
	# rally at a player who has been looking at them for weeks.
	assert_false(_save.needs_reveal_seeding(), "a brand-new career has nothing to backfill")
	_save.record_podium_rally("some_rally", 60_000, 1)
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
	_save.record_podium_rally("sm_open", 60_000, 1)  # career progress, but no reveal flags at all
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

# --- Star sinks: repair + part copies -- DELETED (todo/roguelike-pivot.md decision 21) --
# The paid garage repair (repair_car / repair_price / car_needs_repair / car_handles_badly)
# is RETIRED outright, not stubbed -- see the "Spending stars: DELETED" block comment in
# save_manager.gd above can_buy_part. Buying a part or a drivetrain conversion is a
# DIFFERENT case -- the star economy and the parts model INTERLEAVING -- so can_buy_part /
# buy_part / can_buy_drive_mode / buy_drive_mode / part_price / drive_mode_price keep their
# signatures (upgrade_options.gd / upgrades_grid.gd still call them by name) but are left
# DANGLING: every purchase predicate now always refuses. These two tests are the regression
# guard for that dangling state -- when the economy stage wires real money into these, they
# are the tests to replace.

func test_buying_a_part_always_refuses_with_no_money_wired() -> void:
	var item_id := String(UpgradeFixtures.upgrades()[0]["id"])
	var car: Dictionary = _save.grant_car(String(CarFixtures.cars()[0]["id"]))
	var id: int = int(car["instance_id"])
	assert_false(_save.can_buy_part(id, item_id),
		"no star ledger left to check a price against -- always refuses")
	assert_false(_save.buy_part(id, item_id), "so the purchase never goes through")
	assert_eq((_save.get_car(id)["installed_upgrades"] as Array).size(), 0, "nothing fitted")


func test_buying_a_drive_mode_always_refuses_with_no_money_wired() -> void:
	var car: Dictionary = _save.grant_car(String(CarFixtures.cars()[0]["id"]))
	var id: int = int(car["instance_id"])
	var stock: int = UpgradeLibrary.stock_drive_mode(car)
	var non_stock := 0 if stock != 0 else 1
	assert_false(_save.can_buy_drive_mode(id, non_stock),
		"no star ledger left to check a price against -- always refuses")
	assert_false(_save.buy_drive_mode(id, non_stock), "so the purchase never goes through")
	assert_eq((_save.get_car(id)["drivetrain_modes_bought"] as Array).size(), 0,
		"nothing recorded as bought")


# repair_car / repair_price / car_needs_repair / car_handles_badly are all DELETED
# (see the block comment above) -- the paid garage repair had no callers left once the
# star ledger was gone, and between-run resets leave it nothing to do once the run loop
# lands. Their tests (a repair restoring health and charging the price, straightening
# wheels, an undamaged car refusing a charge, a short balance refusing the repair, and
# the two "handling warning vs needs-repair" distinctions) are deleted with them.




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


# --- v4 -> v5 / v5 -> v6 migration tests: DELETED (todo/roguelike-pivot.md decision 34) --
# test_migration_v4_grants_parts_whose_unlock_rally_moved,
# test_migration_v4_does_not_fake_the_new_rally_completion,
# test_migration_v5_keeps_engine_swapping_for_a_career_that_won_the_old_rally and
# test_migration_v5_does_not_grant_engine_swapping_to_a_career_that_never_won_it all drove
# Save._migrate_step / _MIGRATABLE_FROM / MOVED_PART_UNLOCKS / OLD_ENGINE_SWAP_UNLOCK_RALLY,
# all deleted with the whole migration ladder -- no migration is written for the pivot, so a
# pre-pivot profile resets instead (see Save.SCHEMA_VERSION's own comment).
# test_engine_swaps_unlock_by_winning_the_current_rally below is untouched -- it exercises
# the surviving, non-legacy unlock path.



func test_engine_swaps_unlock_by_winning_the_current_rally() -> void:
	# The ordinary path, independent of any legacy flag: completing the rally the constant
	# names is what opens swapping.
	var profile: Dictionary = _save._default_profile()
	assert_false(RallyLibrary.engine_swaps_unlocked(profile), "setup: locked on a fresh career")
	profile[_save.KEY_RALLIES] = {
		RallyLibrary.ENGINE_SWAP_UNLOCK_RALLY: {"completed": true, "best_placed": 1},
	}
	assert_true(RallyLibrary.engine_swaps_unlocked(profile),
		"winning the unlock rally opens engine swapping")


# test_a_fresh_profile_has_no_legacy_grants DELETED: KEY_LEGACY_ENGINE_SWAP /
# KEY_LEGACY_PART_UNLOCKS are no longer declared in _default_profile() at all
# (todo/roguelike-pivot.md decision 34 -- see that dict's own comment), so indexing
# either off a fresh profile now errors instead of reading a default.



func test_the_legacy_set_satisfies_the_rally_gate() -> void:
	# The mechanism itself: an id in the set passes rally_gate_met even though its
	# unlock rally has not been completed.
	#
	# Against a SYNTHETIC catalogue, not the shipped one — both because CLAUDE.md says
	# not to lean on a real entry, and because another test in this file may have left a
	# fixture installed, under which a real part id resolves to no gate at all and this
	# would pass vacuously.
	UpgradeLibrary.override_for_test([
		{"id": "test_part", "name": "Test Part", "slot": "tires",
		 "unlocked_by_rally": "test_rally"},
	] as Array[Dictionary])
	var profile: Dictionary = _save._default_profile()
	assert_false(UpgradeLibrary.rally_gate_met("test_part", profile),
		"setup: the part is gated with an empty profile")
	profile[_save.KEY_LEGACY_PART_UNLOCKS] = ["test_part"]
	assert_true(UpgradeLibrary.rally_gate_met("test_part", profile),
		"a legacy grant opens the gate without the rally")
	UpgradeLibrary.reset()


# --- Every persisted key is DECLARED, not conjured (ratchet) --------------------
# The defect this guards, found by the small-model-readiness loop in round 014: a probe
# added a `rallies_finished` counter with `profile["rallies_finished"] = ... + 1` and a
# `profile.get("rallies_finished", 0)` reader, and never declared it in
# `_default_profile()`. Everything worked and every test passed — the getter defaults to
# 0 — but `_migrate`'s key backfill seeds existing profiles ONLY from `_default_profile()`,
# so the key was absent from every fresh and every migrated profile and sprang into
# existence on first write. That is inconsistent with every sibling counter
# (`cloud_revision`, `username` and several more all say so in their own
# comments) and invisible to the suite.
#
# Derived from the source, so a field added tomorrow is covered without touching this test.
# Keys the migration chain writes for its own bookkeeping are exempt by name below.
# (The migration ladder itself is deleted -- todo/roguelike-pivot.md decision 34 -- so
# nothing currently matches "schema_version" any more; kept as a harmless exemption in
# case a future one-off transform writes it again the same way.)
const PROFILE_KEY_WRITE_EXEMPT := [
	"schema_version",
]


func test_every_persisted_key_written_is_declared_in_the_default_profile() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/save_manager.gd")
	assert_ne(src, "", "could not read save_manager.gd")

	var declared := (Save._default_profile() as Dictionary).keys()
	var re := RegEx.new()
	re.compile('\\b(?:profile|p)\\["([a-z_]+)"\\]\\s*=')

	var undeclared: Array[String] = []
	for hit in re.search_all(src):
		var key := hit.get_string(1)
		if PROFILE_KEY_WRITE_EXEMPT.has(key):
			continue
		if not declared.has(key) and not undeclared.has(key):
			undeclared.append(key)

	assert_eq(undeclared, ([] as Array[String]),
		"these profile keys are written but never declared in _default_profile(): %s. "
		% str(undeclared)
		+ "Add each one there with a default. That is not bookkeeping — _migrate() backfills "
		+ "existing profiles from _default_profile() alone, so an undeclared key is missing "
		+ "from every fresh and every migrated profile until something happens to write it. "
		+ "A `.get(key, 0)` reader hides this completely and no test will catch it. "
		+ "See the `cloud_revision` / `username` comments for the shape to copy.")


# --- Guard: a "finished" metric may not be derived from the podium-gated record ---------
#
# WHY (round 015). A probe asked to "track how many rallies the player has finished" added
# `RallyLibrary.finished_count()` counting rallies with `best_placed > 0`, and put
# "Rallies finished: N" on the profile screen. Every test passed and the number is WRONG:
# `Save.record_podium_rally` has exactly one caller (`rally_session.gd`, inside
# `_award_podium_rewards`, gated on `podium_or_opening`), so a 5th-place finish writes
# nothing into the rally's record. The gate is on the WRITE, which makes every field of the
# record podium-gated — so `best_placed > 0` is the podium count wearing a better name.
#
# Round 003 had already planted the warning, but its reasoning named only the `completed`
# flag, so `best_placed` read as an untainted sibling to escape through. The note has now
# failed twice on this route; this is the executable check that replaces a third one.
#
# Derived from the source tree, so a file or function added tomorrow is covered without
# touching this test. It does NOT forbid the sanctioned fix: a real finish counter is a NEW
# persisted key (declared in `_default_profile()`), and reading that key touches none of
# the gated fields below.
const GATED_RECORD_FIELDS := ["completed", "best_placed", "best_combined_ms"]


func _gd_scripts_under(dir_path: String, out: Array[String]) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	for f in d.get_files():
		if f.ends_with(".gd"):
			out.append(dir_path.path_join(f))
	for sub in d.get_directories():
		_gd_scripts_under(dir_path.path_join(sub), out)


func test_no_finish_named_symbol_derives_from_the_podium_gated_rally_record() -> void:
	var files: Array[String] = []
	_gd_scripts_under("res://scripts", files)
	assert_gt(files.size(), 50, "sanity: expected to find the scripts/ tree")

	var gated := RegEx.new()
	gated.compile('\\.get\\("(?:%s)"' % "|".join(GATED_RECORD_FIELDS))
	var func_re := RegEx.new()
	func_re.compile("^(?:static\\s+)?func\\s+([A-Za-z0-9_]+)")

	var offenders: Array[String] = []
	for path in files:
		var src := FileAccess.get_file_as_string(path)
		assert_ne(src, "", "could not read %s" % path)
		var current := ""
		var line_no := 0
		for line in src.split("\n"):
			line_no += 1
			var m := func_re.search(line)
			if m != null:
				current = m.get_string(1)
			if current.to_lower().contains("finish") and gated.search(line) != null:
				offenders.append("%s:%d in %s() — %s"
					% [path, line_no, current, line.strip_edges()])

	assert_eq(offenders, ([] as Array[String]),
		"these 'finish'-named symbols read a PODIUM-GATED field of a rally's save record: %s. "
		% str(offenders)
		+ "That number is not a finish count. Save.record_podium_rally is called from exactly one "
		+ "site (rally_session.gd, inside _award_podium_rewards, gated on `podium_or_opening`), "
		+ "so a 5th-place finish writes NOTHING into the record — `completed`, `best_placed` and "
		+ "`best_combined_ms` are all equally podium-gated and there is no untainted sibling "
		+ "field to escape through. To count finishes in any position, ADD a persisted counter: "
		+ "declare it in Save._default_profile() (so _migrate's key backfill seeds existing "
		+ "saves), increment it on the any-finish path, and read that key instead. "
		+ "See Save.rally_podiumed() and RallyLibrary.podium_count() for what the record CAN "
		+ "honestly tell you.")


# --- Guard: the runtime tripwire for an undeclared persisted key -------------------------
#
# The RUNTIME half of `test_every_persisted_key_written_is_declared_in_the_default_profile`
# above (round 015). That static check catches the mistake in CI, but two independent probes
# of this codebase made it anyway, because neither ran the suite — and the failure is silent
# (`profile.get(key, 0)` reads 0 whether or not the key was ever declared). `save()` now
# announces it via push_error, so it surfaces in the editor with no test run at all.
#
# These exercise the PURE detector rather than the push_error wrapper, deliberately: asserting
# on an emitted engine error is brittle, and the interesting logic is entirely in "which keys
# count as unknown".
func test_a_code_written_undeclared_profile_key_is_detected() -> void:
	_save.profile = _save._default_profile()
	_save._note_known_profile_keys()
	assert_eq(_save._undeclared_profile_keys(), ([] as Array[String]),
		"a freshly defaulted profile declares everything it holds")

	_save.profile["totally_made_up_counter"] = 3
	assert_eq(_save._undeclared_profile_keys(), (["totally_made_up_counter"] as Array[String]),
		"a key written by code and absent from _default_profile() must be reported — that is "
		+ "the defect the tripwire exists for")


func test_a_retired_key_already_on_disk_is_not_reported() -> void:
	# A real player's profile can carry a top-level key that has since been retired: load
	# backfills missing keys but never prunes extra ones. Shouting about those would be a
	# false alarm, which is why "known" is declared-keys UNION keys-as-loaded.
	_save.profile = _save._default_profile()
	_save.profile["some_retired_key_from_an_old_build"] = "x"
	_save._note_known_profile_keys()  # as if this profile had just been loaded from disk
	assert_eq(_save._undeclared_profile_keys(), ([] as Array[String]),
		"a key that was already in the loaded profile is not a code-written key")

	_save.profile["written_after_load"] = 1
	assert_eq(_save._undeclared_profile_keys(), (["written_after_load"] as Array[String]),
		"but a key appearing AFTER the snapshot still is")


# --- Guard: the podium-gated recorder must not write a "finish"-named profile key ---------
#
# The SECOND route into the same wrong number (round 016). The guard above catches a "finish"
# metric DERIVED from a gated record field. This catches one INCREMENTED inside the gated
# recorder: `record_podium_rally()` has exactly one caller, gated on `podium_or_opening`, so a
# counter bumped in there counts podiums no matter what the key is called.
#
# A probe did exactly this — declared `rallies_finished` correctly in `_default_profile()`,
# incremented it inside the recorder, and shipped "Rallies Finished: N" to the profile screen.
# Round 014's undeclared-key ratchet passed (the key WAS declared) and the read-side guard
# passed (no finish-named function read a gated field), so all 107 tests in this file were
# green while the player saw the podium count.
#
# Derived from the source, so it covers keys that do not exist yet.
func test_the_podium_gated_recorder_writes_no_finish_named_profile_key() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/save_manager.gd")
	assert_ne(src, "", "could not read save_manager.gd")

	var lines := src.split("\n")
	var start := -1
	for i in lines.size():
		if lines[i].begins_with("func record_podium_rally("):
			start = i
			break
	assert_gt(start, -1,
		"could not find func record_podium_rally() — if it was renamed, update this guard "
		+ "(and keep the gate warning in its docstring)")

	# The function body runs to the next top-level func.
	var writes := RegEx.new()
	writes.compile('profile\\["([a-z_]+)"\\]\\s*=')
	var offenders: Array[String] = []
	for i in range(start + 1, lines.size()):
		var line := lines[i]
		if line.begins_with("func ") or line.begins_with("static func "):
			break
		var m := writes.search(line)
		if m != null and m.get_string(1).contains("finish"):
			offenders.append("line %d: %s" % [i + 1, line.strip_edges()])

	assert_eq(offenders, ([] as Array[String]),
		"record_podium_rally() writes these 'finish'-named profile keys: %s. " % str(offenders)
		+ "That function has exactly ONE caller — rally_session.gd, inside "
		+ "_award_podium_rewards, which runs only `if podium_or_opening` — so anything written "
		+ "there is PODIUM-GATED and a finish counter bumped in it counts podiums. Move the "
		+ "increment to the any-finish gate (`var finished := not _dnf` in "
		+ "rally_session.gd::_resolve_results, beside _award_any_finish_bonus_stars) instead.")
