extends GutTest
# Per-car config isolation (scripts/car.gd `config` / use_isolated_config).
#
# Config.data is a single global GameConfig. The active/player car reshapes it in
# place so the HUD/tuning/audio/save all see the fielded car. But NON-simulating prop
# cars (HQ car-park lineup, start-line queue, podium display) also call apply_car —
# and before per-car config that clobbered the active car's engine/gearbox in the
# shared global, leaving the player car running on stale/default torque. These tests
# pin the INVARIANT (a prop's apply can't touch the active car's config), not any
# authored value.

const CAR_SCENE := preload("res://car.tscn")


func before_each() -> void:
	Config.reset()
	CarFixtures.install()


func after_each() -> void:
	CarFixtures.restore()


func _fresh_car() -> Node:
	var car := CAR_SCENE.instantiate()
	add_child_autofree(car)
	await get_tree().physics_frame  # let _ready() run (builds drivetrain, sets config)
	return car


func test_active_car_uses_shared_global_config() -> void:
	var player := await _fresh_car()
	assert_eq(player.config, Config.data,
		"a car with no isolated config drives the shared global Config.data")


func test_isolated_config_is_a_separate_object() -> void:
	var prop := await _fresh_car()
	prop.use_isolated_config()
	assert_ne(prop.config, Config.data, "an isolated prop config is its own object")
	# Mutating the isolated copy must never leak into the global.
	var before: float = Config.data.peak_torque
	prop.config.peak_torque = before + 500.0
	assert_eq(Config.data.peak_torque, before,
		"writing an isolated prop's config leaves the global untouched")


func test_prop_apply_does_not_clobber_active_cars_engine() -> void:
	# Active car applies some car and owns the global config.
	var player := await _fresh_car()
	player.apply_car(CarLibrary.index_of("fx_rwd_coupe"))
	var active_torque: float = Config.data.peak_torque
	var active_final: float = Config.data.final_drive

	# A prop car with an isolated config then applies a DIFFERENT car.
	var prop := await _fresh_car()
	prop.use_isolated_config()
	prop.apply_car(CarLibrary.index_of("fx_light_rwd"))

	# The global (active car's) engine/gearbox must be exactly as the active car
	# left it — the prop's reshape landed on its own copy.
	assert_eq(Config.data.peak_torque, active_torque,
		"prop apply must not change the active car's torque in the global config")
	assert_eq(Config.data.final_drive, active_final,
		"prop apply must not change the active car's gearing in the global config")
	# And the prop's own config really did take its own car's engine (logic, not a
	# pinned number: compare against the EngineLibrary source it copies from).
	var prop_engine := EngineLibrary.by_id(CarLibrary.by_id("fx_light_rwd")["engine"])
	assert_eq(prop.config.peak_torque, prop_engine["peak_torque"],
		"prop config carries its own engine's torque")


# VALUE SNAPSHOTS (GameConfig.snapshot_values / restore_values) — how code saves and restores
# the live config around a mutation WITHOUT swapping the object out from under the car that
# holds it. Two properties matter, and both are the reason `duplicate(true)` + reassignment
# is not an acceptable substitute (see the note in game_config.gd).

func test_snapshot_captures_the_non_exported_live_engine_fields() -> void:
	# The LIVE engine fields are plain non-@export vars, so Resource.duplicate() resets them
	# to their declared defaults. A round-trip through the snapshot must not.
	var cfg: GameConfig = Config.data
	cfg.peak_torque = 333.0   # sentinels, not tuning: the point is that they survive
	cfg.redline_rpm = 7777.0
	var snap := cfg.snapshot_values()
	cfg.peak_torque = 1.0
	cfg.redline_rpm = 2.0
	cfg.restore_values(snap)
	assert_almost_eq(cfg.peak_torque, 333.0, 0.001, "a non-exported live field round-trips")
	assert_almost_eq(cfg.redline_rpm, 7777.0, 0.001, "…and so does the redline beside it")
	# Sanity check on the premise, so this test can't quietly stop testing anything: the
	# duplicate() path really does lose them.
	assert_ne(cfg.duplicate(true).peak_torque, 333.0,
		"premise: duplicate() resets the non-exported live fields, which is why the dict exists")


func test_restore_writes_in_place_and_shares_no_mutable_state() -> void:
	var cfg: GameConfig = Config.data
	var snap := cfg.snapshot_values()
	cfg.restore_values(snap)
	assert_same(Config.data, cfg,
		"restoring values must not replace the object the car/HUD/audio hold by reference")
	# Containers are deep-copied both ways, so a later write to the live config can't
	# reach back into the snapshot (or vice versa).
	var before: int = cfg.engine_firing_angles.size()
	cfg.engine_firing_angles.append(90.0)
	cfg.restore_values(snap)
	assert_eq(cfg.engine_firing_angles.size(), before,
		"the restore undoes a container edit rather than sharing the array with the snapshot")


# HOT RELOAD (Config.reload_from_disk) — the tuning loop for world-space menu placement: retune a
# value on game_config.tres in the inspector, press F8 in the running game, see it.
#
# The bug this guards is subtle and was the reason the feature didn't work at first: `load()` returns
# the CACHED resource, so reset() re-duplicates the copy read at boot however many times it is
# called and a disk edit is invisible. Only CACHE_MODE_REPLACE goes back to the file. That is not
# directly observable without editing a file mid-test, so what IS asserted is the two things that
# must hold for it to be capable of working at all: it succeeds, and it installs a FRESH instance
# rather than handing back the object already in use.
func test_reload_from_disk_swaps_in_a_fresh_config() -> void:
	var before: GameConfig = Config.data
	# A runtime mutation of the kind the game makes (car.gd's apply_car reshapes the live config).
	# A real re-read must not preserve it — that is the difference between reloading and no-op.
	before.hq_tree_count = 12345

	assert_true(Config.reload_from_disk(), "the authored config re-reads from disk")
	assert_ne(Config.data, before, "reload installs a NEW GameConfig, not the one already in use")
	assert_ne(Config.data.hq_tree_count, 12345,
		"a re-read drops runtime mutations — otherwise nothing was actually re-read")


# The key that drives it. Debug-build-only in hq.gd, but the ACTION has to exist or the handler is
# dead code (the same reasoning as test_menu_nav's gamepad-button guard).
func test_the_config_hot_reload_action_exists() -> void:
	assert_true(InputMap.has_action("reload_config"),
		"F8 hot-reload needs its input action in project.godot")


# --- Cross-FILE config hygiene ------------------------------------------------------------
#
# Config.data is a single global that outlives the script that mutated it, so a file which
# swaps in a different baseline and never puts the authored one back silently re-tunes every
# LATER file that reads the ambient config. That is an order-dependent failure — green under
# `--fast <one file>`, red in a full run — and it is exactly how test_rest_pose.gd (which has
# no setup hook at all and reads whatever Config.data currently is) ended up settling a car
# against the frozen physics baseline instead of the shipped one.
#
# The convention: any file that installs a non-authored baseline (SceneTestHelpers
# .use_test_config / .minimal_world) hands it back with Config.reset() in its teardown —
# sim_test.gd, test_drivetrain.gd, test_drive_mode.gd and test_car_terrain.gd all do.
#
# These two tests pin the CONTRACT that makes the convention work, with no authored value in
# sight: the swap really does change the global, and reset() really does restore the authored
# baseline field-for-field (whatever a designer has retuned it to).


# Every @export'd field of the live config, as a name -> value dictionary.
func _fields(cfg: GameConfig) -> Dictionary:
	var out := {}
	for p in cfg.get_property_list():
		if int(p["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE and p["name"] != "script":
			out[p["name"]] = cfg.get(p["name"])
	return out


func test_the_frozen_test_baseline_really_differs_from_the_authored_one() -> void:
	# Without this the restore test below could pass vacuously (if the two baselines were the
	# same object or the same values, leaking one would be harmless and nothing is proven).
	Config.reset()
	var authored := _fields(Config.data)
	SceneTestHelpers.use_test_config()
	assert_ne(Config.data, null, "the frozen test baseline installs")
	var differing := 0
	for name in authored:
		if Config.data.get(name) != authored[name]:
			differing += 1
	Config.reset()
	assert_gt(differing, 0,
		"the frozen physics baseline tunes the car DIFFERENTLY from the shipped config — "
		+ "which is why a file that installs it must restore the authored one in teardown")


func test_reset_restores_the_authored_baseline_after_a_swap() -> void:
	# The teardown contract every physics file relies on: whatever a script left in the
	# global, Config.reset() must put the authored baseline back exactly. Compared against a
	# freshly loaded duplicate of the authored resource, so no value is pinned here.
	SceneTestHelpers.use_test_config()
	Config.data.suspension_travel_front = 0.123   # the kind of reshape apply_car leaves behind
	Config.reset()
	var authored := load("res://config/game_config.tres") as GameConfig
	assert_not_null(authored, "the authored config loads")
	var restored := _fields(Config.data)
	var mismatched: Array[String] = []
	for name in _fields(authored):
		if restored.has(name) and restored[name] != authored.get(name):
			mismatched.append(name)
	assert_eq(mismatched, [] as Array[String],
		"reset() restores every authored field — a leftover here is a cross-file config leak")
	assert_ne(Config.data, authored,
		"...into a private DUPLICATE, so a test mutating Config.data cannot poison the cached "
		+ "resource that every later reset() re-duplicates from")
