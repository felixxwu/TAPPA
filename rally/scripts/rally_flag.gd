class_name RallyFlag
extends RefCounted
# Procedural flag marker for the HQ map-table rally pins (hq.gd). Replaces the
# old plain cone marker: a thin pole topped by a waving triangular pennant whose
# COLOUR encodes the rally's state, plus a small finial bead. The state palette
# is a medal ladder so the colour alone reads the player's best result:
#
#   locked  → slate grey   (showdown, not yet unlocked — also non-pickable)
#   0 stars → race red     (unlocked, not yet finished top-3)
#   1 star  → bronze        (best finish P3)
#   2 stars → silver        (best finish P2)
#   3 stars → gold          (best finish P1)
#
# All geometry is built procedurally (no .glb asset) so the marker stays a few
# small meshes that scale with the table — matching how the rest of the HQ props
# are built in hq.gd. `build()` returns a Node3D whose base sits at local y = 0,
# ready to drop onto the map plane.

const POLE_HEIGHT := 0.30
const POLE_RADIUS := 0.0075
const PENNANT_LENGTH := 0.22   # how far the flag flies out from the pole (+X)
const PENNANT_HEIGHT := 0.13   # height of the pennant at the hoist (pole) edge
const PENNANT_SEGMENTS := 12   # along-length tessellation for the wave
const PENNANT_WAVE_AMP := 0.045  # peak furl displacement (grows toward the fly)

# Pole is a state-independent dark metal. The finial bead is a warm gold accent
# on every ACTIVE flag, but goes grey on a locked one so "locked" reads as fully
# greyed-out / disabled rather than just another colour.
const POLE_COLOR := Color(0.16, 0.15, 0.14)
const FINIAL_COLOR := Color(0.95, 0.86, 0.45)
const FINIAL_LOCKED_COLOR := Color(0.42, 0.44, 0.48)


# Map a rally's state to its pennant colour. `stars` is 0..3 (hq._stars_for);
# `locked` wins over stars (a locked showdown shows no progress yet). Locked is a
# dark, desaturated charcoal that sits clearly below the bright metallic silver.
static func state_color(locked: bool, stars: int) -> Color:
	if locked:
		return Color(0.30, 0.32, 0.36)        # charcoal slate (disabled)
	match clampi(stars, 0, 3):
		1: return Color(0.80, 0.50, 0.27)     # bronze
		2: return Color(0.86, 0.89, 0.94)     # silver (bright metal)
		3: return Color(1.00, 0.82, 0.28)     # gold
		_: return Color(0.83, 0.26, 0.24)     # race red (0 stars)


# Build a complete flag marker (pole + pennant + finial). The pennant is tinted
# by `state_color(locked, stars)`. Returns a Node3D rooted at the pole base.
static func build(locked: bool, stars: int) -> Node3D:
	var root := Node3D.new()
	root.name = "RallyFlag"
	var color := state_color(locked, stars)

	# Pole: a thin cylinder standing on the plane.
	var pole := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = POLE_RADIUS
	cyl.bottom_radius = POLE_RADIUS
	cyl.height = POLE_HEIGHT
	cyl.radial_segments = 8
	pole.mesh = cyl
	pole.position = Vector3(0.0, POLE_HEIGHT * 0.5, 0.0)
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = POLE_COLOR
	pmat.metallic = 0.4
	pmat.roughness = 0.6
	pole.material_override = pmat
	root.add_child(pole)

	# Pennant: a waving triangular flag hung from near the top of the pole. Its
	# hoist (pole) edge spans PENNANT_HEIGHT and tapers to a point at the fly.
	var flag := MeshInstance3D.new()
	flag.mesh = _pennant_mesh()
	# Centre the hoist edge so its top sits just below the pole tip.
	flag.position = Vector3(POLE_RADIUS, POLE_HEIGHT - PENNANT_HEIGHT * 0.5 - 0.015, 0.0)
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = color
	fmat.roughness = 0.85
	fmat.cull_mode = BaseMaterial3D.CULL_DISABLED  # visible from both faces
	flag.material_override = fmat
	root.add_child(flag)

	# Finial: a small bead capping the pole tip — a warm accent so the pole top
	# never reads as a cut-off stick.
	var finial := MeshInstance3D.new()
	var bead := SphereMesh.new()
	bead.radius = 0.018
	bead.height = 0.036
	bead.radial_segments = 8
	bead.rings = 4
	finial.mesh = bead
	finial.position = Vector3(0.0, POLE_HEIGHT + 0.008, 0.0)
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = FINIAL_LOCKED_COLOR if locked else FINIAL_COLOR
	bmat.metallic = 0.6
	bmat.roughness = 0.4
	finial.material_override = bmat
	root.add_child(finial)

	return root


# A triangular pennant frozen mid-wave: vertices march along +X from the hoist
# edge to a point at the fly, the half-height tapering linearly to zero and a
# sinusoidal furl (in Z) whose amplitude grows toward the free end. Local origin
# is the hoist-edge centre; the surface is double-sided via the material.
static func _pennant_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tops: Array[Vector3] = []
	var bots: Array[Vector3] = []
	for i in PENNANT_SEGMENTS + 1:
		var t := float(i) / float(PENNANT_SEGMENTS)
		var x := PENNANT_LENGTH * t
		var half := (PENNANT_HEIGHT * 0.5) * (1.0 - t)        # taper to the fly point
		var z := PENNANT_WAVE_AMP * t * sin(t * PI * 2.4 + 0.6)  # furl grows outward
		tops.append(Vector3(x, half, z))
		bots.append(Vector3(x, -half, z))
	for i in PENNANT_SEGMENTS:
		# Two triangles per quad strip between segment i and i+1.
		st.add_vertex(tops[i]); st.add_vertex(bots[i]); st.add_vertex(tops[i + 1])
		st.add_vertex(bots[i]); st.add_vertex(bots[i + 1]); st.add_vertex(tops[i + 1])
	st.generate_normals()
	return st.commit()
