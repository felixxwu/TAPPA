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


# minimal_world() trims main.tscn's expensive terrain/track/foliage generation
# (see scene_helpers.gd), and we build the scene ONCE for the whole script. Every
# test here is a read-only check of the rendering setup (or runs a few process
# frames on it), so a single shared instance is safe. The rendering nodes
# (WorldEnvironment, DistantTerrain, chunk Floor, PostProcess, SpeedLines, car
# materials) are all built regardless of track length/foliage, so the minimal
# build still exercises everything asserted below.
func before_all() -> void:
	SceneTestHelpers.minimal_world()
	# The shipped config ships the distant-terrain backdrop OFF (game_config.tres), but
	# this suite asserts the backdrop-building path, so enable it for the test scene.
	Config.data.distant_terrain_enabled = true
	_scene = load("res://main.tscn").instantiate()
	add_child(_scene)
	await get_tree().physics_frame  # let world._ready() generate + apply + build


func after_all() -> void:
	_scene.free()
	Config.reset()  # minimal_world() zeroed foliage/track — restore the baseline for later files


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
	var dt := _scene.get_node_or_null("DistantTerrain") as Node3D
	assert_not_null(dt, "distant-terrain backdrop built to give the sky a horizon")
	if dt == null:
		return
	assert_null(dt.get_node_or_null("Collision"), "distant terrain node itself is scenery (no collision)")
	var found_tile := false
	for t in dt.get_children():
		var mi := t as MeshInstance3D
		assert_not_null(mi, "backdrop child is a tile MeshInstance3D")
		if mi == null:
			continue
		assert_not_null(mi.mesh, "tile has a mesh")
		assert_null(mi.get_node_or_null("Collision"), "tile is scenery (no collision)")
		found_tile = true
	assert_true(found_tile, "backdrop has at least one tile child")


func test_terrain_chunks_have_shader_materials() -> void:
	# The terrain is now a chunk manager; chunks are created at runtime, so grab
	# any loaded chunk's mesh and verify its material survives mesh assignment.
	var floor_node := _scene.get_node("Floor")
	assert_gt(floor_node.loaded_coords().size(), 0, "chunks loaded around the car")
	var chunk = floor_node._chunks[floor_node.loaded_coords()[0]]
	var chunk_mesh := chunk.get_node("LOD0") as MeshInstance3D
	assert_not_null(chunk_mesh, "chunk LOD0 MeshInstance3D present")
	_assert_shader_material(chunk_mesh.material_override, "chunk mesh")


func test_post_process_shader_wired() -> void:
	var container := _scene.get_node("PostProcess") as SubViewportContainer
	assert_not_null(container, "post-process SubViewportContainer present")
	_assert_shader_material(container.material, "post-process SubViewportContainer")
	# The subviewport must render the SAME world the scene lives in.
	var view := container.get_node("View") as SubViewport
	assert_eq(view.find_world_3d(), container.get_viewport().find_world_3d(),
		"post-process subviewport shares the main World3D")


func test_post_process_mirror_camera_syncs() -> void:
	var src := _scene.get_viewport().get_camera_3d()
	assert_not_null(src, "an active gameplay camera exists")
	var mirror := _scene.get_node("PostProcess/View/ViewCamera") as Camera3D
	# post_process_view copies src's transform + fov each frame, ONE frame later, so
	# while the camera eases into its rest pose (or its speed-based FOV is still
	# changing) the mirror reads a frame behind. Settle first, then the copy matches
	# src exactly — we assert the mirror MIRRORS src, not any forced value (the chase
	# camera owns both the pose and the fov and would overwrite a forced one).
	for _i in 90:
		await get_tree().process_frame
	assert_almost_eq(mirror.global_position, src.global_position, Vector3.ONE * 0.01,
		"mirror camera follows the active camera's position")
	assert_almost_eq(mirror.fov, src.fov, 0.05, "mirror camera copies the active camera's fov")


func test_speed_lines_overlay_wired() -> void:
	# Anime edge speed lines: a ColorRect on its own CanvasLayer (above the
	# post-process, below the HUD) carrying the speed-lines shader, pointed at the car.
	var lines := _scene.get_node_or_null("SpeedLines") as CanvasLayer
	assert_not_null(lines, "SpeedLines overlay layer present")
	if lines == null:
		return
	assert_not_null(lines.car, "speed-lines overlay is pointed at the car")
	var rect := lines.get_node_or_null("ColorRect") as ColorRect
	assert_not_null(rect, "speed-lines ColorRect present")
	_assert_shader_material(rect.material, "speed-lines ColorRect")
	# It must not eat input meant for the HUD / mobile controls underneath.
	assert_eq(rect.mouse_filter, Control.MOUSE_FILTER_IGNORE, "speed-lines overlay ignores input")


func test_speed_lines_shader_radial_edge_effect() -> void:
	var src := FileAccess.get_file_as_string("res://shaders/speed_lines.gdshader")
	assert_true(src.contains("intensity"), "speed-lines shader exposes a speed-driven intensity")
	# Radial mask (inner/outer radius) is what keeps the screen centre clear.
	assert_true(src.contains("inner_radius") and src.contains("outer_radius"),
		"speed-lines shader masks the centre via inner/outer radius")


func test_shader_sources_load() -> void:
	for path in ["res://shaders/ps1_models.gdshader", "res://shaders/ps1_post_process.gdshader",
			"res://shaders/speed_lines.gdshader"]:
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


# --- Nearest-neighbour texture filtering (PS1 look: textures must not blur) ---

func test_all_shaders_sample_textures_with_nearest_filter() -> void:
	# Every sampler2D in every shader must use a nearest filter hint — no
	# filter_linear*, which would blur textures and break the PS1 look.
	var dir := DirAccess.open("res://shaders")
	assert_not_null(dir, "shaders directory opens")
	if dir == null:
		return
	var checked := 0
	for file in dir.get_files():
		if not file.ends_with(".gdshader"):
			continue
		var src := FileAccess.get_file_as_string("res://shaders/" + file)
		# Each sampler2D uniform line must carry filter_nearest (with or without
		# _mipmap); none may use a filter_linear* hint.
		for line in src.split("\n"):
			if line.contains("sampler2D"):
				assert_false(line.contains("filter_linear"),
					file + " sampler must not use filter_linear: " + line.strip_edges())
				assert_true(line.contains("filter_nearest"),
					file + " sampler uses nearest filtering: " + line.strip_edges())
				checked += 1
	assert_gt(checked, 0, "found sampler2D uniforms to check across the shaders")


func test_canvas_default_texture_filter_is_nearest() -> void:
	# 2D / canvas textures (HUD, sign boards drawn as canvas items) default to
	# nearest via the project setting (0 == nearest).
	assert_eq(int(ProjectSettings.get_setting("rendering/textures/canvas_textures/default_texture_filter")), 0,
		"canvas default_texture_filter is Nearest (0)")
