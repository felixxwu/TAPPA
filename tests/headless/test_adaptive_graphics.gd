extends GutTest
# AdaptiveGraphics (features/adaptive-graphics.md): the level view's knobs, their authored ceilings,
# the benchmark's fixed look, and what is remembered between sessions and reloads.

const TEST_PATH := "user://test_adaptive_graphics.json"

var _view: LevelView
var _saved_path := ""


func before_each() -> void:
	Config.reset()
	_saved_path = AdaptiveGraphics.save_path
	AdaptiveGraphics.save_path = TEST_PATH
	AdaptiveGraphics.state = {}
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))
	_view = autofree(LevelView.new())


func after_each() -> void:
	_view.perf_stats.free()
	_view.banner.free()
	Benchmark.active = false
	AdaptiveGraphics.save_path = _saved_path
	AdaptiveGraphics.state = {}
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))
	Config.reset()


func _graphics() -> AdaptiveGraphics:
	var ag: AdaptiveGraphics = add_child_autofree(AdaptiveGraphics.new())
	ag.setup(_view)
	return ag


func _knob(ag: AdaptiveGraphics, id: StringName) -> AdaptiveKnob:
	for k in ag.controller.knobs:
		if k.id == id:
			return k
	return null


func test_a_distance_setting_tops_out_at_the_authored_value() -> void:
	var ag := _graphics()
	var trees := _knob(ag, &"trees")
	trees.set_level(0)
	assert_lt(Config.data.level_tree_draw_m, LevelKnobs.authored("level_tree_draw_m"), "lower levels draw less")
	trees.set_level(trees.top())
	assert_eq(Config.data.level_tree_draw_m, LevelKnobs.authored("level_tree_draw_m"))


func test_near_grass_never_reaches_past_far_grass() -> void:
	var ag := _graphics()
	_knob(ag, &"cover_near").set_level(_knob(ag, &"cover_near").top())
	_knob(ag, &"cover_far").set_level(0)
	assert_lte(Config.data.ground_cover_reach, Config.data.ground_cover_far_reach)


func test_benchmark_runs_with_every_setting_at_its_authored_value() -> void:
	Config.data.level_tree_draw_m = 1.0
	Config.data.spectators_enabled = false
	Benchmark.active = true
	var ag := _graphics()
	assert_false(ag.controller.enabled)
	assert_eq(Config.data.level_tree_draw_m, LevelKnobs.authored("level_tree_draw_m"))
	assert_eq(Config.data.spectators_enabled, LevelKnobs.authored("spectators_enabled"))


func test_levels_survive_a_reload_and_a_restart() -> void:
	var ag := _graphics()
	_knob(ag, &"trees").set_level(1)
	ag.save()
	ag.free()
	assert_eq(_knob(_graphics(), &"trees").level, 1, "kept across a reload")
	AdaptiveGraphics.state = {}
	assert_eq(_knob(_graphics(), &"trees").level, 1, "and read back from the file after a restart")


func test_a_corrupt_save_file_starts_fresh() -> void:
	var f := FileAccess.open(TEST_PATH, FileAccess.WRITE)
	f.store_string("{not json")
	f.close()
	assert_eq(AdaptiveGraphics.load_file(TEST_PATH), {})
	var ag := _graphics()
	for k in ag.controller.knobs:
		assert_between(k.level, 0, k.top())


func test_photo_mode_hands_trees_back_to_the_controller_level() -> void:
	var trees := LevelTrees.new()
	add_child_autofree(trees)
	Config.data.level_tree_draw_m = 321.0
	trees.set_draw_override(5000.0)
	trees.set_draw_override(0.0)
	assert_eq(trees.draw_m(), 321.0, "leaving the render goes back to the controller's distance, not the authored one")
