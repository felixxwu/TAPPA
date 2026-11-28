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


# Every test here is a read-only check of the rendering setup (or runs a few process
# frames on it), so the whole script shares ONE cheap flat level.
func before_all() -> void:
	Config.reset()
	_scene = await SceneTestHelpers.add_level_world(self)


func after_all() -> void:
	_scene.free()
	SceneTestHelpers.remove_level_world()
	Config.reset()


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
	# The level's fog is distance haze that thickens toward a far end, and is not allowed
	# to fully wash out the sky.
	assert_eq(env.fog_mode, Environment.FOG_MODE_DEPTH, "fog is depth haze, not a uniform density wall")
	assert_gt(env.fog_depth_end, env.fog_depth_begin, "fog fades in over a distance")
	assert_lt(env.fog_sky_affect, 1.0, "fog does not fully tint the sky")


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


func test_post_process_grades_before_quantising() -> void:
	var src := FileAccess.get_file_as_string("res://shaders/ps1_post_process.gdshader")
	for param in ["grade_amount", "grade_saturation", "grade_contrast", "grade_shadow_tint",
			"grade_highlight_tint", "grade_vignette_strength", "grade_vignette_radius"]:
		assert_true(src.contains("uniform") and src.contains(param),
			"post-process shader exposes " + param)
	# The grade MUST run ahead of the 5-bit truncation, so the banding lands in the
	# graded palette instead of the grade smearing already-quantised levels back
	# into intermediate values. Ordering is the one thing a source check can pin.
	var grade_at := src.find("mix(vec3(luma)")
	var quantise_at := src.find("floor((color + dither)")
	assert_gt(grade_at, -1, "grade maths present in fragment()")
	assert_gt(quantise_at, -1, "5-bit quantise present in fragment()")
	assert_lt(grade_at, quantise_at, "colour grade runs BEFORE the 5-bit quantise")
	# grade_amount = 0 must be a true bypass, vignette included — so the vignette
	# has to be folded into the graded value ahead of the master mix.
	assert_lt(src.find("grade_vignette_strength)"), src.find("mix(original, graded"),
		"vignette applies inside the graded branch, before the grade_amount blend")


func test_shader_sources_load() -> void:
	for path in ["res://shaders/ps1_post_process.gdshader",
			"res://shaders/speed_lines.gdshader", "res://shaders/level_ground.gdshader"]:
		var shader := load(path) as Shader
		assert_not_null(shader, path + " loads as a Shader")
		if shader != null:
			assert_false(shader.code.is_empty(), path + " has source code")


func test_lit_car_shader_has_fake_lighting() -> void:
	var src := FileAccess.get_file_as_string("res://shaders/ps1_models_lit.gdshader")
	# The car variant fakes lighting in-shader; it must stay unshaded (no engine
	# lighting pass / shadows) and gate the effect behind light_amount.
	assert_true(src.contains("unshaded"), "ps1_models_lit stays render_mode unshaded")
	assert_true(src.contains("light_amount"), "ps1_models_lit gates fake lighting behind light_amount")
	assert_true(src.contains("void vertex()"), "ps1_models_lit computes lighting per-vertex")


func test_car_headlight_cone_rejects_backfaces() -> void:
	# The headlight cone must not light a car's REAR panels just because they sit
	# geometrically inside the cone's angle/range — it needs to know which way the
	# surface faces. The car shader must pass its world normal into a facing-aware
	# headlight_lit() call, and the include must define a variant that actually
	# consumes a normal.
	var src := FileAccess.get_file_as_string("res://shaders/ps1_models_lit.gdshader")
	assert_true(src.contains("headlight_lit(") and src.contains(", wn)"),
		"ps1_models_lit passes its world normal (wn) into headlight_lit()")
	var inc_src := FileAccess.get_file_as_string("res://shaders/headlight_cone.gdshaderinc")
	assert_true(inc_src.contains("vec3 world_normal"),
		"headlight_cone.gdshaderinc defines a normal-aware cone/lit variant")


func test_car_meshes_are_lit() -> void:
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
			if line.contains("sampler2D") and not line.contains("linear_ok"):
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


func test_no_weather_field_on_a_dry_stage() -> void:
	# The shared level above is dry (Config.reset's authored baseline weather). Weather must construct NOTHING when dry,
	# so a dry stage carries exactly zero new per-frame cost — that is the whole
	# contract of the weather visuals (features/rendering.md).
	assert_eq(_scene.find_children("", "WeatherField", true, false).size(), 0,
		"a dry stage builds no weather field")


func test_rain_field_is_a_single_cheap_draw() -> void:
	# Structural budget of the wet-stage rain, independent of any tuned count:
	# one draw pass, no shadow pass, no particle collision, world-space simulation
	# (so drops stream past the camera with correct parallax instead of being
	# dragged along with it), and parented to the camera so the emission box
	# still follows the view.
	var cam := Camera3D.new()
	add_child_autofree(cam)
	var rain := WeatherField.spawn_rain(cam, 8)
	assert_eq(rain.get_parent(), cam, "rain is parented to the camera it follows")
	assert_false(rain.local_coords, "rain simulates in world space so it streams past at speed")
	assert_eq(rain.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
		"rain casts no shadows")
	assert_not_null(rain.draw_pass_1, "rain has its one draw pass")
	assert_eq(rain.draw_passes, 1, "rain uses a single draw pass")
	var proc := rain.process_material as ParticleProcessMaterial
	assert_not_null(proc, "rain has a particle process material")
	if proc != null:
		assert_eq(proc.collision_mode, ParticleProcessMaterial.COLLISION_DISABLED,
			"rain particles do not collide")
	var mat := (rain.draw_pass_1 as QuadMesh).material as StandardMaterial3D
	assert_not_null(mat, "rain quads use a StandardMaterial3D")
	if mat != null:
		assert_eq(mat.shading_mode, BaseMaterial3D.SHADING_MODE_UNSHADED,
			"rain quads are unshaded")
		assert_eq(mat.billboard_mode, BaseMaterial3D.BILLBOARD_PARTICLES,
			"rain quads billboard per-particle so their world-space velocity reads as a streak")


func test_sandstorm_field_is_a_single_cheap_draw_with_wind_direction() -> void:
	# Same structural budget as rain (one draw pass, no shadows, no collision,
	# world-space), but the dust travels in a fixed WORLD direction rather than
	# falling — asserted as "not straight down" and matching the requested compass
	# heading, never a specific tuned speed/count.
	var cam := Camera3D.new()
	add_child_autofree(cam)
	var sand := WeatherField.spawn_sandstorm(cam, 8, 90.0)
	assert_eq(sand.get_parent(), cam, "dust is parented to the camera it follows")
	assert_false(sand.local_coords, "dust simulates in world space, indifferent to camera motion")
	assert_eq(sand.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
		"dust casts no shadows")
	assert_eq(sand.draw_passes, 1, "dust uses a single draw pass")
	var proc := sand.process_material as ParticleProcessMaterial
	assert_not_null(proc, "dust has a particle process material")
	if proc != null:
		assert_eq(proc.collision_mode, ParticleProcessMaterial.COLLISION_DISABLED,
			"dust particles do not collide")
		assert_almost_eq(proc.direction.y, 0.0, 0.05, "wind blows roughly horizontally, not downward")
		# wind_dir_deg=90 -> world +Z per WeatherField.spawn_sandstorm's convention.
		assert_gt(proc.direction.z, 0.5, "dust direction follows the requested wind heading")

	# A different heading must actually change the direction — i.e. the wind is a
	# real input, not a hardcoded constant.
	var sand2 := WeatherField.spawn_sandstorm(cam, 8, 0.0)
	var proc2 := sand2.process_material as ParticleProcessMaterial
	assert_gt(proc2.direction.x, 0.5, "0-degree wind blows toward world +X")
	assert_ne(proc.direction, proc2.direction, "different headings produce different wind directions")

	# Travel speed is an INPUT too, passed down from the GameConfig field the weather
	# table's "particle_speed" names — WeatherField reads no condition's config field
	# itself. The speed here is the test's own, so nothing authored is pinned.
	var sand3 := WeatherField.spawn_sandstorm(cam, 8, 0.0, 42.0)
	assert_eq((sand3.process_material as ParticleProcessMaterial).initial_velocity_min, 42.0,
		"the requested particle speed reaches the process material")


func test_a_condition_without_a_particle_kind_constructs_no_field() -> void:
	# The no-particle path, driven through the SAME seam LevelView.apply_weather
	# uses (WeatherField.spawn with the entry's particle kind). A visibility-only
	# condition such as fog names no kind, so nothing is built and it costs nothing
	# per frame; a precipitation condition names one and gets a field. Synthetic
	# entries, so no shipped condition's tuning is pinned.
	var cam := Camera3D.new()
	add_child_autofree(cam)
	var visibility_only := {"id": "haze"}
	var precipitation := {"id": "squall", "particles": "rain"}
	assert_null(WeatherField.spawn(cam, String(visibility_only.get("particles", "")), 8, 0.0),
		"a condition naming no particle kind builds no field")
	assert_eq(cam.find_children("", "WeatherField", true, false).size(), 0,
		"and adds nothing to the scene")
	assert_not_null(WeatherField.spawn(cam, String(precipitation.get("particles", "")), 8, 0.0),
		"a condition naming a particle kind builds one")
	assert_eq(cam.find_children("", "WeatherField", true, false).size(), 1,
		"exactly one field is added")
