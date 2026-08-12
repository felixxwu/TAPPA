class_name BarrierSection
extends Node3D
# One 2 m module of roadside crash barrier, built entirely from code (like
# FinishArch / SignField) in the project's PS1 flat-shaded style. Sections are
# meant to be STITCHED END TO END along the outside of a sharp corner: each is
# self-contained, exactly `length` long, and its continuous elements overrun the
# module ends by `joint_overlap` so a run laid around a curve shows no gaps at the
# joints.
#
# Six candidate LOOKS are implemented behind `style` — this is a menu to choose
# from (see features/barriers.md); once one is picked the rest can go.
#
# Local frame (all styles obey it, so placement code is style-agnostic):
#   +Z / -Z  the run direction (length axis), the module centred on z = 0
#   +Y       up, ground at y = 0
#   +X       the ROAD side — the face the driver sees. Mass extends toward -X.
# So a section is placed with its Z axis along the road tangent and its +X turned
# in toward the racing line.
#
# `variant_seed` seeds the per-module jitter (bale angles, stone sizes, tyre roll)
# so a stitched run looks hand-built instead of cloned; the same seed always
# rebuilds the same module.

const BARRIER_SHADER := preload("res://shaders/ps1_models_lit.gdshader")

enum Style {
	ARMCO,        # galvanised steel W-beam guardrail on posts
	TYRE_WALL,    # stacked used tyres lashed to timber stakes
	HAY_BALES,    # staggered courses of straw bales
	TIMBER_RAIL,  # log post-and-rail fence
	JERSEY,       # precast concrete jersey/K-rail
	STONE_WALL,   # dry-stone rubble wall
}

# Display names for the render harness / any future picker UI.
const STYLE_NAMES := {
	Style.ARMCO: "ARMCO GUARDRAIL",
	Style.TYRE_WALL: "TYRE WALL",
	Style.HAY_BALES: "HAY BALES",
	Style.TIMBER_RAIL: "TIMBER RAIL",
	Style.JERSEY: "CONCRETE JERSEY",
	Style.STONE_WALL: "DRY-STONE WALL",
}

@export var style: Style = Style.ARMCO
@export var length: float = 2.0          # module length along Z (the stitch pitch)
@export var joint_overlap: float = 0.03  # how far continuous parts overrun each end
@export var variant_seed: int = 0        # per-module jitter seed
@export var sun_direction: Vector3 = Vector3(0.35, 0.85, 0.4)

# --- Palettes (per style, kept together so the whole look is tweakable here) ---
const _STEEL := Color(0.60, 0.63, 0.62)
const _STEEL_DARK := Color(0.33, 0.35, 0.35)
const _RUBBER := Color(0.12, 0.12, 0.13)
const _STRAW := Color(0.82, 0.72, 0.42)
const _TWINE := Color(0.56, 0.47, 0.30)
const _TIMBER := Color(0.44, 0.32, 0.21)
const _TIMBER_DARK := Color(0.31, 0.22, 0.15)
const _CONCRETE := Color(0.72, 0.71, 0.67)
const _CONCRETE_DARK := Color(0.55, 0.54, 0.51)
const _STONE := Color(0.60, 0.57, 0.50)
const _WARN_RED := Color(0.74, 0.18, 0.13)
const _WARN_WHITE := Color(0.92, 0.90, 0.85)

var _rng := RandomNumberGenerator.new()
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
	# Style is folded into the seed so switching style re-rolls the jitter instead
	# of reusing another style's stream.
	_rng.seed = hash(Vector2i(int(style), variant_seed))
	match style:
		Style.ARMCO: _build_armco()
		Style.TYRE_WALL: _build_tyre_wall()
		Style.HAY_BALES: _build_hay_bales()
		Style.TIMBER_RAIL: _build_timber_rail()
		Style.JERSEY: _build_jersey()
		Style.STONE_WALL: _build_stone_wall()


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
# Tyre wall — worn tyres stood ON EDGE with their faces toward the road (the
# classic lashed-tyre corner protection), two courses in a stagger so the upper
# tyres nest in the valleys of the lower ones. Held by driven stakes behind.
# ---------------------------------------------------------------------------
func _build_tyre_wall() -> void:
	var outer := 0.31
	var inner := 0.13
	var thick := (outer - inner)          # tyre tread width (its X extent on edge)
	var courses := 2
	var per_course := 3
	var pitch := length / float(per_course)
	for course in range(courses):
		# Course 1 drops into the gaps of course 0, so it rides a little lower than
		# a full diameter up.
		var y := outer + course * (outer * 1.72)
		var shift := 0.0 if course % 2 == 0 else pitch * 0.5
		for i in range(per_course + 1):
			var z := -length * 0.5 + pitch * 0.5 + i * pitch + shift
			# A staggered course owns the tyre that lands ON its far end and none at
			# its near end, so a stitched run keeps one unbroken pitch across the
			# joint instead of doubling up or leaving a hole.
			if z > length * 0.5 + 0.01:
				continue
			var t := TorusMesh.new()
			t.inner_radius = inner
			t.outer_radius = outer
			t.rings = 9
			t.ring_segments = 5
			var wear := _rng.randf_range(-0.02, 0.03)
			var mi := _add_mesh(t, _RUBBER + Color(wear, wear, wear, 0.0))
			mi.position = Vector3(thick * 0.5 - 0.06 + _rng.randf_range(-0.02, 0.02), y, z)
			# Euler order is YXZ, so Z acts first: a quarter turn about Z lays the
			# wheel axis along X and turns the tyre's face to the road. Y adds a
			# touch of hand-stacked slop. Deliberately NO roll about the tyre's own
			# axis: a plain torus is rotationally symmetric so it would not show,
			# and it would inflate local_aabb()'s box union by ~0.1 m (its Y and Z
			# half-extents are equal, so any roll spills the box below the ground).
			mi.rotation = Vector3(0.0, _rng.randf_range(-0.06, 0.06), PI * 0.5)
	var wall_h := outer * 2.0 + outer * 1.72 - outer
	# Stakes behind the stack, leaning into it to hold the courses up.
	for s in [-1.0, 1.0]:
		var stake_h: float = wall_h * 0.95
		_add_cyl(0.055, stake_h, Vector3(-0.16, stake_h * 0.5, s * length * 0.28),
			_TIMBER_DARK, Vector3(0.0, 0.0, _rng.randf_range(0.04, 0.10)), 6)


# ---------------------------------------------------------------------------
# Hay bales — two courses in a stagger. The top course is half-length at each
# end, so two stitched modules make a whole bale over the joint and the run
# reads as a continuous staggered stack rather than repeating blocks.
# ---------------------------------------------------------------------------
func _build_hay_bales() -> void:
	var bale_h := 0.40
	var bale_x := 0.56
	var whole := length * 0.5   # two bales to a module
	# course 0: two whole bales. course 1: half, whole, half — so a stitched joint
	# is spanned by a whole bale's worth of stack rather than a butt seam.
	var courses := [
		[whole, whole],
		[whole * 0.5, whole, whole * 0.5],
	]
	for course in range(courses.size()):
		var lens: Array = courses[course]
		var z := -length * 0.5
		for bale_len in lens:
			var centre_z: float = z + bale_len * 0.5
			z += bale_len
			var tint := _rng.randf_range(-0.035, 0.035)
			var col := _STRAW + Color(tint, tint * 0.8, tint * 0.5, 0.0)
			var pos := Vector3(_rng.randf_range(-0.03, 0.03),
				bale_h * (course + 0.5), centre_z)
			var mi := _add_box(Vector3(bale_x, bale_h, bale_len * 0.98), pos, col)
			mi.rotation = Vector3(0.0, _rng.randf_range(-0.04, 0.04), 0.0)
			# Twine: two strings wrapped round the bale's girth, so on the
			# road-facing face they read as a pair of thin vertical lines. Laid
			# just proud of the face (the bale's yaw jitter is small enough that
			# module-space placement still hugs it).
			if bale_len > whole * 0.75:
				for t in [-0.24, 0.24]:
					_add_box(Vector3(0.015, bale_h * 0.94, 0.035),
						pos + Vector3(bale_x * 0.5, 0.0, bale_len * t), _TWINE)


# ---------------------------------------------------------------------------
# Timber rail — a log post-and-rail fence: one post per module with two round
# rails running past it. The airiest of the six (you can see through it).
# ---------------------------------------------------------------------------
func _build_timber_rail() -> void:
	var post_h := 1.02
	var lean := _rng.randf_range(-0.035, 0.035)
	_add_cyl(0.09, post_h, Vector3(-0.06, post_h * 0.5, 0.0), _TIMBER_DARK,
		Vector3(lean * 0.5, 0.0, lean), 7)
	var rail_len := length + joint_overlap * 2.0
	for y in [0.46, 0.84]:
		_add_cyl(0.07, rail_len, Vector3(0.06, y + _rng.randf_range(-0.02, 0.02), 0.0),
			_TIMBER, Vector3(PI * 0.5, 0.0, 0.0), 7)


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
	var tint := _rng.randf_range(-0.03, 0.03)
	_add_mesh(_extrude_closed(prof, -hz, hz), _CONCRETE + Color(tint, tint, tint, 0.0), "Rail")
	# Cast seam at each end, so the modular joints read from the road.
	for s in [-1.0, 1.0]:
		_add_box(Vector3(0.24, top * 0.92, 0.03),
			Vector3(0.005, top * 0.46, s * hz), _CONCRETE_DARK)
	# Reflector plate high on the road face (red over white, hazard-marker style).
	_add_box(Vector3(0.02, 0.16, 0.10), Vector3(0.115, top - 0.16, 0.0), _WARN_WHITE)
	_add_box(Vector3(0.02, 0.08, 0.10), Vector3(0.12, top - 0.12, 0.0), _WARN_RED)


# ---------------------------------------------------------------------------
# Dry-stone wall — a solid core (so the run is never see-through) dressed with
# jittered rubble stones on the road face, the back and the coping course.
# ---------------------------------------------------------------------------
func _build_stone_wall() -> void:
	var core_h := 0.50
	var core_x := 0.42
	var hz := length * 0.5 + joint_overlap
	_add_box(Vector3(core_x, core_h, hz * 2.0), Vector3(0.0, core_h * 0.5, 0.0),
		_STONE * 0.88, "Core")
	# Face stones: three courses down each side, more on the road face than behind.
	for side in [1.0, -1.0]:
		var courses := 3 if side > 0.0 else 2
		for course in range(courses):
			var z := -length * 0.5
			while z < length * 0.5 - 0.05:
				var stone_len: float = _rng.randf_range(0.18, 0.34)
				stone_len = minf(stone_len, length * 0.5 - z)
				var stone_h := core_h / float(courses) * _rng.randf_range(0.8, 1.05)
				var y: float = core_h * (course + 0.5) / float(courses)
				var shade := _rng.randf_range(-0.07, 0.07)
				var mi := _add_box(
					Vector3(_rng.randf_range(0.16, 0.24), stone_h, stone_len * 0.94),
					Vector3(side * (core_x * 0.5 - 0.04), y, z + stone_len * 0.5),
					_STONE + Color(shade, shade, shade * 0.9, 0.0))
				mi.rotation = Vector3(_rng.randf_range(-0.05, 0.05),
					_rng.randf_range(-0.12, 0.12), _rng.randf_range(-0.05, 0.05))
				z += stone_len
	# Coping: flatter stones laid across the top, overhanging both faces.
	var cz := -length * 0.5
	while cz < length * 0.5 - 0.05:
		var cap_len: float = minf(_rng.randf_range(0.22, 0.36), length * 0.5 - cz)
		var shade := _rng.randf_range(-0.05, 0.05)
		var mi := _add_box(Vector3(core_x * 1.15, 0.13, cap_len * 0.95),
			Vector3(0.0, core_h + 0.06, cz + cap_len * 0.5),
			_STONE + Color(shade, shade, shade, 0.0))
		mi.rotation = Vector3(0.0, _rng.randf_range(-0.06, 0.06), 0.0)
		cz += cap_len


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
