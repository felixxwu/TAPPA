extends Node3D
# Verification aid: boot as the main scene (so the project's autoloads — Config,
# Save, RallySession — are available, unlike a --script run), instantiate the real
# main.tscn world, and photograph one roadside turn-arrow sign from the road. Proves
# the baked texture actually lands on the A-frame in-context. Captures to
# sign_trackside_check.png. Run via:
#
#   xvfb-run -a -s "-screen 0 1280x960x24" godot --path rally \
#       --rendering-driver opengl3 res://tools/sign_capture.tscn
#
# Pure tooling — not shipped in the game.


func _ready() -> void:
	get_window().size = Vector2i(960, 720)
	var world := (load("res://main.tscn") as PackedScene).instantiate()
	add_child(world)

	# Wait for world._ready() to generate terrain/track and build the sign field.
	var field: Node = null
	for i in range(4000):
		await get_tree().process_frame
		field = _find_sign_field(world)
		if field != null and int(field.sign_count) > 0:
			break
	if field == null or int(field.sign_count) == 0:
		printerr("sign-render: no signs were built")
		get_tree().quit()
		return
	# Let the bodies settle on the road for a moment.
	for i in range(40):
		await get_tree().process_frame

	# Stop the camera manager forcing the chase/bonnet camera current each frame.
	var cm := world.get_node_or_null("CameraManager")
	if cm != null:
		cm.set_process(false)
		cm.set_physics_process(false)

	# Frame the first sign from in front of its face (its -Z runs along the road
	# tangent = the face normal), nudged to one side + up for a 3/4 road view.
	var sign := field.get_child(0) as Node3D
	var sp := sign.global_position
	var b := sign.global_transform.basis
	var fwd := -b.z
	var cam := Camera3D.new()
	add_child(cam)
	cam.global_position = sp + fwd * 5.5 + b.x * 3.0 + Vector3(0.0, 2.2, 0.0)
	cam.look_at(sp + Vector3(0.0, 0.4, 0.0), Vector3.UP)
	cam.fov = 55.0
	cam.current = true

	for i in range(6):
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	var out := ProjectSettings.globalize_path("res://../sign_trackside_check.png")
	img.save_png(out)
	print("sign-render: saved %s (sign_count=%d)" % [out, int(field.sign_count)])
	get_tree().quit()


# Recursively find the SignField node (custom classes report their base type, so
# match on the attached script path instead of get_class()).
func _find_sign_field(n: Node) -> Node:
	var scr: Variant = n.get_script()
	if scr != null and String(scr.resource_path).ends_with("sign_field.gd"):
		return n
	for c in n.get_children():
		var r := _find_sign_field(c)
		if r != null:
			return r
	return null
