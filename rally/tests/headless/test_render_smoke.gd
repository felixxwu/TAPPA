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


func test_environment_uses_skybox_with_demoted_fog() -> void:
	var env := (_scene.get_node("WorldEnvironment") as WorldEnvironment).environment
	assert_eq(env.background_mode, Environment.BG_SKY, "background is a Sky, not a flat colour")
	assert_not_null(env.sky, "environment has a Sky resource")
	if env.sky != null:
		assert_true(env.sky.sky_material is PanoramaSkyMaterial,
			"sky uses a panorama (photographic) material, not a colour gradient")
	# Fog demoted from the old ~0.03 edge-hiding wall to thin haze, and not allowed
	# to fully wash out the sky.
	assert_lt(env.fog_density, 0.02, "fog reduced now that DistantTerrain hides the edge")
	assert_lt(env.fog_sky_affect, 1.0, "fog does not fully tint the sky")


func test_distant_terrain_backdrop_built() -> void:
	var dt := _scene.get_node_or_null("DistantTerrain") as MeshInstance3D
	assert_not_null(dt, "distant-terrain backdrop built to give the sky a horizon")
	if dt != null:
		assert_not_null(dt.mesh, "distant terrain has a mesh")
		assert_null(dt.get_node_or_null("Collision"), "distant terrain is scenery (no collision)")
		assert_not_null(dt.material_override, "distant terrain reuses the shared chunk material")


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


func test_lit_car_shader_has_fake_lighting() -> void:
	var src := FileAccess.get_file_as_string("res://shaders/ps1_models_lit.gdshader")
	# The car variant fakes lighting in-shader; it must stay unshaded (no engine
	# lighting pass / shadows) and gate the effect behind light_amount.
	assert_true(src.contains("unshaded"), "ps1_models_lit stays render_mode unshaded")
	assert_true(src.contains("light_amount"), "ps1_models_lit gates fake lighting behind light_amount")
	assert_true(src.contains("void vertex()"), "ps1_models_lit computes lighting per-vertex")
	# Parked cars bake their shading and set light_amount 0; the vertex stage must
	# skip the per-vertex lighting maths entirely for them (car.gd bake_shading),
	# not just discard the result — so it keeps a frozen car at zero per-frame cost.
	assert_true(src.contains("if (light_amount <= 0.0)"),
		"ps1_models_lit skips the lighting maths when light_amount is 0 (frozen/baked cars)")


func test_terrain_shader_has_no_vertex_stage() -> void:
	# Performance guard: the shared terrain shader must NOT carry a vertex() stage.
	# The terrain is the heaviest geometry (tens of thousands of vertices in the
	# loaded chunk ring), so per-vertex lighting there is a real mobile regression.
	# Car lighting lives in the separate ps1_models_lit.gdshader instead.
	var src := FileAccess.get_file_as_string("res://shaders/ps1_models.gdshader")
	assert_false(src.contains("void vertex()"), "ps1_models (terrain) has no vertex stage")
	assert_false(src.contains("light_amount"), "ps1_models (terrain) carries no lighting cost")


func test_car_meshes_are_lit_but_terrain_is_flat() -> void:
	# The car meshes use the lit shader (world.gd applies the light params); the
	# terrain uses the plain shader, which has no light_amount uniform at all.
	var car_chassis := _scene.get_node("Car/Chassis") as MeshInstance3D
	var car_mat := car_chassis.get_surface_override_material(0) as ShaderMaterial
	assert_not_null(car_mat, "car chassis has a ShaderMaterial")
	assert_gt(car_mat.get_shader_parameter("light_amount"), 0.0, "car mesh is lit (light_amount > 0)")
	# Fake-light direction is the configured, skybox-aligned sun. The panorama is
	# rolled (tools/align_sky_sun.py) so the sun sits at image centre — which is +Z
	# in Godot's mapping — so the light comes from +Z (z > 0) and the shading lines
	# up with the visible sun.
	var light_dir = car_mat.get_shader_parameter("light_dir")
	assert_eq(light_dir, Config.data.sun_direction, "car shading uses the configured sun_direction")
	assert_gt(light_dir.z, 0.0, "sun-centred convention: the light comes from +Z")

	var floor_node := _scene.get_node("Floor")
	var terrain_mat := floor_node.chunk_material as ShaderMaterial
	# The terrain shader has no light_amount uniform → null (flat, no extra cost).
	assert_null(terrain_mat.get_shader_parameter("light_amount"), "terrain shader has no lighting uniform")


func test_terrain_material_enables_road_blend_with_gravel() -> void:
	var floor_node := _scene.get_node("Floor")
	var mat := floor_node.chunk_material as ShaderMaterial
	assert_not_null(mat, "floor has a ShaderMaterial")
	assert_true(mat.get_shader_parameter("blend_road"), "terrain enables blend_road")
	assert_not_null(mat.get_shader_parameter("road_texture"), "terrain has a road_texture wired")
	# road tiling uniform is applied from config at startup (world.gd._ready).
	assert_gt(mat.get_shader_parameter("road_uv_scale"), 0.0, "road_uv_scale applied (positive)")
