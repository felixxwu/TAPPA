class_name RallyFlag
extends RefCounted
# Procedural flag marker for the HQ map-table rally pins (hq.gd). A small golden /
# metal base disk that sits on the map, a thin pole standing on it topped by a
# waving triangular pennant, plus a small finial bead. The marker's look encodes
# the rally's state across two independent axes:
#
# Pennant (the flag itself):
#   placed 3rd or better  → black-and-grey CHECKERED racing flag (a result earned)
#   has an eligible car    → light green   (raceable now, not yet podiumed)
#   no eligible car         → dark grey      (can't field a qualifying car — also
#                                            the look of the still-locked showdown)
#
# Tip + base (finial bead and base disk, which always share one colour):
#   finished 1st (3 stars) → warm gold      (the rally is won)
#   otherwise               → metal grey
#
# All geometry is built procedurally (no .glb asset) so the marker stays a few
# small meshes that scale with the table — matching how the rest of the HQ props
# are built in hq.gd. `build()` returns a Node3D whose base sits at local y = 0,
# ready to drop onto the map plane.

const POLE_HEIGHT := 0.30
const POLE_RADIUS := 0.0075
const DISK_RADIUS := 0.055    # small base disk the pole stands on
const DISK_HEIGHT := 0.012    # disk thickness (a low coin sitting on the map)
const PENNANT_LENGTH := 0.22   # how far the flag flies out from the pole (+X)
const PENNANT_HEIGHT := 0.13   # height of the pennant at the hoist (pole) edge
const PENNANT_SEGMENTS := 12   # along-length tessellation for the wave
const PENNANT_WAVE_AMP := 0.045  # peak furl displacement (grows toward the fly)

# Pole is a state-independent dark metal.
const POLE_COLOR := Color(0.16, 0.15, 0.14)

# Tip + base accent palette. Gold marks a won rally; metal grey is everything else.
const ACCENT_GOLD := Color(0.96, 0.80, 0.34)
const ACCENT_METAL := Color(0.60, 0.62, 0.66)

# Solid pennant colours (the non-checkered cases).
const PENNANT_GREEN := Color(0.30, 0.95, 0.32)   # raceable: eligible car owned (bright)
const PENNANT_GREY := Color(0.30, 0.32, 0.36)    # no eligible car / locked showdown

# Checkered racing-flag swatches (generated into a tiny checker texture, cached).
# Black and grey (not white) so the flag reads muted against the bright map.
const CHECKER_DARK := Color(0.08, 0.08, 0.08)
const CHECKER_LIGHT := Color(0.52, 0.52, 0.52)
const CHECKER_COLS := 5    # visible squares along the pennant length
const CHECKER_ROWS := 3    # visible squares across the pennant height

# Pennant kinds (which appearance the flag takes).
enum { PENNANT_CHECKERED, PENNANT_SOLID_GREEN, PENNANT_SOLID_GREY }

# One shared checkerboard texture for the whole game (deterministic, generated once).
static var _checker_tex: Texture2D


# Which pennant a rally shows. A podium result (placed 3rd or better → stars >= 1)
# always wins and shows the checkered flag; otherwise green when the player owns a
# car eligible to enter, else grey. A locked rally can never be podiumed and is
# treated as having no eligible car, so it reads grey/disabled.
static func pennant_kind(locked: bool, stars: int, has_eligible_car: bool) -> int:
	if not locked and clampi(stars, 0, 3) >= 1:
		return PENNANT_CHECKERED
	if not locked and has_eligible_car:
		return PENNANT_SOLID_GREEN
	return PENNANT_SOLID_GREY


# The tip + base colour: warm gold once the rally is WON (3 stars = finished 1st),
# metal grey otherwise (including locked).
static func accent_color(locked: bool, stars: int) -> Color:
	if not locked and clampi(stars, 0, 3) == 3:
		return ACCENT_GOLD
	return ACCENT_METAL


# Build a complete flag marker (disk + pole + pennant + finial). Returns a Node3D
# rooted at the disk base (local y = 0). `stars` is the rally's best-finish medal
# count (0..3, hq._stars_for); `has_eligible_car` is whether the player owns a car
# that may enter the rally; `locked` forces the disabled grey/metal look.
static func build(locked: bool, stars: int, has_eligible_car: bool) -> Node3D:
	var root := Node3D.new()
	root.name = "RallyFlag"
	var accent := accent_color(locked, stars)

	# Base disk: a small coin sitting flat on the map plane that the pole stands on.
	# Built first so everything above is lifted to rest on its top face.
	var disk := MeshInstance3D.new()
	var disk_mesh := CylinderMesh.new()
	disk_mesh.top_radius = DISK_RADIUS
	disk_mesh.bottom_radius = DISK_RADIUS
	disk_mesh.height = DISK_HEIGHT
	disk_mesh.radial_segments = 24
	disk.mesh = disk_mesh
	disk.position = Vector3(0.0, DISK_HEIGHT * 0.5, 0.0)
	disk.material_override = _accent_mat(accent)
	root.add_child(disk)

	# Pole: a thin cylinder standing on the disk top.
	var pole := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = POLE_RADIUS
	cyl.bottom_radius = POLE_RADIUS
	cyl.height = POLE_HEIGHT
	cyl.radial_segments = 8
	pole.mesh = cyl
	pole.position = Vector3(0.0, DISK_HEIGHT + POLE_HEIGHT * 0.5, 0.0)
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
	flag.position = Vector3(POLE_RADIUS, DISK_HEIGHT + POLE_HEIGHT - PENNANT_HEIGHT * 0.5 - 0.015, 0.0)
	flag.material_override = _pennant_mat(pennant_kind(locked, stars, has_eligible_car))
	root.add_child(flag)

	# Finial: a small bead capping the pole tip — shares the tip/base accent colour.
	var finial := MeshInstance3D.new()
	var bead := SphereMesh.new()
	bead.radius = 0.018
	bead.height = 0.036
	bead.radial_segments = 8
	bead.rings = 4
	finial.mesh = bead
	finial.position = Vector3(0.0, DISK_HEIGHT + POLE_HEIGHT + 0.008, 0.0)
	finial.material_override = _accent_mat(accent)
	root.add_child(finial)

	return root


# A glossy metal material for the tip/base accent (gold or grey).
static func _accent_mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic = 0.85
	m.roughness = 0.3
	return m


# The pennant material for a given kind: a double-sided cloth that's either a solid
# tint (green / grey) or the shared black-and-white checker texture.
static func _pennant_mat(kind: int) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.roughness = 0.85
	m.cull_mode = BaseMaterial3D.CULL_DISABLED  # visible from both faces
	match kind:
		PENNANT_CHECKERED:
			m.albedo_texture = _checker_texture()
			m.albedo_color = Color.WHITE
			m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		PENNANT_SOLID_GREEN:
			m.albedo_color = PENNANT_GREEN
		_:
			m.albedo_color = PENNANT_GREY
	return m


# A triangular pennant frozen mid-wave: vertices march along +X from the hoist
# edge to a point at the fly, the half-height tapering linearly to zero and a
# sinusoidal furl (in Z) whose amplitude grows toward the free end. Local origin
# is the hoist-edge centre; the surface is double-sided via the material. UVs run
# u = 0..1 along the length and v = 0..1 across the height (collapsing to the
# centreline at the fly point), so the checker texture tiles cleanly over it.
static func _pennant_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tops: Array[Vector3] = []
	var bots: Array[Vector3] = []
	var top_uv: Array[Vector2] = []
	var bot_uv: Array[Vector2] = []
	for i in PENNANT_SEGMENTS + 1:
		var t := float(i) / float(PENNANT_SEGMENTS)
		var x := PENNANT_LENGTH * t
		var half := (PENNANT_HEIGHT * 0.5) * (1.0 - t)        # taper to the fly point
		var z := PENNANT_WAVE_AMP * t * sin(t * PI * 2.4 + 0.6)  # furl grows outward
		tops.append(Vector3(x, half, z))
		bots.append(Vector3(x, -half, z))
		# v maps the full hoist height to 0..1; both edges converge to 0.5 at the fly.
		top_uv.append(Vector2(t, 0.5 - (half / PENNANT_HEIGHT)))
		bot_uv.append(Vector2(t, 0.5 + (half / PENNANT_HEIGHT)))
	for i in PENNANT_SEGMENTS:
		# Two triangles per quad strip between segment i and i+1.
		st.set_uv(top_uv[i]); st.add_vertex(tops[i])
		st.set_uv(bot_uv[i]); st.add_vertex(bots[i])
		st.set_uv(top_uv[i + 1]); st.add_vertex(tops[i + 1])
		st.set_uv(bot_uv[i]); st.add_vertex(bots[i])
		st.set_uv(bot_uv[i + 1]); st.add_vertex(bots[i + 1])
		st.set_uv(top_uv[i + 1]); st.add_vertex(tops[i + 1])
	st.generate_normals()
	return st.commit()


# A tiny black-and-white checkerboard texture (CHECKER_COLS × CHECKER_ROWS cells),
# nearest-filtered so the squares stay crisp. Generated once and cached.
static func _checker_texture() -> Texture2D:
	if _checker_tex != null:
		return _checker_tex
	var cell := 16
	var img := Image.create(CHECKER_COLS * cell, CHECKER_ROWS * cell, false, Image.FORMAT_RGBA8)
	# Fill one solid block per checker cell (alternating), so no per-pixel divide.
	for cy in range(CHECKER_ROWS):
		for cx in range(CHECKER_COLS):
			var col := CHECKER_DARK if (cx + cy) % 2 == 0 else CHECKER_LIGHT
			img.fill_rect(Rect2i(cx * cell, cy * cell, cell, cell), col)
	_checker_tex = ImageTexture.create_from_image(img)
	return _checker_tex
