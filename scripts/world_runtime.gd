class_name WorldRuntime
extends RefCounted
# Docs: features/loading.md, features/rendering.md
# — update in the same change as this file.
# Tests: tests/headless/test_world_runtime.gd, tests/headless/test_world_fps_cap.gd.
#
# The world-host behaviour LevelView needs: capping the frame rate while the level builds
# behind a loading cover, and pre-warming shaders in front of the camera.
#
# WHY A STATIC HELPER MODULE AND NOT A BASE CLASS: a static module is pure functions over
# arguments the host already holds, unit-testable without instancing the scene, and leaves the
# host free to keep its own node lookups and headless caching. So: static helpers, called from thin
# host wrappers that keep their existing names (the docs and the call sites reference them).


# Frame cap applied for the DURATION of world generation only (see LevelView._ready).
# Loading yields hundreds of frames, and a low cap makes each of those yields idle away most
# of its frame budget instead of generating (verified on the web export: 33.4 ms per awaited
# frame at cap 30 vs 8.3 ms uncapped). Bounded rather than uncapped on touch: running a phone
# flat-out through a long load is the thermal/battery failure this is meant to avoid, and a
# throttled phone then plays worse. 0 = uncapped.
# Authored in scripts/game_config.gd as `loading_max_fps` / `loading_touch_max_fps`.


## The loading-window frame cap for this platform. `touch` covers touch/web.
##
## Called ONCE per world boot (LevelView._ready), not per frame, so it reads the config here
## rather than caching — the cap it returns is then held for the whole load window.
static func loading_cap(touch: bool) -> int:
	return Config.data.loading_touch_max_fps if touch else Config.data.loading_max_fps


## Apply a frame cap and record the intent in `caps`. The Engine write is suppressed under
## --headless (nothing to pace, and it would throttle the frame-awaiting test runner), but the
## intent is recorded on EVERY path so tests can assert it without reading Engine.max_fps.
static func apply_fps_cap(caps: Array[int], cap: int, headless: bool) -> void:
	caps.append(cap)
	if not headless:
		Engine.max_fps = cap


## A point ~2 m in front of the active camera — where a warm-up instance is guaranteed to sit
## inside the frustum (so it actually draws and compiles its shader). `fallback` is what the
## caller wants when no camera is up yet (LevelView uses the car), so the
## fallback stays at the call site rather than being guessed here.
static func warm_up_point(cam: Camera3D, fallback: Vector3) -> Vector3:
	if cam != null:
		return cam.global_position - cam.global_transform.basis.z * 2.0
	return fallback


## A throwaway camera turns full circle above `centre`, then looks down from high up, so everything
## loaded around it draws once and its shaders compile behind the loading cover. The caller then
## hands the view back to its own camera.
static func look_around(host: Node, centre: Vector3) -> void:
	var tree := host.get_tree()
	var cam := Camera3D.new()
	cam.far = 400.0
	host.add_child(cam)
	cam.make_current()
	for k in 9:
		var eye := centre + Vector3(0.0, 3.0, 0.0)
		var dir := Vector3(sin(k * TAU / 8.0), -0.1, cos(k * TAU / 8.0)) if k < 8 else Vector3(0.0, -1.0, 0.01)
		if k == 8:
			eye = centre + Vector3(0.0, 120.0, 0.0)
		cam.look_at_from_position(eye, eye + dir, Vector3.UP)
		await tree.process_frame
		await tree.process_frame
		if not is_instance_valid(host):
			return  # the scene closed mid-spin
	cam.queue_free()
