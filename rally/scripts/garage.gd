extends Node3D
# garage.gd — a diegetic 3D rally-team SERVICE PARK GARAGE, modelled after a WRC
# manufacturer awning (the reference is the Toyota Gazoo Racing service area):
# a long, low modular structure of open service bays under one continuous flat
# roof, with a branded fascia band across the front, driver/crew name pillars
# between the bays, white fabric curtains, a bright ceiling light rig, a white
# branded floor mat, and a rally car raised on a service lift surrounded by the
# usual pit clutter (flight cases, a tyre stack, a coiled air line, a timing
# screen). Tarmac apron out front, gravel beyond — the service-park ground.
#
# Like hq.gd / podium.gd the geometry is built PROCEDURALLY from primitives via
# the _block / _panel helpers (no imported mesh) so it stays light and tweakable.
# The build is split into one function per element; tweak the CONSTANTS block to
# re-proportion the whole structure.
#
# Self-contained: it builds its OWN WorldEnvironment, sun and interior lights so
# the scene looks right opened on its own or dropped into another scene, and it
# pulls in NO autoloads (Config/Save/…), so it instances cleanly in headless
# tests and in the multi-angle render harness (tools/render_garage.gd).
#
# Orientation convention: the garage OPENS toward +Z (the apron / the camera
# looks in from +Z), the back wall is at −Z, and the bays run along X. Bay 0 is
# the left-most (−X). Origin sits on the ground at the centre of the front edge.

# --- Proportions (metres) ----------------------------------------------------
const NUM_BAYS := 3
const CENTER_BAY := int(NUM_BAYS / 2.0)   # index of the bay that holds the hero car
const BAY_WIDTH := 6.0          # clear opening width of one bay
const BAY_DEPTH := 9.0          # front-to-back depth of the structure
const PILLAR_W := 0.5           # square section of the dividing pillars
const WALL_H := 4.4             # height of the bay opening (underside of fascia)
const FASCIA_H := 1.4           # the branded header band above the openings
const ROOF_T := 0.25
const FRONT_OVERHANG := 1.1     # roof + fascia jut out past the bay opening

# --- Palette -----------------------------------------------------------------
const C_FASCIA := Color(0.12, 0.13, 0.15)        # charcoal brand band
const C_PILLAR := Color(0.15, 0.16, 0.19)
const C_ROOF := Color(0.90, 0.90, 0.91)
const C_CURTAIN := Color(0.87, 0.87, 0.85)       # off-white fabric side/back
const C_FLOOR := Color(0.88, 0.88, 0.90)         # white vinyl mat
const C_FLOOR_EDGE := Color(0.16, 0.17, 0.20)    # dark mat border
const C_RED := Color(0.80, 0.10, 0.16)           # GR / livery red
const C_TARMAC := Color(0.30, 0.31, 0.34)
const C_GRAVEL := Color(0.46, 0.41, 0.34)
const C_CASE := Color(0.06, 0.06, 0.07)          # flight-case black
const C_METAL := Color(0.52, 0.54, 0.58)
const C_TYRE := Color(0.07, 0.07, 0.08)

# Driver / co-driver name plates for the bay pillars (as seen on the reference).
const CREW_NAMES := ["T. KATSUTA", "A. JOHNSTON", "S. OGIER"]

# Build the environment + interior lights by default. A host scene that already
# provides its own lighting can set this false before adding the garage.
@export var build_environment := true

var _mat_cache: Dictionary = {}


func _ready() -> void:
	build()


# Build the whole garage. Public so the render harness / tests can call it on a
# freshly-`new()`d instance without going through _ready timing.
func build() -> void:
	if build_environment:
		_build_environment()
	_build_ground()
	_build_structure()
	_build_floor_mat()
	_build_ceiling_rig()
	_build_crew_pillars()
	_build_branding()
	_build_lift_and_car()
	_build_pit_clutter()
	_build_crew_figures()


# --- Helpers -----------------------------------------------------------------

# Cached unshaded-aware standard material keyed by (color, emissive, metallic).
func _mat(color: Color, emissive := false, metallic := 0.0, rough := 0.85) -> StandardMaterial3D:
	var key := "%s|%s|%s|%s" % [color, emissive, metallic, rough]
	if _mat_cache.has(key):
		return _mat_cache[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic = metallic
	m.roughness = rough
	if emissive:
		m.emission_enabled = true
		m.emission = color
		m.emission_energy_multiplier = 1.6
	_mat_cache[key] = m
	return m


# A box mesh of `size` centred at `pos`, added under `parent` (defaults to self).
func _block(pos: Vector3, size: Vector3, color: Color, parent: Node3D = null,
		emissive := false, metallic := 0.0, rough := 0.85) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = _mat(color, emissive, metallic, rough)
	mi.position = pos
	(parent if parent != null else self).add_child(mi)
	return mi


# A billboarded-or-fixed 3D text label. Fixed (not billboard) so signage stays
# glued to its panel; faces +Z by default.
func _text(s: String, pos: Vector3, font_size: int, color: Color,
		parent: Node3D = null, rot_y := 0.0) -> Label3D:
	var l := Label3D.new()
	l.text = s
	l.font_size = font_size
	l.pixel_size = 0.01
	l.modulate = color
	l.outline_size = 0
	l.position = pos
	l.rotation.y = rot_y
	l.double_sided = false
	(parent if parent != null else self).add_child(l)
	return l


# Total structure width across all bays + the pillars between/around them.
func _total_width() -> float:
	return NUM_BAYS * BAY_WIDTH + (NUM_BAYS + 1) * PILLAR_W


# World X of the centre of bay `i` (0 = left / −X).
func _bay_center_x(i: int) -> float:
	var left := -_total_width() * 0.5
	return left + PILLAR_W + i * (BAY_WIDTH + PILLAR_W) + BAY_WIDTH * 0.5


# World X of the centre of pillar `i` (0..NUM_BAYS, left to right).
func _pillar_center_x(i: int) -> float:
	var left := -_total_width() * 0.5
	return left + PILLAR_W * 0.5 + i * (BAY_WIDTH + PILLAR_W)


# --- Environment + lighting --------------------------------------------------

func _build_environment() -> void:
	var we := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.62, 0.68, 0.78)   # overcast service-park sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.58, 0.64)
	e.ambient_light_energy = 1.1
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	we.environment = e
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-48.0), deg_to_rad(35.0), 0.0)
	sun.light_energy = 1.05
	sun.shadow_enabled = true
	add_child(sun)


# --- Ground ------------------------------------------------------------------

func _build_ground() -> void:
	# Gravel field underneath everything.
	var gravel := MeshInstance3D.new()
	var gp := PlaneMesh.new()
	gp.size = Vector2(120.0, 120.0)
	gravel.mesh = gp
	gravel.material_override = _mat(C_GRAVEL, false, 0.0, 1.0)
	gravel.position.y = -0.02
	add_child(gravel)

	# Tarmac apron spanning the structure front, a touch above the gravel.
	var apron := MeshInstance3D.new()
	var ap := PlaneMesh.new()
	ap.size = Vector2(_total_width() + 10.0, BAY_DEPTH + 14.0)
	apron.mesh = ap
	apron.material_override = _mat(C_TARMAC, false, 0.0, 0.95)
	apron.position = Vector3(0.0, 0.0, BAY_DEPTH * 0.5 - 7.0)
	add_child(apron)


# --- Structure: floor pad, walls, pillars, fascia, roof ----------------------

func _build_structure() -> void:
	var w := _total_width()
	var back_z := -BAY_DEPTH
	var t := 0.4

	# Concrete slab under the whole footprint.
	_block(Vector3(0.0, 0.04, -BAY_DEPTH * 0.5), Vector3(w, 0.08, BAY_DEPTH), Color(0.22, 0.23, 0.26))

	# Back wall + side walls in off-white fabric.
	_block(Vector3(0.0, WALL_H * 0.5, back_z), Vector3(w, WALL_H, t), C_CURTAIN)
	_block(Vector3(-w * 0.5, WALL_H * 0.5, -BAY_DEPTH * 0.5), Vector3(t, WALL_H, BAY_DEPTH), C_CURTAIN)
	_block(Vector3(w * 0.5, WALL_H * 0.5, -BAY_DEPTH * 0.5), Vector3(t, WALL_H, BAY_DEPTH), C_CURTAIN)

	# Internal partition curtains between bays (hang from the roof, stop short of
	# the floor) so each bay reads as its own work box.
	for i in range(1, NUM_BAYS):
		var x := _pillar_center_x(i)
		_block(Vector3(x, WALL_H * 0.5 + 0.6, -BAY_DEPTH * 0.5 + 0.5),
			Vector3(0.08, WALL_H - 1.2, BAY_DEPTH - 1.0), C_CURTAIN)

	# Front pillars (the dark dividers that carry the crew name plates).
	for i in range(NUM_BAYS + 1):
		var px := _pillar_center_x(i)
		_block(Vector3(px, (WALL_H + FASCIA_H) * 0.5, FRONT_OVERHANG * 0.3),
			Vector3(PILLAR_W, WALL_H + FASCIA_H, PILLAR_W), C_PILLAR)

	# Fascia header band across the full front, jutting out over the openings.
	var fascia_y := WALL_H + FASCIA_H * 0.5
	_block(Vector3(0.0, fascia_y, FRONT_OVERHANG), Vector3(w + 0.4, FASCIA_H, 0.4), C_FASCIA)
	# Thin tagline strip just under the fascia (the lighter sub-band on the ref).
	_block(Vector3(0.0, WALL_H + 0.08, FRONT_OVERHANG + 0.02),
		Vector3(w + 0.4, 0.16, 0.36), Color(0.22, 0.23, 0.26))

	# Flat roof spanning the footprint + front overhang.
	var roof_depth := BAY_DEPTH + FRONT_OVERHANG
	_block(Vector3(0.0, WALL_H + FASCIA_H + ROOF_T * 0.5, FRONT_OVERHANG - roof_depth * 0.5 + 0.5),
		Vector3(w + 0.5, ROOF_T, roof_depth), C_ROOF)


# --- White branded floor mat -------------------------------------------------

func _build_floor_mat() -> void:
	# One white mat per bay with a dark border and red GR corner accents + taped
	# guide lines, like the reference service-bay floors.
	for i in range(NUM_BAYS):
		var cx := _bay_center_x(i)
		var cz := -BAY_DEPTH * 0.5 + 0.6
		var mw := BAY_WIDTH - 0.4
		var md := BAY_DEPTH - 1.8
		_block(Vector3(cx, 0.09, cz), Vector3(mw, 0.02, md), C_FLOOR_EDGE)            # border
		_block(Vector3(cx, 0.10, cz), Vector3(mw - 0.5, 0.02, md - 0.5), C_FLOOR)     # white field
		# Red accent stripes front + back of the mat.
		_block(Vector3(cx, 0.105, cz - md * 0.5 + 0.4), Vector3(mw - 0.5, 0.02, 0.25), C_RED)
		_block(Vector3(cx, 0.105, cz + md * 0.5 - 0.4), Vector3(mw - 0.5, 0.02, 0.25), C_RED)
		# GR text on the mat (faces up; lay it flat).
		var t := _text("GR", Vector3(cx, 0.12, cz), 120, C_RED)
		t.rotation = Vector3(deg_to_rad(-90.0), 0.0, 0.0)
		t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER


# --- Ceiling light rig -------------------------------------------------------

func _build_ceiling_rig() -> void:
	var rig_y := WALL_H + FASCIA_H - 0.35
	# Cross trusses + long emissive light strips running front-to-back per bay.
	for i in range(NUM_BAYS):
		var cx := _bay_center_x(i)
		for off in [-1.4, 1.4]:
			_block(Vector3(cx + off, rig_y, -BAY_DEPTH * 0.5),
				Vector3(0.18, 0.12, BAY_DEPTH - 1.5), Color(0.92, 0.92, 0.94), null, true)
		# A soft point light per bay so the interior actually lifts.
		var lamp := OmniLight3D.new()
		lamp.position = Vector3(cx, rig_y - 0.4, -BAY_DEPTH * 0.5 + 1.0)
		lamp.light_energy = 1.4
		lamp.omni_range = 12.0
		lamp.light_color = Color(0.96, 0.97, 1.0)
		add_child(lamp)
	# Truss spine across the bays.
	_block(Vector3(0.0, rig_y + 0.18, -BAY_DEPTH * 0.5 + 1.5),
		Vector3(_total_width(), 0.12, 0.18), C_METAL)


# --- Crew name pillars -------------------------------------------------------

func _build_crew_pillars() -> void:
	# A vertical name plate on the front face of each bay's left pillar, reading
	# bottom-to-top like the reference (rotated 90° about Z).
	for i in range(NUM_BAYS):
		var name: String = CREW_NAMES[i % CREW_NAMES.size()]
		var px := _pillar_center_x(i) + PILLAR_W * 0.5 + 0.01
		var plate := _text(name, Vector3(px, WALL_H * 0.55, FRONT_OVERHANG * 0.3 + PILLAR_W * 0.5 + 0.02),
			28, Color(0.92, 0.92, 0.94))
		plate.rotation = Vector3(0.0, 0.0, deg_to_rad(90.0))
		plate.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER


# --- Fascia branding (GR logo + wordmark + tagline) --------------------------

func _build_branding() -> void:
	var z := FRONT_OVERHANG + 0.22
	var fy := WALL_H + FASCIA_H * 0.5
	var left := -_total_width() * 0.5

	# GR logo: a red plate with white "GR", toward the left of the fascia. The text
	# sits clearly proud of the plate (+Z) with an outline so it never z-fights.
	var logo_x := left + 1.6
	_block(Vector3(logo_x, fy, z - 0.02), Vector3(1.7, 1.0, 0.08), C_RED)
	var gr := _text("GR", Vector3(logo_x, fy, z + 0.06), 80, Color(0.97, 0.97, 0.97))
	gr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	gr.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	gr.outline_size = 8
	gr.outline_modulate = C_RED

	# Wordmark next to the logo.
	var word := _text("TOYOTA GAZOO Racing", Vector3(logo_x + 1.3, fy + 0.05, z), 64,
		Color(0.95, 0.95, 0.96))
	word.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	word.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

	# Tagline toward the right end of the band.
	var tag := _text("Pushing the limits for Better",
		Vector3(_total_width() * 0.5 - 0.4, fy, z), 34, Color(0.78, 0.80, 0.84))
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER


# --- Service lift + raised rally car -----------------------------------------

func _build_lift_and_car() -> void:
	# Centre bay holds the hero car raised on a low scissor-style platform.
	var cx := _bay_center_x(CENTER_BAY)
	var cz := -BAY_DEPTH * 0.5 - 0.3
	var lift_h := 1.05

	# Lift platform + scissor legs.
	_block(Vector3(cx, lift_h, cz), Vector3(2.4, 0.18, 5.0), C_METAL, null, false, 0.6, 0.4)
	for sx in [-0.9, 0.9]:
		_block(Vector3(cx + sx, lift_h * 0.5, cz), Vector3(0.16, lift_h, 0.16), Color(0.30, 0.31, 0.34))
		_block(Vector3(cx + sx, lift_h * 0.5, cz - 1.8), Vector3(0.16, lift_h, 0.16), Color(0.30, 0.31, 0.34))
		_block(Vector3(cx + sx, lift_h * 0.5, cz + 1.8), Vector3(0.16, lift_h, 0.16), Color(0.30, 0.31, 0.34))

	_build_car(Vector3(cx, lift_h + 0.1, cz))


# A stylised WRC Yaris-ish rally car: white body with red + black livery blocks,
# a roof, bonnet scoop, big rear wing and four chunky gravel wheels.
func _build_car(base: Vector3) -> void:
	var car := Node3D.new()
	car.position = base
	add_child(car)

	var body_w := 1.85
	var body_l := 4.1
	var white := Color(0.93, 0.93, 0.94)

	# Lower body + cabin.
	_block(Vector3(0, 0.45, 0), Vector3(body_w, 0.7, body_l), white, car)
	_block(Vector3(0, 0.95, -0.35), Vector3(body_w - 0.25, 0.55, 2.1), white, car)
	# Black livery flanks + red shoulder stripe.
	_block(Vector3(0, 0.45, 0), Vector3(body_w + 0.02, 0.32, body_l - 0.4), C_CASE, car)
	_block(Vector3(0, 0.74, 0.3), Vector3(body_w + 0.02, 0.14, body_l - 1.4), C_RED, car)
	# Windscreen / windows (dark glass).
	_block(Vector3(0, 0.98, 0.75), Vector3(body_w - 0.35, 0.42, 0.1), Color(0.10, 0.12, 0.16), car)
	_block(Vector3(0, 0.98, -1.4), Vector3(body_w - 0.35, 0.42, 0.1), Color(0.10, 0.12, 0.16), car)
	# Bonnet scoop.
	_block(Vector3(0, 0.86, 1.4), Vector3(0.7, 0.12, 0.7), C_CASE, car)
	# Rear wing.
	_block(Vector3(0, 1.25, -1.95), Vector3(body_w + 0.1, 0.08, 0.5), C_CASE, car)
	for wx in [-(body_w * 0.5), body_w * 0.5]:
		_block(Vector3(wx, 1.08, -1.95), Vector3(0.08, 0.36, 0.3), C_CASE, car)
	# Front number panel + red arrow nod to the livery.
	_block(Vector3(0, 0.5, body_l * 0.5 - 0.02), Vector3(1.1, 0.5, 0.06), white, car)
	var num := _text("18", Vector3(0, 0.55, body_l * 0.5 + 0.04), 60, C_RED, car)
	num.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	# Four wheels (white rally rims sitting in black tyres).
	var wb := 1.35   # half wheelbase
	var tw := body_w * 0.5 + 0.02
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_wheel(car, Vector3(sx * tw, 0.0, sz * wb))


func _wheel(parent: Node3D, pos: Vector3) -> void:
	var hub := Node3D.new()
	hub.position = pos
	parent.add_child(hub)
	var tyre := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.36
	cyl.bottom_radius = 0.36
	cyl.height = 0.28
	tyre.mesh = cyl
	tyre.material_override = _mat(C_TYRE, false, 0.0, 0.95)
	tyre.rotation = Vector3(0.0, 0.0, deg_to_rad(90.0))
	hub.add_child(tyre)
	var rim := MeshInstance3D.new()
	var rc := CylinderMesh.new()
	rc.top_radius = 0.2
	rc.bottom_radius = 0.2
	rc.height = 0.3
	rim.mesh = rc
	rim.material_override = _mat(Color(0.9, 0.9, 0.92), false, 0.2, 0.5)
	rim.rotation = Vector3(0.0, 0.0, deg_to_rad(90.0))
	hub.add_child(rim)


# --- Pit clutter: flight cases, tyre stack, hose reel, timing screen ---------

func _build_pit_clutter() -> void:
	# Flight cases / tool cabinets lined along the back of the left + right bays.
	for i in [0, NUM_BAYS - 1]:
		var cx := _bay_center_x(i)
		var bz := -BAY_DEPTH + 1.1
		for j in range(3):
			var x := cx - 1.6 + j * 1.6
			_block(Vector3(x, 0.65, bz), Vector3(1.3, 1.1, 0.8), C_CASE)
			_block(Vector3(x, 1.12, bz), Vector3(1.32, 0.06, 0.82), C_METAL)   # top trim
			var g := _text("GR", Vector3(x, 0.7, bz + 0.42), 22, C_RED)
			g.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	# Tyre stack in the left bay.
	var lx := _bay_center_x(0) + 1.8
	for k in range(4):
		var tyre := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.36
		cyl.bottom_radius = 0.36
		cyl.height = 0.26
		tyre.mesh = cyl
		tyre.material_override = _mat(C_TYRE, false, 0.0, 0.95)
		tyre.position = Vector3(lx, 0.16 + k * 0.27, -BAY_DEPTH + 1.0)
		add_child(tyre)

	# Coiled red air line on a small reel in the centre bay.
	var cx := _bay_center_x(CENTER_BAY) - 2.3
	_block(Vector3(cx, 1.4, -BAY_DEPTH + 0.6), Vector3(0.5, 0.5, 0.3), Color(0.2, 0.2, 0.22))
	var coil := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.18
	torus.outer_radius = 0.32
	coil.mesh = torus
	coil.material_override = _mat(C_RED, false, 0.0, 0.6)
	coil.position = Vector3(cx, 1.4, -BAY_DEPTH + 0.78)
	add_child(coil)

	# Timing screen on a stand in the right bay (emissive face + the famous clock).
	var sx := _bay_center_x(NUM_BAYS - 1) - 2.0
	var sz := -BAY_DEPTH + 0.7
	_block(Vector3(sx, 1.0, sz), Vector3(0.1, 2.0, 0.1), Color(0.2, 0.2, 0.22))   # pole
	_block(Vector3(sx, 2.1, sz + 0.05), Vector3(1.5, 0.85, 0.08), Color(0.05, 0.05, 0.07))
	_block(Vector3(sx, 2.1, sz + 0.1), Vector3(1.36, 0.7, 0.02), Color(0.06, 0.10, 0.18), null, true)
	var clk := _text("11:26:54", Vector3(sx, 2.15, sz + 0.12), 40, Color(0.5, 0.85, 1.0))
	clk.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	clk.vertical_alignment = VERTICAL_ALIGNMENT_CENTER


# --- Crew figures ------------------------------------------------------------

# Stylised mechanics in the team's black-and-red kit — they give the bays scale
# and read instantly as "people working on the car", like the reference photos.
func _build_crew_figures() -> void:
	var cx := _bay_center_x(CENTER_BAY)
	var cz := -BAY_DEPTH * 0.5 - 0.3
	# Two crew either side of the hero car, one at the nose, plus one in a side bay.
	_figure(Vector3(cx - 1.9, 0.0, cz + 0.6), deg_to_rad(90.0))
	_figure(Vector3(cx + 1.9, 0.0, cz - 0.4), deg_to_rad(-90.0))
	_figure(Vector3(cx + 0.2, 0.0, cz + 3.0), deg_to_rad(180.0))
	_figure(Vector3(_bay_center_x(0) + 0.4, 0.0, -BAY_DEPTH + 2.2), deg_to_rad(160.0))


func _figure(pos: Vector3, facing: float) -> void:
	var fig := Node3D.new()
	fig.position = pos
	fig.rotation.y = facing
	add_child(fig)
	var kit := Color(0.08, 0.08, 0.10)
	var skin := Color(0.80, 0.62, 0.50)
	# Legs.
	_block(Vector3(-0.12, 0.42, 0.0), Vector3(0.18, 0.84, 0.22), kit, fig)
	_block(Vector3(0.12, 0.42, 0.0), Vector3(0.18, 0.84, 0.22), kit, fig)
	# Torso with a red shoulder band.
	_block(Vector3(0.0, 1.15, 0.0), Vector3(0.52, 0.66, 0.28), kit, fig)
	_block(Vector3(0.0, 1.36, 0.0), Vector3(0.54, 0.12, 0.30), C_RED, fig)
	# Head.
	var head := MeshInstance3D.new()
	var hs := SphereMesh.new()
	hs.radius = 0.13
	hs.height = 0.26
	head.mesh = hs
	head.material_override = _mat(skin, false, 0.0, 0.7)
	head.position = Vector3(0.0, 1.66, 0.0)
	fig.add_child(head)
