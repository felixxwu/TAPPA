extends Node
# Measures the level view's draw calls: boots level_view.tscn on the dev level, parks the car at a few spots along
# the road, and prints the frame's total draw calls / objects / primitives, then how many each part of the scene
# adds (by hiding it and measuring again). Needs a window (draw calls are zero headless):
#
#   xvfb-run -a godot --path . --rendering-driver opengl3 res://tools/level_draw_calls.tscn
#
# DRAW_SPOTS="0.1,0.35,0.6,0.85" picks the spots as fractions of the road samples; DRAW_OUT=<dir> also saves a
# screenshot of each spot there (<dir>/spot_<fraction>.png), for comparing a change's look before and after.

const PARTS := ["Level/Trees", "Level/Ground/Cover", "Level/Ground", "Level/Buildings", "Level/LogPile*", "Level/Spectators", "Car"]


func _ready() -> void:
	get_window().size = Vector2i(1280, 720)
	Save.save_disabled = true
	var world := (load("res://level_view.tscn") as PackedScene).instantiate()
	add_child(world)
	var level := world.get_node("Level") as LevelView
	await level.loaded
	var car := world.get_node("Car") as VehicleBody3D
	var spots := (OS.get_environment("DRAW_SPOTS") if OS.get_environment("DRAW_SPOTS") != "" else "0.1,0.35,0.6,0.85").split(",")
	var bake: LevelBake = level._bake
	var totals := {}
	for s in spots:
		var i := clampi(int(float(s) * bake.sx.size()), 0, bake.sx.size() - 2)
		var p := Vector2(bake.sx[i], bake.sz[i])
		var ahead := Vector3(bake.sx[i + 1] - p.x, 0.0, bake.sz[i + 1] - p.y)
		car.reset_to(level.road_pose(p, ahead.normalized()))
		await level._streamer.prefill_async()
		for _f in 120:
			await get_tree().process_frame
		level._trees.settle()
		for _f in 10:
			await get_tree().process_frame
		var row := {"total": _info()}
		if OS.get_environment("DRAW_OUT") != "":
			get_viewport().get_texture().get_image().save_png("%s/spot_%s.png" % [OS.get_environment("DRAW_OUT"), s])
		for part: String in PARTS:
			var nodes := _find(world, part)
			for n in nodes:
				n.visible = false
			for _f in 3:
				await get_tree().process_frame
			row[part] = row["total"] - _info()
			for n in nodes:
				n.visible = true
			for _f in 3:
				await get_tree().process_frame
		var g := level._streamer
		var levels := {"near": [], "mid": [], "far": [], "horizon": []}
		for ts in g._tiles.values():
			if ts.near_mesh != null: levels["near"].append(ts.near_mesh)
		for st in g._chunks.values():
			if st.mid_mesh != null: levels["mid"].append(st.mid_mesh)
			if st.far_mesh != null and st.far_mesh.visible: levels["far"].append(st.far_mesh)
		for hs in g._horizon.values():
			if hs.mesh != null and hs.mesh.visible: levels["horizon"].append(hs.mesh)
		for k: String in levels:
			for n: Node3D in levels[k]:
				n.visible = false
			for _f in 3:
				await get_tree().process_frame
			row["ground_" + k] = row["total"] - _info()
			for n: Node3D in levels[k]:
				n.visible = true
			for _f in 3:
				await get_tree().process_frame
		print("draw_calls spot %s (%.0f, %.0f): %s" % [s, p.x, p.y, _fmt(row)])
		for k: String in row:
			totals[k] = totals.get(k, Vector3i.ZERO) + row[k]
	for k: String in totals:
		totals[k] = totals[k] / spots.size()
	print("draw_calls mean: %s" % _fmt(totals))
	get_tree().quit()


func _info() -> Vector3i:
	return Vector3i(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME))


func _find(world: Node, part: String) -> Array[Node3D]:
	var out: Array[Node3D] = []
	var parent := world.get_node(part.get_base_dir()) if "/" in part else world
	for c in parent.get_children():
		if c is Node3D and c.name.match(part.get_file()):
			out.append(c)
	return out


func _fmt(row: Dictionary) -> String:
	var parts := []
	for k: String in row:
		parts.append("%s=%d calls/%d obj/%dk prims" % [k.get_file(), row[k].x, row[k].y, row[k].z / 1000])
	return ", ".join(parts)
