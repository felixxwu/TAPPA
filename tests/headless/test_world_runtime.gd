extends GutTest
# The world host's runtime helpers (`scripts/world_runtime.gd`): the loading frame cap and the
# shader warm-up point. No tunable is asserted and no scene is instantiated.


# --- Loading frame cap -------------------------------------------------------------------

# The branch, not the number: touch/web and non-touch take the two different fields. Asserted
# against the fields themselves so retuning either cap cannot break this test.
func test_loading_cap_picks_the_touch_cap_only_for_touch() -> void:
	assert_eq(WorldRuntime.loading_cap(true), Config.data.loading_touch_max_fps,
		"touch/web takes the bounded loading cap")
	assert_eq(WorldRuntime.loading_cap(false), Config.data.loading_max_fps,
		"desktop/native takes the non-touch loading cap")


# The INTENT is recorded on every path, in order — which is what both hosts' `applied_fps_caps`
# arrays (and the tests that read them) depend on.
func test_apply_fps_cap_records_every_cap_in_order() -> void:
	var caps: Array[int] = []
	WorldRuntime.apply_fps_cap(caps, 41, true)
	WorldRuntime.apply_fps_cap(caps, 0, true)
	assert_eq(caps.size(), 2, "both caps recorded")
	assert_eq(caps[0], 41, "the first cap applied is recorded first")
	assert_eq(caps[1], 0, "and the second (0 = uncapped) second")


# The headless guard. Writing Engine.max_fps under --headless would throttle the frame-awaiting
# test runner, so the write must be suppressed while the intent is still recorded.
func test_apply_fps_cap_never_writes_the_engine_under_headless() -> void:
	var before := Engine.max_fps
	var caps: Array[int] = []
	WorldRuntime.apply_fps_cap(caps, before + 7, true)
	assert_eq(Engine.max_fps, before, "Engine.max_fps untouched under headless")
	assert_eq(caps.size(), 1, "the intent was still recorded")


# --- Shader warm-up point ----------------------------------------------------------------

# ~2 m in FRONT of the camera (a Node3D's forward is -Z), which is what puts a warm-up instance
# inside the frustum so it actually draws and compiles its shader.
func test_warm_up_point_sits_in_front_of_the_camera() -> void:
	var cam := Camera3D.new()
	add_child_autofree(cam)
	cam.global_position = Vector3(10.0, 3.0, -4.0)
	cam.look_at_from_position(cam.global_position, cam.global_position + Vector3(0.0, 0.0, -1.0),
		Vector3.UP)
	var point := WorldRuntime.warm_up_point(cam, Vector3(999.0, 999.0, 999.0))
	assert_almost_eq(point.distance_to(cam.global_position), 2.0, 1e-3,
		"two metres from the camera")
	var forward := -cam.global_transform.basis.z
	assert_gt((point - cam.global_position).normalized().dot(forward), 0.99,
		"and in front of it, not behind")


# No camera up yet: the caller's own fallback is returned untouched.
func test_warm_up_point_returns_the_callers_fallback_without_a_camera() -> void:
	var fallback := Vector3(1.0, 2.0, 3.0)
	assert_eq(WorldRuntime.warm_up_point(null, fallback), fallback,
		"the host's own fallback wins when no camera exists")
