extends GutTest
# world.gd's replay-leaderboard engine mute. Because engine_audio.gd now writes
# volume_db every frame for proximity attenuation, the leaderboard mute must
# disable the EngineAudio node's processing (not write volume_db, which would be
# overwritten). Asserts process_mode, never a dB value.

const SceneHelpers = preload("res://tests/headless/scene_helpers.gd")

var _scene: Node3D


func before_all() -> void:
	# Boot main.tscn once on a 1-turn / no-foliage track (~15s -> <1s). We only need
	# the World root + its Car/EngineAudio to exercise the leaderboard mute toggle.
	SceneHelpers.minimal_world()
	_scene = load("res://main.tscn").instantiate()
	add_child(_scene)


func after_all() -> void:
	_scene.free()
	Config.reset()


func test_leaderboard_mute_disables_engine_processing() -> void:
	var ea := _scene.get_node("Car").get_node("EngineAudio")
	_scene._on_leaderboard_hidden_changed(false)  # leaderboard shown
	assert_eq(ea.process_mode, Node.PROCESS_MODE_DISABLED, "muted under the leaderboard")
	_scene._on_leaderboard_hidden_changed(true)   # hidden -> watch mode
	assert_ne(ea.process_mode, Node.PROCESS_MODE_DISABLED, "audible in watch mode")
	# Leave it enabled so the shared scene doesn't leak a disabled node.
	_scene._on_leaderboard_hidden_changed(true)
