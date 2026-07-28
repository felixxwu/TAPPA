extends GutTest
# world.gd's shared "load finished" hook (todo/mobile-web-performance.md).
#
# Subscribers hang load-only frees off this signal (baked terrain light, the
# road/cliff bake dictionaries), so the contract that matters is:
#   1. it fires at all — INCLUDING under headless, which is the trap: the hook
#      must NOT live inside _end_load_timing(), which early-returns when headless
#      or when no stage was recorded;
#   2. it fires exactly once, so a regeneration can't double-free.
#
# Asserts the signal contract only — no timings, no stage labels, no tunables.

const SceneHelpers = preload("res://tests/headless/scene_helpers.gd")

var _scene: Node3D


func before_all() -> void:
	# 1-turn / no-foliage track: we only need _ready() to run to completion.
	SceneHelpers.minimal_world()
	_scene = load("res://main.tscn").instantiate()
	add_child(_scene)


func after_all() -> void:
	_scene.free()
	Config.reset()


func test_load_finished_fired_under_headless() -> void:
	# The whole point of the separate call site: _end_load_timing() bails out under
	# headless, so a hook folded into it would never reach the test runner.
	assert_true(_scene._load_finished,
		"load_finished must fire on the headless path, not just with an overlay up")


func test_load_finished_emits_only_once() -> void:
	var fired := [0]
	_scene.load_finished.connect(func() -> void: fired[0] += 1)
	# Already latched by the boot above, so a second call must be a no-op —
	# subscribers free data that cannot be rebuilt mid-run.
	_scene._on_load_finished()
	_scene._on_load_finished()
	assert_eq(fired[0], 0, "load_finished must not re-emit after the first fire")
