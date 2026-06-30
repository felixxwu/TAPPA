extends Node3D
# Controlled single-sign render to settle arrow orientation. One sign with a known
# tangent (+Z), viewed from the driver's approach (camera up-track looking down-
# track). Compare the rendered approach face to the source arrow_2_right.png.

func _ready() -> void:
	get_window().size = Vector2i(480, 480)
	var tm := TerrainManager.new()
	add_child(tm)
	var field := SignField.new()
	add_child(field)
	var params := Config.data.sign_render_params()
	# The PAIR for one corner: same texture + tangent, opposite road edges. Both
	# should read identically to the approaching driver (tangent +Z, approach from -Z).
	var layout := [
		{"kind": "turn", "texture_key": "arrow_2_right", "pos": Vector2(0, 0), "tangent": Vector2(0, 1), "side": 1},
		{"kind": "turn", "texture_key": "arrow_2_right", "pos": Vector2(0, 0), "tangent": Vector2(0, 1), "side": -1},
	]
	field.build(layout, tm, params)
	for i in range(8):
		await get_tree().process_frame
	var sp := (field.get_child(0) as Node3D).global_position
	var cam := Camera3D.new()
	add_child(cam)
	# Up-track (-Z) centred between the pair, looking down-track (+Z) — driver's view.
	cam.global_position = Vector3(0.0, 1.6, sp.z - 9.0)
	cam.look_at(Vector3(0.0, 0.7, sp.z + 1.0), Vector3.UP)
	cam.fov = 72.0
	cam.current = true
	for i in range(6):
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	img.save_png(ProjectSettings.globalize_path("res://../sign_controlled.png"))
	print("controlled-sign: saved (driver approach view of arrow_2_right; should curve to the driver's RIGHT)")
	get_tree().quit()
