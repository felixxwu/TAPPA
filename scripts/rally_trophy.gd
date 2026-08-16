class_name RallyTrophy
extends RefCounted
# Procedural trophy marker for the HQ map table's SPECIAL EVENT pins (hq.gd). Where an
# ordinary rally plants a flag (RallyFlag), a star-gated special stands a small low-poly
# cup — a stepped plinth, a stem, a tapered bowl with two ring handles and a finial bead.
# The silhouette alone says "this one is a prize", which is the whole point: a special is
# the prestige event on its corner of the map and should not read as one more flag.
#
# Same two independent state axes as RallyFlag, so the map keeps ONE visual language:
#
# Cup + finial (the prize itself) — your BEST RESULT here, which a trophy can say more
# precisely than a pennant can:
#   won outright (3 stars)      → warm gold
#   rest of the podium (2 stars) → silver
#   finished off the podium (1)  → bronze
#   never finished               → plain metal grey (nothing won yet)
#
# Plinth + base disk — RACEABILITY, mirroring the flag's green/grey pennant axis:
#   an eligible car is owned → green   (you can enter this now)
#   none, or still star-locked → dark grey
#
# The palette is imported from RallyFlag rather than re-declared, so the two markers
# cannot drift apart on what "gold" or "raceable green" means.
#
# All geometry is procedural (no .glb) and deliberately cheap — the table builds a marker
# for every rally on the roster at once, so this is a handful of primitives with low
# segment counts and no per-instance texture. `build()` returns a Node3D whose base sits
# at local y = 0, ready to drop onto the map plane exactly like a flag.

# Vertical layout, bottom-up. HEIGHT is the marker's top (where hq hangs its readout box),
# and is the one value callers need — keep it in step with the parts below.
const DISK_RADIUS := RallyFlag.DISK_RADIUS   # identical footprint to a flag's base coin
const DISK_HEIGHT := RallyFlag.DISK_HEIGHT
const PLINTH_SIZE := 0.090      # square plinth, x/z
const PLINTH_HEIGHT := 0.042
const STEM_RADIUS := 0.013
const STEM_HEIGHT := 0.105
const CUP_BOTTOM_RADIUS := 0.040  # narrow where it meets the stem
const CUP_TOP_RADIUS := 0.070     # flares out to the rim
const CUP_HEIGHT := 0.115
const FINIAL_RADIUS := 0.018
const HANDLE_RADIUS := 0.032      # ring handles, one each side (+/- X)
const HANDLE_THICKNESS := 0.008

# Total height, matching the assembled parts (finial sits half-proud of the rim). Sized to
# stand as tall as a flag pole (RallyFlag.POLE_HEIGHT): a special is the PRESTIGE event on
# its corner, so its marker must not read as a smaller thing than the ordinary rallies
# around it. test_rally_trophy pins that relationship.
const HEIGHT := (DISK_HEIGHT + PLINTH_HEIGHT + STEM_HEIGHT + CUP_HEIGHT
	+ FINIAL_RADIUS)

# Medal palette. Gold is shared with RallyFlag so a won rally reads the same on both
# markers; silver and bronze are trophy-only, since a pennant has no way to show placement.
const MEDAL_GOLD := RallyFlag.ACCENT_GOLD
const MEDAL_SILVER := Color(0.82, 0.84, 0.88)
const MEDAL_BRONZE := Color(0.80, 0.52, 0.30)
const MEDAL_NONE := RallyFlag.ACCENT_METAL     # nothing won here yet

# Plinth/base tints. DERIVED from the flag's pennant axis rather than reused raw: the flag
# wears its green on a small cloth pennant, whereas here it covers a chunky plinth, and at
# that size the full-brightness green overpowers the cup it is supposed to frame. Darkened
# to a deep racing green that still reads unmistakably as "go" beside the grey.
const BASE_RACEABLE := Color(0.10, 0.34, 0.13)
const BASE_INERT := Color(0.20, 0.21, 0.24)


# The cup colour for a best-finish medal count (hq._stars_for: 3 = won outright, 2 = the
# rest of the podium, 1 = finished off the podium, 0 = never finished). A locked special
# can't have been raced, so it always reads as unwon.
static func medal_color(locked: bool, stars: int) -> Color:
	if locked:
		return MEDAL_NONE
	# if/elif rather than `match`: the tiers are constants on another class, which match
	# patterns can't take, and thresholds keep the mapping right if an amount is retuned.
	var rated := clampi(stars, 0, RallyLibrary.MAX_STARS_PER_RALLY)
	if rated >= RallyLibrary.STARS_FOR_WIN:
		return MEDAL_GOLD
	if rated >= RallyLibrary.STARS_FOR_PODIUM:
		return MEDAL_SILVER
	if rated >= RallyLibrary.STARS_FOR_FINISH:
		return MEDAL_BRONZE
	return MEDAL_NONE


# The plinth/base colour: green when the player owns a car that may enter, else grey.
# Locked forces grey — the same "can't race this" reading a locked flag gets.
static func base_color(locked: bool, has_eligible_car: bool) -> Color:
	return BASE_RACEABLE if (not locked and has_eligible_car) else BASE_INERT


# Build a complete trophy marker. Returns a Node3D rooted at the base (local y = 0).
# `stars` is the best-finish medal count (0..MAX_STARS_PER_RALLY), `has_eligible_car`
# whether the player owns a car that may enter, `locked` forces the unwon + inert look.
static func build(locked: bool, stars: int, has_eligible_car: bool) -> Node3D:
	var root := Node3D.new()
	root.name = "RallyTrophy"
	var medal := medal_color(locked, stars)
	var base_tint := base_color(locked, has_eligible_car)
	var medal_mat := _metal_mat(medal)
	var base_mat := _stone_mat(base_tint)

	# Base coin — same radius/thickness as a flag's, so a trophy pin sits on the map with
	# an identical footprint and the table's pin spacing needs no special case.
	var disk := MeshInstance3D.new()
	var coin := CylinderMesh.new()
	coin.top_radius = DISK_RADIUS
	coin.bottom_radius = DISK_RADIUS
	coin.height = DISK_HEIGHT
	coin.radial_segments = 16
	disk.mesh = coin
	disk.position = Vector3(0.0, DISK_HEIGHT * 0.5, 0.0)
	disk.material_override = base_mat
	root.add_child(disk)

	# Plinth: a squat square block standing on the coin. Reads as the engraved base a real
	# trophy is bolted to, and gives the silhouette a wider foot than a flag's bare pole.
	var plinth := MeshInstance3D.new()
	var block := BoxMesh.new()
	block.size = Vector3(PLINTH_SIZE, PLINTH_HEIGHT, PLINTH_SIZE)
	plinth.mesh = block
	plinth.position = Vector3(0.0, DISK_HEIGHT + PLINTH_HEIGHT * 0.5, 0.0)
	plinth.material_override = base_mat
	root.add_child(plinth)

	var stem_base := DISK_HEIGHT + PLINTH_HEIGHT

	# Stem: a thin column from the plinth up to the bowl.
	var stem := MeshInstance3D.new()
	var post := CylinderMesh.new()
	post.top_radius = STEM_RADIUS
	post.bottom_radius = STEM_RADIUS
	post.height = STEM_HEIGHT
	post.radial_segments = 8
	stem.mesh = post
	stem.position = Vector3(0.0, stem_base + STEM_HEIGHT * 0.5, 0.0)
	stem.material_override = medal_mat
	root.add_child(stem)

	var cup_base := stem_base + STEM_HEIGHT

	# Bowl: a truncated cone flaring to the rim. The taper is deliberately GENTLE — a steep
	# one reads as a funnel rather than a cup, which is the single biggest thing separating
	# "trophy" from "traffic cone on a stick" at this poly count. 12 radial segments is the
	# low-poly sweet spot: the facets read as deliberate at table scale.
	var cup := MeshInstance3D.new()
	var bowl := CylinderMesh.new()
	bowl.bottom_radius = CUP_BOTTOM_RADIUS
	bowl.top_radius = CUP_TOP_RADIUS
	bowl.height = CUP_HEIGHT
	bowl.radial_segments = 12
	bowl.rings = 1
	cup.mesh = bowl
	cup.position = Vector3(0.0, cup_base + CUP_HEIGHT * 0.5, 0.0)
	cup.material_override = medal_mat
	root.add_child(cup)

	# Handles: a ring each side of the bowl, upper third, where a cup's handles sit. Rotated
	# so each ring's plane faces the viewer across X rather than lying flat.
	var handle_y := cup_base + CUP_HEIGHT * 0.62
	for side in [-1.0, 1.0]:
		var handle := MeshInstance3D.new()
		var ring := TorusMesh.new()
		ring.inner_radius = HANDLE_RADIUS - HANDLE_THICKNESS
		ring.outer_radius = HANDLE_RADIUS
		ring.rings = 8
		ring.ring_segments = 6
		handle.mesh = ring
		# A torus is born in the XZ plane; stand it up so it hoops out sideways.
		handle.rotation = Vector3(PI * 0.5, 0.0, 0.0)
		# Sat out AT the rim line so most of the ring hoops clear of the bowl and reads as a
		# handle. Tucked much further in and it disappears into the cone; much further out and
		# it detaches into a stray floating wire.
		handle.position = Vector3(side * (CUP_TOP_RADIUS * 0.88), handle_y, 0.0)
		handle.material_override = medal_mat
		root.add_child(handle)

	# Finial: a bead capping the rim, so the top reads as a lid rather than an open pipe.
	var finial := MeshInstance3D.new()
	var bead := SphereMesh.new()
	bead.radius = FINIAL_RADIUS
	bead.height = FINIAL_RADIUS * 2.0
	bead.radial_segments = 10
	bead.rings = 5
	finial.mesh = bead
	finial.position = Vector3(0.0, cup_base + CUP_HEIGHT, 0.0)
	finial.material_override = medal_mat
	root.add_child(finial)

	return root


# Polished metal for the cup, stem, handles and finial — the prize surfaces.
static func _metal_mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic = 0.9
	m.roughness = 0.25
	return m


# A matte, barely-metallic finish for the plinth and coin, so the base reads as stone /
# painted wood and never competes with the cup for attention.
static func _stone_mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic = 0.1
	m.roughness = 0.8
	return m
