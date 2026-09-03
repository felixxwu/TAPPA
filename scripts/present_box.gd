class_name PresentBox
extends RefCounted
# Procedural gift-box marker: the HQ map target that trades stars for a random car
# (todo/star-economy.md), and the oversized version the car park opens as a reveal.
#
# Two builders off one set of proportions, so the thing the player taps on the map and the
# thing that opens in the car park are recognisably the same object:
#
#   build()          — a small static box for the map pin (like RallyFlag; RallyTrophy,
#                      the star-gated special's version of this, is deleted along with the
#                      star ledger — todo/roguelike-pivot.md decision 21).
#   build_openable() — the same box at ANY SIZE IN METRES (width x depth x wall height), with
#                      the lid and the four side walls as SEPARATELY NAMED children so the
#                      car-park cinematic can tween them apart. Nothing here animates; the
#                      caller owns the motion.
#
# Dimensions are metres, not a scale multiplier, because the reveal copy has to CONTAIN a car:
# the car park sizes it from CarLibrary.max_car_bounds() so the longest car on the roster
# still fits. A single scale factor cannot express that — cars are far longer than they are
# wide, so a square box either clips the long ones or dwarfs the narrow ones.
#
# All geometry is procedural (no .glb), matching how every other HQ prop is built. Both
# builders return a Node3D whose base sits at local y = 0, ready to drop onto a surface.

# --- Proportions (map-pin scale; build_openable scales them uniformly) --------
const SIZE := 0.20          # body width/depth (m)
# Body height is deliberately well under SIZE: a present reads as a wide, low box, and at
# reveal scale the walls only need to clear a car's roofline, not tower over it.
const BODY_HEIGHT := 0.105  # body height, lid excluded
const LID_HEIGHT := 0.035   # lid slab thickness
const LID_OVERHANG := 0.012 # how far the lid proud of the body on each side
const RIBBON_WIDTH := 0.030 # width of each ribbon band crossing the body
const RIBBON_PROUD := 0.004 # how far a ribbon stands off the surface (avoids z-fighting)
const BOW_RADIUS := 0.032   # radius of each bow loop
const BOW_TUBE := 0.011     # thickness of the bow loop tube

# Total height of the assembled box (body + lid), so a caller can hang a readout above it
# the way a pin hangs one above a flag pole.
const HEIGHT := BODY_HEIGHT + LID_HEIGHT

# --- Palette -----------------------------------------------------------------
# Deliberately NOT the design system's black/gold: this is the one cheerful object on the
# map table, and it has to read as a present at a glance rather than as another readout.
const BOX_COLOR := Color(0.86, 0.20, 0.28)      # deep festive red
const LID_COLOR := Color(0.94, 0.28, 0.34)      # a shade lighter, so the lid reads separate
const RIBBON_COLOR := Color(0.96, 0.83, 0.38)   # gold ribbon + bow


# A small static present box for the map pin.
static func build() -> Node3D:
	return build_openable(SIZE, SIZE, BODY_HEIGHT)


# The box at `width` x `depth` metres with `body_h` metre walls, with the openable parts
# named so a caller can animate them:
#
#   "Lid"    — the slab on top (tween it up and out of frame)
#   "SideN" / "SideE" / "SideS" / "SideW" — the four walls, each PIVOTED AT ITS BOTTOM EDGE
#             so rotating it about its own local X/Z drops it outward like a hinged panel.
#
# The pivot placement is the whole reason the walls are separate Node3Ds wrapping a mesh:
# a mesh centred on the wall would rotate about its middle and sink through the floor.
#
# X is width, Z is depth — matching the car-park convention where a car's LENGTH runs along Z
# (its marker faces +Z), so `depth` is what has to cover a car's length.
static func build_openable(width := SIZE, depth := SIZE, body_h := BODY_HEIGHT) -> Node3D:
	var root := Node3D.new()
	root.name = "PresentBox"

	var half_w := width * 0.5
	var half_d := depth * 0.5
	# Trim sizes (ribbon, bow, wall thickness) scale off the NARROW dimension, so the dressing
	# stays proportionate on a long thin box instead of a 6 m ribbon on a 2 m face.
	var s := (minf(width, depth) / SIZE) if SIZE > 0.0 else 1.0
	var wall := RIBBON_PROUD * s  # walls are thin slabs; reuse the small offset as thickness

	# Floor pad, so an opened box still reads as a container rather than four loose panels.
	var floor_slab := MeshInstance3D.new()
	var floor_mesh := BoxMesh.new()
	floor_mesh.size = Vector3(width, wall, depth)
	floor_slab.mesh = floor_mesh
	floor_slab.position = Vector3(0.0, wall * 0.5, 0.0)
	floor_slab.material_override = _mat(BOX_COLOR)
	root.add_child(floor_slab)

	# Four walls. Each is a Node3D at the bottom edge of that side, holding a mesh offset
	# up and inward — so `rotation` on the wrapper hinges the panel about the floor line.
	var sides := [
		["SideN", Vector3(0.0, 0.0, -half_d), Vector3(width, body_h, wall)],
		["SideS", Vector3(0.0, 0.0, half_d), Vector3(width, body_h, wall)],
		["SideW", Vector3(-half_w, 0.0, 0.0), Vector3(wall, body_h, depth)],
		["SideE", Vector3(half_w, 0.0, 0.0), Vector3(wall, body_h, depth)],
	]
	for spec in sides:
		var hinge := Node3D.new()
		hinge.name = String(spec[0])
		hinge.position = spec[1]
		root.add_child(hinge)
		var panel := MeshInstance3D.new()
		var panel_mesh := BoxMesh.new()
		panel_mesh.size = spec[2]
		panel.mesh = panel_mesh
		panel.position = Vector3(0.0, body_h * 0.5, 0.0)
		panel.material_override = _mat(BOX_COLOR)
		hinge.add_child(panel)
		# Gold ribbon band running up the outside of each wall.
		var band := MeshInstance3D.new()
		var band_mesh := BoxMesh.new()
		var along_x: bool = Vector3(spec[2]).x > Vector3(spec[2]).z
		band_mesh.size = (Vector3(RIBBON_WIDTH * s, body_h, wall) if along_x
			else Vector3(wall, body_h, RIBBON_WIDTH * s))
		band.mesh = band_mesh
		var out := Vector3(spec[1]).normalized() * (wall * 0.6)
		band.position = Vector3(0.0, body_h * 0.5, 0.0) + out
		band.material_override = _mat(RIBBON_COLOR, true)
		hinge.add_child(band)

	# Lid: a slightly overhanging slab, plus crossed ribbon and a two-loop bow on top. All
	# parented to the lid so it lifts away as one piece.
	var lid := Node3D.new()
	lid.name = "Lid"
	lid.position = Vector3(0.0, body_h, 0.0)
	root.add_child(lid)

	var lid_h := LID_HEIGHT * s
	var lid_w := width + LID_OVERHANG * 2.0 * s
	var lid_d := depth + LID_OVERHANG * 2.0 * s
	var slab := MeshInstance3D.new()
	var slab_mesh := BoxMesh.new()
	slab_mesh.size = Vector3(lid_w, lid_h, lid_d)
	slab.mesh = slab_mesh
	slab.position = Vector3(0.0, lid_h * 0.5, 0.0)
	slab.material_override = _mat(LID_COLOR)
	lid.add_child(slab)

	# Crossed ribbon over the lid top.
	for axis_x in [true, false]:
		var cross := MeshInstance3D.new()
		var cross_mesh := BoxMesh.new()
		cross_mesh.size = (Vector3(lid_w, RIBBON_PROUD * s, RIBBON_WIDTH * s) if axis_x
			else Vector3(RIBBON_WIDTH * s, RIBBON_PROUD * s, lid_d))
		cross.mesh = cross_mesh
		cross.position = Vector3(0.0, lid_h + RIBBON_PROUD * s * 0.5, 0.0)
		cross.material_override = _mat(RIBBON_COLOR, true)
		lid.add_child(cross)

	# Bow: two torus loops leaning apart, with a small knot between them.
	for sign_x in [-1.0, 1.0]:
		var loop := MeshInstance3D.new()
		var torus := TorusMesh.new()
		torus.inner_radius = maxf(0.001, (BOW_RADIUS - BOW_TUBE) * s)
		torus.outer_radius = (BOW_RADIUS + BOW_TUBE) * s
		loop.mesh = torus
		loop.position = Vector3(sign_x * BOW_RADIUS * s, lid_h + BOW_RADIUS * s * 0.9, 0.0)
		loop.rotation = Vector3(PI * 0.5, 0.0, sign_x * 0.45)
		loop.material_override = _mat(RIBBON_COLOR, true)
		lid.add_child(loop)

	var knot := MeshInstance3D.new()
	var knot_mesh := SphereMesh.new()
	knot_mesh.radius = BOW_TUBE * 1.6 * s
	knot_mesh.height = BOW_TUBE * 3.2 * s
	knot.mesh = knot_mesh
	knot.position = Vector3(0.0, lid_h + BOW_TUBE * 1.6 * s, 0.0)
	knot.material_override = _mat(RIBBON_COLOR, true)
	lid.add_child(knot)

	return root


# Paper is matte; ribbon is glossy so the bow catches a highlight and reads as satin.
static func _mat(color: Color, glossy := false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic = 0.55 if glossy else 0.0
	m.roughness = 0.28 if glossy else 0.75
	return m
