extends GutTest
# world.gd's frame-cap lifecycle (todo/mobile-web-performance.md §1.1). Generation
# yields hundreds of frames, and a low cap paces every one of them, so _ready applies a
# transient LOADING cap first and the real cap only once generation is done.
#
# These tests assert the INTENT recorded in world.gd's `applied_fps_caps`, never a
# literal cap value: every cap here (the loading const, the resolver's answer) is a
# tunable, and the point is that a cap is applied at all and that the FINAL one is
# whatever the resolver chose for that mode — not what number that happens to be.
# Engine.max_fps itself is deliberately not written under --headless (it would throttle
# the frame-awaiting runner), which is the other reason to assert on the record.

var _scene: Node3D


func _boot() -> Array:
	SceneTestHelpers.minimal_world()
	_scene = load("res://main.tscn").instantiate()
	add_child(_scene)
	await get_tree().physics_frame  # let _ready() run
	return _scene.applied_fps_caps


func after_each() -> void:
	if _scene != null:
		_scene.free()
		_scene = null
	Benchmark.active = false
	Config.reset()


func test_a_loading_cap_is_applied_before_the_final_one() -> void:
	# Guards against the post-load cap being applied somewhere that can early-return
	# (e.g. inside _end_load_timing) — that would leave the loading cap, possibly
	# uncapped, in force for the whole session, cooking the player's phone.
	var caps: Array = await _boot()
	assert_eq(caps.size(), 2, "one loading cap, then one post-load cap on every path")


func test_post_load_cap_is_the_resolver_s_choice() -> void:
	var caps: Array = await _boot()
	assert_eq(caps[caps.size() - 1], FpsSetting.resolve(),
		"the cap left in place after loading is whatever FpsSetting.resolve() selects")


func test_benchmark_never_sees_a_transient_loading_cap() -> void:
	# benchmark_mode.gd snapshots Engine.max_fps to restore on exit, so a transient
	# loading cap must never be applied on that path — it could be what gets captured.
	# Every cap world.gd applies during a benchmark is the benchmark's own resolved cap.
	Benchmark.active = true
	var caps: Array = await _boot()
	for cap in caps:
		assert_eq(cap, FpsSetting.default_cap(),
			"under a benchmark every applied cap is the benchmark's resolved cap")
