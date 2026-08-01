extends GutTest
# The live config's waterline must describe the water the terrain ACTUALLY has.
#
# TrackGenParams.recompute_origin is allowed to clamp water_level down — or switch
# water off entirely — when no dry start exists within budget. Only `params` learns
# about that; everything downstream reads the config: the rendered/collided lake
# (world.gd._build_lakes), the loading-screen preview, the chase camera's ground
# seat, the submersion reset in track_progress.gd. So world.gd._generate_track
# reconciles the config to the params it generated with, and this guards that.
#
# No authored value is pinned here: the test floods the world itself and asserts
# only the relationship that must hold for any waterline the generator settles on.

const SceneHelpers = preload("res://tests/headless/scene_helpers.gd")

var _scene: Node3D


func before_each() -> void:
	SceneHelpers.minimal_world()


func after_each() -> void:
	Config.reset()


func test_config_waterline_is_one_the_start_is_not_submerged_under() -> void:
	var cfg: GameConfig = Config.data
	cfg.water_enabled = true
	# Far above any terrain the generator can produce, so no dry origin exists and
	# the clamp/disable fallback is guaranteed to fire.
	cfg.track_water_level_m = 500.0
	_scene = load("res://main.tscn").instantiate()
	add_child_autofree(_scene)
	await get_tree().physics_frame

	var floor_node: Node = null
	for child in _scene.get_children():
		if child.has_method("height_at"):
			floor_node = child
			break
	assert_not_null(floor_node, "the world exposes a terrain to sample")
	var car := _scene.get_node("Car") as Node3D
	var ground: float = floor_node.height_at(car.global_position.x, car.global_position.z)
	# Either resolution is correct — the generator may clamp the level below the start
	# or give up on water entirely — but the pre-clamp 500.0 surviving on the config is
	# not, and that's what leaks a phantom waterline to the lake, preview and camera.
	assert_true(not cfg.water_enabled or cfg.track_water_level_m < ground,
		"the config was reconciled to the generated params: water is either off, or its level sits below the ground at the start (level=%f ground=%f enabled=%s)" \
			% [cfg.track_water_level_m, ground, str(cfg.water_enabled)])
