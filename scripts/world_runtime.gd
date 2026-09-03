class_name WorldRuntime
extends RefCounted
# Docs: features/loading.md, features/rendering.md, features/snow-region.md
# — update in the same change as this file.
# Tests: tests/headless/test_world_runtime.gd, tests/headless/test_world_fps_cap.gd.
#
# The behaviour the two WORLD HOSTS share: world.gd (a rally stage) and overworld.gd (the
# free-roam map). Both are Node3D scene roots that build terrain behind a loading cover,
# cap the frame rate for the duration of that build, swap the floor shader for deep snow,
# and pre-warm shaders in front of the camera. Those pieces were byte-for-byte duplicated
# in both files and drifted (a line wrap here, `$Floor` vs a cached accessor there).
#
# WHY A STATIC HELPER MODULE AND NOT A COMMON BASE CLASS:
# a base class is possible — both hosts are Node3D roots — but it would change the
# scene↔script relationship for main.tscn and overworld.tscn (every `extends` swap risks a
# scene-load regression, and the two hosts' _ready bodies are NOT a common sequence, only
# these leaf helpers are). A static module has no such coupling: it is pure functions over
# arguments the hosts already hold, it is unit-testable without instancing either scene, and
# it leaves each host free to keep its own node lookups (`$Floor` vs `_floor()`), its own
# headless caching, and its own divergent fallbacks. So: static helpers, called from thin
# host wrappers that keep their existing names (the docs and the call sites reference them).


# The two terrain shaders the floor material swaps between per stage. The base one is kept
# deliberately free of a vertex stage (terrain is the heaviest geometry in the game and this
# renderer targets low-end phones); the snow variant adds the off-road ground raise the Alps
# need, so only a snow stage pays for it. See apply_deep_snow and
# test_terrain_shader_has_no_vertex_stage.
const TERRAIN_BASE_SHADER := preload("res://shaders/ps1_models.gdshader")
const TERRAIN_SNOW_SHADER := preload("res://shaders/ps1_terrain_snow.gdshader")

# Frame cap applied for the DURATION of world generation only (see each host's _ready).
# Loading yields hundreds of frames, and a low cap makes each of those yields idle away most
# of its frame budget instead of generating (verified on the web export: 33.4 ms per awaited
# frame at cap 30 vs 8.3 ms uncapped). Bounded rather than uncapped on touch: running a phone
# flat-out through a long load is the thermal/battery failure this is meant to avoid, and a
# throttled phone then plays worse. 0 = uncapped.
#
# THESE TWO NOW LIVE IN GameConfig — the consts are FALLBACK DEFAULTS ONLY.
# Authored in config/game_config.tres (group "Loading") as `loading_max_fps` /
# `loading_touch_max_fps` and read through `loading_cap()` below, per CLAUDE.md. RETUNE IN THE
# .tres. The consts stay as the documented shipped values and as the fallback when the field is
# missing; both hosts already reach the value through `loading_cap`, so neither world.gd nor
# overworld.gd needed changing.
const LOADING_MAX_FPS := 0         # non-touch (desktop/native): no ceiling for the load
const LOADING_TOUCH_MAX_FPS := 60  # touch/web: fast, but still a ceiling


## The loading-window frame cap for this platform. `touch` covers touch/web.
##
## Called ONCE per world boot (each host's _ready), not per frame, so it reads the config here
## rather than caching — the cap it returns is then held for the whole load window.
static func loading_cap(touch: bool) -> int:
	if touch:
		return int(Config.get_float("loading_touch_max_fps", float(LOADING_TOUCH_MAX_FPS)))
	return int(Config.get_float("loading_max_fps", float(LOADING_MAX_FPS)))


## Apply a frame cap and record the intent in `caps`. The Engine write is suppressed under
## --headless (nothing to pace, and it would throttle the frame-awaiting test runner), but the
## intent is recorded on EVERY path so tests can assert it without reading Engine.max_fps.
static func apply_fps_cap(caps: Array[int], cap: int, headless: bool) -> void:
	caps.append(cap)
	if not headless:
		Engine.max_fps = cap


## Deep snow: draw the ground ABOVE the collision surface off-road, so the car sinks in
## (features/snow-region.md). Collision is untouched, so the wheels rest at true ground
## level; car.gd's matching drag is what makes it read as ploughing rather than floating.
##
## Done by SWAPPING THE SHADER rather than setting a uniform on the shared one, because the
## base terrain shader is deliberately kept free of a vertex stage — terrain is the heaviest
## geometry in the game and this renderer targets low-end phones. See the header of
## ps1_terrain_snow.gdshader and test_terrain_shader_has_no_vertex_stage. Non-snow stages
## therefore pay literally nothing: they run the same shader they always did.
##
## Must be called UNCONDITIONALLY every world boot, and that is load-bearing. The floor
## material is a shared sub-resource of the host scene with no resource_local_to_scene, so it
## survives every scene instantiation in the process. Without the else-branch restoring the
## base shader, one snow stage would leave every later world's ground floating in mid-air.
##
## `floor_mat` is passed in because the two hosts reach their floor differently ($Floor vs a
## cached TerrainManager accessor); a null material is a no-op.
static func apply_deep_snow(floor_mat: ShaderMaterial, cfg: GameConfig) -> void:
	if floor_mat == null:
		return
	if cfg.deep_snow_depth_m > 0.0:
		if floor_mat.shader != TERRAIN_SNOW_SHADER:
			floor_mat.shader = TERRAIN_SNOW_SHADER
		floor_mat.set_shader_parameter("snow_depth", cfg.deep_snow_depth_m)
	elif floor_mat.shader != TERRAIN_BASE_SHADER:
		floor_mat.shader = TERRAIN_BASE_SHADER


## True when the live TerrainLayer resources already match the configured (wavelength,
## amplitude) pairs. Assigning `layers` triggers a full terrain regeneration, so both hosts
## use this to skip a no-op assignment.
static func layers_match(layers: Array[TerrainLayer], params: Array[Vector2]) -> bool:
	if layers.size() != params.size():
		return false
	for i in layers.size():
		if layers[i] == null or layers[i].wavelength_m != params[i].x \
				or layers[i].amplitude_m != params[i].y:
			return false
	return true


## Yield a frame so a freshly-set LoadingScreen step actually paints before the next blocking
## generation call. A no-op under headless, where the await would otherwise spread world
## generation across frames and break tests that inspect the world right after instantiating
## the scene — there the whole _ready chain runs synchronously inside add_child(), as it did
## before staged loading.
static func yield_frame(tree: SceneTree, headless: bool) -> void:
	if not headless and tree != null:
		await tree.process_frame


## A point ~2 m in front of the active camera — where a warm-up instance is guaranteed to sit
## inside the frustum (so it actually draws and compiles its shader). `fallback` is what the
## caller wants when no camera is up yet; the two hosts DIVERGE there (world.gd uses its
## authored $Car, overworld.gd looks the car up by name and tolerates its absence), so the
## fallback stays at the call site rather than being guessed here.
static func warm_up_point(cam: Camera3D, fallback: Vector3) -> Vector3:
	if cam != null:
		return cam.global_position - cam.global_transform.basis.z * 2.0
	return fallback
