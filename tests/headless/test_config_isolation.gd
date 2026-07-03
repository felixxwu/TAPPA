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
