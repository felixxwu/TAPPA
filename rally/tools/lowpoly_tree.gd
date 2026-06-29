# Procedural low-poly tree generator + multi-angle render harness.
#
# Builds a faceted, vertex-coloured deciduous tree (tapered trunk + a cluster of
# overlapping icosphere "blobs" for a billowing broadleaf canopy) to match the
# rounded park trees in the skybox (textures/sky_field.png). The flat-shaded,
# vertex-colour look fits the project's unshaded PS1 aesthetic — no textures.
#
# Run headless to export the .glb:
#   godot --headless -s tools/lowpoly_tree.gd -- --export
# Run under xvfb + opengl3 to also save verification renders:
#   xvfb-run -a godot --rendering-driver opengl3 -s tools/lowpoly_tree.gd -- --render
extends SceneTree

const GOLDEN := 1.618033988749895

# ----------------------------------------------------------------------------
# Small deterministic hash -> [0,1), so the same tree is produced every run.
# ----------------------------------------------------------------------------
func _h(seed: int) -> float:
	var x := (seed * 374761393 + 668265263) & 0x7fffffff
	x = (x ^ (x >> 13)) * 1274126177 & 0x7fffffff
	return float(x % 100000) / 100000.0


# Hash keyed on a (quantized) unit direction, so every triangle that shares an
# icosphere vertex gets the SAME displacement — the surface stays watertight
# (no cracks/spikes) while still looking irregular. seed varies it per blob.
func _vhash(dir: Vector3, seed: int) -> float:
	var qx := int(round(dir.x * 32.0))
	var qy := int(round(dir.y * 32.0))
	var qz := int(round(dir.z * 32.0))
	return _h(seed * 131 + qx * 73856093 + qy * 19349663 + qz * 83492791)


# ----------------------------------------------------------------------------
# Icosahedron -> subdivided sphere. Returns an Array of triangles, each an
# Array[Vector3] of 3 unit-sphere positions (kept as triangles so we can
# flat-shade per face for the low-poly facet look).
# ----------------------------------------------------------------------------
func _icosphere(subdiv: int) -> Array:
	var t := GOLDEN
	var v := [
		Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1),
	]
	for i in v.size():
		v[i] = (v[i] as Vector3).normalized()
	var faces := [
		[0,11,5],[0,5,1],[0,1,7],[0,7,10],[0,10,11],
		[1,5,9],[5,11,4],[11,10,2],[10,7,6],[7,1,8],
		[3,9,4],[3,4,2],[3,2,6],[3,6,8],[3,8,9],
		[4,9,5],[2,4,11],[6,2,10],[8,6,7],[9,8,1],
	]
	var tris := []
	for f in faces:
		tris.append([v[f[0]], v[f[1]], v[f[2]]])
	for _s in subdiv:
		var next := []
		for tri in tris:
			var a: Vector3 = tri[0]
			var b: Vector3 = tri[1]
			var c: Vector3 = tri[2]
			var ab := ((a + b) * 0.5).normalized()
			var bc := ((b + c) * 0.5).normalized()
			var ca := ((c + a) * 0.5).normalized()
			next.append([a, ab, ca])
			next.append([b, bc, ab])
			next.append([c, ca, bc])
			next.append([ab, bc, ca])
		tris = next
	return tris


# Append one canopy blob (a squashed icosphere) into st, with per-face green
# variation + vertical shading so the underside reads darker.
func _add_canopy_blob(st: SurfaceTool, center: Vector3, radius: float,
		squash: float, seed: int, base: Color, top_h: float, bot_h: float) -> void:
	var tris := _icosphere(1)
	var idx := 0
	for tri in tris:
		idx += 1
		# slight per-blob wobble so blobs aren't perfect spheres
		var pts := []
		var face_c := Vector3.ZERO
		for p in tri:
			var pp: Vector3 = p
			# per-vertex-direction lump (shared between adjacent faces)
			var wob := 1.0 + (_vhash(pp, seed) - 0.5) * 0.16
			pp.y *= squash
			var world := center + pp * radius * wob
			pts.append(world)
			face_c += world
		face_c /= 3.0
		# height factor 0 (bottom of whole canopy) .. 1 (top) for fake AO/sun
		var hf: float = clamp(inverse_lerp(bot_h, top_h, face_c.y), 0.0, 1.0)
		var shade: float = lerp(0.62, 1.12, hf)
		# per-face hue jitter between a few green tones
		var jit := _h(seed * 31 + idx)
		var col := Color(
			clamp(base.r * shade * (0.9 + jit * 0.22), 0, 1),
			clamp(base.g * shade * (0.9 + jit * 0.18), 0, 1),
			clamp(base.b * shade * (0.85 + jit * 0.30), 0, 1))
		var n := (Vector3(pts[1]) - Vector3(pts[0])).cross(Vector3(pts[2]) - Vector3(pts[0])).normalized()
		for p in pts:
			st.set_color(col)
			st.set_normal(n)
			st.add_vertex(p)


func _add_trunk(st: SurfaceTool, sides: int, bottom_r: float, top_r: float,
		height: float, base: Color) -> void:
	var prev_ang := 0.0
	for i in range(sides + 1):
		var a0 := TAU * float(i) / sides
		var a1 := TAU * float(i + 1) / sides
		var b0 := Vector3(cos(a0) * bottom_r, 0, sin(a0) * bottom_r)
		var b1 := Vector3(cos(a1) * bottom_r, 0, sin(a1) * bottom_r)
		var t0 := Vector3(cos(a0) * top_r, height, sin(a0) * top_r)
		var t1 := Vector3(cos(a1) * top_r, height, sin(a1) * top_r)
		# two tris per side, flat shaded, slight per-face bark variation
		var jit := _h(i * 7)
		var col := Color(base.r * (0.85 + jit * 0.3), base.g * (0.85 + jit * 0.3), base.b * (0.85 + jit * 0.3))
		_quad(st, b0, b1, t1, t0, col)


func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color) -> void:
	var n1 := (b - a).cross(c - a).normalized()
	for p in [a, b, c]:
		st.set_color(col); st.set_normal(n1); st.add_vertex(p)
	var n2 := (c - a).cross(d - a).normalized()
	for p in [a, c, d]:
		st.set_color(col); st.set_normal(n2); st.add_vertex(p)


# ----------------------------------------------------------------------------
# Build the whole tree mesh.
# ----------------------------------------------------------------------------
func build_tree() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var trunk_col := Color(0.34, 0.25, 0.16)
	var leaf := Color(0.30, 0.42, 0.18)

	var trunk_h := 1.7
	_add_trunk(st, 6, 0.20, 0.12, trunk_h, trunk_col)

	# Canopy: a cluster of overlapping blobs forming a rounded, slightly
	# irregular broadleaf crown sitting on top of the trunk.
	var crown_base := trunk_h + 0.5
	var top_h := crown_base + 2.8
	var bot_h := trunk_h - 0.1
	# Overlapping blobs (center, radius, squash). Radii chosen so neighbours
	# interpenetrate — that closes the thin sky cracks between facets — and a
	# low bottom-fill blob skirts the trunk junction so the crown isn't ragged.
	var blobs := [
		[Vector3(0.0, crown_base + 1.05, 0.0), 1.62, 0.96],   # big central mass
		[Vector3(0.78, crown_base + 0.5, 0.28), 1.20, 1.0],   # right lobe
		[Vector3(-0.68, crown_base + 0.58, -0.36), 1.22, 1.0], # left-back lobe
		[Vector3(0.16, crown_base + 1.75, -0.18), 1.06, 1.0], # top crown
		[Vector3(-0.28, crown_base + 0.34, 0.58), 1.14, 1.0], # front lobe
		[Vector3(0.08, crown_base + 0.05, -0.06), 1.18, 0.88], # bottom skirt
	]
	var bi := 0
	for b in blobs:
		bi += 1
		_add_canopy_blob(st, b[0], b[1], b[2], bi * 17 + 3, leaf, top_h, bot_h)

	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	mat.metallic = 0.0
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	st.set_material(mat)

	var mesh := st.commit()
	return mesh


func _export_glb(mesh: ArrayMesh, path: String) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.name = "LowPolyTree"
	var root := Node3D.new()
	root.name = "LowPolyTree"
	root.add_child(mi)
	mi.owner = root
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	doc.append_from_scene(root, state)
	doc.write_to_filesystem(state, path)
	print("EXPORTED ", path, " verts=", mesh.surface_get_array_len(0))


# ----------------------------------------------------------------------------
# Render harness: N angles around the tree, saved as PNGs.
# ----------------------------------------------------------------------------
func _render(mesh: ArrayMesh, out_dir: String) -> void:
	var fov_deg := 38.0
	var scenario := RenderingServer.scenario_create()
	var inst := RenderingServer.instance_create2(mesh.get_rid(), scenario)

	# light (sun) + a fill via environment ambient
	var env := RenderingServer.environment_create()
	RenderingServer.environment_set_background(env, RenderingServer.ENV_BG_COLOR)
	RenderingServer.environment_set_bg_color(env, Color(0.55, 0.70, 0.90))
	RenderingServer.environment_set_ambient_light(env, Color(0.75, 0.80, 0.85), RenderingServer.ENV_AMBIENT_SOURCE_COLOR, 1.0)

	var sun := RenderingServer.directional_light_create()
	var sun_i := RenderingServer.instance_create2(sun, scenario)
	var sun_basis := Basis.from_euler(Vector3(-0.9, 0.6, 0.0))
	RenderingServer.instance_set_transform(sun_i, Transform3D(sun_basis, Vector3.ZERO))

	var size := Vector2i(480, 600)
	var vp := RenderingServer.viewport_create()
	RenderingServer.viewport_set_size(vp, size.x, size.y)
	RenderingServer.viewport_set_active(vp, true)
	RenderingServer.viewport_set_scenario(vp, scenario)
	RenderingServer.viewport_set_transparent_background(vp, false)
	RenderingServer.viewport_set_update_mode(vp, RenderingServer.VIEWPORT_UPDATE_ALWAYS)

	var cam := RenderingServer.camera_create()
	RenderingServer.viewport_attach_camera(vp, cam)
	RenderingServer.camera_set_perspective(cam, fov_deg, 0.05, 100)
	RenderingServer.camera_set_environment(cam, env)

	var aabb := mesh.get_aabb()
	var center := aabb.position + aabb.size * 0.5
	# distance needed to fit the tree's height (and a bit of width) in frame
	var half_fov := deg_to_rad(fov_deg) * 0.5
	var fit_h: float = (aabb.size.y * 0.5) / tan(half_fov)
	var fit_w: float = (max(aabb.size.x, aabb.size.z) * 0.5) / (tan(half_fov) * (480.0 / 600.0))
	var radius: float = max(fit_h, fit_w) * 1.25
	var pitch := -0.12

	var angles := {"front": 0.0, "side": PI * 0.5, "q34": PI * 0.25, "back": PI}
	for name: String in angles:
		var yaw: float = angles[name]
		var dir := Vector3(sin(yaw) * cos(pitch), -sin(pitch), cos(yaw) * cos(pitch))
		var eye := center + dir * radius
		var xf := Transform3D(Basis(), eye).looking_at(center, Vector3.UP)
		RenderingServer.camera_set_transform(cam, xf)
		# pump a few frames so llvmpipe finishes
		for i in 3:
			await process_frame
		RenderingServer.force_draw()
		var img := RenderingServer.texture_2d_get(RenderingServer.viewport_get_texture(vp))
		if img:
			var p := out_dir + "/tree_" + name + ".png"
			img.save_png(p)
			print("RENDERED ", p)
		else:
			print("NO IMAGE for ", name)


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var do_export := args.has("--export")
	var do_render := args.has("--render")
	if not do_export and not do_render:
		do_export = true
		do_render = true

	var mesh := build_tree()
	if do_export:
		_export_glb(mesh, "res://models/low_poly_tree.glb")
	if do_render:
		var out_dir := ProjectSettings.globalize_path("res://tools/tree_renders")
		DirAccess.make_dir_recursive_absolute(out_dir)
		await _render(mesh, out_dir)
	quit()
