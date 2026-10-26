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


# --- Money (todo/roguelike-pivot.md decision 21) -------------------------------
#
# No amounts are asserted — every payout in the game is a GameConfig tunable. What is
# pinned is the LEDGER's behaviour, which must hold whatever those numbers are.

func test_debounce_timer_keeps_running_while_tree_paused() -> void:
	# pause_menu.gd holds get_tree().paused = true for as long as the pause
	# overlay is open. A debounce timer left at the default PROCESS_MODE_PAUSABLE
	# would silently stop advancing for that whole window instead of ~1s, so a
	# mutation made just before/during a paused menu would sit unsaved until the
	# menu closes — a crash/force-quit in that window then loses it. The timer
	# must therefore always process regardless of tree pause.
	assert_eq(_save._debounce.process_mode, Node.PROCESS_MODE_ALWAYS,
		"debounced save must still tick down while the game is paused")


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

# --- The meta shop: boost levels (todo/roguelike-pivot.md decision 42) -----------

func test_sanitise_backfills_wheel_toe_on_old_saves() -> void:
	# A pre-feature owned car has no wheel_toe key; load must backfill it straight.
	_save.profile["cars"] = [{
		"instance_id": 7, "model_id": "fx_light_rwd", "hp": 500.0,
		"installed_upgrades": [], "disabled_upgrades": [], "tuning": {},
	}]
	_save.profile = _save._sanitise(_save.profile)
	assert_eq(_save.profile["cars"][0]["wheel_toe"], [0.0, 0.0, 0.0, 0.0], "backfilled straight")


func _rng(seed_value: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed_value
	return r


func test_migration_refuses_newer_version() -> void:
	var future: Dictionary = _save._default_profile()
	future["schema_version"] = _save.SCHEMA_VERSION + 1
	assert_true(_save._migrate(future).is_empty(), "a newer-version profile is refused (returns empty)")


# Regression: load_or_new() used to set save_disabled = true whenever the on-disk profile
# was refused (wrong/older schema_version — exactly the state of EVERY pre-pivot save on
# its first post-pivot launch). That flag blocks every future save()/save_now(), so the
# fresh profile this branch hands the player could never actually reach disk: buy a car,
# finish a run, all session — nothing saved, and the same stale file would refuse again on
# the very next launch. This is the "runs and cars bought are still not saved properly"
# bug reported after the pivot. Pins that a refused load leaves saving enabled and a real
# write actually lands.
func test_a_refused_pre_pivot_profile_can_still_save_new_progress() -> void:
	var f := FileAccess.open(TEST_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify({"schema_version": _save.SCHEMA_VERSION - 1, "cars": []}))
	f.close()
	_save.load_or_new()
	assert_eq(_save.profile["cars"].size(), 0, "refused profile replaced with a fresh default")
	assert_false(_save.save_disabled, "saving is NOT disabled just because the old file was refused")
	_save.grant_car("fx_light_rwd")
	_save.save_now()
	var on_disk: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TEST_PATH))
	assert_eq((on_disk["cars"] as Array).size(), 1,
		"the new car actually reached disk, superseding the refused pre-pivot file")


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
	assert_true(migrated.has(_save.KEY_WORLD), "missing world block backfilled")
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
		+ "See the `cloud_revision` comment for the shape to copy.")


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
