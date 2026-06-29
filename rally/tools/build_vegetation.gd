extends SceneTree

# ---------------------------------------------------------------------------
# Low-poly LOW vegetation builder + multi-angle renderer + GLB exporter.
# Bushes / shrubs / ground cover — no trees.
#
# Two kinds of surface are combined per model:
#   * solid faceted blobs  (foliage.jpg, flat-shaded, per-face normals)
#   * leaf cards           (leaves.png alpha-cutout quads, double-sided) so
#                           individual leaves are visible on the silhouette
#
# Textures are online-sourced (CC-BY) — see models/vegetation/README.md.
# Pure tooling, not shipped. Run headlessly:
#
#   xvfb-run -a godot --path rally --rendering-driver opengl3 \
#       --script tools/build_vegetation.gd
#
# Writes *.glb to models/vegetation/ and a 4-angle contact sheet per model to
# models/vegetation/previews/.
# ---------------------------------------------------------------------------

var TEX_DIR := ProjectSettings.globalize_path("res://models/vegetation/textures/")
var OUT_DIR := ProjectSettings.globalize_path("res://models/vegetation/")

var foliage_tex: ImageTexture
var leaf_tex: ImageTexture

# ---- low-level geometry ---------------------------------------------------

func _tex(path: String) -> ImageTexture:
	return ImageTexture.create_from_image(Image.load_from_file(path))

func add_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3,
		ua: Vector2, ub: Vector2, uc: Vector2, outward: Vector3) -> void:
	var n := (b - a).cross(c - a)
	if n.length() < 1e-9:
		return
	n = n.normalized()
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

# low-poly lumpy sphere centred at c (outward-only jitter keeps it convex).
func add_blob(st: SurfaceTool, c: Vector3, radius: float, rings: int, sectors: int,
		seed: int, jitter: float, squash: float) -> void:
	var rnd := RandomNumberGenerator.new()
	rnd.seed = seed
	var grid := []
	for ri in range(rings + 1):
		var row := []
		var phi := PI * float(ri) / rings
		for si in range(sectors + 1):
			var theta := TAU * float(si) / sectors
			var rr := radius * (1.0 + rnd.randf() * jitter)
			if si == sectors:
				rr = (row[0] as Vector3).distance_to(c)
			row.append(c + Vector3(sin(phi) * cos(theta) * rr,
				cos(phi) * rr * squash, sin(phi) * sin(theta) * rr))
		grid.append(row)
	for ri in range(rings):
		for si in range(sectors):
			var a: Vector3 = grid[ri][si]
			var b: Vector3 = grid[ri][si + 1]
			var cc: Vector3 = grid[ri + 1][si + 1]
			var d: Vector3 = grid[ri + 1][si]
			var center_out := ((a + b + cc + d) * 0.25) - c
			add_quad(st, a, b, cc, d, Vector2(0, 0), Vector2(2, 0), Vector2(2, 2),
				Vector2(0, 2), center_out)

# A single double-sided leaf card (quad) centred at `pos`, facing `face`.
# `uv` selects a sub-window of the leaf atlas so each card shows a few leaves.
func add_leaf_card(st: SurfaceTool, pos: Vector3, face: Vector3, w: float, h: float,
		roll: float, uv: Rect2, flip: bool) -> void:
	face = face.normalized()
	var up_ref := Vector3.UP
	if absf(face.dot(up_ref)) > 0.95:
		up_ref = Vector3.RIGHT
	var right := up_ref.cross(face).normalized()
	var up := face.cross(right).normalized()
	# random roll around the facing axis
	right = (right * cos(roll) + up * sin(roll)).normalized()
	up = face.cross(right).normalized()
	var hw := right * (w * 0.5)
	var hh := up * (h * 0.5)
	var a := pos - hw - hh
	var b := pos + hw - hh
	var c := pos + hw + hh
	var d := pos - hw + hh
	var u0 := uv.position.x
	var u1 := uv.position.x + uv.size.x
	if flip:
		var t := u0; u0 = u1; u1 = t
	var v0 := uv.position.y + uv.size.y   # v grows downward in the atlas
	var v1 := uv.position.y
	# normals set explicitly so shading is leaf-front; material is double-sided
	st.set_normal(face); st.set_uv(Vector2(u0, v0)); st.add_vertex(a)
	st.set_normal(face); st.set_uv(Vector2(u1, v0)); st.add_vertex(b)
	st.set_normal(face); st.set_uv(Vector2(u1, v1)); st.add_vertex(c)
	st.set_normal(face); st.set_uv(Vector2(u0, v0)); st.add_vertex(a)
	st.set_normal(face); st.set_uv(Vector2(u1, v1)); st.add_vertex(c)
	st.set_normal(face); st.set_uv(Vector2(u0, v1)); st.add_vertex(d)

# An OPAQUE leaf: a small flat diamond whose silhouette is the geometry itself
# (no alpha cutout) so it keeps early-Z and is cheap on mobile overdraw. UVs
# sample a small green window of the tiling foliage texture for colour variety.
func add_leaf_poly(st: SurfaceTool, pos: Vector3, face: Vector3, w: float, h: float,
		roll: float, rnd: RandomNumberGenerator) -> void:
	face = face.normalized()
	var up_ref := Vector3.UP
	if absf(face.dot(up_ref)) > 0.95:
		up_ref = Vector3.RIGHT
	var right := up_ref.cross(face).normalized()
	var up := face.cross(right).normalized()
	right = (right * cos(roll) + up * sin(roll)).normalized()
	up = face.cross(right).normalized()
	var top := pos + up * (h * 0.5)
	var bot := pos - up * (h * 0.5)
	var lft := pos - right * (w * 0.5) + up * (h * 0.08)
	var rgt := pos + right * (w * 0.5) + up * (h * 0.08)
	var s := 0.12
	var u0 := rnd.randf_range(0.2, 0.78)
	var v0 := rnd.randf_range(0.2, 0.78)
	var uv_t := Vector2(u0 + s * 0.5, v0)
	var uv_b := Vector2(u0 + s * 0.5, v0 + s)
	var uv_l := Vector2(u0, v0 + s * 0.5)
	var uv_r := Vector2(u0 + s, v0 + s * 0.5)
	add_tri(st, top, rgt, bot, uv_t, uv_r, uv_b, face)
	add_tri(st, top, bot, lft, uv_t, uv_b, uv_l, face)

func leaf_uv(rnd: RandomNumberGenerator, zoom: float) -> Rect2:
	# sample a leafy window of the branch atlas (skip the bare stem near the top)
	var s := zoom
	var u0 := rnd.randf_range(0.05, 0.95 - s)
	var v0 := rnd.randf_range(0.12, 0.92 - s)
	return Rect2(u0, v0, s, s)

# Scatter leaf cards over a squashed dome of radius (rx,ry,rz) centred at c.
func scatter_leaves(st: SurfaceTool, c: Vector3, rx: float, ry: float, rz: float,
		count: int, size_min: float, size_max: float, up_bias: float,
		zoom: float, seed: int) -> void:
	var rnd := RandomNumberGenerator.new()
	rnd.seed = seed
	for i in count:
		var theta := rnd.randf_range(0.0, TAU)
		var phi := acos(rnd.randf_range(-0.25, 1.0))   # mostly upper dome
		var dir := Vector3(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta))
		var rad := rnd.randf_range(0.78, 1.0)
		var pos := c + Vector3(dir.x * rx, dir.y * ry, dir.z * rz) * rad
		var face := (dir + Vector3.UP * up_bias).normalized()
		var sz := rnd.randf_range(size_min, size_max)
		add_leaf_card(st, pos, face, sz, sz * 1.05, rnd.randf_range(0.0, TAU),
			leaf_uv(rnd, zoom), rnd.randf() < 0.5)

# ---- materials ------------------------------------------------------------

func make_solid(tint: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = foliage_tex
	m.albedo_color = tint
	m.roughness = 1.0
	m.uv1_scale = Vector3(1.5, 1.5, 1.0)
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	return m

func make_leaf(tint: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = leaf_tex
	m.albedo_color = tint
	m.roughness = 1.0
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	m.alpha_scissor_threshold = 0.5
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	return m

func make_opaque_leaf(tint: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = foliage_tex
	m.albedo_color = tint
	m.roughness = 1.0
	m.cull_mode = BaseMaterial3D.CULL_DISABLED  # 2-sided, still fully opaque
	m.uv1_scale = Vector3(1.0, 1.0, 1.0)
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	return m

func finalize(surfaces: Array) -> MeshInstance3D:
	var mesh := ArrayMesh.new()
	for s in surfaces:
		(s["st"] as SurfaceTool).commit(mesh)
	for i in surfaces.size():
		mesh.surface_set_material(i, surfaces[i]["mat"])
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	return mi

func new_st() -> SurfaceTool:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	return st

# ---- models ---------------------------------------------------------------

# solid faceted blob bush (kept from the first pass — clean, cheap)
func build_bush_blob() -> MeshInstance3D:
	var fol := new_st()
	add_blob(fol, Vector3(0, 0.30, 0), 0.48, 4, 9, 5, 0.16, 0.95)
	add_blob(fol, Vector3(0.36, 0.20, 0.10), 0.38, 4, 8, 9, 0.16, 0.9)
	add_blob(fol, Vector3(-0.32, 0.18, -0.12), 0.36, 4, 8, 19, 0.16, 0.9)
	return finalize([{"st": fol, "mat": make_solid(Color(0.80, 0.95, 0.62))}])

# round leafy bush: small solid core for opacity + dense leaf cards
func build_bush_leafy() -> MeshInstance3D:
	var core := new_st()
	add_blob(core, Vector3(0, 0.28, 0), 0.30, 4, 8, 3, 0.12, 0.9)
	add_blob(core, Vector3(0.20, 0.20, 0.05), 0.22, 3, 7, 7, 0.12, 0.9)
	var leaves := new_st()
	scatter_leaves(leaves, Vector3(0, 0.30, 0), 0.50, 0.42, 0.50, 90,
		0.26, 0.40, 0.15, 0.34, 101)
	return finalize([
		{"st": core, "mat": make_solid(Color(0.45, 0.62, 0.34))},
		{"st": leaves, "mat": make_leaf(Color(0.95, 1.0, 0.85))},
	])

# upright shrub: taller, narrower, sparser leaf cards
func build_shrub() -> MeshInstance3D:
	var core := new_st()
	add_blob(core, Vector3(0, 0.42, 0), 0.30, 4, 8, 4, 0.12, 1.4)
	add_blob(core, Vector3(0, 0.18, 0), 0.26, 3, 7, 6, 0.12, 1.0)
	var leaves := new_st()
	scatter_leaves(leaves, Vector3(0, 0.50, 0), 0.34, 0.55, 0.34, 70,
		0.24, 0.38, 0.25, 0.32, 202)
	# denser, lower skirt leaves to close the base
	scatter_leaves(leaves, Vector3(0, 0.18, 0), 0.40, 0.22, 0.40, 40,
		0.22, 0.34, -0.05, 0.32, 211)
	return finalize([
		{"st": core, "mat": make_solid(Color(0.42, 0.58, 0.32))},
		{"st": leaves, "mat": make_leaf(Color(0.88, 1.0, 0.78))},
	])

# low spreading ground cover: wide, very low, lots of near-flat leaf cards
func build_groundcover() -> MeshInstance3D:
	var leaves := new_st()
	scatter_leaves(leaves, Vector3(0, 0.10, 0), 0.62, 0.10, 0.62, 80,
		0.22, 0.36, 0.55, 0.30, 303)
	return finalize([
		{"st": leaves, "mat": make_leaf(Color(0.82, 1.0, 0.70))},
	])

# opaque ground cover: same low spreading patch as `groundcover` but built
# from solid leaf-shaped diamonds (no alpha cutout) — mobile-friendly overdraw.
func build_groundcover_opaque() -> MeshInstance3D:
	var leaves := new_st()
	var rnd := RandomNumberGenerator.new(); rnd.seed = 505
	for i in 110:
		var theta := rnd.randf_range(0.0, TAU)
		var r := sqrt(rnd.randf()) * 0.6           # uniform over the disc
		var pos := Vector3(cos(theta) * r, rnd.randf_range(0.02, 0.16), sin(theta) * r)
		# leaves point mostly up with an outward lean
		var lean := Vector3(cos(theta + rnd.randf_range(-1.0, 1.0)), 0.0,
			sin(theta + rnd.randf_range(-1.0, 1.0)))
		var face := (Vector3.UP + lean * rnd.randf_range(0.3, 0.9)).normalized()
		var sz := rnd.randf_range(0.13, 0.22)
		add_leaf_poly(leaves, pos, face, sz, sz * 1.6, rnd.randf_range(0.0, TAU), rnd)
	return finalize([
		{"st": leaves, "mat": make_opaque_leaf(Color(0.74, 0.92, 0.52))},
	])

# grass / fern tuft: upright narrow blades radiating from the base
func build_grass_tuft() -> MeshInstance3D:
	var leaves := new_st()
	var rnd := RandomNumberGenerator.new(); rnd.seed = 404
	for i in 42:
		var theta := rnd.randf_range(0.0, TAU)
		var r := rnd.randf_range(0.0, 0.22)
		var base := Vector3(cos(theta) * r, 0.0, sin(theta) * r)
		var lean := Vector3(cos(theta), 0.0, sin(theta)) * rnd.randf_range(0.05, 0.22)
		var h := rnd.randf_range(0.35, 0.6)
		var top := base + Vector3(0, h, 0) + lean
		var mid := (base + top) * 0.5
		var face := Vector3(cos(theta + 1.2), 0.15, sin(theta + 1.2)).normalized()
		# tall thin vertical UV strip = a blade with a few leaves
		var u0 := rnd.randf_range(0.1, 0.7)
		var uv := Rect2(u0, rnd.randf_range(0.15, 0.45), 0.18, 0.45)
		add_leaf_card(leaves, mid, face, rnd.randf_range(0.10, 0.16), h * 1.1,
			0.0, uv, rnd.randf() < 0.5)
	return finalize([
		{"st": leaves, "mat": make_leaf(Color(0.80, 1.0, 0.62))},
	])

# ---- rendering ------------------------------------------------------------

const TILE := 360
const TILE_H := 380

var vp: SubViewport
var cam: Camera3D
var pivot: Node3D

func setup_stage() -> void:
	vp = SubViewport.new()
	vp.size = Vector2i(TILE, TILE_H)
	vp.world_3d = World3D.new()
	vp.msaa_3d = Viewport.MSAA_4X
	get_root().add_child(vp)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.74, 0.83, 0.92)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.6, 0.68)
	env.ambient_light_energy = 1.0

	cam = Camera3D.new()
	cam.environment = env
	cam.fov = 36.0
	vp.add_child(cam)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-42, -55, 0)
	key.light_energy = 1.25
	vp.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20, 130, 0)
	fill.light_energy = 0.4
	fill.light_color = Color(0.8, 0.85, 1.0)
	vp.add_child(fill)

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

func render_one() -> Image:
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await process_frame
	await process_frame
	await process_frame
	return vp.get_texture().get_image()

func render_model(model: MeshInstance3D, top_y: float, look_y: float, dist: float) -> Image:
	for ch in pivot.get_children():
		pivot.remove_child(ch); ch.queue_free()
	pivot.add_child(model)
	var views := [Vector2(25.0, 0.25), Vector2(90.0, 0.25),
		Vector2(200.0, 0.25), Vector2(135.0, top_y * 0.9)]
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
	holder.add_child(m); m.owner = holder
	get_root().add_child(holder)
	await process_frame
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_scene(holder, state) == OK:
		doc.write_to_filesystem(state, OUT_DIR + name + ".glb")
		print("  exported ", name, ".glb")
	else:
		print("  GLB export FAILED for ", name)
	get_root().remove_child(holder); holder.queue_free()

func _init() -> void:
	foliage_tex = _tex(TEX_DIR + "foliage.jpg")
	leaf_tex = _tex(TEX_DIR + "leaves.png")
	setup_stage()
	await process_frame
	await process_frame

	var specs := [
		{"name": "bush_blob", "fn": "build_bush_blob", "top": 0.85, "look": 0.40, "dist": 2.2},
		{"name": "bush_leafy", "fn": "build_bush_leafy", "top": 0.95, "look": 0.42, "dist": 2.3},
		{"name": "shrub", "fn": "build_shrub", "top": 1.15, "look": 0.52, "dist": 2.5},
		{"name": "groundcover", "fn": "build_groundcover", "top": 0.45, "look": 0.20, "dist": 2.2},
		{"name": "groundcover_opaque", "fn": "build_groundcover_opaque", "top": 0.45, "look": 0.20, "dist": 2.2},
		{"name": "grass_tuft", "fn": "build_grass_tuft", "top": 0.75, "look": 0.32, "dist": 1.9},
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
