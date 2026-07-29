extends SceneTree
# Verification aid for the flat-ground vertex cut (todo/mobile-web-performance.md
# E2): render the HQ apron and the podium tarmac pad with the OLD uniform
# (subdiv+1)^2 grid and with the NEW coarse-lattice + fine-edge-ring grid, so the
# smoothstep feather band — the only thing the subdivision ever bought — can be
# compared side by side.
#
# Usage: godot --rendering-driver opengl3 --path . --script res://tools/render_ground_feather.gd
# Writes docs/perf/ground_<case>_<variant>.png. Not part of the build.

const OUT_DIR := "res://docs/perf"


func _initialize() -> void:
	await process_frame
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var cfg = load("res://config/game_config.tres")
	var fth: float = cfg.podium_tarmac_feather_m

	var apron := Rect2(Vector2(cfg.hq_concrete_center.x, cfg.hq_concrete_center.z)
		- cfg.hq_concrete_size * 0.5, cfg.hq_concrete_size)
	var pad_size: Vector2 = Vector2.ONE * float(cfg.podium_tarmac_pad_half) * 2.0
	var podium_pads: Array[Rect2] = [
		Rect2(Vector2(0.0, 0.0) - pad_size * 0.5, pad_size),
		Rect2(Vector2(40.0, 0.0) - pad_size * 0.5, pad_size),
	]
	var hq_pads: Array[Rect2] = [apron]

	# case = [name, plane size, pads, old subdiv, new subdiv, top-down span, focus XZ]
	var cases := [
		["hq", 240.0, hq_pads, 240, 24, 70.0, apron.get_center()],
		["podium", 120.0, podium_pads, 160, 24, 34.0, Vector2(0.0, 0.0)],
	]
	for c in cases:
		for variant in ["before", "after"]:
			var pads: Array[Rect2] = c[2]
			var mesh: ArrayMesh
			if variant == "before":
				mesh = _uniform_ground_mesh(c[1], c[3], pads, fth)
			else:
				mesh = MeshUtil.feathered_ground_mesh(c[1], c[4], pads, fth)
			var arrays := mesh.surface_get_arrays(0)
			print("[ground] %s %s verts=%d tris=%d" % [c[0], variant,
				(arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(),
				(arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3])
			await _shot(mesh, cfg, "%s_%s_top" % [c[0], variant], c[6], c[5], true)
			await _shot(mesh, cfg, "%s_%s_edge" % [c[0], variant], c[6], c[5], false)
	quit()


# The PREVIOUS uniform grid, kept here (and only here) so the "before" image is a
# faithful render of what shipped rather than a description of it.
func _uniform_ground_mesh(size: float, subdiv: int, pads: Array[Rect2], feather: float) -> ArrayMesh:
	var fth := maxf(feather, 0.001)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := maxi(subdiv, 1)
	var step := size / float(n)
	var origin := -size * 0.5
	for j in n + 1:
		for i in n + 1:
			var x := origin + float(i) * step
			var z := origin + float(j) * step
			var w := 0.0
			for pad in pads:
				var c := pad.get_center()
				var d := maxf(absf(x - c.x) - pad.size.x * 0.5, absf(z - c.y) - pad.size.y * 0.5)
				w = maxf(w, 1.0 - smoothstep(0.0, fth, d))
			st.set_color(Color(1.0, 1.0, 1.0, w))
			st.set_uv(Vector2(x, z))
			st.set_uv2(Vector2(1.0, 0.0))
			st.set_normal(Vector3.UP)
			st.add_vertex(Vector3(x, 0.0, z))
	var row := n + 1
	for j in n:
		for i in n:
			var a := j * row + i
			var b := a + 1
			var cc := a + row
			var d := cc + 1
			st.add_index(a); st.add_index(b); st.add_index(cc)
			st.add_index(b); st.add_index(d); st.add_index(cc)
	return st.commit()


# Render `mesh` with the real road-blend ground material into a PNG. `top` picks a
# straight-down orthographic view of a `span`-metre square around `focus` (shows the
# whole feather ring); otherwise a low oblique across the near pad edge.
func _shot(mesh: ArrayMesh, cfg, shot_name: String, focus: Vector2, span: float, top: bool) -> void:
	var svp := SubViewport.new()
	svp.size = Vector2i(900, 900)
	svp.own_world_3d = true
	svp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	get_root().add_child(svp)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.05, 0.06, 0.09)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.6, 0.68)
	e.ambient_light_energy = 1.0
	env.environment = e
	svp.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-50.0), deg_to_rad(40.0), 0.0)
	sun.light_energy = 1.1
	svp.add_child(sun)

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = MeshUtil.feathered_ground_material(cfg)
	svp.add_child(mi)

	var cam := Camera3D.new()
	cam.current = true
	if top:
		cam.projection = Camera3D.PROJECTION_ORTHOGONAL
		cam.size = span
		cam.position = Vector3(focus.x, 60.0, focus.y)
		cam.rotation = Vector3(deg_to_rad(-90.0), 0.0, 0.0)
	else:
		cam.position = Vector3(focus.x, 6.0, focus.y + span * 0.75)
	svp.add_child(cam)
	if not top:
		cam.look_at(Vector3(focus.x, 0.0, focus.y), Vector3.UP)

	for _i in 6:
		await process_frame
	var img := svp.get_texture().get_image()
	var path := "%s/ground_%s.png" % [OUT_DIR, shot_name]
	print("[ground] wrote ", path, " err=", img.save_png(path))
	svp.queue_free()
