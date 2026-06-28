extends SceneTree
# render_garage.gd — multi-angle still renderer for the garage model.
#
# Loads scripts/garage.gd, builds it, then captures the same scene from several
# camera poses to PNGs so the model can be iterated on visually (the task asks
# to "render from different angles to iterate"). Run via tools/render_garage.sh
# (which provides the xvfb display + GL driver). Output goes to docs/garage/.
#
# Renders into a fixed-size SubViewport (not the OS window) so the output is a
# reliable 1280x720 regardless of the host window size, and `new()`s the garage
# script directly so the render stays isolated from the project's autoloads.

const OUT_DIR := "res://docs/garage/"
const IMG_W := 1280
const IMG_H := 720

# Camera poses: [name, eye, look_at, fov]. Framed for the two-bay empty shell.
const SHOTS := [
	["01_front_three_quarter", Vector3(11.0, 5.5, 13.0), Vector3(0.0, 2.2, -2.5), 52.0],
	["02_front_on", Vector3(0.0, 4.0, 14.0), Vector3(0.0, 3.0, -3.0), 50.0],
	["03_bay_interior", Vector3(3.0, 1.9, 3.0), Vector3(-1.5, 1.6, -6.0), 64.0],
	["04_side", Vector3(17.0, 6.0, 9.0), Vector3(0.0, 3.0, -4.5), 45.0],
	["05_high_overview", Vector3(11.0, 13.0, 14.0), Vector3(0.0, 0.5, -4.0), 52.0],
]


func _initialize() -> void:
	# Offscreen viewport with its own 3D world, sized exactly to the output.
	var svp := SubViewport.new()
	svp.size = Vector2i(IMG_W, IMG_H)
	svp.own_world_3d = true
	svp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	svp.transparent_bg = false
	get_root().add_child(svp)

	var GarageScript := load("res://scripts/garage.gd")
	var garage: Node3D = GarageScript.new()
	svp.add_child(garage)

	var cam := Camera3D.new()
	cam.current = true
	svp.add_child(cam)

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	# Let the scene build + light settle before the first capture.
	for _i in 5:
		await process_frame

	for shot in SHOTS:
		cam.fov = shot[3]
		cam.position = shot[1]
		cam.look_at(shot[2], Vector3.UP)
		# A couple of frames so shadows / lighting resolve for this pose.
		await process_frame
		await process_frame
		var img := svp.get_texture().get_image()
		var path: String = OUT_DIR + String(shot[0]) + ".png"
		var err := img.save_png(path)
		print("[render] ", shot[0], " -> ", path, "  ", img.get_size(), "  err=", err)

	print("[render] done")
	quit()
