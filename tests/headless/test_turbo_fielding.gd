extends GutTest
# Fielding-pipeline regression: a turbo fitted as an UPGRADE to a naturally-
# aspirated car must be AUDIBLE. The engine-audio synth caches its voicing when
# it is (re)built, so apply_owned has to rebuild it AFTER UpgradeLibrary.apply
# writes the turbo's whistle/BOV gains onto the config — otherwise the synth keeps
# the NA (gain 0) voicing and the turbo is silent even though its physics runs.
# Uses the synthetic CarFixtures roster (its cars are NA) + the real turbo upgrade.

const SceneHelpers = preload("res://tests/headless/scene_helpers.gd")
const CarFixtures = preload("res://tests/headless/car_fixtures.gd")

var _scene: Node3D


func before_each() -> void:
	SceneHelpers.minimal_world()
	CarFixtures.install()
	_scene = load("res://main.tscn").instantiate()
	add_child_autofree(_scene)


func after_each() -> void:
	CarFixtures.restore()
	Config.reset()


func test_turbo_upgrade_on_na_car_reconfigures_audio() -> void:
	var car: VehicleBody3D = _scene.get_node("Car")
	var audio := car.get_node("EngineAudio")
	# Field a fixture (NA) car with a big-turbo upgrade fitted.
	var owned := {"model_id": "fx_light_rwd", "installed_upgrades": ["turbo_large"], "disabled_upgrades": []}
	car.apply_owned(owned)
	# The upgrade path ran and enabled the turbo on the live config.
	assert_true(Config.data.turbo_enabled, "the turbo upgrade enables the turbo on an NA car")
	# The audio synth must be REBUILT after the upgrade, so its cached whistle gain
	# matches the config's (the bug left the synth on the stale NA gain of 0). Compare
	# synth-to-config rather than a pinned number, so no tuned value is asserted.
	assert_eq(audio._synth._turbo_whistle_gain, Config.data.engine_turbo_whistle_gain,
		"the engine voice is rebuilt after upgrades, so a turbo fitted to an NA car is audible")
