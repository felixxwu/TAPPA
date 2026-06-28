extends Node3D
# garage.gd — a diegetic 3D rally-team SERVICE-PARK GARAGE: a low modular
# structure of two open, EMPTY service bays under one flat roof, with a plain
# dark fascia band across the front, dark divider pillars, off-white fabric
# walls and a simple ceiling light rig. The bays are deliberately bare so the
# game can stage its own contents inside them (e.g. the player's car).
#
# Like hq.gd / podium.gd the geometry is built PROCEDURALLY from primitives via
# the _block helper (no imported mesh) so it stays light and tweakable. The
# build is split into one function per element; tweak the CONSTANTS block to
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
# Exposed so a host scene (e.g. the HQ hub) can re-size the shell to its
# footprint before the model builds; defaults are the standalone proportions.
@export var num_bays := 2
@export var bay_width := 6.0    # clear opening width of one bay
@export var bay_depth := 9.0    # front-to-back depth of the structure
@export var pillar_w := 0.5     # square section of the dividing pillars
@export var wall_h := 4.4       # height of the bay opening (underside of fascia)
@export var fascia_h := 1.2     # the plain header band above the openings
@export var roof_t := 0.25
@export var front_overhang := 1.1  # roof + fascia jut out past the bay opening

# --- Palette -----------------------------------------------------------------
const C_FASCIA := Color(0.12, 0.13, 0.15)        # charcoal brand band
const C_PILLAR := Color(0.15, 0.16, 0.19)
const C_ROOF := Color(0.90, 0.90, 0.91)
const C_WALL := Color(0.87, 0.87, 0.85)          # off-white fabric walls
const C_FLOOR := Color(0.22, 0.23, 0.26)         # plain concrete slab
const C_TARMAC := Color(0.30, 0.31, 0.34)
const C_GRAVEL := Color(0.46, 0.41, 0.34)

# Build the environment + interior lights by default. A host scene that already
# provides its own lighting can set this false before adding the garage.
@export var build_environment := true
# Build the gravel/tarmac ground by default. A host scene with its own ground
# (e.g. the HQ grass + concrete apron) sets this false to keep just the shell.
@export var build_ground := true

var _mat_cache: Dictionary = {}


func _ready() -> void:
	build()


# Build the whole garage. Public so the render harness / tests can call it on a
# freshly-`new()`d instance without going through _ready timing.
func build() -> void:
	if build_environment:
		_build_environment()
	if build_ground:
		_build_ground()
	_build_structure()
	_build_ceiling_rig()


# --- Helpers -----------------------------------------------------------------

# Cached standard material keyed by (color, emissive).
func _mat(color: Color, emissive := false, rough := 0.9) -> StandardMaterial3D:
	var key := "%s|%s|%s" % [color, emissive, rough]
	if _mat_cache.has(key):
		return _mat_cache[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	if emissive:
		m.emission_enabled = true
		m.emission = color
		m.emission_energy_multiplier = 1.6
	_mat_cache[key] = m
	return m


# A box mesh of `size` centred at `pos`, added under self.
func _block(pos: Vector3, size: Vector3, color: Color, emissive := false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = _mat(color, emissive)
	mi.position = pos
	add_child(mi)
	return mi


# Total structure width across all bays + the pillars between/around them.
func _total_width() -> float:
	return num_bays * bay_width + (num_bays + 1) * pillar_w


# World X of the centre of bay `i` (0 = left / −X).
func _bay_center_x(i: int) -> float:
	var left := -_total_width() * 0.5
	return left + pillar_w + i * (bay_width + pillar_w) + bay_width * 0.5


# World X of the centre of pillar `i` (0..num_bays, left to right).
func _pillar_center_x(i: int) -> float:
	var left := -_total_width() * 0.5
	return left + pillar_w * 0.5 + i * (bay_width + pillar_w)


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
	gravel.material_override = _mat(C_GRAVEL, false, 1.0)
	gravel.position.y = -0.02
	add_child(gravel)

	# Tarmac apron spanning the structure front, a touch above the gravel.
	var apron := MeshInstance3D.new()
	var ap := PlaneMesh.new()
	ap.size = Vector2(_total_width() + 10.0, bay_depth + 14.0)
	apron.mesh = ap
	apron.material_override = _mat(C_TARMAC, false, 0.95)
	apron.position = Vector3(0.0, 0.0, bay_depth * 0.5 - 7.0)
	add_child(apron)


# --- Structure: floor slab, walls, pillars, fascia, roof ---------------------

func _build_structure() -> void:
	var w := _total_width()
	var back_z := -bay_depth
	var t := 0.4

	# Concrete slab under the whole footprint.
	_block(Vector3(0.0, 0.04, -bay_depth * 0.5), Vector3(w, 0.08, bay_depth), C_FLOOR)

	# Back wall + side walls in off-white fabric.
	_block(Vector3(0.0, wall_h * 0.5, back_z), Vector3(w, wall_h, t), C_WALL)
	_block(Vector3(-w * 0.5, wall_h * 0.5, -bay_depth * 0.5), Vector3(t, wall_h, bay_depth), C_WALL)
	_block(Vector3(w * 0.5, wall_h * 0.5, -bay_depth * 0.5), Vector3(t, wall_h, bay_depth), C_WALL)

	# Front pillars (the dark dividers between/around the bays).
	for i in range(num_bays + 1):
		var px := _pillar_center_x(i)
		_block(Vector3(px, (wall_h + fascia_h) * 0.5, front_overhang * 0.3),
			Vector3(pillar_w, wall_h + fascia_h, pillar_w), C_PILLAR)

	# Plain fascia header band across the full front, jutting out over the openings.
	var fascia_y := wall_h + fascia_h * 0.5
	_block(Vector3(0.0, fascia_y, front_overhang), Vector3(w + 0.4, fascia_h, 0.4), C_FASCIA)

	# Flat roof spanning the footprint + front overhang.
	var roof_depth := bay_depth + front_overhang
	_block(Vector3(0.0, wall_h + fascia_h + roof_t * 0.5, front_overhang - roof_depth * 0.5 + 0.5),
		Vector3(w + 0.5, roof_t, roof_depth), C_ROOF)


# --- Ceiling light rig -------------------------------------------------------

# One emissive light strip + one soft lamp per bay — just enough to light the
# empty interior. Deliberately minimal (no truss spine / clutter).
func _build_ceiling_rig() -> void:
	var rig_y := wall_h + fascia_h - 0.35
	for i in range(num_bays):
		var cx := _bay_center_x(i)
		_block(Vector3(cx, rig_y, -bay_depth * 0.5),
			Vector3(0.25, 0.12, bay_depth - 1.5), Color(0.92, 0.92, 0.94), true)
		var lamp := OmniLight3D.new()
		lamp.position = Vector3(cx, rig_y - 0.4, -bay_depth * 0.5 + 1.0)
		lamp.light_energy = 1.4
		lamp.omni_range = 12.0
		lamp.light_color = Color(0.96, 0.97, 1.0)
		add_child(lamp)
