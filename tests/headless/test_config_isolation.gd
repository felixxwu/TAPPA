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
