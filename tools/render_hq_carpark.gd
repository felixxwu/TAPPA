extends SceneTree
# One-off: boot the real HQ scene with a full collection parked and capture the
# EXTERIOR (title) shot and the CARPARK (car-select) framing, so the outdoor car
# park — its painted bays and the focused-car camera angle — can be eyeballed.
# Run via tools/render_hq_carpark.sh. Not part of the normal build — a verify aid.
#
# NOTE: this is run with `--script` under the opengl3 driver. Referencing the
# `hq.View.*` enum (or any hq.gd member that forces a deep analysis of hq.gd)
# makes the analyzer compile hq.gd in a context where its autoload globals
# (Config/Save/…) aren't registered → "Compile Error: Identifier not found".
# So drive the HQ only through plain method calls and reach the Save autoload by
# walking root's children rather than by name.

func _initialize() -> void:
	await process_frame
	# Find the Save autoload by walking root's children (a get_node("Save") literal
	# would be const-folded + resolved against the autoload list, which isn't
	# populated for the `--script` entry file under opengl3).
	var sm: Node = null
	for child in get_root().get_children():
		if child.name == "Save":
			sm = child
			break
	# Throwaway profile so the render never touches the real save, and fill the lot
	# with a full 10-car collection (duplicates are fine — each is its own instance).
	sm.profile_path = "user://render_carpark_profile.json"
	sm.save_disabled = true
	sm.load_or_new()
	# Start from a clean roster (load_or_new can recover a stale .bak), then grant 9 so
	# the starter makes a full 10-car collection (== the cap → boots to the title).
	sm.profile["cars"] = []
	for id in ["focus", "charger", "porsche911", "lfa", "aventador", "focus", "charger", "porsche911", "lfa"]:
		sm.grant_car(id, false)

	var svp := SubViewport.new()
	svp.size = Vector2i(1280, 720)
	svp.own_world_3d = true
	svp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	get_root().add_child(svp)

	var hq: Node3D = load("res://hq.tscn").instantiate()
	svp.add_child(hq)

	# Let _ready() build the HQ (it awaits a few frames behind a loading cover). It
	# boots straight to the exterior/title station, so just wait and capture that.
	for _i in 50:
		await process_frame
	_save_shot(svp, "exterior")

	# Car park (car-select): pick an open-class rally and enter so the eligible
	# lineup is parked, then capture the focused-car framing (no hq.View refs).
	hq._on_rally_pin("shakedown")
	hq._enter_car_screen()
	for _i in 40:
		await process_frame
	_save_shot(svp, "carpark")

	# A focused car a few slots along, to check the framing pans cleanly.
	hq._cycle_focus(3)
	for _i in 24:
		await process_frame
	_save_shot(svp, "carpark_focus3")

	quit()


func _save_shot(svp: SubViewport, shot_name: String) -> void:
	var img := svp.get_texture().get_image()
	var path := "res://docs/garage/hq_%s_view.png" % shot_name
	var err := img.save_png(path)
	print("[hq-render] ", path, "  ", img.get_size(), "  err=", err)
