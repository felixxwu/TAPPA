extends SceneTree

# ---------------------------------------------------------------------------
# Low-poly vegetation builder + multi-angle renderer + GLB exporter.
# Geometry is procedural, flat-shaded (per-face normals, no shared verts).
# Textures (bark / foliage) are loaded from disk (online-sourced, see
# models/vegetation/README.md for provenance + licensing).
#
# Pure tooling — not shipped in the game. Run headlessly:
#
#   xvfb-run -a godot --path rally --rendering-driver opengl3 \
#       --script tools/build_vegetation.gd
#
# Writes tree_pine.glb / tree_oak.glb / bush.glb to models/vegetation/ and a
# 4-angle contact sheet per model to models/vegetation/previews/.
# ---------------------------------------------------------------------------

var TEX_DIR := ProjectSettings.globalize_path("res://models/vegetation/textures/")
var OUT_DIR := ProjectSettings.globalize_path("res://models/vegetation/")

var bark_mat: StandardMaterial3D
var foliage_mat_tpl: StandardMaterial3D

# ---- geometry helpers -----------------------------------------------------

func _tex(path: String, srgb: bool) -> ImageTexture:
	var img := Image.load_from_file(path)
	if srgb:
		pass
	return ImageTexture.create_from_image(img)

func add_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3,
		ua: Vector2, ub: Vector2, uc: Vector2, outward: Vector3) -> void:
	var n := (b - a).cross(c - a)
	if n.length() < 1e-9:
		return
	n = n.normalized()
	# flip winding+normal so the face points outward
	if outward != Vector3.ZERO and n.dot(outward) < 0.0:
		var t := b; b = c; c = t
		var tu := ub; ub = uc; uc = tu
		n = -n
	st.set_normal(n); st.set_uv(ua); st.add_vertex(a)
	st.set_normal(n); st.set_uv(ub); st.add_vertex(b)
	st.set_normal(n); st.set_uv(uc); st.add_vertex(c)

func add_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		ua: Vector2, ub: Vector2, uc: Vector2, ud: Vector2, outward: Vector3) -> void:
	add_tri(st, a, b, c, ua, ub, uc, outward)
	add_tri(st, a, c, d, ua, uc, ud, outward)

# tapered tube (frustum). r1==0 -> cone. center on (cx,cz) axis.
func add_frustum(st: SurfaceTool, cx: float, cz: float, y0: float, y1: float,
		r0: float, r1: float, sides: int, v0: float, v1: float) -> void:
	for i in sides:
		var a0 := TAU * float(i) / sides
		var a1 := TAU * float(i + 1) / sides
		var u0 := float(i) / sides
		var u1 := float(i + 1) / sides
		var b00 := Vector3(cx + cos(a0) * r0, y0, cz + sin(a0) * r0)
		var b10 := Vector3(cx + cos(a1) * r0, y0, cz + sin(a1) * r0)
		var out0 := Vector3(cos(a0), 0.2, sin(a0))
		var outm := Vector3(cos((a0 + a1) * 0.5), 0.2, sin((a0 + a1) * 0.5))
		if r1 <= 0.0001:
			var apex := Vector3(cx, y1, cz)
			add_tri(st, b00, b10, apex,
				Vector2(u0, v0), Vector2(u1, v0), Vector2((u0 + u1) * 0.5, v1), outm)
		else:
			var t00 := Vector3(cx + cos(a0) * r1, y1, cz + sin(a0) * r1)
			var t10 := Vector3(cx + cos(a1) * r1, y1, cz + sin(a1) * r1)
			add_quad(st, b00, b10, t10, t00,
				Vector2(u0, v0), Vector2(u1, v0), Vector2(u1, v1), Vector2(u0, v1), out0)

# low-poly lumpy sphere centred at c. seed drives per-vertex radius jitter.
func add_blob(st: SurfaceTool, c: Vector3, radius: float, rings: int, sectors: int,
		seed: int, jitter: float, squash: float) -> void:
	var rnd := RandomNumberGenerator.new()
	rnd.seed = seed
	var grid := []
	for ri in range(rings + 1):
		var row := []
		var phi := PI * float(ri) / rings        # 0..PI top->bottom
		for si in range(sectors + 1):
			var theta := TAU * float(si) / sectors
			# outward-only jitter keeps the blob convex (no dark inward gashes)
			var rr := radius * (1.0 + rnd.randf() * jitter)
			if si == sectors:
				rr = (row[0] as Vector3).distance_to(c) # close seam exactly
			var p := c + Vector3(
				sin(phi) * cos(theta) * rr,
				cos(phi) * rr * squash,
				sin(phi) * sin(theta) * rr)
			row.append(p)
		grid.append(row)
	for ri in range(rings):
		for si in range(sectors):
			var a: Vector3 = grid[ri][si]
			var b: Vector3 = grid[ri][si + 1]
			var cc: Vector3 = grid[ri + 1][si + 1]
			var d: Vector3 = grid[ri + 1][si]
			var u0 := float(si) / sectors * 2.0
			var u1 := float(si + 1) / sectors * 2.0
			var v0 := float(ri) / rings * 2.0
			var v1 := float(ri + 1) / rings * 2.0
			var center_out := ((a + b + cc + d) * 0.25) - c
			add_quad(st, a, b, cc, d,
				Vector2(u0, v0), Vector2(u1, v0), Vector2(u1, v1), Vector2(u0, v1), center_out)

# ---- materials ------------------------------------------------------------

func make_foliage_mat(tint: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = foliage_mat_tpl.albedo_texture
	m.albedo_color = tint
	m.roughness = 1.0
	m.metallic = 0.0
	m.uv1_scale = Vector3(1.5, 1.5, 1.0)
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	return m

# ---- model builders -------------------------------------------------------
# Each returns a MeshInstance3D with surface 0 = bark, surface 1 = foliage.

func finalize(bark_st: SurfaceTool, fol_st: SurfaceTool, fol_mat: StandardMaterial3D) -> MeshInstance3D:
	var mesh := ArrayMesh.new()
	bark_st.commit(mesh)
	fol_st.commit(mesh)
	mesh.surface_set_material(0, bark_mat)
	mesh.surface_set_material(1, fol_mat)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	return mi

func build_pine() -> MeshInstance3D:
	var bark := SurfaceTool.new(); bark.begin(Mesh.PRIMITIVE_TRIANGLES)
	var fol := SurfaceTool.new(); fol.begin(Mesh.PRIMITIVE_TRIANGLES)
	add_frustum(bark, 0, 0, 0.0, 1.0, 0.16, 0.10, 6, 0.0, 1.0)
	# three stacked cones
	add_frustum(fol, 0, 0, 0.55, 1.55, 0.75, 0.0, 8, 0.0, 1.0)
	add_frustum(fol, 0, 0, 1.20, 2.15, 0.58, 0.0, 8, 0.0, 1.0)
	add_frustum(fol, 0, 0, 1.80, 2.70, 0.40, 0.0, 8, 0.0, 1.0)
	return finalize(bark, fol, make_foliage_mat(Color(0.62, 0.82, 0.55)))

func build_oak() -> MeshInstance3D:
	var bark := SurfaceTool.new(); bark.begin(Mesh.PRIMITIVE_TRIANGLES)
	var fol := SurfaceTool.new(); fol.begin(Mesh.PRIMITIVE_TRIANGLES)
	add_frustum(bark, 0, 0, 0.0, 1.05, 0.17, 0.12, 6, 0.0, 1.0)
	add_blob(fol, Vector3(0, 1.75, 0), 0.95, 5, 9, 11, 0.16, 1.05)
	add_blob(fol, Vector3(0.45, 1.45, 0.15), 0.55, 4, 8, 23, 0.16, 1.0)
	add_blob(fol, Vector3(-0.40, 1.55, -0.20), 0.55, 4, 8, 37, 0.16, 1.0)
	return finalize(bark, fol, make_foliage_mat(Color(0.85, 0.95, 0.70)))

func build_bush() -> MeshInstance3D:
	var bark := SurfaceTool.new(); bark.begin(Mesh.PRIMITIVE_TRIANGLES)
	var fol := SurfaceTool.new(); fol.begin(Mesh.PRIMITIVE_TRIANGLES)
	# tiny stub so bark surface is non-empty (buried fully below ground, hidden)
	add_frustum(bark, 0, 0, -0.35, -0.10, 0.08, 0.05, 5, 0.0, 1.0)
	# blobs sit into the ground (centres low) so they overlap and close the base
	add_blob(fol, Vector3(0, 0.30, 0), 0.48, 4, 9, 5, 0.16, 0.95)
	add_blob(fol, Vector3(0.36, 0.20, 0.10), 0.38, 4, 8, 9, 0.16, 0.9)
	add_blob(fol, Vector3(-0.32, 0.18, -0.12), 0.36, 4, 8, 19, 0.16, 0.9)
	return finalize(bark, fol, make_foliage_mat(Color(0.80, 0.95, 0.62)))

# ---- rendering ------------------------------------------------------------

var vp: SubViewport
var cam: Camera3D
var pivot: Node3D

func setup_stage() -> void:
	vp = SubViewport.new()
	vp.size = Vector2i(TILE, TILE_H)
	vp.transparent_bg = false
	vp.world_3d = World3D.new()
	vp.msaa_3d = Viewport.MSAA_4X
	get_root().add_child(vp)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.74, 0.83, 0.92)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.6, 0.68)
	env.ambient_light_energy = 0.9

	cam = Camera3D.new()
	cam.environment = env
	cam.fov = 38.0
	vp.add_child(cam)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-42, -55, 0)
	key.light_energy = 1.25
	vp.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20, 130, 0)
	fill.light_energy = 0.35
	fill.light_color = Color(0.8, 0.85, 1.0)
	vp.add_child(fill)

	# ground disc
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new(); pm.size = Vector2(8, 8)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.46, 0.52, 0.36)
	gm.roughness = 1.0
	ground.material_override = gm
	vp.add_child(ground)

	pivot = Node3D.new()
	vp.add_child(pivot)

const TILE := 360
const TILE_H := 440

func render_one() -> Image:
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await process_frame
	await process_frame
	await process_frame
	return vp.get_texture().get_image()

# render a model from several angles into one montage row image
func render_model(model: MeshInstance3D, top_y: float, look_y: float, dist: float) -> Image:
	for c in pivot.get_children():
		pivot.remove_child(c); c.queue_free()
	pivot.add_child(model)
	pivot.rotation = Vector3.ZERO

	# (yaw, extra camera height) per view: front-3/4, side, back-3/4, elevated hero
	var views := [
		Vector2(25.0, 0.35),
		Vector2(90.0, 0.35),
		Vector2(200.0, 0.35),
		Vector2(135.0, top_y * 0.9),
	]
	var montage := Image.create(TILE * views.size(), TILE_H, false, Image.FORMAT_RGB8)
	var idx := 0
	for v in views:
		pivot.rotation_degrees = Vector3(0, v.x, 0)
		cam.position = Vector3(0, look_y + v.y, dist)
		cam.look_at(Vector3(0, look_y, 0), Vector3.UP)
		var img := await render_one()
		img.convert(Image.FORMAT_RGB8)
		montage.blit_rect(img, Rect2i(0, 0, TILE, TILE_H), Vector2i(idx * TILE, 0))
		idx += 1
	return montage

func export_glb(model: MeshInstance3D, name: String) -> void:
	var holder := Node3D.new()
	holder.name = name
	var m: MeshInstance3D = model.duplicate()
	holder.add_child(m)
	m.owner = holder
	get_root().add_child(holder)
	await process_frame
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_scene(holder, state)
	if err == OK:
		doc.write_to_filesystem(state, OUT_DIR + name + ".glb")
		print("  exported ", name, ".glb")
	else:
		print("  GLB export FAILED for ", name, " err=", err)
	get_root().remove_child(holder); holder.queue_free()

func _init() -> void:
	# materials
	bark_mat = StandardMaterial3D.new()
	bark_mat.albedo_texture = _tex(TEX_DIR + "bark.jpg", true)
	bark_mat.albedo_color = Color(0.95, 0.85, 0.75)
	bark_mat.roughness = 1.0
	bark_mat.uv1_scale = Vector3(1.0, 1.0, 1.0)
	foliage_mat_tpl = StandardMaterial3D.new()
	foliage_mat_tpl.albedo_texture = _tex(TEX_DIR + "foliage.jpg", true)

	setup_stage()
	await process_frame
	await process_frame

	var specs := [
		{"name": "tree_pine", "fn": "build_pine", "top": 2.7, "look": 1.35, "dist": 5.0},
		{"name": "tree_oak", "fn": "build_oak", "top": 2.6, "look": 1.35, "dist": 5.2},
		{"name": "bush", "fn": "build_bush", "top": 0.95, "look": 0.45, "dist": 2.4},
	]
	for s in specs:
		var model: MeshInstance3D = call(s["fn"])
		print("built ", s["name"], " surfaces=", model.mesh.get_surface_count(),
			" verts=", _count_verts(model.mesh))
		var montage: Image = await render_model(model, s["top"], s["look"], s["dist"])
		montage.save_png(OUT_DIR + "previews/" + s["name"] + ".png")
		print("  saved preview ", s["name"], ".png")
		await export_glb(model, s["name"])
	print("ALL_DONE")
	quit()

func _count_verts(mesh: ArrayMesh) -> int:
	var n := 0
	for i in mesh.get_surface_count():
		n += mesh.surface_get_arrays(i)[Mesh.ARRAY_VERTEX].size()
	return n
