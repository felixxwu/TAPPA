extends SceneTree
# Offscreen model-iteration harness. Instantiates a model into a SubViewport with
# a desert-ish environment and renders it from several camera angles to PNGs, so
# the arch can be eyeballed and iterated headlessly:
#
#   xvfb-run -a godot --path rally --rendering-driver opengl3 \
#       --script tools/render_model.gd
#
# Outputs land in tools/render_out/. Pure tooling — not shipped in the game.

const OUT_DIR := "res://tools/render_out"
const RES := Vector2i(1000, 750)


func _init() -> void:
	_run()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	# Dedicated SubViewport so resolution is independent of the project window.
	var vp := SubViewport.new()
	vp.size = RES
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.msaa_3d = Viewport.MSAA_2X
	get_root().add_child(vp)

	var world := Node3D.new()
	vp.add_child(world)

	# Environment: warm desert sky + ground.
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.62, 0.74, 0.86)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.72, 0.78)
	env.ambient_light_energy = 1.0
	we.environment = env
	world.add_child(we)

	# Ground plane (sandy tarmac strip vibe).
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(60, 60)
	ground.mesh = plane
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.78, 0.71, 0.55)
	gmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ground.material_override = gmat
	world.add_child(ground)

	# A road strip down the middle, at the real in-game track_width (6 m), so the
	# render shows the arch's legs standing clear of the road on both sides.
	var road := MeshInstance3D.new()
	var rplane := PlaneMesh.new()
	rplane.size = Vector2(6, 60)
	road.mesh = rplane
	var rmat := StandardMaterial3D.new()
	rmat.albedo_color = Color(0.32, 0.31, 0.30)
	rmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	road.material_override = rmat
	road.position = Vector3(0, 0.01, 0)
	world.add_child(road)

	# The model under test, sized exactly as world.gd places it: a clear opening of
	# track_width (6 m) + a 1.5 m margin each side = 9 m, so the legs clear the road.
	var ArchScene = load("res://scripts/finish_arch.gd")
	var arch = ArchScene.new()
	arch.span = 6.0 + 2.0 * 1.5
	world.add_child(arch)

	var cam := Camera3D.new()
	world.add_child(cam)

	await process_frame
	await process_frame

	# Camera angles: name -> (position, look-at target).
	var target := Vector3(0, 3.0, 0)
	var shots := {
		"front": Vector3(0, 3.2, 16),
		"three_quarter": Vector3(11, 4.0, 13),
		"side": Vector3(17, 3.5, 0.5),
		"hero_low": Vector3(7, 1.4, 11),
		"through": Vector3(0, 2.0, 7.5),
	}
	for shot_name in shots:
		cam.position = shots[shot_name]
		cam.look_at(target, Vector3.UP)
		# A couple of frames so the render target updates with the new transform.
		await process_frame
		await process_frame
		var img := vp.get_texture().get_image()
		var path := "%s/%s.png" % [OUT_DIR, shot_name]
		img.save_png(path)
		print("SAVED ", path, " ", img.get_size())

	quit()
