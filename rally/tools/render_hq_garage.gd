extends SceneTree
# One-off: boot the real HQ scene and capture the GARAGE station so the new
# garage model can be eyeballed in-context (map table in the left bay, tuning
# lift in the right bay). Run via tools/render_hq_garage.sh. Not part of the
# normal build — a verification aid.

const OUT := "res://docs/garage/hq_garage_view.png"


func _initialize() -> void:
	var svp := SubViewport.new()
	svp.size = Vector2i(1280, 720)
	svp.own_world_3d = true
	svp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	get_root().add_child(svp)

	var hq: Node3D = load("res://hq.tscn").instantiate()
	svp.add_child(hq)

	# Let _ready() build the HQ (it awaits a few frames behind a loading cover).
	for _i in 40:
		await process_frame

	# Capture each camera station that frames the garage, snapping between them.
	for shot in [["garage", hq.View.GARAGE], ["table", hq.View.TABLE], ["lift", hq.View.LIFT]]:
		hq._go_to(shot[1], true)
		for _i in 18:
			await process_frame
		var img := svp.get_texture().get_image()
		var path: String = "res://docs/garage/hq_%s_view.png" % shot[0]
		var err := img.save_png(path)
		print("[hq-render] ", path, "  ", img.get_size(), "  err=", err)
	quit()
