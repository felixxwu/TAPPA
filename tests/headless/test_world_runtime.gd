extends GutTest
# THE SHARED WORLD-HOST RUNTIME (`scripts/world_runtime.gd`).
#
# `world.gd` (a rally stage) and `overworld.gd` (the free-roam map) are both Node3D scene roots
# that build terrain behind a loading cover. The leaf behaviours they share — the loading frame
# cap, the deep-snow shader swap, the terrain-layer equality guard, the headless frame yield and
# the shader warm-up point — used to be duplicated in both files and had already drifted. They
# now live once, in `WorldRuntime`, and this file pins the CONTRACT each host relies on.
#
# WHY THESE ASSERTIONS AND NOT OTHERS. No tunable is asserted: not the cap values (the branch is
# checked against the const, never against a number), not a snow depth, not a terrain layer
# shape. Every input is synthetic — a bare `GameConfig.new()`, hand-built `TerrainLayer`s, a
# throwaway `ShaderMaterial` — so nothing here depends on `game_config.tres` or on any catalogue
# entry. The one thing worth pinning hard is the deep-snow RESTORE: the floor material is a
# shared sub-resource that outlives a scene change, so a missing else-branch would leave every
# later world's ground floating in mid-air.
#
# COST: no scene is instantiated. These are pure static functions over their arguments.


func _layer(wavelength: float, amplitude: float) -> TerrainLayer:
	var layer := TerrainLayer.new()
	layer.wavelength_m = wavelength
	layer.amplitude_m = amplitude
	return layer


# --- Loading frame cap -------------------------------------------------------------------

# The branch, not the number: touch/web and non-touch take the two different consts. Asserted
# against the consts themselves so retuning either cap cannot break this test.
func test_loading_cap_picks_the_touch_cap_only_for_touch() -> void:
	assert_eq(WorldRuntime.loading_cap(true), WorldRuntime.LOADING_TOUCH_MAX_FPS,
		"touch/web takes the bounded loading cap")
	assert_eq(WorldRuntime.loading_cap(false), WorldRuntime.LOADING_MAX_FPS,
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


# --- Deep snow ---------------------------------------------------------------------------

func test_deep_snow_swaps_in_the_snow_shader_and_pushes_the_depth() -> void:
	var mat := ShaderMaterial.new()
	mat.shader = WorldRuntime.TERRAIN_BASE_SHADER
	var cfg := GameConfig.new()
	cfg.deep_snow_depth_m = 1.25  # synthetic input, not the authored value
	WorldRuntime.apply_deep_snow(mat, cfg)
	assert_eq(mat.shader, WorldRuntime.TERRAIN_SNOW_SHADER, "snow shader is swapped in")
	assert_almost_eq(float(mat.get_shader_parameter("snow_depth")), 1.25, 1e-5,
		"the configured depth reaches the shader")


# THE LOAD-BEARING HALF. The floor material is a shared sub-resource with no
# resource_local_to_scene, so it survives every scene instantiation in the process: without the
# else-branch, one snow world would leave every later world's ground drawn above its collision.
func test_deep_snow_restores_the_base_shader_when_depth_is_off() -> void:
	var mat := ShaderMaterial.new()
	mat.shader = WorldRuntime.TERRAIN_SNOW_SHADER
	var cfg := GameConfig.new()
	cfg.deep_snow_depth_m = 0.0
	WorldRuntime.apply_deep_snow(mat, cfg)
	assert_eq(mat.shader, WorldRuntime.TERRAIN_BASE_SHADER,
		"a non-snow world gets the base shader back")


# Calling it repeatedly must be idempotent in both directions — every host calls it
# unconditionally on every boot.
func test_deep_snow_is_idempotent_in_both_directions() -> void:
	var mat := ShaderMaterial.new()
	mat.shader = WorldRuntime.TERRAIN_BASE_SHADER
	var snow := GameConfig.new()
	snow.deep_snow_depth_m = 0.5
	var dry := GameConfig.new()
	dry.deep_snow_depth_m = 0.0
	for _i in 3:
		WorldRuntime.apply_deep_snow(mat, snow)
	assert_eq(mat.shader, WorldRuntime.TERRAIN_SNOW_SHADER, "still the snow shader")
	for _i in 3:
		WorldRuntime.apply_deep_snow(mat, dry)
	assert_eq(mat.shader, WorldRuntime.TERRAIN_BASE_SHADER, "back to the base shader, once")


# A host whose floor material isn't resolvable must be a silent no-op, not a crash — both hosts
# pass the result of a cast straight in.
func test_deep_snow_tolerates_a_null_material() -> void:
	var cfg := GameConfig.new()
	cfg.deep_snow_depth_m = 1.0
	WorldRuntime.apply_deep_snow(null, cfg)
	pass_test("a null floor material is a no-op")


# --- Terrain layer equality --------------------------------------------------------------
#
# Assigning `layers` triggers a FULL terrain regeneration, so both hosts skip the assignment
# when the live layers already match the configured pairs. A false "match" would silently ignore
# a config change; a false "mismatch" would rebuild the terrain for nothing.

func test_layers_match_accepts_layers_equal_to_the_params() -> void:
	var layers: Array[TerrainLayer] = [_layer(120.0, 9.0), _layer(30.0, 2.0)]
	assert_true(WorldRuntime.layers_match(layers, [Vector2(120.0, 9.0), Vector2(30.0, 2.0)]),
		"identical wavelength/amplitude pairs match")


func test_layers_match_rejects_a_different_count() -> void:
	var layers: Array[TerrainLayer] = [_layer(120.0, 9.0)]
	assert_false(WorldRuntime.layers_match(layers, [Vector2(120.0, 9.0), Vector2(30.0, 2.0)]),
		"a missing layer is a mismatch")
	assert_false(WorldRuntime.layers_match(layers, []), "an empty config is a mismatch")


func test_layers_match_rejects_a_changed_wavelength_or_amplitude() -> void:
	var layers: Array[TerrainLayer] = [_layer(120.0, 9.0)]
	assert_false(WorldRuntime.layers_match(layers, [Vector2(121.0, 9.0)]),
		"a changed wavelength is a mismatch")
	assert_false(WorldRuntime.layers_match(layers, [Vector2(120.0, 9.5)]),
		"a changed amplitude is a mismatch")


func test_layers_match_rejects_a_null_layer() -> void:
	var layers: Array[TerrainLayer] = [null]
	assert_false(WorldRuntime.layers_match(layers, [Vector2(120.0, 9.0)]),
		"a null layer can never match")


func test_layers_match_treats_two_empties_as_equal() -> void:
	var layers: Array[TerrainLayer] = []
	assert_true(WorldRuntime.layers_match(layers, []), "nothing configured, nothing live")


# --- Headless frame yield ----------------------------------------------------------------
#
# The contract the whole test suite leans on: under headless the yield collapses to a
# synchronous no-op, so a host's `_ready` chain runs to completion inside add_child() and a test
# sees a fully-built world the instant it instantiates the scene.

func test_yield_frame_is_synchronous_under_headless() -> void:
	var before := Engine.get_process_frames()
	await WorldRuntime.yield_frame(get_tree(), true)
	assert_eq(Engine.get_process_frames(), before, "no frame was awaited under headless")


func test_yield_frame_awaits_a_frame_when_not_headless() -> void:
	var before := Engine.get_process_frames()
	await WorldRuntime.yield_frame(get_tree(), false)
	assert_gt(Engine.get_process_frames(), before, "a frame was awaited on the interactive path")


# A host without a tree (freed mid-load) must not crash the yield.
func test_yield_frame_tolerates_a_null_tree() -> void:
	await WorldRuntime.yield_frame(null, false)
	pass_test("a null tree is a no-op")


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


# No camera up yet: the caller's own fallback is returned untouched. The two hosts DIVERGE on
# what that fallback is (an authored $Car vs a car looked up by name), which is exactly why it
# is a parameter and not baked in here.
func test_warm_up_point_returns_the_callers_fallback_without_a_camera() -> void:
	var fallback := Vector3(1.0, 2.0, 3.0)
	assert_eq(WorldRuntime.warm_up_point(null, fallback), fallback,
		"the host's own fallback wins when no camera exists")
