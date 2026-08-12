class_name BarrierSection
extends Node3D
# One 2 m module of roadside crash barrier, built entirely from code (like
# FinishArch / SignField) in the project's PS1 flat-shaded style. Modules are
# STITCHED END TO END along the outside of a sharp corner: each is self-contained,
# exactly `length` long, and its continuous elements overrun the module ends by
# `joint_overlap` so a run laid around a curve shows no gaps at the joints.
# BarrierLayout plans the runs and BarrierField builds them — see features/barriers.md.
#
# Two looks, picked by the ROAD SURFACE under the corner (style_for_tarmac):
# gravel gets the steel armco guardrail, tarmac the precast concrete jersey rail.
#
# Local frame (both styles obey it, so placement code is style-agnostic):
#   +Z / -Z  the run direction (length axis), the module centred on z = 0
#   +Y       up, ground at y = 0
#   +X       the ROAD side — the face the driver sees. Mass extends toward -X.
# So a module is placed with its Z axis along the road tangent and its +X turned
# in toward the racing line.
#
# Deliberately NO per-module jitter: both barriers are MANUFACTURED, identical
# units in real life, and identical modules are what let BarrierField draw a whole
# run from one MultiMesh per part instead of a node per module.

const BARRIER_SHADER := preload("res://shaders/ps1_models_lit.gdshader")

enum Style {
	ARMCO,   # galvanised steel W-beam guardrail on posts — the gravel-stage barrier
	JERSEY,  # precast concrete jersey/K-rail — the tarmac-stage barrier
}

# Display names for the render harness / any future picker UI.
const STYLE_NAMES := {
	Style.ARMCO: "ARMCO GUARDRAIL",
	Style.JERSEY: "CONCRETE JERSEY",
}

@export var style: Style = Style.ARMCO
@export var length: float = 2.0          # module length along Z (the stitch pitch)
@export var joint_overlap: float = 0.06  # how far continuous parts overrun each end
@export var sun_direction: Vector3 = Vector3(0.35, 0.85, 0.4)

# --- Palettes (per style, kept together so the whole look is tweakable here) ---
const _STEEL := Color(0.60, 0.63, 0.62)
const _STEEL_DARK := Color(0.33, 0.35, 0.35)
const _CONCRETE := Color(0.72, 0.71, 0.67)
const _CONCRETE_DARK := Color(0.55, 0.54, 0.51)
const _WARN_RED := Color(0.74, 0.18, 0.13)
const _WARN_WHITE := Color(0.92, 0.90, 0.85)

var _mats: Dictionary = {}


func _ready() -> void:
	build()


# Rebuild the module from scratch. Idempotent — children are detached and freed
# first, so calling it after changing `style` / `length` replaces the model rather
# than stacking a second one on top.
func build() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_mats.clear()
	match style:
		Style.ARMCO: _build_armco()
		Style.JERSEY: _build_jersey()


# Union of every child mesh's AABB, in this node's local space. The stitching
# contract in metres: `size.z` is the module's footprint along the run, `size.y`
# its height and `size.x` its thickness — what a later placement pass needs to
# size a collision box and to inset the run from the road edge. Conservative:
# each part contributes its transformed BOX, so a rotated part reports a little
# larger than its true silhouette.
func local_aabb() -> AABB:
	var out := AABB()
	var first := true
	for c in get_children():
		var mi := c as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var box: AABB = mi.transform * mi.mesh.get_aabb()
		if first:
			out = box
			first = false
		else:
			out = out.merge(box)
	return out


static func style_name(s: int) -> String:
	return String(STYLE_NAMES.get(s, "BARRIER"))


# Which barrier belongs on a road of this surface: concrete jersey rail once the
# road is mostly tarmac, steel armco on gravel. `tarmac_weight` is the 0..1
# tarmac-ness TrackSurface/TerrainManager report at that point along the track, so
# a stage that switches surface mid-corner switches barrier with it.
static func style_for_tarmac(tarmac_weight: float, threshold: float) -> Style:
	return Style.JERSEY if tarmac_weight >= threshold else Style.ARMCO


# The built model as flat instancing data: one entry per part,
# `{"mesh": Mesh, "material": Material, "transform": Transform3D}` in module-local
# space. BarrierField uses this to draw a whole RUN from one MultiMesh per part
# (instead of a node per module) without keeping the prototype node around.
func parts() -> Array:
	var out: Array = []
	for c in get_children():
		var mi := c as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		out.append({"mesh": mi.mesh, "material": mi.material_override,
			"transform": mi.transform})
	return out


# ---------------------------------------------------------------------------
# Armco — a corrugated steel W-beam on one post per module, so a stitched run
# gets a post every `length`. The beam is a swept open profile (a thin shell),
# the post/bracket/bolt are primitives.
# ---------------------------------------------------------------------------
func _build_armco() -> void:
	var beam_bottom := 0.45
	var beam_h := 0.31
	var d := 0.075                     # corrugation depth toward the road (+X)
	var mid := beam_bottom + beam_h * 0.5
	# W-beam cross-section traced bottom -> top: folded lips top and bottom, two
	# proud humps and the bolt valley between them.
	var prof := PackedVector2Array([
		Vector2(0.0, beam_bottom),
		Vector2(d, beam_bottom + 0.05),
		Vector2(d, beam_bottom + 0.11),
		Vector2(0.014, mid),
		Vector2(d, beam_bottom + beam_h - 0.11),
		Vector2(d, beam_bottom + beam_h - 0.05),
		Vector2(0.0, beam_bottom + beam_h),
	])
	var hz := length * 0.5 + joint_overlap
	_add_mesh(_sweep_open(prof, -hz, hz), _STEEL, "Beam")
	# Post: dark C-section faked as a single box, sunk behind the beam.
	var post_h := beam_bottom + beam_h * 0.55
	_add_box(Vector3(0.13, post_h, 0.14), Vector3(-0.07, post_h * 0.5, 0.0), _STEEL_DARK, "Post")
	# Spacer block between post and beam, and the splice bolt in the valley.
	_add_box(Vector3(0.06, 0.16, 0.12), Vector3(0.015, mid, 0.0), _STEEL_DARK)
	_add_cyl(0.032, 0.05, Vector3(d * 0.6, mid, 0.0), _STEEL_DARK,
		Vector3(0.0, 0.0, PI * 0.5), 6)


# ---------------------------------------------------------------------------
# Concrete jersey — a precast K-rail: the symmetric jersey profile extruded
# along the run, with a reflector plate and the pin-joint seams at each end.
# ---------------------------------------------------------------------------
func _build_jersey() -> void:
	var top := 0.81
	# Closed cross-section, traced round the outline (road side +X first).
	var prof := PackedVector2Array([
		Vector2(0.30, 0.0), Vector2(0.30, 0.08), Vector2(0.115, 0.55),
		Vector2(0.10, top), Vector2(-0.10, top), Vector2(-0.115, 0.55),
		Vector2(-0.30, 0.08), Vector2(-0.30, 0.0),
	])
	var hz := length * 0.5 + joint_overlap
	_add_mesh(_extrude_closed(prof, -hz, hz), _CONCRETE, "Rail")
	# Cast seam at ONE end only, so a stitched joint reads as a single thin line: a
	# seam at both ends would butt two of them together into a 6 cm dark band that
	# looks like a gap between the modules rather than a joint between them.
	_add_box(Vector3(0.24, top * 0.92, 0.025),
		Vector3(0.005, top * 0.46, hz), _CONCRETE_DARK)
	# Reflector plate high on the road face (red over white, hazard-marker style).
	_add_box(Vector3(0.02, 0.16, 0.10), Vector3(0.115, top - 0.16, 0.0), _WARN_WHITE)
	_add_box(Vector3(0.02, 0.08, 0.10), Vector3(0.12, top - 0.12, 0.0), _WARN_RED)


# ---------------------------------------------------------------------------
# Mesh helpers
# ---------------------------------------------------------------------------

# Sweep an OPEN 2D polyline (in XY) along Z into a thin shell — the armco beam.
func _sweep_open(prof: PackedVector2Array, z0: float, z1: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(prof.size() - 1):
		var p0 := prof[i]
		var p1 := prof[i + 1]
		_quad2(st, Vector3(p0.x, p0.y, z0), Vector3(p1.x, p1.y, z0),
			Vector3(p1.x, p1.y, z1), Vector3(p0.x, p0.y, z1))
	return st.commit()


# Extrude a CLOSED 2D outline (in XY) along Z, with triangulated end caps.
func _extrude_closed(prof: PackedVector2Array, z0: float, z1: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := prof.size()
	for i in range(n):
		var p0 := prof[i]
		var p1 := prof[(i + 1) % n]
		_quad2(st, Vector3(p0.x, p0.y, z0), Vector3(p1.x, p1.y, z0),
			Vector3(p1.x, p1.y, z1), Vector3(p0.x, p0.y, z1))
	var tris := Geometry2D.triangulate_polygon(prof)
	for i in range(0, tris.size(), 3):
		var a := prof[tris[i]]
		var b := prof[tris[i + 1]]
		var c := prof[tris[i + 2]]
		for z in [z0, z1]:
			_tri2(st, Vector3(a.x, a.y, z), Vector3(b.x, b.y, z), Vector3(c.x, c.y, z))
	return st.commit()


# Emit a triangle BOTH ways, each side with its own flat normal. Every custom
# surface here is double-sided on purpose: it costs a handful of extra triangles
# on a module this small and removes any front-face winding ambiguity, so a
# barrier is never see-through from the angle the camera happens to be at.
func _tri2(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	var nrm := (b - a).cross(c - a)
	if nrm.length_squared() < 1e-12:
		return
	nrm = nrm.normalized()
	for v in [a, b, c]:
		st.set_normal(nrm)
		st.add_vertex(v)
	for v in [a, c, b]:
		st.set_normal(-nrm)
		st.add_vertex(v)


func _quad2(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	_tri2(st, a, b, c)
	_tri2(st, a, c, d)


func _box_mesh(size: Vector3) -> BoxMesh:
	var bm := BoxMesh.new()
	bm.size = size
	return bm


func _add_mesh(mesh: Mesh, col: Color, node_name := "") -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _mat(col)
	if node_name != "":
		mi.name = node_name
	add_child(mi)
	return mi


func _add_box(size: Vector3, pos: Vector3, col: Color, node_name := "") -> MeshInstance3D:
	var mi := _add_mesh(_box_mesh(size), col, node_name)
	mi.position = pos
	return mi


func _add_cyl(radius: float, height: float, pos: Vector3, col: Color,
		rot := Vector3.ZERO, segments := 8) -> MeshInstance3D:
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = height
	cm.radial_segments = segments
	cm.rings = 1
	var mi := _add_mesh(cm, col)
	mi.position = pos
	mi.rotation = rot
	return mi


# Flat-lit PS1 material, cached per colour so repeated parts share one material.
func _mat(col: Color) -> ShaderMaterial:
	if _mats.has(col):
		return _mats[col]
	var mat := ShaderMaterial.new()
	mat.shader = BARRIER_SHADER
	mat.set_shader_parameter("albedo_color", col)
	mat.set_shader_parameter("light_amount", 0.85)
	mat.set_shader_parameter("light_dir", sun_direction.normalized())
	mat.set_shader_parameter("sun_color", Color(0.55, 0.52, 0.48))
	mat.set_shader_parameter("sky_color", Color(0.55, 0.6, 0.7))
	mat.set_shader_parameter("ground_color", Color(0.35, 0.3, 0.25))
	_mats[col] = mat
	return mat
