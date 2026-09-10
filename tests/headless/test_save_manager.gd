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
	_clean()
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.load_or_new()  # fresh default against the test path


func after_each() -> void:
	_clean()
	# Restore the real path so we don't leak the test redirect into other files.
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	CarFixtures.restore()


func _clean() -> void:
	for suffix in ["", ".bak", ".tmp", ".conflict.bak"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


func test_default_profile_is_empty_and_valid() -> void:
	assert_false(_save.has_save(), "no file on disk yet -> has_save() false")
	assert_eq(_save.profile["schema_version"], _save.SCHEMA_VERSION, "default carries current schema")
	assert_eq(_save.profile["cars"].size(), 0, "no owned cars")
	assert_false(_save.profile["starter_picked"], "starter not yet picked")


func test_round_trip_survives_save_and_reload() -> void:
	var car: Dictionary = _save.grant_car("fx_light_rwd")
	_save.set_tuning(car["instance_id"], {"brake_bias": 0.55})
	_save.save_now()
	assert_true(_save.has_save(), "file written to disk")

	# Wipe in-memory state, reload from disk, assert it came back intact.
	_save.profile = {}
	_save.load_or_new()
	assert_eq(_save.profile["cars"].size(), 1, "owned car reloaded")
	assert_eq(_save.profile["cars"][0]["model_id"], "fx_light_rwd", "model id reloaded")
	assert_almost_eq(float(_save.profile["cars"][0]["tuning"]["brake_bias"]), 0.55, 0.001, "tuning reloaded")


func test_set_run_persists_and_survives_reload() -> void:
	# The three challenge-run methods (RunSession's only writers of these
	# keys) go through the same save/reload path as every other domain.
	var run := {"period_key": "2026-W1", "kind": "weekly", "car_instance_id": 7,
		"stage_index": 1, "stage_times_ms": [1000], "dnf": false}
	_save.set_run(run)
	_save.save_now()
	_save.profile = {}
	_save.load_or_new()
	# Field-by-field with casts rather than a verbatim dict compare: the profile round-trips
	# through JSON, which has no integer type, so every int comes back as a float (7 -> 7.0).
	var back: Dictionary = _save.profile[Save.KEY_RUN]
	assert_eq(String(back["period_key"]), "2026-W1", "period key reloaded")
	assert_eq(String(back["kind"]), "weekly", "kind reloaded")
	assert_eq(int(back["car_instance_id"]), 7, "car instance id reloaded")
	assert_eq(int(back["stage_index"]), 1, "stage index reloaded")
	assert_eq(int((back["stage_times_ms"] as Array)[0]), 1000, "stage times reloaded")
	assert_false(bool(back["dnf"]), "dnf flag reloaded")


func test_clear_run_empties_the_key() -> void:
	_save.set_run({"period_key": "x", "kind": "daily"})
	_save.clear_run()
	assert_eq(_save.profile[Save.KEY_RUN], {}, "cleared back to empty")


# --- Money (todo/roguelike-pivot.md decision 21) -------------------------------
#
# No amounts are asserted — every payout in the game is a GameConfig tunable. What is
# pinned is the LEDGER's behaviour, which must hold whatever those numbers are.

func test_money_accumulates_and_survives_a_reload() -> void:
	# A known baseline, set explicitly rather than assumed: a fresh profile is no longer
	# broke (decision 28 — it starts with GameConfig.run_starting_money so the shop is
	# reachable), so "starts at 0" is a setup step here, not an assertion about defaults.
	_save.profile[_save.KEY_MONEY] = 0
	assert_eq(_save.add_money(120), 120, "banking returns the new balance")
	@warning_ignore("return_value_discarded")
	_save.add_money(30)
	_save.save_now()
	_save.profile = {}
	_save.load_or_new()
	assert_eq(_save.money(), 150, "the balance round-trips through the save file")


func test_banking_a_non_positive_amount_never_moves_the_balance() -> void:
	var before: int = _save.money()
	@warning_ignore("return_value_discarded")
	_save.add_money(50)
	var after_deposit: int = _save.money()
	assert_eq(after_deposit, before + 50, "setup: a positive deposit lands")
	@warning_ignore("return_value_discarded")
	_save.add_money(0)
	@warning_ignore("return_value_discarded")
	_save.add_money(-999)
	assert_eq(_save.money(), after_deposit, "add_money only ever adds — there is no lose_money")


func test_an_unaffordable_purchase_is_refused_rather_than_going_negative() -> void:
	# A known baseline (decision 28 means a fresh profile is no longer broke by default).
	_save.profile[_save.KEY_MONEY] = 100
	assert_false(_save.spend_money(101), "the purchase is refused")
	assert_eq(_save.money(), 100, "and nothing is half-spent")
	assert_true(_save.spend_money(100), "an affordable purchase goes through")
	assert_eq(_save.money(), 0, "…debiting exactly its price")


func test_set_challenge_results_replaces_the_whole_map() -> void:
	_save.set_challenge_results({"2026-D1": {"kind": "daily", "dnf": false, "cumulative_ms": 500}})
	_save.save_now()
	_save.profile = {}
	_save.load_or_new()
	assert_eq(_save.profile["challenge_results"].keys(), ["2026-D1"], "the map round-trips")
	# A later call REPLACES rather than merges — this is how RunSession's
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


# --- The meta shop: buying a car (todo/roguelike-pivot.md decision 28) -----------

func test_buy_car_spends_its_listed_cost_and_grants_it() -> void:
	var cost := int(CarLibrary.by_id("fx_awd")["cost"])
	_save.profile[_save.KEY_MONEY] = cost
	assert_false(_save.owns_model("fx_awd"), "setup: not owned yet")
	assert_true(_save.buy_car("fx_awd"), "an affordable purchase goes through")
	assert_true(_save.owns_model("fx_awd"), "the car is now owned")
	assert_eq(_save.money(), 0, "exactly its listed cost was spent — no more, no less")


func test_buy_car_refuses_when_unaffordable_and_changes_nothing() -> void:
	var cost := int(CarLibrary.by_id("fx_awd")["cost"])
	_save.profile[_save.KEY_MONEY] = cost - 1
	var before: Dictionary = _save.profile.duplicate(true)
	assert_false(_save.buy_car("fx_awd"), "one short of the price is refused")
	assert_eq(_save.profile, before, "a refused purchase leaves the profile untouched")


func test_buy_car_refuses_a_model_already_owned() -> void:
	_save.grant_car("fx_awd")
	_save.profile[_save.KEY_MONEY] = int(CarLibrary.by_id("fx_awd")["cost"]) * 10
	var before: Dictionary = _save.profile.duplicate(true)
	assert_false(_save.buy_car("fx_awd"), "buying a car already owned is refused")
	assert_eq(_save.profile, before, "nothing changes — no duplicate grant, no money spent")


func test_buy_car_refuses_an_unknown_model() -> void:
	_save.profile[_save.KEY_MONEY] = 999999
	var before: Dictionary = _save.profile.duplicate(true)
	assert_false(_save.buy_car("not_a_real_car"), "an unknown model id is refused")
	assert_eq(_save.profile, before, "nothing changes")


# --- The meta shop: boost levels (todo/roguelike-pivot.md decision 42) -----------

func test_buy_boost_level_spends_the_listed_price_and_raises_the_level() -> void:
	_save.profile[_save.KEY_MONEY] = _save.boost_level_price("grip")
	assert_eq(_save.boost_level("grip"), 0, "setup: level 0")
	assert_true(_save.buy_boost_level("grip"), "an affordable purchase goes through")
	assert_eq(_save.boost_level("grip"), 1, "the level increments by exactly one")
	assert_eq(_save.money(), 0, "exactly the listed price was spent")


func test_boost_level_price_rises_with_level() -> void:
	# The relationship only (CLAUDE.md forbids pinning the growth curve's numbers): buying
	# a level must never make the NEXT one cheaper or free.
	var price_at_0: int = _save.boost_level_price("grip")
	_save.profile[_save.KEY_MONEY] = price_at_0
	assert_true(_save.buy_boost_level("grip"), "setup: level 1 bought")
	var price_at_1: int = _save.boost_level_price("grip")
	assert_gte(price_at_1, price_at_0, "the ladder never gets cheaper going up")


func test_buy_boost_level_refuses_when_unaffordable_and_changes_nothing() -> void:
	_save.profile[_save.KEY_MONEY] = _save.boost_level_price("grip") - 1
	var before: Dictionary = _save.profile.duplicate(true)
	assert_false(_save.buy_boost_level("grip"), "one short of the price is refused")
	assert_eq(_save.profile, before, "a refused purchase leaves the profile untouched")


func test_buy_boost_level_refuses_an_unknown_id() -> void:
	_save.profile[_save.KEY_MONEY] = 999999
	var before: Dictionary = _save.profile.duplicate(true)
	assert_false(_save.buy_boost_level("not_a_real_boost"), "an unknown boost id is refused")
	assert_eq(_save.profile, before, "nothing changes")


func test_buy_boost_level_refuses_once_the_level_is_at_the_cap() -> void:
	var max_level := int(Config.data.boost_level_max)
	_save.profile[_save.KEY_BOOST_LEVELS] = {"grip": max_level}
	_save.profile[_save.KEY_MONEY] = 999999999
	var before: Dictionary = _save.profile.duplicate(true)
	assert_false(_save.buy_boost_level("grip"), "a level already at the cap cannot be bought again")
	assert_eq(_save.profile, before, "nothing changes — money included")


# --- Rally completion records: DELETED with the HQ map (nothing writes or reads a
# rally record any more — region runs keep their own KEY_REGIONS_CLEARED ledger, and
# the dev 3-star cheat is gone with the map it lit). The idempotent-best-time, DNF-guard
# and best-placement tests went with the record.


func test_damage_past_zero_keeps_the_car_and_its_bent_wheels() -> void:
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")
	var id := int(car["instance_id"])
	_save.set_wheel_toe(id, [0.05, -0.03, 0.0, 0.0])

	_save.apply_damage(id, 999999.0)  # far past zero
	# 0 HP is a STATE, not an event: nothing is removed, reset, or handed back at part
	# health. The car sits at exactly 0 and stays fully owned.
	assert_eq(_save.profile["cars"].size(), 1, "the car is kept")
	assert_eq(float(_save.get_car(id)["hp"]), 0.0, "HP clamps at exactly zero, never negative")
	# car_needs_repair() was asserted here too; it is deleted with the paid garage repair
	# (todo/roguelike-pivot.md decision 21) — see the "Star sinks" block comment further down.
	assert_eq(_save.get_car(id)["wheel_toe"], [0.05, -0.03, 0.0, 0.0],
		"and its stored wheel_toe is untouched — no hidden restore")


# heal_car — the OTHER way HP climbs back (RunSession.report_event_result routes a stage
# that ended with a net heal here; the "self_healing" skill, todo/roguelike-pivot.md
# decision 51). Caps at the car's authored max_hp and refuses a non-positive amount.
func test_heal_car_gives_hp_back_and_caps_at_max() -> void:
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")
	var id := int(car["instance_id"])
	var max_hp := float(_save.get_car(id)["hp"])  # a fresh car is fielded at full HP
	_save.apply_damage(id, 500.0)
	var damaged := float(_save.get_car(id)["hp"])
	_save.heal_car(id, 200.0)
	assert_almost_eq(float(_save.get_car(id)["hp"]), damaged + 200.0, 0.001)
	_save.heal_car(id, 999999.0)
	assert_almost_eq(float(_save.get_car(id)["hp"]), max_hp, 0.001,
		"healing never pushes a car past its authored max_hp")


func test_heal_car_ignores_a_non_positive_amount() -> void:
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")
	var id := int(car["instance_id"])
	_save.apply_damage(id, 500.0)
	var damaged := float(_save.get_car(id)["hp"])
	_save.heal_car(id, 0.0)
	_save.heal_car(id, -100.0)
	assert_eq(float(_save.get_car(id)["hp"]), damaged,
		"heal_car is not a back door into apply_damage")


# restore_car_to_full — the ONLY other writer besides grant_car that sets hp to max_hp.
# Used by RunSession.begin() so a new run always starts at 100% health.
func test_restore_car_to_full_heals_a_damaged_car_to_max_hp() -> void:
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")
	var id := int(car["instance_id"])
	var max_hp := float(_save.get_car(id)["hp"])
	_save.apply_damage(id, 500.0)
	assert_lt(float(_save.get_car(id)["hp"]), max_hp, "setup: the car is damaged")

	_save.restore_car_to_full(id)

	assert_almost_eq(float(_save.get_car(id)["hp"]), max_hp, 0.001,
		"a full restore brings a damaged car back to its authored max_hp")


func test_restore_car_to_full_changes_nothing_on_an_already_full_car() -> void:
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")
	var id := int(car["instance_id"])
	var max_hp := float(_save.get_car(id)["hp"])

	_save.restore_car_to_full(id)

	assert_almost_eq(float(_save.get_car(id)["hp"]), max_hp, 0.001,
		"restoring an already-full car is a no-op on its HP")


func test_car_health_fraction_reflects_current_over_max_hp() -> void:
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")
	var id := int(car["instance_id"])
	assert_almost_eq(_save.car_health_fraction(id), 1.0, 0.001,
		"a freshly granted car is at full health")
	var max_hp := float(_save.get_car(id)["hp"])
	_save.apply_damage(id, max_hp * 0.5)
	assert_almost_eq(_save.car_health_fraction(id), 0.5, 0.01)


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



# test_sanitise_drops_the_retired_repair_kit_from_an_existing_profile: DELETED — the
# whole inventory subsystem is gone, so there is no live consumable to protect and the
# retired-id strip went with it.


func test_migration_backfills_missing_keys() -> void:
	# A correctly-versioned but partial dict gets missing keys filled from default.
	var partial := {"schema_version": _save.SCHEMA_VERSION, "cars": []}
	var migrated: Dictionary = _save._migrate(partial)
	assert_true(migrated.has("boost_levels"), "missing boost ladder backfilled")
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


# --- Drivetrain conversion: no longer a money sink ---------------------------------
#
# Decision 52 (a per-car purchase, Save.buy_drive_mode) is superseded: a conversion is now
# a run-scoped mid-run upgrade picked between stages (RunSession.choose_drivetrain), so
# there is nothing left to buy or persist on the profile — see
# tests/headless/test_run_session.gd for the coverage that replaces this block.

func test_drivetrain_override_defaults_for_legacy_car() -> void:
	# A car dict without the key (an older save) reads as stock via .get default.
	var legacy := {"instance_id": 1, "model_id": "x", "installed_upgrades": [], "disabled_upgrades": []}
	assert_eq(int(legacy.get("drivetrain_override", -1)), -1, "missing key reads as stock")


# --- Selected car: DELETED with the garage lift (nothing selects a car any more —
# the hub fields whichever car the player confirms; RunSession holds the run's own car).


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


# --- New-rally reveal: DELETED with the HQ map (no reveal parade exists to
# acknowledge; the seeding tests went with _seed_reveals_if_needed).


func test_a_fresh_profile_declares_the_run_meta_block() -> void:
	var p: Dictionary = _save._default_profile()
	# Shapes, not values: a designer may change the starting purse freely.
	assert_true(p.has(_save.KEY_MONEY), "money is declared")
	assert_typeof(p[_save.KEY_REGIONS_CLEARED], TYPE_ARRAY, "regions_cleared is a list of ids")
	assert_typeof(p[_save.KEY_BOOST_LEVELS], TYPE_DICTIONARY, "boost_levels maps id -> level")
	assert_typeof(p[_save.KEY_BOUGHT_SKILLS], TYPE_ARRAY, "bought_skills is a list of ids")
	assert_typeof(p[_save.KEY_EQUIPPED_SKILLS], TYPE_ARRAY, "equipped_skills is a list of ids")
	assert_typeof(p[_save.KEY_LIFETIME], TYPE_DICTIONARY, "lifetime maps stat -> total")


func test_the_run_meta_block_round_trips_through_a_save_and_load() -> void:
	# The point of the block is that it OUTLIVES things. A value that does not survive a
	# save/load cannot survive a failed run either.
	_save.profile[_save.KEY_MONEY] = 1234
	_save.profile[_save.KEY_REGIONS_CLEARED] = ["home"]
	_save.profile[_save.KEY_BOOST_LEVELS] = {"engine": 2}
	_save.profile[_save.KEY_BOUGHT_SKILLS] = ["fx_skill"]
	_save.profile[_save.KEY_EQUIPPED_SKILLS] = ["fx_skill"]
	_save.profile[_save.KEY_LIFETIME] = {"stages_cleared": 7}
	_save.save_now()
	_save.load_or_new()

	assert_eq(int(_save.profile[_save.KEY_MONEY]), 1234, "money survives")
	assert_eq(_save.profile[_save.KEY_REGIONS_CLEARED], ["home"], "cleared regions survive")
	assert_eq(int((_save.profile[_save.KEY_BOOST_LEVELS] as Dictionary)["engine"]), 2,
		"purchased boost levels survive")
	assert_eq(_save.profile[_save.KEY_BOUGHT_SKILLS], ["fx_skill"], "bought skills survive")
	assert_eq(_save.profile[_save.KEY_EQUIPPED_SKILLS], ["fx_skill"], "equipped skills survive")
	assert_eq(int((_save.profile[_save.KEY_LIFETIME] as Dictionary)["stages_cleared"]), 7,
		"lifetime stats survive")


# --- Skills (todo/roguelike-pivot.md "Skills — a straight lift from RR") ----------
# Save-level purchase/equip mutators. The state-machine contract (locked/purchasable/
# owned, the equip cap) belongs to test_skill_library.gd; this file only pins the
# "a refused purchase leaves the profile byte-identical" rule every meta-shop
# purchase shares (see the engine-swap-unlock tests just above).

const _FX_PERK_ID := "fx_save_manager_skill"
const _FX_SKILLS: Array[Dictionary] = [
	{
		"id": _FX_PERK_ID, "label": "Fixture Skill", "price": 500,
		"unlock": {"stat": "fx_stat", "threshold": 3},
	},
]


func test_buy_skill_refuses_while_locked_and_changes_nothing() -> void:
	SkillLibrary.override_for_test(_FX_SKILLS)
	_save.profile[_save.KEY_LIFETIME] = {"fx_stat": 0}
	_save.profile[_save.KEY_MONEY] = 999999
	var before: Dictionary = _save.profile.duplicate(true)
	assert_false(_save.buy_skill(_FX_PERK_ID), "below its threshold — refused")
	assert_eq(_save.profile, before, "a refused purchase leaves the profile untouched")
	SkillLibrary.reset()


func test_buy_skill_succeeds_once_unlocked_and_affordable() -> void:
	SkillLibrary.override_for_test(_FX_SKILLS)
	_save.profile[_save.KEY_LIFETIME] = {"fx_stat": 3}
	_save.profile[_save.KEY_MONEY] = 500
	assert_true(_save.buy_skill(_FX_PERK_ID), "unlocked and affordable")
	assert_true(_save.owns_skill(_FX_PERK_ID))
	assert_eq(_save.money(), 0, "the price is fully spent")
	SkillLibrary.reset()


func test_equip_skill_refuses_past_the_config_cap_and_changes_nothing() -> void:
	var cap := int(Config.data.skill_max_equipped)
	var extra: Array[Dictionary] = []
	for i in cap + 1:
		extra.append({"id": "fx_cap_%d" % i, "label": "Fixture %d" % i, "price": 0,
			"unlock": {"stat": "fx_stat", "threshold": 0}})
	SkillLibrary.override_for_test(extra)
	_save.profile[_save.KEY_LIFETIME] = {"fx_stat": 1}
	for i in cap:
		_save.buy_skill("fx_cap_%d" % i)
		assert_true(_save.equip_skill("fx_cap_%d" % i), "setup: filling the cap")
	_save.buy_skill("fx_cap_%d" % cap)
	var before: Dictionary = _save.profile.duplicate(true)
	assert_false(_save.equip_skill("fx_cap_%d" % cap), "the cap refuses one more")
	assert_eq(_save.profile, before, "a refused equip leaves the profile untouched")
	SkillLibrary.reset()


# The dev cheat behind Settings → Dev → "Unlock all skills": ownership of every
# catalogue entry at once, bypassing the unlock threshold — and IDEMPOTENT, so a
# second press grants (and writes) nothing.
func test_dev_grant_all_skills_is_idempotent() -> void:
	SkillLibrary.override_for_test(_FX_SKILLS)
	# Below its unlock threshold on purpose: the cheat must not care.
	_save.profile[_save.KEY_LIFETIME] = {"fx_stat": 0}
	_save.profile[_save.KEY_MONEY] = 700
	assert_eq(_save.dev_grant_all_skills(), _FX_SKILLS.size(),
		"every catalogue entry is granted")
	assert_true(_save.owns_skill(_FX_PERK_ID), "ownership lands despite the lock")
	assert_eq(_save.money(), 700, "the grant moves no money")
	assert_eq((_save.profile[_save.KEY_EQUIPPED_SKILLS] as Array).size(), 0,
		"equipping stays the Skills page's own step")
	var settled: Dictionary = _save.profile.duplicate(true)
	assert_eq(_save.dev_grant_all_skills(), 0, "a second call grants nothing")
	assert_eq(_save.profile, settled, "and writes nothing doing it")
	SkillLibrary.reset()


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
