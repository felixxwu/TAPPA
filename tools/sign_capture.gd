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
	# Let the bodies settle AND the start countdown (a centre-screen 3-2-1 overlay)
	# finish, so it doesn't sit over the sign in the shot.
	for i in range(360):
		await get_tree().process_frame

	# Stop the camera manager forcing the chase/bonnet camera current each frame.
	var cm := world.get_node_or_null("CameraManager")
	if cm != null:
		cm.set_process(false)
		cm.set_physics_process(false)

	# DRIVER APPROACH POV: the car travels along the sign's local -Z (= road
	# tangent), so it comes from the +Z (up-track) side and sees that face. Sit the
	# camera up-track + above, looking down-track past the sign, so the arrow AND the
	# road bending beyond it are both in frame for a direct comparison.
	var idx := int(OS.get_environment("SIGN_IDX")) if OS.has_environment("SIGN_IDX") else 0
	idx = clampi(idx, 0, field.get_child_count() - 1)
	# Health check: how many signs are still upright (local +Y near world up) after
	# the settle, and how far each drifted from its spawn — toppled/flung signs would
	# explain wrong-looking arrows and missing signs.
	var toppled := 0
	for c in field.get_children():
		var up_dot := (c as Node3D).global_transform.basis.y.dot(Vector3.UP)
		if up_dot < 0.9:
			toppled += 1
	print("sign-render: %d/%d signs NOT upright after settle" % [toppled, field.get_child_count()])

	var sign_node := field.get_child(idx) as Node3D
	var key := String(sign_node.get_meta("texture_key", "?"))
	var updot := sign_node.global_transform.basis.y.dot(Vector3.UP)
	print("sign-render: SIGN_IDX=%d key=%s upright_dot=%.3f pos=%s" % [idx, key, updot, sign_node.global_position])
	var sp := sign_node.global_position
	var bz := sign_node.global_transform.basis.z  # world dir of local +Z = up-track
	var cam := Camera3D.new()
	add_child(cam)
	if OS.has_environment("PLAYER_VIEW"):
		# The real player's chase view at the start: behind + above the car, looking
		# down the track at the first corner(s) and their signs.
		var car := world.get_node("Car") as Node3D
		var ct := car.global_transform
		var carfwd := -ct.basis.z
		cam.global_position = ct.origin - carfwd * 7.0 + Vector3(0.0, 3.2, 0.0)
		cam.look_at(ct.origin + carfwd * 14.0 + Vector3(0.0, 0.5, 0.0), Vector3.UP)
		cam.fov = 60.0
	else:
		# Up-track (+Z side) and above, looking DOWN at the sign — frames the approach
		# face reliably plus the road bending beyond it for an arrow-vs-bend compare.
		cam.global_position = sp + bz * 3.5 + Vector3(0.0, 1.0, 0.0)
		cam.look_at(sp + Vector3(0.0, 0.65, 0.0), Vector3.UP)
		cam.fov = 44.0
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
