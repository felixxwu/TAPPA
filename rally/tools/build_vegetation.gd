extends SceneTree

# ---------------------------------------------------------------------------
# Low-poly OPAQUE ground-cover builder + multi-angle renderer + GLB exporter.
#
# A low, wide spreading patch built from small solid leaf-shaped diamonds whose
# silhouette is the geometry itself — no alpha cutout, so fragments keep early-Z
# and avoid the overdraw cost that alpha-tested leaf cards incur on mobile.
#
# Texture is online-sourced (CC-BY) — see models/vegetation/README.md.
# Pure tooling, not shipped. Run headlessly:
#
#   xvfb-run -a godot --path rally --rendering-driver opengl3 \
#       --script tools/build_vegetation.gd
#
# Writes groundcover_opaque.glb to models/vegetation/ and a 4-angle contact
# sheet to models/vegetation/previews/.
# ---------------------------------------------------------------------------

var TEX_DIR := ProjectSettings.globalize_path("res://models/vegetation/textures/")
var OUT_DIR := ProjectSettings.globalize_path("res://models/vegetation/")

var foliage_tex: ImageTexture

# ---- geometry -------------------------------------------------------------

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

# An opaque leaf: a small flat diamond whose silhouette is the geometry itself.
# UVs sample a small green window of the tiling foliage texture for colour variety.
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

# ---- material / assembly --------------------------------------------------

func make_opaque_leaf(tint: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = foliage_tex
	m.albedo_color = tint
	m.roughness = 1.0
	m.cull_mode = BaseMaterial3D.CULL_DISABLED  # 2-sided, still fully opaque
	m.uv1_scale = Vector3(1.0, 1.0, 1.0)
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	return m

func new_st() -> SurfaceTool:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	return st

func finalize(st: SurfaceTool, mat: StandardMaterial3D) -> MeshInstance3D:
	var mesh := ArrayMesh.new()
	st.commit(mesh)
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	return mi

# ---- model ----------------------------------------------------------------

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
	return finalize(leaves, make_opaque_leaf(Color(0.74, 0.92, 0.52)))

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
	setup_stage()
	await process_frame
	await process_frame

	var model := build_groundcover_opaque()
	print("built groundcover_opaque verts=", _count_verts(model.mesh))
	var montage: Image = await render_model(model, 0.45, 0.20, 2.2)
	montage.save_png(OUT_DIR + "previews/groundcover_opaque.png")
	print("  saved preview groundcover_opaque.png")
	await export_glb(model, "groundcover_opaque")
	print("ALL_DONE")
	quit()

func _count_verts(mesh: ArrayMesh) -> int:
	var n := 0
	for i in mesh.get_surface_count():
		n += mesh.surface_get_arrays(i)[Mesh.ARRAY_VERTEX].size()
	return n
