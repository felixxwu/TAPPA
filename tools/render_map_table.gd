extends SceneTree
# render_map_table.gd — multi-angle still renderer for the HQ map table model.
#
# Loads scripts/map_table.gd, builds it, lays a stand-in map plane on top (so the
# table reads in its real context), then captures the same scene from several camera
# poses to PNGs so the furniture can be iterated on visually. Run via
# tools/render_map_table.sh (which provides the xvfb display + GL driver). Output
# goes to docs/map_table/.
#
# Renders into a fixed-size SubViewport (not the OS window) so the output is a
# reliable size regardless of the host window, and `new()`s the model script
# directly so the render stays isolated from the project's autoloads.

const OUT_DIR := "res://docs/map_table/"
const IMG_W := 1280
const IMG_H := 720

# Camera poses: [name, eye, look_at, fov]. The table is ~4.6 m square, ~0.9 m tall,
# origin at floor centre, top at y = 0.9.
const SHOTS := [
	["01_three_quarter", Vector3(5.0, 3.6, 5.6), Vector3(0.0, 0.6, 0.0), 50.0],
	["02_front_on", Vector3(0.0, 1.6, 6.6), Vector3(0.0, 0.7, 0.0), 48.0],
	["03_low_corner", Vector3(4.6, 0.9, 4.6), Vector3(0.0, 0.5, 0.0), 55.0],
	["04_top_down", Vector3(0.2, 6.2, 0.6), Vector3(0.0, 0.9, 0.0), 48.0],
	["05_leg_detail", Vector3(3.2, 0.5, 3.6), Vector3(1.6, 0.3, 1.6), 50.0],
]


func _initialize() -> void:
	var svp := SubViewport.new()
	svp.size = Vector2i(IMG_W, IMG_H)
	svp.own_world_3d = true
	svp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	svp.transparent_bg = false
	svp.msaa_3d = Viewport.MSAA_2X
	get_root().add_child(svp)

	# Garage-ish environment so the wood reads under interior lighting.
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.20, 0.21, 0.24)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.6, 0.66)
	env.ambient_light_energy = 0.9
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	we.environment = env
	svp.add_child(we)

	var key := DirectionalLight3D.new()
	key.rotation = Vector3(deg_to_rad(-55.0), deg_to_rad(40.0), 0.0)
	key.light_energy = 1.2
	key.shadow_enabled = true
	svp.add_child(key)

	# Concrete-ish floor under the table for grounding + shadow catch.
	var floor_mi := MeshInstance3D.new()
	var fp := PlaneMesh.new()
	fp.size = Vector2(24.0, 24.0)
	floor_mi.mesh = fp
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = Color(0.34, 0.35, 0.38)
	fmat.roughness = 0.95
	floor_mi.material_override = fmat
	svp.add_child(floor_mi)

	var MapTableScript := load("res://scripts/map_table.gd")
	var table: Node3D = MapTableScript.new()
	svp.add_child(table)

	# Stand-in map plane on top, mirroring hq.gd's placement, so the table reads in
	# context (the satellite photo laid over the square top).
	var top_y: float = table.table_size.y
	var plane := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(table.table_size.x * 0.92, table.table_size.z * 0.92)
	plane.mesh = pm
	var pmat := StandardMaterial3D.new()
	var map_tex := load("res://textures/map_table.jpg") as Texture2D
	if map_tex != null:
		pmat.albedo_texture = map_tex
	pmat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	pmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	plane.material_override = pmat
	plane.position = Vector3(0.0, top_y + 0.01, 0.0)
	svp.add_child(plane)

	var cam := Camera3D.new()
	cam.current = true
	svp.add_child(cam)

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	for _i in 6:
		await process_frame

	for shot in SHOTS:
		cam.fov = shot[3]
		cam.position = shot[1]
		cam.look_at(shot[2], Vector3.UP)
		await process_frame
		await process_frame
		var img := svp.get_texture().get_image()
		var path: String = OUT_DIR + String(shot[0]) + ".png"
		var err := img.save_png(path)
		print("[render] ", shot[0], " -> ", path, "  ", img.get_size(), "  err=", err)

	print("[render] done")
	quit()
