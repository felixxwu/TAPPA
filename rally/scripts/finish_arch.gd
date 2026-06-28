class_name FinishArch
extends Node3D
# Procedural inflatable rally gate — the fat orange "portal" seen at a stage's
# start/finish (Dakar-style), modelled on the reference photo: two inflatable legs
# joined by a top beam with rounded inner/outer corners, wordmark banners down each
# leg and a sponsor strip across the top, anchored by guy ropes to ground stakes on
# each side. The same model serves BOTH gates — world.gd builds a FINISH one at the
# centerline end and a START one at the start line; the `*_banner` exports below
# pick which baked banner set (FINISH vs START wordmarks) it wears.
#
# Built entirely from code so it fits the project's procedural-asset style (cf.
# SignField) and the PS1 flat-shaded look: one extruded arch mesh with the lit
# car shader, plus thin banner quads laid just proud of the front face. All
# dimensions are metres; the arch spans a road of `span` width.

const ARCH_SHADER := preload("res://shaders/ps1_models_lit.gdshader")

# --- Geometry params (metres) -------------------------------------------------
@export var span: float = 8.0          # clear opening between the inner leg faces
@export var leg_width: float = 1.7     # thickness of each leg (X)
@export var height: float = 6.6        # ground to top of the arch
@export var top_height: float = 1.7    # thickness of the top beam (Y)
@export var depth: float = 1.6         # front-to-back thickness (Z)
@export var bulge: float = 0.4         # how far the tube bulges out at its depth equator (m)
@export var depth_segments: int = 4    # rings used to round the front-to-back profile
@export var inner_radius: float = 1.6  # rounding of the two inner top corners
@export var outer_radius: float = 0.9  # rounding of the two outer top corners
@export var corner_segments: int = 8   # arc resolution per rounded corner
@export var leg_taper: float = 0.0     # outward lean added to each leg at the base (m)

# --- Look ---------------------------------------------------------------------
@export var arch_color: Color = Color(0.86, 0.30, 0.16)   # inflatable orange-red
@export var seam_color: Color = Color(0.72, 0.23, 0.12)   # darker inflatable seams
@export var sun_direction: Vector3 = Vector3(0.35, 0.85, 0.4)

# --- Banners ------------------------------------------------------------------
# Base names of the baked banner textures (textures/finish/<name>.png) for the top
# beam (approach face), its down-track back face, and the legs. Defaults wear the
# FINISH set; the start gate sets these to the START set (see tools/bake_finish_banners.gd).
@export var top_banner: String = "top"
@export var back_banner: String = "back"
@export var leg_banner: String = "leg"

var _mat: ShaderMaterial


func _ready() -> void:
	build()


func build() -> void:
	for c in get_children():
		c.queue_free()
	_mat = _make_material(arch_color)
	var body := MeshInstance3D.new()
	body.name = "ArchBody"
	body.mesh = _build_arch_mesh()
	body.material_override = _mat
	add_child(body)
	_add_inflatable_seams()
	_add_banners()
	_add_guy_ropes()
	_add_anchors()


# ---------------------------------------------------------------------------
# Arch profile + extrusion
# ---------------------------------------------------------------------------

# The arch is a single closed 2D outline (an inverted U, open at the bottom)
# extruded along Z. We trace the boundary counter-clockwise starting at the
# bottom-left outer corner, rounding the two top-outer and two top-inner corners.
func _arch_profile() -> PackedVector2Array:
	var half_w := span * 0.5 + leg_width   # outer half-width
	var inner_x := span * 0.5              # inner leg face (x)
	var beam_y := height - top_height      # underside of the top beam
	var pts := PackedVector2Array()

	# Up the left outer edge.
	pts.append(Vector2(-half_w, 0.0))
	# Top-left outer rounded corner (from the left edge, sweeping to the top edge).
	_append_arc(pts, Vector2(-half_w + outer_radius, height - outer_radius),
		outer_radius, PI, PI * 0.5)
	# Top-right outer rounded corner.
	_append_arc(pts, Vector2(half_w - outer_radius, height - outer_radius),
		outer_radius, PI * 0.5, 0.0)
	# Down the right outer edge to the ground.
	pts.append(Vector2(half_w, 0.0))
	# Across the bottom of the right leg to its inner face.
	pts.append(Vector2(inner_x, 0.0))
	# Up the right inner edge, then round the (concave) inner corner into the beam
	# underside. Fillet centre sits inside the opening, tangent to both edges.
	_append_arc(pts, Vector2(inner_x - inner_radius, beam_y - inner_radius),
		inner_radius, 0.0, PI * 0.5)
	# Across the underside of the beam, then round the left inner corner.
	_append_arc(pts, Vector2(-inner_x + inner_radius, beam_y - inner_radius),
		inner_radius, PI * 0.5, PI)
	# Down the left inner edge to the ground, then back to the start.
	pts.append(Vector2(-inner_x, 0.0))
	return pts


# Append a circular arc (centre c, radius r) sweeping from angle a0 to a1.
func _append_arc(pts: PackedVector2Array, c: Vector2, r: float, a0: float, a1: float) -> void:
	for i in range(corner_segments + 1):
		var t := float(i) / float(corner_segments)
		var a: float = lerp(a0, a1, t)
		pts.append(c + Vector2(cos(a), sin(a)) * r)


# Build the solid arch: triangulated front + back caps and a side wall ribbon,
# with a subtle leg taper applied to X so the legs are fatter at the base.
func _build_arch_mesh() -> ArrayMesh:
	var profile := _arch_profile()
	# Optional leg lean: push each side outward toward the ground (y = 0) so the
	# base is wider than the top — a small offset by sign, leaving the top square.
	if leg_taper != 0.0:
		var shaped := PackedVector2Array()
		for p in profile:
			var t: float = clampf(1.0 - p.y / height, 0.0, 1.0)
			shaped.append(Vector2(p.x + signf(p.x) * leg_taper * t, p.y))
		profile = shaped

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hz := depth * 0.5
	var tris := Geometry2D.triangulate_polygon(profile)
	var n := profile.size()

	# Flat front cap (+Z) and back cap (-Z) — kept flat so banners read cleanly.
	for i in range(0, tris.size(), 3):
		var a := tris[i]
		var b := tris[i + 1]
		var c := tris[i + 2]
		_face(st, _v(profile[a], hz), _v(profile[b], hz), _v(profile[c], hz), Vector3.BACK)
		_face(st, _v(profile[c], -hz), _v(profile[b], -hz), _v(profile[a], -hz), Vector3.FORWARD)

	# Bulged side wall: instead of a flat vertical band front->back, sweep a
	# barrel profile so the tube bulges outward at its depth equator (inflatable
	# look). Ring k sits at angle θ ∈ [-π/2, π/2]; z = hz·sinθ pushes front→back
	# while the boundary point is shoved out along its 2D normal by bulge·cosθ.
	for i in range(n):
		var p0 := profile[i]
		var p1 := profile[(i + 1) % n]
		var nrm0 := _edge_normal(profile, i)
		var nrm1 := _edge_normal(profile, (i + 1) % n)
		for k in range(depth_segments):
			var a0: float = lerp(-PI * 0.5, PI * 0.5, float(k) / float(depth_segments))
			var a1: float = lerp(-PI * 0.5, PI * 0.5, float(k + 1) / float(depth_segments))
			var r0a := _ring_point(p0, nrm0, hz, a0)
			var r0b := _ring_point(p0, nrm0, hz, a1)
			var r1a := _ring_point(p1, nrm1, hz, a0)
			var r1b := _ring_point(p1, nrm1, hz, a1)
			st.add_vertex(r0a); st.add_vertex(r1a); st.add_vertex(r1b)
			st.add_vertex(r0a); st.add_vertex(r1b); st.add_vertex(r0b)

	st.generate_normals()
	return st.commit()


# A point on the bulged side wall: profile point p with outward 2D normal nrm,
# at depth angle a (−π/2 back … +π/2 front).
func _ring_point(p: Vector2, nrm: Vector2, hz: float, a: float) -> Vector3:
	var out := p + nrm * (bulge * cos(a))
	return Vector3(out.x, out.y, hz * sin(a))


# Averaged outward normal at boundary vertex i (mean of its two adjacent edges)
# so the bulge stays smooth around corners.
func _edge_normal(profile: PackedVector2Array, i: int) -> Vector2:
	var n := profile.size()
	var prev := profile[(i - 1 + n) % n]
	var cur := profile[i]
	var nxt := profile[(i + 1) % n]
	var e0 := (cur - prev)
	var e1 := (nxt - cur)
	var n0 := Vector2(e0.y, -e0.x)
	var n1 := Vector2(e1.y, -e1.x)
	return (n0 + n1).normalized()


func _v(p: Vector2, z: float) -> Vector3:
	return Vector3(p.x, p.y, z)


func _face(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, nrm: Vector3) -> void:
	st.set_normal(nrm)
	st.add_vertex(a)
	st.set_normal(nrm)
	st.add_vertex(b)
	st.set_normal(nrm)
	st.add_vertex(c)


# ---------------------------------------------------------------------------
# Inflatable seam rings — thin dark bands wrapped around the tubes to sell the
# "inflated baffles" look. A handful of flat quads on the front face.
# ---------------------------------------------------------------------------
func _add_inflatable_seams() -> void:
	var seam_mat := _make_material(seam_color)
	var z := depth * 0.5 + 0.01
	# Horizontal seams down each leg.
	var leg_centres := [-(span * 0.5 + leg_width * 0.5), (span * 0.5 + leg_width * 0.5)]
	var beam_y := height - top_height
	for cx in leg_centres:
		var rings := int(beam_y / 0.9)
		for r in range(1, rings):
			var y := r * (beam_y / float(rings))
			var q := _quad(leg_width * 1.02, 0.08)
			var mi := MeshInstance3D.new()
			mi.mesh = q
			mi.material_override = seam_mat
			mi.position = Vector3(cx, y, z)
			add_child(mi)


# ---------------------------------------------------------------------------
# Banners — the FINISH beam strip and the stacked sponsor panels on each leg,
# laid just proud of the front/back faces. Textures are baked by
# tools/bake_finish_banners.gd into textures/finish/ and loaded at runtime via
# Image.load (no import step). Missing textures fall back to a flat panel colour.
# ---------------------------------------------------------------------------
const BANNER_DIR := "res://textures/finish"

func _add_banners() -> void:
	var hz := depth * 0.5 + 0.02
	var beam_y := height - top_height
	var total_w := span + 2.0 * leg_width
	# Top beam strip, front (approach) and back (down-track) faces.
	var top_tex := _load_banner(top_banner)
	var back_tex := _load_banner(back_banner)
	_add_banner_quad(top_tex, Color(0.95, 0.95, 0.92),
		Vector3(0, beam_y + top_height * 0.5, hz),
		Vector2(total_w * 0.99, top_height * 0.86), false)
	_add_banner_quad(back_tex, arch_color,
		Vector3(0, beam_y + top_height * 0.5, -hz),
		Vector2(total_w * 0.99, top_height * 0.86), true)
	# Leg sponsor panels, front face of each leg.
	var leg_tex := _load_banner(leg_banner)
	for cx in [-(span * 0.5 + leg_width * 0.5), (span * 0.5 + leg_width * 0.5)]:
		_add_banner_quad(leg_tex, Color(0.85, 0.78, 0.6),
			Vector3(cx, beam_y * 0.5, hz),
			Vector2(leg_width * 0.84, beam_y * 0.92), false)


# One flat textured quad facing +Z (front) or -Z (back).
func _add_banner_quad(tex: Texture2D, fallback: Color, pos: Vector3,
		size: Vector2, face_back: bool) -> void:
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = size
	mi.mesh = q
	var mat := ShaderMaterial.new()
	mat.shader = ARCH_SHADER
	mat.set_shader_parameter("light_amount", 0.4)  # banners read flatter than the tubes
	mat.set_shader_parameter("light_dir", sun_direction.normalized())
	mat.set_shader_parameter("sun_color", Color(0.45, 0.43, 0.4))
	mat.set_shader_parameter("sky_color", Color(0.6, 0.62, 0.68))
	mat.set_shader_parameter("ground_color", Color(0.4, 0.36, 0.3))
	if tex != null:
		mat.set_shader_parameter("albedo_texture", tex)
		mat.set_shader_parameter("albedo_color", Color.WHITE)
	else:
		mat.set_shader_parameter("albedo_color", fallback)
	mi.material_override = mat
	mi.position = pos
	if face_back:
		mi.rotate_y(PI)
	add_child(mi)


# Baked banner textures, loaded as normal imported resources (committed .import
# files, like the project's other textures) and cached across rebuilds/instances.
# Returns null if the texture hasn't been baked yet (tools/bake_finish_banners.gd),
# in which case the quad falls back to a flat panel colour.
static var _banner_cache: Dictionary = {}

func _load_banner(tex_name: String) -> Texture2D:
	if _banner_cache.has(tex_name):
		return _banner_cache[tex_name]
	var path := "%s/%s.png" % [BANNER_DIR, tex_name]
	var tex: Texture2D = load(path) as Texture2D if ResourceLoader.exists(path) else null
	_banner_cache[tex_name] = tex
	return tex


# ---------------------------------------------------------------------------
# Guy ropes + ground anchors
# ---------------------------------------------------------------------------
func _add_guy_ropes() -> void:
	var rope_mat := _make_material(Color(0.06, 0.06, 0.06))
	var half_w := span * 0.5 + leg_width
	# Two ropes per side, fore and aft, from near the top of each leg out to stakes.
	for side in [-1.0, 1.0]:
		var top := Vector3(side * (half_w - 0.2), height - top_height * 0.4, 0.0)
		for fb in [-1.0, 1.0]:
			var anchor := Vector3(side * (half_w + 2.6), 0.05, fb * 2.8)
			_add_rope(top, anchor, rope_mat)


func _add_rope(a: Vector3, b: Vector3, mat: ShaderMaterial) -> void:
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.035
	cyl.bottom_radius = 0.035
	cyl.height = a.distance_to(b)
	cyl.radial_segments = 4
	var mi := MeshInstance3D.new()
	mi.mesh = cyl
	mi.material_override = mat
	var mid := (a + b) * 0.5
	# Orient the cylinder (local +Y) along the rope direction.
	var dir := (b - a).normalized()
	var rope_basis := _basis_from_y(dir)
	mi.transform = Transform3D(rope_basis, mid)
	add_child(mi)


func _add_anchors() -> void:
	var stake_mat := _make_material(Color(0.12, 0.12, 0.13))
	var half_w := span * 0.5 + leg_width
	for side in [-1.0, 1.0]:
		var stake := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.4, 0.5, 1.2)
		stake.mesh = box
		stake.material_override = stake_mat
		stake.position = Vector3(side * (half_w + 2.6), 0.25, 0.0)
		add_child(stake)


# Orthonormal basis whose Y axis points along `y_axis`.
func _basis_from_y(y_axis: Vector3) -> Basis:
	var y := y_axis.normalized()
	var x := Vector3.RIGHT
	if absf(y.dot(x)) > 0.99:
		x = Vector3.FORWARD
	var z := x.cross(y).normalized()
	x = y.cross(z).normalized()
	return Basis(x, y, z)


func _quad(w: float, h: float) -> QuadMesh:
	var q := QuadMesh.new()
	q.size = Vector2(w, h)
	return q


# ---------------------------------------------------------------------------
# Material — flat-lit PS1 shader so the arch catches the same fake sun as the car.
# ---------------------------------------------------------------------------
func _make_material(col: Color) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = ARCH_SHADER
	mat.set_shader_parameter("albedo_color", col)
	mat.set_shader_parameter("light_amount", 0.85)
	mat.set_shader_parameter("light_dir", sun_direction.normalized())
	mat.set_shader_parameter("sun_color", Color(0.55, 0.52, 0.48))
	mat.set_shader_parameter("sky_color", Color(0.55, 0.6, 0.7))
	mat.set_shader_parameter("ground_color", Color(0.35, 0.3, 0.25))
	return mat
