extends GutTest

# Render-pipeline smoke test. The old pixel-diff golden test was removed: full
# frame capture only works windowed (headless uses a dummy renderer that can't
# read back pixels) and was chronically flaky. This replaces the meaningful half
# of that coverage WITHOUT pixels — it asserts the rendering setup is intact
# (environment present, meshes have their shader materials, post-process shader
# wired, shader source loads) and that bringing the scene up for a few frames
# raises no script errors. The runner fails on any "SCRIPT ERROR" in output, so
# a broken _ready/_process during render setup is caught here too.

var _scene: Node3D


# main.tscn._ready() generates the full terrain + track, which is expensive, so
# build it ONCE for the whole script. Every test here is a read-only check of
# the rendering setup (or runs a few process frames on it), so a single shared
# instance is safe.
func before_all() -> void:
	_scene = load("res://main.tscn").instantiate()
	add_child(_scene)
	await get_tree().physics_frame  # let world._ready() generate + apply + build


func after_all() -> void:
	_scene.free()


func _assert_shader_material(mat: Material, who: String) -> void:
	var sm := mat as ShaderMaterial
	assert_not_null(sm, who + " uses a ShaderMaterial")
	if sm == null:
		return
	assert_not_null(sm.shader, who + " has a Shader assigned")
	if sm.shader != null:
		assert_false(sm.shader.code.is_empty(), who + " shader has source code")


func test_world_environment_present() -> void:
	var we := _scene.get_node("WorldEnvironment") as WorldEnvironment
	assert_not_null(we, "WorldEnvironment node present")
	assert_not_null(we.environment as Environment, "WorldEnvironment has an Environment")


func test_terrain_chunks_have_shader_materials() -> void:
	# The terrain is now a chunk manager; chunks are created at runtime, so grab
	# any loaded chunk's mesh and verify its material survives mesh assignment.
	var floor_node := _scene.get_node("Floor")
	assert_gt(floor_node.loaded_coords().size(), 0, "chunks loaded around the car")
	var chunk = floor_node._chunks[floor_node.loaded_coords()[0]]
	var chunk_mesh := chunk.get_node("MeshInstance3D") as MeshInstance3D
	assert_not_null(chunk_mesh, "chunk MeshInstance3D present")
	_assert_shader_material(chunk_mesh.material_override, "chunk mesh")


func test_post_process_shader_wired() -> void:
	var rect := _scene.get_node("PostProcess/ColorRect") as ColorRect
	assert_not_null(rect, "post-process ColorRect present")
	_assert_shader_material(rect.material, "post-process ColorRect")


func test_shader_sources_load() -> void:
	for path in ["res://shaders/ps1_models.gdshader", "res://shaders/ps1_post_process.gdshader"]:
		var shader := load(path) as Shader
		assert_not_null(shader, path + " loads as a Shader")
		if shader != null:
			assert_false(shader.code.is_empty(), path + " has source code")


func test_scene_renders_a_few_frames_without_errors() -> void:
	# No assertion on pixels (headless can't read them); the value is that scene
	# setup + a few process frames run clean. The runner flags any SCRIPT ERROR.
	var cam := _scene.get_node("ChaseCamera") as Camera3D
	assert_not_null(cam, "ChaseCamera present")
	for i in 5:
		await get_tree().process_frame
	assert_true(true, "scene survived 5 process frames")


func test_models_shader_uses_vertex_color() -> void:
	var src := FileAccess.get_file_as_string("res://shaders/ps1_models.gdshader")
	assert_true(src.contains("COLOR"), "ps1_models multiplies albedo by vertex COLOR")


func test_models_shader_blends_to_road_texture() -> void:
	var src := FileAccess.get_file_as_string("res://shaders/ps1_models.gdshader")
	assert_true(src.contains("road_texture"), "ps1_models samples a road_texture")
	assert_true(src.contains("blend_road"), "ps1_models gates the road blend behind blend_road")


func test_models_shader_has_fake_lighting() -> void:
	var src := FileAccess.get_file_as_string("res://shaders/ps1_models.gdshader")
	# Lighting is faked in-shader; the material must stay unshaded (no engine
	# lighting pass / shadows) and gate the effect behind light_amount.
	assert_true(src.contains("unshaded"), "ps1_models stays render_mode unshaded")
	assert_true(src.contains("light_amount"), "ps1_models gates fake lighting behind light_amount")
	assert_true(src.contains("void vertex()"), "ps1_models computes lighting per-vertex")


func test_car_meshes_are_lit_but_terrain_is_flat() -> void:
	# world.gd applies the fake lighting to the car meshes only; the terrain
	# leaves light_amount at the shader default (0) and stays flat.
	var car_chassis := _scene.get_node("Car/Chassis") as MeshInstance3D
	var car_mat := car_chassis.get_surface_override_material(0) as ShaderMaterial
	assert_not_null(car_mat, "car chassis has a ShaderMaterial")
	assert_gt(car_mat.get_shader_parameter("light_amount"), 0.0, "car mesh is lit (light_amount > 0)")

	var floor_node := _scene.get_node("Floor")
	var terrain_mat := floor_node.chunk_material as ShaderMaterial
	# Never set on the terrain material → null (shader default 0 = flat).
	assert_null(terrain_mat.get_shader_parameter("light_amount"), "terrain stays flat (light_amount unset)")


func test_terrain_material_enables_road_blend_with_gravel() -> void:
	var floor_node := _scene.get_node("Floor")
	var mat := floor_node.chunk_material as ShaderMaterial
	assert_not_null(mat, "floor has a ShaderMaterial")
	assert_true(mat.get_shader_parameter("blend_road"), "terrain enables blend_road")
	assert_not_null(mat.get_shader_parameter("road_texture"), "terrain has a road_texture wired")
	# road tiling uniform is applied from config at startup (world.gd._ready).
	assert_gt(mat.get_shader_parameter("road_uv_scale"), 0.0, "road_uv_scale applied (positive)")
