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


# A stand-in for the terrain Floor: world.gd's tint helper only needs a node named
# "Floor" exposing `chunk_material`, so this lets the read-modify-write be exercised
# on a PRIVATE material instead of main.tscn's shared one.
class _FakeFloor extends Node:
	var chunk_material: ShaderMaterial


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
	# Pick a level that actually HAS a mesh: a chunk's LOD0 is legitimately null when it
	# is coarse (fine levels pruned) or when its finest level is lazily deferred outside
	# the detail ring, and _apply_level_bands only materials the present levels.
	var chunk_mesh: MeshInstance3D = null
	for coord in floor_node.loaded_coords():
		for child in floor_node._chunks[coord].get_children():
			var mi := child as MeshInstance3D
			if mi != null and mi.mesh != null:
				chunk_mesh = mi
				break
		if chunk_mesh != null:
			break
	assert_not_null(chunk_mesh, "some loaded chunk has a built LOD MeshInstance3D")
	if chunk_mesh == null:
		return
	_assert_shader_material(chunk_mesh.material_override, "chunk mesh")


func test_post_process_shader_wired() -> void:
	var container := _scene.get_node("PostProcess") as SubViewportContainer
	assert_not_null(container, "post-process SubViewportContainer present")
	_assert_shader_material(container.material, "post-process SubViewportContainer")
	# The subviewport must render the SAME world the scene lives in.
	var view := container.get_node("View") as SubViewport
	assert_eq(view.find_world_3d(), container.get_viewport().find_world_3d(),
		"post-process subviewport shares the main World3D")


func test_hq_hosts_the_same_post_process_pass() -> void:
	# The HQ hub gets the identical PS1 pass as the stage, so the colour grade covers
	# the whole game's 3D rather than stopping at the garage door.
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	var container := hq.get_node_or_null("PostProcess") as SubViewportContainer
	assert_not_null(container, "HQ has a post-process SubViewportContainer")
	if container == null:
		return
	_assert_shader_material(container.material, "HQ post-process SubViewportContainer")
	var view := container.get_node("View") as SubViewport
	assert_eq(view.find_world_3d(), container.get_viewport().find_world_3d(),
		"HQ post-process subviewport shares the HQ World3D")
	# The container must not swallow mouse events: the HQ's table / lift / pin
	# stations are Area3D picked through the ROOT viewport.
	assert_eq(container.mouse_filter, Control.MOUSE_FILTER_IGNORE,
		"HQ post-process container ignores the mouse so 3D picking still reaches the stations")
	# Grade values must actually be pushed, not left on the shader defaults.
	var cfg: GameConfig = Config.data
	var mat := container.material as ShaderMaterial
	assert_eq(mat.get_shader_parameter("grade_saturation"), cfg.grade_saturation,
		"HQ grade pushed from config")


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
	for path in ["res://shaders/ps1_models.gdshader", "res://shaders/ps1_post_process.gdshader",
			"res://shaders/speed_lines.gdshader"]:
		var shader := load(path) as Shader
		assert_not_null(shader, path + " loads as a Shader")
		if shader != null:
			assert_false(shader.code.is_empty(), path + " has source code")


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


func test_no_weather_field_on_a_dry_stage() -> void:
	# The shared scene above is a dry stage (minimal_world resets Config, whose
	# authored baseline weather is dry). Weather must construct NOTHING when dry,
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
	# The no-particle path, driven through the SAME seam world.gd._apply_weather_look
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


func test_lightning_spikes_the_environment_colour_and_restores_it() -> void:
	# Lightning is deliberately NOT a light node — this renderer is unshaded with
	# baked vertex lighting and ships with no lights at all — so a flash is a short
	# tween on an environment colour the weather look ALREADY drives. What must hold
	# for ANY authored brightness/cadence: the colour goes UP during the flash, comes
	# back to EXACTLY where it started (a flash that leaked would leave the stage
	# permanently mis-lit), and the timer re-arms itself for the next one.
	#
	# Driven with a synthetic lightning block and config values set here, so no
	# authored colour, brightness or interval is pinned. The host is a bare
	# Node3D + WorldEnvironment carrying world.gd (the script is attached AFTER the
	# node is in the tree, so world.gd._ready — a full stage build — never runs).
	var host := Node3D.new()
	var world_env := WorldEnvironment.new()
	world_env.name = "WorldEnvironment"
	world_env.environment = Environment.new()
	var base := Color(0.4, 0.4, 0.45)
	world_env.environment.fog_light_color = base
	host.add_child(world_env)
	add_child_autofree(host)
	host.set_script(load("res://scripts/world.gd"))
	var cfg := GameConfig.new()
	cfg.storm_lightning_flash = 2.0
	cfg.storm_lightning_duration_s = 0.5
	cfg.storm_lightning_interval_min_s = 5.0
	cfg.storm_lightning_interval_max_s = 5.0
	host._start_lightning(cfg, {
		"flash": "storm_lightning_flash", "duration": "storm_lightning_duration_s",
		"interval_min": "storm_lightning_interval_min_s",
		"interval_max": "storm_lightning_interval_max_s",
	})
	var timer: Timer = host.get_node("Lightning")
	assert_gt(timer.time_left, 0.0, "the first flash is scheduled")
	timer.start(0.01)
	await wait_seconds(0.15)
	assert_gt(world_env.environment.fog_light_color.r, base.r,
		"the flash brightens the environment colour")
	await wait_seconds(0.6)
	assert_almost_eq(world_env.environment.fog_light_color.r, base.r, 0.001,
		"and returns exactly to the stage's own colour")
	assert_gt(timer.time_left, 0.0, "the timer re-arms itself for the next flash")


func test_stage_boot_re_seeds_the_ground_albedo_from_the_authored_baseline() -> void:
	# The guard on the weather road tint's idempotence. _tint_road does a
	# read-modify-write on the floor material's albedo_color, and that material is a
	# SHARED sub-resource of main.tscn (no resource_local_to_scene), so unless every
	# stage boot re-seeds the parameter from the authored baseline a wet stage's
	# darkening compounds across stages and leaks into later dry ones. Asserts the
	# IDENTITY (the material holds the authored value after boot), never a colour.
	var floor_mat := _scene.get_node("Floor").chunk_material as ShaderMaterial
	var look: Dictionary = RegionLibrary.look_of("home")
	var expected: Color = look.get("terrain_tint", Config.data.terrain_tint)
	assert_eq(floor_mat.get_shader_parameter("albedo_color"), expected,
		"a booted stage starts from the authored ground tint, not a previous tint")


func test_road_tint_applies_once_per_stage_and_never_compounds() -> void:
	# REGRESSION (critical): two wet stages in a row used to leave the ground at
	# amount², and every later DRY stage stayed darkened, because the tint modified
	# whatever the shared material already held. With the per-stage re-seed above, the
	# same condition applied on two stages yields the SAME result — the property that
	# matters, asserted as an identity between two applications rather than as any
	# particular colour, so retuning rain_road_darken or the dust colour cannot break
	# it.
	var host := Node3D.new()
	var fake_floor := _FakeFloor.new()
	fake_floor.name = "Floor"
	fake_floor.chunk_material = ShaderMaterial.new()
	host.add_child(fake_floor)
	add_child_autofree(host)
	host.set_script(load("res://scripts/world.gd"))
	var mat: ShaderMaterial = fake_floor.chunk_material
	var base := Color(0.8, 0.8, 0.85, 1.0)
	var seed_baseline := func () -> void:
		mat.set_shader_parameter("albedo_color", base)
		mat.set_shader_parameter("tarmac_color", base)
	# Darkening (no target colour) — a wet/storm road.
	seed_baseline.call()
	host._tint_road(0.5, Color.BLACK, false)
	var after_one_stage: Color = mat.get_shader_parameter("albedo_color")
	assert_lt(after_one_stage.r, base.r, "a darkening tint does darken the ground")
	seed_baseline.call()
	host._tint_road(0.5, Color.BLACK, false)
	assert_eq(mat.get_shader_parameter("albedo_color"), after_one_stage,
		"the next stage lands on the SAME ground colour, not a darker one")
	# The re-seed is what provides that: without it the operation compounds, which is
	# exactly the bug it guards. (Characterising the helper, not endorsing the path —
	# _ready always re-seeds before _apply_weather_look runs.)
	host._tint_road(0.5, Color.BLACK, false)
	assert_lt(float(mat.get_shader_parameter("albedo_color").r), after_one_stage.r,
		"tinting an already-tinted value compounds — hence the per-stage re-seed")
	# Lerping toward a named colour — dust, and any future condition (snow) that names
	# one. Same idempotence, and no colour literal reaches world.gd.
	var target := Color(0.6, 0.5, 0.3, 1.0)
	seed_baseline.call()
	host._tint_road(0.4, target, true)
	var tinted_once: Color = mat.get_shader_parameter("albedo_color")
	assert_ne(tinted_once, base, "a colour tint does move the ground toward the target")
	seed_baseline.call()
	host._tint_road(0.4, target, true)
	assert_eq(mat.get_shader_parameter("albedo_color"), tinted_once,
		"a colour tint is idempotent across stages too")
	# Full strength lands exactly on the named colour (alpha preserved) — the property
	# that makes "name a colour field" a complete description of the mode.
	seed_baseline.call()
	host._tint_road(1.0, target, true)
	var full: Color = mat.get_shader_parameter("albedo_color")
	assert_almost_eq(full.r, target.r, 0.001, "amount 1.0 reaches the named colour")
	assert_almost_eq(full.a, base.a, 0.001, "and preserves the material's alpha")
