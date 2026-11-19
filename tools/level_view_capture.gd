extends Node
# Verification aid: boot level_view.tscn on the dev level and photograph it.
# Default: chase camera after the car settles, plus a high three-quarter view
# (tools/level_view_capture_<n>.png). Run:
#
#   godot --path . res://tools/level_view_capture.tscn
#
# Photo-match mode (env vars): CAP_POSES="x,z,tx,tz;..." renders an eye-height camera (CAP_EYE m above the
# ground, CAP_FOV vertical degrees) at each x,z looking at tx,tz, into CAP_OUT/<n>.png.

func _ready() -> void:
	get_window().size = Vector2i(1280, 720)
	Save.save_disabled = true
	var world := (load("res://level_view.tscn") as PackedScene).instantiate()
	add_child(world)
	for _i in 150:
		await get_tree().process_frame
	var poses := OS.get_environment("CAP_POSES")
	if not poses.is_empty():
		await _photo_match(world, poses)
		get_tree().quit()
		return
	get_viewport().get_texture().get_image().save_png("res://tools/level_view_capture_0.png")
	var car: Node3D = world.get_node("Car")
	var cam := Camera3D.new()
	world.add_child(cam)
	var eye := car.global_position + car.global_basis.z * 25.0 + Vector3(12, 12, 0)
	cam.global_transform = Transform3D(Basis.looking_at(car.global_position - car.global_basis.z * 30.0 - eye), eye)
	cam.fov = 70.0
	cam.make_current()
	for _i in 30:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png("res://tools/level_view_capture_1.png")
	get_tree().quit()


func _photo_match(world: Node, poses: String) -> void:
	var level: LevelView = world.get_node("Level")
	var out := OS.get_environment("CAP_OUT")
	var eye_h := float(OS.get_environment("CAP_EYE")) if OS.get_environment("CAP_EYE") != "" else 2.0
	var fov := float(OS.get_environment("CAP_FOV")) if OS.get_environment("CAP_FOV") != "" else 66.0
	world.get_node("Car").visible = false
	world.get_node("HUD").visible = false
	var cam := Camera3D.new()
	world.add_child(cam)
	cam.fov = fov
	cam.far = 800.0
	cam.make_current()
	var n := 0
	for p in poses.split(";"):
		var v := p.split(",")
		var eye := Vector3(float(v[0]), 0, float(v[1]))
		eye.y = level.height_at(eye.x, eye.z) + eye_h
		var tgt := Vector3(float(v[2]), eye.y - 1.0, float(v[3]))
		cam.global_transform = Transform3D(Basis.looking_at(tgt - eye), eye)
		for _i in 20:
			await get_tree().process_frame
		get_viewport().get_texture().get_image().save_png("%s/%s.png" % [out, v[4] if v.size() > 4 else str(n)])
		n += 1
