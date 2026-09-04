extends GutTest
# LifetimeStats (scripts/lifetime_stats.gd) — the lifetime-counter registry — plus the
# Save-level persistence it sits on (lifetime_stat / add_lifetime_stat /
# raise_lifetime_stat). Per CLAUDE.md this file asserts LOGIC, not values: nothing here
# pins which stats exist or what any of them are currently worth — only the contract
# every stat must obey (persisted, only ever grows, survives what a failed run wipes)
# and the ratchet's own high-water-mark behaviour.

var _save: Node
var _prev_lifetime: Dictionary = {}


func before_each() -> void:
	_save = Save
	_prev_lifetime = (_save.profile.get(_save.KEY_LIFETIME, {}) as Dictionary).duplicate(true)
	_save.profile[_save.KEY_LIFETIME] = {}


func after_each() -> void:
	_save.profile[_save.KEY_LIFETIME] = _prev_lifetime


# --- The registry's own contract --------------------------------------------------

func test_every_stat_id_is_a_non_empty_string() -> void:
	for id in LifetimeStats.IDS:
		assert_false(String(id).is_empty(), "every declared stat id is non-empty")


func test_every_declared_id_has_a_stats_entry_and_a_label() -> void:
	for id in LifetimeStats.IDS:
		assert_true(LifetimeStats.STATS.has(id), "%s is in IDS but not in STATS" % id)
		assert_false(LifetimeStats.label_for(String(id)).is_empty(),
			"%s resolves to a non-empty label" % id)


func test_is_known_agrees_with_the_stats_table() -> void:
	for id in LifetimeStats.IDS:
		assert_true(LifetimeStats.is_known(String(id)))
	assert_false(LifetimeStats.is_known("fx_not_a_real_stat"))


# --- Save persistence: read/write, only ever grows --------------------------------

func test_an_unset_stat_reads_as_zero() -> void:
	assert_eq(_save.lifetime_stat("fx_stat"), 0)


func test_add_lifetime_stat_accumulates() -> void:
	_save.add_lifetime_stat("fx_stat", 3)
	_save.add_lifetime_stat("fx_stat", 4)
	assert_eq(_save.lifetime_stat("fx_stat"), 7, "repeated adds accumulate")


func test_add_lifetime_stat_defaults_to_one() -> void:
	_save.add_lifetime_stat("fx_stat")
	assert_eq(_save.lifetime_stat("fx_stat"), 1)


func test_add_lifetime_stat_ignores_non_positive_amounts() -> void:
	_save.add_lifetime_stat("fx_stat", 5)
	_save.add_lifetime_stat("fx_stat", 0)
	_save.add_lifetime_stat("fx_stat", -10)
	assert_eq(_save.lifetime_stat("fx_stat"), 5,
		"a non-positive amount never lowers a counter that only ever grows")


func test_add_lifetime_stat_survives_a_save_and_load() -> void:
	var prev_path: String = _save.profile_path
	_save.profile_path = "user://test_lifetime_stats_profile.json"
	# Clearing save_disabled is REQUIRED, not tidiness: an earlier test (in this file or
	# another) can leave it set, and both save() and save_now() no-op silently while it is
	# true — the write vanishes and only the read-back fails, a long way from the cause.
	# test_save_manager.gd's before_each does the same thing for the same reason.
	_save.save_disabled = false
	_save.add_lifetime_stat("fx_stat", 9)
	_save.save_now()
	_save.load_or_new()
	assert_eq(_save.lifetime_stat("fx_stat"), 9, "a lifetime counter survives a reload")
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(_save.profile_path + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(_save.profile_path + suffix))
	_save.profile_path = prev_path
	_save.load_or_new()


# --- The high-water-mark ratchet ----------------------------------------------------

func test_raise_lifetime_stat_ratchets_up_to_the_max() -> void:
	_save.raise_lifetime_stat("fx_best", 3)
	_save.raise_lifetime_stat("fx_best", 7)
	assert_eq(_save.lifetime_stat("fx_best"), 7, "raises to the higher value")


func test_raise_lifetime_stat_never_lowers_the_stored_value() -> void:
	_save.raise_lifetime_stat("fx_best", 7)
	_save.raise_lifetime_stat("fx_best", 2)
	assert_eq(_save.lifetime_stat("fx_best"), 7,
		"a lower value never regresses a high-water mark — a repeat run must not read as new progress")


func test_raise_lifetime_stat_from_zero() -> void:
	_save.raise_lifetime_stat("fx_best", 0)
	assert_eq(_save.lifetime_stat("fx_best"), 0)
	_save.raise_lifetime_stat("fx_best", 1)
	assert_eq(_save.lifetime_stat("fx_best"), 1)
